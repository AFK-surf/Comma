defmodule SalixIM.TaskWorkerWatch do
  @moduledoc """
  Tells a Task's Router when its Worker stopped without publishing a result.

  A plain single-Worker Task (`kind: agent_task`) has no
  supervisor: the Router delegates, calls `wait_for`, and is woken by the
  Worker's result Message. When the Worker instead stops without one — its
  model request failed and the session parked, its runtime is unavailable,
  or it simply ended a turn without replying — nothing wakes the Router. On
  staging over 14 days, 13 of 288 Worker sessions ended that way; each one
  was found only by the Router's `wait_for` timeout alarm, hundreds of
  which fire for nothing in between.

  This actor
  subscribes to the Worker session's activity, waits out a grace period
  after the session reports `stopped` or `error`, re-verifies, and then
  appends at most one reminder to the Worker and, if the Worker still does
  not publish, at most one notification to the Router per delegation. Both
  are ordinary system Messages in the Task, so the Router's notification is
  delivered like any Task input and ends its `wait_for`.

  ## Protocol assumptions (no formal model; see systems/AGENTS.md)

    * A "delegation" is the latest Message in the Task not authored by the
      Worker and not written by this actor (the Router's command, a user's
      follow-up). Its `seq` is the epoch every decision is keyed to.
    * The Worker "responded" when any Worker-authored Message has a `seq`
      above the epoch. A responded Worker is never reminded or reported,
      whatever its session state: stopping after a reply is the normal end
      of a turn.
    * Per epoch: at most one reminder (`task_worker_nudge`), then at most
      one Router notification (`task_worker_stopped`). Both are appended
      with epoch-keyed idempotency keys, so a crash between the decision
      and the append cannot double-send, and a restarted actor recomputes
      the same decision from the Messages alone. No state is kept outside
      the Conversation.
    * The reminder records the activity `version` of the stop it answered.
      Escalation to the Router requires a stop with a different version:
      the Worker stopped again after the reminder. A restarted actor that
      finds the same stop it already reminded for does nothing more.
    * A stage completes only when its Message is durably appended. A failed
      append leaves the stage open and retries on a short timer, at most
      `@max_attempts` times per stop, after which the stop is given up and
      logged; a later stop starts afresh.
    * A blocking session issue (the runtime itself cannot run the Worker)
      skips the reminder and notifies the Router at once.
    * Only `status == "active"` Tasks are watched; a Task the Router has
      already moved on from is left alone.
    * Timer fences: a stop is identified by the writer-owned activity
      `version`; a stale timer for an earlier version is ignored, and the
      decision re-reads Conversation and activity at firing time.
  """

  use GenServer

  alias SalixIM.Ports.SessionActivity
  alias SalixIM.{ConversationActor, Conversations}

  require Logger

  @grace_ms :timer.minutes(1)
  @messages_window 50
  # The runtime cannot run
  # the Worker, so a reminder would only bounce.
  @blocking_failure_issues ~w(
    authentication_required
    model_unavailable
    quota_exhausted
    rate_limited
    recovery_exhausted
    runtime_failed
  )

  @nudge_type "task_worker_nudge"
  @notify_type "task_worker_stopped"
  @max_attempts 5
  @retry_base_ms 2_000

  defstruct owner: nil,
            capability: nil,
            group_id: nil,
            conversation_id: nil,
            session_ref: nil,
            worker_agent_id: nil,
            worker_participant_id: nil,
            delegator_agent_id: nil,
            stop: nil,
            attempts: 0

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Re-read the Conversation and (re)attach to its Worker session."
  def reconcile(pid, capability), do: GenServer.cast(pid, {:reconcile, self(), capability})

  @doc false
  def nudge_type, do: @nudge_type
  @doc false
  def notify_type, do: @notify_type

  @doc false
  def grace_ms do
    case Application.get_env(:salix_im, :task_worker_watch_grace_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @grace_ms
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       owner: Keyword.fetch!(opts, :owner),
       capability: Keyword.fetch!(opts, :capability),
       group_id: Keyword.fetch!(opts, :group_id),
       conversation_id: Keyword.fetch!(opts, :conversation_id)
     }}
  end

  @impl true
  def handle_cast(
        {:reconcile, owner, capability},
        %{owner: owner, capability: capability} = state
      ),
      do: {:noreply, do_reconcile(state)}

  def handle_cast({:reconcile, _caller, _capability}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:session_activity_updated, agent_id, session_id},
        %{session_ref: {agent_id, session_id}} = state
      ),
      do: {:noreply, refresh_activity(state)}

  def handle_info({:session_activity_updated, _agent_id, _session_id}, state),
    do: {:noreply, state}

  def handle_info(
        {:task_worker_stopped_timeout, session_ref, version, token},
        %{session_ref: session_ref, stop: {phase, version, _kind, _issue, _timer, token}} = state
      )
      when phase in [:scheduled, :retry],
      do: {:noreply, handle_timeout(state, version)}

  def handle_info({:task_worker_stopped_timeout, _ref, _version, _token}, state),
    do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # -- reconcile ---------------------------------------------------------------

  defp do_reconcile(state) do
    case ConversationActor.get_conversation(state.owner) do
      {:ok, %{"kind" => "agent_task", "status" => "active"} = conversation} ->
        watch(state, conversation)

      {:ok, _conversation} ->
        unwatch(state)

      {:error, :not_found} ->
        unwatch(state)

      {:error, _reason} ->
        state
    end
  end

  defp watch(state, conversation) do
    with worker_agent_id when is_binary(worker_agent_id) and worker_agent_id != "" <-
           conversation["task_worker_agent_id"],
         {:ok, worker} <- ConversationActor.get_agent_participant(state.owner, worker_agent_id),
         session_id when is_binary(session_id) and session_id != "" <-
           get_in(worker, ["payload", "session_id"]) do
      state
      |> attach({worker_agent_id, session_id})
      |> Map.merge(%{
        worker_agent_id: worker_agent_id,
        worker_participant_id: worker["participant_id"],
        delegator_agent_id: conversation["created_by_agent_id"]
      })
      |> refresh_activity()
    else
      _ -> unwatch(state)
    end
  end

  defp attach(%{session_ref: session_ref} = state, session_ref), do: state

  defp attach(state, {agent_id, session_id} = session_ref) do
    state = unwatch(state)

    case SessionActivity.subscribe(agent_id, session_id) do
      :ok ->
        %{state | session_ref: session_ref}

      {:error, reason} ->
        Logger.warning(
          "task worker watch #{state.conversation_id}: subscribe failed: #{inspect(reason)}"
        )

        state
    end
  end

  defp unwatch(%{session_ref: nil} = state), do: %{cancel_stop(state) | stop: nil}

  defp unwatch(%{session_ref: {agent_id, session_id}} = state) do
    _ = SessionActivity.unsubscribe(agent_id, session_id)
    %{cancel_stop(state) | session_ref: nil, stop: nil}
  end

  # -- activity ----------------------------------------------------------------

  defp refresh_activity(%{session_ref: nil} = state), do: state

  defp refresh_activity(%{session_ref: {agent_id, session_id}} = state) do
    case SessionActivity.get(agent_id, session_id) do
      {:ok, activity} when is_map(activity) ->
        observe(state, activity)

      _ ->
        state
    end
  end

  defp observe(state, activity) do
    case monitored(activity) do
      {:ok, kind, version, issue} ->
        case state.stop do
          {_phase, ^version, _kind, _issue, _timer, _token} ->
            state

          _ ->
            schedule(state, kind, version, issue, activity)
        end

      :not_monitored ->
        %{cancel_stop(state) | stop: nil}
    end
  end

  # Consumer half of the activity version fence: timestamps may collide, so
  # only the writer-owned opaque revision identifies one stop.
  defp monitored(%{"state" => "stopped", "version" => version})
       when is_binary(version) and version != "",
       do: {:ok, :stopped, version, nil}

  defp monitored(%{"state" => "error", "version" => version} = activity)
       when is_binary(version) and version != "",
       do: {:ok, :error, version, text(activity["issue"])}

  defp monitored(_activity), do: :not_monitored

  defp schedule(state, kind, version, issue, activity) do
    state = cancel_stop(state)
    token = make_ref()
    delay = remaining_grace(activity)

    timer =
      Process.send_after(
        self(),
        {:task_worker_stopped_timeout, state.session_ref, version, token},
        delay
      )

    %{state | stop: {:scheduled, version, kind, issue, timer, token}, attempts: 0}
  end

  # The grace runs from the stop the runtime reported, so a stop found late
  # (actor restart, recovery) does not wait a full grace again.
  defp remaining_grace(activity) do
    grace = grace_ms()

    case timestamp_ms(activity["updated_at"]) do
      nil -> grace
      at -> (at + grace - now()) |> max(0) |> min(grace)
    end
  end

  defp timestamp_ms(value) when is_integer(value) and value > 10_000_000_000, do: value
  defp timestamp_ms(value) when is_integer(value) and value > 1_000_000_000, do: value * 1_000
  defp timestamp_ms(_value), do: nil

  defp cancel_stop(%{stop: {_phase, _version, _kind, _issue, timer, _token}} = state)
       when is_reference(timer) do
    Process.cancel_timer(timer, async: true, info: false)
    state
  end

  defp cancel_stop(state), do: state

  # -- decision ----------------------------------------------------------------

  defp handle_timeout(state, version) do
    {_phase, ^version, kind, issue, _timer, _token} = state.stop

    with {:ok, %{"kind" => "agent_task", "status" => "active"} = conversation} <-
           ConversationActor.get_conversation(state.owner),
         true <- conversation["task_worker_agent_id"] == state.worker_agent_id,
         {agent_id, session_id} = state.session_ref,
         {:ok, activity} <- SessionActivity.get(agent_id, session_id),
         {:ok, ^kind, ^version, ^issue} <- monitored(activity),
         {:ok, messages} <-
           Conversations.list_group_conversation_messages(
             state.group_id,
             state.conversation_id,
             tail: @messages_window
           ) do
      case act(state, decide(messages, state, kind, issue, version), version, issue, activity) do
        :error -> retry_later(state, version, kind, issue)
        _done -> %{state | stop: {:acted, version, kind, issue, nil, nil}, attempts: 0}
      end
    else
      _changed ->
        # The Task, the Worker or its activity moved on; re-observe from scratch.
        %{state | stop: nil, attempts: 0} |> do_reconcile()
    end
  end

  # The stage is not done until its Message is durable. A failed append is
  # retried on a short timer; the same token discipline as the grace timer
  # applies, so a later stop supersedes a pending retry.
  defp retry_later(state, version, kind, issue) do
    attempts = state.attempts + 1

    if attempts > @max_attempts do
      Logger.warning(
        "task worker watch #{state.conversation_id}: giving up on stop #{version} after #{state.attempts} failed appends"
      )

      %{state | stop: {:acted, version, kind, issue, nil, nil}, attempts: 0}
    else
      token = make_ref()

      timer =
        Process.send_after(
          self(),
          {:task_worker_stopped_timeout, state.session_ref, version, token},
          @retry_base_ms * attempts
        )

      %{state | stop: {:retry, version, kind, issue, timer, token}, attempts: attempts}
    end
  end

  @doc false
  # `:none`, `{:nudge, epoch}` or `{:notify, epoch, reason}` for the Task's
  # recent Messages, given the Worker's current stop (kind, issue, version).
  def decide(messages, %{} = ids, kind, issue, version) when is_list(messages) do
    worker_pid = ids.worker_participant_id
    worker_agent = ids.worker_agent_id

    by_worker? = fn m ->
      (worker_pid != nil and m["participant_id"] == worker_pid) or
        (worker_agent != nil and m["agent_id"] == worker_agent)
    end

    watch_type = fn m -> get_in(m, ["metadata", "message_type"]) end
    watch? = fn m -> watch_type.(m) in [@nudge_type, @notify_type] end
    seq = fn m -> if is_integer(m["seq"]), do: m["seq"], else: 0 end

    epoch =
      messages
      |> Enum.reject(fn m -> by_worker?.(m) or watch?.(m) end)
      |> Enum.map(seq)
      |> Enum.max(fn -> 0 end)

    since = fn pred -> Enum.any?(messages, fn m -> seq.(m) > epoch and pred.(m) end) end
    nudge? = fn m -> watch_type.(m) == @nudge_type end
    nudged_version = fn m -> get_in(m, ["metadata", "task_worker_watch", "activity_version"]) end

    cond do
      since.(by_worker?) -> :none
      since.(&(watch_type.(&1) == @notify_type)) -> :none
      kind == :error and issue in @blocking_failure_issues -> {:notify, epoch, issue}
      # The reminder answered this very stop: nothing new has happened, even
      # if a restarted actor is seeing the stop for the first time.
      since.(&(nudge?.(&1) and nudged_version.(&1) == version)) -> :none
      since.(nudge?) -> {:notify, epoch, "stopped_after_reminder"}
      true -> {:nudge, epoch}
    end
  end

  # `:ok`, `:none` or `:error`; only `:error` leaves the stage open.
  defp act(_state, :none, _version, _issue, _activity), do: :none

  defp act(state, {:nudge, epoch}, version, issue, _activity) do
    send_watch_message(
      state,
      state.worker_participant_id,
      "task-worker-watch:nudge:#{epoch}",
      @nudge_type,
      nudge_content(issue),
      %{"epoch_seq" => epoch, "activity_version" => version, "issue" => issue}
    )
  end

  defp act(state, {:notify, epoch, reason}, version, issue, activity) do
    with delegator when is_binary(delegator) and delegator != "" <- state.delegator_agent_id,
         {:ok, participant} <- ConversationActor.get_agent_participant(state.owner, delegator) do
      send_watch_message(
        state,
        participant["participant_id"],
        "task-worker-watch:notify:#{epoch}",
        @notify_type,
        notify_content(reason, activity),
        %{
          "epoch_seq" => epoch,
          "activity_version" => version,
          "issue" => issue,
          "reason" => reason
        }
      )
    else
      other ->
        Logger.warning(
          "task worker watch #{state.conversation_id}: no Router participant to notify: #{inspect(other)}"
        )

        :error
    end
  end

  defp send_watch_message(state, participant_id, key, type, content, facts) do
    case append_system_message(state, participant_id, %{
           "idempotency_key" => key,
           "role_label" => "runtime",
           "content" => content,
           "metadata" => %{"message_type" => type, "task_worker_watch" => facts}
         }) do
      {:ok, _message} ->
        CommaLog.log("task_worker_watch_message", %{
          group_id: state.group_id,
          conversation_id: state.conversation_id,
          message_type: type,
          epoch_seq: facts["epoch_seq"],
          issue: facts["issue"]
        })

        :ok

      {:error, reason} ->
        Logger.warning(
          "task worker watch #{state.conversation_id}: #{type} append failed: #{inspect(reason)}"
        )

        :error
    end
  end

  # Test seam: one injected append failure, to exercise the retry path.
  defp append_system_message(state, participant_id, attrs) do
    if Application.get_env(:salix_im, :task_worker_watch_fail_next_append) do
      Application.delete_env(:salix_im, :task_worker_watch_fail_next_append)
      {:error, :injected_append_failure}
    else
      ConversationActor.send_system_message(state.owner, participant_id, attrs)
    end
  end

  defp nudge_content("input_round_budget_parked") do
    "The runtime stopped your session: it used its whole round budget on the last input " <>
      "without publishing a result Message, and the Task is still active. Do not resume " <>
      "searching or checking. Publish exactly one result Message now: the result you have, or " <>
      "a failure Message that says what blocked you."
  end

  defp nudge_content(_issue) do
    "Your session stopped without publishing a result Message in this Task, and the Task is " <>
      "still active. Continue the work and publish exactly one result Message: the result, or " <>
      "a failure Message that says what blocked you. Do not stay silent."
  end

  defp notify_content(reason, activity) when reason in ~w(quota_exhausted rate_limited) do
    # The activity was re-read and version-fenced in handle_timeout. Carry its
    # bounded runtime diagnosis, including a provider reset time when present.
    detail = activity["status"] |> text() |> String.slice(0, 320)

    "The Worker for this Task is blocked (#{reason}). #{detail} " <>
      "Tell the requester that the external Worker hit a usage limit and include the " <>
      "provider reset time if present; do not promise automatic recovery. " <>
      "Do not wait_for it again or retry it repeatedly while limited. " <>
      "The Task has not completed; use im_api.internal.update_conversation to mark it failed, " <>
      "or explicitly arrange a later retry."
  end

  defp notify_content(reason, _activity) do
    "The Worker for this Task stopped without publishing a result (#{reason}). " <>
      "You are the Task creator and must decide: send it new instructions with " <>
      "im_api.internal.send_message, mark the Task failed or cancelled with " <>
      "im_api.internal.update_conversation, or create a new Task. Do not wait_for it again."
  end

  defp now, do: System.system_time(:millisecond)

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
