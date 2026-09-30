defmodule KernelAgent.Session do
  @moduledoc """
  The one session: a process that owns the kernel revision, admits input from
  any number of conversations, and runs model rounds until the kernel says the
  session is idle or waiting.

  Input goes through the kernel's `input` command. The kernel's session driver
  (`session_step`) decides everything that follows, as it does for
  production. This module performs the effects it asks for: storage,
  commands, configuration, tools, model calls, and timers.
  """

  use GenServer
  require Logger

  alias KernelAgent.{Driver, LLM, Tools}

  ## API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  Admits one user message from `conversation_id`. Returns once the input is
  durable: `:committed`, `:duplicate`, or `{:error, reason}`. Processing
  follows in the background.
  """
  def deliver(server, conversation_id, text, opts \\ []),
    do: GenServer.call(server, {:deliver, conversation_id, text, opts}, :infinity)

  @doc "Waits until the session has processed everything it can now."
  def await_idle(server), do: GenServer.call(server, :await_idle, :infinity)

  @doc "The kernel state handle, for inspection."
  def state(server), do: GenServer.call(server, :state)

  ## Server

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)
    agent_id = Keyword.get(opts, :agent_id, "local")
    session_id = Keyword.get(opts, :session_id, "ses1_0000000000000000001")

    # The model call is a linked process, so it ends with the session.
    Process.flag(:trap_exit, true)

    case Driver.open(root, agent_id, session_id, %{"name" => "Local"}) do
      {:ok, rev, _origin} ->
        send(self(), :process)

        {:ok,
         %{
           root: root,
           rev: rev,
           llm: Keyword.fetch!(opts, :llm),
           host: host(opts),
           machine: nil,
           checkpoint: nil,
           round: %{},
           inflight: nil,
           queue_snapshot: nil,
           retry: nil,
           waiters: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:deliver, conversation_id, text, opts}, _from, ctx) do
    {result, rev} =
      Driver.command(
        ctx.rev,
        :input,
        {input_entry(conversation_id, text, opts), Driver.fresh?(ctx.rev)},
        &effect/1
      )

    send(self(), :process)

    reply =
      case result do
        {:ok, outcome} -> outcome
        other -> other
      end

    {:reply, reply, %{ctx | rev: rev}}
  end

  def handle_call(:await_idle, from, ctx) do
    send(self(), :release)
    {:noreply, %{ctx | waiters: [from | ctx.waiters]}}
  end

  def handle_call(:state, _from, ctx), do: {:reply, Driver.state(ctx.rev), ctx}

  @impl true
  def handle_info(:process, ctx), do: {:noreply, ctx |> process() |> release()}

  def handle_info({:retry, _at}, ctx),
    do: {:noreply, %{ctx | retry: nil} |> process() |> release()}

  def handle_info(:release, ctx), do: {:noreply, release(ctx)}

  # The model call finished. A call that ended without a response is lost:
  # the kernel records the failure, as production does.
  def handle_info({:EXIT, pid, reason}, %{inflight: {pid, kind}} = ctx) do
    event =
      case {kind, reason} do
        {:model, {:shutdown, {:response, response}}} ->
          {:model, response}

        {:model, other} ->
          {:model_lost, %{"detail" => inspect(other), "queue_snapshot" => ctx.queue_snapshot}}

        {:summary, {:shutdown, {:response, response}}} ->
          {:done, summary_outcome(response)}

        {:summary, other} ->
          {:done, {:error, inspect(other)}}
      end

    {:noreply, %{ctx | inflight: nil} |> step(event) |> release()}
  end

  def handle_info({:EXIT, _pid, _reason}, ctx), do: {:noreply, ctx}

  # Waiters return when no model call runs and no retry is armed.
  defp release(%{inflight: nil, retry: nil} = ctx) do
    Enum.each(ctx.waiters, &GenServer.reply(&1, :ok))
    %{ctx | waiters: []}
  end

  defp release(ctx), do: ctx

  ## Effects

  # The kernel's session driver (`session_step`) decides every step: recovery
  # and repair, activation, compaction, model rounds, and the agent loop. Each
  # step asks for one effect, and the host answers it with `{:done, value}`.
  # This runtime runs no background tools, so no live process owns a call.
  defp process(%{inflight: nil} = ctx),
    do: step(%{ctx | machine: nil}, {:process, %{"live" => [], "checkpoint" => ctx.checkpoint}})

  defp process(ctx), do: ctx

  defp step(ctx, event) do
    query = &Driver.query(ctx.rev, :session_step, &1, &2)
    {machine, effect} = SalixVerifiedKernel.SessionStep.run(query, ctx.machine, event, &read/1)
    ctx = %{ctx | machine: machine}

    # A step ends with an idle machine, or waits for a model call.
    if machine["phase"] == "idle" or effect == :await,
      do: conclude(ctx, effect),
      else: perform(ctx, effect)
  end

  defp answer(ctx, value), do: step(ctx, {:done, value})

  # The session has more to do now: process it again in this callback, so
  # an idle waiter does not return in between.
  defp conclude(ctx, :reprocess), do: process(ctx)

  defp conclude(ctx, outcome) when outcome in [:idle, :await], do: ctx

  defp conclude(ctx, {:apply_recovery, recovery}) do
    Logger.error("recovery stopped: #{inspect(recovery)}")
    ctx
  end

  defp conclude(ctx, stopped) do
    Logger.error("session stopped: #{inspect(stopped)}")
    ctx
  end

  # Recovery, and the checkpoint the next recovery starts from.
  defp perform(ctx, :recover) do
    {result, rev} = Driver.command(ctx.rev, :recover, nil, &effect/1)
    answer(%{ctx | rev: rev}, result)
  end

  defp perform(ctx, {:apply_recovery, recovery}),
    do: answer(%{ctx | checkpoint: recovery[:checkpoint]}, :ok)

  # One owner writes this store, so a commit never meets a newer revision.
  defp perform(ctx, {:commit, events, opts, _mode}) do
    {:ok, rev} = Driver.commit(ctx.rev, events, Keyword.get(opts || [], :hwm))
    answer(%{ctx | rev: rev}, :ok)
  end

  defp perform(ctx, {:write, events}),
    do: answer(%{ctx | rev: Driver.write(ctx.rev, events, nil)}, :ok)

  defp perform(ctx, :fence) do
    {:ok, rev} = Driver.fence(ctx.rev)
    answer(%{ctx | rev: rev}, :ok)
  end

  defp perform(ctx, :refresh), do: answer(ctx, :ok)

  defp perform(ctx, {:plan, mode}) do
    {rev, outcome, changed} = Driver.plan(ctx.rev, mode)
    answer(%{ctx | rev: rev}, {outcome, changed})
  end

  defp perform(ctx, {:command, name, args}) do
    {result, rev} = Driver.command(ctx.rev, name, args, &effect/1)
    answer(%{ctx | rev: rev}, result)
  end

  # The activation's configuration: the prompt, and the compaction facts
  # that decide whether the session compacts first.
  defp perform(ctx, :round_config),
    do:
      answer(
        ctx,
        {:ok, %{"prompt" => ctx.host["prompt"], "compaction" => ctx.host["compaction"]}}
      )

  # The model call never starts beside the activation fence here.
  defp perform(ctx, {:speculate, _args}), do: answer(ctx, :sequential)

  defp perform(ctx, {:notify, kind, data}) do
    Logger.debug("loop notify #{kind}: #{inspect(data, limit: 8)}")
    answer(ctx, :ok)
  end

  # Host facts: this runtime's one session is its agent's Router, and it has
  # no wait delegates.
  defp perform(ctx, {:fact, :canonical_router}), do: answer(ctx, true)
  defp perform(ctx, {:fact, {:delegates_busy, _wait}}), do: answer(ctx, false)

  # Rounds: the kernel builds the request and the round facts from this
  # configuration.
  defp perform(ctx, {:round_prepare, kind}) when kind in [:guard, :failure],
    do: answer(ctx, {:ok, facts_config()})

  defp perform(ctx, {:round_prepare, _kind}) do
    config =
      Map.merge(facts_config(), %{
        "protocol" => ctx.host["protocol"],
        "cfg" => ctx.host["cfg"],
        "tools" => ctx.host["tools"],
        "nonce" => System.unique_integer([:positive])
      })

    answer(ctx, {:ok, config})
  end

  defp perform(ctx, {:round_abandon, _reason}), do: answer(ctx, :ok)

  # The model call runs in its own process, so input keeps arriving.
  defp perform(ctx, {:call_model, request, _facts}) do
    llm = ctx.llm
    pid = spawn_link(fn -> exit({:shutdown, {:response, LLM.complete(llm, request)}}) end)
    snapshot = Driver.get(ctx.rev, :next_queue_id)
    answer(%{ctx | inflight: {pid, :model}, queue_snapshot: snapshot}, :started)
  end

  defp perform(ctx, {:round, facts}) do
    round = %{source_ids: facts["source_ids"] || [], trace: facts["trace"] || %{}}
    answer(%{ctx | round: round}, :ok)
  end

  defp perform(ctx, {:round_outcome, _outcome}), do: answer(ctx, :ok)

  defp perform(ctx, {:call_failed, _committed}) do
    Logger.warning("model call failed")
    answer(ctx, :ok)
  end

  # Loop data: the kernel's queries build it from this runtime's facts.
  defp perform(ctx, {:build_record, spec}) do
    facts = %{
      "role" => ctx.host["role"],
      "canonical_router" => true,
      "source_ids" => ctx.round.source_ids,
      "trace" => ctx.round.trace
    }

    case Driver.query(ctx.rev, :loop_record, {spec, facts}) do
      %{"record" => record, "scope" => scope} ->
        round = Map.merge(ctx.round, %{scope: scope, decision: spec["decision_outcome"]})
        answer(%{ctx | round: round}, {:record, record})

      %{"record" => record} ->
        answer(ctx, {:record, record})
    end
  end

  defp perform(ctx, {:run_tools, calls, flags}) do
    results = ctx |> operations(calls, flags) |> Tools.run(ctx.root)
    answer(ctx, {:tools_done, results, false})
  end

  defp perform(ctx, {:store_results, pending, results}) do
    base = Driver.get(ctx.rev, :next_message_id)
    batch = %{"checkpoint" => pending["checkpoint"], "label" => true}
    {:ok, events, hwm} = Driver.query(ctx.rev, :tool_batch_events, {batch, results, %{}})
    answer(ctx, {:results_stored, events, hwm, base, results})
  end

  # This runtime never plans admission (`"admission" => nil`).
  defp perform(_ctx, {:commit_planned_results, _pending, _results}),
    do: raise("unexpected planned results: this runtime does not plan admission")

  # Compaction: the host's compaction facts carry the model configuration,
  # and the summary runs in its own process as a model call does.
  defp perform(ctx, {:compaction_facts, _mode}), do: answer(ctx, ctx.host["compaction"])
  defp perform(ctx, :compaction_config), do: answer(ctx, {:ok, ctx.host["compaction"]})

  defp perform(ctx, {:compaction_prompt, _plan}) do
    prompt = ctx.host["prompt"]
    answer(ctx, {:ok, %{"prompt" => prompt, "refreshed" => prompt}})
  end

  defp perform(ctx, {:summarize, plan, prompt}) do
    host = ctx.host
    args = {plan, host["compaction"], prompt, host["protocol"], host["cfg"], host["tools"]}

    case Driver.query(ctx.rev, :compaction_request, args) do
      :skip ->
        answer(ctx, :skip)

      {:summary, request} ->
        llm = ctx.llm
        pid = spawn_link(fn -> exit({:shutdown, {:response, LLM.complete(llm, request)}}) end)
        answer(%{ctx | inflight: {pid, :summary}}, :started)

      {:provider, _messages} ->
        answer(ctx, {:error, "provider_compaction_unsupported"})
    end
  end

  defp perform(ctx, {:compacted, _result, _continuation}), do: answer(ctx, :ok)

  defp perform(ctx, {:set_timer, :retry, at}) do
    if ctx.retry, do: Process.cancel_timer(ctx.retry)
    delay = max(0, at - System.system_time(:millisecond))
    answer(%{ctx | retry: Process.send_after(self(), {:retry, at}, delay)}, :ok)
  end

  defp perform(ctx, {:cancel_timer, :retry}) do
    if ctx.retry, do: Process.cancel_timer(ctx.retry)
    answer(%{ctx | retry: nil}, :ok)
  end

  # This runtime arms only the retry timer: it has no waits.
  defp perform(ctx, {:set_timer, kind, _data}), do: unsupported(ctx, kind)
  defp perform(ctx, {:cancel_timer, kind}), do: unsupported(ctx, kind)

  defp unsupported(ctx, kind) do
    Logger.warning("unsupported timer #{inspect(kind)}")
    answer(ctx, :ok)
  end

  defp facts_config, do: %{"role" => "router", "canonical_router" => true, "guard_config" => true}

  # The model answer as compaction reads it.
  defp summary_outcome({:final, text}) when is_binary(text), do: {:summary_text, text}
  defp summary_outcome({:final, text, _meta}) when is_binary(text), do: {:summary_text, text}
  defp summary_outcome({:assistant, text, _calls}) when is_binary(text), do: {:summary_text, text}

  defp summary_outcome({:assistant, text, _calls, _meta}) when is_binary(text),
    do: {:summary_text, text}

  defp summary_outcome({:error, meta}) when is_map(meta), do: {:error, meta}
  defp summary_outcome(other), do: {:error, inspect(other)}

  # As in production, the kernel applies the call envelope, and then admits
  # each call against the round's reply scope. A runtime failure notice is
  # admitted under the scope that authorized it.
  defp operations(ctx, calls, flags) do
    notice? = flags["mode"] == "runtime_failure_notice"
    role = ctx.host["role"]

    scope =
      if notice?,
        do: Driver.query(ctx.rev, :notice_reply_scope, {flags["aid"], role, true}),
        else: ctx.round[:scope]

    admission = %{
      "llm_tool_envelope" => true,
      "runtime_failure_delivery" => notice?,
      "terminal_decision_outcome" => if(notice?, do: nil, else: ctx.round[:decision])
    }

    ctx.rev
    |> Driver.query(:call_envelopes, {calls, true})
    |> Enum.map(&admit(&1, scope, admission))
  end

  defp admit(call, scope, admission) do
    base = %{
      "id" => field(call, :id),
      "runtime_failure_reply" => field(call, :runtime_failure_reply)
    }

    if call[:guidance_error] do
      Map.merge(base, %{
        "name" => call[:guidance_tool],
        "error" => call[:guidance_error],
        "guidance_reason" => call[:guidance_reason]
      })
    else
      name = field(call, :name)
      request = %{"name" => name, "args" => field(call, :args) || %{}, "id" => base["id"]}
      request = Map.put(request, "reply_intent", call[:reply_intent])

      case SalixVerifiedKernel.AgentLoop.terminal_reply_admission(request, scope, admission) do
        {:ok, args, binding} ->
          Map.merge(base, %{
            "name" => name,
            "args" => args,
            "ifc" => call[:ifc],
            "binding" => binding
          })

        {:error, reason} ->
          Map.merge(base, %{"name" => name, "refused" => reason})
      end
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # Reads for the kernel's crash repair and rounds. This runtime keeps no
  # archive, staged workspace results, or capability requests, and runs no
  # background tools. No tool here has a recoverable envelope, so a missing
  # result is a restart failure.
  defp read(:clock), do: System.system_time(:millisecond)
  defp read(:nonce), do: System.unique_integer([:positive])
  defp read({:archived_record, _seq}), do: nil
  defp read({:staged_result, _attempt}), do: {:error, :not_found}
  defp read({:reconcile_capability, _id, _result}), do: {:ok, :not_found}
  defp read({:restart, {"guidance", _call}, _guard}), do: :not_recoverable
  defp read({:restart, {"staged_result", _record}, _guard}), do: {:error, :not_found}

  defp read({:restart, request, _guard}),
    do: raise("restart plan needs a background tool observation: #{inspect(request)}")

  # The facts this runtime owns: its configuration, provider, tool catalog,
  # and Router role. It has no wait delegates.
  defp host(opts) do
    llm = Keyword.fetch!(opts, :llm)
    {protocol, cfg} = LLM.protocol(llm)

    %{
      "prompt" => Keyword.get(opts, :prompt, default_prompt()),
      "protocol" => protocol,
      "cfg" => cfg,
      "tools" => Tools.specs(),
      "compaction" => %{
        "protocol" => to_string(protocol),
        "cfg" => Map.put(cfg, :context_tokens, Keyword.get(opts, :context_tokens))
      },
      "role" => "router",
      "canonical_router" => true
    }
  end

  # Host I/O: answers to the command driver's effects. A local runtime has no
  # draft surface, workspace store, or visible-reply authority to consult.
  defp effect({:random, bytes}),
    do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp effect({:authorize, _scope}), do: :ok
  defp effect({:draft_clear, _scope}), do: :ok
  defp effect({:notify, _kind, _events}), do: :ok
  defp effect({:workspace, _id, _meta, _events, _billing}), do: :ok

  # The input entry: the text, and a trusted origin that names the
  # conversation. The kernel derives the reply target from the origin, and
  # shows the conversation in front of the text in each request
  # (`show_conversation`).
  defp input_entry(conversation_id, text, opts) do
    now = System.system_time(:millisecond)

    source =
      Keyword.get(opts, :source_message_id, "msg_#{now}_#{System.unique_integer([:positive])}")

    %{
      source_message_id: source,
      payload: %{
        content: text,
        role: "user",
        created_at: div(now, 1000),
        delivered_at_ms: now,
        trusted_origin: %{
          "provider" => "internal",
          "source_actor_type" => "user",
          "conversation_kind" => "user_chat",
          "conversation_id" => conversation_id,
          "source_message_id" => source,
          "show_conversation" => true
        }
      }
    }
  end

  defp default_prompt do
    """
    You are a helpful agent. Each user message arrives from a conversation named in its source.
    Reply to the conversation the current message came from, with end_turn and reply, or with call.
    Use fs.* operations for files in your workspace.
    """
  end
end
