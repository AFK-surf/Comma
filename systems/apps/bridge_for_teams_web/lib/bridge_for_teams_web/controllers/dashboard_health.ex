defmodule BridgeForTeamsWeb.DashboardHealth do
  @moduledoc """
  Builds the customer-facing Health page payloads for `DashboardAPIController`.

  Every read is bounded: a fixed number of queries with small limits, and no
  Salix calls. Raw diagnostics (event evidence, check gates, runs) stay in
  Grafana and the backroom; this page shows the org status, the age of the
  latest fact per signal, recent errors and the audit trail.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Environments, Observability, Projects}
  alias BridgeForTeams.RunChecks.GateContract

  @event_limit 20
  @event_window_seconds 7 * 86_400
  @audit_page_limit 25
  @redacted_display "[REDACTED]"

  @doc "The Health page payload for `org`."
  def health(org) do
    now = DateTime.utc_now()
    policy = Observability.freshness_policy()
    projects = Projects.list_projects(org.id)
    runners = Environments.list_mac_mini_provisioners(org.id)
    summary = Observability.org_health_summary_for_org(org.id, length(projects), runners)
    project_ids = MapSet.new(projects, & &1.id)

    %{
      "health" => %{
        "status" => summary.health,
        "reasons" => summary.reason_codes |> Enum.map(&reason_text/1) |> Enum.uniq()
      },
      "signals" => [
        delivery_signal(org.id, now, policy),
        integration_signal(org.id, now, policy),
        runner_signal(runners, now, policy),
        device_signal(org.id, now, policy)
      ],
      "runners" => %{
        "total" => length(runners),
        "online" => Enum.count(runners, &(&1.effective_status == "online"))
      },
      "events" => recent_events(org, project_ids, now),
      "audit_export_href" => "/orgs/#{org.slug}/operations/audit.csv"
    }
  end

  @doc "One page of the org audit trail, newest first."
  def audit_page(org, cursor) do
    page = Observability.page_audit_logs(org.id, limit: @audit_page_limit, after: cursor)

    %{
      "entries" => Enum.map(page.entries, &public_audit/1),
      "next_cursor" => page.next_cursor
    }
  end

  defp delivery_signal(org_id, now, policy) do
    case Observability.list_check_results(org_id, limit: 1) do
      [check] ->
        signal(
          "delivery",
          pgettext("health signal", "Delivery"),
          gettext("Latest check: %{summary}", summary: check_gate_summary(check)),
          check.ran_at,
          policy[:check_result_history_seconds],
          now,
          check.status in ~w(critical fail)
        )

      [] ->
        signal(
          "delivery",
          pgettext("health signal", "Delivery"),
          gettext("No check result observed"),
          nil,
          0,
          now
        )
    end
  end

  defp integration_signal(org_id, now, policy) do
    label = gettext("Integrations")

    case Observability.list_events(org_id, domain: "integration", limit: 1) do
      [event] ->
        signal(
          "integrations",
          label,
          gettext("Latest diagnostic: %{summary}", summary: event_summary(event)),
          event.occurred_at,
          policy[:integration_check_freshness_seconds],
          now,
          failing_event?(event)
        )

      [] ->
        signal("integrations", label, gettext("No integration diagnostic observed"), nil, 0, now)
    end
  end

  defp runner_signal(runners, now, policy) do
    label = pgettext("health signal", "Runners")

    case runners
         |> Enum.filter(& &1.last_seen_at)
         |> Enum.max_by(& &1.last_seen_at, DateTime, fn -> nil end) do
      nil ->
        signal("runners", label, gettext("No runner heartbeat observed"), nil, 0, now)

      runner ->
        signal(
          "runners",
          label,
          gettext("Latest heartbeat: %{runner}", runner: runner_name(runner)),
          runner.last_seen_at,
          policy[:runner_heartbeat_stale_seconds],
          now,
          Enum.any?(runners, &(&1.effective_status in ~w(offline failed error critical)))
        )
    end
  end

  defp device_signal(org_id, now, policy) do
    label = gettext("Devices")

    case Observability.list_events(org_id, domain: "device", limit: 1) do
      [event] ->
        signal(
          "devices",
          label,
          gettext("Latest device event: %{summary}", summary: event_summary(event)),
          event.occurred_at,
          policy[:event_history_seconds],
          now,
          failing_event?(event)
        )

      [] ->
        signal("devices", label, gettext("No device diagnostic observed"), nil, 0, now)
    end
  end

  # A signal is degraded when its latest fact is a failure or when it is
  # older than the freshness policy allows; unknown when nothing was observed.
  defp signal(key, label, detail, observed_at, max_age_seconds, now, failing? \\ false) do
    status =
      case freshness_status(observed_at, max_age_seconds, now) do
        "ok" when failing? -> "degraded"
        status -> status
      end

    %{
      "key" => key,
      "label" => label,
      "detail" => detail,
      "observed_at" => observed_at,
      "status" => status
    }
  end

  defp failing_event?(event), do: event.severity in ~w(error critical)

  defp freshness_status(nil, _max_age_seconds, _now), do: "unknown"

  defp freshness_status(observed_at, max_age_seconds, now)
       when is_integer(max_age_seconds) and max_age_seconds > 0 do
    if DateTime.diff(now, observed_at, :second) > max_age_seconds, do: "degraded", else: "ok"
  end

  defp freshness_status(_observed_at, _max_age_seconds, _now), do: "ok"

  # Error and critical events are separate indexed reads; each is capped, then
  # the two are merged newest first.
  defp recent_events(org, project_ids, now) do
    since = DateTime.add(now, -@event_window_seconds, :second)

    ~w(critical error)
    |> Enum.flat_map(fn severity ->
      Observability.list_events(org.id,
        severity: severity,
        exclude_domain: "audit",
        since: since,
        limit: @event_limit
      )
    end)
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
    |> Enum.take(@event_limit)
    |> Enum.map(&public_event(&1, org, project_ids))
  end

  defp public_event(event, org, project_ids) do
    %{
      "id" => event.id,
      "occurred_at" => event.occurred_at,
      "severity" => event.severity,
      "title" => event_title(event.event_type),
      "summary" => event_summary(event),
      "href" => event_href(event, org, project_ids)
    }
  end

  defp event_title(event_type) do
    case safe_text(event_type) do
      nil -> gettext("Diagnostic recorded")
      text -> text |> String.replace(~w(. _ -), " ") |> String.capitalize()
    end
  end

  defp event_summary(event), do: safe_text(event.summary) || gettext("Diagnostic recorded")

  defp event_href(%{project_id: project_id} = event, org, project_ids)
       when is_binary(project_id) do
    if MapSet.member?(project_ids, project_id) do
      base = "/orgs/#{org.slug}/projects/#{project_id}"
      if event.conversation_id, do: "#{base}/tasks/#{event.conversation_id}", else: base
    end
  end

  defp event_href(_event, _org, _project_ids), do: nil

  defp public_audit(audit) do
    %{
      "id" => audit.id,
      "created_at" => audit.created_at,
      "actor" => audit_actor_label(audit),
      "action" => safe_text(audit.action),
      "resource" => audit_resource_label(audit),
      "result" => safe_text(audit.result)
    }
  end

  defp audit_actor_label(audit) do
    safe_text(audit.actor_label) || short_id(audit.actor_user_id) ||
      safe_text(audit.actor_type) || gettext("system")
  end

  defp audit_resource_label(audit) do
    safe_text(audit.resource_label) || safe_text(audit.resource_id) ||
      safe_text(audit.target) || gettext("Resource")
  end

  defp short_id(id) do
    case safe_text(id) do
      id when is_binary(id) and byte_size(id) > 12 and id != @redacted_display ->
        String.slice(id, 0, 8) <> "..."

      id ->
        id
    end
  end

  defp runner_name(runner), do: safe_text(runner.name) || safe_text(runner.stable_id) || "Runner"

  defp check_gate_summary(%{result: %{"gates" => [_ | _] = gates}}) do
    gates = GateContract.normalize_gates(gates)
    required = Enum.filter(gates, &GateContract.required?/1)

    gate =
      Enum.find(required, &(Map.get(&1, "status") in ~w(fail needs_manual skipped))) ||
        List.first(required) || hd(gates)

    label =
      safe_text(Map.get(gate, "label", Map.get(gate, "gate_id"))) ||
        pgettext("check gate", "Gate")

    status = (Map.get(gate, "status") || "unknown") |> to_string() |> String.replace(~w(_ -), " ")
    "#{label} - #{status}"
  end

  defp check_gate_summary(_check), do: gettext("No gates recorded")

  # Stored text is redacted on write; redact again so a row written before a
  # redaction rule landed never reaches the page.
  defp safe_text(value) when value in [nil, ""], do: nil

  defp safe_text(value) do
    case Observability.redact_payload(value) do
      value when value in [nil, ""] -> nil
      value when is_binary(value) -> value
      value when is_number(value) or is_boolean(value) -> to_string(value)
      _other -> @redacted_display
    end
  end

  defp reason_text(:no_operations_facts), do: gettext("No health signals have been recorded yet.")

  defp reason_text(:projects_without_runners),
    do: gettext("Agent Swarms exist, but no runner is connected.")

  defp reason_text(:critical_runner_status),
    do: gettext("At least one runner reports a critical status.")

  defp reason_text(:runner_offline_or_failed),
    do: gettext("At least one runner is offline or failed.")

  defp reason_text(:runner_stale_or_unknown),
    do: gettext("At least one runner heartbeat is stale or unknown.")

  defp reason_text(:critical_events),
    do: gettext("Recent operational events include critical alerts.")

  defp reason_text(:error_events), do: gettext("Recent operational events include errors.")

  defp reason_text(:critical_runs),
    do: gettext("Recent bounded execution runs include critical failures.")

  defp reason_text(:failed_or_canceled_runs),
    do: gettext("Recent bounded execution runs failed or were canceled.")

  defp reason_text(:critical_checks),
    do: gettext("Recent check snapshots include critical failures.")

  defp reason_text(:failed_checks), do: gettext("Recent check snapshots include failures.")

  defp reason_text(:manual_or_skipped_runs),
    do: gettext("Recent runs need manual follow-up or were skipped.")

  defp reason_text(:manual_or_skipped_checks),
    do: gettext("Recent checks need manual follow-up or were skipped.")

  defp reason_text(:checks_healthy), do: gettext("Latest check snapshots are healthy.")

  defp reason_text(_reason),
    do: gettext("Some signals are missing, so the status stays degraded until they arrive.")
end
