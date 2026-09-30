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
      runbook: @deployment_failure_runbook
    },
    ["gcp_monitoring", "comma_alerting", "external_session_runtime_failed"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P0",
      team: "comma",
      service: "salix_agent",
      family: "availability",
      summary: "Agent session 自动恢复耗尽，需要人工介入",
      impact: "受影响的外部 Agent session 已耗尽自动恢复预算，当前 execution 需要人工处理。",
      firing_latest: "已观察到持久化成功后的 recovery_exhausted lifecycle 事实，自动恢复已停止。",
      evidence_values: %{
        "cluster" => :gke_cluster,
        "trigger_error" => "recovery_exhausted",
        "threshold" => ">= 1 个自动恢复耗尽事件",
        "duration" => "单次事件"
      },
      runbook: @salix_agent_runtime_runbook
    },
    ["gcp_monitoring", "comma_alerting", "external_session_runtime_interrupted"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging, :production],
      environments: ~w(staging production),
      priority: "P1",
      team: "comma",
      service: "salix_agent",
      family: "availability",
      summary: "Agent 任务执行受阻",
      impact: "任务可能无法继续执行。受影响的会话和具体失败类型尚待定位。",
      firing_latest: "监控已报告执行异常，恢复情况尚未确认；不表示自动恢复耗尽。",
      evidence_values: %{
        "cluster" => :gke_cluster,
        "threshold" => "external 中断 1 次；internal 同一 Task activation 依赖失败 3 次",
        "duration" => "达到对应事件门槛"
      },
      runbook: @salix_agent_runtime_runbook
    },
    ["gcp_monitoring", "comma_alerting", "router_request_stalled"] => %{
      source: "gcp_monitoring",
      source_accounts: [:staging],
      environments: ~w(staging),
      priority: "P1",
      team: "comma",
      service: "salix_agent",
      family: "availability",
      summary: "Router user requests are not starting",
      impact: "Admitted user requests are waiting behind a stalled Router.",
      firing_latest: "At least one Router has old pending input and no new request starts.",
      evidence_values: %{
        "threshold" => "pending > 0; oldest > 300s; no new start >= 300s",
        "duration" => "No additional hold"
      },
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
      firing_latest: "归因后的 IM 入口失败率持续高于已审核阈值。",
      evidence_values: %{
        "threshold" => "> 5%",
        "duration" => "15 分钟",
        "sample_count" => ">= 20 个样本"
      },
      runbook: @im_runbook
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

  defp source_accounts(:configured_posthog) do
    case AlertRouter.Adapters.PostHog.configuration() do
      {:ok, config} -> [config.account]
      _ -> []
    end
  end

  defp source_accounts(accounts) when is_list(accounts) do
    projects = Application.get_env(:alert_router, :gcp_projects, %{})

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
      cluster = Application.get_env(:alert_router, :gke_cluster)

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
    "来源已结束告警，服务恢复待确认。关闭后续事项前请检查完整生命周期时间线。"
  end
end
