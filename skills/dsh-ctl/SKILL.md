---
name: dsh-ctl
description: >
  使用 dsh-ctl 插件的本地 HTTP 控制面，查看与控制一台常驻运行的 DeepSeek Harness
  （`dsh web`）：摸清一台陌生机器上的 fleet、巡检正在跑的会话、判定是否卡住、注入 prompt。
  用于「这台/那台机器上的 DSH 现在在干什么」「让它接着干」「把它停下来」这类任务。
---

# dsh-ctl：查看与控制一台常驻的 DSH

## 0. 三十秒上手

```sh
# 本机
curl -s http://127.0.0.1:17390/ctl/health
curl -s "http://127.0.0.1:17390/ctl/sessions?running=1"

# 另一台机器（永远先 SSH 到那台机器，再打它自己的 loopback）
ssh <host> 'curl -s http://127.0.0.1:17390/ctl/health'
```

三条命令答不出问题，再往下读。

## 1. 原理（先懂这个，再谈命令）

DSH 只有 `web` profile 是长跑服务，其它（`headless` / `acp` / `sdk`）都会随调用结束或
stdio 断开而退出。所以「一直挂着」= 一个常驻的 `dsh web`。

`dsh web` 自己的 `/api` 有启动 token、签名 cookie 和 Host/Origin 栅栏，脚本调用很别扭。
`dsh-ctl` 是 bundle 插件，用 `ctx.webServer.register()` 注册**栅栏之外**的一等路由，
挂在 `127.0.0.1:<port>`。

- **只能 loopback**。非本机 socket 直接 403。远程一律 `ssh <host> '<命令>'`，
  **不要**试图直连 `http://<对端IP>:<port>`，也不要把它 bind 到 `0.0.0.0`。
- 插件只在装了它的 profile 里生效。没装 = 路由不存在，不是服务坏了。

## 2. 摸清一台机器（陌生 fleet 的探索顺序）

按顺序来，每一步都可能直接终止后面的步骤。

### 2.1 先确认"哪台机器、怎么连"

**连接方式不在本 skill 里**（见第 8 节）。先问用户，或读用户维护的本地登记表。
拿到 host 后先验证连通性，不要假设它在跑：

```sh
ssh <host> 'echo ok'      # 连不上就别往下猜
```

### 2.2 找到 DSH 进程和它用的 profile

```sh
# POSIX
ps -axo pid,etime,command | grep -i 'dsh' | grep -v grep
pgrep -af 'dsh .*--port'          # 只匹配带 --port 的常驻实例

# Windows（远程时用 powershell -NoProfile -Command "..."）
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'bin\.js' } |
  Select-Object ProcessId, @{n='cmd';e={$_.CommandLine}}
```

命令行里能看到 **profile 名**和 **`--port`**，这两个是后面所有命令的前提。
同一个 DSH_HOME 下可以并存多个 profile，各自是独立的 fleet。

### 2.3 确认端口

默认 `17390`，**但这不是约定**——启动脚本允许覆盖。以 2.2 的 `--port` 为准，
或用监听表反查：

```sh
lsof -nP -iTCP -sTCP:LISTEN | grep -i node          # POSIX
Get-NetTCPConnection -State Listen | ? LocalPort -eq <port>   # Windows
```

### 2.4 区分三种"没响应"

这一步最容易误判，三种情况处理完全不同：

| 现象 | 含义 | 下一步 |
|---|---|---|
| 连接被拒绝（端口无监听） | 进程根本没跑 | 去查保活机制（2.5）或手动拉起 |
| `GET /` 返回 200，`GET /ctl` 返回 **404** | 服务在跑，但**没装 dsh-ctl 插件** | 装插件，不要以为服务坏了 |
| `GET /ctl` 有响应但 `/ctl/health` 超时 | 插件在加载或宿主忙 | 等几秒重试，再不行看进程日志 |

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>       # 页面
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/ctl   # 插件
```

### 2.5 谁在守着它（决定"能不能重启"）

| 平台 | 查看方式 | 备注 |
|---|---|---|
| macOS | `launchctl print gui/$(id -u)/<label>` | LaunchAgent，`KeepAlive` |
| Linux | `systemctl status <unit>` | systemd |
| Windows | `Get-ScheduledTask -TaskName <name>` | 任务计划；`RunLevel` 看是否提权 |
| 无 | 进程直接跑的 | SSH 断开会带走它，重启需要重新拉起 |

## 3. 巡检：现在有哪些会话在跑

一次拿全量，然后本地分组。**不要一个会话一个请求地扫**。

```sh
curl -s "http://127.0.0.1:<port>/ctl/sessions?limit=100"
```

- `limit` 上限 100，默认很小；机器上会话可能上百，先看 `total`。
- 返回 `{total, running, returned, items[]}`。**`running` 是宿主给的活跃数，最省事。**

对有 `running: true` 的会话，逐个取两样东西判断是否真的在动：

```sh
curl -s "http://127.0.0.1:<port>/ctl/tail?sessionId=<id>&frames=5"
curl -s "http://127.0.0.1:<port>/ctl/control?ms=2000"
```

汇报时给一张表就够，不要贴原始 JSON：

| 会话 | 状态 | 最后活动 | 在做什么 |
|---|---|---|---|
| `<title>` | running | `time` 距现在 N 秒 | 最新一条 `tool/call` 的名字 |

`/ctl/control` 每次调用会开一个 follow 流并阻塞到 `ms`，**巡检里最多调一次**，
不要放到循环里。

## 4. 三个判断，决定做什么

### 4.1 这个会话现在活着吗

**不要看时间戳。** `lastUserInputAt` 只在「用户亲手发消息」时推进（宿主只为
`source.kind === 'user'` 的 `user/message` 发 activity 事件），自主运行一天也不会动。

| 信号 | 怎么取 | 含义 |
|---|---|---|
| `running` | `/ctl/sessions?running=1` | 宿主说它在执行 |
| 最新记录的 `time` | `/ctl/tail?sessionId=…` | 日志最后一次真正推进的时间 |
| `stats.steps` | `/ctl/control` | 单调递增，变了就是在干活 |

`lastEventSeq` 是**落盘游标**：变了证明有进展，不变**不能**证明卡住。

### 4.2 卡住了，还是只是在忙

长任务里 `running: true` 可以持续几小时。判据是**步数或最新记录时间有没有前进**，
两次采样间隔 20–30 秒。都不动、且日志停在某个 `tool/call` / `job/registered` 之后
不再有新事件，才是真卡住。

卡住后：`POST /ctl/cancel` 取消该轮，再用**明确、简短、带禁止项**的 prompt 重试
（例如「不要截图、不要跑 bash、不要开后台任务」）——含糊指令容易让它再次进同一个坑。

### 4.3 注入是排队还是插队

| `mode` | 落点 | 什么时候用 |
|---|---|---|
| `queue`（默认） | 当前轮结束后的下一轮 | 不着急、不想打断 |
| `steer` | 插进正在跑的这一轮 | 要它立刻改方向 |

两者都只返回 `accepted: true`，**都还没落盘**。确认落点要在同一进程里看
`/ctl/control` 的 `placement`；0.2.1-rc.5 起宿主不再发布 `queues`，该字段可能为空。
`tail` 看不到未落盘的注入。

## 5. 常用动作

| 想干什么 | 调用 |
|---|---|
| 谁在跑 | `GET /ctl/sessions?running=1` |
| 看某会话最近说了什么 | `GET /ctl/tail?sessionId=…`（含 `seq` / `time` / `type` / `text`） |
| 不唤醒 agent 看持久状态 | `GET /ctl/inspect?id=…` |
| 新建会话 | `POST /ctl/create {cwd}` |
| 注入 | `POST /ctl/prompt {sessionId, text, mode?}` |
| 停当前轮 | `POST /ctl/cancel {sessionId}` |
| 改名 | `POST /ctl/rename {sessionId, title}` |
| 字段对不上时探形状 | `GET /ctl/debug/shape?sessionId=…&type=…` |
| 实时队列与统计 | `GET /ctl/control?ms=2000`（**每次开流并阻塞，不要高频调**） |

仓库里的 `scripts/ctl.sh`（POSIX）和 `scripts/ctl.ps1`（Windows）已经包好了 JSON 转义
和 URL 引号，优先用它们，别手拼 `curl`。

**Windows 远程特别注意**：默认 shell 是 `cmd.exe`，会吃掉 URL 里的 `?` 和 `&`，
`curl http://…/ctl/sessions?limit=5` 会静默返回空。把命令写成 `.ps1` 传过去执行，
或者用 `scripts/ctl.ps1`。

## 6. 两条硬约束

1. **不要高频轮询 `/ctl/control`**：每次调用都会开一个 follow 流并阻塞到 `ms`。
   轮询存活用 `/ctl/sessions` 或 `tail`。
2. **子 agent 的会话不能注入**：`POST /ctl/prompt` 对 `is owned by subagent routing`
   的会话会被拒绝。只对根会话注入。

## 7. 排障顺序

1. `ssh` 连不上 → 与 DSH 无关，先解决网络/认证。
2. 端口无监听 → 进程没跑。Windows 上 SSH 直接拉起的进程会随会话被杀，
   持久化必须走计划任务（`scripts/win-install-scheduledtask.ps1`）。
3. `/` 通但 `/ctl` 404 → 该 profile 没装插件。
4. 有响应但会话列表为空 → `DSH_HOME/sessions` 是否存在、是不是同一个 profile。
5. 字段名对不上（跨 DSH 版本）→ `/ctl/debug/shape` 打真实键路径，不要猜。
6. 注入 400 → 缺 `sessionId`；404 → session 不存在。

## 8. 连接信息不在本 skill 里

本 skill **刻意不包含任何主机名、IP、用户名、路径**，以便公开分享。
需要连哪台机器，由**用户在对话里给出**，或从用户自己维护的本地登记表读
（默认位置 `~/.dsh/fleet-registry.md`，纯个人文件，不入版本库）。

如果两者都没有，就**直接问用户**，不要猜、不要扫网段。可以按这个格式请求：

```
- 叫法：<一个便于指代的短名>
- 连接：ssh <user>@<host>   或   <ssh config 里的别名>
- 平台：macOS / Linux / Windows
- 保活：launchd <label> / systemd <unit> / 计划任务 <name> / 无
```

拿到之后，本 skill 剩下的流程对任何机器都一样。

## 9. 边界

它**只**控制会话：不装/卸插件、不管 MCP、不删会话、不 fork。插件安装是
`dsh plugin --profile <p> add …` 的事。

它**也**不会替你判断该不该动别人的会话——注入 preamble、取消任务都是有副作用的操作，
在别人的自主任务上动手前先确认。
