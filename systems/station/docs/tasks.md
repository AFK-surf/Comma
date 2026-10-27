# Task 跨 Station

代码：`src/tasks/tasks.ts`。

## 名词

- **Station**：跑 Session 的地方。Salix 是云上的 Station，设备上的 station 是设备 Station。
- **Task**：一段对话，放在一个 Station 上（它的 host）。Message 只存在 host 上。
- **Message**：Task 里按 seq 排的一条记录，作者是人或某个 Session。
- **Session**：在一个 Station 上参与 Task 的运行过程。属于那个 Station，别的 Station 不记它。
- **Session Event**：Session 的执行历史，只存在 Session 所在的 Station 上。

## Station 之间的请求

走 station transport（`src/jobs/remote.ts` 的 `handle`：`task.invite`、`put`、`post`、`hello`、`file`、`leave`、`status`）。跟 `session.message` 一样，只要求对方是同一个 workspace 的 Station，不需要 `remoteJobs.allow`。host 是 Salix 时走 connector 的连接，请求一样。

| 请求 | 谁发给谁 | 内容 | 回答 |
| --- | --- | --- | --- |
| `task.invite` | host → Station | `task`、`start`（`requester`、`runtime`、`model`、`effort`、`title`）。重新邀请时还有 `answered`（同 `task.put`）。换模型时带 `replace: true` | `session`、`thread`。跑不了就回错误，说明原因。已有 Session 参与时：不带 `replace` 回原来的 Session；带 `replace` 起一个新 Session 接替，见下面“换模型” |
| `task.put` | host → 参与的 Station | `task`、`messages`（每条 `seq`、`author`、`text`、`declared`、`at`，对方的 Session 发的带 `author.session`；带文件的有 `files`，每个 `index`、`name`、`size`；有 milestone 的带 `milestones`；host 自己给 Message 编了 id 的（Salix）带 `id`）、`through`、`answered` | `through`。没有这个 Task 的 thread 就回 `unknown`（同时带 `gone`，给之前版本的 host）。有 thread 但 Session 都结束了就回 `gone` |
| `task.post` | 参与的 Station → host | `task`、`session`、`text`、`key`、`declared`、`milestones`；Session 的一轮起不来时，Station 说的那一句带 `cannot_start`（`error`：为什么）；带文件的有 `files`，每个 `index`、`name`、`size`（host 是别的 Station 时，先用 `task.post_file` 把文件整个给它） | `seq` |
| `task.post_file` | 参与的 Station → host 是 Station 时 | `task`、`session`、`key`（随后那条 post 的）、`index`、`name`、`size`、`offset`、`data`（最多 256 KiB，base64） | `have`：host 已有这个文件多少字节。`offset` 不等于它时什么都不写，参与的 Station 从 `have` 接着给。一条 post 最多 20 个文件、合计 1 GiB；post 来时文件不全就拒收。没被 post 用上的，host 一天后删掉 |
| `task.leave` | host → 参与的 Station | `task` | 空。Task 换到别处跑了：这里参与的 Session 离开它的 thread，没交给它们的 Message 不再交，它之后发到这个 Task 的话 host 都拒收；正在跑的那一轮或等待会被发出中断，不等它停下就回答（runtime 正在做的那一步可能还会做完，但写不进 Task）；thread 留着。没有这个 Task 也回空 |
| `task.posted_file` | Salix → 参与的 Station | `task`、`key`、`index`、`offset`：这个 post 还在等回答时，它带的文件 | `name`、`size`、`offset`、`data`（最多 256 KiB，base64）。没有这个 post 或文件回 `missing` |
| `task.history` | Salix → 参与的 Station | `task`、`before?`（条目序号）、`limit?`（默认 100，最多 200） | 参与的 Session 的执行记录：`start`、`total`、`entries`（运行时 transcript 的条目，最新的一页，合计不超过约 600 KB）、`usage`（模型调用次数和 token：输入含缓存、缓存、输出，模型） |
| `task.file` | 参与的 Station → host | `task`、`session`、`seq`、`id`（put 给了就带）、`index`、`offset` | `name`、`size`、`offset`、`data`（从 `offset` 起最多 256 KiB，base64）。没有这个文件（Message 没带、文件不在了）回 `missing`（原因） |
| `task.hello` | 参与的 Station → host | `tasks`：它有的这个 host 的每个 Task，`[{task, fetched}]`（`fetched`：给到哪了，`tasks_elsewhere.fetched`） | 空 |
| `task.status` | host → 参与的 Station | `task`、`session`（可省，省了就看参与这个 Task 的 Session） | `state`（`running`：一轮在跑，含启动中；`waiting`：agent 说了在等它起的活；`idle`：没在跑、没待处理；`cannot_start`：有待处理但 runtime 起不来，正在退避；`gone`：没有这个 Task 的 thread，或这个 Session 不参与）、`pending`（待处理的 Message 数）、`for_ms`（在这个状态里待了多久，毫秒；是时长不是时间戳，两边时钟不用对齐；不知道就是 null）、`last_failure`（`cannot_start` 时最后一次起不来的原因，最多 200 字）。`idle` 且 `pending` > 0 是 Station 拿着 Message 还没交给 Session（turn 被 hold，或 Station 启动后还没拿起这个 Session）。只读：不起任何一轮，不改任何状态。不认识这个请求的旧 Station 回错误 |

- `task` 是 Task 在 host 上的地址（station 上是 `EMBER/<ts>`）。`session` 是参与的 Station 上 Session 的 key。
- **编码 Task**（Salix 的 `runs_on {kind: sandbox}`，见 `docs/compute-devices.md#coding-sandboxes`）：`start` 多一个 `repo`（`owner`、`name`、`base_ref`、`branch`，接续一个 PR 时还有 `pull_request`：`branch` 就是这个 PR 的 head 分支，Session 的说明会告诉 agent 推送即更新这个 PR）。代码：`src/tasks/coding.ts`。
  - Station 收到这样的 `task.invite` 照常起 Session，同时在 Session 的 workspace 里做 git worktree：仓库缓存 `<数据目录>/repos/github.com/<owner>/<name>` 里的规范 clone，切到 `branch`。远端已有这个分支（之前的沙盒推过）就从它接着做，没有就从 `base_ref` 新建。worktree 做好之前这个 Session 不起任何一轮（Hub 按 Session 暂停），做不出来就在 thread 里说明原因。
  - 每一轮结束后，分支上有远端没有的提交就推送。
  - 这个 Session 的说明里写明沙盒是临时的：改了文件的一轮，结束前要提交并推送这个分支，只推这个分支，不强推（`codingInstructions`）。
  - `task.status` 多回 `dirty`（有没提交的改动）和 `unpushed`（有没推送的提交）。
  - 只有 Salix 发的三个请求：`task.diff`（相对 `base_ref` 合并基点的改动，含未提交和新文件；每个文件 `path`、`status`、`additions`、`deletions`、`patch`；补丁合计最多 2 MiB、最多 1000 个文件，超出的不带补丁，`truncated` 为 true；另回分支在基点之后的提交 `commits`（新的在前，最多 100 个：`sha`、`title`、`author`、`at`）和 `uncommitted`（有没有未提交的改动）。带 `commit`（分支上某个提交的完整 sha）只回这个提交的改动；带 `uncommitted: true` 只回未提交的改动和新文件）；`task.save`（把没提交的提交成一个进行中的提交并推送，回 `dirty`、`unpushed`）；`task.pull_request`（`title?`、`body?`、`draft?`：先推送，再用 `gh pr create` 开 PR，已有打开的就回它；回 `url`、`number`）。
  - 沙盒里没有 GitHub token：Group 的 token 在 L4ES 节点的代理里，代理只让它用于这个 Task 的仓库，推送只能改这个 Task 的分支（l4h-sandbox DESIGN.md §31）。git 和 gh 出示 L4ES 给沙盒的代理 token `/run/sbx/secrets/SBX_GITHUB_TOKEN`（每次启动都换新）：git 的 credential helper 每次用时读这个文件，gh 读 Station 启动时写的 `hosts.yml`，不放进任何进程的环境变量。token 快过期时由 Salix 换给 L4ES，Station 不用管。
- Salix 的 Router 还能读写 station 自己托管的 Task（页面上的对话，Task 索引里的那些），只走这台 station 自己到 Salix 的 connector 连接，别的 Station 不能发：`task.read`（`task`、`after`、`limit` ≤ 100）回 `messages`（每条 `seq`、`author_kind`、`author`、`text`、`at`、`declared`，有 milestone 的带 `milestones`）、`title` 和 `through`；`task.say`（`task`、`text`、`key`、`requester`）以 `salix/<requester>` 的身份写进去并交给这个对话的 Session，同一个 `key` 只写一次，回 `seq`。Router 用 `station:<station_id>:<thread>` 指这样的 Task（`SalixWeb.StationHostedTasks`），station 不在线时读写都失败。
- host 是 Salix 时，Worker 可以绑定一个 Station（Agent 记录的 `station_binding`）：这个 Worker 的每个 Task 都邀请那个 Station，`start` 的 `runtime`、`model`、`effort` 来自绑定，没有 `model` 就用那个 Station 的默认模型。Station 不知道有绑定，请求和上面一样。Router 给一个 Task 的 `model` 也可以只写 runtime（`{kind: runtime, provider}`，不带 model id），`start` 同样不带 `model`；VMM 或 Cloudflare 托管 Station 收到不带 `model` 的 Codex Task 时，Salix 给它平台模型。
- host 是 Salix 时，显式 `runs_on`、Worker 的 `station_binding`、Group 的 `default_task_place` 依次决定位置。都未指定时，runtime 模型的 Task 按 VMM Station、可信请求用户允许的物理机 Station、已启用的 Cloudflare Station 选择。普通内部 Task 在 Salix 运行。Salix 在邀请前把自动位置写入创建回执，重试沿用这个位置。邀请结果未知时不换 Station。Station 接收同一套邀请协议。
- host 是 Salix 时，Task 建好以后也能换模型、换地方跑（`SalixIM.TaskRun`）。新地方是 Station 就先邀请它：它已经参与这个 Task 就带 `replace`，起一个按新 `start` 跑的新 Session，加进同一个 thread，原来的 Session 离开 thread，没交给它的 Message 不再交给它；起不来就回错误，什么都不变。被替换的 Session 同样被发出中断（不等它停下），它之后发到 Task 的话 host 拒收。不认识 `replace` 的旧 Station 回原来的 Session，host 就不换，告诉人更新。Salix 里的 Worker 正在跑一轮时不换（`task_running`），等这一轮结束；换到 Salix 时 Worker 用一个按新模型新建的 Session，从头读 Task。邀请成功后，原来参与的 Station 收到 `task.leave`（连不上就不说，host 也不再给它；它再连上发 `task.hello` 时，host 对它列出、已经不参与、拿到过东西的 Task 再发 `task.leave`。Station 的 hello 只列它还有 Session 参与的 Task，所以只说一次），新 Station 的 Session 记为参与者，`sent` 归 0，从头给整个 Task；同一台 Station 上 thread 里已有的 Message 不重写，`answered` 之后的交给新 Session。

- host 是 station 时，它自己的 Task 也能换到别的 Station 上跑（`POST /threads/:id/run`，`station`、`runtime`、`model`、`effort`；`tasks.ts` 的 `moveTo`、`moveHome`），跟 Salix 换地方一样：先邀请新 Station（它已经在跑这个 Task 就带 `replace`），起不来就什么都不变。成功后原来跑它的离开：别的 Station 收到 `task.leave`；原来是 chat 自己的 session 时，它这一轮被中断、待处理的作废，之后什么都不交给它，它再往这个 Task 发的话被拒（`task_runs` 记着 Task 在哪台 Station 上跑）。新 Session 从头拿到整个 Task，`answered` 之后的交给它。换回这台 station（不给 `station`，或给自己）时，原来的 Station 收到 `task.leave`，chat 自己的 session 离开它跑过的运行时会话，下一轮另起一个（跟换账号一样，读回之前的），那台 Station 没答的消息交给它；带了 `runtime`、`model` 就同时换。连不上的 Station 之后发 `task.hello` 列出它已经不跑的 Task 时，host 再发 `task.leave`。Task 在别处跑时，Task 索引的 runtime、model 是那台 Station 起 Session 时的，状态按它最后一条消息：结束一轮（`all_done`、`need_help`）就是待看，否则在跑；`GET /threads/:id` 和 `GET /chats` 里它那一行多一个 `runsOn`（`station`、`session`、`runtime`、`model`），那一行也不再带 chat 自己 session 的 `need`。

## 送达规则

- **Message 进了 Task 就一定送到。** host 给每个参与的 Session 记交到了哪（`task_sessions.sent`）。`sent` 之后的 Message 还没给它，用 `task.put` 给，对方回答了才往前移。
- **什么时候给**：Task 有新 Message、host 启动、host 连上 still.fail cloud（拿到当前名册），以及参与的 Station 发来 `task.hello`。没有定时轮询，不设期限，不丢。
- **对方连不上**（不在名册里、连接建不起来、Salix 的连接断了）：不再试，等它连上后发 `task.hello`。
- **对方是 Group 的 Cloud VM**（host 是 Salix，设备是这个 Group 的 Workload 记的那台）：归档或停掉的 Cloud VM 只有 Salix 唤醒才回来。给它而连不上时，Salix 请求唤醒这台 VM（`SalixWeb.CloudVM.RuntimeLifecycle.wake/1`），然后等它的 `task.hello`。每次给只请求一次。唤醒不了（比如计费不允许、需要人工恢复）就记一条日志，Message 留着，下次给时再请求。VM 什么时候空闲只由 Station 自己说：有待处理的 Station 拒绝归档前的询问。
- **对方连上了但没回答**（超时、中途断了、回了错误）：只针对这个 Task 和这个 Station 退避再给（`PUT_AGAIN_MAX_MS`），给到为止。期间有新 Message 或 `task.hello` 就马上给。
- **参与的 Station 收到 `task.put`**：写进它那条 thread，交给它的 Session，然后回答。按 seq 去重，同一批给两次也只写一条、只交一次。seq 不超过 `answered` 的不交（见下面“答过的不再答”）。
- **交给了 Session 但这一轮没起来**（runtime 启动失败）：Message 留在这个 Session 的待处理里，thread 里说一次原因，然后这个 Session 退避再试，起来为止（`src/sessions/actor.ts` 的 `startAgain`）。期间来了新 Message 就马上试。还有待处理时 Station 不算空闲，Cloud VM 不会带着没交到的 Message 归档。
- **`task.post` 当场回答**：写进 Task 才回 `seq`。带文件的 post，Salix 先用 `task.posted_file` 一段一段把文件读过去（一次 post 最多 20 个、合计 1 GiB），存成 Task 的 Worker 的文件，再写进 Task；读不到就不写，post 失败。Station 等这种 post 的回答最多 30 分钟。没写进去，Session 的 `chat_post` 当场报错，由 Session 决定要不要再发。同一个 `key` 只写一条，所以没收到回答时可以用同一个 key 再发一次。
- **`task.invite` 当场回答**：对方连不上，或者跑不了（比如没有这个模型），邀请直接失败，发起方当场知道。Task 里什么都不写。
- **Station 连上后**：给它参与的每个 host 发一次 `task.hello`（station transport 是拿到当前名册时，Salix 是 connector 连上时）。
- **host 收到 `task.hello`**：对这个 Station 参与的每个 Task，按 `tasks` 里的 `fetched` 给。`fetched` 比 `sent` 小（Station 从备份恢复，丢了后面的），就把 `sent` 退到 `fetched`，再给一遍。按 seq 去重，已有的不会写两次。`tasks` 里没有的 Task 当作 `fetched` 是 0：Station 没有它的 thread，`task.put` 会回 `unknown`。没有 `tasks` 字段（之前版本的 Station）就从 `sent` 往后给。
- **`task.put` 回 `unknown`**（Station 丢了这个 Task）：host 用当初邀请时的 `start`（`task_sessions.start`，Salix 是 `station_task_sessions.start`）再发一次 `task.invite`，新的 Session 替换这个 Station 原来的 Session，`sent` 归 0，从头给整个 Task。参与者不删。没存 `start` 的：station 上用 chat 的创建人和标题。Salix 上存 `start` 之前邀请的，迁移 `20261019220001` 按迁移时 Task 的 Worker 和它的 Station 绑定补存了 `start`（Worker 已不在就不带 `runtime`、`model`），之后绑定再改也不影响；仍没存的用 Task 的 Worker 作 `requester`，不带 `runtime`、`model`。邀请连不上就等 `task.hello`，邀请出错就跟 put 出错一样退避再试。
- **答过的不再答：host 每次给 Message 都说“答到哪了”。** host 给一个 Station 东西时（每个 `task.put`，以及重新邀请的 `task.invite`），都带 `answered`：这个 Station 的 Session 在这个 Task 里已经答到哪个 seq。Station 记下它被告知过的最大值（`tasks_elsewhere.answered`）。seq 不超过它的 Message 只写进 thread 当作历史，不交给 Session，不起新的一轮。之后的照常交给 Session。Station 丢了整个 Task 和 Station 从存档恢复到更早的时候，用同一条规则。
  - **`answered` 的值**：这个 Station 的 Session 发来一条结束了一轮的 Message（`declared` 是 `all_done` 或 `need_help`）时，host 把 `answered` 提到那时已经给到这个 Station 的 seq（`sent`），不超过这条 Message 自己的 seq。还没给到 Station 的 Message 不算被这一轮答过，之后照常交给 Session。没有答过就是 0，不带这个字段。只发了进度（不带 `declared`）不算答完。
  - **host 怎么记**：跟 `sent` 记在一起（station 是 `task_sessions.answered`，Salix 是 `station_task_sessions.answered`），收到 `task.post` 时更新。重新邀请时换了 Session，值留着。列是空的就在第一次用到时从 Task 的 Message 里补上。
  - **Station 上已经在等的**：Station 恢复到更早的时候，可能还留着一条“已交给 Session、还没听”的 Message，而 host 说它已经答过了。Station 被告知更大的 `answered` 时，把这个 Task 里 seq 不超过它、还没听的都记成已听，不再起一轮。恢复时正跑到一半的那一轮，Station 一启动就会接着跑，这种情况可能再答一次。
  - host 给 Message 时，凡是这个 Station 的 Session 发的，都带 `author.session`，被替换掉的旧 Session 发的也带。Station 收到的 `author.session` 不是它现在的 Session，就记成现在这个 Session 自己的 Message，`declared` 照旧。这只管 thread 里怎么显示，不决定交不交。
  - 任一方是不认识 `task.put` 里 `answered` 的旧版本时，Station 从存档恢复后可能重答。
- host 只接受参与的 Session 的 `task.post`。参与的 Station 对它的 Session 都已结束的 Task 回 `gone`，host 就删掉这个参与者，不再给它。
- 人的已读按人记，记在 Task 所在的 Station 上（station 是 `reads` 表，按 viewer 和 chat）。跟 `sent` 无关。

## 在 station 上的样子

- **host**：Task 就是 station 自己的 chat（`EMBER/…`）。别的 Station 的 Session 发的 Message，作者记成 `<station>/<session>`，交给 chat 里本地的 Session。chat 里有新 Message 时，host 用 `task.put` 给每个参与的 Station。
- **参与的 Station**：收到 `task.invite` 时，起一个 Session，给 Task 开一个自己的 thread（`TASK/<ts>`，surface `task`，connect `task`）。`task.put` 给的 Message 记在这个 thread 里，ts 是 host 上的 seq，所以自己发的 Message 再给回来不会重复。agent 用 `chat_post` 回复，经 `task.post` 写到 host。
- **Message 带的文件**：参与的 Station 收到带 `files` 的 Message，先记下（`task_arrivals`）就回答 put，再用 `task.file` 从 host 一段一段取到自己 Session 的 uploads，取齐了才把 Message 写进 thread、交给 Session；它后面的 Message 等它，所以顺序不乱。取到一半断了（host 连不上、Station 重启），连上后从已有的长度接着取。host 回 `missing` 或文件超过 1 GiB 的，在 Message 的文字后面说一句没拿到哪个文件、为什么，照常交给 Session。host 是 Salix 时，支持 Agent 发的、绑定了 blob 的文件（`file`、`image`），也支持用户从 Comma 上传的图片和文件。Conversation owner 在接受用户的 Task Message 前，从本 Group 的 Router VFS 绑定上传文件，保存在 Message 的 `owner_uploads` 中。每条 Message 最多绑定 64 个不同的上传文件，任何文件不可用则拒绝发送。重试已接受的 Message 沿用原文件。用户自行填写的 blob 引用不能授权读取文件。
- **文件长度校验**：以 Message 声明的长度为准。每次 `task.file` 回复必须保留该长度，offset 必须等于本地已有长度。每段必须非空，最多 256 KiB，且不能超过剩余字节数。Station 在解码前限制 base64 长度，在写入前检查这些条件。

  不合格的回复保留已验证的部分，按现有退避重试，Message 和后续 Message 继续等待。临时文件超过声明长度时从头下载，完成文件长度不符时重新下载。临时文件改名和文件交给 Session 前都检查完整长度。已写入 thread 的 Message 不重新取文件，以保留 runtime 后续的修改。
- Salix 上的 Task（包括 Coding Task）支持 `chat_post files`，也会自动附加 Markdown 链接或图片引用的本地文件。Station 先复制文件，再通过 `task.post` 和 `task.posted_file` 交给 Salix；host 是别的 Station 时，先用 `task.post_file` 一段一段给它，再 `task.post`，host 把文件放进 chat 自己 session 的 uploads。消息中的路径改为附件文件名。路径不存在、文件超限或不同文件重名时，拒绝发送，不结束当前轮。所有 Task 都不支持卡片。
- Message 可以带 agent 记下的 milestone（`chat_post` 的 `milestones`：每条一行，最多 80 个字符，一条 Message 最多 20 个），只在 Task 的 Activity 里显示。只有 milestone 的 Message `text` 为空：照常给、照常写，但不交给任何 Session，不算未读，也不发通知。station 把它存成 `milestone` 条目（`entries.milestones`），Salix 存成 Worker Message 的 `milestone` 块。
