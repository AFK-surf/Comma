defmodule AlertRouter.Catalog do
  @moduledoc """
  Reviewed copy, routing fields, evidence defaults, and link policy keyed by
  the source policy identities that are already owned in this repository.

  Provider payloads supply lifecycle facts and observed values. The catalog
  projects those observations into the reviewed threshold's display unit; the
  provider cannot author Slack copy, service/family ownership, thresholds,
  runbooks, or route destinations.
  """

  @github_runbook "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
  @grafana_runbook "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
  @im_runbook "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
  @salix_agent_runtime_runbook "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
  @deployment_failure_runbook "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
  @station_task_runbook "https://github.com/AFK-surf/Comma/blob/main/docs/salix/tasks-background-execution.md"
  @cloud_vm_runbook "https://github.com/AFK-surf/Comma/blob/main/.codex/skills/cf-vm-ops/SKILL.md"
  @sandbox_runbook "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"

  @catalog %{
    ["gcp_monitoring", "comma_alerting", "gke_oom_kill"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "gke",
      family: "capacity",
      summary: "GKE 集群发生 OOM kill",
      impact: "集群中至少一个进程被内核因内存不足终止；受影响的工作负载仍需定位。",
      firing_latest: "kernel-monitor 已报告 OOMKilling；Pod 自动重启或 Ready 不抵消该事件。",
      evidence_values: %{"threshold" => ">= 1 个 OOM 事件", "duration" => "单次事件"},
      first_checks: [
        "在 Logs 里找 kernel-monitor 的 OOMKilling 事件，确认被杀的进程和 Pod",
        "对照这个 Pod 的内存上限和最近一次发布，判断是内存泄漏还是上限太低"
      ],
      runbook: "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
    },
    ["gcp_monitoring", "comma_alerting", "telegram_delivery_failure"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "telegram",
      family: "availability",
      summary: "Telegram 同阶段重复失败",
      impact: "部分已鉴权入站消息或用户可见回复可能未完成。",
      firing_latest: "同一 Telegram 阶段的近期可归因失败达到已审核阈值。",
      evidence_values: %{
        "threshold" => ">= 3 次失败 / 10 分钟 / 同阶段",
        "duration" => "5 分钟"
      },
      first_checks: [
        "在 Metrics Explorer 按 operation、outcome 看 Telegram 的失败，确认是入站 webhook、生命周期消息还是 Agent 发送",
        "按失败的阶段查同一时间的 Comma 日志"
      ],
      runbook: "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
    },
    ["posthog", "comma_client_critical_issue"] => %{
      source: "posthog",
      source_accounts: :configured_posthog,
      environments: ~w(staging production),
      priority: "P2",
      team: "comma",
      service: "comma_client",
      family: "availability",
      summary: "Comma 客户端发生致命渲染错误",
      impact: "至少一个客户端界面无法继续渲染；影响范围需在 PostHog 中确认。",
      firing_latest: "PostHog 报告严重渲染错误 issue 新建或重新出现。",
      evidence_values: %{"threshold" => ">= 1 个严重错误 issue", "duration" => "单次 issue occurrence"},
      first_checks: [
        "打开 PostHog Error Tracking 里的这个 issue，看影响的用户数和客户端版本",
        "对照最近的客户端发布，决定是否回滚"
      ],
      runbook: "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
    },
    ["posthog", "comma_client_login_unavailable"] => %{
      source: "posthog",
      source_accounts: :configured_posthog,
      environments: ~w(staging production),
      priority: "P1",
      team: "comma",
      service: "comma_client",
      family: "availability",
      summary: "Comma Google 登录失败",
      impact: "至少一次 Google 登录因基础设施或协议错误失败；影响范围需在 PostHog 中确认。",
      firing_latest: "PostHog 报告登录不可用 issue 新建或重新出现。",
      evidence_values: %{"threshold" => ">= 1 个登录不可用 issue", "duration" => "单次 issue occurrence"},
      first_checks: [
        "打开 PostHog 里的这个 issue，看错误类和次数",
        "自己用 Google 登录一次，确认还能不能复现"
      ],
      runbook: "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
    },
    ["github_actions", "AFK-surf/Comma", "staging_deployment_failure"] => %{
      source: "github_actions",
      source_accounts: ["AFK-surf/Comma"],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "comma_release",
      family: "deployment",
      summary: "Comma staging 部署失败",
      impact: "本次 staging 发布没有正常完成；旧版本可能仍在服务。",
      firing_latest: "GitHub 已报告 Comma Deployment 以失败或取消结束。",
      evidence_values: %{
        "threshold" => ">= 1 次失败终态",
        "duration" => "单次 workflow run"
      },
      first_checks: [
        "打开失败的 Comma Deployment run，看是哪一步失败",
        "确认 staging 现在跑的是哪个版本，修好后重新发布"
      ],
      runbook: @deployment_failure_runbook
    },
    ["gcp_monitoring", "comma_alerting", "task_worker_dependency_failed"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P1",
      team: "comma",
      service: "salix_agent",
      family: "availability",
      summary: "Task Worker 依赖失败",
      impact: "Task Worker 缺少插件投影，任务可能无法继续执行。",
      firing_latest: "同一 Task activation 已连续三次遇到 plugin_projection:not_found，恢复情况尚未确认。",
      evidence_values: %{
        "cluster" => :gke_cluster,
        "threshold" => "同一 Task activation 依赖失败 3 次",
        "duration" => "达到事件门槛"
      },
      first_checks: [
        "在 Logs 里按 plugin_projection:not_found 找到这次 Task activation 和它缺的插件",
        "确认这个插件的投影有没有生成，Task 是否已经失败结束"
      ],
      runbook: @salix_agent_runtime_runbook
    },
    ["gcp_monitoring", "comma_alerting", "station_task_stalled"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P2",
      team: "comma",
      service: "salix_im",
      family: "availability",
      summary: "Cloud VM 或沙箱 Task 委派无人应答",
      impact:
        "派到 Group Cloud VM 或 Task 自己沙箱上的 Task 收到了新委派，但那台机器上的 station 没有回帖；Router 只能等超时，用户看到任务没有进展。",
      firing_latest: "派到 Cloud VM 或沙箱的委派到了阈值仍没有 Worker 回帖。",
      evidence_values: %{
        "cluster" => :gke_cluster,
        "threshold" =>
          "VM 或沙箱未就绪 / 离线 / 未交付 >= 10 分钟；闲着没回帖催促后再 10 分钟；起不来 10 分钟；station 退出 Task 立即",
        "duration" => "达到事件门槛"
      },
      first_checks: [
        "在 Logs 里按 station_task_stalled 找到 Task、Group、place 和 stage",
        "vm_not_ready、station_offline 先看这个 Group 的 Cloud VM 或这个 Task 的沙箱 Workload；idle_no_reply、cannot_start、station_left 看 station 里的 Session"
      ],
      runbook: @station_task_runbook
    },
    ["gcp_monitoring", "comma_alerting", "cloud_vm_container_lost"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "cloud_vm",
      family: "availability",
      summary: "Cloud VM Container 自行停止，磁盘丢失",
      impact:
        "一个 Group 的 Cloud VM Container 不是 Salix 停的，磁盘随之丢失；记录已归档回上一份快照，快照之后写的文件没有了，当时的 Task 会中断。",
      firing_latest: "Salix 记录到一次 Container 自行停止。",
      evidence_values: %{
        "cluster" => :gke_cluster,
        "threshold" => "一次 cloud_vm_container_lost 事件；一小时内只呼叫一次",
        "duration" => "达到事件门槛"
      },
      first_checks: [
        "在 Logs 里找 cloud_vm_container_lost 事件，看 reason 和 restored",
        "reason 是 rollout 时为 Cloudflare 运行时升级，其他原因查这个 Group 的 Container 日志"
      ],
      runbook: @cloud_vm_runbook
    },
    ["gcp_monitoring", "comma_alerting", "cloud_vm_wake_slow"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "cloud_vm",
      family: "availability",
      summary: "Cloud VM 唤醒过慢或反复失败",
      impact: "Cloud VM 唤醒远超正常的 10 秒，或同一种失败半小时内反复出现；派到 Cloud VM 的 Task 要等很久才开始，或根本开始不了。",
      firing_latest: "Cloud VM 唤醒的 p95 超过 120 秒，或同一种唤醒失败反复出现。",
      evidence_values: %{
        "threshold" => "ok 唤醒 p95 > 120s（1h），或单一失败 outcome ≥ 3 次（30m）",
        "duration" => "无额外持续时间"
      },
      first_checks: [
        "在 Metrics Explorer 按 outcome、provider 看 salix_vm_wake_duration_seconds",
        "看 cloud_vm_container_lost 是否同时在响"
      ],
      runbook: @cloud_vm_runbook
    },
    ["gcp_monitoring", "comma_alerting", "cloud_vm_stuck_state"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "cloud_vm",
      family: "availability",
      summary: "Cloud VM 记录卡在过渡状态超过一小时",
      impact:
        "一个 Group 的 Cloud VM 记录在 creating、waking 或 archiving 里停了一小时以上；这个 Group 的 Cloud VM 不能用，reconciler 反复重试却没人知道。",
      firing_latest: "至少一个 Cloud VM 记录在过渡状态停了一小时以上。",
      evidence_values: %{
        "threshold" => "最老的记录停留 > 1 小时",
        "duration" => "持续 10 分钟"
      },
      first_checks: [
        "用 SalixStore.Compute.group_workload_fleet/0 找到卡住的 Group 记录",
        "看 reconciler 对这条记录的 warning，再按 cf-vm-ops 处置手册处理"
      ],
      runbook: @cloud_vm_runbook
    },
    ["gcp_monitoring", "comma_alerting", "sandbox_start_failed"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "sandbox",
      family: "availability",
      summary: "沙箱启动反复失败",
      impact:
        "沙箱 Task 的沙箱半小时内至少 3 次没起来，Task 开始不了。同一个 Task 短时间失败几十上百次，就是有东西在反复唤醒它（2026-10-29 staging 的唤醒循环 40 小时失败 802 次）。",
      firing_latest: "30 分钟内失败的沙箱启动达到 3 次。",
      evidence_values: %{
        "threshold" => "失败的启动 >= 3 次（30m，各 pod 合计）",
        "duration" => "无额外持续时间"
      },
      first_checks: [
        "在 Metrics Explorer 按 kind 看 salix_sandbox_start_duration_seconds_count{outcome=\"failed\"}，分清是第一台沙箱（create）还是唤醒（wake）",
        "读 kind=coding_sandbox、state=failed 的 Workload 的 reason 和 generation：generation 短时间涨得很快，就是同一个 Task 在反复唤醒，查是哪条消息在唤醒它"
      ],
      runbook: @sandbox_runbook
    },
    ["gcp_monitoring", "comma_alerting", "sandbox_lost"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "sandbox",
      family: "availability",
      summary: "沙箱在 Comma 之外被结束",
      impact: "L4ES 结束了一台正在运行的沙箱，不是 Comma 停的；正在跑的一轮被打断。L4ES 没保住数据盘时，沙箱从空盘再起，未提交、未推送的改动就没了。",
      firing_latest: "最近一小时有沙箱被记为 lost。",
      evidence_values: %{
        "threshold" => "lost >= 1 次（1h）",
        "duration" => "无额外持续时间；一次丢失让告警开着约 1 小时"
      },
      first_checks: [
        "读 kind=coding_sandbox、state=lost 的 Workload，看 reason 和是哪个 Task（conversation_id）",
        "在 L4ES 侧查这台沙箱为什么结束；一小时内多台 lost，先查 L4ES 节点"
      ],
      runbook: @sandbox_runbook
    },
    ["gcp_monitoring", "comma_alerting", "sandbox_start_slow"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P3",
      team: "comma",
      service: "sandbox",
      family: "availability",
      summary: "沙箱唤醒变慢",
      impact: "停着的沙箱从磁盘再起到 station 连上要两分钟以上；用户给 Task 发消息后，要等很久 Worker 才开始干活。",
      firing_latest: "最近一小时成功唤醒的 p90 超过 120 秒。",
      evidence_values: %{
        "threshold" => "成功唤醒 p90 > 120s（1h）",
        "duration" => "无额外持续时间"
      },
      first_checks: [
        "在 Metrics Explorer 看 salix_sandbox_start_duration_seconds_bucket{kind=\"wake\"} 的分布和次数：是普遍变慢，还是一两次",
        "对照 kind=\"create\" 是否一样慢，再核对 L4ES 与沙箱镜像的最近发布"
      ],
      runbook: @sandbox_runbook
    },
    ["gcp_monitoring", "comma_alerting", "sandbox_checks_stalled"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "sandbox",
      family: "availability",
      summary: "沙箱检查停了，或没处理超时的启动",
      impact: "沙箱检查停了，或有沙箱在 starting 停了 15 分钟以上没人处理：新 Task 的沙箱建不起来，停着的沙箱唤不醒，用户也收不到说明。",
      firing_latest: "最老的 starting 沙箱，或没有时最近一次发布，已超过 300 秒，并持续 10 分钟。",
      evidence_values: %{
        "threshold" => "time() - 最老 starting 的开始时间（没有时为发布时间）> 300 秒",
        "duration" => "持续 10 分钟"
      },
      first_checks: [
        "在 Logs 里找 “coding sandboxes not checked” 和 “sandbox fleet metrics skipped”",
        "读 compute_workloads 里 state=starting 的行：有超过 5 分钟的，是检查没处理它；没有，是没有节点在发布，看各节点的 SalixWeb.CodingSandboxes 进程是否卡住"
      ],
      runbook: @sandbox_runbook
    },
    ["gcp_monitoring", "comma_alerting", "router_request_stalled"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P1",
      team: "comma",
      service: "salix_agent",
      family: "availability",
      summary: "Router 的用户请求开始不了",
      impact: "已接收的用户请求排在一个卡住的 Router 后面等待。",
      firing_latest: "至少一个 Router 的待处理输入超过 5 分钟，且 5 分钟内没有新请求开始。",
      evidence_values: %{
        "threshold" => "待处理 > 0，最老 > 300 秒，>= 300 秒无新请求开始",
        "duration" => "无额外持续时间"
      },
      first_checks: [
        "在 Logs 里找卡住的 Router 和它最老的待处理输入",
        "看这个 Router 的 Session 是否卡在一个不结束的回合里"
      ],
      runbook: "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
    },
    ["gcp_monitoring", "comma_alerting", "im_ingress_5xx"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P2",
      team: "comma",
      service: "im_ingress",
      family: "availability",
      summary: "IM 入口失败率",
      impact: "部分归因后的 IM 入站事件可能未被处理。",
      firing_latest: "已归因的 IM 入站事件失败占比超过阈值。",
      evidence_values: %{
        "threshold" => "> 5%",
        "duration" => "15 分钟",
        "sample_count" => ">= 20 个样本"
      },
      first_checks: [
        "在 Metrics Explorer 按 outcome 看 im_ingress 的 salix_operations_total，确认失败是哪一类",
        "在 BFT Operations → Events 按 `source=salix.im`、`status=failed` 看 reason_class",
        "修好后检查 Slack 是否自动停用了事件订阅"
      ],
      runbook: @im_runbook
    },
    ["gcp_monitoring", "comma_alerting", "platform_model_account_failed"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P0",
      team: "comma",
      service: "platform_model",
      family: "availability",
      summary: "平台模型账户被拒（欠费或 key 失效）",
      impact: "平台出钱的模型账户拒绝调用：用这个模型的成员每条消息都立刻停下，只有运维能修。",
      firing_latest: "近 10 分钟内有平台出钱的模型调用被供应商以欠费或 key 被拒拒绝。",
      evidence_values: %{
        "threshold" => ">= 1 次被拒",
        "duration" => "10 分钟",
        "sample_count" => "按 provider、reason 分别计数，不含成员自己的 key 和订阅"
      },
      first_checks: [
        "在 Metrics Explorer 按 provider、reason 看 salix_llm_platform_account_failures_total",
        "quota_exhausted：到该供应商控制台充值（Anthropic 为 Claude Console → Billing），考虑打开 auto-reload",
        "credentials_rejected：确认平台 Profile 的 key 未被吊销或轮换，必要时换新 key"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_alerting", "platform_model_account_low_balance"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P2",
      team: "comma",
      service: "platform_model",
      family: "availability",
      summary: "平台模型账户余额不足",
      impact: "平台 DeepSeek 账户余额低于阈值，很快会用完；用完后用平台模型的成员都会停下。",
      firing_latest: "平台 DeepSeek key 中最低的余额持续 10 分钟低于阈值。",
      evidence_values: %{
        "threshold" => "< 1,000 元，或 < 140 美元",
        "duration" => "10 分钟",
        "sample_count" => "每 5 分钟读一次余额，取各 key 中最低的"
      },
      first_checks: [
        "在 Metrics Explorer 按 kind（币种）看 salix_llm_platform_account_balance",
        "到 DeepSeek 开放平台给平台账户充值",
        "充值后 5 分钟内余额 gauge 回到阈值以上"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_alerting", "recording_asr_failed"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P2",
      team: "comma",
      service: "recording_asr",
      family: "availability",
      summary: "录音转写反复失败",
      impact: "会议纪要或 Drive 录音没有文字稿；音频本身仍在。",
      firing_latest: "同一入口近 1 小时内录音转写失败次数达到阈值。",
      evidence_values: %{
        "threshold" => ">= 3 次失败",
        "duration" => "1 小时",
        "sample_count" => "按 operation 分别计数，不含无人声和听写"
      },
      first_checks: [
        "在 Metrics Explorer 按 operation、reason 看 salix_asr_failures_total，确认是哪一类失败",
        "在 Logs 里搜 `audio.transcribe failed`、`recording transcription failed`、`ASR chunk failed`，看第几片、什么原因",
        "content_filter 查模型安全设置；rate_limited、provider_5xx、transport 查转写模型网关和配额"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_alerting", "comma_api_5xx"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P1",
      team: "comma",
      service: "comma_api",
      family: "availability",
      summary: "Comma API 大多数请求返回 5xx",
      impact: "至少一族 /v1/comma 接口的大多数请求失败，客户端的会话、搜索或发消息可能不可用。",
      firing_latest: "某个 /v1/comma route 的 5xx 占比持续高于已审核阈值。",
      evidence_values: %{
        "threshold" => "> 50%",
        "duration" => "5 分钟",
        "sample_count" => ">= 20 个请求 / 5 分钟"
      },
      first_checks: [
        "在 Metrics Explorer 按 route、status_class 看 comma_system_http_requests_total，确认是哪一族接口在失败",
        "在 Logs 里查 comma workload 同一时间的错误",
        "对照最近一次 Comma Deployment run 和数据迁移"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_alerting", "bft_login_uptime"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P1",
      team: "comma",
      service: "bft",
      family: "availability",
      summary: "BFT 登录页无法访问",
      impact: "用户可能无法打开 BFT 登录页。",
      firing_latest: "至少两个公网探测区域无法访问已审核的 BFT 登录端点。",
      evidence_values: %{"threshold" => ">= 3 个区域中的 2 个", "duration" => "60 秒"},
      first_checks: [
        "直接打开 BFT 登录页，确认是否还打不开",
        "看 Gateway、workload 和最近一次 Comma Deployment run"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_alerting", "salix_public_uptime"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P1",
      team: "comma",
      service: "salix",
      family: "availability",
      summary: "Salix 公网健康检查失败",
      impact: "依赖 Salix 公网端点的用户路径可能不可用。",
      firing_latest: "至少两个公网探测区域无法访问已审核的 Salix 健康检查端点。",
      evidence_values: %{"threshold" => ">= 3 个区域中的 2 个", "duration" => "60 秒"},
      first_checks: [
        "直接打开 Salix /health，确认是否还失败",
        "看 Gateway、workload 和最近一次 Comma Deployment run"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_alerting", "l4es_ready_uptime"] => %{
      source: "gcp_monitoring",
      source_accounts: [:production],
      environments: ~w(production),
      priority: "P1",
      team: "comma",
      service: "l4es_ready",
      family: "availability",
      summary: "L4ES 控制面不就绪",
      impact: "新沙箱建不起来，停着的沙箱唤不醒，SSH 和 web 会话连不上；已在跑的沙箱继续跑。",
      firing_latest: "至少两个公网探测区域访问 L4ES /readyz 失败。",
      evidence_values: %{"threshold" => ">= 3 个区域中的 2 个", "duration" => "60 秒"},
      first_checks: [
        "直接打开 L4ES /readyz，确认是否还失败",
        "登录控制面 VM（ssh -p 2222 debian@152.236.4.63），看控制面服务和 serving slot"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_alerting", "l4es_cluster_uptime"] => %{
      source: "gcp_monitoring",
      source_accounts: [:production],
      environments: ~w(production),
      priority: "P2",
      team: "comma",
      service: "l4es_cluster",
      family: "availability",
      summary: "L4ES 集群健康检查未通过",
      impact: "L4ES 集群有一项健康检查没过：可能是节点不在线、空闲槽位不够、沙箱排队，或数据库没有异地备份。",
      firing_latest: "至少两个公网探测区域访问 L4ES /cluster-ok 失败。",
      evidence_values: %{"threshold" => ">= 3 个区域中的 2 个", "duration" => "60 秒"},
      first_checks: [
        "登录控制面 VM，sudo cat /var/lib/l4es/health/status.txt 看哪一项没过",
        "看 journalctl -u l4es-health -n 20 和 sbx node ls"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_rfc11", "workload_unavailable"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P1",
      team: "comma",
      service: "comma_runtime",
      family: "availability",
      summary: "Comma 工作负载不可用",
      impact: "Comma 核心用户路径可能不可用。",
      firing_latest: "最新的期望副本数或就绪副本数低于 1。",
      evidence_values: %{"threshold" => "< 1 个副本", "duration" => "90 秒"},
      first_checks: [
        "用 kubectl get statefulset -n comma 看哪个 workload 没有就绪副本",
        "看最近的 Comma Deployment run 有没有失败、取消或停在 quiesce"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_rfc11", "workload_degraded"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "comma_runtime",
      family: "capacity",
      summary: "Comma 工作负载降级",
      impact: "可用容量下降，延迟可能升高。",
      firing_latest: "仍有部分 Comma 期望副本不可用，但至少有一个副本已就绪。",
      evidence_values: %{"threshold" => "0 < 就绪副本 < 期望副本", "duration" => "5 分钟"},
      first_checks: [
        "用 kubectl get pods -n comma 看哪个 Pod 没就绪以及原因",
        "确认是不是正在发布或节点在扩缩容"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_rfc11", "workload_signal_missing"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "comma_runtime",
      family: "observability",
      summary: "Comma 工作负载信号缺失",
      impact: "当前无法判断工作负载健康状态；仅凭此信号不能确认服务中断。",
      firing_latest: "新鲜度窗口内缺少期望副本数或就绪副本数。",
      evidence_values: %{"threshold" => "缺少新鲜数据", "duration" => "4 分钟"},
      first_checks: [
        "这条只说明看不到副本数据：先确认服务本身是否正常",
        "确认 kube-state-metrics 和 Collector 在跑"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_rfc11", "pipeline_collector_unavailable"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "otel_collector",
      family: "data_pipeline",
      summary: "遥测采集器不可用",
      impact: "链路追踪数据可能不完整。",
      firing_latest: "健康的采集器目标数低于已审核的最低值。",
      evidence_values: %{"threshold" => "< 2 个目标", "duration" => "2 分钟"},
      first_checks: [
        "看 comma-otel-collector 的 Pod 是否都在跑",
        "看 Collector 日志里的启动或抓取错误"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_rfc11", "pipeline_export_failure"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "otel_collector",
      family: "data_pipeline",
      summary: "遥测导出失败",
      impact: "链路追踪数据传输可能延迟或不完整。",
      firing_latest: "采集器在已审核窗口内报告了 span 导出失败。",
      evidence_values: %{"threshold" => "> 0 次失败", "duration" => "5 分钟窗口"},
      first_checks: [
        "看 Collector 日志里的导出错误",
        "确认 Cloud Trace 的配额和权限"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_rfc11", "pipeline_queue_full"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "otel_collector",
      family: "data_pipeline",
      summary: "遥测导出队列已满",
      impact: "新的链路追踪数据可能无法入队并丢失。",
      firing_latest: "采集器导出队列持续处于满载状态。",
      evidence_values: %{"threshold" => ">= 100%", "duration" => "60 秒"},
      first_checks: [
        "看 Collector 日志里的导出错误或变慢",
        "确认 Collector 的副本数和资源是否够"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_rfc11", "pipeline_receiver_refused"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "otel_collector",
      family: "data_pipeline",
      summary: "遥测接收器拒绝 span",
      impact: "应用链路追踪数据可能不完整。",
      firing_latest: "采集器在已审核窗口内拒绝了一个或多个 span。",
      evidence_values: %{"threshold" => "> 0 个被拒绝", "duration" => "5 分钟窗口"},
      first_checks: [
        "看 Collector 日志里拒收的原因（内存限制或格式）",
        "确认最近是否有发版让 span 量突增"
      ],
      runbook: @github_runbook
    },
    ["gcp_monitoring", "comma_rfc11", "pipeline_terminal_drop"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "otel_collector",
      family: "data_pipeline",
      summary: "遥测数据已丢弃",
      impact: "部分链路追踪数据已永久丢失。",
      firing_latest: "采集器发出了终态数据丢弃信号。",
      evidence_values: %{"threshold" => "> 0 次终态丢弃", "duration" => "单次事件"},
      first_checks: [
        "看 Collector 日志里的丢弃原因",
        "这些数据已经丢了，修好导出即可，不需要补发"
      ],
      runbook: @github_runbook
    },
    ["grafana", "comma_grafana:stg_llm_logical_error"] => %{
      source: "grafana",
      source_accounts: ["https://afksurf.grafana.net"],
      environments: ~w(staging),
      observed_format: :ratio_percent,
      priority: "P2",
      team: "comma",
      service: "llm",
      family: "availability",
      summary: "LLM 最终请求错误率",
      impact: "部分 LLM 逻辑请求在重试后仍可能失败。",
      firing_latest: "逻辑请求的最终错误率持续高于已审核阈值。",
      evidence_values: %{
        "threshold" => "> 10%",
        "duration" => "15 分钟",
        "sample_count" => ">= 10 个样本"
      },
      first_checks: [
        "在 Grafana 按 provider、model 看最终错误率",
        "确认是不是单个 provider 的故障"
      ],
      runbook: @grafana_runbook
    },
    ["grafana", "comma_grafana:stg_llm_ttft"] => %{
      source: "grafana",
      source_accounts: ["https://afksurf.grafana.net"],
      environments: ~w(staging),
      observed_format: :seconds,
      priority: "P2",
      team: "comma",
      service: "llm",
      family: "capacity",
      summary: "LLM 首 Token 延迟",
      impact: "部分 LLM 请求等待首 Token 的时间可能显著变长。",
      firing_latest: "Provider attempt 的 TTFT p95 持续高于已审核阈值。",
      evidence_values: %{
        "threshold" => "> 30 秒",
        "duration" => "15 分钟",
        "sample_count" => ">= 20 个样本"
      },
      first_checks: [
        "在 Grafana 按 provider、model 看 TTFT p95",
        "确认是不是单个 provider 变慢"
      ],
      runbook: @grafana_runbook
    },
    # Meeting reliability. These are counts of a rare event, not ratios, so
    # they keep the default :raw observed format and carry no sample-count
    # gate: one occurrence is already worth a look.
    ["grafana", "comma_grafana:stg_meeting_runtime_lost"] => %{
      source: "grafana",
      source_accounts: ["https://afksurf.grafana.net"],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "meetings",
      family: "availability",
      summary: "会议因运行时失联被判记录不完整",
      impact: "受影响会议的参会者收到「记录不完整」说明而不是总结，且之后不会再补发。",
      firing_latest: "总结 watchdog 在超过拖堂上限后仍拿不到确定的活会话答案。",
      evidence_values: %{
        "threshold" => "> 0 次 runtime_lost 终态化",
        "duration" => "15 分钟"
      },
      first_checks: [
        "在 Grafana 看受影响的会议数",
        "按会议查总结 watchdog 的日志，看运行时为何失联"
      ],
      runbook: @grafana_runbook
    },
    ["grafana", "comma_grafana:stg_meeting_stuck_nonterminal"] => %{
      source: "grafana",
      source_accounts: ["https://afksurf.grafana.net"],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "meetings",
      family: "availability",
      summary: "会议卡在非终态且没有时间锚点",
      impact: "这些会议既不会产出总结，也无法被自动终态化，需要人工兜底。",
      firing_latest: "投递巡检发现已派发入会的会议缺少全部时间戳锚点。",
      evidence_values: %{
        "threshold" => "> 0 次无锚点滞留",
        "duration" => "15 分钟"
      },
      first_checks: [
        "在 Grafana 看滞留的会议数",
        "按会议查投递巡检日志，这些会议需要人工终态化"
      ],
      runbook: @grafana_runbook
    },
    ["grafana", "comma_grafana:stg_meeting_delivery_error"] => %{
      source: "grafana",
      source_accounts: ["https://afksurf.grafana.net"],
      environments: ~w(staging),
      priority: "P2",
      team: "comma",
      service: "meetings",
      family: "availability",
      summary: "会议总结投递持续报错",
      impact: "受影响会议的总结暂时没有送达；有界重试仍在进行，尚未终态化。",
      firing_latest: "会议总结投递的 error 结局持续非零。",
      evidence_values: %{
        "threshold" => "> 0 次投递 error",
        "duration" => "15 分钟"
      },
      first_checks: [
        "在 Grafana 看投递 error 的会议数",
        "按会议查总结投递日志里的错误"
      ],
      runbook: @grafana_runbook
    }
  }

  @spec enrich(map()) :: {:ok, map()} | {:error, term()}
  def enrich(%{policy_identity: policy_identity} = attrs) do
    with {:ok, entry} <- fetch_entry(policy_identity),
         :ok <- exact(attrs.source, entry.source, :source),
         :ok <-
           one_of(attrs.source_account, source_accounts(entry.source_accounts), :source_account),
         :ok <- one_of(attrs.environment, entry.environments, :environment),
         :ok <- optional_exact(attrs[:priority], entry.priority, :priority),
         :ok <- optional_exact(attrs[:team], entry.team, :team),
         :ok <- optional_exact(attrs[:service], entry.service, :service),
         :ok <- optional_exact(attrs[:family], entry.family, :family),
         :ok <- reviewed_evidence_matches(attrs[:evidence_values], entry.evidence_values),
         {:ok, evidence_values} <-
           format_observed(
             attrs[:evidence_values],
             Map.get(entry, :observed_format, :raw),
             policy_identity
           ),
         links <- catalog_links(attrs, entry),
         :ok <- validate_links(links, entry.source, attrs.source_account) do
      latest =
        if attrs.state == "resolved", do: source_terminal_latest(), else: entry.firing_latest

      {:ok,
       Map.merge(attrs, %{
         priority: entry.priority,
         team: entry.team,
         service: entry.service,
         family: entry.family,
         summary: entry.summary,
         impact: entry.impact,
         latest: latest,
         evidence_values: Map.merge(evidence_values, entry.evidence_values),
         links: links
       })}
    else
      :error -> {:error, {:unknown_policy, policy_identity}}
      {:error, _reason} = error -> error
    end
  end

  def enrich(_attrs), do: {:error, {:missing_field, :policy_identity}}

  @doc "The reviewed first steps an on-call person takes for one policy."
  @spec first_checks(term()) :: [String.t()]
  def first_checks(policy_identity) do
    case Map.fetch(@catalog, policy_identity) do
      {:ok, entry} -> Map.get(entry, :first_checks, [])
      :error -> []
    end
  end

  defp source_accounts(:configured_posthog) do
    case AlertRouter.Adapters.PostHog.configuration() do
      {:ok, config} -> [config.account]
      _ -> []
    end
  end

  defp source_accounts(accounts) when is_list(accounts) do
    projects = SystemsRuntime.get_env(:alert_router, :gcp_projects, %{})

    Enum.flat_map(accounts, fn
      environment when is_atom(environment) ->
        case Map.get(projects, environment) do
          project when is_binary(project) and project != "" -> [project]
          _ -> []
        end

      account ->
        [account]
    end)
  end

  defp fetch_entry(policy_identity) do
    with {:ok, entry} <- Map.fetch(@catalog, policy_identity) do
      cluster = SystemsRuntime.get_env(:alert_router, :gke_cluster)

      values =
        Map.new(entry.evidence_values, fn
          {key, :gke_cluster} -> {key, cluster}
          pair -> pair
        end)

      {:ok,
       %{entry | evidence_values: values |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()}}
    end
  end

  defp catalog_links(attrs, entry) do
    defaults = %{
      "dashboard" => dashboard_url(attrs.source, attrs.source_account),
      "runbook" => entry.runbook
    }

    defaults
    |> Map.merge(attrs.links || %{})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp dashboard_url("gcp_monitoring", source_account) do
    "https://console.cloud.google.com/monitoring/alerting/incidents?project=#{source_account}"
  end

  defp dashboard_url("posthog", account), do: account <> "/error_tracking"

  defp dashboard_url("grafana", _source_account), do: nil

  defp dashboard_url("github_actions", "AFK-surf/Comma") do
    "https://github.com/AFK-surf/Comma/actions/workflows/comma-deployment.yml"
  end

  defp validate_links(links, source, source_account) do
    case Enum.find(links, fn {key, value} ->
           not reviewed_link?(key, URI.parse(value), source, source_account)
         end) do
      nil -> :ok
      {key, _value} -> {:error, {:unreviewed_link, key}}
    end
  end

  defp reviewed_link?(
         "runbook",
         %URI{
           scheme: "https",
           host: "github.com",
           port: port,
           userinfo: nil,
           path: "/AFK-surf/Comma/blob/" <> suffix,
           query: nil,
           fragment: nil
         },
         _source,
         _account
       ),
       do: port in [nil, 443] and suffix != ""

  defp reviewed_link?(key, uri, "gcp_monitoring", account)
       when key in ["incident", "dashboard"] do
    expected_path? =
      case {key, uri.path} do
        {"incident", path} when is_binary(path) -> path != ""
        {"dashboard", "/monitoring/alerting/incidents"} -> true
        _ -> false
      end

    expected_path? and uri.scheme == "https" and uri.host == "console.cloud.google.com" and
      uri.port in [nil, 443] and is_nil(uri.userinfo) and is_nil(uri.fragment) and
      decode_query(uri.query) == %{"project" => account}
  end

  defp reviewed_link?(key, uri, "grafana", source_account)
       when key in ["incident", "dashboard"] do
    expected_host = URI.parse(source_account).host

    expected_path? =
      case {key, uri.path} do
        {"incident", "/alerting/" <> suffix} -> suffix != ""
        {"dashboard", "/d/" <> suffix} -> suffix != ""
        _ -> false
      end

    expected_path? and uri.scheme == "https" and uri.host == expected_host and
      uri.port in [nil, 443] and is_nil(uri.userinfo) and is_nil(uri.query) and
      is_nil(uri.fragment)
  end

  defp reviewed_link?(key, uri, "github_actions", "AFK-surf/Comma")
       when key in ["incident", "dashboard"] do
    expected_path? =
      case {key, uri.path} do
        {"incident", "/AFK-surf/Comma/actions/runs/" <> run_id} ->
          run_id != "" and String.match?(run_id, ~r/^\d+$/)

        {"dashboard", "/AFK-surf/Comma/actions/workflows/comma-deployment.yml"} ->
          true

        _ ->
          false
      end

    expected_path? and uri.scheme == "https" and uri.host == "github.com" and
      uri.port in [nil, 443] and is_nil(uri.userinfo) and is_nil(uri.query) and
      is_nil(uri.fragment)
  end

  defp reviewed_link?(key, uri, "posthog", account) when key in ["incident", "dashboard"] do
    origin = URI.parse(account)
    expected_prefix = origin.path <> "/error_tracking"

    valid_path =
      case {key, uri.path} do
        {"dashboard", ^expected_prefix} ->
          true

        {"incident", path} when is_binary(path) ->
          prefix = expected_prefix <> "/"

          String.starts_with?(path, prefix) and
            match?({:ok, _}, Ecto.UUID.cast(String.replace_prefix(path, prefix, "")))

        _ ->
          false
      end

    valid_path and uri.scheme == "https" and uri.host == origin.host and
      uri.port in [nil, 443] and is_nil(uri.userinfo) and is_nil(uri.query) and
      is_nil(uri.fragment)
  end

  defp reviewed_link?(_key, _uri, _source, _account), do: false

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    URI.decode_query(query)
  rescue
    ArgumentError -> :invalid
  end

  defp exact(value, value, _field), do: :ok
  defp exact(actual, expected, field), do: {:error, {:catalog_conflict, field, expected, actual}}

  defp optional_exact(nil, _expected, _field), do: :ok
  defp optional_exact(actual, expected, field), do: exact(actual, expected, field)

  defp reviewed_evidence_matches(provider_values, catalog_values) do
    provider_values = provider_values || %{}

    Enum.reduce_while(["threshold", "duration"], :ok, fn key, :ok ->
      case optional_exact(provider_values[key], catalog_values[key], {:evidence, key}) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp format_observed(provider_values, format, policy_identity) do
    provider_values = provider_values || %{}

    case provider_values["observed"] do
      nil ->
        {:ok, provider_values}

      observed ->
        case observed_value(observed, format) do
          {:ok, formatted} ->
            {:ok, Map.put(provider_values, "observed", formatted)}

          :error ->
            {:error, {:invalid_observed_value, policy_identity, observed}}
        end
    end
  end

  defp observed_value(value, :raw), do: {:ok, value}

  defp observed_value(value, :ratio_percent) do
    with {:ok, number} <- finite_number(value) do
      {:ok, compact_number(number * 100) <> "%"}
    end
  end

  defp observed_value(value, :seconds) do
    with {:ok, number} <- finite_number(value) do
      {:ok, compact_number(number) <> " 秒"}
    end
  end

  defp finite_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number == number -> {:ok, number}
      _ -> :error
    end
  end

  defp finite_number(_value), do: :error

  defp compact_number(number) do
    number
    |> :erlang.float_to_binary([:compact, decimals: 6])
    |> String.trim_trailing(".0")
  end

  defp one_of(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, {:catalog_conflict, field, allowed, value}}
  end

  defp source_terminal_latest do
    "告警来源已关闭，指标回到阈值内；服务是否恢复还没有确认。"
  end
end
