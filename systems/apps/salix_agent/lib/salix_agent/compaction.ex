defmodule SalixAgent.Compaction do
  @moduledoc """
  Context compaction — the port of Willow's
  `ContextBuffer.Compact` / `shouldRunCompaction` (`internal/agent/context.go`,
  `activation.go`). When an internal runtime session transcript approaches the
  model context window, the session's **own LLM** summarizes the history and a
  `compaction` event records the summary + watermark — **never deleting** messages. After
  compaction the LLM request is built from the summary plus messages after
  `compacted_through`, so context stays bounded while the full transcript is
  retained in the journal.

  The verified kernel decides compaction (`VerifiedKernel.Session.CompactionHost`):
  the trigger, admission and backoff, the window a request may summarize, the
  request, how the model answer is read, and the events a commit writes. This
  module does the I/O: it resolves the model configuration and session prompt,
  calls the model, and commits the kernel's events through the store.

  The prepare/summarize/commit semantic fence is modeled in
  `tla/salix/CompactionFence.tla`. Preservation of fresh user input and
  resumption of a runnable suffix across compaction are modeled in
  `tla/salix/CompactionContinuation.tla`.

  ## Auto trigger (willow `ShouldCompact`)

  Willow compacts when `usage.total_tokens / context_window > 0.9`, with the
  window from the template's `context_tokens` (default 128000). When a Salix
  provider surfaces prompt usage, the trigger uses that authoritative request
  size. Each assistant response fences its usage to the compaction generation
  the request used, so stale pre-compaction usage cannot retrigger. Missing usage
  does not trigger automatic compaction. A rejected oversized request gets one
  durable compaction recovery before the runtime reports a terminal failure.
  The owning `InternalSessionActor` checks its own session before running a
  round and after later wakes; the next round then builds from the compacted
  context, willow's compact-before-overflow effect.

  ## Summarization (willow `Compact`)

  The request is built EXACTLY like a normal round (same system-prompt parts,
  same tool specs, same image inlining) so it hits the same prompt-cache
  prefix; the only new content is willow's appended summarize instruction.
  The model must answer with a `<compaction-summary>...</compaction-summary>`
  block; the extracted summary is stored wrapped in willow's
  `<compacted-context>` tags. Explicit compaction soft-fails on a failed or
  tag-less response. Automatic compaction records retry/backoff state and,
  once recovery is required, advances the compaction watermark with a fixed
  recovery summary that points the agent to the session recovery file. That
  recovery watermark only covers the transcript available at that failure:
  later messages can trigger another attempt and roll the recovery watermark
  forward so the live context remains bounded.

  The summarizer is injectable for tests: `opts[:summarizer]` or
  `config :salix_agent, :summarizer` (a 2-arity fun or `{mod, fun}` taking
  `(prev_summary, live_messages)`) bypasses the LLM entirely; test config
  pins `deterministic_summary/2` so replay-parity suites stay stable.

  Microcompaction is intentionally NOT ported.
  """

  require Logger
  require SalixAgent.InternalSession

  alias CommaLog
  alias SalixAgent.AgentActor
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionFleet
  alias SalixAgent.InternalSessionStore
  alias SalixAgent.InternalSessionStore.Revision
  alias SalixAgent.SessionDriver

  # The model configuration fields the kernel reads.
  @config_fields [
    :protocol,
    :provider,
    :model,
    :base_url,
    :max_tokens,
    :context_tokens,
    :compaction_strategy,
    :context_compaction_strategy,
    :compaction
  ]

  @type session_state :: InternalSession.t()
  @type runtime_context :: %{
          required(:agent_id) => String.t(),
          required(:session_id) => String.t(),
          optional(atom()) => term()
        }

  @typedoc """
  String-keyed compact result. `"status"` is required; `"reason"` is present
  only for classified non-success outcomes.
  """
  @type compact_result :: %{required(String.t()) => String.t()}

  @doc """
  True if the session's live context is over the compaction trigger.

  Default: provider-observed prompt tokens > 0.9 × the context window
  (`opts[:context_tokens]`, willow's 128000 default). `opts[:threshold]` (or
  `config :salix_agent, :compaction_threshold`) switches to a raw byte
  threshold — the test/ops seam.
  """
  @spec should_compact?(session_state(), keyword()) :: boolean()
  def should_compact?(session, opts \\ []) when InternalSession.is_session(session),
    do:
      InternalSession.should_compact?(
        session,
        opts[:threshold],
        opts[:context_tokens],
        opts[:model]
      )

  @doc "The compaction facts of the kernel's `activation_plan` query."
  def required_facts(llm_opts) do
    %{
      "config" => kernel_config(llm_opts),
      "threshold" => nil,
      "context_tokens" => nil,
      "model" => nil
    }
  end

  @doc """
  Compact one session: summarize the live context and commit a `compaction`
  event. The result map classifies owner-handled outcomes so explicit compact
  callers do not infer completion from `summary_sequence`.
  """
  @spec compact(runtime_context(), String.t(), keyword()) ::
          {:ok, runtime_context(), compact_result()} | {:error, term()}
  def compact(context, session_id, opts \\ [])

  def compact(%SalixStore.Agent.Owned{}, _session_id, _opts),
    do: {:error, :agent_lease_not_session_runtime_context}

  def compact(%{agent_id: agent_id} = context, session_id, opts) do
    with :ok <- require_session_context(context, session_id),
         do: InternalSessionFleet.compact_session(agent_id, session_id, :compact, context, opts)
  end

  @doc """
  Compact one session when it crosses the trigger, through the session's
  owner. The owner's own automatic compaction runs in its session driver.
  It reads only the target session and never scans the agent's session set.
  """
  @spec maybe_compact_session(runtime_context(), String.t(), keyword()) ::
          {:ok, runtime_context(), compact_result()} | {:error, term()}
  def maybe_compact_session(context, session_id, opts \\ [])

  def maybe_compact_session(%SalixStore.Agent.Owned{}, _session_id, _opts),
    do: {:error, :agent_lease_not_session_runtime_context}

  def maybe_compact_session(%{agent_id: agent_id} = context, session_id, opts) do
    with :ok <- require_session_context(context, session_id),
         do:
           InternalSessionFleet.compact_session(
             agent_id,
             session_id,
             :maybe_compact,
             context,
             opts
           )
  end

  # ---- the kernel's session driver ----
  #
  # The kernel sequences a compaction (`session_step`): admission, the model
  # configuration it asks for, the summarizing request, how the answer reads,
  # and the commit. The host answers each effect below.

  @doc false
  # A compaction's host: the runtime context, the session it read, and the
  # options and configuration its effects resolve along the way.
  def host(context, session, opts) do
    %{
      agent_id: context.agent_id,
      session_id: InternalSession.session_id(session),
      context: context,
      session: session,
      state: revision_state(context) || session,
      opts: opts
    }
  end

  @doc false
  # The driver event that starts a compaction.
  def event(mode, opts, continuation) when mode in [:compact, :maybe_compact],
    do: {:compact, mode, prepare_facts(opts), continuation}

  @doc false
  # One compaction effect. `{:answer, value, host, driver}` answers the driver;
  # `{:summarize, plan}` asks the caller to run the model call (inline, or in a
  # dependency job) and to answer with `summarized/2`; `{:result, result}` is
  # the compaction's result for its continuation.
  def perform(host, driver, effect) do
    case effect do
      {:compaction_facts, _mode} ->
        {:answer, prepare_facts(host.opts), host, driver}

      :compaction_config ->
        case compaction_llm_opts(host.context, host.opts) do
          {:ok, llm_opts} ->
            host = %{host | opts: Keyword.put(host.opts, :llm_opts, llm_opts)}
            {:answer, {:ok, kernel_config(llm_opts)}, host, driver}

          {:error, {:session_config, reason}} ->
            {:answer, {:error, kernel_term(reason)}, host, driver}
        end

      {:compaction_prompt, _plan} ->
        compaction_prompt(host, driver)

      {:summarize, kernel_plan, prompt} ->
        {:summarize, Map.merge(host, %{kernel: kernel_plan, prompt: prompt})}

      {:commit, events, opts, mode} ->
        commit(host, driver, events, opts, mode)

      {:compacted, result, _continuation} ->
        {:result, public_result(host, result)}
    end
  end

  @doc false
  # The model call's outcome as the kernel reads it.
  def summarized(plan, outcome) do
    log_compaction_outcome(plan, outcome)
    kernel_outcome(outcome)
  end

  defp compaction_prompt(
         %{agent_id: agent_id, session_id: session_id, session: session} = host,
         driver
       ) do
    case AgentActor.runtime_session_config(agent_id, %{
           platform: InternalSession.get(session, :platform),
           session_context: session
         }) do
      {:ok, session_config} ->
        tenant_id =
          case Map.get(session_config, :tenant_id) || Map.get(session_config, "tenant_id") do
            tenant_id when is_binary(tenant_id) and tenant_id != "" -> tenant_id
            _missing -> "agent:" <> agent_id
          end

        prompts = %{
          "prompt" => session_system_prompt(host.context, session, session_config),
          "refreshed" => session_config.system_prompt || build_session_prompt(host.context)
        }

        host =
          host
          |> Map.put(:opts, Keyword.put(host.opts, :runtime_session_config, session_config))
          |> Map.put(:tenant_id, tenant_id)

        {:answer, {:ok, prompts}, host, driver}

      {:error, reason} ->
        Logger.warning(
          "compaction skipped: agent=#{agent_id} session=#{session_id} config: #{inspect(reason)}"
        )

        {:answer, {:error, kernel_term(reason)}, host, driver}
    end
  end

  # The kernel's events: a plain commit, or the summary commit, which the
  # driver checks against the summarized view again when the session moved.
  defp commit(host, driver, events, opts, mode) do
    %{agent_id: agent_id, session_id: session_id, context: context} = host

    committed =
      SalixAgent.SubscriptionLog.context([agent_id: agent_id, session_id: session_id], fn ->
        SalixAgent.SubscriptionLog.span("compaction_commit", [], fn ->
          SessionDriver.commit(
            agent_id,
            session_id,
            context[:revision],
            driver,
            {events, opts, mode}
          )
        end)
      end)

    case committed do
      {:ok, revision, driver} ->
        {:answer, :ok, archived(host, revision, mode), driver}

      {:rerouted, revision, driver, effect} ->
        {:rerouted, with_revision(host, revision), driver, effect}

      {:error, _} = error ->
        {:answer, error, host, driver}
    end
  end

  # Archiving writes the session again behind this revision; the next owner
  # step reads the archived state once.
  defp archived(host, revision, %{"archive" => true}) do
    InternalSessionStore.archive_compacted(host.agent_id, host.session_id)
    host = with_revision(host, revision)
    %{host | context: Map.delete(host.context, :revision)}
  end

  defp archived(host, revision, _mode), do: with_revision(host, revision)

  defp with_revision(host, revision),
    do: %{host | context: Map.put(host.context, :revision, revision), state: revision.state}

  defp public_result(host, {:ok, result}), do: {:ok, host.context, result}

  defp public_result(
         _host,
         {:error, {:stale_compaction_view, %{expected: expected, actual: actual}}}
       ),
       do:
         {:error,
          {:stale_compaction_view,
           %{
             expected: summarized_view_fingerprint(expected),
             actual: summarized_view_fingerprint(actual)
           }}}

  defp public_result(_host, {:error, _} = error), do: error

  defp revision_state(%{revision: %Revision{state: state}}), do: state
  defp revision_state(_context), do: nil

  defp prepare_facts(opts) do
    facts = %{
      "threshold" => opts[:threshold],
      "context_tokens" => opts[:context_tokens],
      "model" => opts[:model],
      "overflow_recovery" => Keyword.get(opts, :context_overflow_recovery, false),
      "strategy" => [
        opts[:compaction_strategy],
        Application.get_env(:salix_agent, :compaction_strategy)
      ],
      "source_message_id" => opts[:result_source_message_id]
    }

    case Keyword.get(opts, :llm_opts) do
      nil -> facts
      llm_opts -> Map.put(facts, "config", kernel_config(llm_opts))
    end
  end

  @doc false
  @spec execute_prepared(map()) :: term()
  def execute_prepared(plan) do
    SalixAgent.SubscriptionLog.context(
      [agent_id: plan.agent_id, session_id: plan.session_id],
      fn ->
        SalixAgent.SubscriptionLog.span("compaction_execute", [], fn -> summarize(plan) end)
      end
    )
  end

  @doc """
  Settle an ALREADY-ACKNOWLEDGED control compaction that cannot run, binding
  the result to its source id.

  `stage_session_compact_control/1` answers `{:ok, :committed}` the moment it
  sends its ephemeral message, and the public API then polls for a result
  carrying that source id. Dropping the request therefore does not "retry
  later" — it leaves that caller polling to its deadline. Anything that
  declines an acknowledged control must commit a result instead.
  """
  @spec commit_compact_noop_result(String.t(), String.t(), String.t(), term()) ::
          {:ok, compact_result()} | {:error, term()}
  def commit_compact_noop_result(agent_id, session_id, source_message_id, reason)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(source_message_id),
      do: commit_settled_result(agent_id, session_id, "noop", reason, source_message_id)

  @doc false
  @spec commit_compact_hard_failure_result(String.t(), String.t(), String.t(), term()) ::
          {:ok, compact_result()} | {:error, term()}
  def commit_compact_hard_failure_result(agent_id, session_id, source_message_id, reason)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(source_message_id),
      do: commit_settled_result(agent_id, session_id, "failed_hard", reason, source_message_id)

  defp commit_settled_result(agent_id, session_id, status, reason, source_message_id) do
    {result, events} =
      InternalSession.compaction_result_events(
        session_id,
        status,
        kernel_term(reason),
        source_message_id
      )

    case InternalSessionStore.commit(agent_id, session_id, events) do
      {:ok, _session} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # The kernel reads summaries, provider items, skips, and failures. A model
  # call may still answer with a summarized outcome.
  defp kernel_outcome({:ok, {:summary, summary}}), do: {:summary, summary}
  defp kernel_outcome({:ok, {:provider_compaction, items, _trace}}), do: {:provider_items, items}
  defp kernel_outcome({:error, reason}), do: {:error, kernel_term(reason)}
  defp kernel_outcome(outcome), do: kernel_term(outcome)

  defp log_compaction_outcome(%{agent_id: agent_id, session_id: session_id}, {:error, reason}) do
    Logger.warning(
      "compaction summarize failed: agent=#{agent_id} session=#{session_id} #{inspect(reason)}"
    )

    CommaLog.log("compaction_error", %{
      agent_id: agent_id,
      session_id: session_id,
      reason: reason
    })
  end

  defp log_compaction_outcome(_plan, _outcome), do: :ok

  defp summarized_view_fingerprint(view) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(view))
    |> Base.encode16(case: :lower)
  end

  # Kernel terms carry data only. A process, reference, port, or function in
  # a failure reason crosses as its inspected text.
  defp kernel_term(value)
       when is_pid(value) or is_reference(value) or is_port(value) or is_function(value),
       do: inspect(value)

  defp kernel_term(value) when is_list(value), do: kernel_list(value)

  defp kernel_term(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&kernel_term/1) |> List.to_tuple()

  defp kernel_term(value) when is_map(value),
    do:
      value
      |> :maps.to_list()
      |> Map.new(fn {key, item} -> {kernel_term(key), kernel_term(item)} end)

  defp kernel_term(value), do: value

  defp kernel_list([head | tail]), do: [kernel_term(head) | kernel_list(tail)]
  defp kernel_list([]), do: []
  defp kernel_list(tail), do: kernel_term(tail)

  # ---- the summary ----

  defp summarize(plan) do
    summarizer = plan.opts[:summarizer] || Application.get_env(:salix_agent, :summarizer)

    if summarizer && plan.kernel["strategy"] != "openai_responses" do
      {:summary, run_summarizer(summarizer, plan.kernel["summary"], plan.kernel["live"])}
    else
      with {:ok, llm_opts} <- compaction_llm_opts(plan.context, plan.opts) do
        request =
          InternalSession.query(
            plan.session,
            :compaction_request,
            {plan.kernel, kernel_config(llm_opts), plan.prompt},
            SalixAgent.ImageRefs.reader(image_context(plan))
          )

        case request do
          :skip -> :skip
          {:summary, messages} -> summary_call(plan, messages, llm_opts)
          {:provider, messages} -> provider_call(plan, messages, llm_opts)
        end
      end
    end
  catch
    {:error, _} = err -> err
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_summarizer({mod, fun}, summary, live), do: apply(mod, fun, [summary, live])
  defp run_summarizer(fun, summary, live) when is_function(fun, 2), do: fun.(summary, live)

  defp summary_call(plan, messages, llm_opts) do
    CommaLog.log("compaction_start", %{
      agent_id: plan.agent_id,
      session_id: plan.session_id,
      message_count: length(messages),
      estimated_tokens: InternalSession.estimated_tokens(plan.session)
    })

    case SalixAgent.LLM.complete(
           messages,
           plan.opts[:runtime_session_config].tool_specs,
           metering_opts(llm_opts, plan.session, "compaction", "system"),
           archive_identity(plan)
         ) do
      {:final, text} -> {:summary_text, to_string(text)}
      {:final, text, _meta} -> {:summary_text, to_string(text)}
      {:final, text, _provider_meta, _trace_meta} -> {:summary_text, to_string(text)}
      {:error, %{} = meta} -> {:error, meta}
      {:assistant, text, _calls} -> {:summary_text, to_string(text)}
      {:assistant, text, _calls, _meta} -> {:summary_text, to_string(text)}
      {:assistant, text, _calls, _provider_meta, _trace_meta} -> {:summary_text, to_string(text)}
      other -> {:error, {:unexpected_llm_result, elem_or_atom(other)}}
    end
  end

  defp provider_call(plan, messages, llm_opts) do
    CommaLog.log("provider_compaction_start", %{
      agent_id: plan.agent_id,
      session_id: plan.session_id,
      strategy: "openai_responses",
      message_count: length(messages),
      estimated_tokens: InternalSession.estimated_tokens(plan.session)
    })

    case SalixAgent.LLM.compact_context(
           messages,
           plan.opts[:runtime_session_config].tool_specs,
           metering_opts(llm_opts, plan.session, "compaction", "system"),
           archive_identity(plan)
         ) do
      {:ok, items, _trace_meta} -> {:provider_items, items}
      {:unsupported, reason} -> {:error, {:provider_compaction_unsupported, reason}}
      {:error, %{} = meta} -> {:error, meta}
      other -> {:error, {:unexpected_provider_compaction_result, elem_or_atom(other)}}
    end
  end

  defp compaction_llm_opts(context, opts) do
    case Keyword.get(opts, :llm_opts) do
      nil ->
        case SalixAgent.LlmResolver.resolve_runtime(context.agent_id) do
          {:ok, llm} -> {:ok, llm}
          {:error, reason} -> {:error, {:session_config, reason}}
        end

      resolved ->
        {:ok, resolved}
    end
  end

  # The kernel's projection of the model configuration.
  defp kernel_config(llm_opts) do
    Map.new(@config_fields, fn key ->
      {Atom.to_string(key), kernel_term(llm_opt(llm_opts, key))}
    end)
  end

  # The window and model read the text key first, as the retired
  # `context_window/1` and `model_name/1` did.
  defp llm_opt(opts, key) when is_map(opts) and key in [:context_tokens, :model],
    do: opts[Atom.to_string(key)] || opts[key]

  defp llm_opt(opts, key) when is_map(opts), do: opts[key] || opts[Atom.to_string(key)]
  defp llm_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp llm_opt(_opts, _key), do: nil

  defp image_context(%{context: context, session: session} = plan) do
    session_config = plan.opts[:runtime_session_config]

    %{
      agent_id: context.agent_id,
      session_id: plan.session_id,
      tenant_id: session_config.tenant_id,
      group_id: session_config.group_id,
      async_result_resolver: fn seq -> resolve_async_result(context.agent_id, session, seq) end
    }
  end

  defp resolve_async_result(agent_id, session, seq) when is_integer(seq) and seq > 0 do
    case InternalSession.query(session, :async_result_record, seq) do
      %{} = record ->
        {:ok, record}

      nil ->
        InternalSessionStore.fetch_archived_record(
          agent_id,
          InternalSession.session_id(session),
          session,
          seq
        )
    end
  end

  defp resolve_async_result(_agent_id, _session, _seq), do: {:error, :not_found}

  defp metering_opts(opts, session, entrypoint, actor_type) when is_list(opts) do
    opts
    |> Keyword.put(:billing_context, session_billing_context(session))
    |> Keyword.put(:entrypoint, entrypoint)
    |> Keyword.put(:actor_type, actor_type)
  end

  defp metering_opts(opts, session, entrypoint, actor_type) when is_map(opts) do
    opts
    |> Map.put("billing_context", session_billing_context(session))
    |> Map.put("entrypoint", entrypoint)
    |> Map.put("actor_type", actor_type)
  end

  defp metering_opts(_opts, session, entrypoint, actor_type),
    do: %{
      "billing_context" => session_billing_context(session),
      "entrypoint" => entrypoint,
      "actor_type" => actor_type
    }

  defp session_billing_context(session) do
    InternalSession.get(session, :billing_context) || %{}
  end

  # Compaction is the archive's most valuable boundary — it ships the whole
  # conversation and is the last point that history exists before it is
  # discarded — so an unattributed compaction row is the worst one to have.
  # The billing context cannot supply this: no context in this system carries a
  # `session_id`, and only the `salix_`-prefixed agent id is real.
  defp archive_identity(plan), do: [agent_id: plan.agent_id, session_id: plan.session_id]

  defp session_system_prompt(context, session, runtime_session_config) do
    case InternalSession.get(session, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" -> prompt
      _ -> runtime_session_config.system_prompt || build_session_prompt(context)
    end
  end

  defp build_session_prompt(%{agent_id: agent_id}) do
    case AgentActor.runtime_session_config(agent_id, %{}) do
      {:ok, %{system_prompt: prompt}} ->
        prompt

      {:error, reason} ->
        raise "agent runtime config error: #{inspect(reason)}"
    end
  end

  defp elem_or_atom(tuple) when is_tuple(tuple), do: elem(tuple, 0)
  defp elem_or_atom(other), do: other

  # ---- the resident revision ----
  #
  defp require_session_context(%{session_id: session_id}, session_id)
       when is_binary(session_id),
       do: :ok

  defp require_session_context(%{session_id: actual}, expected),
    do: {:error, {:session_runtime_context_mismatch, expected, actual}}

  defp require_session_context(_context, session_id),
    do: {:error, {:session_runtime_context_missing, session_id}}

  # ---- reads ----

  @doc """
  The conversation to send the LLM: the summary (if any) followed by messages
  after `compacted_through`. Used by the round driver so compaction bounds the
  request while the journal keeps everything.
  """
  @spec context(session_state()) :: [map()]
  def context(session) when InternalSession.is_session(session) do
    InternalSession.query(session, :provider_context)
  end

  @doc """
  The messages of `context/1` that `selector` selects, in order:
  `{:runtime_message_id, id}` or `{:tool_ids, ids}` for tool results by
  message id. The kernel does the per-message work for these messages only.
  """
  @spec context_where(session_state(), {:runtime_message_id, term()} | {:tool_ids, [term()]}) ::
          [map()]
  def context_where(session, selector) when InternalSession.is_session(session) do
    InternalSession.query(session, :provider_context_where, selector)
  end

  @doc """
  The context window the trigger ratio is measured against: the template's
  `context_tokens` when positive, else willow's 128000 default.

  Public so a status surface reports the SAME window the kernel compacts
  against.
  """
  @spec context_window(term()) :: pos_integer()
  def context_window(llm_opts), do: InternalSession.compaction_window(kernel_config(llm_opts))

  @doc """
  The diagnostic live-context token estimate. Automatic compaction uses
  provider-reported usage, not this estimate.
  """
  @spec context_tokens_used(session_state()) :: non_neg_integer()
  def context_tokens_used(session) when InternalSession.is_session(session),
    do: InternalSession.estimated_tokens(session)

  @doc """
  Willow's deterministic stand-in for tests/replay suites
  (`config :salix_agent, :summarizer` in test config).
  """
  @spec deterministic_summary(String.t() | nil, [map()]) :: String.t()
  def deterministic_summary(prev_summary, messages) do
    base = if prev_summary, do: prev_summary <> " | ", else: ""
    last = messages |> Enum.map(& &1[:id]) |> Enum.max(fn -> 0 end)
    base <> "summary of #{length(messages)} messages through id #{last}"
  end
end
