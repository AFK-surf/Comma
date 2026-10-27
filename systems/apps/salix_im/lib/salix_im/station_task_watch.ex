defmodule SalixIM.StationTaskWatch do
  @messages_window 50

  @moduledoc """
  Says when a Task that runs on a station (`runs_on`: the Group's Cloud VM or
  a person's desktop station) has a delegation its Worker has not answered,
  and reminds and reports a Worker Session that stopped there without one.

  Such a Task's Worker is a Session of the station, not of Salix
  (`SalixIM.Ports.TaskStations`). `SalixIM.TaskWorkerWatch` subscribes to a
  Worker Session that never reports anything, so a station that was never
  given the Task, lost its connection, or whose Cloud VM never came up leaves
  the Router's `wait_for` to time out and the person to ask. This actor
  observes from the Task's Messages and the station's standing, and, once
  the station has the delegation, asks it where its Session stands
  (`task.status`): a turn that runs is waited for, a Session that sits idle
  without a reply is reminded once and then reported to the Router, and a
  runtime that cannot start a turn is reported to the Router at once. The
  reminder and the report are the Messages `SalixIM.TaskWorkerWatch` writes
  for a Worker inside Salix (`task_worker_nudge`, `task_worker_stopped`), so
  the Router is woken the same way. It logs one `station_task_stalled` event
  per delegation and stage, counted by
  `salix.station_tasks.stalled.total{phase, kind}` (the stage, and the kind of
  station: `cloud_vm` or `device`), and one `station_task_recovered` when a
  reported delegation is answered after all. Every answered delegation
  records `salix.station_tasks.first_reply.seconds{kind}`. The log-based alert
  `comma_alerting:station_task_stalled` fires for the Group's Cloud VM on the
  stages that are failures; a desktop station that goes away is its owner
  closing a laptop, logged and counted only. A Task of a Group named in
  `canary_group_ids` is the Cloud VM canary (docs/observability.md): its
  events and metrics carry `canary: true`, and its own alerts fire on every
  stage and on two hours without an answered delegation.

  ## Protocol assumptions (no formal model; see systems/AGENTS.md)

    * A delegation is the latest Message in the Task the Worker was given
      (`SalixIM.TaskWorkerWatch` keys its decisions the same way): addressed
      to the Worker, not authored by it, not a watch Message. Its `seq` is the
      epoch. It is answered once a Worker-authored Message has a `seq` above
      it; the first such Message is the reply the wait is measured to. A
      Message of milestones alone (`SalixIM.ConversationMilestone`) answers
      nothing.
    * A Task is watched only while it is `active` and its Worker is a
      station's (`SalixIM.TaskConversationInput.station_worker?/1`). The port's
      `standing/2` confirms at every check; `:not_station` ends the watch
      (telling the Router first when a delegation is unanswered, below), and
      a standing that cannot be read is asked again, never taken for a stage.
    * The only state outside the Task is the timer of the unanswered
      delegation and the stages reported for it. A restarted actor rebuilds
      the delegation from the Messages: one younger than `stale_ms` may be
      reported once more, one older is left alone (logged as
      `station_task_stale`), and no first reply is recorded for a delegation
      this actor did not wait for.
    * Bound: a Message costs the owner's cast with the Message itself, no
      read. Reads happen at reconcile (the Task record and its last
      #{@messages_window} Messages) and at each timer firing (the same, plus
      the station's standing and, once it has the delegation, one
      `task.status` request), every `recheck_ms` until the delegation is
      answered or the Task leaves `active`. One timer per active station
      Task with an unanswered delegation. No scan over Tasks, no poll of the
      station. A delegation older than the Message window is still waited
      for: a Worker Message in the window answers it.
    * Stages, from the standing: `vm_not_ready` (the Group's Cloud VM is not
      `ready`, or the Group has no Cloud VM Workload), `station_offline` (the
      station's connector is not connected), `not_given` (the station was not
      given the delegation yet). With the delegation at the station, from its
      Session's status: `running` (a turn runs, or the agent waits on work it
      started: not a stall, logged once as `station_task_running` past
      `running_ms`, never reminded), `idle_no_reply` (nothing runs and
      nothing is pending, or the station has no Session of the Task any
      more: a Worker that stopped without a result), `cannot_start` (Messages
      are pending but its runtime does not start). `given_no_reply` is what
      is left when the station cannot say: not connected after all, no answer
      in time, a station from before `task.status`, or one that is idle with
      Messages pending (held, not handed to its Session). Each stage has a
      threshold (`:station_task_watch` config), measured from the delegation.
      A waiting stage is reported once per delegation, when the delegation
      is at least that old. `vm_not_ready` of the Group's Cloud VM also tells
      the Router then (`task_worker_stopped`, reason `vm_not_ready`): a Task
      made or given a Message while the VM slept is kept for it and the VM
      woken (`SalixWeb.StationTasks`), and nothing else says when the VM did
      not come up in its wake budget; a coding sandbox says so itself.
      `station_left` has no threshold: the port's
      `standing/2` finds no station in the Task any more (it answered `gone`
      to what it was given, its Sessions of the Task ended; or it never
      joined). Nothing will answer the delegation. Where the Task runs is on
      its record (`runs_on`), so a station that left is still reported under
      its place.
    * Per epoch: at most one reminder (`task_worker_nudge`, to the Worker,
      so the station's Session runs a turn on it), then at most one Router
      notification (`task_worker_stopped`). Both are appended with the same
      epoch-keyed idempotency keys as `SalixIM.TaskWorkerWatch`, and whether
      each was sent is read from the Messages, so a crash between the
      decision and the append cannot double-send and a restarted actor
      decides the same. The reminder goes once the delegation and the idle
      Session are both `idle_no_reply_ms` old; the notification once, after
      the reminder, the Session is idle that long again without a reply
      (idleness as the station measures it, a duration: the clocks need not
      agree). A
      Session that `cannot_start` is not reminded (it would only add to what
      is pending): the Router is told once the stage is `cannot_start_ms`
      old, or at once when the last failure reads as a sign-in, quota or
      billing problem. A station that left while the delegation is
      unanswered is told to the Router at once (`station_left`), unless a
      notification for the epoch was sent already (its Session was reported
      idle before it left, or this actor restarted after telling), and this
      wait ends with it (a later delegation is waited for again); a Task
      whose delegation was answered, or that had none, ends quietly as it
      always did. `idle_no_reply`, `cannot_start`
      and `station_left` are reported as stalls when the Router is told, not
      when the reminder goes: a reminder that works is no incident; with no
      Router participant to tell, the stall is reported all the same. A stage
      is not done until its Message is durably appended: a failed append is
      retried on a short timer, at most `@max_attempts` times, then checked
      again after `recheck_ms`. Never reminded: a Session that is `running`.
    * A failure inside this actor is logged and the check is made again; it
      never stops the Task's owner.
  """

  alias SystemsRuntime.Proc

  use SystemsRuntime.Server

  alias SalixIM.Ports.TaskStations

  alias SalixIM.{
    ConversationActor,
    ConversationMessage,
    Conversations,
    TaskConversationInput,
    TaskWorkerWatch
  }

  require Logger

  @defaults [
    vm_not_ready_ms: :timer.minutes(10),
    station_offline_ms: :timer.minutes(10),
    not_given_ms: :timer.minutes(10),
    given_no_reply_ms: :timer.minutes(30),
    running_ms: :timer.hours(2),
    idle_no_reply_ms: :timer.minutes(10),
    cannot_start_ms: :timer.minutes(10),
    recheck_ms: :timer.minutes(10),
    stale_ms: :timer.hours(24),
    canary_group_ids: []
  ]
  @thresholds %{
    vm_not_ready: :vm_not_ready_ms,
    station_offline: :station_offline_ms,
    not_given: :not_given_ms,
    given_no_reply: :given_no_reply_ms,
    running: :running_ms,
    idle_no_reply: :idle_no_reply_ms,
    cannot_start: :cannot_start_ms
  }
  @waiting_stages [:vm_not_ready, :station_offline, :not_given, :given_no_reply]
  @stalled_event "station_task_stalled"
  @recovered_event "station_task_recovered"
  @stale_event "station_task_stale"
  @running_event "station_task_running"
  @nudged_event "station_task_nudged"
  @max_attempts 5
  @retry_base_ms 2_000
  # A start failure that reads as the station's sign-in, quota or billing: a
  # reminder would only bounce, and the Router is told at once. Narrow on
  # purpose: a passing error (overloaded, a context or max tokens limit) is
  # left to `cannot_start_ms`.
  @blocking_failure ~r/auth|login|logged|credential|invalid.?token|token (has )?expired|token runs out|unauthori[sz]ed|forbidden|quota|rate.?limit|usage limit|insufficient|billing|credit/i

  defstruct owner: nil,
            capability: nil,
            group_id: nil,
            conversation_id: nil,
            # Set while the Task is a station's and active.
            worker_agent_id: nil,
            worker_participant_id: nil,
            delegator_agent_id: nil,
            # Where the Task runs (`:cloud_vm` or `:device`): from the Task
            # record's `runs_on`, or, for a Task from before it was kept
            # there, from the last standing read or Worker reply. What a
            # station that left is reported under.
            place: nil,
            # The latest delegation without a Worker reply: its `epoch` (seq),
            # `at` (ms), the stages `reported` for it with the `place` and
            # `vm_status` of the last report, its `timer` and `token`, failed
            # `attempts` at the watch Message due, and whether it was already
            # `stale` when found.
            pending: nil

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)

  @doc "Re-read the Task: watch it while it is active and runs on a station."
  def reconcile(pid, capability),
    do: SystemsRuntime.Server.cast(pid, {:reconcile, Proc.self(), capability})

  @doc """
  `message` was added to the Task: a delegation may be answered, or a new one
  made. The Message record itself, so the watch reads nothing for it.
  """
  def appended(pid, capability, message),
    do: SystemsRuntime.Server.cast(pid, {:appended, Proc.self(), capability, message})

  @doc false
  def stalled_event, do: @stalled_event
  @doc false
  def recovered_event, do: @recovered_event
  @doc false
  def stale_event, do: @stale_event
  @doc false
  def running_event, do: @running_event
  @doc false
  def nudged_event, do: @nudged_event

  @doc false
  # The stage thresholds and `canary_group_ids`, the Groups whose station
  # Tasks are the Cloud VM canary; a value of another shape keeps the default.
  def config do
    configured =
      :salix_im
      |> SystemsRuntime.get_env(:station_task_watch, [])
      |> Enum.filter(fn
        {:canary_group_ids, ids} -> is_list(ids) and Enum.all?(ids, &is_binary/1)
        {key, ms} -> Keyword.has_key?(@defaults, key) and is_integer(ms) and ms >= 0
        _other -> false
      end)

    Keyword.merge(@defaults, configured)
  end

  @doc "Whether the Group's station Tasks are the Cloud VM canary."
  def canary?(group_id), do: group_id in config()[:canary_group_ids]

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
      do: {:noreply, guarded(state, fn -> do_reconcile(state) end)}

  # A Task that is not a station's costs nothing per Message.
  def handle_cast(
        {:appended, owner, capability, message},
        %{owner: owner, capability: capability, worker_agent_id: worker_agent_id} = state
      )
      when is_binary(worker_agent_id),
      do: {:noreply, guarded(state, fn -> apply_message(state, message) end)}

  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:station_task_timeout, epoch, token},
        %{pending: %{epoch: epoch, token: token} = pending} = state
      ) do
    state = %{state | pending: %{pending | timer: nil, token: nil}}
    {:noreply, guarded(state, fn -> check(state) end)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # An observer's failure is its own: logged, and the delegation is checked
  # again, with the Task's owner none the wiser.
  defp guarded(state, fun) do
    fun.()
  rescue
    error -> failed(state, Exception.message(error))
  catch
    kind, reason -> failed(state, Exception.format_banner(kind, reason))
  end

  defp failed(state, what) do
    Logger.warning(
      "station task watch #{state.conversation_id} failed and checks again: #{what}",
      event: "station_task_watch_failed",
      component: "salix_im",
      group_id: state.group_id,
      conversation_id: state.conversation_id
    )

    case state.pending do
      %{timer: nil, stale: false} = pending -> arm(state, pending, config()[:recheck_ms])
      _ -> state
    end
  end

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
         true <- TaskConversationInput.station_worker?(worker) do
      %{
        state
        | worker_agent_id: worker_agent_id,
          worker_participant_id: worker["participant_id"],
          delegator_agent_id: conversation["created_by_agent_id"],
          place:
            device_place(get_in(conversation, ["runs_on", "device_id"]), state) || state.place
      }
      |> observe()
    else
      _ -> unwatch(state)
    end
  end

  defp unwatch(state),
    do: %{
      cancel(state)
      | worker_agent_id: nil,
        worker_participant_id: nil,
        delegator_agent_id: nil,
        place: nil,
        pending: nil
    }

  defp device_place(device, state) when is_binary(device) and device != "" do
    cond do
      device == SalixStore.RuntimeIds.cloud_vm_device_id(state.group_id) -> :cloud_vm
      SalixStore.CodingSandboxes.device?(device) -> :sandbox
      true -> :device
    end
  end

  defp device_place(_device, _state), do: nil

  # -- messages ----------------------------------------------------------------

  # A Message as the owner appended it: a Worker reply answers the delegation
  # waited for; a Message given to the Worker is a newer delegation.
  defp apply_message(state, %{"seq" => seq} = message) when is_integer(seq) do
    cond do
      worker_reply?(message, state) ->
        case state.pending do
          %{epoch: epoch, at: at} when seq > epoch -> answered(state, epoch, at, message)
          _ -> state
        end

      delegation?(message, state) ->
        case state.pending do
          %{epoch: epoch} when seq <= epoch -> state
          _ -> ensure_pending(state, seq, timestamp_ms(message["created_at"]) || now())
        end

      true ->
        state
    end
  end

  # Without the record (an owner that notified with less), the Task is read.
  defp apply_message(state, _message), do: observe(state)

  defp observe(state) do
    case read_messages(state) do
      {:ok, messages} -> settle(state, messages)
      {:error, _reason} -> state
    end
  end

  defp read_messages(state) do
    Conversations.list_group_conversation_messages(
      state.group_id,
      state.conversation_id,
      tail: @messages_window
    )
  end

  defp settle(state, messages) do
    case decide(messages, state) do
      :none -> beyond_window(state, messages)
      {:answered, epoch, at, reply} -> answered(state, epoch, at, reply)
      {:unanswered, epoch, at} -> ensure_pending(state, epoch, at)
    end
  end

  # No delegation in the window. One waited for that is older than the
  # window is answered by a Worker Message in it, or still waited for; with
  # the window reaching its seq, there is none to wait for.
  defp beyond_window(%{pending: %{epoch: epoch, at: at}} = state, messages) do
    oldest = messages |> Enum.map(&seq/1) |> Enum.min(fn -> nil end)

    if is_integer(oldest) and oldest > epoch do
      case first_worker_reply(messages, epoch, state) do
        nil -> state
        reply -> answered(state, epoch, at, reply)
      end
    else
      %{cancel(state) | pending: nil}
    end
  end

  defp beyond_window(state, _messages), do: %{cancel(state) | pending: nil}

  @doc false
  # `:none` (no delegation in the window), `{:unanswered, epoch, at_ms}` or
  # `{:answered, epoch, at_ms, reply}` for the Task's recent Messages.
  def decide(messages, state) when is_list(messages) do
    delegation =
      messages
      |> Enum.filter(&delegation?(&1, state))
      |> Enum.max_by(&seq/1, fn -> nil end)

    case delegation do
      nil ->
        :none

      delegation ->
        epoch = seq(delegation)
        at = timestamp_ms(delegation["created_at"]) || now()

        case first_worker_reply(messages, epoch, state) do
          nil -> {:unanswered, epoch, at}
          reply -> {:answered, epoch, at, reply}
        end
    end
  end

  defp first_worker_reply(messages, epoch, state) do
    messages
    |> Enum.filter(&(seq(&1) > epoch and worker_reply?(&1, state)))
    |> Enum.min_by(&seq/1, fn -> nil end)
  end

  defp seq(message), do: if(is_integer(message["seq"]), do: message["seq"], else: 0)

  # Milestones alone show the Worker at work, not a reply: they answer no one.
  defp worker_reply?(message, state),
    do:
      by_worker?(message, state) and
        not SalixIM.ConversationMilestone.only_milestones?(message["content"])

  defp by_worker?(message, %{worker_participant_id: pid, worker_agent_id: agent}) do
    (pid != nil and message["participant_id"] == pid) or
      (agent != nil and message["agent_id"] == agent)
  end

  # Given to the Worker, written by someone else, and not a watch Message.
  defp delegation?(message, %{worker_participant_id: pid} = state) do
    (pid == nil or ConversationMessage.addressed_to?(pid, message)) and
      not by_worker?(message, state) and not watch_message?(message)
  end

  defp watch_message?(message), do: message_type(message) in watch_types()

  defp watch_types,
    do: [
      TaskWorkerWatch.nudge_type(),
      TaskWorkerWatch.notify_type(),
      TaskWorkerWatch.status_type()
    ]

  defp message_type(message), do: get_in(message, ["metadata", "message_type"])

  # Whether a watch Message of `type` was written for the delegation `epoch`.
  defp sent?(messages, epoch, type),
    do: Enum.any?(messages, &(seq(&1) > epoch and message_type(&1) == type))

  # The delegation this actor waited for was answered: the wait is recorded,
  # and a reported stall is said to be over. One it did not wait for (a stale
  # one, a restarted actor's, an older delegation) is not measured.
  defp answered(%{pending: %{epoch: epoch, stale: true}} = state, epoch, _at, _reply),
    do: %{state | pending: nil}

  defp answered(%{pending: %{epoch: epoch} = pending} = state, epoch, at, reply) do
    waited = max((timestamp_ms(reply["created_at"]) || now()) - at, 0)
    place = reply_place(state, reply)
    canary = canary?(state.group_id)

    SystemsRuntime.Telemetry.execute(
      [:salix_im, :station_task, :answered],
      %{duration: waited},
      %{kind: place, canary: canary}
    )

    case Enum.reject(pending.reported, &(&1 == :running)) do
      [stage | _] ->
        Logger.info(
          "station Task delegation answered after a stall: stage=#{stage} place=#{place} epoch=#{epoch} age_ms=#{waited} canary=#{canary}",
          event: @recovered_event,
          component: "salix_im",
          group_id: state.group_id,
          conversation_id: state.conversation_id,
          worker_agent_id: state.worker_agent_id,
          stage: Atom.to_string(stage),
          place: Atom.to_string(place),
          vm_status: pending.vm_status,
          epoch_seq: epoch,
          age_ms: waited,
          canary: canary
        )

      [] ->
        :ok
    end

    %{cancel(state) | pending: nil, place: place}
  end

  defp answered(state, _epoch, _at, _reply), do: %{cancel(state) | pending: nil}

  # The station that posted the reply says where the Task runs; a reply
  # without one (none a station posts) keeps the place last reported.
  defp reply_place(state, reply),
    do:
      device_place(get_in(reply, ["metadata", "device_id"]), state) || state.pending.place ||
        state.place || :other

  defp ensure_pending(%{pending: %{epoch: epoch, timer: timer}} = state, epoch, _at)
       when is_reference(timer),
       do: state

  defp ensure_pending(%{pending: %{epoch: epoch, stale: true}} = state, epoch, _at), do: state

  defp ensure_pending(%{pending: %{epoch: epoch} = pending} = state, epoch, _at),
    do: arm(state, pending, config()[:recheck_ms])

  # A delegation found already older than `stale_ms` (an actor restarted long
  # after it) was reported by the actor that waited for it, if it stalled: it
  # is not reported again.
  defp ensure_pending(state, epoch, at) do
    pending = %{
      epoch: epoch,
      at: at,
      reported: [],
      place: nil,
      vm_status: nil,
      timer: nil,
      token: nil,
      attempts: 0,
      stale: false
    }

    state = %{cancel(state) | pending: pending}
    age = max(now() - at, 0)

    if age >= config()[:stale_ms] do
      Logger.info(
        "station Task delegation older than stale_ms is not watched: epoch=#{epoch} age_ms=#{age}",
        event: @stale_event,
        component: "salix_im",
        group_id: state.group_id,
        conversation_id: state.conversation_id,
        worker_agent_id: state.worker_agent_id,
        epoch_seq: epoch,
        age_ms: age,
        canary: canary?(state.group_id)
      )

      %{state | pending: %{pending | stale: true}}
    else
      arm(state, pending, first_check_delay(at))
    end
  end

  # The first check is due at the earliest stage threshold after the
  # delegation, so one found late (actor restart, recovery) is not waited for
  # a whole threshold again.
  defp first_check_delay(at) do
    config = config()

    first =
      @thresholds
      |> Map.values()
      |> Enum.map(&Keyword.fetch!(config, &1))
      |> Enum.min()

    max(at + first - now(), 0)
  end

  defp arm(state, pending, delay) do
    token = Proc.make_ref()

    timer =
      SystemsClock.send_after(
        Proc.self(),
        {:station_task_timeout, pending.epoch, token},
        delay
      )

    %{state | pending: %{pending | timer: timer, token: token}}
  end

  defp recheck(state), do: arm(state, state.pending, config()[:recheck_ms])

  defp cancel(%{pending: %{timer: timer} = pending} = state) when is_reference(timer) do
    SystemsClock.cancel_timer(timer)
    %{state | pending: %{pending | timer: nil, token: nil}}
  end

  defp cancel(state), do: state

  # -- check -------------------------------------------------------------------

  # The timer fired: re-read the Task, and if its delegation is still the
  # one waited for and unanswered, read where the station stands.
  defp check(state) do
    waited = state.pending.epoch

    with {:ok, %{"kind" => "agent_task", "status" => "active"}} <-
           ConversationActor.get_conversation(state.owner),
         {:ok, messages} <- read_messages(state) do
      case decide(messages, state) do
        {:unanswered, ^waited, at} ->
          assess(state, at, messages)

        :none ->
          case beyond_window(state, messages) do
            %{pending: %{epoch: ^waited, timer: nil, at: at}} = state ->
              assess(state, at, messages)

            state ->
              state
          end

        decision ->
          settle_decision(state, decision)
      end
    else
      {:ok, _not_active} ->
        unwatch(state)

      {:error, :not_found} ->
        unwatch(state)

      {:error, reason} ->
        Logger.warning(
          "station task watch #{state.conversation_id}: Task not read, checked again: #{inspect(reason)}"
        )

        recheck(state)
    end
  end

  defp settle_decision(state, {:answered, epoch, at, reply}),
    do: answered(state, epoch, at, reply)

  defp settle_decision(state, {:unanswered, epoch, at}), do: ensure_pending(state, epoch, at)

  # A port that raises is a failure of this actor's (`guarded/2`): logged, and
  # the standing is asked for again.
  defp assess(%{pending: pending} = state, at, messages) do
    case TaskStations.standing(state.group_id, state.conversation_id) do
      :not_station ->
        left(state, messages, max(now() - at, 0))

      {:ok, standing} ->
        state = %{state | place: standing.place}
        {stage, session} = stage(state, standing, pending.epoch)
        act(state, stage, standing, session, messages, max(now() - at, 0))

      {:error, reason} ->
        Logger.warning(
          "station task watch #{state.conversation_id}: standing not read, checked again: #{inspect(reason)}"
        )

        recheck(state)
    end
  end

  # The stage, and the Session's status when the station was asked for it.
  defp stage(state, standing, epoch) do
    case given_stage(standing, epoch) do
      :given_no_reply ->
        case TaskStations.session_status(state.group_id, state.conversation_id) do
          {:ok, session} -> {session_stage(session), session}
          :unknown -> {:given_no_reply, nil}
        end

      stage ->
        {stage, nil}
    end
  end

  defp given_stage(%{place: place, vm_status: status}, _epoch)
       when place in [:cloud_vm, :sandbox] and status != "ready",
       do: :vm_not_ready

  defp given_stage(%{connected?: false}, _epoch), do: :station_offline

  defp given_stage(%{sent: sent}, epoch) when is_integer(sent) and sent < epoch, do: :not_given

  defp given_stage(_standing, _epoch), do: :given_no_reply

  defp session_stage(%{state: session_state}) when session_state in [:running, :waiting],
    do: :running

  # Idle with Messages pending: the station holds them and has not handed
  # them to its Session (turns held, or the Session not taken up since the
  # station started). A reminder would only add to them; waited out as a
  # station that cannot say.
  defp session_stage(%{state: :idle, pending: pending}) when is_integer(pending) and pending > 0,
    do: :given_no_reply

  defp session_stage(%{state: session_state}) when session_state in [:idle, :gone],
    do: :idle_no_reply

  defp session_stage(%{state: :cannot_start}), do: :cannot_start

  # The Group's Cloud VM has not come up: the wake asked for when the Task
  # was made or given the delegation did not bring it within the threshold.
  # The Router is told once, and the delegation checked on: the VM may still
  # come up, and its station answer. A coding sandbox that is not ready is
  # waited out below: its own notices say what became of it.
  defp act(state, :vm_not_ready, %{place: :cloud_vm} = standing, session, messages, age) do
    cond do
      sent?(messages, state.pending.epoch, TaskWorkerWatch.notify_type()) ->
        state |> report_once(:vm_not_ready, standing, session, age) |> recheck()

      age >= threshold(:vm_not_ready) ->
        tell(state, :vm_not_ready, "vm_not_ready", standing, session, age)

      true ->
        recheck(state)
    end
  end

  # A stage that is waited out, and a turn that runs: reported once past the
  # threshold, nothing written.
  defp act(state, stage, standing, session, _messages, age)
       when stage in @waiting_stages or stage == :running do
    state
    |> report_past_threshold(stage, standing, session, age)
    |> recheck()
  end

  # The Session sits idle without a reply (or the station has none of the
  # Task any more): reminded once the delegation and the idleness are both
  # old enough, then reported to the Router once idle that long again.
  defp act(state, :idle_no_reply, standing, session, messages, age) do
    epoch = state.pending.epoch
    threshold = threshold(:idle_no_reply)

    cond do
      sent?(messages, epoch, TaskWorkerWatch.notify_type()) ->
        state |> report_once(:idle_no_reply, standing, session, age) |> recheck()

      age < threshold or not settled?(session, threshold) ->
        recheck(state)

      sent?(messages, epoch, TaskWorkerWatch.nudge_type()) ->
        tell(state, :idle_no_reply, "stopped_after_reminder", standing, session, age)

      true ->
        nudge(state, session)
    end
  end

  # Its runtime does not start: no reminder (it would only add to what is
  # pending); the Router is told once the stage is old enough, or at once
  # when the failure reads as sign-in, quota or billing.
  defp act(state, :cannot_start, standing, session, messages, age) do
    cond do
      sent?(messages, state.pending.epoch, TaskWorkerWatch.notify_type()) ->
        state |> report_once(:cannot_start, standing, session, age) |> recheck()

      blocking_failure?(session.last_failure) or age >= threshold(:cannot_start) ->
        tell(state, :cannot_start, "cannot_start", standing, session, age)

      true ->
        recheck(state)
    end
  end

  # In its state at least `threshold`, as the station measures it (a duration,
  # so the clocks need not agree); a station that does not say for how long
  # is taken at its word.
  defp settled?(%{for_ms: for_ms}, threshold) when is_integer(for_ms), do: for_ms >= threshold

  defp settled?(_session, _threshold), do: true

  defp blocking_failure?(text) when is_binary(text), do: Regex.match?(@blocking_failure, text)
  defp blocking_failure?(_text), do: false

  defp nudge(%{pending: pending} = state, session) do
    epoch = pending.epoch

    result =
      TaskWorkerWatch.send_watch_message(
        state,
        state.worker_participant_id,
        "task-worker-watch:nudge:#{epoch}",
        TaskWorkerWatch.nudge_type(),
        TaskWorkerWatch.nudge_content(nil),
        %{"epoch_seq" => epoch, "issue" => nil, "station_state" => Atom.to_string(session.state)}
      )

    case result do
      :ok ->
        Logger.info(
          "station Task Worker reminded: its Session is #{session.state} without a reply: epoch=#{epoch} canary=#{canary?(state.group_id)}",
          event: @nudged_event,
          component: "salix_im",
          group_id: state.group_id,
          conversation_id: state.conversation_id,
          worker_agent_id: state.worker_agent_id,
          station_state: Atom.to_string(session.state),
          epoch_seq: epoch,
          canary: canary?(state.group_id)
        )

        recheck(%{state | pending: %{pending | attempts: 0}})

      :error ->
        retry_later(state)
    end
  end

  # No station takes part in the Task any more: the one that did answered
  # `gone` to what it was given (its Sessions of the Task ended) and left, or
  # none ever joined. Nothing will answer the delegation, so the Router is
  # told now, under the epoch's one notification key: one sent already (the Session was reported
  # idle before the station left, or this actor restarted after telling) is
  # not repeated. The stall is logged with the telling (or with nobody to
  # tell), under the place last known, and this wait ends: there is no
  # station to check on.
  defp left(%{pending: pending} = state, messages, age) do
    if sent?(messages, pending.epoch, TaskWorkerWatch.notify_type()) do
      %{state | pending: nil}
    else
      standing = %{place: state.place || :other, vm_status: nil}

      case notify(state, "station_left", nil) do
        :error -> retry_later(state)
        _told_or_nobody -> %{report(state, :station_left, standing, nil, age) | pending: nil}
      end
    end
  end

  # The Router is told, the stall reported with it, and the delegation is
  # checked on: it may still be answered.
  defp tell(%{pending: pending} = state, stage, reason, standing, session, age) do
    case notify(state, reason, session, standing[:vm_status]) do
      :ok ->
        %{state | pending: %{pending | attempts: 0}}
        |> report(stage, standing, session, age)
        |> recheck()

      :error ->
        retry_later(state)

      :none ->
        state |> report_once(stage, standing, session, age) |> recheck()
    end
  end

  # `:ok`, `:error` (the append failed, to be retried) or `:none` (no Router
  # participant to tell, logged: the stall is reported all the same).
  defp notify(%{pending: pending} = state, reason, session, vm_status \\ nil) do
    epoch = pending.epoch

    with delegator when is_binary(delegator) and delegator != "" <- state.delegator_agent_id,
         {:ok, router} <- ConversationActor.get_agent_participant(state.owner, delegator) do
      TaskWorkerWatch.send_watch_message(
        state,
        router["participant_id"],
        "task-worker-watch:notify:#{epoch}",
        TaskWorkerWatch.notify_type(),
        notify_content(reason, session, vm_status),
        %{
          "epoch_seq" => epoch,
          "issue" => if(reason == "cannot_start", do: reason),
          "reason" => reason,
          "station_state" => if(session, do: Atom.to_string(session.state)),
          "last_failure" => if(session, do: session.last_failure),
          "vm_status" => vm_status
        }
      )
    else
      other ->
        # Nobody to tell: the stall is at least logged and counted, once.
        Logger.warning(
          "station task watch #{state.conversation_id}: no Router participant to notify: #{inspect(other)}"
        )

        :none
    end
  end

  defp notify_content("vm_not_ready", _session, vm_status) do
    status =
      case vm_status do
        text when is_binary(text) and text != "" -> text
        _none -> "none"
      end

    "The Worker for this Task runs on the Workspace's Cloud VM, and the VM has not come up " <>
      "for it (vm_not_ready: its status is #{status}). Salix asked for the VM when the Task " <>
      "was given to it; it did not come up in time, and what the Task was given stays " <>
      "with it until the VM does. Call cloud_vm.start once to see what the VM does, and " <>
      "tell the requester what it answers; if it fails, mark the Task failed with " <>
      "im_api.internal.update_conversation or create a new Task at another place. " <>
      "The Task has not completed. Do not wait_for it again until the VM is up."
  end

  defp notify_content(reason, session, _vm_status), do: notify_content(reason, session)

  defp notify_content("cannot_start", session) do
    why =
      case session.last_failure do
        text when is_binary(text) and text != "" -> ": " <> String.slice(text, 0, 200)
        _none -> ""
      end

    "The Worker for this Task runs on a station, and that station cannot start a turn for it " <>
      "(cannot_start)#{why}. The station keeps trying, and what it was given stays pending there; " <>
      "if this reads as a sign-in, quota or billing problem, tell the requester to fix it on the " <>
      "station (or in Settings > Model & API for the Cloud VM) before the Task can continue. " <>
      "Do not wait_for it again until that changes. The Task has not completed; use " <>
      "im_api.internal.update_conversation to mark it failed, or send the Worker new " <>
      "instructions once the station runs again."
  end

  defp notify_content("station_left", _session) do
    "The Worker for this Task runs on a station, and that station no longer takes part in " <>
      "the Task (station_left): it has no Session of the Task any more, no result was " <>
      "published, and it is given nothing more here, so new instructions in this Task do " <>
      "not reach it. " <>
      "The Task has not completed. You are the Task creator and must decide: mark it failed " <>
      "or cancelled with im_api.internal.update_conversation, or create a new Task for the " <>
      "work that is left. Do not wait_for it again."
  end

  defp notify_content(reason, _session), do: TaskWorkerWatch.notify_content(reason, %{})

  # The stage is not done until its Message is durable. A failed append is
  # retried on a short timer, at most `@max_attempts` times; then checked
  # again as usual, the Message still due.
  defp retry_later(%{pending: pending} = state) do
    attempts = pending.attempts + 1

    if attempts > @max_attempts do
      Logger.warning(
        "station task watch #{state.conversation_id}: the watch Message for epoch #{pending.epoch} was not appended in #{pending.attempts} tries; checked again"
      )

      recheck(%{state | pending: %{pending | attempts: 0}})
    else
      pending = %{pending | attempts: attempts}
      arm(%{state | pending: pending}, pending, @retry_base_ms * attempts)
    end
  end

  defp threshold(stage), do: Keyword.fetch!(config(), Map.fetch!(@thresholds, stage))

  defp report_past_threshold(state, stage, standing, session, age) do
    if age >= threshold(stage),
      do: report_once(state, stage, standing, session, age),
      else: state
  end

  defp report_once(%{pending: pending} = state, stage, standing, session, age) do
    if stage in pending.reported,
      do: state,
      else: report(state, stage, standing, session, age)
  end

  defp report(%{pending: pending} = state, stage, standing, session, age) do
    place = standing.place
    vm_status = standing[:vm_status]
    canary = canary?(state.group_id)
    session_state = if session, do: Atom.to_string(session.state)

    facts = [
      event: if(stage == :running, do: @running_event, else: @stalled_event),
      component: "salix_im",
      group_id: state.group_id,
      conversation_id: state.conversation_id,
      worker_agent_id: state.worker_agent_id,
      stage: Atom.to_string(stage),
      place: Atom.to_string(place),
      vm_status: vm_status,
      station_state: session_state,
      pending_messages: if(session, do: session.pending),
      last_failure: if(session, do: session.last_failure),
      epoch_seq: pending.epoch,
      age_ms: age,
      canary: canary
    ]

    if stage == :running do
      Logger.info(
        "station Task delegation still being worked on: stage=running place=#{place} station_state=#{session_state} epoch=#{pending.epoch} age_ms=#{age} canary=#{canary}",
        facts
      )
    else
      Logger.warning(
        "station Task delegation unanswered: stage=#{stage} place=#{place} vm_status=#{vm_status || "-"} epoch=#{pending.epoch} age_ms=#{age} canary=#{canary}" <>
          if(session_state, do: " station_state=#{session_state}", else: ""),
        facts
      )

      SystemsRuntime.Telemetry.execute(
        [:salix_im, :station_task, :stalled],
        %{count: 1},
        %{phase: stage, kind: place, canary: canary}
      )
    end

    %{
      state
      | pending: %{
          pending
          | reported: [stage | pending.reported],
            place: place,
            vm_status: vm_status
        }
    }
  end

  defp timestamp_ms(value) when is_integer(value) and value > 10_000_000_000, do: value
  defp timestamp_ms(value) when is_integer(value) and value > 1_000_000_000, do: value * 1_000
  defp timestamp_ms(_value), do: nil

  defp now, do: SystemsClock.system_time(:millisecond)
end
