defmodule SalixAgent.CondensedWorkspace.Decision do
  require SystemsRuntime.Proc

  @moduledoc """
  The Condensed Workspace check after a model round
  (docs/agent-runtime.md#condensed-workspace).

  When a model response has tool calls, `start/1` asks the global decision
  model two independent yes/no questions while the tools run: does the
  Condensed Workspace need an update, and is the Agent off-track. The
  evidence is the current Condensed Workspace, the newest visible
  conversation and the tool calls of this response, within 32 KiB. The
  visible conversation comes from the kernel (`request_conversation_tail`):
  messages the Session received from people and other Agents, and the text of
  the message-sending tool calls it made. Raw assistant text is private and
  is not evidence. By owner decision, IFC
  labels do not filter it (the same decision as the voice profile).

  `reminder/2` runs in the next round's activation. It waits for the answer
  until the deadline, which is 5 s after the start, and returns at most one
  advisory runtime message. `rethink` wins when both answers pass their
  thresholds (defaults: 50% for an update, 70% for a rethink). A timeout,
  an error, a refused budget or an answer below the thresholds sends
  nothing. The same reminder kind is not sent again until
  the Condensed Workspace revision changes or three checks have passed.

  The pending check and the repeat state belong to the Session actor process
  that runs the rounds, so they are kept in its process dictionary. A restart
  loses them, which is acceptable for advice.
  """

  require Logger

  alias SalixAgent.{CondensedWorkspace, Decide, InternalSession}
  alias SalixStore.CondensedWorkspaces, as: Store

  @max_args 32 * 1024
  @max_messages 16
  @max_message_bytes 1_500
  @max_call_bytes 1_000
  @default_deadline_ms 5_000
  # Measured against jev-1.13 on 20 labelled rounds (2026-10-05): rounds that
  # needed an update scored 0.69-0.95 and the others at most 0.21; off-track
  # rounds scored 0.88-0.97 and the others at most 0.20.
  @default_update_threshold_bp 5_000
  @default_rethink_threshold_bp 7_000
  @repeat_after_checks 3
  # A check older than this belongs to work the Session has moved past.
  @max_age_ms 10 * 60 * 1000

  @questions %{
    "needs_update" => %{
      "type" => "noul",
      "instructions" =>
        "The state has the Condensed Workspace (the shared list of current facts for every Agent of this Group), the newest messages this Agent received from people or other Agents and sent through message tools, and the tool calls the Agent has just made. " <>
          "Answer true when the conversation establishes or changes a fact that other Agents of the Group need, such as a decision, an owner, a status, a constraint or where something is, " <>
          "and the Condensed Workspace does not state it or states something the conversation shows is no longer true. Answer false otherwise."
    },
    "off_track" => %{
      "type" => "noul",
      "instructions" =>
        "The state has the Condensed Workspace (the shared list of current facts for every Agent of this Group), the newest messages this Agent received from people or other Agents and sent through message tools, and the tool calls the Agent has just made. " <>
          "Answer true when the Agent's recent replies and these tool calls are off-track: they contradict the Condensed Workspace or the request, repeat work that already failed, or pursue a goal the conversation does not ask for. Answer false otherwise."
    }
  }

  @doc """
  Starts the check for one model response, beside its tool execution.

  `attrs` has `:session` (the Session handle), `:calls`, `:agent_id`,
  `:session_id`, `:tenant_id`, `:group_id` and `:enabled`, and optionally the
  round's `:meter_ctx` and `:activation_key` for the `cw_evidence` phase fact.
  Returns `:started` or `:skipped`.
  """
  def start(%{enabled: true, calls: [_ | _]} = attrs) do
    with {:ok, _config} <- Decide.config(),
         true <- text?(attrs[:group_id]) and text?(attrs[:tenant_id]) do
      started_at_ms = SalixAgent.PhaseTelemetry.now_ms()
      deadline = SystemsClock.monotonic_time(:millisecond) + deadline_ms()
      conversation = conversation(attrs.session)
      calls = Enum.map(attrs.calls, &call_view/1)

      ctx = %{
        agent_id: attrs.agent_id,
        session_id: attrs.session_id,
        tenant_id: attrs.tenant_id,
        group_id: attrs.group_id,
        billing_context: InternalSession.get(attrs.session, :billing_context) || %{}
      }

      captured = SystemsObservability.Context.capture()

      task =
        SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
          SystemsObservability.Context.run(captured, fn ->
            check(attrs.group_id, conversation, calls, ctx, deadline)
          end)
        end)

      replace_pending(attrs.session_id, %{
        task: task,
        deadline: deadline,
        started_at: SystemsClock.monotonic_time(:millisecond)
      })

      Process.put({__MODULE__, :ref, task.ref}, attrs.session_id)

      SalixAgent.PhaseTelemetry.emit(
        :cw_evidence,
        attrs[:meter_ctx],
        attrs[:activation_key],
        started_at_ms
      )

      :started
    else
      _ -> :skipped
    end
  rescue
    exception ->
      Logger.warning("condensed workspace check did not start: #{inspect(exception.__struct__)}")

      :skipped
  end

  def start(_attrs), do: :skipped

  @doc """
  The advisory message for the round about to run and the window this call
  waited in: `{:none | {:messages, [payload]}, nil | %{started_at_ms:,
  ended_at_ms:}}`. Waits for a pending check until its deadline. The window
  is the round's `cw_wait` phase; it is nil when no check was pending.
  """
  def reminder(session_id, session_config) do
    case Process.delete({__MODULE__, :pending, session_id}) do
      nil ->
        {:none, nil}

      pending ->
        started_at_ms = SalixAgent.PhaseTelemetry.now_ms()
        result = await(pending)
        timing = %{started_at_ms: started_at_ms, ended_at_ms: SalixAgent.PhaseTelemetry.now_ms()}

        if CondensedWorkspace.enabled_config?(session_config),
          do: {decide_reminder(session_id, result), timing},
          else: {:none, timing}
    end
  end

  @doc """
  Keeps a check's reply that reached the Session actor's mailbox before the
  next round asked for it. The actor calls this for `{ref, %{condensed_workspace_check: _}}`.
  """
  def settle(ref, %{condensed_workspace_check: result}) when SystemsRuntime.Proc.is_ref(ref) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])

    with session_id when not is_nil(session_id) <- Process.delete({__MODULE__, :ref, ref}),
         %{task: %Task{ref: ^ref}} = pending <- Process.get({__MODULE__, :pending, session_id}) do
      Process.put({__MODULE__, :pending, session_id}, Map.put(pending, :settled, result))
    end

    :ok
  end

  defp await(%{task: task} = pending) do
    Process.delete({__MODULE__, :ref, task.ref})
    now = SystemsClock.monotonic_time(:millisecond)

    cond do
      now - pending.started_at > @max_age_ms ->
        SystemsRuntime.Task.shutdown(task, :brutal_kill)
        {:error, :expired}

      Map.has_key?(pending, :settled) ->
        pending.settled

      true ->
        await_reply(task, pending.deadline, now)
    end
  end

  defp await_reply(task, deadline, now) do
    case SystemsClock.yield(task, max(deadline - now, 0)) ||
           SystemsRuntime.Task.shutdown(task, :brutal_kill) do
      {:ok, %{condensed_workspace_check: result}} -> result
      {:exit, _reason} -> {:error, :crashed}
      nil -> {:error, :timeout}
    end
  end

  defp decide_reminder(session_id, {:ok, kind, revision}) when kind in [:update, :rethink] do
    history = Process.get({__MODULE__, :history, session_id}, %{checks: 0})
    checks = history.checks + 1
    last = Map.get(history, kind)

    repeat? =
      is_map(last) and last.revision == revision and checks - last.check < @repeat_after_checks

    if repeat? do
      Process.put({__MODULE__, :history, session_id}, %{history | checks: checks})
      :none
    else
      Process.put(
        {__MODULE__, :history, session_id},
        history |> Map.put(:checks, checks) |> Map.put(kind, %{revision: revision, check: checks})
      )

      SystemsRuntime.Telemetry.execute([:salix, :condensed_workspace, :reminder], %{count: 1}, %{
        kind: kind
      })

      {:messages, [payload(kind)]}
    end
  end

  defp decide_reminder(session_id, _result) do
    history = Process.get({__MODULE__, :history, session_id}, %{checks: 0})
    Process.put({__MODULE__, :history, session_id}, %{history | checks: history.checks + 1})
    :none
  end

  # One pending check per Session: a newer response supersedes the older one.
  defp replace_pending(session_id, pending) do
    case Process.put({__MODULE__, :pending, session_id}, pending) do
      %{task: old} ->
        Process.delete({__MODULE__, :ref, old.ref})
        SystemsRuntime.Task.shutdown(old, :brutal_kill)

      _ ->
        :ok
    end
  end

  # ---- the check (runs in its own task) ----

  defp check(group_id, conversation, calls, ctx, deadline) do
    result =
      with {:ok, workspace} <- Store.get(group_id),
           {:ok, args} <- args(workspace, conversation, calls),
           {:ok, answer} <- Decide.condensed_workspace_call(args, ctx, deadline) do
        {:ok, classify(answer), workspace.revision}
      end

    %{condensed_workspace_check: result}
  end

  @doc false
  def classify(%{"answers" => answers}) do
    rethink? =
      probability(answers, "off_track") >=
        setting(:rethink_threshold_bp, @default_rethink_threshold_bp)

    update? =
      probability(answers, "needs_update") >=
        setting(:update_threshold_bp, @default_update_threshold_bp)

    cond do
      rethink? -> :rethink
      update? -> :update
      true -> :good
    end
  end

  def classify(_answer), do: :good

  defp probability(answers, key) do
    case answers[key] do
      %{"probability_bp" => bp} when is_integer(bp) -> bp
      _ -> 0
    end
  end

  @doc false
  def args(workspace, conversation, calls) do
    base = %{
      "condensed_workspace" => Store.render(workspace.statements),
      "tool_calls" => calls
    }

    messages = fit(Enum.reverse(conversation), [], base)

    if byte_size(Jason.encode!(request(base, messages))) <= @max_args,
      do: {:ok, request(base, messages)},
      else: {:error, :too_large}
  end

  # `newest_first` is newest first; the result is oldest first.
  defp fit([], kept, _base), do: kept

  defp fit([message | older], kept, base) do
    next = [message | kept]

    if byte_size(Jason.encode!(request(base, next))) <= @max_args,
      do: fit(older, next, base),
      else: kept
  end

  defp request(base, messages),
    do: %{"state" => Map.put(base, "messages", messages), "questions" => @questions}

  # ---- evidence (runs in the Session actor) ----

  defp conversation(session) do
    session
    |> InternalSession.request_conversation_tail(@max_messages)
    |> List.wrap()
    |> Enum.flat_map(&entry/1)
  end

  # Inbound: who sent it (a person, another Agent, a system). Outbound: this
  # Agent, and the tool that carried the message.
  defp entry(%{"direction" => "in", "text" => text} = entry) when is_binary(text),
    do: [%{"from" => entry["from"] || "user", "text" => cut(text, @max_message_bytes)}]

  defp entry(%{"direction" => "out", "text" => text} = entry) when is_binary(text),
    do: [
      %{"from" => "this_agent", "via" => entry["tool"], "text" => cut(text, @max_message_bytes)}
    ]

  defp entry(_entry), do: []

  defp call_view(call) when is_map(call) do
    arguments = field(call, :arguments) || field(call, :args) || field(call, :input) || %{}

    encoded =
      case Jason.encode(arguments) do
        {:ok, json} -> json
        _ -> inspect(arguments, limit: 50)
      end

    %{"tool" => to_string(field(call, :name) || ""), "arguments" => cut(encoded, @max_call_bytes)}
  end

  defp call_view(_call), do: %{"tool" => "", "arguments" => ""}

  defp cut(text, max) when byte_size(text) <= max, do: text

  defp cut(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, size} ->
      size = size + byte_size(grapheme)
      if size > max - 3, do: {:halt, {acc, size}}, else: {:cont, {acc <> grapheme, size}}
    end)
    |> elem(0)
    |> Kernel.<>("…")
  end

  # ---- reminders ----

  @doc false
  def payload(:update) do
    CondensedWorkspace.payload(
      "Condensed Workspace may need an update",
      "Advisory check: your recent work appears to establish or change facts that the Condensed Workspace does not reflect. " <>
        "If that is right, update it with #{CondensedWorkspace.tool_name()} so other Agents of this Group see the current facts. " <>
        "This check is automatic and can be wrong. If you judge it inaccurate, ignore it."
    )
  end

  def payload(:rethink) do
    CondensedWorkspace.payload(
      "Trajectory check suggests a correction",
      "Advisory check: your recent actions may be off-track relative to the Condensed Workspace or the request. " <>
        "Before you continue, compare your plan with the current facts and with what was asked, and correct it if needed. " <>
        "This check is automatic and can be wrong. If you are confident that you are on track, continue and ignore it."
    )
  end

  # ---- configuration ----

  defp deadline_ms, do: setting(:decision_deadline_ms, @default_deadline_ms)

  defp setting(key, default) do
    case SystemsRuntime.get_env(:salix_agent, :condensed_workspace, [])[key] do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp text?(value), do: is_binary(value) and String.trim(value) != ""
end
