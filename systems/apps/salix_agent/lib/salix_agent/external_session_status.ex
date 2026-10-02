defmodule SalixAgent.ExternalSessionStatus do
  @moduledoc false

  alias SalixAgent.SessionStorageRevision
  alias SalixStore.{Keys, S3}
  alias SalixAgent.ExternalSessionLifecycleObservation

  @legacy_schema_version 1
  @schema_version 2
  # The exclusive v1-writer drain, exact-CAS v1 certification, forward-only
  # v2 boundary, and revision rotation consumed by Workflow recovery are
  # modeled in tla/salix/SessionActivityVersion.tla. The release boundary is
  # salix-20260807000101; this schema is not rolling-writer compatible.
  @starting_timeout_seconds 30
  @wait_projection_cas_retries 3
  @work_states ~w(running settled failed)
  @statuses ~w(idle starting running waiting failed unknown)
  @terminal_issues ~w(quota_exhausted rate_limited authentication_required model_unavailable recovery_exhausted runtime_failed insufficient_credits account_inactive missing_account)

  @doc false
  def schema_version, do: @schema_version

  def create(agent_id, session_id, timestamp) do
    status = base(session_id, timestamp, "idle")

    case S3.put(key(agent_id, session_id), Jason.encode!(status), if_none_match: "*") do
      {:ok, _} -> {:ok, status}
      {:error, :precondition_failed} -> get(agent_id, session_id)
      {:error, _} = error -> error
    end
  end

  def get(agent_id, session_id) do
    path = key(agent_id, session_id)

    with {:ok, status, etag} <- read_current(path, session_id),
         {:ok, status} <- certify_current_revision(path, status, etag, session_id) do
      {:ok, expire_starting(status, now())}
    end
  end

  def dispatch_started(agent_id, session_id, dispatch_id, connector_run_id, timestamp) do
    {_mode, result} =
      dispatch_started_with_mode(agent_id, session_id, dispatch_id, connector_run_id, timestamp)

    result
  end

  # The observed mode survives a failed projection write. A failed read leaves it unknown.
  def dispatch_started_with_mode(agent_id, session_id, dispatch_id, connector_run_id, timestamp) do
    path = key(agent_id, session_id)

    with {:ok, current, etag} <- current(path, session_id),
         next <-
           current
           |> expire_starting(now())
           |> start_dispatch(dispatch_id, connector_run_id, timestamp)
           |> then(&put_activity_revision(current, &1)),
         :ok <- validate(next, session_id) do
      result =
        case S3.put(path, Jason.encode!(next), if_match: etag) do
          {:ok, _} -> {:ok, next}
          {:error, _} = error -> error
        end

      {next["status"] == "running", result}
    else
      {:error, _} = error -> {:unknown, error}
    end
  end

  def dispatch_accepted(agent_id, session_id, dispatch_id, execution_id, timestamp) do
    update(
      agent_id,
      session_id,
      &accept_execution(&1, dispatch_id, execution_id, timestamp)
    )
  end

  def dispatch_failed(
        agent_id,
        session_id,
        dispatch_id,
        timestamp,
        source_watermark \\ nil,
        projection_target \\ nil,
        terminal \\ nil
      ) do
    update_with_observation(agent_id, session_id, fn current ->
      {next, mapping} =
        dispatch_failure_transition(current, projection_target, dispatch_id, terminal, timestamp)

      next = put_lifecycle_record(next, source_watermark)

      observation = %{
        source: "server_dispatch_failure",
        mapping: mapping,
        agent_id: agent_id,
        session_id: session_id,
        connector_run_id: next["connector_run_id"],
        dispatch_id: dispatch_id,
        execution_id: next["execution_id"],
        record_id: source_watermark,
        status: next["status"],
        issue: next["issue"],
        terminal: terminal
      }

      {next, observation, :info}
    end)
  end

  def apply_runtime_event(
        agent_id,
        session_id,
        event,
        record_id,
        connector_run_id,
        projection_target \\ nil
      )
      when is_map(event) do
    work_state = event["work_state"]

    if work_state in @work_states do
      update_with_observation(agent_id, session_id, fn current ->
        {next, mapping} =
          current
          |> align_with_projection_target(event, projection_target)
          |> apply_work_state(event, record_id, connector_run_id)

        next = put_projection_record(next, record_id)

        observation = %{
          source: "connector_event",
          mapping: mapping,
          agent_id: agent_id,
          session_id: session_id,
          connector_run_id: connector_run_id,
          dispatch_id: event["dispatch_id"],
          execution_id: event["execution_id"],
          record_id: record_id,
          work_state: work_state,
          status: next["status"],
          issue: next["issue"]
        }

        level = if mapping == "applied" and work_state == "running", do: :debug, else: :info
        {next, observation, level}
      end)
    else
      result = get(agent_id, session_id)

      if observable_value?(work_state) do
        status =
          case result do
            {:ok, current} -> current
            _other -> %{}
          end

        ExternalSessionLifecycleObservation.lifecycle(%{
          source: "connector_event",
          mapping: "ignored_invalid_work_state",
          agent_id: agent_id,
          session_id: session_id,
          connector_run_id: connector_run_id,
          dispatch_id: event["dispatch_id"],
          execution_id: event["execution_id"],
          record_id: record_id,
          work_state: work_state,
          status: status["status"],
          issue: status["issue"]
        })
      end

      result
    end
  end

  @doc false
  # Modeled in tla/salix/ExternalRuntimeEventProjection.tla. Preview events in
  # durable record order so the first event at a new dispatch installs its
  # execution, then select at most one latest advancing event for that execution.
  def plan_runtime_event(agent_id, session_id, candidates, projection_target)
      when is_list(candidates) do
    with {:ok, current} <- get(agent_id, session_id) do
      {project, ignored, _preview} =
        Enum.reduce(candidates, {nil, nil, current}, fn candidate, {project, ignored, preview} ->
          event = candidate.event

          {next, mapping} =
            case projection_target_mapping(projection_target, event, candidate.record_id) do
              nil ->
                preview
                |> align_with_projection_target(event, projection_target)
                |> apply_work_state(
                  event,
                  candidate.record_id,
                  candidate.connector_run_id
                )

              mapping ->
                {preview, mapping}
            end

          if mapping == "applied" do
            {candidate, ignored, next}
          else
            {project, ignored || {candidate, mapping, next}, next}
          end
        end)

      case {project, ignored} do
        {candidate, _ignored} when is_map(candidate) -> {:ok, candidate, nil}
        {nil, {candidate, mapping, status}} -> {:ok, nil, {candidate, mapping, status}}
        {nil, nil} -> {:ok, nil, nil}
      end
    end
  end

  @doc false
  def runtime_event_candidate?(target, event, record_id),
    do: is_nil(projection_target_mapping(target, event, record_id))

  defp projection_target_mapping(target, event, record_id) when is_map(target) do
    cond do
      present?(target["dispatch_id"]) and target["dispatch_id"] != event["dispatch_id"] ->
        "ignored_dispatch_mismatch"

      present?(target["execution_id"]) and target["execution_id"] != event["execution_id"] ->
        "ignored_execution_mismatch"

      present?(target["watermark"]) and target["watermark"] > record_id ->
        "ignored_stale_watermark"

      true ->
        nil
    end
  end

  defp projection_target_mapping(_target, _event, _record_id), do: nil

  def apply_events(
        agent_id,
        session_id,
        events,
        timestamp,
        source_record_watermark \\ nil
      )
      when is_list(events) do
    wait_events = Enum.filter(events, &(&1["type"] in ["wait_set", "wait_clear"]))

    if wait_events == [] do
      get(agent_id, session_id)
    else
      apply_wait_events(
        agent_id,
        session_id,
        wait_events,
        timestamp,
        source_record_watermark,
        @wait_projection_cas_retries
      )
    end
  end

  def complete(agent_id, session_id, timestamp, watermark \\ nil),
    do: set_terminal(agent_id, session_id, "idle", nil, timestamp, watermark)

  def fail(agent_id, session_id, timestamp, watermark \\ nil, error \\ nil) do
    update_with_observation(agent_id, session_id, fn current ->
      financial? = SalixAgent.BillingAvailability.denied?(error)

      active? =
        present?(current["dispatch_id"]) and
          (current["work_status"] == "starting" or
             (current["work_status"] == "running" and present?(current["execution_id"])))

      next =
        cond do
          financial? and active? ->
            put_projection_record(current, watermark)

          financial? ->
            current
            |> set_work_status("failed", timestamp, error["reason"])
            |> put_message(error["message"])
            |> put_projection_record(watermark)

          true ->
            current
            |> set_work_status("failed", timestamp, "runtime_failed")
            |> put_lifecycle_record(watermark)
        end

      observation = %{
        source: "server_dispatch_failure",
        mapping: if(financial? and active?, do: "preserved_active_execution", else: "applied"),
        agent_id: agent_id,
        session_id: session_id,
        connector_run_id: next["connector_run_id"],
        dispatch_id: next["dispatch_id"],
        execution_id: next["execution_id"],
        record_id: watermark,
        status: next["status"],
        issue: next["issue"],
        terminal: true
      }

      {next, observation, :info}
    end)
  end

  def public(status, runtime_availability) when is_map(status) do
    status
    |> expire_starting(now())
    |> invalidate_lost_observation(runtime_availability)
    |> Map.take(~w(session_id status status_updated_at activity_revision issue message wait))
    |> Map.put("runtime_availability", runtime_availability)
    |> compact()
  end

  def unknown(session_id, timestamp \\ 0) do
    base(session_id, timestamp, "unknown")
    |> Map.put("issue", "runtime_status_unknown")
  end

  # ExternalRuntimeEventProjection.tla: exact execution fence plus one
  # record-floor-authorized handoff at a new dispatch boundary.
  defp align_with_projection_target(current, event, target) when is_map(target) do
    if target["dispatch_id"] == event["dispatch_id"] and
         (not present?(target["execution_id"]) or
            target["execution_id"] == event["execution_id"]) do
      current = Map.put(current, "dispatch_id", event["dispatch_id"])

      cond do
        not present?(current["execution_id"]) ->
          Map.put(current, "execution_id", event["execution_id"])

        current["execution_id"] == event["execution_id"] ->
          current

        present?(target["record_floor"]) and
            (not present?(current["source_record_watermark"]) or
               current["source_record_watermark"] <= target["record_floor"]) ->
          Map.put(current, "execution_id", event["execution_id"])

        true ->
          current
      end
    else
      current
    end
  end

  defp align_with_projection_target(current, _event, _target), do: current

  defp apply_work_state(current, event, record_id, connector_run_id) do
    dispatch_id = event["dispatch_id"]
    execution_id = event["execution_id"]
    current_watermark = current["source_record_watermark"] || ""

    cond do
      not present?(dispatch_id) or not present?(execution_id) ->
        {current, "ignored_missing_identity"}

      current["dispatch_id"] != dispatch_id ->
        {current, "ignored_dispatch_mismatch"}

      present?(current["execution_id"]) and current["execution_id"] != execution_id ->
        {current, "ignored_execution_mismatch"}

      present?(record_id) and current_watermark >= record_id ->
        {current, "ignored_stale_watermark"}

      true ->
        timestamp = event_timestamp(event)

        next =
          current
          |> Map.put("execution_id", execution_id)
          |> Map.put("connector_run_id", connector_run_id)
          |> Map.put("source_record_watermark", record_id)
          |> Map.put("source_work_state", event["work_state"])
          |> set_work_status(work_status(event["work_state"]), timestamp, work_issue(event))
          |> put_message(work_message(event))

        {next, "applied"}
    end
  end

  defp dispatch_failure_transition(current, target, dispatch_id, terminal, timestamp) do
    cond do
      is_map(target) and target["dispatch_id"] == dispatch_id and
        not present?(target["execution_id"]) and terminal != false ->
        next =
          current
          |> Map.put("dispatch_id", dispatch_id)
          |> Map.put("execution_id", nil)
          |> set_work_status("failed", timestamp, "runtime_failed")

        {next, "applied"}

      is_map(target) and terminal == false ->
        {current, "ignored_non_terminal"}

      is_map(target) and target["dispatch_id"] != dispatch_id ->
        {current, "ignored_projection_target_mismatch"}

      is_map(target) and present?(target["execution_id"]) ->
        {current, "ignored_execution_already_started"}

      current["dispatch_id"] != dispatch_id ->
        {current, "ignored_dispatch_mismatch"}

      present?(current["execution_id"]) ->
        {current, "ignored_execution_already_started"}

      true ->
        {set_work_status(current, "failed", timestamp, "runtime_failed"), "applied"}
    end
  end

  defp accept_execution(current, dispatch_id, execution_id, timestamp)
       when is_binary(execution_id) do
    cond do
      current["dispatch_id"] != dispatch_id ->
        current

      not present?(current["execution_id"]) ->
        Map.put(current, "execution_id", execution_id)

      current["execution_id"] == execution_id ->
        current

      true ->
        current
        |> Map.put("execution_id", execution_id)
        |> Map.put("status", "starting")
        |> Map.put("work_status", "starting")
        |> Map.put("status_updated_at", timestamp)
        |> Map.put("starting_expires_at", timestamp + starting_timeout_seconds())
    end
  end

  defp accept_execution(current, _dispatch_id, _execution_id, _timestamp), do: current

  defp start_dispatch(current, dispatch_id, connector_run_id, timestamp) do
    active? = current["status"] == "running" and present?(current["execution_id"])

    current =
      current
      |> Map.put("dispatch_id", dispatch_id)
      |> Map.put("connector_run_id", connector_run_id)
      |> Map.delete("issue")
      |> Map.delete("message")

    if active? do
      current
    else
      current
      |> Map.put("execution_id", nil)
      |> Map.put("source_work_state", nil)
      |> Map.put("status", "starting")
      |> Map.put("work_status", "starting")
      |> Map.put("status_updated_at", timestamp)
      |> Map.put("starting_expires_at", timestamp + starting_timeout_seconds())
    end
  end

  defp work_status("running"), do: "running"
  defp work_status("settled"), do: "idle"
  defp work_status("failed"), do: "failed"

  defp work_issue(%{"work_state" => "failed", "issue" => issue})
       when issue in @terminal_issues,
       do: issue

  defp work_issue(%{"work_state" => "failed"}), do: "runtime_failed"
  defp work_issue(_event), do: nil

  defp work_message(%{"work_state" => "failed", "issue" => issue, "message" => message})
       when issue in @terminal_issues and is_binary(message),
       do: message

  defp work_message(_event), do: nil

  defp set_work_status(current, status, timestamp, issue) do
    current
    |> Map.put("work_status", status)
    |> Map.put("status_updated_at", timestamp)
    |> Map.delete("starting_expires_at")
    |> Map.delete("message")
    |> put_issue(issue)
    |> set_public_status(timestamp)
  end

  defp set_public_status(current, timestamp) do
    work_status = current["work_status"] || "unknown"

    status =
      cond do
        work_status in ~w(starting running failed) -> work_status
        is_map(current["wait"]) -> "waiting"
        work_status in ~w(idle unknown) -> work_status
        true -> "unknown"
      end

    current
    |> Map.put("status", status)
    |> then(fn next ->
      if current["status"] == status,
        do: next,
        else: Map.put(next, "status_updated_at", timestamp)
    end)
    |> put_issue(if(status == "unknown", do: "runtime_status_unknown", else: current["issue"]))
  end

  defp refresh_wait_timestamp(%{"status" => "waiting"} = status, timestamp),
    do: Map.put(status, "status_updated_at", timestamp)

  defp refresh_wait_timestamp(status, _timestamp), do: status

  defp apply_wait_event(status, event, fallback) do
    timestamp = event_timestamp(event, fallback)

    case event["type"] do
      "wait_set" ->
        status
        |> put_issue(if(status["work_status"] == "failed", do: status["issue"]))
        |> Map.put("wait", minimal_wait(event["wait"]))
        |> set_public_status(timestamp)
        |> refresh_wait_timestamp(timestamp)

      "wait_clear" ->
        status
        |> Map.put("wait", nil)
        |> set_public_status(timestamp)
    end
  end

  # Modeled in tla/salix/ExternalRuntimeToolWake.tla. Wait projection is an
  # independent dimension from Connector lifecycle projection: a clean CAS
  # conflict rebases the exact wait event batch on a fresh status read, while
  # the wait-specific record watermark prevents an older wait_set/wait_clear
  # retry from overwriting a newer wait transition. Ambiguous and all other
  # storage outcomes retain their original shape and are never retried here.
  defp apply_wait_events(
         agent_id,
         session_id,
         wait_events,
         timestamp,
         source_record_watermark,
         retries_left
       ) do
    result =
      update(agent_id, session_id, fn current ->
        if newer_wait_projection?(current, source_record_watermark) do
          wait_events
          |> Enum.reduce(current, &apply_wait_event(&2, &1, timestamp))
          |> put_wait_projection_record(source_record_watermark)
          |> put_projection_record(source_record_watermark)
        else
          current
        end
      end)

    case result do
      {:error, :precondition_failed} when retries_left > 0 ->
        apply_wait_events(
          agent_id,
          session_id,
          wait_events,
          timestamp,
          source_record_watermark,
          retries_left - 1
        )

      other ->
        other
    end
  end

  defp newer_wait_projection?(_status, watermark) when not is_binary(watermark), do: true

  defp newer_wait_projection?(status, watermark),
    do: (status["wait_projection_watermark"] || "") < watermark

  defp put_source_record(status, watermark),
    do: put_watermark(status, "source_record_watermark", watermark)

  defp put_projection_record(status, watermark),
    do: put_watermark(status, "projection_watermark", watermark)

  defp put_wait_projection_record(status, watermark),
    do: put_watermark(status, "wait_projection_watermark", watermark)

  defp put_lifecycle_record(status, watermark),
    do: status |> put_source_record(watermark) |> put_projection_record(watermark)

  defp put_watermark(status, key, watermark) when is_binary(watermark),
    do: if((status[key] || "") < watermark, do: Map.put(status, key, watermark), else: status)

  defp put_watermark(status, _key, _watermark), do: status

  defp expire_starting(
         %{"status" => "starting", "starting_expires_at" => expires_at} = status,
         at
       )
       when is_integer(expires_at) and expires_at <= at do
    status
    |> Map.put("status", "unknown")
    |> Map.put("work_status", "unknown")
    |> Map.put("issue", "native_start_unconfirmed")
    |> Map.put("status_updated_at", expires_at)
  end

  defp expire_starting(status, _at), do: status

  defp observable_value?(nil), do: false
  defp observable_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp observable_value?(_value), do: true

  defp invalidate_lost_observation(status, availability) do
    availability = availability || %{"status" => "unknown"}
    observed_run = status["connector_run_id"]
    current_run = availability["connector_run_id"]

    lost? =
      status["status"] in ~w(starting running) and
        (availability["status"] in ~w(disconnected missing) or
           (present?(observed_run) and present?(current_run) and observed_run != current_run))

    if lost? do
      status
      |> Map.put("status", "unknown")
      |> Map.put("issue", "runtime_observation_lost")
      |> Map.put("status_updated_at", invalidation_timestamp(status, availability))
    else
      status
    end
  end

  defp update(agent_id, session_id, fun) do
    path = key(agent_id, session_id)

    with {:ok, current, etag} <- current(path, session_id),
         next <- current |> expire_starting(now()) |> fun.(),
         next <- put_activity_revision(current, next),
         :ok <- validate(next, session_id),
         {:ok, _} <- S3.put(path, Jason.encode!(next), if_match: etag) do
      {:ok, next}
    end
  end

  defp update_with_observation(agent_id, session_id, fun) do
    path = key(agent_id, session_id)

    with {:ok, current, etag} <- current(path, session_id),
         {next, observation, level} <- current |> expire_starting(now()) |> fun.(),
         next <- put_activity_revision(current, next),
         :ok <- validate(next, session_id),
         {:ok, _} <- S3.put(path, Jason.encode!(next), if_match: etag) do
      ExternalSessionLifecycleObservation.lifecycle(observation, level)
      {:ok, next}
    end
  end

  defp current(path, session_id) do
    case read_current(path, session_id) do
      {:ok, _status, _etag} = current ->
        current

      {:error, :not_found} ->
        timestamp = now()
        status = unknown(session_id, timestamp)

        case S3.put(path, Jason.encode!(status), if_none_match: "*") do
          {:ok, _} -> current(path, session_id)
          {:error, :precondition_failed} -> current(path, session_id)
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp read_current(path, session_id) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(path),
         {:ok, status} <- Jason.decode(body),
         :ok <- validate(status, session_id) do
      {:ok, status, etag}
    end
  end

  defp validate(status, session_id) do
    cond do
      status["schema_version"] not in [@legacy_schema_version, @schema_version] ->
        {:error, :invalid_external_session_status}

      status["schema_version"] == @schema_version and
          not valid_revision?(status["activity_revision"]) ->
        {:error, :invalid_external_session_status}

      status["session_id"] != session_id ->
        {:error, :session_id_mismatch}

      status["status"] not in @statuses ->
        {:error, :invalid_external_session_status}

      status["source_work_state"] not in [nil | @work_states] ->
        {:error, :invalid_external_session_status}

      not valid_message?(status["message"]) ->
        {:error, :invalid_external_session_status}

      true ->
        :ok
    end
  end

  defp set_terminal(agent_id, session_id, status, issue, timestamp, watermark) do
    update(agent_id, session_id, fn current ->
      current |> set_work_status(status, timestamp, issue) |> put_lifecycle_record(watermark)
    end)
  end

  defp base(session_id, timestamp, status) do
    %{
      "schema_version" => @schema_version,
      "session_id" => session_id,
      "status" => status,
      "work_status" => status,
      "source_work_state" => nil,
      "status_updated_at" => timestamp,
      "activity_revision" => SessionStorageRevision.new(),
      "wait" => nil,
      "wait_projection_watermark" => nil,
      "source_record_watermark" => nil,
      "projection_watermark" => nil
    }
  end

  defp minimal_wait(wait) when is_map(wait),
    do: Map.take(wait, ~w(wait_id reason deadline_at remaining_seconds source))

  defp minimal_wait(_wait), do: %{}

  defp event_timestamp(event) do
    event_timestamp(event, now())
  end

  defp event_timestamp(event, fallback) do
    case event["created_at"] || event["updated_at"] do
      value when is_integer(value) and value > 10_000_000_000 -> div(value, 1_000)
      value when is_integer(value) -> value
      _ -> fallback
    end
  end

  defp invalidation_timestamp(status, availability) do
    case availability["updated_at"] do
      timestamp when is_integer(timestamp) and timestamp > 0 -> timestamp
      _other -> status["status_updated_at"] || 0
    end
  end

  defp starting_timeout_seconds,
    do:
      Application.get_env(
        :salix_agent,
        :external_runtime_starting_timeout_seconds,
        @starting_timeout_seconds
      )

  defp put_issue(map, nil), do: Map.delete(map, "issue")
  defp put_issue(map, issue), do: Map.put(map, "issue", issue)
  defp put_message(map, nil), do: Map.delete(map, "message")
  defp put_message(map, message), do: Map.put(map, "message", message)
  defp valid_message?(nil), do: true

  defp valid_message?(message) when is_binary(message),
    do: String.valid?(message) and String.trim(message) != "" and byte_size(message) <= 300

  defp valid_message?(_message), do: false

  defp certify_current_revision(
         _path,
         %{"schema_version" => @schema_version} = status,
         _etag,
         _session_id
       ),
       do: {:ok, status}

  defp certify_current_revision(path, status, etag, session_id) do
    certified =
      status
      |> Map.put("schema_version", @schema_version)
      |> Map.put("activity_revision", SessionStorageRevision.new())

    with :ok <- validate(certified, session_id),
         {:ok, _} <- S3.put(path, Jason.encode!(certified), if_match: etag) do
      {:ok, certified}
    else
      {:error, :precondition_failed} -> {:error, :stale_external_session_status}
      {:error, _} = error -> error
    end
  end

  defp put_activity_revision(current, next) do
    revision =
      if valid_revision?(current["activity_revision"]) and
           monitored_activity_signature(current) == monitored_activity_signature(next),
         do: current["activity_revision"],
         else: SessionStorageRevision.new()

    next
    |> Map.put("schema_version", @schema_version)
    |> Map.put("activity_revision", revision)
  end

  defp monitored_activity_signature(%{"status" => "idle"}), do: :stopped

  defp monitored_activity_signature(%{"status" => "failed"} = status) do
    case status["issue"] do
      issue when is_binary(issue) ->
        case String.trim(issue) do
          "" -> {:error, "runtime_failed"}
          issue when issue in @terminal_issues -> {:error, issue}
          _unmonitored_issue -> :active
        end

      _missing ->
        {:error, "runtime_failed"}
    end
  end

  defp monitored_activity_signature(_status), do: :active

  defp valid_revision?(revision), do: is_binary(revision) and revision != ""
  defp compact(map), do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp key(agent_id, session_id),
    do: Keys.agent_external_runtime_session_status(agent_id, session_id)

  defp now, do: System.system_time(:second)
end
