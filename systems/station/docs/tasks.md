# Task 跨 Station

代码：`src/tasks/tasks.ts`。

## 名词

- **Station**：跑 Session 的地方。Salix 是云上的 Station，设备上的 station 是设备 Station。
- **Task**：一段对话，放在一个 Station 上（它的 host）。Message 只存在 host 上。
- **Message**：Task 里按 seq 排的一条记录，作者是人或某个 Session。
- **Session**：在一个 Station 上参与 Task 的运行过程。属于那个 Station，别的 Station 不记它。
- **Session Event**：Session 的执行历史，只存在 Session 所在的 Station 上。

## Station 之间的请求

走 station transport（`src/jobs/remote.ts` 的 `handle`）。跟 `session.message` 一样，只要求对方是同一个 workspace 的 Station，不需要 `remoteJobs.allow`。host 是 Salix 时走 connector 的连接，请求一样。

| 请求 | 谁发给谁 | 内容 | 回答 |
| --- | --- | --- | --- |
| `task.invite` | host → Station | `task`、`start`（`requester`、`runtime`、`model`、`effort`、`title`）。重新邀请时还有 `answered`（同 `task.put`） | `session`、`thread`。跑不了就回错误，说明原因 |
| `task.put` | host → 参与的 Station | `task`、`messages`（每条 `seq`、`author`、`text`、`declared`、`at`，对方的 Session 发的带 `author.session`）、`through`、`answered` | `through`。没有这个 Task 的 thread 就回 `unknown`（同时带 `gone`，给之前版本的 host）。有 thread 但 Session 都结束了就回 `gone` |
| `task.post` | 参与的 Station → host | `task`、`session`、`text`、`key`、`declared` | `seq` |
| `task.hello` | 参与的 Station → host | `tasks`：它有的这个 host 的每个 Task，`[{task, fetched}]`（`fetched`：给到哪了，`tasks_elsewhere.fetched`） | 空 |
| `task.status` | host → 参与的 Station | `task`、`session`（可省，省了就看参与这个 Task 的 Session） | `state`（`running`：一轮在跑，含启动中；`waiting`：agent 说了在等它起的活；`idle`：没在跑、没待处理；`cannot_start`：有待处理但 runtime 起不来，正在退避；`gone`：没有这个 Task 的 thread，或这个 Session 不参与）、`pending`（待处理的 Message 数）、`for_ms`（在这个状态里待了多久，毫秒；是时长不是时间戳，两边时钟不用对齐；不知道就是 null）、`last_failure`（`cannot_start` 时最后一次起不来的原因，最多 200 字）。`idle` 且 `pending` > 0 是 Station 拿着 Message 还没交给 Session（turn 被 hold，或 Station 启动后还没拿起这个 Session）。只读：不起任何一轮，不改任何状态。不认识这个请求的旧 Station 回错误 |

- `task` 是 Task 在 host 上的地址（station 上是 `EMBER/<ts>`）。`session` 是参与的 Station 上 Session 的 key。
- Salix 的 Router 还能读写 station 自己托管的 Task（页面上的对话，Task 索引里的那些），只走这台 station 自己到 Salix 的 connector 连接，别的 Station 不能发：`task.read`（`task`、`after`、`limit` ≤ 100）回 `messages`（每条 `seq`、`author_kind`、`author`、`text`、`at`、`declared`）、`title` 和 `through`；`task.say`（`task`、`text`、`key`、`requester`）以 `salix/<requester>` 的身份写进去并交给这个对话的 Session，同一个 `key` 只写一次，回 `seq`。Router 用 `station:<station_id>:<thread>` 指这样的 Task（`SalixWeb.StationHostedTasks`），station 不在线时读写都失败。
- host 是 Salix 时，Worker 可以绑定一个 Station（Agent 记录的 `station_binding`）：这个 Worker 的每个 Task 都邀请那个 Station，`start` 的 `runtime`、`model`、`effort` 来自绑定，没有 `model` 就用那个 Station 的默认模型。Station 不知道有绑定，请求和上面一样。Router 给一个 Task 的 `model` 也可以只写 runtime（`{kind: runtime, provider}`，不带 model id），`start` 同样不带 `model`；Group 的 Cloud VM 收到不带 `model` 的 Codex Task 时，Salix 给它平台模型。
- host 是 Salix 时，Group 还可以有一个默认运行位置（Group 记录的 `default_task_place`：Salix、Group 的 Cloud VM，或一个 Station）。Router 建 Task 时不给 `runs_on`、Worker 没有绑定、`model` 没给或是 runtime 的，Task 就在默认位置运行，跟 Router 自己给了这个 `runs_on` 一样邀请那个 Station；那个位置不能接（Station 不在线、Cloud VM 没开），建 Task 就失败。Station 不知道有默认位置。

## 送达规则

- **Message 进了 Task 就一定送到。** host 给每个参与的 Session 记交到了哪（`task_sessions.sent`）。`sent` 之后的 Message 还没给它，用 `task.put` 给，对方回答了才往前移。
- **什么时候给**：Task 有新 Message、host 启动、host 连上 still.fail cloud（拿到当前名册），以及参与的 Station 发来 `task.hello`。没有定时轮询，不设期限，不丢。
- **对方连不上**（不在名册里、连接建不起来、Salix 的连接断了）：不再试，等它连上后发 `task.hello`。
- **对方是 Group 的 Cloud VM**（host 是 Salix，设备是这个 Group 的 Workload 记的那台）：归档或停掉的 Cloud VM 只有 Salix 唤醒才回来。给它而连不上时，Salix 请求唤醒这台 VM（`SalixWeb.CloudVM.RuntimeLifecycle.wake/1`），然后等它的 `task.hello`。每次给只请求一次。唤醒不了（比如计费不允许、需要人工恢复）就记一条日志，Message 留着，下次给时再请求。VM 什么时候空闲只由 Station 自己说：有待处理的 Station 拒绝归档前的询问。
- **对方连上了但没回答**（超时、中途断了、回了错误）：只针对这个 Task 和这个 Station 退避再给（`PUT_AGAIN_MAX_MS`），给到为止。期间有新 Message 或 `task.hello` 就马上给。
- **参与的 Station 收到 `task.put`**：写进它那条 thread，交给它的 Session，然后回答。按 seq 去重，同一批给两次也只写一条、只交一次。seq 不超过 `answered` 的不交（见下面“答过的不再答”）。
- **交给了 Session 但这一轮没起来**（runtime 启动失败）：Message 留在这个 Session 的待处理里，thread 里说一次原因，然后这个 Session 退避再试，起来为止（`src/sessions/actor.ts` 的 `startAgain`）。期间来了新 Message 就马上试。还有待处理时 Station 不算空闲，Cloud VM 不会带着没交到的 Message 归档。
- **`task.post` 当场回答**：写进 Task 才回 `seq`。没写进去，Session 的 `chat_post` 当场报错，由 Session 决定要不要再发。同一个 `key` 只写一条，所以没收到回答时可以用同一个 key 再发一次。
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
- 目前 `task.post` 不带文件和卡片。
