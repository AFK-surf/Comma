defmodule AlertRouter.Slack.Renderer do
  @moduledoc """
  Pure Slack Block Kit projection.

  Root messages always contain exactly two top-level siblings in this order:
  `container`, then native `plan`. Thread events are compact Block Kit cards.
  All root titles pair a color marker with an explicit lifecycle
  label so status remains distinguishable without relying on color alone.

  The native plan is an event-backed incident timeline. Every distinct source,
  canonical, or recovery state appends one stable task at the event's observed
  time. The latest task remains open while the incident is not verified as
  recovered instead of projecting a fixed transport checklist.

  Recovery wording is modeled by
  `tla/alert_router/AlertRouterRecoveryTruth.tla::RecoveryClaimRequiresEvidence`
  and `UnknownTerminalIsNotRecovered`.
  """

  alias AlertRouter.Data.{EventRecord, Incident}
  alias AlertRouter.Slack.MessageMarker

  @provider_icons %{
    "salix_runtime" => %{
      url: "https://cloud.google.com/images/social-icon-google-cloud-1200-630.png",
      alt: "Google Cloud"
    },
    "posthog" => %{url: "https://posthog.com/favicon.ico", alt: "PostHog"},
    "gcp_monitoring" => %{
      url: "https://cloud.google.com/images/social-icon-google-cloud-1200-630.png",
      alt: "Google Cloud"
    },
    "grafana" => %{
      url: "https://grafana.com/static/assets/img/fav32.png",
      alt: "Grafana"
    },
    "github_actions" => %{
      url: "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png",
      alt: "GitHub Actions"
    }
  }

  @verified_recovery_latest "本次告警对应的故障已由正向证据确认恢复。"

  @spec root(Incident.t(), pos_integer(), keyword()) :: map()
  def root(%Incident{} = incident, revision, opts \\ [])
      when is_integer(revision) and revision > 0 and is_list(opts) do
    id = incident_id(incident.incident_key)
    channel_mention? = channel_mention?(incident, opts)
    lifecycle_events = Keyword.get(opts, :lifecycle_events, [])

    %{
      "text" => fallback_text(incident, channel_mention?),
      "blocks" => [
        container(
          incident,
          revision,
          id,
          channel_mention?,
          Keyword.get(opts, :progress_enabled, false)
        ),
        plan(incident, revision, id, lifecycle_events)
      ]
    }
  end

  @spec timeline(EventRecord.t(), Incident.t(), keyword()) :: map()
  def timeline(event, incident, opts \\ [])

  def timeline(
        %EventRecord{canonical_payload: %{"notice_kind" => _} = snapshot} = event,
        %Incident{} = incident,
        opts
      ) do
    id = incident_id(incident.incident_key)
    revision = event.render_revision
    text = snapshot["notice_text"]
    mention = notice_mention(snapshot, incident)

    %{
      "text" => "#{mention}#{snapshot["priority"]} · #{snapshot["summary"]} — #{escape(text)}",
      "blocks" => [
        %{
          "type" => "container",
          "block_id" => MessageMarker.timeline(id, revision, event_id(event.event_id)),
          "title" => plain_text("处理更新 · #{incident.summary}"),
          "child_blocks" =>
            [
              if(mention != "", do: %{"type" => "section", "text" => mrkdwn(mention)}),
              %{"type" => "section", "text" => plain_text(text)},
              if(opts[:root_url],
                do: %{
                  "type" => "actions",
                  "elements" => [button(opts[:root_url], "查看主卡与处理进展", "view_alert_thread")]
                }
              )
            ]
            |> Enum.reject(&is_nil/1)
        }
      ]
    }
  end

  def timeline(%EventRecord{} = event, %Incident{} = incident, opts) do
    id = incident_id(incident.incident_key)
    revision = event.render_revision || incident.desired_revision
    snapshot = event.canonical_payload || %{}
    recovery_status = snapshot["recovery_status"] || incident.recovery_status
    state = state_label(event.state, recovery_status)
    summary = snapshot["summary"] || incident.summary

    latest =
      display_latest(event.state, recovery_status, snapshot["latest"] || incident.latest)

    source = snapshot["source"] || incident.source

    escalation? = channel_notification?(event, incident)
    priority = snapshot["priority"] || incident.priority

    %{
      "text" =>
        if(escalation?,
          do: "<!channel> #{priority} 升级 · #{state} · #{summary}",
          else: "#{state} · #{summary}"
        ),
      "blocks" => [
        %{
          "type" => "container",
          "block_id" => MessageMarker.timeline(id, revision, event_id(event.event_id)),
          "title" => plain_text("#{state} · #{summary}"),
          "subtitle" => plain_text(format_time(event.observed_at)),
          "width" => "standard",
          "has_header_divider" => true,
          "child_blocks" =>
            [
              source_context(source, revision, id, "timeline-source"),
              %{
                "type" => "section",
                "block_id" => block_id(id, revision, "timeline-body"),
                "text" =>
                  mrkdwn(
                    if(escalation?, do: "<!channel> *#{priority} 升级，需要处理*\n", else: "") <>
                      "*最新状态*\n#{escape(latest)}"
                  )
              },
              %{
                "type" => "context",
                "block_id" => block_id(id, revision, "timeline-context"),
                "elements" => [
                  mrkdwn("生命周期事件 · `#{id}` · 修订 #{revision}")
                ]
              },
              if(opts[:root_url],
                do: %{
                  "type" => "actions",
                  "block_id" => block_id(id, revision, "original-thread"),
                  "elements" => [button(opts[:root_url], "查看主卡与处理进展", "view_alert_thread")]
                }
              )
            ]
            |> Enum.reject(&is_nil/1)
        }
      ]
    }
  end

  defp notice_mention(snapshot, incident) do
    case {incident.route_id, snapshot["notice_mention"]} do
      {"live", "channel"} ->
        "<!channel> "

      {"live", user} when is_binary(user) ->
        if Regex.match?(~r/\A[UW][A-Z0-9]{1,32}\z/, user), do: "<@#{user}> ", else: ""

      _ ->
        ""
    end
  end

  def channel_notification?(event, incident) do
    snapshot = event.canonical_payload || %{}

    if snapshot["channel_notice"] == true do
      incident.route_id == "live"
    else
      incident.route_id == "live" and event.state == "firing" and
        (snapshot["priority"] || incident.priority) in ["P0", "P1"] and
        Map.get(snapshot, "channel_notification", false) and
        (event.render_revision || 1) > (incident.slack_root_revision || 1)
    end
  end

  @doc "Returns the non-sensitive Block Kit marker identifier for one incident generation."
  @spec incident_id(String.t()) :: String.t()
  def incident_id(incident_key) when is_binary(incident_key), do: short_hash(incident_key)

  @doc "Returns the non-sensitive Block Kit marker identifier for one canonical event."
  @spec event_id(String.t()) :: String.t()
  def event_id(event_id) when is_binary(event_id), do: short_hash(event_id)

  defp container(incident, revision, id, channel_mention?, progress_enabled?) do
    child_blocks =
      [
        channel_mention(channel_mention?, incident.priority, revision, id),
        incident_source_context(incident, revision, id),
        progress_section(incident, revision, id),
        feedback_section(incident, revision, id),
        status_section(incident, revision, id),
        diagnostic_context(incident, revision, id),
        metric_table(incident, revision, id),
        actions(incident, revision, id),
        ownership_actions(incident, revision, id, progress_enabled?),
        context(incident, revision, id, progress_enabled?)
      ]
      |> Enum.reject(&is_nil/1)

    %{
      "type" => "container",
      "block_id" => MessageMarker.root(id, revision),
      "title" => plain_text(container_title(incident)),
      "subtitle" => plain_text(container_subtitle(incident)),
      "width" => "standard",
      "has_header_divider" => true,
      "child_blocks" => child_blocks
    }
  end

  defp channel_mention(true, priority, revision, id) do
    %{
      "type" => "section",
      "block_id" => block_id(id, revision, "channel-mention"),
      "text" => mrkdwn("<!channel> *#{priority} 全员告警*")
    }
  end

  defp channel_mention(false, _priority, _revision, _id), do: nil

  defp incident_source_context(%Incident{} = incident, revision, id) do
    icon = Map.fetch!(@provider_icons, incident.source)

    owner =
      case incident.owner do
        nil ->
          "未指派"

        user ->
          if Regex.match?(~r/\A[UW][A-Z0-9]{1,32}\z/, user), do: "<@#{user}>", else: escape(user)
      end

    %{
      "type" => "context",
      "block_id" => block_id(id, revision, "source"),
      "elements" => [
        %{"type" => "image", "image_url" => icon.url, "alt_text" => icon.alt},
        mrkdwn(
          "*#{source_label(incident.source)}* · #{format_time(incident.started_at)} · 负责人 #{owner}"
        )
      ]
    }
  end

  defp diagnostic_context(%Incident{} = incident, revision, id) do
    evidence = incident.evidence_values || %{}

    rows =
      [
        {"归属", [{"Tenant", "tenant"}, {"Agent Group", "agent_group"}]},
        {"执行", [{"Agent", "agent"}, {"Session", "session"}]},
        {"定位", [{"Execution", "execution"}, {"Dispatch", "dispatch"}]}
      ]
      |> Enum.flat_map(fn {label, fields} ->
        values =
          fields
          |> Enum.filter(fn {_label, key} -> present?(evidence[key]) end)
          |> Enum.map(fn {label, key} -> "#{label} #{display_detail(evidence[key])}" end)

        if values == [], do: [], else: ["*#{label}*  " <> Enum.join(values, " · ")]
      end)

    if rows != [],
      do: %{
        "type" => "section",
        "block_id" => block_id(id, revision, "diagnostic-context"),
        "text" => mrkdwn(Enum.join(rows, "\n"))
      }
  end

  defp metric_table(incident, revision, id) do
    evidence = incident.evidence_values || %{}

    headers = ["最新值", "触发阈值", "窗口"]

    %{
      "type" => "table",
      "block_id" => block_id(id, revision, "metrics"),
      "column_settings" => [
        %{"align" => "left"},
        %{"align" => "left"},
        %{"align" => "left"}
      ],
      "rows" => [
        Enum.map(headers, &raw_text/1),
        Enum.map(
          [
            evidence["observed"] || "—",
            evidence["threshold"] || "—",
            evidence["duration"] || "—"
          ],
          &raw_text/1
        )
      ]
    }
  end

  defp status_section(%Incident{} = incident, revision, id) do
    error = (incident.evidence_values || %{})["trigger_error"]
    latest = display_latest(incident.state, incident.recovery_status, incident.latest)

    error_line = if present?(error), do: "*触发错误*  #{display_detail(error)}\n", else: ""

    %{
      "type" => "section",
      "block_id" => block_id(id, revision, "status"),
      "text" =>
        mrkdwn(
          error_line <>
            "*影响*  #{escape(incident.impact)}\n" <>
            "*告警状态*  #{escape(latest)}\n" <>
            "*已知范围*  #{escape(affected_scope(incident))}"
        )
    }
  end

  defp affected_scope(incident) do
    evidence = incident.evidence_values || %{}

    cond do
      present?(evidence["session"]) -> "已定位 1 个会话；整体影响范围尚未确认。"
      true -> "受影响的用户和任务数量尚未确认。"
    end
  end

  defp progress_section(incident, revision, id) do
    progress = incident.progress || %{}

    text =
      case progress do
        %{"text" => text, "author" => author, "timestamp" => timestamp} ->
          time = timestamp |> DateTime.from_unix!(:microsecond) |> format_time()
          source = if progress["source"] == "investigator", do: "调查机器人回报", else: "线程回报"
          "最新处理进展（#{source}）\n#{text}\n回报人 #{author} · #{time}\n回报不替代恢复验证。"

        _ ->
          "最新处理进展：尚无调查回报。"
      end

    %{
      "type" => "section",
      "block_id" => block_id(id, revision, "progress"),
      "text" => plain_text(text)
    }
  end

  defp actions(incident, revision, id) do
    elements =
      [
        button(incident.links["incident"], "打开事件", "open_incident"),
        button(incident.links["dashboard"], "查看仪表盘", "view_dashboard"),
        button(incident.links["runbook"], "查看处置手册", "view_runbook")
      ]
      |> Enum.reject(&is_nil/1)

    if elements == [] do
      nil
    else
      %{
        "type" => "actions",
        "block_id" => block_id(id, revision, "actions"),
        "elements" => elements
      }
    end
  end

  defp ownership_actions(_, _, _, false), do: nil

  defp ownership_actions(incident, revision, id, true) do
    element =
      if is_nil(incident.owner) do
        %{"type" => "button", "action_id" => "alert_claim", "text" => plain_text("我来处理")}
      else
        %{
          "type" => "users_select",
          "action_id" => "alert_transfer",
          "placeholder" => plain_text("负责人转交给…")
        }
      end

    %{
      "type" => "actions",
      "block_id" => block_id(id, revision, "ownership"),
      "elements" => [
        element,
        %{
          "type" => "static_select",
          "action_id" => "alert_feedback",
          "placeholder" => plain_text("告警质量反馈"),
          "options" =>
            Enum.map(["needs_action", "self_recovered", "false_positive"], fn value ->
              %{"value" => value, "text" => plain_text(feedback_label(value))}
            end)
        }
      ]
    }
  end

  def feedback_label("needs_action"), do: "需要行动"
  def feedback_label("self_recovered"), do: "自愈"
  def feedback_label("false_positive"), do: "误报"
  def feedback_label(_), do: "待分类"

  defp feedback_section(%{feedback: %{"outcome" => outcome, "author" => author}}, revision, id) do
    %{
      "type" => "context",
      "block_id" => block_id(id, revision, "feedback"),
      "elements" => [plain_text("处理反馈：#{feedback_label(outcome)} · #{author}（不替代恢复验证）")]
    }
  end

  defp feedback_section(_, _, _), do: nil

  defp context(incident, revision, id, progress_enabled?) do
    label =
      escape(policy_label(incident.policy_identity))

    %{
      "type" => "context",
      "block_id" => block_id(id, revision, "context"),
      "elements" =>
        [
          mrkdwn("#{label} · `#{id}` · r#{revision} · 时间线见 thread"),
          if(progress_enabled?,
            do: plain_text("更新主卡：在线程回复，以“告警进展”独占首行，随后写已确认、影响、下一步。")
          )
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp plan(incident, revision, id, events) do
    transitions = lifecycle_transitions(events, incident)
    last_index = length(transitions) - 1

    %{
      "type" => "plan",
      "block_id" => block_id(id, revision, "plan"),
      "title" => "告警生命周期",
      "tasks" =>
        transitions
        |> Enum.with_index()
        |> Enum.map(fn {event, index} ->
          latest? = index == last_index
          lifecycle_task(id, event, latest?, incident.recovery_status)
        end)
    }
  end

  defp task(id, suffix, title, status) do
    %{"task_id" => "ar_#{id}_#{suffix}", "title" => title, "status" => status}
  end

  defp lifecycle_transitions([], incident), do: [incident_event(incident)]

  defp lifecycle_transitions(events, _incident) do
    events
    |> Enum.sort_by(&{&1.render_revision || 0, &1.event_id})
    |> Enum.reduce([], fn event, transitions ->
      case transitions do
        [previous | _rest] ->
          if lifecycle_signature(previous) == lifecycle_signature(event) do
            transitions
          else
            [event | transitions]
          end

        [] ->
          [event | transitions]
      end
    end)
    |> Enum.reverse()
  end

  defp lifecycle_task(id, event, latest?, incident_recovery_status) do
    recovery_status = event_recovery_status(event)

    status =
      if latest? and incident_recovery_status != "verified", do: "pending", else: "complete"

    task(
      id,
      event_task_id(event),
      lifecycle_title(event, recovery_status),
      status
    )
  end

  defp lifecycle_title(event, recovery_status) do
    title =
      [
        state_label(event.state, recovery_status),
        event.source_state,
        format_time(event.observed_at)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    if event.state == "resolved" and recovery_status != "verified" do
      title <> " · 服务恢复待确认"
    else
      title
    end
  end

  defp lifecycle_signature(event) do
    {event.state, event.source_state, event_recovery_status(event)}
  end

  defp event_recovery_status(event) do
    get_in(event.canonical_payload || %{}, ["recovery_status"]) || "not_applicable"
  end

  defp event_task_id(%EventRecord{event_id: event_id}) when is_binary(event_id),
    do: event_id(event_id)

  defp event_task_id(_event), do: "current"

  defp incident_event(incident) do
    %EventRecord{
      incident_key: incident.incident_key,
      source_state: incident.source_state,
      state: incident.state,
      observed_at: incident.observed_at,
      render_revision: incident.desired_revision,
      canonical_payload: %{"recovery_status" => incident.recovery_status}
    }
  end

  defp button(nil, _label, _action_id), do: nil

  defp button(url, label, action_id) do
    %{
      "type" => "button",
      "text" => plain_text(label),
      "url" => url,
      "action_id" => action_id
    }
  end

  defp fallback_text(incident, channel_mention?) do
    latest =
      case incident.progress || %{} do
        %{"text" => report} -> "线程回报：" <> String.slice(report, 0, 240)
        _ -> display_latest(incident.state, incident.recovery_status, incident.latest)
      end

    prefix = if channel_mention?, do: "<!channel> ", else: ""

    prefix <>
      "#{incident.priority} #{state_label(incident.state, incident.recovery_status)}：#{incident.summary} " <>
      "(#{incident.environment}/#{incident.service}) — #{escape(latest)}"
  end

  defp channel_mention?(incident, opts) do
    Keyword.get(opts, :channel_mention, false) and
      incident.route_id == "live" and
      incident.priority in ["P0", "P1"] and
      incident.state == "firing"
  end

  defp container_subtitle(%Incident{} = incident) do
    evidence = incident.evidence_values || %{}

    [incident.environment, incident.service, evidence["cluster"], incident.region]
    |> Enum.filter(&present?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.join(" · ")
  end

  defp source_context(source, revision, id, suffix) do
    icon = Map.fetch!(@provider_icons, source)

    %{
      "type" => "context",
      "block_id" => block_id(id, revision, suffix),
      "elements" => [
        %{
          "type" => "image",
          "image_url" => icon.url,
          "alt_text" => icon.alt
        },
        mrkdwn("*#{source_label(source)}* · 告警来源")
      ]
    }
  end

  defp source_label("gcp_monitoring"), do: "GCP 监控"
  defp source_label("salix_runtime"), do: "Salix runtime"
  defp source_label("posthog"), do: "PostHog"
  defp source_label("grafana"), do: "Grafana"
  defp source_label("github_actions"), do: "GitHub Actions"
  defp source_label(source), do: source

  defp state_label("firing", _recovery_status), do: "告警中"
  defp state_label("resolved", "verified"), do: "已确认恢复"
  defp state_label("resolved", _recovery_status), do: "来源已结束告警"
  defp state_label(state, _recovery_status), do: state

  defp status_marker("firing", _recovery_status), do: "🔴"
  defp status_marker("resolved", "verified"), do: "🟢"
  defp status_marker("resolved", _recovery_status), do: "🟡"
  defp status_marker(_state, _recovery_status), do: "⚪"

  defp container_title(%Incident{} = incident) do
    title =
      "#{incident.priority} · #{state_label(incident.state, incident.recovery_status)} · #{incident.summary}"

    "#{status_marker(incident.state, incident.recovery_status)} #{title}"
  end

  defp display_detail(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "_未提供_"
      value -> "`#{escape(value)}`"
    end
  end

  defp display_detail(_value), do: "_未提供_"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp display_latest("resolved", "verified", _latest), do: @verified_recovery_latest
  defp display_latest(_state, _recovery_status, latest), do: latest

  defp policy_label(identity) when is_list(identity), do: Enum.join(identity, "/")
  defp policy_label(_identity), do: "unknown-policy"

  defp plain_text(text), do: %{"type" => "plain_text", "text" => text, "emoji" => false}
  defp mrkdwn(text), do: %{"type" => "mrkdwn", "text" => text}
  defp raw_text(text), do: %{"type" => "raw_text", "text" => to_string(text)}

  defp block_id(id, revision, suffix), do: "ar-#{id}-r#{revision}-#{suffix}"

  defp short_hash(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
    |> String.downcase()
  end

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  defp format_time(_datetime), do: "Time unavailable"

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
