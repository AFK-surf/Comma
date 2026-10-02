defmodule SalixAgent.SubscriptionLog do
  @moduledoc false
  require Logger

  @ids ~w(tenant_id agent_id session_id account_id worker_request_id)a
  @numbers ~w(timeout_ms candidate_count ready_count cooling_count retry_after_ms duration_ms host_frames host_bytes host_first_frame_ms active_calls http_status)a
  @codes ~w(not_found conflict unavailable not_configured authorization_unavailable invalid_input request_too_large worker_busy worker_unavailable worker_down worker_timeout worker_first_event_timeout worker_idle_timeout worker_cancelled worker_operation_failed model_required invalid_provider provider_mismatch invalid_request invalid_credential prepare_failed quota_unavailable reset_unavailable reset_pending reset_in_progress exchange_failed subscription_request_failed upstream_stream_failed context_length_exceeded account_proxy_timeout response_too_large invalid_protocol caller_cancelled exception storage_error provider_error unknown)
  @operations ~w(/normalize /prepare /quota /quota/reset /oauth/begin /oauth/device/begin /oauth/device/poll /oauth/exchange /v1/responses /v1/responses/compact /v1/messages /v1/chat/completions /v1/images/generations /v1/images/edits)

  def emit(event, fields \\ []) do
    fields = sanitize(fields)
    level = if fields[:outcome] in ["error", "exception"], do: :warning, else: :info
    Logger.log(level, event, fields)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def context(fields, fun) do
    previous = Logger.metadata()
    Logger.metadata(sanitize(fields))

    try do
      fun.()
    after
      Logger.reset_metadata(previous)
    end
  end

  def span(event, fields, fun, extra \\ fn -> [] end) do
    started = System.monotonic_time(:millisecond)
    emit(event <> "_start", fields)

    try do
      result = fun.()
      finish(event, fields, result_fields(result), started, extra)
      result
    catch
      kind, reason ->
        finish(event, fields, [outcome: "exception", error_code: "exception"], started, extra)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp finish(event, fields, result, started, extra) do
    emit(
      event <> "_finish",
      fields ++ result ++ [duration_ms: System.monotonic_time(:millisecond) - started] ++ extra.()
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def result_fields({:error, status, code, _}),
    do: [outcome: "error", http_status: status, error_code: code]

  def result_fields({:error, {:worker_rejected, status, code}}),
    do: [outcome: "error", http_status: status, error_code: code]

  def result_fields({:error, reason}) when is_atom(reason),
    do: [outcome: "error", error_code: Atom.to_string(reason)]

  def result_fields({:error, %{} = reason}),
    do: [
      outcome: "error",
      error_code: "provider_error",
      http_status: Map.get(reason, "status"),
      retry_after_ms: Map.get(reason, "retry_after_ms")
    ]

  def result_fields({:error, _}), do: [outcome: "error", error_code: "unknown"]
  def result_fields(_), do: [outcome: "ok"]

  def frame(stats, bytes, started) do
    if :atomics.add_get(stats, 1, 1) == 1 do
      :atomics.put(stats, 3, System.monotonic_time(:millisecond) - started + 1)
    end

    :atomics.add(stats, 2, byte_size(bytes))
    :ok
  rescue
    _ -> :ok
  end

  def stats(stats) do
    [
      host_frames: :atomics.get(stats, 1),
      host_bytes: :atomics.get(stats, 2),
      host_first_frame_ms: if(:atomics.get(stats, 3) > 0, do: :atomics.get(stats, 3) - 1)
    ]
  end

  def sanitize(fields) do
    Enum.flat_map(fields, fn
      {key, value} when key in @ids and is_binary(value) ->
        if byte_size(value) <= 256 and Regex.match?(~r/\A[A-Za-z0-9_:-]+\z/, value),
          do: [{key, value}],
          else: []

      {key, value} when key in @numbers and is_integer(value) and value >= 0 ->
        [{key, value}]

      {:provider, value} ->
        if SalixAgent.AccountPool.provider?(value), do: [provider: value], else: []

      {:stream, value} when is_boolean(value) ->
        [stream: value]

      {:operation, value} when value in @operations ->
        [operation: value]

      {:outcome, value} when value in ["ok", "error", "exception", "cancelled"] ->
        [outcome: value]

      {:error_code, value} when value in @codes ->
        [error_code: value]

      {:error_code, _} ->
        [error_code: "unknown"]

      _ ->
        []
    end)
  rescue
    _ -> []
  end
end
