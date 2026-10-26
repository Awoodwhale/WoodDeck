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

    const route = (session, event) => {
      if (event === null || typeof event !== 'object') return
      const sessionId = typeof session?.id === 'string' ? session.id : ''
      const cwd = typeof session?.header?.cwd === 'string' ? session.header.cwd : ''
      const data = event.data

      switch (event.type) {
        case 'user/message':
          // 只有人类输入算 prompt；注入的上下文自带其它 source 类型
          if (data?.source?.kind !== 'user') return
          emit({
            event: 'prompt',
            session: sessionId,
            cwd,
            message: textOfContent(data?.content),
            identity: textOfContent(data?.content),
          })
          return
        case 'tool/call':
          rememberCall(sessionId, data?.callId, data?.name)
          emit({ event: 'tool_start', session: sessionId, cwd, tool: data?.name, identity: data?.callId })
          return
        case 'tool/result':
          emit({
            event: 'tool_end',
            session: sessionId,
            cwd,
            tool: takeCall(sessionId, data?.message?.toolCallId),
            identity: data?.message?.toolCallId,
          })
          return
        case 'approval/asked':
          emit({
            event: 'permission_request',
            session: sessionId,
            cwd,
            tool: data?.toolName,
            message: data?.reason,
            identity: data?.id,
          })
          return
        case 'turn/end':
          emit({ event: 'stop', session: sessionId, cwd, message: data?.reason?.kind })
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
