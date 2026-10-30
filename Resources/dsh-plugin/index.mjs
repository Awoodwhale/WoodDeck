// 把 DSH 的会话、工具、审批与轮次事件推给 macOS 应用 WoodDeck。
// WoodDeck 通过 `--hook dsh` 从标准输入读取一条 JSON 事件，这里每次送达都启动一个
// 短命令子进程，写完立刻放手，不等待它退出；任何失败都静默丢弃，不影响 DSH 主流程。

import { spawn } from 'node:child_process'

export const name = 'wooddeck-hook'

const DEFAULT_BINARY = '/Applications/WoodDeck.app/Contents/MacOS/WoodDeck'
const HOOK_ARGUMENTS = ['--hook', 'dsh']
const DEDUPE_WINDOW_MS = 200
const MESSAGE_MAX_CHARS = 200
const RECENT_LIMIT = 512
const PENDING_CALL_LIMIT = 256
const TITLE_LIMIT = 256
// 恢复出来的旧会话在插件加载前就有了标题事件，第一次见到时往回找这么多条
const TITLE_SCAN_LIMIT = 4000

// 只取文本块，多个文本块之间用空格连接
function textOfContent(content) {
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    if (block.type === 'text' && typeof block.text === 'string') parts.push(block.text)
  }
  return parts.join(' ')
}

// 压缩空白，按字符截断到 MESSAGE_MAX_CHARS（一个汉字算一个字符）
function clipMessage(value) {
  const text = typeof value === 'string' ? value.replace(/\s+/g, ' ').trim() : ''
  if (text === '') return ''
  const chars = Array.from(text)
  return chars.length > MESSAGE_MAX_CHARS ? chars.slice(0, MESSAGE_MAX_CHARS).join('') : text
}

function clipField(value) {
  return typeof value === 'string' ? value : ''
}

// 构造一条 WoodDeck 事件：字段缺失或类型不对时用空字符串
export function buildEvent(fields = {}) {
  return {
    agent: 'dsh',
    event: clipField(fields.event),
    session: clipField(fields.session),
    cwd: clipField(fields.cwd),
    title: clipField(fields.title),
    name: clipField(fields.name),
    message: clipMessage(fields.message),
    tool: clipField(fields.tool),
    timestamp: Number.isFinite(fields.timestamp) ? fields.timestamp : Date.now(),
  }
}

export function apply(ctx, config) {
  try {
    const configuredBinary = config?.binaryPath
    const binaryPath =
      typeof configuredBinary === 'string' && configuredBinary.trim() !== ''
        ? configuredBinary.trim()
        : DEFAULT_BINARY

    /** 去重表：会话 + 事件 + 身份 -> 上次送达时刻 */
    const recent = new Map()
    /** 已经发出 tool_start、还没等到结果的调用：会话 + callId -> 工具名 */
    const pendingCalls = new Map()

    const spawnDelivery = (event) => {
      let child
      try {
        child = spawn(binaryPath, HOOK_ARGUMENTS, { stdio: ['pipe', 'ignore', 'ignore'] })
      } catch {
        return
      }
      const ignore = () => {}
      child.on('error', ignore)
      child.stdin?.on('error', ignore)
      try {
        child.stdin?.end(`${JSON.stringify(event)}\n`)
      } catch {
        // 对端已经退出时写入会失败，直接忽略
      }
      try {
        child.unref()
        child.stdin?.unref?.()
      } catch {
        // 忽略：子进程生命周期与 DSH 无关
      }
    }

    // identity 是同一条源事件的身份（调用 id、审批 id、消息文本），去重按它比较
    const emit = ({ identity, ...fields }) => {
      try {
        const event = buildEvent({ ...fields, timestamp: Date.now() })
        const key = `${event.session}\u0000${event.event}\u0000${identity ?? event.tool}`
        const now = Date.now()
        const seen = recent.get(key)
        if (seen !== undefined && now - seen < DEDUPE_WINDOW_MS) return
        recent.set(key, now)
        if (recent.size > RECENT_LIMIT) {
          for (const [entry, time] of recent) {
            if (now - time >= DEDUPE_WINDOW_MS) recent.delete(entry)
          }
        }
        spawnDelivery(event)
      } catch {
        // 事件写入失败一律忽略
      }
    }

    const rememberCall = (sessionId, callId, toolName) => {
      if (typeof callId !== 'string' || callId === '') return
      if (typeof toolName !== 'string' || toolName === '') return
      if (pendingCalls.size >= PENDING_CALL_LIMIT) pendingCalls.clear()
      pendingCalls.set(`${sessionId}\u0000${callId}`, toolName)
    }

    const takeCall = (sessionId, callId) => {
      if (typeof callId !== 'string' || callId === '') return ''
      const key = `${sessionId}\u0000${callId}`
      const toolName = pendingCalls.get(key) ?? ''
      pendingCalls.delete(key)
      return toolName
    }

    /** 会话 id -> 最近的会话标题（空字符串表示查过但没有） */
    const titles = new Map()

    const rememberTitle = (sessionId, title) => {
      if (sessionId === '') return
      if (titles.size >= TITLE_LIMIT && !titles.has(sessionId)) titles.clear()
      titles.set(sessionId, typeof title === 'string' ? title.trim() : '')
    }

    // 第一次见到某个会话时，从日志末尾往回找最近的 session/title
    const titleOf = (session, sessionId) => {
      if (sessionId === '') return ''
      const known = titles.get(sessionId)
      if (known !== undefined) return known
      let found = ''
      try {
        const end = typeof session?.seq === 'number' ? session.seq : 0
        const stop = Math.max(0, end - TITLE_SCAN_LIMIT)
        for (let seq = end - 1; seq >= stop; seq--) {
          const past = session.eventAt(seq)
          if (past?.type === 'session/title' && typeof past.data?.title === 'string') {
            found = past.data.title
            break
          }
        }
      } catch {
        // 读不到历史时当作没有标题
      }
      rememberTitle(sessionId, found)
      return titles.get(sessionId) ?? ''
    }

    const route = (session, event) => {
      if (event === null || typeof event !== 'object') return
      const sessionId = typeof session?.id === 'string' ? session.id : ''
      const cwd = typeof session?.header?.cwd === 'string' ? session.header.cwd : ''
      const data = event.data

      if (event.type === 'session/title') {
        rememberTitle(sessionId, data?.title)
        emit({ event: 'title', session: sessionId, cwd, name: titles.get(sessionId), identity: titles.get(sessionId) })
        return
      }
      const name = titleOf(session, sessionId)

      switch (event.type) {
        case 'user/message':
          // 只有人类输入算 prompt；注入的上下文自带其它 source 类型
          if (data?.source?.kind !== 'user') return
          emit({
            event: 'prompt',
            session: sessionId,
            cwd,
            name,
            message: textOfContent(data?.content),
            identity: textOfContent(data?.content),
          })
          return
        case 'tool/call':
          rememberCall(sessionId, data?.callId, data?.name)
          emit({ event: 'tool_start', session: sessionId, cwd, name, tool: data?.name, identity: data?.callId })
          return
        case 'tool/result':
          emit({
            event: 'tool_end',
            session: sessionId,
            cwd,
            name,
            tool: takeCall(sessionId, data?.message?.toolCallId),
            identity: data?.message?.toolCallId,
          })
          return
        case 'approval/asked':
          emit({
            event: 'permission_request',
            session: sessionId,
            cwd,
            name,
            tool: data?.toolName,
            message: data?.reason,
            identity: data?.id,
          })
          return
        case 'approval/decided':
          // 用户在 DSH 里批准或拒绝之后，岛上的审批提示随之收起
          emit({
            event: 'permission_resolved',
            session: sessionId,
            cwd,
            name,
            message: data?.outcome,
            identity: data?.id,
          })
          return
        case 'turn/end':
          emit({ event: 'stop', session: sessionId, cwd, name, message: data?.reason?.kind })
          return
        default:
          return
      }
    }

    const forgetSession = (sessionId) => {
      const prefix = `${sessionId}\u0000`
      for (const key of pendingCalls.keys()) {
        if (key.startsWith(prefix)) pendingCalls.delete(key)
      }
      titles.delete(sessionId)
    }

    ctx.on('session/created', (session) => {
      try {
        emit({ event: 'session_start', session: session?.id, cwd: session?.header?.cwd })
      } catch {
        // 忽略
      }
    })

    ctx.on('session/disposed', (session) => {
      try {
        forgetSession(typeof session?.id === 'string' ? session.id : '')
        emit({ event: 'session_end', session: session?.id, cwd: session?.header?.cwd })
      } catch {
        // 忽略
      }
    })

    ctx.on('session/event', (session, event) => {
      try {
        route(session, event)
      } catch {
        // 忽略
      }
    })
  } catch {
    // 插件装配失败同样不能影响 DSH
  }
}
