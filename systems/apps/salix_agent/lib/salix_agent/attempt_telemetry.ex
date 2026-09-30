defmodule SalixAgent.AttemptTelemetry do
  @moduledoc """
  Failed provider attempts — why a logical model request needed more than
  one try, or why it gave up.

  `llm_call_events_v2` records one row per logical request with its final
  status and the number of attempts; the reasons the earlier attempts
  failed only reached the pod log, which staging keeps for hours. A request
  whose job is killed at the deadline before any attempt succeeds never
  writes that row at all: on 2026-09-14 one Router failed 18 rounds in a
  row at the 600 s deadline and nothing in ClickHouse could say why.

  Emitted from Round's retry loop through the non-billable observability
  path (`SalixAgent.Observability.llm_attempt/1`): one fact per failed
  attempt, best-effort, every failure swallowed. `outcome` is what the loop
  did next: `retry` after `delay_ms`, `abandoned` because the delay would
  outlast the request deadline, or `exhausted` when no attempt follows.

  ## What the row may say

  `reason` is a summary drawn from a closed vocabulary (`vocabulary/0`):
  the provider's error `type` / `code` / `status` when the body is JSON and
  the value is a listed provider code (`rate_limit_error`,
  `RESOURCE_EXHAUSTED`), the kernel's fixed reason and provider-status
  words (`output_token_limit`, `incomplete`), a listed transport failure
  named in the transport reason (`stream_idle_timeout`, `closed`), a listed
  exit reason of a caught exit (`timeout`, `noproc`). Anything not in the
  vocabulary is dropped: provider message text, raw bodies, unlisted codes,
  exception messages and exit values never enter the fact, and a string
  that merely looks like an identifier is not a code. The raw detail is
  already sealed per attempt at the encrypted archive's `llm_response`
  boundary (`SalixAgent.EventArchive.Emit.llm_response/6`), which is where
  an operator with the key goes for it.

  ## The attempt killed at the deadline

  A fact is emitted when an attempt RETURNS to the loop, and a job killed at
  its deadline — `Process.exit(pid, :kill)` is untrappable — never returns.
  The session actor that kills it emits that attempt instead, through
  `emit_killed/4`, with outcome `killed` and what the stream had received
  before the kill (`SalixAgent.StreamProgress`): when the first and last
  response bytes arrived, how many, and whether any text, tool-argument or
  reasoning delta ever reached the round. That row is what tells a provider
  still writing an answer at the deadline from one heartbeating over an
  empty stream; `agent_run_events_v2` (`actor_failed`) only says the round
  was lost. A call that hangs before any body arrives (or outside
  `SalixLlm.Http`) leaves the body columns null.
  """

  require Logger

  @max_words 6

  # Failure classes the provider seam assigns (`VerifiedKernel.Provider.Error`).
  @categories ~w(transport_error retryable_provider_error permanent_provider_error context_overflow)
  @kernel_reasons ~w(output_token_limit invalid_tool_arguments)
  @provider_statuses ~w(incomplete failed cancelled expired)
  # `error.type` / `error.code` (OpenAI-compatible, Anthropic) and
  # `error.status` (Google) values worth telling apart. Unlisted values are
  # dropped, not recorded.
  @provider_codes ~w(
    invalid_request_error rate_limit_error authentication_error permission_error
    not_found_error server_error api_error overloaded_error request_too_large
    billing_error insufficient_quota rate_limit_exceeded invalid_api_key
    context_length_exceeded model_not_found content_filter server_overloaded
    RESOURCE_EXHAUSTED INVALID_ARGUMENT PERMISSION_DENIED UNAUTHENTICATED NOT_FOUND
    INTERNAL UNAVAILABLE DEADLINE_EXCEEDED FAILED_PRECONDITION ABORTED CANCELLED UNKNOWN
  )
  # Transport failures the runtime raises (`SalixLlm.Http` idle and first-event
  # timeouts) or receives from the socket layer.
  @transport_kinds ~w(
    incomplete_stream stream_idle_timeout first_event_timeout idle_timeout timeout closed econnrefused
    econnreset nxdomain etimedout ehostunreach enetunreach
  )
  @exit_kinds ~w(timeout noproc killed shutdown normal dependency_timeout dependency_crashed)

  # `SalixAgent.StreamProgress.snapshot/1` fields the fact carries as columns;
  # anything else in the snapshot (attempt, elapsed, the wall-clock start) is
  # spent on the attempt, duration and start fields instead.
  @progress_fields ~w(
    first_body_ms last_body_ms received_bytes received_chunks
    first_content_ms last_content_ms content_deltas
  )a
  @transport_pattern ~r/(?<![A-Za-z0-9_])(?:#{Enum.join(@transport_kinds, "|")})(?![A-Za-z0-9_])/

  @doc "Wall-clock milliseconds, the unit every attempt is stamped in."
  def now_ms, do: System.system_time(:millisecond)

  @doc """
  Emit one failed-attempt fact. `reason` is what the provider seam returned
  or raised: `{:error, map}` from `SalixAgent.LLM.Error`, an exception, or
  a caught `{kind, value}`.
  """
  def emit(meter_ctx, attempt, max_attempts, outcome, reason, delay_ms, duration_ms, started_ms) do
    fact =
      build(meter_ctx, attempt, max_attempts, outcome, reason, delay_ms, duration_ms, started_ms)

    SalixAgent.Observability.llm_attempt(fact)
  rescue
    exception ->
      Logger.warning("attempt telemetry emit failed: #{Exception.message(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, value ->
      Logger.warning("attempt telemetry emit exited: #{inspect({kind, value})}")
      {:error, {kind, value}}
  end

  @doc """
  Emit the fact for an attempt the session actor killed at the job deadline.
  `reason` is the dependency failure the actor saw (`{:dependency_timeout,
  :llm}` or `{:dependency_crashed, :llm, reason}`); `progress` is the
  `SalixAgent.StreamProgress.snapshot/1` of the attempt in flight, or `nil`
  when the job died before any attempt began.
  """
  def emit_killed(meter_ctx, max_attempts, reason, progress) do
    fact = build_killed(meter_ctx, max_attempts, reason, progress)
    SalixAgent.Observability.llm_attempt(fact)
  rescue
    exception ->
      Logger.warning("attempt telemetry emit failed: #{Exception.message(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, value ->
      Logger.warning("attempt telemetry emit exited: #{inspect({kind, value})}")
      {:error, {kind, value}}
  end

  @doc false
  def build_killed(meter_ctx, max_attempts, reason, progress) do
    progress = if is_map(progress), do: progress, else: %{}

    fact =
      build(
        meter_ctx,
        progress[:attempt] || 1,
        max_attempts,
        :killed,
        {:exit, reason},
        0,
        progress[:elapsed_ms],
        progress[:attempt_started_at_ms]
      )

    # Every progress column is present on the fact, nil when unobserved, so a
    # killed fact has one shape whether or not the stream ever started.
    fact
    |> Map.merge(Map.new(@progress_fields, &{&1, progress[&1]}))
    |> Map.update!(:http_status, &(&1 || progress[:http_status]))
  end

  @doc false
  def build(meter_ctx, attempt, max_attempts, outcome, reason, delay_ms, duration_ms, started_ms) do
    meter_ctx = meter_ctx || %{}
    billing = field(meter_ctx, :billing_context) || %{}
    request_id = field(meter_ctx, :request_id)
    round_id = field(meter_ctx, :round_id)
    {category, http_status, summary} = classify(reason)

    %{
      source: "salix_agent.llm_attempt",
      source_key: "#{request_id || round_id || "request:" <> random_id()}:#{attempt}",
      entrypoint: "llm_attempt",
      surface: field(meter_ctx, :surface) || field(billing, :surface) || "unknown",
      tenant_id: field(meter_ctx, :tenant_id) || "unknown",
      group_id: field(meter_ctx, :group_id) || "unknown",
      actor_type: field(meter_ctx, :actor_type) || field(billing, :actor_type) || "user",
      provider: field(meter_ctx, :provider),
      model: field(meter_ctx, :model),
      attempt: attempt,
      max_attempts: max_attempts,
      outcome: to_string(outcome),
      category: category,
      reason: summary,
      http_status: http_status,
      duration_ms: max(duration_ms || 0, 0),
      delay_ms: max(delay_ms || 0, 0),
      started_at: DateTime.from_unix!(started_ms || now_ms(), :millisecond),
      metered_at: DateTime.utc_now(),
      trace_id: field(meter_ctx, :trace_id),
      request_id: request_id,
      salix_agent_id: field(meter_ctx, :salix_agent_id) || field(meter_ctx, :agent_id),
      session_id: field(meter_ctx, :session_id),
      round_id: round_id,
      charge_status: "unattributed",
      app_revision: field(meter_ctx, :app_revision) || SalixAgent.AppRevision.value()
    }
  end

  @doc "Every word `reason` can carry. Tests pin that nothing else appears."
  def vocabulary,
    do:
      @kernel_reasons ++ @provider_statuses ++ @provider_codes ++ @transport_kinds ++ @exit_kinds

  @doc false
  # `{category, http_status, summary}` for whatever the retry loop saw. The
  # summary is the ordered, deduplicated list of vocabulary words the failure
  # names; a failure that names none leaves it empty.
  def classify({:error, reason}), do: classify(reason)

  def classify(%{} = error) when not is_struct(error) do
    status = field(error, :status)
    http_status = if is_integer(status), do: status, else: nil

    words =
      [
        listed(field(error, :reason), @kernel_reasons),
        listed(field(error, :provider_status), @provider_statuses)
      ] ++
        body_words(field(error, :body)) ++
        transport_words(field(error, :reason))

    {listed(field(error, :category), @categories) || "unknown", http_status, summary(words)}
  end

  def classify(exception) when is_exception(exception), do: {"exception", nil, ""}

  def classify({kind, value}) when kind in [:exit, :throw, :error],
    do: {to_string(kind), nil, summary(exit_words(value))}

  def classify(_other), do: {"unknown", nil, ""}

  # Provider error bodies are JSON with the class of failure under a few
  # well-known keys; only listed values under those keys are read.
  defp body_words(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> body_words(decoded)
      _ -> []
    end
  end

  defp body_words(%{} = body) do
    nested = field(body, :error)
    scope = if is_map(nested) and not is_struct(nested), do: nested, else: body
    Enum.map(~w(type code status), &listed(Map.get(scope, &1), @provider_codes))
  end

  defp body_words(_body), do: []

  # A transport reason arrives as the kernel's `inspect` preview of a term.
  # It is not parsed: the listed transport kinds are looked up in it as whole
  # words, so the output is a subset of the list whatever the preview holds.
  defp transport_words(preview) when is_binary(preview),
    do: Regex.scan(@transport_pattern, preview) |> Enum.map(&hd/1)

  defp transport_words(_preview), do: []

  # A caught exit value is a live term: only listed atoms in it are named.
  defp exit_words(term, depth \\ 0)
  defp exit_words(_term, depth) when depth > 3, do: []
  defp exit_words(atom, _depth) when is_atom(atom), do: List.wrap(listed(atom, @exit_kinds))

  defp exit_words(tuple, depth) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&exit_words(&1, depth + 1))

  defp exit_words(list, depth) when is_list(list),
    do: list |> Enum.take(4) |> Enum.flat_map(&exit_words(&1, depth + 1))

  defp exit_words(_term, _depth), do: []

  defp summary(words) do
    words |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.take(@max_words) |> Enum.join(" ")
  end

  defp listed(value, list) when is_atom(value) and not is_nil(value),
    do: listed(Atom.to_string(value), list)

  defp listed(value, list) when is_binary(value), do: if(value in list, do: value)
  defp listed(_value, _list), do: nil

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
