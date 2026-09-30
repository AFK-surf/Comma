defmodule BridgeForTeams.RunChecks.CalendarStatusContract do
  @moduledoc """
  Public raw contract and allowlist for the experimental meeting-calendar diagnostic.

  Salix owns the internal projection and plan records. BFT publishes only this
  bounded DTO. The complete raw shape and its cross-field identities are
  validated before any defaulting or redaction, so provider/storage errors,
  fabricated defaults, and conference URLs embedded in untrusted strings
  cannot cross the CLI boundary.
  """

  alias SalixCalendar.{MeetingDiagnosticContract, OccurrenceQualification}

  @public_health_pairs MapSet.new([
                         {"degraded", "calendar_worker_not_running"},
                         {"degraded", "calendar_worker_not_configured"},
                         {"pending", "projection_not_scanned"},
                         {"degraded", "projection_stale"},
                         {"degraded", "projection_freshness_invalid"},
                         {"degraded", "meeting_plan_unavailable"},
                         {"degraded", "calendar_candidate_recovery_error"},
                         {"degraded", "autojoin_runtime_error"},
                         {"ok", "no_eligible_meetings_in_window"},
                         {"ok", "eligible_meetings_projected"},
                         {"degraded", "calendar_status_truncated"}
                       ])
  @runtime_statuses ~w(running not_running not_configured)
  @projection_states ~w(active not_scanned unavailable)
  @candidate_kinds ~w(fresh recovery)
  @plan_statuses ~w(provisioning planned cancelled missing unavailable unknown)
  @research_decisions ~w(pending required not_required)
  @deadline_statuses ~w(pending diagnostic_only not_required)
  @unavailable_reasons ~w(calendar_status_invalid_response calendar_status_unavailable)
  @raw_status_fields ~w(
    health reason connect_id group_id window_hours runtime projection summary events
  )
  @raw_projection_fields ~w(
    state calendar_id updated_at age_ms stale_after_ms stale fresh_count recovery_count
    candidate_count returned_count limit truncated
  )
  @raw_summary_fields ~w(
    candidate_count returned_count planned_count plan_error_count candidate_error_count
    autojoin_error_count
  )
  @raw_event_fields ~w(
    candidate_kind meeting_id event_id title start_ms end_ms calendar_id calendar_item_id
    meeting_plan_id google_meet_eligible candidate_updated_at recovery_started_at
    last_error_present plan autojoin
  )
  @raw_plan_fields ~w(status conversation_id revision updated_at preparation)
  @raw_preparation_fields ~w(
    decision_at publish_start_at publish_deadline_at research_decision
    deadline_status
  )
  @raw_autojoin_fields ~w(status start_at join_requested_at joined_at)
  @full_plan_statuses @plan_statuses -- ~w(missing unavailable)

  @spec normalize(map(), pos_integer()) :: map()
  def normalize(status, limit) when is_map(status) and is_integer(limit) and limit in 1..50 do
    if raw_status_valid?(status, limit) do
      normalize_valid_status(status, limit)
    else
      unavailable("calendar_status_invalid_response", limit)
    end
  end

  def normalize(_status, limit), do: unavailable("calendar_status_invalid_response", limit)

  @spec unavailable(String.t(), pos_integer()) :: map()
  def unavailable(reason, limit) do
    %{
      "health" => "unavailable",
      "reason" => safe_reason(reason),
      "window_hours" => 24,
      "runtime" => %{},
      "projection" => %{
        "state" => "unavailable",
        "candidate_count" => 0,
        "returned_count" => 0,
        "limit" => limit,
        "truncated" => false
      },
      "summary" => empty_summary(),
      "events" => []
    }
  end

  @spec redact_meet_urls(term()) :: term()
  def redact_meet_urls(value), do: OccurrenceQualification.redact_google_meet_urls(value)

  defp normalize_valid_status(status, limit) do
    events = status["events"] |> Enum.take(limit) |> Enum.map(&event/1)
    runtime = runtime(status["runtime"])
    projection = projection(status["projection"], limit, length(events))
    summary = summary(status["summary"], length(events))

    {health, reason} =
      runtime
      |> derive_public_health(projection, summary, events)
      |> cross_check_source_health(status["health"], status["reason"])

    %{
      "health" => health,
      "reason" => reason,
      "connect_id" => safe_string(status["connect_id"], 256),
      "group_id" => safe_string(status["group_id"], 256),
      "window_hours" => 24,
      "runtime" => runtime,
      "projection" => projection,
      "summary" => summary,
      "events" => events
    }
  end

  defp derive_public_health(runtime, projection, summary, events) do
    cond do
      projection["state"] == "unavailable" ->
        {"unavailable", "calendar_status_invalid_response"}

      runtime["status"] != "running" ->
        {"degraded", "calendar_worker_#{runtime["status"]}"}

      projection["state"] == "not_scanned" ->
        {"pending", "projection_not_scanned"}

      not projection_freshness_valid?(projection) ->
        {"degraded", "projection_freshness_invalid"}

      projection["stale"] ->
        {"degraded", "projection_stale"}

      projection["truncated"] ->
        {"degraded", "calendar_status_truncated"}

      plan_error?(summary, events) ->
        {"degraded", "meeting_plan_unavailable"}

      candidate_error?(summary, events) ->
        {"degraded", "calendar_candidate_recovery_error"}

      autojoin_error?(summary, events) ->
        {"degraded", "autojoin_runtime_error"}

      projection["candidate_count"] == 0 ->
        {"ok", "no_eligible_meetings_in_window"}

      true ->
        {"ok", "eligible_meetings_projected"}
    end
  end

  defp cross_check_source_health(derived, health, reason) do
    source = {health, reason}

    cond do
      not MapSet.member?(@public_health_pairs, source) ->
        {"unavailable", "calendar_status_invalid_response"}

      source == derived ->
        derived

      health == "ok" and elem(derived, 0) != "ok" ->
        derived

      true ->
        {"unavailable", "calendar_status_invalid_response"}
    end
  end

  defp projection_freshness_valid?(%{"state" => "active"} = projection) do
    is_integer(projection["updated_at"]) and projection["updated_at"] >= 0 and
      is_integer(projection["age_ms"]) and projection["age_ms"] >= 0 and
      is_integer(projection["stale_after_ms"]) and projection["stale_after_ms"] > 0
  end

  defp projection_freshness_valid?(_projection), do: true

  defp plan_error?(summary, events) do
    summary["plan_error_count"] > 0 or
      Enum.any?(events, &(get_in(&1, ["plan", "status"]) != "planned"))
  end

  defp candidate_error?(summary, events) do
    summary["candidate_error_count"] > 0 or
      Enum.any?(events, &(&1["last_error_present"] == true))
  end

  defp autojoin_error?(summary, events) do
    summary["autojoin_error_count"] > 0 or
      Enum.any?(events, fn event ->
        autojoin = event["autojoin"]

        MeetingDiagnosticContract.autojoin_error_status?(autojoin["status"]) or
          autojoin["error_present"] == true or is_integer(autojoin["abandoned_at"])
      end)
  end

  defp raw_status_valid?(status, limit) do
    raw_events = status["events"]

    required_fields?(status, @raw_status_fields) and
      MapSet.member?(@public_health_pairs, {status["health"], status["reason"]}) and
      bounded_non_empty_string?(status["connect_id"], 256) and
      bounded_non_empty_string?(status["group_id"], 256) and
      status["window_hours"] == 24 and is_list(raw_events) and
      Enum.all?(raw_events, &is_map/1) and
      runtime_contract_valid?(status["runtime"]) and
      projection_contract_valid?(status["projection"], raw_events, limit) and
      Enum.all?(raw_events, &event_contract_valid?/1) and
      summary_contract_valid?(status["summary"], raw_events) and
      status["projection"]["candidate_count"] == status["summary"]["candidate_count"] and
      status["projection"]["returned_count"] == status["summary"]["returned_count"]
  end

  defp runtime_contract_valid?(%{
         "status" => "running",
         "configured" => true,
         "running" => true,
         "scan_interval_ms" => scan_interval_ms
       }),
       do: positive_integer?(scan_interval_ms)

  defp runtime_contract_valid?(%{
         "status" => "not_running",
         "configured" => true,
         "running" => false,
         "scan_interval_ms" => scan_interval_ms
       }),
       do: positive_integer?(scan_interval_ms)

  defp runtime_contract_valid?(%{
         "status" => "not_configured",
         "configured" => false,
         "running" => false,
         "scan_interval_ms" => nil
       }),
       do: true

  defp runtime_contract_valid?(_runtime), do: false

  defp projection_contract_valid?(projection, raw_events, limit) when is_map(projection) do
    required_fields?(projection, @raw_projection_fields) and
      projection["state"] in @projection_states and
      projection_state_contract_valid?(projection) and
      nullable_non_negative_integer?(projection["updated_at"]) and
      nullable_non_negative_integer?(projection["age_ms"]) and
      positive_integer?(projection["stale_after_ms"]) and
      is_boolean(projection["stale"]) and
      stale_contract_valid?(projection) and
      non_negative_integer?(projection["fresh_count"]) and
      non_negative_integer?(projection["recovery_count"]) and
      non_negative_integer?(projection["candidate_count"]) and
      non_negative_integer?(projection["returned_count"]) and
      projection["fresh_count"] + projection["recovery_count"] ==
        projection["candidate_count"] and
      returned_kind_count(raw_events, "fresh") <= projection["fresh_count"] and
      returned_kind_count(raw_events, "recovery") <= projection["recovery_count"] and
      projection["limit"] == limit and is_boolean(projection["truncated"]) and
      length(raw_events) <= limit and
      projection["returned_count"] == length(raw_events) and
      projection["candidate_count"] >= length(raw_events) and
      Enum.all?(raw_events, fn event ->
        is_map(event) and event["calendar_id"] == projection["calendar_id"]
      end) and
      projection["truncated"] ==
        projection["candidate_count"] > projection["returned_count"]
  end

  defp projection_contract_valid?(_projection, _raw_events, _limit), do: false

  defp summary_contract_valid?(summary, raw_events) when is_map(summary) do
    required_fields?(summary, @raw_summary_fields) and
      Enum.all?(@raw_summary_fields, &non_negative_integer?(summary[&1])) and
      summary["returned_count"] == length(raw_events) and
      summary["candidate_count"] >= length(raw_events) and
      summary["planned_count"] == Enum.count(raw_events, &planned_event?/1) and
      summary["plan_error_count"] == Enum.count(raw_events, &(not planned_event?(&1))) and
      summary["candidate_error_count"] ==
        Enum.count(raw_events, &(&1["last_error_present"] == true)) and
      summary["autojoin_error_count"] == Enum.count(raw_events, &raw_autojoin_error?/1)
  end

  defp summary_contract_valid?(_summary, _raw_events), do: false

  defp event_contract_valid?(event) when is_map(event) do
    plan = event["plan"]
    autojoin = event["autojoin"]

    required_fields?(event, @raw_event_fields) and
      event["candidate_kind"] in @candidate_kinds and
      bounded_non_empty_string?(event["meeting_id"], 256) and
      bounded_non_empty_string?(event["event_id"], 256) and
      bounded_non_empty_string?(event["title"], 256) and
      non_negative_integer?(event["start_ms"]) and
      non_negative_integer?(event["end_ms"]) and event["end_ms"] >= event["start_ms"] and
      bounded_non_empty_string?(event["calendar_id"], 256) and
      bounded_non_empty_string?(event["calendar_item_id"], 256) and
      nullable_bounded_string?(event["meeting_plan_id"], 256) and
      event["google_meet_eligible"] == true and
      non_negative_integer?(event["candidate_updated_at"]) and
      nullable_non_negative_integer?(event["recovery_started_at"]) and
      candidate_recovery_contract_valid?(event) and
      is_boolean(event["last_error_present"]) and plan_contract_valid?(plan) and
      plan_identity_contract_valid?(event["meeting_plan_id"], plan["status"]) and
      autojoin_contract_valid?(autojoin)
  end

  defp event_contract_valid?(_event), do: false

  defp projection_state_contract_valid?(%{"state" => "active"} = projection) do
    bounded_non_empty_string?(projection["calendar_id"], 256) and
      same_nullability?(projection["updated_at"], projection["age_ms"])
  end

  defp projection_state_contract_valid?(%{"state" => state} = projection)
       when state in ~w(not_scanned unavailable) do
    is_nil(projection["calendar_id"]) and is_nil(projection["updated_at"]) and
      is_nil(projection["age_ms"]) and projection["stale"] == false and
      projection["fresh_count"] == 0 and projection["recovery_count"] == 0 and
      projection["candidate_count"] == 0 and projection["returned_count"] == 0
  end

  defp projection_state_contract_valid?(_projection), do: false

  defp stale_contract_valid?(%{"age_ms" => nil, "stale" => false}), do: true

  defp stale_contract_valid?(%{
         "age_ms" => age_ms,
         "stale_after_ms" => stale_after_ms,
         "stale" => stale
       })
       when is_integer(age_ms) and is_integer(stale_after_ms),
       do: stale == age_ms > stale_after_ms

  defp stale_contract_valid?(_projection), do: false

  defp candidate_recovery_contract_valid?(%{
         "candidate_kind" => "fresh",
         "recovery_started_at" => nil
       }),
       do: true

  defp candidate_recovery_contract_valid?(%{
         "candidate_kind" => "recovery",
         "recovery_started_at" => recovery_started_at
       }),
       do: non_negative_integer?(recovery_started_at)

  defp candidate_recovery_contract_valid?(_event), do: false

  defp plan_contract_valid?(%{"status" => status} = plan)
       when status in ~w(missing unavailable),
       do: required_fields?(plan, ["status"])

  defp plan_contract_valid?(%{"status" => status} = plan) when status in @full_plan_statuses do
    required_fields?(plan, @raw_plan_fields) and
      plan_conversation_contract_valid?(status, plan["conversation_id"]) and
      positive_integer?(plan["revision"]) and non_negative_integer?(plan["updated_at"]) and
      preparation_contract_valid?(plan["preparation"])
  end

  defp plan_contract_valid?(_plan), do: false

  defp plan_conversation_contract_valid?("planned", conversation_id),
    do: bounded_non_empty_string?(conversation_id, 256)

  defp plan_conversation_contract_valid?(_status, conversation_id),
    do: nullable_bounded_string?(conversation_id, 256)

  defp preparation_contract_valid?(preparation) when is_map(preparation) do
    required_fields?(preparation, @raw_preparation_fields) and
      nullable_non_negative_integer?(preparation["decision_at"]) and
      nullable_non_negative_integer?(preparation["publish_start_at"]) and
      nullable_non_negative_integer?(preparation["publish_deadline_at"]) and
      nullable_enum?(preparation["research_decision"], @research_decisions) and
      nullable_enum?(preparation["deadline_status"], @deadline_statuses)
  end

  defp preparation_contract_valid?(_preparation), do: false

  defp autojoin_contract_valid?(autojoin) when is_map(autojoin) do
    required_fields?(autojoin, @raw_autojoin_fields) and
      MeetingDiagnosticContract.autojoin_status?(autojoin["status"]) and
      nullable_non_negative_integer?(autojoin["start_at"]) and
      nullable_non_negative_integer?(autojoin["join_requested_at"]) and
      nullable_non_negative_integer?(autojoin["joined_at"]) and
      optional_boolean?(autojoin, "error_present") and
      optional_nullable_non_negative_integer?(autojoin, "abandoned_at")
  end

  defp autojoin_contract_valid?(_autojoin), do: false

  defp plan_identity_contract_valid?(nil, "missing"), do: true
  defp plan_identity_contract_valid?(plan_id, _status), do: is_binary(plan_id) and plan_id != ""

  defp planned_event?(event), do: get_in(event, ["plan", "status"]) == "planned"

  defp raw_autojoin_error?(event) do
    autojoin = event["autojoin"]

    MeetingDiagnosticContract.autojoin_error_status?(autojoin["status"]) or
      autojoin["error_present"] == true or is_integer(autojoin["abandoned_at"])
  end

  defp returned_kind_count(events, kind) do
    Enum.count(events, fn event -> is_map(event) and event["candidate_kind"] == kind end)
  end

  defp runtime(runtime) when is_map(runtime) do
    %{
      "status" => enum(runtime["status"], @runtime_statuses, "not_configured"),
      "configured" => boolean(runtime["configured"]),
      "running" => boolean(runtime["running"]),
      "scan_interval_ms" => integer(runtime["scan_interval_ms"])
    }
  end

  defp runtime(_runtime), do: %{}

  defp projection(projection, limit, returned_count) when is_map(projection) do
    candidate_count = count(projection["candidate_count"])
    age_ms = integer(projection["age_ms"])
    stale_after_ms = integer(projection["stale_after_ms"])

    %{
      "state" => enum(projection["state"], @projection_states, "unavailable"),
      "calendar_id" => safe_string(projection["calendar_id"], 256),
      "updated_at" => integer(projection["updated_at"]),
      "age_ms" => age_ms,
      "stale_after_ms" => stale_after_ms,
      "stale" =>
        is_integer(age_ms) and is_integer(stale_after_ms) and stale_after_ms > 0 and
          age_ms > stale_after_ms,
      "fresh_count" => count(projection["fresh_count"]),
      "recovery_count" => count(projection["recovery_count"]),
      "candidate_count" => candidate_count,
      "returned_count" => returned_count,
      "limit" => limit,
      "truncated" => boolean(projection["truncated"]) or candidate_count > returned_count
    }
  end

  defp projection(_projection, limit, _returned_count),
    do: %{
      "state" => "unavailable",
      "candidate_count" => 0,
      "returned_count" => 0,
      "limit" => limit,
      "truncated" => false
    }

  defp summary(summary, returned_count) when is_map(summary) do
    %{
      "candidate_count" => count(summary["candidate_count"]),
      "returned_count" => returned_count,
      "planned_count" => count(summary["planned_count"]),
      "plan_error_count" => count(summary["plan_error_count"]),
      "candidate_error_count" => count(summary["candidate_error_count"]),
      "autojoin_error_count" => count(summary["autojoin_error_count"])
    }
  end

  defp summary(_summary, _returned_count), do: empty_summary()

  defp empty_summary do
    %{
      "candidate_count" => 0,
      "returned_count" => 0,
      "planned_count" => 0,
      "plan_error_count" => 0,
      "candidate_error_count" => 0,
      "autojoin_error_count" => 0
    }
  end

  defp event(event) when is_map(event) do
    %{
      "candidate_kind" => enum(event["candidate_kind"], @candidate_kinds, "fresh"),
      "meeting_id" => safe_string(event["meeting_id"], 256),
      "event_id" => safe_string(event["event_id"], 256),
      "title" => safe_title(event["title"]),
      "start_ms" => integer(event["start_ms"]),
      "end_ms" => integer(event["end_ms"]),
      "calendar_id" => safe_string(event["calendar_id"], 256),
      "calendar_item_id" => safe_string(event["calendar_item_id"], 256),
      "meeting_plan_id" => safe_string(event["meeting_plan_id"], 256),
      "google_meet_eligible" => boolean(event["google_meet_eligible"]),
      "candidate_updated_at" => integer(event["candidate_updated_at"]),
      "recovery_started_at" => integer(event["recovery_started_at"]),
      "last_error_present" => boolean(event["last_error_present"]),
      "plan" => plan(event["plan"]),
      "autojoin" => autojoin(event["autojoin"])
    }
  end

  defp event(_event), do: event(%{})

  defp plan(plan) when is_map(plan) do
    %{
      "status" => enum(plan["status"], @plan_statuses, "unknown"),
      "conversation_id" => safe_string(plan["conversation_id"], 256),
      "revision" => integer(plan["revision"]),
      "updated_at" => integer(plan["updated_at"]),
      "preparation" => preparation(plan["preparation"])
    }
  end

  defp plan(_plan), do: %{"status" => "unknown", "preparation" => %{}}

  defp preparation(preparation) when is_map(preparation) do
    %{
      "decision_at" => integer(preparation["decision_at"]),
      "publish_start_at" => integer(preparation["publish_start_at"]),
      "publish_deadline_at" => integer(preparation["publish_deadline_at"]),
      "research_decision" =>
        enum(preparation["research_decision"], @research_decisions, "pending"),
      "deadline_status" => enum(preparation["deadline_status"], @deadline_statuses, "pending")
    }
  end

  defp preparation(_preparation), do: %{}

  defp autojoin(autojoin) when is_map(autojoin) do
    %{
      "status" => MeetingDiagnosticContract.autojoin_status(autojoin["status"]),
      "start_at" => integer(autojoin["start_at"]),
      "join_requested_at" => integer(autojoin["join_requested_at"]),
      "joined_at" => integer(autojoin["joined_at"]),
      "abandoned_at" => integer(autojoin["abandoned_at"]),
      "error_present" => boolean(autojoin["error_present"])
    }
  end

  defp autojoin(_autojoin), do: %{"status" => "unavailable", "error_present" => false}

  defp safe_title(value) do
    case safe_string(value, 256) do
      nil -> "Calendar meeting"
      "" -> "Calendar meeting"
      title -> title
    end
  end

  defp safe_reason(reason) when reason in @unavailable_reasons, do: reason

  defp safe_reason(_reason), do: "calendar_status_unavailable"

  defp safe_string(value, max_bytes) when is_binary(value) do
    value
    |> redact_meet_urls()
    |> String.slice(0, max_bytes)
  end

  defp safe_string(_value, _max_bytes), do: nil

  defp enum(value, allowed, fallback) when is_binary(value),
    do: if(value in allowed, do: value, else: fallback)

  defp enum(_value, _allowed, fallback), do: fallback
  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil
  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0
  defp boolean(value), do: value == true
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp nullable_non_negative_integer?(nil), do: true
  defp nullable_non_negative_integer?(value), do: non_negative_integer?(value)

  defp bounded_non_empty_string?(value, max_length) when is_binary(value),
    do: value != "" and String.length(value) <= max_length

  defp bounded_non_empty_string?(_value, _max_length), do: false

  defp nullable_bounded_string?(nil, _max_length), do: true

  defp nullable_bounded_string?(value, max_length),
    do: bounded_non_empty_string?(value, max_length)

  defp nullable_enum?(nil, _allowed), do: true
  defp nullable_enum?(value, allowed), do: value in allowed

  defp required_fields?(map, fields),
    do: is_map(map) and Enum.all?(fields, &Map.has_key?(map, &1))

  defp same_nullability?(left, right), do: is_nil(left) == is_nil(right)

  defp optional_boolean?(map, key),
    do: not Map.has_key?(map, key) or is_boolean(map[key])

  defp optional_nullable_non_negative_integer?(map, key),
    do: not Map.has_key?(map, key) or nullable_non_negative_integer?(map[key])
end
