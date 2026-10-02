defmodule SalixAgent.LLM do
  @moduledoc """
  The LLM seam used by the round driver. It defines the provider behaviour and
  a scriptable mock for tests; `salix_llm` implements chat-completions,
  responses, Anthropic, and streaming providers through the same boundary.

  The round supplies a resident Session and request-local facts. Lean produces
  the final provider body before dispatch and archival.
  Providers that implement `request_config/1` receive an encoded request.
  Other providers receive a message list from the same Lean projection.
  List-based callers retain their existing interface.

  Completion callbacks receive that request and the available tools, and return one of:

    * `{:assistant, content, tool_calls}` — an assistant turn requesting tools;
      `tool_calls` is a list of `%{id, name, args}`. The round persists the
      assistant and synchronous tool results; the session actor's next
      activation decides whether another round should run.
    * `{:final, content}` — provider output with no tool calls. Internal
      Router/Worker sessions persist it without ACK and request another decision
      round; only a valid standalone `end_turn` settles the work.
    * Provider implementations may append a final metadata map:
      `{:final, content, trace_meta}`,
      `{:final, content, provider_meta, trace_meta}`,
      `{:assistant, content, tool_calls, provider_meta, trace_meta}`. The
      round persists that map onto the assistant message for `/trace`.
    * `{:error, meta}` — a provider/transport failure. Runtime drivers record
      this as a non-transcript session event and end the current activation
      boundary; compaction inspects `meta` to decide retry/recovery behavior.

  `complete_stream/3` is the streaming variant: same return
  shapes, plus an `on_delta` callback fired with each text delta in stream
  order while the response arrives. It is an OPTIONAL callback — impls that
  only define `complete/2` still work; the dispatch helper falls back to
  `complete/2` (no deltas fire).
  """

  alias SalixAgent.{LLMMetering, LLMProvider}

  @default_request_timeout_ms 600_000
  @default_stream_idle_timeout_ms 30_000
  @default_stream_first_event_timeout_ms 120_000
  # RFC 4122 OID namespace; the key must only be stable, not secret.
  @prompt_cache_namespace <<0x6B, 0xA7, 0xB8, 0x12, 0x9D, 0xAD, 0x11, 0xD1, 0x80, 0xB4, 0x00,
                            0xC0, 0x4F, 0xD4, 0x30, 0xC8>>

  @type message :: map()
  @type provider_request :: [message()] | {:encoded_provider_request, String.t(), binary()}
  @type request :: provider_request()
  @type tool_call :: %{id: String.t(), name: String.t(), args: map()}
  @type result ::
          {:assistant, String.t(), [tool_call()]}
          | {:assistant, String.t(), [tool_call()], provider_meta :: map()}
          | {:assistant, String.t(), [tool_call()], provider_meta :: map() | nil,
             trace_meta :: map()}
          | {:final, String.t()}
          | {:final, String.t(), trace_meta :: map()}
          | {:final, String.t(), provider_meta :: map() | nil, trace_meta :: map()}
          | {:error, map()}
  @type compact_result ::
          {:ok, output_items :: [map()], trace_meta :: map()}
          | {:error, map()}
          | {:unsupported, term()}

  @typedoc "Callback invoked with each streamed text delta, in order. Best-effort."
  @type on_delta :: (String.t() -> any())

  @typedoc """
  Provider-classified reasoning callback. Only `:public_summary` text is
  eligible for a user-visible activity; `:private_reasoning` text is raw and
  must remain private.
  """
  @type on_reasoning_delta :: (SalixAgent.LLM.ReasoningDelta.t() -> any())

  @typedoc """
  Per-agent provider overrides (the agent's template snapshot — willow's
  `ResolveAgentProviderConfig`): model / protocol / api_key / api_key_env /
  base_url / max_tokens / default_headers. String- or atom-keyed.
  """
  @type llm_opts :: map() | keyword()

  @doc "Total request budget shared by agent LLM dependencies and provider transports."
  @spec request_timeout_ms() :: pos_integer()
  def request_timeout_ms do
    case Application.get_env(:salix_agent, :llm_request_timeout_ms, @default_request_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_request_timeout_ms
    end
  end

  @doc """
  Longest quiet gap tolerated between two SSE events of a streamed provider
  response once the first event has arrived. A stream that goes silent for
  longer is abandoned as a transport failure well before `request_timeout_ms/0`
  would end it. Every event on the wire counts as activity — pings, thinking
  and tool-argument deltas included — not only text deltas. `:infinity`
  disables the check.
  """
  @spec stream_idle_timeout_ms() :: pos_integer() | :infinity
  def stream_idle_timeout_ms do
    stream_timeout_env(:llm_stream_idle_timeout_ms, @default_stream_idle_timeout_ms)
  end

  @doc """
  How long a streamed provider request may wait for its first SSE event. This
  covers time-to-first-token — prompt processing, cache writes and provider
  queueing — so it is deliberately longer than `stream_idle_timeout_ms/0`.
  `:infinity` disables the check.
  """
  @spec stream_first_event_timeout_ms() :: pos_integer() | :infinity
  def stream_first_event_timeout_ms do
    stream_timeout_env(:llm_stream_first_event_timeout_ms, @default_stream_first_event_timeout_ms)
  end

  defp stream_timeout_env(key, default) do
    case Application.get_env(:salix_agent, key, default) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      :infinity -> :infinity
      _invalid -> default
    end
  end

  @callback complete(provider_request(), [map()]) :: result()
  @callback complete(provider_request(), [map()], llm_opts()) :: result()
  @callback complete_stream(provider_request(), [map()], on_delta()) :: result()
  @callback complete_stream(provider_request(), [map()], on_delta(), llm_opts()) :: result()
  @callback compact_context([message()], [map()], llm_opts()) :: compact_result()
  @callback request_config(llm_opts()) :: {String.t(), map()}
  @optional_callbacks complete: 3,
                      complete_stream: 3,
                      complete_stream: 4,
                      compact_context: 3,
                      request_config: 1

  @typedoc """
  Who a dispatch belongs to: `agent_id`, `session_id`, `round_id`, `tenant_id`.

  Separate from `llm_opts` because it is a different KIND of thing. `llm_opts`
  is the template's provider config — resolved per template, identical for
  every agent sharing one — and it cannot answer "whose round is this?".
  Callers pass identity explicitly so that the archive and dispatch metering
  can attribute a call without the seam having to guess. Anything absent is
  derived where it can be (tenant from the agent id) and empty where it
  cannot.
  """
  @type identity :: keyword() | map()

  @doc "Dispatch a template-owned Codex image request through the subscription pool."
  def generate_image(prompt, opts, identity) do
    cfg = Keyword.fetch!(opts, :config)

    with %{
           "provider" => "openai",
           "model" => "gpt-image-2",
           "provider_config" => %{"account_pool" => "codex"},
           "account_pool_tenant" => tenant
         } <- cfg,
         true <- SalixStore.Ids.valid_tenant_id?(tenant),
         {:ok, route} <-
           SalixAgent.AccountPool.resolve_config(
             %{"account_pool" => "codex", "model" => cfg["model"]},
             tenant
           ) do
      route =
        route
        |> Map.put("billing_context", opt(identity, :billing_context) || %{})
        |> Map.put("image_options", Map.new(Keyword.take(opts, [:size, :quality, :format])))

      config = %{
        "provider" => "openai",
        "model" => cfg["model"],
        "provider_config" => %{"base_url" => route["base_url"]}
      }

      call = fn resolved ->
        media_opts =
          opts |> Keyword.put(:config, config) |> Keyword.put(:transport, resolved["transport"])

        case SalixMedia.ImageGen.generate(prompt, media_opts) do
          {:error, {:http, status, body}} -> SalixAgent.LLM.Error.http("openai", status, body)
          result -> result
        end
      end

      images =
        Enum.map(Keyword.get(opts, :input_images, []), fn image ->
          %{
            "type" => "input_image",
            "image_url" => "data:" <> image.mime_type <> ";base64," <> Base.encode64(image.data)
          }
        end)

      metered_call(:generate_image, route, call, nil, %{
        messages: [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => prompt}] ++ images
          }
        ],
        tools: [],
        identity: identity
      })
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_image_account_pool}
    end
  end

  @doc "Evaluate typed questions through the shared metering and archive seam."
  def decide(args, config, identity, metering \\ [entrypoint: "decide", actor_type: "tool"]) do
    billing = identity[:billing_context] || %{}

    billing =
      Map.merge(billing, %{
        "salix_agent_id" => identity.agent_id,
        "salix_tenant_id" => identity.tenant_id,
        "salix_group_id" => identity.group_id
      })

    opts =
      Map.merge(config, %{
        billing_context: billing,
        entrypoint: Keyword.fetch!(metering, :entrypoint),
        actor_type: Keyword.fetch!(metering, :actor_type)
      })

    call = fn _ ->
      remaining =
        if is_integer(config[:deadline]),
          do: max(config.deadline - System.monotonic_time(:millisecond), 0),
          else: 2_000

      case SalixAgent.DependencyJob.start(
             :llm,
             identity.tenant_id,
             fn -> SalixAgent.Decide.Provider.request(args, config) end,
             timeout_ms: remaining
           ) do
        {:ok, job} ->
          case SalixAgent.DependencyJob.yield(job, remaining) do
            {:ok, result} ->
              result

            {:exit, {:dependency_timeout, :llm}} ->
              {:error, :timeout}

            {:exit, _} ->
              {:error, :unavailable}

            nil ->
              SalixAgent.DependencyJob.cancel(job, :timeout)
              {:error, :timeout}
          end

        {:error, _} ->
          {:error, :unavailable}
      end
    end

    metered_call(:decide, opts, call, nil, %{
      messages:
        {:encoded_provider_request, "decisions",
         Jason.encode!(Map.put(args, "model", config.model))},
      tools: [],
      identity: identity
    })
  end

  @doc "Dispatch to the configured LLM module (default: the scriptable mock)."
  @spec complete(request(), [map()], llm_opts(), identity()) :: result()
  def complete(messages, tools, llm_opts \\ [], identity \\ []) do
    llm_opts = put_prompt_cache_key(llm_opts, identity)
    mod = impl()

    call = fn llm_opts ->
      if has_opts?(llm_opts) and exported?(mod, :complete, 3) do
        mod.complete(messages, tools, llm_opts)
      else
        mod.complete(messages, tools)
      end
    end

    metered_call(:complete, llm_opts, call, nil, %{
      messages: messages,
      tools: tools,
      identity: identity
    })
  end

  @doc """
  Streaming dispatch: calls the configured impl's `complete_stream/3` when it
  exports one, else falls back to `complete/2` (ignoring `on_delta`).
  """
  @spec complete_stream(request(), [map()], on_delta(), llm_opts(), identity()) :: result()
  def complete_stream(messages, tools, on_delta, llm_opts \\ [], identity \\ [])
      when is_function(on_delta, 1) do
    llm_opts = put_prompt_cache_key(llm_opts, identity)
    mod = impl()
    started = System.monotonic_time()
    first_delta = :atomics.new(1, signed: true)
    # Any output delivered to the caller: text, a tool-call fragment (the
    # Router streams its visible reply this way) or reasoning. Once set, a
    # catalog dispatch must not hand the request to another Profile. Kept
    # apart from `first_delta`, which times the first TEXT delta only.
    output = :atomics.new(1, [])

    # Archive accumulation. Streamed text and reasoning exist ONLY as they fly
    # past these callbacks: `:private_reasoning` deltas never appear in the
    # terminal result, so without capturing them here the archive would be
    # missing what the model actually produced.
    accumulator = SalixAgent.EventArchive.Accumulator.new()

    measured_delta = fn delta ->
      _ = :atomics.compare_exchange(first_delta, 1, 0, System.monotonic_time())
      :atomics.put(output, 1, 1)
      SalixAgent.EventArchive.Accumulator.text(accumulator, delta)
      on_delta.(delta)
    end

    llm_opts =
      llm_opts
      |> mark_output(:on_tool_delta, output)
      |> mark_output(:on_reasoning_delta, output)

    llm_opts = SalixAgent.EventArchive.Accumulator.wrap_reasoning(accumulator, llm_opts)
    has_opts = has_opts?(llm_opts)

    call = fn llm_opts ->
      cond do
        has_opts and exported?(mod, :complete_stream, 4) ->
          mod.complete_stream(messages, tools, measured_delta, llm_opts)

        exported?(mod, :complete_stream, 3) ->
          mod.complete_stream(messages, tools, measured_delta)

        has_opts and exported?(mod, :complete, 3) ->
          mod.complete(messages, tools, llm_opts)

        true ->
          mod.complete(messages, tools)
      end
    end

    metered_call(:complete_stream, llm_opts, call, {started, first_delta, output}, %{
      messages: messages,
      tools: tools,
      accumulator: accumulator,
      identity: identity
    })
  end

  @doc """
  Provider-owned context compaction. Implemented only by providers with a native
  compact endpoint; callers should fall back to Salix summary compaction on
  `{:unsupported, _}`.
  """
  @spec compact_context([message()], [map()], llm_opts(), identity()) :: compact_result()
  def compact_context(messages, tools, llm_opts \\ [], identity \\ []) do
    llm_opts = put_prompt_cache_key(llm_opts, identity)
    mod = impl()

    call = fn llm_opts ->
      if exported?(mod, :compact_context, 3) do
        mod.compact_context(messages, tools, llm_opts)
      else
        {:unsupported, :not_implemented}
      end
    end

    metered_call(:compact_context, llm_opts, call, nil, %{
      messages: messages,
      tools: tools,
      identity: identity
    })
  end

  @doc false
  def emit_logical_request(llm_opts, result) do
    context = dispatch_meter_context(llm_opts)
    billing = context.billing_context

    Salix.Telemetry.emit_llm_request(%{
      surface: ctx(billing, "surface") || "system",
      provider: context.provider || "other",
      model_key: context.model || "other",
      outcome: dispatch_status(result)
    })
  end

  defp exported?(mod, fun, arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)

  defp impl, do: Application.get_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

  @doc """
  The provider request configuration a dispatch of `llm_opts` uses:
  `{protocol, cfg, supports_images?}`. The kernel encodes a round's request
  with it (`round_request`); `:neutral` asks for provider-neutral messages.
  """
  def request_config(llm_opts, identity \\ []) do
    llm_opts = put_prompt_cache_key(llm_opts, identity)
    mod = impl()

    # A catalog route binds its Profile only at dispatch, and each candidate
    # speaks its own protocol with its own request id. Nothing before dispatch
    # may encode for one of them: the request stays provider-neutral, and the
    # chosen candidate's provider encodes it.
    {protocol, cfg} =
      cond do
        SalixAgent.AccountPool.catalog_route?(llm_opts) -> {:neutral, nil}
        exported?(mod, :request_config, 1) -> mod.request_config(llm_opts)
        true -> {:neutral, nil}
      end

    {protocol, cfg, opt(llm_opts, :supports_images) == true}
  end

  # EVERY provider dispatch funnels through here — Round, Compaction, Titles and
  # the trajectory-eval judge alike — so archive boundaries 2 and 3 live at this
  # seam rather than at call sites. Emitting per call site was the original
  # design and it silently missed compaction, which ships the whole
  # conversation to the model and is the LAST place that history exists before
  # compaction discards it.
  defp metered_call(kind, llm_opts, call, stream_timing, archive) do
    started = stream_started(stream_timing)
    archive_request(kind, llm_opts, archive)

    # Taken BEFORE the dispatch, and deliberately not inside the try: the arms
    # below cannot run at all if this process is killed, which is how
    # `DependencyJob` cancels a job. See `reserve_response/2`.
    reservation = reserve_response(llm_opts, archive)

    try do
      result = do_metered_call(llm_opts, call, identity(archive), stream_timing)
      archive_response(kind, llm_opts, archive, result, reservation)

      emit_platform_telemetry(
        llm_opts,
        result,
        System.monotonic_time() - started,
        ttft_duration(stream_timing, started)
      )

      result
    rescue
      exception ->
        archive_response(
          kind,
          llm_opts,
          archive,
          {:error, %{exception: Exception.message(exception)}},
          reservation
        )

        emit_platform_telemetry(
          llm_opts,
          {:error, exception},
          System.monotonic_time() - started,
          ttft_duration(stream_timing, started)
        )

        reraise exception, __STACKTRACE__
    catch
      # Provider transports fail by EXIT far more often than by raise: a
      # Task.await timeout, a GenServer.call timeout, an :erpc exit. Round is
      # built for it (`safe_llm_provider_call/1` catches and retries), so
      # without this arm the common failure mode archived a request with no
      # response AND orphaned the accumulator's ETS row — up to 8 MiB of
      # already-received text and private reasoning, leaked until node restart.
      #
      # This arm does NOT cover every death. `Process.exit(pid, :kill)` is
      # untrappable, and `DependencyJob.drop_job/4` uses it to cancel a job, so
      # a cancelled dispatch runs none of this. The accumulator's row is then
      # reclaimed by `Accumulator.sweep/0`'s stale window rather than here, and
      # the missing response is visible only because `reservation` already
      # consumed its stream position.
      caught_kind, reason ->
        archive_response(
          kind,
          llm_opts,
          archive,
          {:error, %{kind: caught_kind, reason: reason}},
          reservation
        )

        emit_platform_telemetry(
          llm_opts,
          {:error, reason},
          System.monotonic_time() - started,
          ttft_duration(stream_timing, started)
        )

        :erlang.raise(caught_kind, reason, __STACKTRACE__)
    end
  end

  defp archive_request(_kind, _llm_opts, nil), do: :ok

  defp archive_request(kind, llm_opts, archive),
    do:
      SalixAgent.EventArchive.Emit.llm_request(
        kind,
        archive.messages,
        archive.tools,
        llm_opts,
        identity(archive)
      )

  # The call site's identity, carried alongside the payload rather than inside
  # `llm_opts`: provider config is resolved per template and names no agent,
  # session or round. `[]` for a caller that passed none, which the emitters
  # and the meter context both treat as "derive what you can".
  defp identity(archive) when is_map(archive), do: Map.get(archive, :identity) || []
  defp identity(_archive), do: []

  # Reserving costs one counter bump and buys the only detection there is for a
  # dispatch that is killed outright. `nil` when the archive is off or the call
  # is unarchived, in which case `llm_response/5` allocates normally.
  defp reserve_response(_llm_opts, nil), do: nil

  defp reserve_response(llm_opts, archive),
    do: SalixAgent.EventArchive.Emit.reserve_llm_response(llm_opts, identity(archive))

  defp archive_response(_kind, _llm_opts, nil, _result, _reservation), do: :ok

  defp archive_response(kind, llm_opts, archive, result, reservation),
    do:
      SalixAgent.EventArchive.Emit.llm_response(
        kind,
        result,
        llm_opts,
        archive[:accumulator],
        reservation,
        identity(archive)
      )

  defp do_metered_call(llm_opts, call, identity, stream_timing) do
    started? = fn ->
      case stream_timing do
        {_, _, output} -> :atomics.get(output, 1) != 0
        _ -> false
      end
    end

    if metering_disabled?(llm_opts) do
      SalixAgent.AccountPool.dispatch(llm_opts, call, started?, identity)
    else
      context = dispatch_meter_context(llm_opts, identity)

      case LLMMetering.before_llm_call(context) do
        {:error, {:billing_unavailable, _decision} = reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, {:billing_unavailable, fee_control_error_decision(context, reason)}}

        _ ->
          started = System.monotonic_time(:millisecond)

          try do
            result = SalixAgent.AccountPool.dispatch(llm_opts, call, started?, identity)
            duration_ms = System.monotonic_time(:millisecond) - started

            _ =
              LLMMetering.after_llm_call(dispatch_meter_result(context, result, duration_ms))

            result
          rescue
            exception ->
              duration_ms = System.monotonic_time(:millisecond) - started

              _ =
                LLMMetering.after_llm_call(
                  Map.merge(context, %{
                    status: "error",
                    duration_ms: duration_ms,
                    error: Exception.message(exception)
                  })
                )

              reraise exception, __STACKTRACE__
          end
      end
    end
  end

  defp emit_platform_telemetry(llm_opts, result, duration, ttft_duration) do
    context = dispatch_meter_context(llm_opts)
    billing = context.billing_context

    metadata = %{
      surface: ctx(billing, "surface") || "system",
      provider: context.provider || "other",
      model_key: context.model || "other",
      outcome: dispatch_status(result)
    }

    # This dispatch boundary owns TTFT and usage. The Round boundary owns the
    # logical request across its existing retry loop.
    attempt_metadata =
      if is_integer(ttft_duration) and ttft_duration >= 0 do
        metadata
        |> Map.put(:ttft, true)
        |> Map.put(:ttft_duration, ttft_duration)
      else
        metadata
      end

    Salix.Telemetry.emit_llm_attempt(attempt_metadata, duration)

    response = response_meta(result)
    emit_usage(response["usage"] || response[:usage] || %{}, metadata)
  end

  defp emit_usage(usage, metadata) when is_map(usage) do
    for {kind, keys} <- [
          {"input", ["input_tokens", :input_tokens, "prompt_tokens", :prompt_tokens]},
          {"output", ["output_tokens", :output_tokens, "completion_tokens", :completion_tokens]},
          {"cache_read",
           [
             "cache_read_input_tokens",
             :cache_read_input_tokens,
             "cache_read_tokens",
             :cache_read_tokens
           ]},
          {"cache_write",
           [
             "cache_write_input_tokens",
             :cache_write_input_tokens,
             "cache_write_tokens",
             :cache_write_tokens
           ]}
        ],
        value = Enum.find_value(keys, &Map.get(usage, &1)),
        is_number(value) do
      Salix.Telemetry.emit_llm_usage(Map.put(metadata, :kind, kind), value)
    end

    :ok
  end

  defp emit_usage(_usage, _metadata), do: :ok

  defp stream_started({started, _first_delta, _output}), do: started
  defp stream_started(nil), do: System.monotonic_time()

  defp ttft_duration({_started, first_delta, _output}, started) do
    case :atomics.get(first_delta, 1) do
      0 -> nil
      first -> max(first - started, 0)
    end
  end

  defp ttft_duration(nil, _started), do: nil

  # `identity` fills the same fields here that it fills in the archive, for the
  # same reason. `BillingCore.Metering.LLMMetering.row_attrs/1` reads
  # `salix_agent_id`, `session_id` and `round_id` from the fact's TOP LEVEL
  # only — never nested into `billing_context` — so every dispatch metered here
  # (compaction, title generation, the trajectory-eval judge) wrote those
  # columns null. `SalixAgent.Round` supplies them itself through
  # `llm_meter_context/6` and meters with dispatch metering off, so it is
  # unaffected either way; this closes the gap for everything else.
  #
  # `turn_id` is not set: no caller at this seam has a turn, and a key that is
  # always nil reads as one that is sometimes populated. Tenant and group are
  # not set either — `row_attrs/1` already resolves those through the nested
  # `salix_`-prefixed keys.
  defp dispatch_meter_context(llm_opts, identity \\ []) do
    billing_context = opt(llm_opts, :billing_context) || %{}

    agent_id =
      opt(identity, :agent_id) || ctx(billing_context, "salix_agent_id") ||
        opt(llm_opts, :agent_id)

    %{
      entrypoint:
        opt(llm_opts, :entrypoint) || ctx(billing_context, "entrypoint") || "llm_dispatch",
      actor_type: opt(llm_opts, :actor_type) || ctx(billing_context, "actor_type") || "system",
      model: opt(llm_opts, :model),
      protocol: opt(llm_opts, :protocol),
      provider: LLMProvider.provider(llm_opts),
      tenant_account_pool: SalixAgent.AccountPool.owns_route?(llm_opts),
      credential_scope: opt(llm_opts, :credential_scope),
      billing_context: billing_context,
      salix_agent_id: agent_id,
      session_id: opt(identity, :session_id) || opt(llm_opts, :session_id),
      round_id: opt(identity, :round_id) || opt(llm_opts, :round_id),
      request_id: new_request_id(),
      app_revision: SalixAgent.AppRevision.value(),
      started_at_ms: System.system_time(:millisecond)
    }
  end

  defp dispatch_meter_result(context, result, duration_ms) do
    meta = response_meta(result)

    context
    |> Map.merge(%{
      status: dispatch_status(result),
      duration_ms: duration_ms,
      completed_at_ms: System.system_time(:millisecond),
      response_kind: elem_or(result, 0),
      usage: dispatch_usage(meta, context, result),
      provider_model: meta["model"] || meta[:model]
    })
    |> maybe_put(:llm_error, meta["llm_error"] || meta[:llm_error])
  end

  defp dispatch_usage(meta, context, result) do
    meta["usage"] || meta[:usage] ||
      if context[:protocol] in ["responses", :responses] and dispatch_status(result) == "ok" do
        %{"usage_reported" => false}
      else
        %{}
      end
  end

  defp response_meta({:final, _content, meta}) when is_map(meta), do: meta

  defp response_meta({:final, _content, _provider_meta, meta}) when is_map(meta), do: meta

  defp response_meta({:assistant, _content, _calls, _provider_meta, meta}) when is_map(meta),
    do: meta

  defp response_meta({:ok, _output, meta}) when is_map(meta), do: meta

  defp response_meta({:ok, meta}) when is_map(meta), do: meta

  # Raw decisions responses belong only in the encrypted archive, never billing diagnostics.
  defp response_meta({:error, %{decide_error: code, usage: usage}}),
    do: %{"llm_error" => %{"code" => Atom.to_string(code)}, "usage" => usage}

  defp response_meta({:error, %{} = meta}), do: %{"llm_error" => meta}

  defp response_meta(_response), do: %{}

  defp dispatch_status({:error, _meta}), do: "error"
  defp dispatch_status(_result), do: "ok"

  defp new_request_id do
    "req-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Wrap a streaming callback so that a delivered delta marks output.
  defp mark_output(llm_opts, key, output) when is_map(llm_opts) or is_list(llm_opts) do
    callback =
      cond do
        is_map(llm_opts) -> Map.get(llm_opts, key) || Map.get(llm_opts, to_string(key))
        Keyword.keyword?(llm_opts) -> Keyword.get(llm_opts, key)
        true -> nil
      end

    if is_function(callback, 1) do
      wrapped = fn delta ->
        :atomics.put(output, 1, 1)
        callback.(delta)
      end

      cond do
        is_list(llm_opts) -> Keyword.put(llm_opts, key, wrapped)
        Map.has_key?(llm_opts, key) -> Map.put(llm_opts, key, wrapped)
        true -> Map.put(llm_opts, to_string(key), wrapped)
      end
    else
      llm_opts
    end
  end

  defp mark_output(llm_opts, _key, _output), do: llm_opts

  defp metering_disabled?(llm_opts), do: opt(llm_opts, :metering_disabled) == true

  defp fee_control_error_decision(context, reason) do
    %{
      allowed?: false,
      would_block: true,
      reason: "fee_control_error",
      error: inspect(reason),
      mode: :enforce,
      resource_kind: :llm,
      action: :start,
      provider: context[:provider],
      sku: context[:sku],
      billing_account_id: ctx(context[:billing_context], "billing_account_id")
    }
  end

  # Total accessor for a billing context, which is read on every dispatch.
  #
  # These used to be plain Access (`billing["surface"]`), and Access RAISES on a
  # binary key against a keyword list. Every producer builds a map today, so it
  # never fired — but the reads sit in `metered_call/5`'s `do` arm, where a
  # raise turns a SUCCEEDED provider call into a failed turn, which is exactly
  # what observation code may never do. Same shape as
  # `SalixAgent.EventArchive.Emit.soft_get/2`, kept local because that one is
  # private to the emitter.
  defp ctx(context, key) when is_map(context) and not is_struct(context),
    do: Map.get(context, key) || Map.get(context, safe_atom(key))

  defp ctx(context, key) when is_list(context) do
    case safe_atom(key) do
      nil -> nil
      atom -> if Keyword.keyword?(context), do: Keyword.get(context, atom), else: nil
    end
  end

  defp ctx(_context, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  @doc """
  The provider prompt-cache key for a session: a UUID v5 of the session id.

  OpenAI routes a request to a cache machine by hashing its first tokens plus
  this key. Every Salix worker session opens with the same role prompt, so
  without a key all sessions collide on one cache and evict each other; the
  Codex subscription proxy goes further and mints a random `Session_id` per
  request when the key is absent. Measured on staging before this key existed:
  consecutive rounds of one session re-read only ~60% of an unchanged prefix.
  A UUID shape is used because the Codex backend expects one in `Session_id`.
  """
  @spec prompt_cache_key(String.t()) :: String.t()
  def prompt_cache_key(session_id) when is_binary(session_id) and session_id != "" do
    <<a::32, b::16, c::16, d::16, e::48, _::binary>> =
      :crypto.hash(:sha, @prompt_cache_namespace <> "salix:session:" <> session_id)

    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x5000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    [<<a::32>>, <<b::16>>, <<c::16>>, <<d::16>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  # Only OpenAI dispatches that know their session get a key: `prompt_cache_key`
  # is an OpenAI request field, and the Chat Completions body is also what
  # Gemini, DeepSeek and other OpenAI-compatible endpoints receive, where an
  # unknown field is at best ignored. Template-level opts never carry a key,
  # so nothing is overwritten. The key is added under the same key style the
  # opts already use (string-keyed template maps stay string-keyed for
  # `SalixLlm.ProviderConfig`).
  defp put_prompt_cache_key(llm_opts, identity) do
    session_id = opt(identity, :session_id) || opt(llm_opts, :session_id)

    cond do
      not (is_binary(session_id) and session_id != "") ->
        llm_opts

      LLMProvider.provider(llm_opts) != "openai" ->
        llm_opts

      opt(llm_opts, :prompt_cache_key) ->
        llm_opts

      is_list(llm_opts) ->
        Keyword.put(llm_opts, :prompt_cache_key, prompt_cache_key(session_id))

      string_keyed?(llm_opts) ->
        Map.put(llm_opts, "prompt_cache_key", prompt_cache_key(session_id))

      true ->
        Map.put(llm_opts, :prompt_cache_key, prompt_cache_key(session_id))
    end
  end

  defp string_keyed?(map), do: Enum.any?(map, fn {key, _} -> is_binary(key) end)

  defp has_opts?(opts), do: opts != [] and opts != %{}

  defp opt(opts, key) when is_map(opts), do: opts[key] || opts[Atom.to_string(key)]
  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(_opts, _key), do: nil

  defp elem_or(tuple, i) when is_tuple(tuple) and tuple_size(tuple) > i, do: elem(tuple, i)
  defp elem_or(other, _i), do: other
end
