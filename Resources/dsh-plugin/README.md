# DSH 接入

把 DeepSeek Harness（DSH）的会话、工具与审批事件推给 WoodDeck。DSH 没有命令式 hook，
这个本地插件订阅 Cordis 事件，把状态变化转成 WoodDeck 的事件格式，每次送达都启动一个
`WoodDeck --hook dsh` 子进程，把一条 JSON 写到它的标准输入，写完立即返回，不等待子进程退出。

## 安装

在 WoodDeck 的「会话通知」里找到「助手」，点 DeepSeek Harness 那一行的「配置」：

1. 面板会显示检测到的 `dsh` 可执行文件；没检测到时可以自己填路径。
2. 「安装到哪些 profile」列出 `~/.dsh/profiles` 下所有带 `cordis.patch.yml` 的 profile，
   默认全部勾选。只装桌面端就只留 `web`，命令行用的 `headless` 也想要就一起勾。
3. 点「安装插件」，WoodDeck 会把插件写到每个选中的 profile 下，并往 `cordis.patch.yml`
   末尾追加挂载条目。重复安装不会产生重复条目，重新安装会覆盖旧的 `binaryPath`。
4. 重启 DSH。profile 的 `dsh.profile.patchReload` 为 `live` 时保存文件即可生效。

也可以用命令行做同样的事：

```
WoodDeck.app/Contents/MacOS/WoodDeck --dsh-hook install
WoodDeck.app/Contents/MacOS/WoodDeck --dsh-hook status
WoodDeck.app/Contents/MacOS/WoodDeck --dsh-hook uninstall
```

命令行版本装在检测到的全部 profile 里；设置文件里挑过 profile 时按挑选的来。`DSH_HOME`
环境变量可以指向别的 DSH 根目录。

手工安装的话，把本目录复制到 profile 目录下：

```
cp -R Resources/dsh-plugin ~/.dsh/profiles/web/dsh-wooddeck-hook
```

然后往该 profile 的 `cordis.patch.yml` 末尾追加（文件里已有的内容保持不动；文件内容只有
`[]` 时先删掉那一行）：

```yaml
- insert:
    - id: wooddeck-hook
      name: './dsh-wooddeck-hook/index.mjs'
      config:
        binaryPath: /Applications/WoodDeck.app/Contents/MacOS/WoodDeck
```

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
