defmodule SalixLlm.StreamWatchdog do
  @moduledoc """
  Stall detection for streamed provider responses.

  Req's `receive_timeout` is the only idle guard Finch offers, and it is one
  number for the whole request. A provider that legitimately needs two minutes
  before its first token therefore forces a two-minute tolerance for every gap
  after it, which is how a stream that dies mid-answer sat idle until the
  ten-minute request budget ended it. This module separates the two phases:

    * `:first_event_timeout` — how long to wait for the first SSE data chunk
      (`SalixAgent.LLM.stream_first_event_timeout_ms/0`, 120 s by default).
    * `:idle_timeout` — the longest quiet gap tolerated after that
      (`SalixAgent.LLM.stream_idle_timeout_ms/0`, 30 s by default).

  Every byte of response body counts as activity, so provider pings, thinking
  deltas and tool-argument fragments keep a stream alive exactly like text.

  `post/3` is a drop-in for `Req.post/2` with an `into:` function. The HTTP
  request runs in a linked relay task that forwards each body chunk to the
  caller as a message; the caller applies the `into:` function itself, so
  delta callbacks keep running in the process that issued the request (the
  round driver keeps per-attempt state in its process dictionary and the site
  LLM handler threads a live `Plug.Conn` the same way). The relay is a Task
  boundary in the `SystemsObservability` sense: it runs under the caller's
  captured context, so the provider request keeps the caller's surface, Logger
  metadata and parent span.

  A quiet gap longer than the active phase's allowance kills the relay — the
  pool then drops its connection — and yields
  `{:error, {:stream_idle_timeout, meta}, partial}`. Every error carries the
  caller-side response accumulated so far (or `nil` when no response had
  started), because a stream that dies after it began has often already
  reported usage the caller must bill. Callers already map a Req transport
  error to a retryable `SalixAgent.LLM.Error.transport/2`, and a stall takes
  the same path.

  Retries are forced off: a transparent Req retry would re-fire deltas.
  Redirects stay on; each response Req delivers (a body-bearing 307 included)
  starts a fresh accumulator, so only the final response's body reaches the
  caller's state, and a redirect's body does not spend the first-event
  allowance: the clock stays in the first-event phase until the final
  response's first chunk arrives.
  """

  require Logger

  @type phase :: :first_event | :streaming

  @typedoc "Reason returned when a stream goes quiet for longer than its phase allows."
  @type idle_timeout :: {:stream_idle_timeout, %{phase: phase(), timeout_ms: pos_integer()}}

  @typedoc """
  Same contract as Req's `into:` function: receives `{:data, chunk}` and the
  `{request, response}` accumulator, returns `{:cont, acc}` or `{:halt, acc}`.
  """
  @type into_fun ::
          ({:data, binary()}, {Req.Request.t(), Req.Response.t()} ->
             {:cont, {Req.Request.t(), Req.Response.t()}}
             | {:halt, {Req.Request.t(), Req.Response.t()}})

  @doc """
  POST `url` with `req_opts` (which must carry an `into:` function) and watch
  the response stream for stalls.

  Options:

    * `:idle_timeout` — ms between chunks once streaming, or `:infinity`.
      Defaults to `SalixAgent.LLM.stream_idle_timeout_ms/0`.
    * `:first_event_timeout` — ms allowed before the first chunk, or
      `:infinity`. Defaults to `SalixAgent.LLM.stream_first_event_timeout_ms/0`.

  Returns `{:ok, %Req.Response{}}` (with the private state the `into:` function
  accumulated) or `{:error, reason, partial}`, where `reason` is a Req
  transport failure or `{:stream_idle_timeout, %{phase: phase, timeout_ms: ms}}`
  and `partial` is the caller-side `%Req.Response{}` accumulated before the
  failure, or `nil` when no response had started. An exception raised by Req
  inside the relay is re-raised in the caller.
  """
  @spec post(String.t(), keyword(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term(), Req.Response.t() | nil}
  def post(url, req_opts, opts \\ []) when is_binary(url) and is_list(req_opts) do
    {into, req_opts} = Keyword.pop(req_opts, :into)

    unless is_function(into, 2) do
      raise ArgumentError, "SalixLlm.StreamWatchdog.post/3 requires an `into:` function"
    end

    timeouts = %{
      first_event:
        timeout_opt(opts, :first_event_timeout, &SalixAgent.LLM.stream_first_event_timeout_ms/0),
      streaming: timeout_opt(opts, :idle_timeout, &SalixAgent.LLM.stream_idle_timeout_ms/0)
    }

    owner = self()
    ref = make_ref()
    req_opts = Keyword.put(req_opts, :retry, false)

    progress = %{
      started_at: now(),
      last_body_at: nil,
      first_body_at: nil,
      received_bytes: 0,
      received_chunks: 0,
      observed_http_status: nil
    }

    # Captured here, in the caller, and re-attached inside the relay: a bare
    # Task would perform the provider request as surface "system" with no
    # Logger metadata and no parent span.
    context = SystemsObservability.Context.capture()

    task =
      Task.async(fn ->
        SystemsObservability.Context.run(context, fn -> relay(owner, ref, url, req_opts) end)
      end)

    await(task, ref, into, nil, :first_event, timeouts, url, progress)
  end

  # ---- relay (runs in the linked task) ----

  defp relay(owner, ref, url, req_opts) do
    into = fn {:data, data}, {req, resp} ->
      resp =
        if Req.Response.get_private(resp, :stream_watchdog_announced, false) do
          send(owner, {ref, :chunk, nil, data})
          resp
        else
          # The first chunk of every response Req delivers carries the
          # request/response pair, so the owner can seed a fresh accumulator
          # with that response's status and headers. A followed redirect that
          # has a body announces itself here too, before the final response.
          send(owner, {ref, :chunk, {req, resp}, data})
          Req.Response.put_private(resp, :stream_watchdog_announced, true)
        end

      {:cont, {req, resp}}
    end

    Req.post(url, Keyword.put(req_opts, :into, into))
  rescue
    exception -> {:stream_watchdog_raise, exception, __STACKTRACE__}
  catch
    kind, reason -> {:stream_watchdog_catch, kind, reason, __STACKTRACE__}
  end

  # ---- owner side ----

  defp await(%Task{ref: task_ref} = task, ref, into, acc, phase, timeouts, url, progress) do
    timeout = Map.fetch!(timeouts, phase)

    receive do
      {^ref, :chunk, initial, data} ->
        # A non-nil `initial` is a new response starting; it replaces whatever
        # an earlier response (a redirect with a body) accumulated.
        acc = initial || acc
        progress = received(progress, initial, data)

        case into.({:data, data}, acc) do
          {:cont, acc} ->
            await(task, ref, into, acc, next_phase(acc), timeouts, url, progress)

          {:halt, {_req, resp}} ->
            _ = Task.shutdown(task, :brutal_kill)
            flush(ref)
            {:ok, resp}
        end

      {^task_ref, result} ->
        Process.demonitor(task_ref, [:flush])
        flush(ref)
        log_failure(result, phase, progress, url)
        finish(result, acc)

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        flush(ref)
        log_failure({:error, {:stream_relay_exit, reason}}, phase, progress, url)
        {:error, {:stream_relay_exit, reason}, partial(acc)}
    after
      timeout ->
        _ = Task.shutdown(task, :brutal_kill)
        flush(ref)

        log_failure({:idle_timeout, timeout}, phase, progress, url)

        {:error, {:stream_idle_timeout, %{phase: phase, timeout_ms: timeout}}, partial(acc)}
    end
  end

  defp received(progress, initial, data) do
    at = now()

    progress =
      case initial do
        {_req, resp} ->
          %{
            progress
            | first_body_at: at,
              received_bytes: 0,
              received_chunks: 0,
              observed_http_status: resp.status
          }

        nil ->
          progress
      end

    %{
      progress
      | last_body_at: at,
        received_bytes: progress.received_bytes + byte_size(data),
        received_chunks: progress.received_chunks + 1
    }
  end

  defp log_failure({:ok, _response}, _phase, _progress, _url), do: :ok

  defp log_failure(result, phase, progress, url) do
    at = now()
    {failure, metadata} = failure_metadata(result)

    diagnostics = %{
      failure: failure,
      phase: phase,
      elapsed_ms: at - progress.started_at,
      silent_ms: at - (progress.last_body_at || progress.started_at),
      first_body_ms: if(progress.first_body_at, do: progress.first_body_at - progress.started_at),
      received_bytes: progress.received_bytes,
      received_chunks: progress.received_chunks,
      observed_http_status: progress.observed_http_status
    }

    {message, diagnostics} =
      case result do
        {:idle_timeout, timeout} ->
          {"llm stream stalled: no #{stall_label(phase)} for #{timeout}ms",
           Map.put(diagnostics, :timeout_ms, timeout)}

        _ ->
          {"llm stream failed", diagnostics}
      end

    Logger.warning(
      message <> " (#{provider_origin(url)})",
      Keyword.merge(metadata,
        stream_diagnostics: diagnostics,
        provider_origin: provider_origin(url)
      )
    )
  rescue
    _ -> :ok
  end

  defp failure_metadata({:idle_timeout, _timeout}), do: {:idle_timeout, [error_class: "timeout"]}

  defp failure_metadata({:error, {:stream_relay_exit, _} = reason}),
    do: {:relay_exit, [crash_reason: {reason, []}]}

  defp failure_metadata({:error, reason}),
    do: {:transport_error, [crash_reason: {reason, []}]}

  defp failure_metadata({:stream_watchdog_raise, exception, stack}),
    do: {:relay_exception, [crash_reason: {exception, stack}]}

  defp failure_metadata({:stream_watchdog_catch, kind, reason, stack}),
    do: {:relay_exception, [crash_reason: {{kind, reason}, stack}]}

  defp now, do: System.monotonic_time(:millisecond)

  defp finish({:ok, %Req.Response{} = relay_resp}, {_req, %Req.Response{} = resp}) do
    # The owner's copy carries what the `into:` function accumulated; the
    # relay's copy carries whatever Req's response pipeline set after the body
    # ended. The owner's private state wins where both wrote.
    {:ok, %{relay_resp | private: Map.merge(relay_resp.private, resp.private)}}
  end

  defp finish({:ok, %Req.Response{} = relay_resp}, nil), do: {:ok, relay_resp}
  defp finish({:error, reason}, acc), do: {:error, reason, partial(acc)}

  defp finish({:stream_watchdog_raise, exception, stacktrace}, _acc),
    do: reraise(exception, stacktrace)

  defp finish({:stream_watchdog_catch, kind, reason, stacktrace}, _acc),
    do: :erlang.raise(kind, reason, stacktrace)

  # The body of a response Req is about to follow (a redirect with a body) is
  # not the response the caller is waiting for. Consuming it keeps the
  # first-event allowance in force, so a provider that is slow to its first
  # token behind a redirect still gets the full time-to-first-token budget
  # rather than the shorter inter-event one. Mirrors Req's own redirect step:
  # a redirect status, a Location header, and redirects enabled.
  defp next_phase({req, %Req.Response{status: status} = resp}) do
    SalixVerifiedKernel.Provider.call(
      :watchdog_phase,
      {status, Req.Request.get_option(req, :redirect, true),
       Req.Response.get_header(resp, "location") != []}
    )
  end

  defp next_phase(_acc), do: :streaming

  defp partial({_req, %Req.Response{} = resp}), do: resp
  defp partial(nil), do: nil

  defp flush(ref) do
    receive do
      {^ref, :chunk, _initial, _data} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp timeout_opt(opts, key, default_fun) do
    case Keyword.get(opts, key) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      :infinity -> :infinity
      nil -> default_fun.()
      other -> raise ArgumentError, "invalid #{key}: #{inspect(other)}"
    end
  end

  defp stall_label(:first_event), do: "first event"
  defp stall_label(:streaming), do: "event"

  defp provider_origin(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | userinfo: nil, path: nil, query: nil, fragment: nil})
  end
end
