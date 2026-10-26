# DSH 接入

把 DeepSeek Harness（DSH）的会话、工具与审批事件推给 WoodDeck。DSH 没有命令式 hook，
这个本地插件订阅 Cordis 事件，把状态变化转成 WoodDeck 的事件格式，每次送达都启动一个
`WoodDeck --hook dsh` 子进程，把一条 JSON 写到它的标准输入，写完立即返回，不等待子进程退出。

## 安装

1. 把本目录复制到 DSH profile 目录下：

   ```
   cp -R Resources/dsh-plugin ~/.dsh/profiles/web/dsh-wooddeck-hook
   ```

2. 在 `~/.dsh/profiles/web/cordis.patch.yml` 末尾追加下面的条目，文件里已有的内容保持不动：

   ```yaml
   - insert:
       - id: wooddeck-hook
         name: './dsh-wooddeck-hook/index.mjs'
         config:
           binaryPath: /Applications/WoodDeck.app/Contents/MacOS/WoodDeck
   ```

3. 重启 DSH。profile 的 `dsh.profile.patchReload` 为 `live` 时保存文件即可生效。

`binaryPath` 可以省略，默认值就是 `/Applications/WoodDeck.app/Contents/MacOS/WoodDeck`。
本地开发构建的应用改成自己的路径即可。

## 事件映射

| DSH 事件 | WoodDeck 事件 | tool | message |
| --- | --- | --- | --- |
| `session/created` | `session_start` | 空 | 空 |
| `user/message`（`source.kind` 为 `user`） | `prompt` | 空 | 用户输入的文本，最多 200 字 |
| `tool/call` | `tool_start` | 工具名 | 空 |
| `tool/result` | `tool_end` | 配对的工具名 | 空 |
| `approval/asked` | `permission_request` | 工具名 | 需要批准的原因 |
| `turn/end` | `stop` | 空 | 结束原因（`completed`、`aborted` 等） |
| `session/disposed` | `session_end` | 空 | 空 |

`cwd` 取自 `session.header.cwd`，`session` 是 DSH 的会话 id，与 `~/.dsh/sessions/<项目>/<会话>/`
的目录名相同，因此 WoodDeck 既有的会话记录观察和本插件的事件会归到同一个会话。

只有人类输入算 `prompt`：`runtime-context`、`schedule`、`goal` 等注入内容的 `source.kind`
不是 `user`，不会产生事件。其余事件（`step/start`、`assistant/message`、`tool/ptc-dispatch` 等）忽略。

## 发送格式

```json
{"agent":"dsh","event":"tool_start","session":"session-0123","cwd":"/Users/wood/work","title":"","message":"","tool":"bash","timestamp":1761130000200}
```

字段全部为字符串，缺失时是空字符串；`timestamp` 是 Unix 纪元毫秒。WoodDeck 收到 dsh 事件时
按接收时刻记录时间（`HookEmitter.normalize` 对 dsh 不读取该字段），`timestamp` 供其它消费方使用。

## 行为约定

- 同一会话、同一事件、同一身份（工具调用 id、审批 id、消息文本）在 200ms 内只发一次。
- 子进程启动失败、标准输入写入失败、二进制路径不存在，全部静默丢弃。
- 事件处理不 `await` 子进程退出，也不阻塞 DSH 的主流程。
- WoodDeck 没有运行时子进程直接退出，退出码为 0。
