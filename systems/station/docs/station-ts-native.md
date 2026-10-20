# TS station 的原生部分：启动器、runner、mesh 插件

结构见 [station-ts.md](station-ts.md)。这三件用 Rust 写，预编译发布。TS 只按这里的约定用它们。测试和打包都经 `scripts/native.ts` 拿它们（怎么预编译、缓存在哪见它的文件头），只有它们自己的源码变了才编。

## 1. runner（`native/runner`，可执行文件 `stillfail-runner`）

一个 agent 进程（claude、codex app-server）一个 runner。station 重启或崩溃时 runner 和 agent 都不受影响，新 station 重新接上，从没读过的地方接着读。

启动：
```
stillfail-runner --dir <run/runners> --id <id> [--cwd <dir>] -- <program> <args…>
```
- 环境变量原样传给 agent。station 启动 runner 时就配好 agent 的环境。
- runner 先 `setsid()`（离开 station 的进程组和会话，launchd 结束 station 时不会带走它），再 fork 出 agent。agent 自己 `setpgid(0,0)` 成一个进程组，station 按 pgid 结束 agent 及其子进程。
- 写 `<dir>/<id>.json`（0600，原子写）：`{"id","runner":pid,"pid":agent pid,"pgid","startedAt":ms,"program","args","socket":"<dir>/<id>.sock","out":"<dir>/<id>.out","err":"<dir>/<id>.err"}`。
- agent 的 stdout、stderr 原样追加到 `<id>.out`、`<id>.err`。stdin 由 runner 持有。
- 在 `<dir>/<id>.sock`（0600）上听一个 Unix socket。启动成功（agent 已 fork、socket 已在听、json 已写）后才把 `{"ready":true,...同 json}` 一行写到自己的 stdout 并关掉 stdout。启动失败则非 0 退出，原因写到 stderr。

socket 协议：每条消息是一行 JSON（`\n` 结尾）。同时只服务一个 station 的连接。一个连接发来第一条消息，才算 station 的连接，这时旧连接被关掉。连上但什么都不发的连接不改变任何东西，只用来问"runner 在不在"。

**runner 在不在，只看它的 socket 有没有人应答。** `<id>.json` 里的 pid 不算数：runner 被杀、机器重启、从归档恢复之后，那个 pid 可能已经是别的进程。runner 启动时连一下 `<id>.sock`：连得上就拒绝启动（stderr 写 `<id> is already kept by a runner`，退出码 1）。连不上就删掉上一个留下的 sock/json/out/err 再启动。station 找 runner 用同一个办法。

客户端 → runner：
- `{"op":"attach"}`：开始推送。runner 从「已确认」的位置起，把 out/err 的新内容推过来，之后有新内容就推。
- `{"op":"ack","out":n,"err":m}`：station 已经处理到 out 第 n 字节、err 第 m 字节。runner 只在内存里记，下次 attach 从这里推。
- `{"op":"write","data":"<base64>"}`：写进 agent 的 stdin。`{"op":"close_stdin"}`。
- `{"op":"signal","signal":"TERM"|"KILL"|"INT","group":true}`：发给 agent（`group` 为真则发给整个进程组）。
- `{"op":"done"}`：station 读完了。agent 若已退出，runner 删掉 sock/json/out/err 并退出。若还在跑，不自动结束。

runner → 客户端：
- `{"op":"out","stream":"out"|"err","at":<这段起点的字节偏移>,"data":"<base64>"}`：按顺序推，偏移连续。
- `{"op":"exit","code":<int|null>,"signal":<string|null>}`：agent 退出且它的输出已全部推出之后才发。之后 runner 等 `done`（或下一个 attach 重放）。
- `{"op":"error","error":"..."}`：协议错误。

其它约定：
- agent 退出后 station 一直没发 `done`：runner 保留文件和 socket 一段时间（`LINGER`）后自行清理退出。
- runner 自己被杀时，agent 的 stdin 关闭，agent 按自己的规矩退出。文件还在，station 能读到最后的输出。

## 2. 启动器（`native/launcher`，可执行文件 `stillfail-station`）

`bin/stillfail`、桌面 app、安装器都调它：

- `run --app DIR [--port N] [--data DIR] [--with-parent]`：启动器自己处理，见下。给了 `--handoff FILE` 时只删掉这个文件，照常启动。
- `enroll …`、`status`、`id`、`channel …`、`comma-client`、`computer-use`：直接 `exec` `<app>/node/bin/node <app>/station/main.js <原参数>`。`$STILLFAIL_NODE` 可以换掉 Node。
- `handoff-version`：打印 `2`。旧的 Rust station 只在回答 `1` 时才 exec 交接，所以它不会把进程交给这个启动器。

`run` 时：
1. 数据目录：`--data`，否则 `$STILLFAIL_DATA`，否则 `$EMBER_DATA`，否则 `~/.stillfail`。`~/.ember` 在第一次启动时被移到 `~/.stillfail`，原处留一个链接。
2. `flock` 住 `<data>/run/station.lock`。拿不到就以退出码 3 退出（桌面 app 靠它）。
3. 启动器自己 bind MCP 端口（`config.json` 的端口）和本机回环口（`--port`），作为继承的 fd 传给 Node。新旧 Node 交接时端口不空档。端口是指定的就必须拿到，否则启动失败并说明被谁占用。没指定时默认端口被占就用任意空闲端口。
4. 起 Node，经一条控制 socket 与它通信（协议见 `native/launcher/src/run.rs` 文件头）。
5. 写 `<data>/run/station.json`：一行，字段与 Rust 版相同，`{"pid":<启动器 pid>,"startedAt":<ms>,"version":…,"handoff":1,"drain":1,"channel":1}`。安装器用 sed 读，格式不能变。
6. 信号：
   - SIGUSR2（交接）：起一个新 Node，等它说准备好。超时或失败就结束新的，写 `run/handoff-failed`，旧的照常。成功后让旧的退出，更新 `station.json` 的 `startedAt`，pid 不变。安装器靠这个判断交接成功。
   - SIGUSR1（drain）、SIGHUP：转给当前 Node。Node 说 drain 完成后，启动器写 `run/drained`。
   - SIGTERM / SIGINT：让 Node 停下，等它退出，然后自己退出。
7. Node 意外退出（不是启动器让它退的）：按递增间隔重启。连续多次在准备好之前退出就放弃，交给 launchd。
8. `--with-parent`：父进程没了就按 SIGTERM 处理。
9. 启动器的 stderr 照常（launchd 会写日志）。Node 的 stdout/stderr 继承启动器的。

## 3. mesh 插件（`native/mesh`，Node 插件 `mesh.node`）

station 和桌面端的 core 都用它。接口在 `native/mesh/src/lib.rs` 和各模块的文件头：

- iroh endpoint：station 的 key、relay、mDNS 和 DHT 发现、每个 relay 上的 keeper（ALPN `stillfail/keep/1`）、双向的连接和流。
- 经 Salix 的中继：一个 iroh 自定义传输，包由 TS 经与 Salix 的 WebSocket 收发（`salix.rs`）。
- 图片：`thumbnail`、`thumbhash`，解码和编码不占 Node 主线程。哪些文件、何时做由 TS（`src/sessions/thumbs.ts`）决定。
- 归档锁（跨进程的 `flock`）、本地 Markdown 链接解析、不跟随符号链接的打开、Profile 逻辑。
- 所有异步操作不阻塞 Node 主线程。
