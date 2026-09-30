defmodule Salix.Bindings.MeetingCalendarStatus do
  @moduledoc """
  Bounded, read-only diagnostics for the durable calendar meeting projection.

  This binding never refreshes Google Calendar and never creates a MeetingPlan.
  It reports only work already observed by the background calendar scanner.
  """

  alias SalixCalendar.{MeetingDiagnosticContract, OccurrenceQualification}
  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixMeet.{CalendarProjection, MeetingPlan, Store}

  @max_events 50
  def get(agent_id, connect_id, limit \\ 20) do
    connect_id = trim(connect_id)

    with true <- is_integer(limit) and limit in 1..@max_events,
         {:ok, agent} <- GroupDirectory.get_agent(agent_id),
         group_id when group_id != "" <- trim(agent["group_id"]),
         {:ok, _connect} <-
           ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack"),
         {:ok, projection} <- CalendarProjection.status(group_id, limit) do
      runtime = runtime_status()
      projection = projection_freshness(projection, runtime["scan_interval_ms"])
      events = Enum.map(projection["entries"], &event_status(group_id, &1))
      plan_error_count = Enum.count(events, &(&1["plan"]["status"] != "planned"))

      candidate_error_count = Enum.count(events, &(&1["last_error_present"] == true))

      autojoin_error_count =
        Enum.count(events, fn event ->
          autojoin = event["autojoin"]

          autojoin["status"] in ["failed", "abandoned", "unavailable"] or
            autojoin["error_present"] == true or not is_nil(autojoin["abandoned_at"])
        end)

      {health, reason} =
        health(runtime, projection, plan_error_count, candidate_error_count, autojoin_error_count)

      {:ok,
       %{
         "health" => health,
         "reason" => reason,
         "connect_id" => connect_id,
         "group_id" => group_id,
         "window_hours" => 24,
         "runtime" => runtime,
         "projection" => Map.drop(projection, ["entries"]),
         "summary" => %{
           "candidate_count" => projection["candidate_count"],
           "returned_count" => length(events),
           "planned_count" => Enum.count(events, &(&1["plan"]["status"] == "planned")),
           "plan_error_count" => plan_error_count,
           "candidate_error_count" => candidate_error_count,
           "autojoin_error_count" => autojoin_error_count
         },
         "events" => events
       }}
    else
      false -> {:error, :invalid_calendar_status_query}
      "" -> {:error, :calendar_policy_agent_group_missing}
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_status_query}
    end
  end

  defp event_status(group_id, entry) do
    event = entry["event"] || %{}
    meeting_id = entry["meeting_id"]

    %{
      "candidate_kind" => entry["kind"],
      "meeting_id" => meeting_id,
      "event_id" => event["event_id"],
      "title" => public_title(event["title"]),
      "start_ms" => event["start_ms"],
      "end_ms" => event["end_ms"],
      "calendar_id" => event["calendar_id"],
      "calendar_item_id" => event["calendar_item_id"],
      "meeting_plan_id" => event["meeting_plan_id"],
      "google_meet_eligible" => OccurrenceQualification.google_meet_url?(event["meet_url"]),
      "candidate_updated_at" => entry["updated_at"],
      "recovery_started_at" => entry["recovery_started_at"],
      "last_error_present" => entry["last_error_present"] == true,
      "plan" => plan_status(group_id, event["meeting_plan_id"]),
      "autojoin" => autojoin_status(meeting_id)
    }
  end

  defp plan_status(group_id, plan_id) when is_binary(plan_id) and plan_id != "" do
    case MeetingPlan.get(group_id, plan_id) do
      {:ok, plan} ->
        preparation = plan["preparation"] || %{}

        %{
          "status" => plan["status"] || "unknown",
          "conversation_id" => plan["conversation_id"],
          "revision" => plan["revision"],
          "updated_at" => plan["updated_at"],
          "settings_revision" =>
            if(plan["managed_calendar"] == true, do: preparation["policy_revision"]),
          "preparation" => %{
            "decision_at" => preparation["decision_at"],
            "publish_start_at" => preparation["publish_start_at"],
            "publish_deadline_at" => preparation["publish_deadline_at"],
            "research_decision" => preparation["research_decision"],
            "deadline_status" => preparation["deadline_status"],
            "card_status" => preparation["card_status"],
            "research_started" => is_map(preparation["research_task"]),
            "report_available" => is_binary(preparation["report"]) and preparation["report"] != ""
          }
        }

      {:error, :not_found} ->
        %{"status" => "missing"}

      {:error, _reason} ->
        %{"status" => "unavailable"}
    end
  end

  defp plan_status(_group_id, _plan_id), do: %{"status" => "missing"}

  defp autojoin_status(meeting_id) do
    case Store.get(meeting_id) do
      {:ok, document, _etag} ->
        state = document["state"] || %{}

        public_autojoin_status(%{
          "status" => state["status"] || document["status"] || "pending",
          "start_at" => state["start_at"],
          "join_requested_at" => document["join_requested_at"] || state["join_requested_at"],
          "joined_at" => state["joined_at"],
          "abandoned_at" => state["calendar_autojoin_abandoned_at"],
          "error_present" => not is_nil(state["error"])
        })

      {:error, :not_found} ->
        public_autojoin_status(%{"status" => "not_started"})

      {:error, _reason} ->
        public_autojoin_status(%{"status" => "unavailable", "error_present" => true})
    end
  end

  defp public_autojoin_status(autojoin) do
    status = MeetingDiagnosticContract.autojoin_status(autojoin["status"])

    %{
      "status" => status,
      "start_at" => autojoin["start_at"],
      "join_requested_at" => autojoin["join_requested_at"],
      "joined_at" => autojoin["joined_at"],
      "abandoned_at" => autojoin["abandoned_at"],
      "error_present" => autojoin["error_present"] == true or status == "unavailable"
    }
  end

  defp runtime_status do
    opts = Application.get_env(:salix_meet, :calendar_autojoin)
    configured? = is_list(opts)
    pid = Process.whereis(SalixMeet.CalendarAutojoin)
    running? = is_pid(pid) and Process.alive?(pid)

    scan_interval_ms =
      if configured?, do: Keyword.get(opts, :scan_interval_ms, 120_000), else: nil

    %{
      "status" =>
        cond do
          running? -> "running"
          configured? -> "not_running"
          true -> "not_configured"
        end,
      "configured" => configured?,
      "running" => running?,
      "scan_interval_ms" => scan_interval_ms,
      "runtime_driver" => effective_runtime_driver(),
      "runtime_driver_conflict" => runtime_driver_conflict?()
    }
  end

  # `meetings.runtime_url` takes precedence over `meetings.driver` when both
  # are configured (config/runtime.exs), which silently disables the connector
  # driver. Expose the effective driver and the conflict so operators can see
  # in one read which runtime path joins actually take.
  defp effective_runtime_driver do
    case Application.get_env(:salix_meet, :runtime_driver) do
      SalixMeet.RuntimeDriver.HTTP -> "http"
      SalixMeet.RuntimeDriver.SalixConnect -> "connector"
      nil -> "none"
      _other -> "unknown"
    end
  end

  defp runtime_driver_conflict? do
    url = Application.get_env(:salix_meet, :runtime_base_url)
    mode = Application.get_env(:salix_meet, :runtime_driver_mode)

    is_binary(url) and String.trim(url) != "" and is_binary(mode) and
      String.trim(mode) == "connector"
  end

  defp projection_freshness(projection, scan_interval_ms) do
    updated_at = projection["updated_at"]
    stale_after_ms = max((scan_interval_ms || 120_000) * 3, 300_000)

    age_ms =
      if is_integer(updated_at),
        do: max(System.system_time(:millisecond) - updated_at, 0),
        else: nil

    projection
    |> Map.put("age_ms", age_ms)
    |> Map.put("stale_after_ms", stale_after_ms)
    |> Map.put("freshness_valid", projection["state"] != "active" or is_integer(updated_at))
    |> Map.put("stale", is_integer(age_ms) and age_ms > stale_after_ms)
  end

  defp health(
         %{"status" => status},
         _projection,
         _plan_errors,
         _candidate_errors,
         _autojoin_errors
       )
       when status != "running",
       do: {"degraded", "calendar_worker_#{status}"}

  defp health(
         _runtime,
         %{"state" => "not_scanned"},
         _plan_errors,
         _candidate_errors,
         _autojoin_errors
       ),
       do: {"pending", "projection_not_scanned"}

  defp health(_runtime, %{"stale" => true}, _plan_errors, _candidate_errors, _autojoin_errors),
    do: {"degraded", "projection_stale"}

  defp health(
         _runtime,
         %{"freshness_valid" => false},
         _plan_errors,
         _candidate_errors,
         _autojoin_errors
       ),
       do: {"degraded", "projection_freshness_invalid"}

  defp health(
         _runtime,
         %{"truncated" => true},
         _plan_errors,
         _candidate_errors,
         _autojoin_errors
       ),
       do: {"degraded", "calendar_status_truncated"}

  defp health(_runtime, _projection, plan_error_count, _candidate_errors, _autojoin_errors)
       when plan_error_count > 0,
       do: {"degraded", "meeting_plan_unavailable"}

  defp health(_runtime, _projection, 0, candidate_error_count, _autojoin_errors)
       when candidate_error_count > 0,
       do: {"degraded", "calendar_candidate_recovery_error"}

  defp health(_runtime, _projection, 0, 0, autojoin_error_count)
       when autojoin_error_count > 0,
       do: {"degraded", "autojoin_runtime_error"}

  defp health(_runtime, %{"candidate_count" => 0}, 0, 0, 0),
    do: {"ok", "no_eligible_meetings_in_window"}

  defp health(_runtime, _projection, 0, 0, 0), do: {"ok", "eligible_meetings_projected"}

  defp public_title(value) when is_binary(value) do
    value
    |> OccurrenceQualification.redact_google_meet_urls()
    |> String.slice(0, 256)
    |> case do
      "" -> "Calendar meeting"
      title -> title
    end
  end

  defp public_title(_value), do: "Calendar meeting"

  defp trim(value), do: value |> to_string() |> String.trim()
end
