defmodule SalixIM.TaskWorkerWatch do
  @moduledoc """
  Tells a Task's Router when its Worker stopped without publishing a result,
  or when a Worker result left the Task `active` after the Router's turn.

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

  The opposite gap is a Worker that did publish a result, after which the
  Router ended its turn without deciding the Task's status. Only the Router
  changes status, so such a Task stays `active` with nobody working on it
  (production, 2026-10-07: the Router forwarded the result and settled with
  `end_turn`). The Router's turn and the Task status live in different owners,
  so the check runs here, not in `end_turn`: once the Worker has stopped after
  its result and the Router's session has stopped after that result, a grace
  later, a still-active Task gets one `task_status_pending` notification to
  the Router per Worker result. A Loop Task whose Loop runs gets none: each
  of its results is one run, not the end of the work (`SalixIM.TaskLoop`).
  Once its Loop stopped or ended, its results are reviewed again. A
  station's Worker Session reports nothing here, so `SalixIM.StationTaskWatch`
  sends the same notification for a Task that runs on a station.

  ## Protocol assumptions (no formal model; see systems/AGENTS.md)

    * A "delegation" is the latest Message in the Task that the Worker was
      given (its delivery filter and mentions select the Worker), not
      authored by the Worker and not written by this actor (the Router's
      command, a user's follow-up). Its `seq` is the epoch every decision is
      keyed to. A Task that gave its Worker nothing, and whose Worker has
      published nothing, is left alone: a desktop meeting's entry goes to no
      participant, so its Worker owes nothing until the recording arrives.
    * The Worker "responded" when any Worker-authored Message other than
      one carrying only milestones has a `seq` above the epoch. A milestone
      shows the Worker at work; it answers no one. A responded Worker is
      never reminded or reported, whatever its session state: stopping
      after a reply is the normal end of a turn.
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
    * While a Loop Task's Loop runs, the Router's Messages other than the
      Task's command are not delegations: the command, the Loop's wakes and
      people's Messages give the Worker its work, and a Router note (such as
      a forwarded run result) asks for no reply. A failed Loop read counts as
      running.
    * Only `status == "active"` Tasks are watched; a Task the Router has
      already moved on from is left alone.
    * A Worker result is the latest Worker-authored Message above the
      epoch. The status notification is keyed to its `seq`: at most one per
      result, idempotent across restarts. It waits for the Router session
      to report `stopped` at or after the result's `created_at`, so a Router
      that is still busy, or has not yet been delivered the result, is not
      woken a second time. A Router that stops with `error` is not notified.
      The Router session is subscribed only while such a result is pending,
      and is released once the notification is sent or given up.
    * Timer fences: a stop is identified by the writer-owned activity
      `version`; a stale timer for an earlier version is ignored, and the
      decision re-reads Conversation and activity at firing time.
  """

  alias SystemsRuntime.Proc

  use SystemsRuntime.Server

  alias SalixIM.Ports.SessionActivity
  alias SalixIM.{ConversationActor, ConversationMessage, Conversations}

  require Logger

  @grace_ms :timer.minutes(1)
  @messages_window 50
  # The runtime cannot run
  # the Worker, so a reminder would only bounce.
  @billing_denial_issues ~w(insufficient_credits account_inactive missing_account)
  @blocking_failure_issues ~w(
    authentication_required
    model_unavailable
    quota_exhausted
    provider_quota_exhausted
    rate_limited
    recovery_exhausted
    runtime_failed
  ) ++ @billing_denial_issues

  @nudge_type "task_worker_nudge"
  @notify_type "task_worker_stopped"
  @status_type "task_status_pending"
  @max_attempts 5
  @retry_base_ms 2_000

  defstruct owner: nil,
            capability: nil,
            group_id: nil,
            conversation_id: nil,
            # %{ {agent_id, session_id} => %{participant_id, agent_id, session_id, primary?, stop, attempts, card_activity} }
            workers: %{},
            worker_agent_id: nil,
            delegator_agent_id: nil,
            # The Router while the Task's Loop runs: its notes are no delegations.
            loop_router_agent_id: nil,
            qq_card?: false,
            # The Router session, subscribed only while `review` is pending.
            router_ref: nil,
            router_participant_id: nil,
            # %{result_seq, result_at, epoch, phase, attempts, worker_ref} for the Worker
            # result whose Task status the Router has not decided yet.
            review: nil

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)

  @doc "Re-read the Conversation and (re)attach to its Worker session."
  def reconcile(pid, capability, qq_card?),
    do: SystemsRuntime.Server.cast(pid, {:reconcile, Proc.self(), capability, qq_card?})

  @doc false
  def nudge_type, do: @nudge_type
  @doc false
  def notify_type, do: @notify_type
  @doc false
  def status_type, do: @status_type

  @doc false
  def grace_ms do
    case SystemsRuntime.get_env(:salix_im, :task_worker_watch_grace_ms) do
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
        {:reconcile, owner, capability, qq_card?},
        %{owner: owner, capability: capability} = state
      ),
      do: {:noreply, do_reconcile(%{state | qq_card?: qq_card?})}

  def handle_cast({:reconcile, _caller, _capability, _qq_card?}, state), do: {:noreply, state}

  @impl true
  def handle_info({:session_activity_updated, agent_id, session_id}, state) do
    ref = {agent_id, session_id}

    cond do
      Map.has_key?(state.workers, ref) ->
        {:noreply, refresh_worker_activity(state, ref)}

      state.router_ref == ref ->
        {:noreply, refresh_router(state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:task_status_pending_timeout, router_ref, version, token},
        %{router_ref: router_ref, review: %{phase: {:scheduled, version, _timer, token}}} = state
      ),
      do: {:noreply, handle_review_timeout(state, version)}

  def handle_info({:task_status_pending_timeout, _ref, _version, _token}, state),
    do: {:noreply, state}

  def handle_info({:task_worker_stopped_timeout, session_ref, version, token}, state) do
    case Map.get(state.workers, session_ref) do
      %{stop: {phase, ^version, _kind, _issue, _timer, ^token}}
      when phase in [:scheduled, :retry] ->
        {:noreply, handle_timeout(state, session_ref, version)}

      _ ->
        {:noreply, state}
    end
  end

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
         {:ok, %{"workers" => roster_workers}} <-
           ConversationActor.task_worker_identities(state.owner) do
      salix_workers =
        roster_workers
        |> Enum.filter(fn w ->
          SalixIM.ConversationSource.receives_messages?(w) and
            is_binary(get_in(w, ["payload", "session_id"])) and
            get_in(w, ["payload", "session_id"]) != ""
        end)

      if salix_workers == [] do
        unwatch(state)
      else
        desired_refs =
          Map.new(salix_workers, fn w ->
            sid = get_in(w, ["payload", "session_id"])
            ref = {w["agent_id"], sid}

            {ref,
             %{
               participant_id: w["participant_id"],
               agent_id: w["agent_id"],
               session_id: sid,
               primary?: w["primary"] == true
             }}
          end)

        state =
          %{
            state
            | worker_agent_id: worker_agent_id,
              # A Collaborative Task's Router is told nothing of it.
              delegator_agent_id:
                if(match?(%{"collaboration" => %{}}, conversation["metadata"]),
                  do: nil,
                  else: conversation["created_by_agent_id"]
                )
          }
          |> sync_workers(desired_refs)

        Enum.reduce(Map.keys(state.workers), state, &refresh_worker_activity(&2, &1))
      end
    else
      _ -> unwatch(state)
    end
  end

  defp sync_workers(state, desired_refs) do
    removed = Map.keys(state.workers) -- Map.keys(desired_refs)

    state =
      Enum.reduce(removed, state, fn {agent_id, session_id} = ref, acc ->
        worker = Map.fetch!(acc.workers, ref)
        cancel_worker_stop(worker)
        _ = SessionActivity.unsubscribe(agent_id, session_id)
        %{acc | workers: Map.delete(acc.workers, ref)}
      end)

    Enum.reduce(desired_refs, state, fn {ref, info}, acc ->
      case Map.get(acc.workers, ref) do
        %{} = existing ->
          {agent_id, session_id} = ref

          subscribed? =
            if Map.get(existing, :subscribed?, true) do
              true
            else
              case SessionActivity.subscribe(agent_id, session_id) do
                :ok -> true
                {:error, _reason} -> false
              end
            end

          updated =
            existing
            |> Map.merge(info)
            |> Map.put(:subscribed?, subscribed?)

          %{acc | workers: Map.put(acc.workers, ref, updated)}

        nil ->
          {agent_id, session_id} = ref

          case SessionActivity.subscribe(agent_id, session_id) do
            :ok ->
              entry =
                Map.merge(info, %{stop: nil, attempts: 0, card_activity: nil, subscribed?: true})

              %{acc | workers: Map.put(acc.workers, ref, entry)}

            {:error, reason} ->
              Logger.warning(
                "task worker watch #{acc.conversation_id}: subscribe failed: #{inspect(reason)}"
              )

              # Keep the worker tracked even when PubSub subscribe fails so
              # workers_idle_status/1 never misses an active secondary session.
              entry =
                Map.merge(info, %{stop: nil, attempts: 0, card_activity: nil, subscribed?: false})

              %{acc | workers: Map.put(acc.workers, ref, entry)}
          end
      end
    end)
  end

  defp unwatch(%{workers: workers} = state) do
    Enum.each(workers, fn {{agent_id, session_id}, worker} ->
      cancel_worker_stop(worker)
      _ = SessionActivity.unsubscribe(agent_id, session_id)
    end)

    %{end_review(state) | workers: %{}}
  end

  # -- activity ----------------------------------------------------------------

  defp refresh_worker_activity(state, {agent_id, session_id} = ref) do
    if Map.has_key?(state.workers, ref) do
      case SessionActivity.get(agent_id, session_id) do
        {:ok, activity} when is_map(activity) ->
          observe(state, ref, activity)

        _ ->
          state
      end
    else
      state
    end
  end

  defp observe(state, ref, activity) do
    state = notify_qq_activity(state, ref, activity)
    worker = Map.fetch!(state.workers, ref)

    case monitored(activity) do
      {:ok, kind, version, issue} ->
        case worker.stop do
          {_phase, ^version, _kind, _issue, _timer, _token} ->
            state

          _ ->
            schedule(state, ref, kind, version, issue, activity)
        end

      :not_monitored ->
        # A Worker runs again: cancel its stop timer and any pending review.
        cancel_worker_stop(worker)
        worker = %{worker | stop: nil, attempts: 0}
        %{end_review(state) | workers: Map.put(state.workers, ref, worker)}
    end
  end

  # Reuse this subscription. No extra timer, per-tool notification or Group scan.
  # A missing card is retried when its initial publication reconciles the watch.
  defp notify_qq_activity(%{qq_card?: true} = state, ref, %{"state" => kind} = activity)
       when kind in ~w(active error) do
    worker = Map.fetch!(state.workers, ref)
    fingerprint = {ref, kind, activity["issue"]}

    if worker.card_activity == fingerprint do
      state
    else
      case ConversationActor.notify_qq_task_activity(state.owner, ref, activity) do
        {:ok, _} ->
          %{state | workers: Map.put(state.workers, ref, %{worker | card_activity: fingerprint})}

        _ ->
          state
      end
    end
  end

  defp notify_qq_activity(state, ref, %{"state" => "stopped"}) do
    worker = Map.fetch!(state.workers, ref)
    %{state | workers: Map.put(state.workers, ref, %{worker | card_activity: nil})}
  end

  defp notify_qq_activity(state, _ref, _activity), do: state

  # Consumer half of the activity version fence: timestamps may collide, so
  # only the writer-owned opaque revision identifies one stop.
  defp monitored(%{"state" => "stopped", "version" => version})
       when is_binary(version) and version != "",
       do: {:ok, :stopped, version, nil}

  defp monitored(%{"state" => "error", "version" => version} = activity)
       when is_binary(version) and version != "",
       do: {:ok, :error, version, text(activity["issue"])}

  defp monitored(_activity), do: :not_monitored

  defp schedule(state, ref, kind, version, issue, activity) do
    worker = Map.fetch!(state.workers, ref)
    cancel_worker_stop(worker)
    token = Proc.make_ref()
    delay = remaining_grace(activity)

    timer =
      SystemsClock.send_after(
        Proc.self(),
        {:task_worker_stopped_timeout, ref, version, token},
        delay
      )

    worker = %{worker | stop: {:scheduled, version, kind, issue, timer, token}, attempts: 0}
    %{state | workers: Map.put(state.workers, ref, worker)}
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

  defp cancel_worker_stop(%{stop: {_phase, _version, _kind, _issue, timer, _token}})
       when is_reference(timer) do
    SystemsClock.cancel_timer(timer)
    :ok
  end

  defp cancel_worker_stop(_worker), do: :ok

  # -- decision ----------------------------------------------------------------

  defp handle_timeout(state, ref, version) do
    worker = Map.fetch!(state.workers, ref)
    {_phase, ^version, kind, issue, _timer, _token} = worker.stop

    with {:ok, %{"kind" => "agent_task", "status" => "active"} = conversation} <-
           ConversationActor.get_conversation(state.owner),
         true <- conversation["task_worker_agent_id"] == state.worker_agent_id,
         {agent_id, session_id} = ref,
         {:ok, activity} <- SessionActivity.get(agent_id, session_id),
         {:ok, ^kind, ^version, ^issue} <- monitored(activity),
         {:ok, messages} <-
           Conversations.list_group_conversation_messages(
             state.group_id,
             state.conversation_id,
             tail: @messages_window
           ) do
      loop_result = SalixIM.TaskLoop.get(state.group_id, state.conversation_id)
      loop_runs? = loop_running_active?(loop_result)

      ids = %{
        worker_participant_id: worker.participant_id,
        worker_agent_id: worker.agent_id,
        primary?: worker.primary?,
        loop_router_agent_id: if(loop_runs?, do: state.delegator_agent_id)
      }

      state = retry_unsubscribed_workers(state)

      case decide(messages, ids, kind, issue, version) do
        {:review, epoch, result_seq, result_at} ->
          if router_decides_status?(conversation) and not loop_runs? do
            case workers_idle_status(state) do
              :idle ->
                worker = %{worker | stop: {:acted, version, kind, issue, nil, nil}, attempts: 0}
                state = %{state | workers: Map.put(state.workers, ref, worker)}
                begin_review(state, ref, epoch, result_seq, result_at)

              :error ->
                retry_later(state, ref, version, kind, issue)

              :busy ->
                if any_unsubscribed_worker?(state) do
                  retry_later(state, ref, version, kind, issue)
                else
                  worker = %{worker | stop: {:acted, version, kind, issue, nil, nil}, attempts: 0}
                  %{state | workers: Map.put(state.workers, ref, worker)}
                end
            end
          else
            worker = %{worker | stop: {:acted, version, kind, issue, nil, nil}, attempts: 0}
            %{state | workers: Map.put(state.workers, ref, worker)}
          end

        decision ->
          case act(state, ref, worker, decision, version, issue, activity, loop_result) do
            :error ->
              retry_later(state, ref, version, kind, issue)

            _done ->
              # If a secondary worker just finished and all workers are now idle,
              # check whether the primary worker had a deferred reviewable result.
              if not worker.primary? and is_nil(state.review) and
                   router_decides_status?(conversation) and not loop_runs? do
                case workers_idle_status(state) do
                  :idle ->
                    worker = %{
                      worker
                      | stop: {:acted, version, kind, issue, nil, nil},
                        attempts: 0
                    }

                    state = %{state | workers: Map.put(state.workers, ref, worker)}
                    maybe_begin_deferred_primary_review(state, messages)

                  :error ->
                    retry_later(state, ref, version, kind, issue)

                  :busy ->
                    if any_unsubscribed_worker?(state) do
                      retry_later(state, ref, version, kind, issue)
                    else
                      worker = %{
                        worker
                        | stop: {:acted, version, kind, issue, nil, nil},
                          attempts: 0
                      }

                      %{state | workers: Map.put(state.workers, ref, worker)}
                    end
                end
              else
                worker = %{worker | stop: {:acted, version, kind, issue, nil, nil}, attempts: 0}
                %{state | workers: Map.put(state.workers, ref, worker)}
              end
          end
      end
    else
      _changed ->
        # The Task, the Worker or its activity moved on; re-observe from scratch.
        worker = %{worker | stop: nil, attempts: 0}
        %{state | workers: Map.put(state.workers, ref, worker)} |> do_reconcile()
    end
  end

  defp maybe_begin_deferred_primary_review(state, messages) do
    case Enum.find(state.workers, fn {_ref, w} -> w.primary? end) do
      {primary_ref, primary} ->
        ids = %{
          worker_participant_id: primary.participant_id,
          worker_agent_id: primary.agent_id,
          primary?: true
        }

        case decide(messages, ids, :stopped, nil, nil) do
          {:review, epoch, result_seq, result_at} ->
            begin_review(state, primary_ref, epoch, result_seq, result_at)

          _ ->
            state
        end

      nil ->
        state
    end
  end

  defp any_unsubscribed_worker?(%{workers: workers}) do
    Enum.any?(workers, fn {_ref, w} -> not Map.get(w, :subscribed?, true) end)
  end

  defp retry_unsubscribed_workers(%{workers: workers} = state) do
    updated =
      Map.new(workers, fn {{agent_id, session_id} = ref, w} ->
        if Map.get(w, :subscribed?, true) do
          {ref, w}
        else
          case SessionActivity.subscribe(agent_id, session_id) do
            :ok -> {ref, Map.put(w, :subscribed?, true)}
            {:error, _} -> {ref, w}
          end
        end
      end)

    %{state | workers: updated}
  end

  defp workers_idle_status(%{workers: workers}) do
    Enum.reduce_while(workers, :idle, fn {{agent_id, session_id}, _worker}, acc ->
      case SessionActivity.get(agent_id, session_id) do
        {:ok, %{"state" => s}} when s in ["stopped", "error", "idle"] ->
          {:cont, acc}

        # Unwoken secondary sessions have no SessionActivity row yet and are idle.
        {:error, :not_found} ->
          {:cont, acc}

        {:ok, _other} ->
          {:halt, :busy}

        {:error, _other} ->
          {:cont, :error}
      end
    end)
  end

  # The stage is not done until its Message is durable. A failed append is
  # retried on a short timer; the same token discipline as the grace timer
  # applies, so a later stop supersedes a pending retry.
  defp retry_later(state, ref, version, kind, issue) do
    worker = Map.fetch!(state.workers, ref)
    attempts = worker.attempts + 1

    if attempts > @max_attempts do
      Logger.warning(
        "task worker watch #{state.conversation_id}: giving up on stop #{version} after #{worker.attempts} failed appends"
      )

      worker = %{worker | stop: {:acted, version, kind, issue, nil, nil}, attempts: 0}
      %{state | workers: Map.put(state.workers, ref, worker)}
    else
      token = Proc.make_ref()

      timer =
        SystemsClock.send_after(
          Proc.self(),
          {:task_worker_stopped_timeout, ref, version, token},
          @retry_base_ms * attempts
        )

      worker = %{worker | stop: {:retry, version, kind, issue, timer, token}, attempts: attempts}
      %{state | workers: Map.put(state.workers, ref, worker)}
    end
  end

  @doc false
  # `:none`, `{:nudge, epoch, delegation_message_id}`, `{:notify, epoch, reason}` or
  # `{:review, epoch, result_seq, result_at_ms}` for the Task's recent
  # Messages, given the Worker's current stop (kind, issue, version).
  def decide(messages, %{} = ids, kind, issue, version) when is_list(messages) do
    worker_pid = ids.worker_participant_id
    worker_agent = ids.worker_agent_id
    primary? = Map.get(ids, :primary?, true)

    by_worker? = fn m ->
      msg_pid = m["participant_id"]

      cond do
        is_binary(msg_pid) and msg_pid != "" and worker_pid != nil ->
          msg_pid == worker_pid

        true ->
          worker_agent != nil and m["agent_id"] == worker_agent
      end
    end

    # Milestones alone show the Worker at work, not a reply: a Worker that
    # records a step and then fails still owes the Task its result.
    replied? = fn m ->
      by_worker?.(m) and not SalixIM.ConversationMilestone.only_milestones?(m["content"])
    end

    watch_type = fn m -> get_in(m, ["metadata", "message_type"]) end
    watch? = fn m -> watch_type.(m) in [@nudge_type, @notify_type, @status_type] end
    seq = fn m -> if is_integer(m["seq"]), do: m["seq"], else: 0 end

    given? = fn m ->
      cond do
        worker_pid == nil ->
          true

        is_list(get_in(m, ["metadata", "wake_targets"])) ->
          worker_pid in get_in(m, ["metadata", "wake_targets"])

        true ->
          ConversationMessage.addressed_to?(worker_pid, m)
      end
    end

    # While a Loop runs, the Task's command, the Loop's wakes and people's
    # Messages are the Worker's work; the Router's other Messages there
    # (forwarding a run's result, a note) ask for nothing it must answer.
    loop_router = Map.get(ids, :loop_router_agent_id)

    loop_router_note? = fn m ->
      loop_router != nil and m["agent_id"] == loop_router and
        watch_type.(m) != "task_command"
    end

    # Passive context in a Collaborative Task is delivered without waking the
    # Worker, so it is not a delegation the Worker owes a result for.
    context_only? = fn m -> get_in(m, ["metadata", "context_only"]) == true end

    # Messages with `wake_reason == "all_sessions"` obligate ONLY the primary worker.
    non_obligated_all_sessions? = fn m ->
      not primary? and get_in(m, ["metadata", "wake_reason"]) == "all_sessions"
    end

    delegations =
      Enum.filter(
        messages,
        &(given?.(&1) and
            not (by_worker?.(&1) or watch?.(&1) or loop_router_note?.(&1) or
                   context_only?.(&1) or non_obligated_all_sessions?.(&1)))
      )

    latest_delegation = Enum.max_by(delegations, seq, fn -> nil end)
    epoch = if(latest_delegation, do: seq.(latest_delegation), else: 0)
    epoch_message_id = latest_delegation && latest_delegation["message_id"]

    since = fn pred -> Enum.any?(messages, fn m -> seq.(m) > epoch and pred.(m) end) end
    nudge? = fn m -> watch_type.(m) == @nudge_type end
    nudged_version = fn m -> get_in(m, ["metadata", "task_worker_watch", "activity_version"]) end

    for_this_worker? = fn m ->
      target_pid = get_in(m, ["metadata", "task_worker_watch", "target_participant_id"])

      cond do
        worker_pid == nil ->
          true

        is_binary(target_pid) and target_pid != "" ->
          target_pid == worker_pid

        watch_type.(m) == @nudge_type and
            is_list(get_in(m, ["delivery_filter", "participant_ids"])) ->
          worker_pid in get_in(m, ["delivery_filter", "participant_ids"])

        true ->
          true
      end
    end

    cond do
      # Nothing given, nothing published: the Worker owes no result.
      delegations == [] and not Enum.any?(messages, by_worker?) ->
        :none

      since.(replied?) ->
        review(messages, epoch, replied?, seq, primary?)

      since.(&(watch_type.(&1) == @notify_type and for_this_worker?.(&1))) ->
        :none

      kind == :error and issue in @blocking_failure_issues ->
        {:notify, epoch, issue}

      # The reminder answered this very stop: nothing new has happened, even
      # if a restarted actor is seeing the stop for the first time.
      since.(&(nudge?.(&1) and for_this_worker?.(&1) and nudged_version.(&1) == version)) ->
        :none

      since.(&(nudge?.(&1) and for_this_worker?.(&1))) ->
        {:notify, epoch, "stopped_after_reminder"}

      true ->
        {:nudge, epoch, epoch_message_id}
    end
  end

  # The Worker's latest result above the epoch, unless the Router was already
  # told about that very result. Secondary workers only trigger review when
  # explicitly mentioning the Router (`explicit_router_mention == true`).
  defp review(messages, epoch, replied?, seq, primary?) do
    result =
      messages
      |> Enum.filter(&(seq.(&1) > epoch and replied?.(&1)))
      |> Enum.max_by(seq)

    result_seq = seq.(result)

    review_eligible? =
      primary? or get_in(result, ["metadata", "explicit_router_mention"]) == true

    notified? =
      Enum.any?(messages, fn m ->
        get_in(m, ["metadata", "message_type"]) == @status_type and
          get_in(m, ["metadata", "task_worker_watch", "result_seq"]) == result_seq
      end)

    case timestamp_ms(result["created_at"]) do
      result_at when is_integer(result_at) and review_eligible? and not notified? ->
        {:review, epoch, result_seq, result_at}

      _ ->
        :none
    end
  end

  # -- pending status ------------------------------------------------------------

  @doc false
  # Recurring Tasks stay active between runs, and legacy Workflow and Triage
  # Tasks have their status set by their own product flow, not the Router.
  def router_decides_status?(conversation) do
    not scheduled?(conversation) and is_nil(conversation["workflow"]) and
      not is_map(get_in(conversation, ["source_refs", "triage_investigation"]))
  end

  defp scheduled?(conversation) do
    case get_in(conversation, ["schedule", "schedule_id"]) do
      schedule_id when is_binary(schedule_id) -> String.trim(schedule_id) != ""
      _ -> false
    end
  end

  defp begin_review(%{review: %{result_seq: result_seq}} = state, _ref, _epoch, result_seq, _at),
    do: state

  defp begin_review(state, worker_ref, epoch, result_seq, result_at) do
    state = end_review(state)

    with delegator when is_binary(delegator) and delegator != "" <- state.delegator_agent_id,
         {:ok, router} <- ConversationActor.get_agent_participant(state.owner, delegator),
         session_id when is_binary(session_id) and session_id != "" <-
           get_in(router, ["payload", "session_id"]),
         :ok <- SessionActivity.subscribe(delegator, session_id) do
      %{
        state
        | router_ref: {delegator, session_id},
          router_participant_id: router["participant_id"],
          review: %{
            worker_ref: worker_ref,
            epoch: epoch,
            result_seq: result_seq,
            result_at: result_at,
            phase: :waiting,
            attempts: 0
          }
      }
      |> refresh_router()
    else
      other ->
        Logger.warning(
          "task worker watch #{state.conversation_id}: cannot watch the Router for result #{result_seq}: #{inspect(other)}"
        )

        state
    end
  end

  defp end_review(state), do: %{release_router(state) | review: nil}

  # The result was reported (or given up on): keep its `result_seq` so the
  # same result is not reviewed again, but stop following the Router.
  defp finish_review(%{review: review} = state),
    do: %{release_router(state) | review: %{review | phase: :acted}}

  defp release_router(%{router_ref: nil} = state), do: cancel_review(state)

  defp release_router(%{router_ref: {agent_id, session_id}} = state) do
    _ = SessionActivity.unsubscribe(agent_id, session_id)
    %{cancel_review(state) | router_ref: nil, router_participant_id: nil}
  end

  defp cancel_review(%{review: %{phase: {:scheduled, _version, timer, _token}}} = state)
       when is_reference(timer) do
    SystemsClock.cancel_timer(timer)
    state
  end

  defp cancel_review(state), do: state

  defp refresh_router(
         %{review: %{phase: phase} = review, router_ref: {agent_id, session_id}} = state
       )
       when phase != :acted do
    case SessionActivity.get(agent_id, session_id) do
      {:ok, activity} when is_map(activity) ->
        case router_settled(activity, review.result_at) do
          {:ok, version} -> schedule_review(state, version, activity)
          :busy -> %{cancel_review(state) | review: %{review | phase: :waiting}}
        end

      _ ->
        state
    end
  end

  defp refresh_router(state), do: state

  # The Router stopped no earlier than the result was published, so its last
  # turn had the result to act on. Session timestamps may be whole seconds,
  # so the result time is floored to its second: a Router that stopped up to
  # a second before the result also counts. Delivering the result then wakes
  # the Router within the grace, which changes the activity version, and the
  # timeout re-checks that version before notifying.
  defp router_settled(%{"state" => "stopped", "version" => version} = activity, result_at)
       when is_binary(version) and version != "" do
    case timestamp_ms(activity["updated_at"]) do
      at when is_integer(at) and at >= div(result_at, 1_000) * 1_000 -> {:ok, version}
      _ -> :busy
    end
  end

  defp router_settled(_activity, _result_at), do: :busy

  defp schedule_review(%{review: %{phase: {:scheduled, version, _, _}}} = state, version, _),
    do: state

  defp schedule_review(state, version, activity),
    do: arm_review(cancel_review(state), version, remaining_grace(activity))

  defp arm_review(%{review: review} = state, version, delay) do
    token = Proc.make_ref()

    timer =
      SystemsClock.send_after(
        Proc.self(),
        {:task_status_pending_timeout, state.router_ref, version, token},
        delay
      )

    %{state | review: %{review | phase: {:scheduled, version, timer, token}}}
  end

  defp handle_review_timeout(%{review: review} = state, version) do
    {agent_id, session_id} = state.router_ref
    result_seq = review.result_seq

    with {:ok, %{"kind" => "agent_task", "status" => "active"} = conversation} <-
           ConversationActor.get_conversation(state.owner),
         true <- conversation["task_worker_agent_id"] == state.worker_agent_id,
         loop_result = SalixIM.TaskLoop.get(state.group_id, state.conversation_id),
         false <- loop_running_active?(loop_result),
         :idle <- workers_idle_status(state),
         %{} = worker <- Map.get(state.workers, review.worker_ref),
         {:ok, messages} <-
           Conversations.list_group_conversation_messages(
             state.group_id,
             state.conversation_id,
             tail: @messages_window
           ),
         ids = %{
           worker_participant_id: worker.participant_id,
           worker_agent_id: worker.agent_id,
           primary?: worker.primary?
         },
         {:review, epoch, ^result_seq, _at} <- decide(messages, ids, :stopped, nil, nil),
         {:ok, activity} <- SessionActivity.get(agent_id, session_id),
         {:ok, ^version} <- router_settled(activity, review.result_at) do
      {:ok, loop_view} = loop_result

      case send_status_pending(state, epoch, result_seq, loop_view) do
        :ok ->
          finish_review(state)

        :error ->
          retry_review(state, version)
      end
    else
      # The Router decided the status, or the Task is gone.
      {:ok, %{} = _not_active_task} ->
        state |> end_review() |> do_reconcile()

      {:error, :not_found} ->
        state |> end_review() |> do_reconcile()

      # The Router started another turn; wait for it to stop again.
      :busy ->
        refresh_router(state)

      {:ok, version} when is_binary(version) ->
        refresh_router(state)

      :error ->
        retry_review(state, version)

      {:error, _reason} ->
        retry_review(state, version)

      _changed ->
        # A new delegation, another Worker, a Loop that runs again, or this
        # result was already reported.
        end_review(state)
    end
  end

  defp retry_review(%{review: review} = state, version) do
    attempts = review.attempts + 1

    if attempts > @max_attempts do
      Logger.warning(
        "task worker watch #{state.conversation_id}: giving up on status notice for result #{review.result_seq}"
      )

      finish_review(state)
    else
      %{state | review: %{review | attempts: attempts}}
      |> arm_review(version, @retry_base_ms * attempts)
    end
  end

  defp send_status_pending(state, epoch, result_seq, loop_view) do
    send_watch_message(
      state,
      state.router_participant_id,
      "task-worker-watch:status:#{result_seq}",
      @status_type,
      status_pending_content(loop_view),
      %{"epoch_seq" => epoch, "result_seq" => result_seq}
    )
  end

  # `:ok`, `:none` or `:error`; only `:error` leaves the stage open.
  defp act(_state, _ref, _worker, :none, _version, _issue, _activity, _loop_result), do: :none

  defp act(
         state,
         _ref,
         worker,
         {:nudge, epoch, reply_to_message_id},
         version,
         issue,
         _activity,
         _loop_result
       ) do
    key =
      if worker.primary?,
        do: "task-worker-watch:nudge:#{epoch}",
        else: "task-worker-watch:nudge:#{epoch}:#{worker.participant_id}"

    send_watch_message(
      state,
      worker.participant_id,
      key,
      @nudge_type,
      nudge_content(issue),
      %{
        "epoch_seq" => epoch,
        "activity_version" => version,
        "issue" => issue,
        "target_participant_id" => worker.participant_id
      },
      reply_to_message_id: reply_to_message_id
    )
  end

  defp act(state, ref, worker, {:notify, epoch, reason}, version, issue, activity, loop_result) do
    with delegator when is_binary(delegator) and delegator != "" <- state.delegator_agent_id,
         {:ok, participant} <- ConversationActor.get_agent_participant(state.owner, delegator) do
      key =
        if worker.primary?,
          do: "task-worker-watch:notify:#{epoch}",
          else: "task-worker-watch:notify:#{epoch}:#{worker.participant_id}"

      result =
        send_watch_message(
          state,
          participant["participant_id"],
          key,
          @notify_type,
          notify_content(reason, activity, loop_state: loop_stop_state(loop_result)),
          %{
            "epoch_seq" => epoch,
            "activity_version" => version,
            "issue" => issue,
            "reason" => reason,
            "target_participant_id" => worker.participant_id
          }
        )

      if result == :ok and state.qq_card? do
        ConversationActor.notify_qq_task_activity(state.owner, ref, activity)
      end

      result
    else
      other ->
        Logger.warning(
          "task worker watch #{state.conversation_id}: no Router participant to notify: #{inspect(other)}"
        )

        :error
    end
  end

  @doc false
  # A watch Message into the Task of `ids` (`owner`, `group_id`,
  # `conversation_id`: this actor's state, or `SalixIM.StationTaskWatch`'s,
  # which reminds and notifies with the same Messages for a station Task).
  def send_watch_message(
        %{owner: _} = state,
        participant_id,
        key,
        type,
        content,
        facts,
        opts \\ []
      ) do
    attrs =
      %{
        "idempotency_key" => key,
        "role_label" => "runtime",
        "content" => content,
        "metadata" => %{"message_type" => type, "task_worker_watch" => facts}
      }
      |> maybe_put_reply_to(opts[:reply_to_message_id])

    case append_system_message(state, participant_id, attrs) do
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

  defp maybe_put_reply_to(attrs, message_id)
       when is_binary(message_id) and message_id != "",
       do: Map.put(attrs, "reply_to_message_id", message_id)

  defp maybe_put_reply_to(attrs, _message_id), do: attrs

  # Test seam: injected append failures (`true`: the next one; an integer:
  # that many in a row), to exercise the retry path.
  defp append_system_message(state, participant_id, attrs) do
    case SystemsRuntime.get_env(:salix_im, :task_worker_watch_fail_next_append) do
      left when left == true or left == 1 ->
        SystemsRuntime.delete_env(:salix_im, :task_worker_watch_fail_next_append)
        {:error, :injected_append_failure}

      left when is_integer(left) and left > 1 ->
        SystemsRuntime.put_env(:salix_im, :task_worker_watch_fail_next_append, left - 1)
        {:error, :injected_append_failure}

      _none ->
        ConversationActor.send_system_message(state.owner, participant_id, attrs)
    end
  end

  @doc false
  # Also `SalixIM.StationTaskWatch`'s, for a Task whose Worker is a station's.
  def status_pending_content(loop_view \\ nil)

  def status_pending_content(%{"trigger" => %{}, "status" => "ended"} = view) do
    reason = view["ended_reason"] || "ended"

    "The Worker published its result in this Task and stopped, and your last turn ended " <>
      "with the Task still active, so nobody is working on it. This Task's previous Background " <>
      "Loop has already ended (#{reason}), so it is no longer automated and will not run again " <>
      "on its own. Decide its status now with im_api.internal.update_conversation: " <>
      "ready_for_review when the result reached the requester and a person still needs to review " <>
      "or decide; completed when delivered with nothing left; failed when it cannot finish. " <>
      "Or send the Worker new instructions, or if the requester asked to restore the recurring " <>
      "schedule, call im_api.internal.task.update with loop and command. Keep it active only if " <>
      "it is waiting for a person's answer. Do not resend a result you already delivered."
  end

  def status_pending_content(%{"trigger" => %{}, "status" => "pending"}) do
    "The Worker published its result in this Task and stopped, and your last turn ended " <>
      "with the Task still active, so nobody is working on it. This Task's requested Background " <>
      "Loop is still pending (never created), so nothing will run on its own until the Worker " <>
      "creates it. Send the Worker new instructions with im_api.internal.send_message to finish " <>
      "setting up the Loop, or end the Task with im_api.internal.update_conversation (cancelled " <>
      "or failed ends the requested Loop). Keep it active only if it is waiting for a person's " <>
      "answer. Do not resend a result you already delivered."
  end

  def status_pending_content(%{"trigger" => %{}, "status" => status} = view) do
    loop_state =
      case {status, view["paused_by"]} do
        {"paused", by} when is_binary(by) and by != "" -> "paused (#{by})"
        {state, _} -> state
      end

    "The Worker published its result in this Task and stopped, and your last turn ended " <>
      "with the Task still active, so nobody is working on it. This Task's Background Loop is " <>
      "currently #{loop_state} rather than running. Keep the Task active while the Loop stays " <>
      "paused or waiting to resume, send the Worker new instructions to resume or repair it, or " <>
      "end the Task with im_api.internal.update_conversation (completed, cancelled, or failed) " <>
      "only if the recurring Loop should stop for good. Do not resend a result you already delivered."
  end

  def status_pending_content(_loop_view) do
    "The Worker published its result in this Task and stopped, and your last turn ended " <>
      "with the Task still active, so nobody is working on it. Decide its status now with " <>
      "im_api.internal.update_conversation: ready_for_review when the result reached the " <>
      "requester and a person still needs to review or decide; completed only for a plain " <>
      "one-shot Task whose result was delivered with nothing left; failed when it cannot " <>
      "finish. Or send the Worker new instructions. Keep it active only if it is waiting for " <>
      "a person's answer. Do not resend a result you already delivered."
  end

  @doc false
  def nudge_content("input_round_budget_parked") do
    "The runtime stopped your session: it used its whole round budget on the last input " <>
      "without publishing a result Message, and the Task is still active. Do not resume " <>
      "searching or checking. Publish exactly one result Message now: the result you have, or " <>
      "a failure Message that says what blocked you."
  end

  def nudge_content(_issue) do
    "Your session stopped without publishing a result Message in this Task, and the Task is " <>
      "still active. Continue the work and publish exactly one result Message: the result, or " <>
      "a failure Message that says what blocked you. Do not stay silent."
  end

  @doc false
  def notify_content(reason, activity, opts \\ [])

  def notify_content("provider_quota_exhausted", _activity, opts) do
    loop_state = Keyword.get(opts, :loop_state)

    "#{notify_subject(loop_state)} is blocked (provider_quota_exhausted): the model provider " <>
      "account it uses, the workspace's own API key or subscription, is out of credits or " <>
      "quota. Tell the requester to add funds or raise the limit with that provider; Comma " <>
      "credits do not fix this. Do not wait_for it again or retry it until that changes. " <>
      blocked_notify_tail(loop_state, :fail_only)
  end

  def notify_content("model_unavailable", _activity, opts) do
    loop_state = Keyword.get(opts, :loop_state)

    "#{notify_subject(loop_state)} is blocked (model_unavailable): it cannot use its configured " <>
      "model right now, and new instructions fail the same way. Tell the requester to choose " <>
      "another model for this Worker in Settings > Model & API, or, if the model service is " <>
      "temporarily out, to try again later. " <>
      "Do not wait_for it again or retry it until that changes. " <>
      blocked_notify_tail(loop_state, :fail_only)
  end

  def notify_content(reason, activity, opts) when reason in ~w(quota_exhausted rate_limited) do
    # The activity was re-read and version-fenced in handle_timeout. Carry its
    # bounded runtime diagnosis, including a provider reset time when present.
    detail = activity["status"] |> text() |> String.slice(0, 320)
    loop_state = Keyword.get(opts, :loop_state)

    "#{notify_subject(loop_state)} is blocked (#{reason}). #{detail} " <>
      "Tell the requester that the external Worker hit a usage limit and include the " <>
      "provider reset time if present; do not promise automatic recovery. " <>
      "Do not wait_for it again or retry it repeatedly while limited. " <>
      blocked_notify_tail(loop_state, :fail_or_retry)
  end

  def notify_content(reason, _activity, opts) when reason in @billing_denial_issues do
    loop_state = Keyword.get(opts, :loop_state)

    "#{notify_subject(loop_state)} is blocked by billing (#{reason}): the workspace cannot pay " <>
      "for the Worker's model requests. Tell the requester that the workspace is out of " <>
      "usage credits or its billing account is unavailable, and that they must add credits " <>
      "or fix billing before #{if(loop_state == :active, do: "runs", else: "the Task")} can continue. " <>
      "This is not a platform outage. Do not wait_for it again or retry it until billing changes. " <>
      blocked_notify_tail(loop_state, :fail_only)
  end

  def notify_content(reason, _activity, opts) do
    case Keyword.get(opts, :loop_state) do
      :active ->
        "The Worker for this Loop Task stopped without publishing a result for this run (#{reason}). " <>
          "You are the Task creator and must decide: send it new instructions with " <>
          "im_api.internal.send_message, keep the Task active so its Background Loop stays " <>
          "scheduled, or mark the Task failed or cancelled with im_api.internal.update_conversation " <>
          "only if the recurring Loop itself should end for good. Do not wait_for it again."

      :paused ->
        "The Worker for this Loop Task stopped without publishing a result (#{reason}). " <>
          "Its Background Loop is currently paused rather than running, and has not ended. " <>
          "Send it new instructions with im_api.internal.send_message to resume or repair the Loop, " <>
          "or mark the Task failed or cancelled with im_api.internal.update_conversation only if " <>
          "the recurring Loop should end for good. Do not wait_for it again."

      :failed ->
        "The Worker for this Loop Task stopped without publishing a result (#{reason}). " <>
          "Its Background Loop is currently stopped in a failed state rather than running, and has " <>
          "not ended. Send it new instructions with im_api.internal.send_message to repair the Loop, " <>
          "or mark the Task failed or cancelled with im_api.internal.update_conversation if the " <>
          "recurring Loop should end for good. Do not wait_for it again."

      :pending ->
        "The Worker for this Loop Task stopped without publishing a result (#{reason}) while its " <>
          "requested Background Loop is still pending (never created), so nothing will run on its " <>
          "own. Send it new instructions with im_api.internal.send_message to finish setup, or mark " <>
          "the Task failed or cancelled with im_api.internal.update_conversation (which ends the " <>
          "requested Loop). Do not wait_for it again."

      nil ->
        "The Worker for this Task stopped without publishing a result (#{reason}). " <>
          "You are the Task creator and must decide: send it new instructions with " <>
          "im_api.internal.send_message, mark the Task failed or cancelled with " <>
          "im_api.internal.update_conversation, or create a new Task. Do not wait_for it again."
    end
  end

  defp notify_subject(:active), do: "This run of the Loop Task"
  defp notify_subject(_other), do: "The Worker for this Task"

  defp blocked_notify_tail(:active, _mode) do
    "Keep the Task active so its Background Loop stays scheduled; only mark it " <>
      "failed or cancelled with im_api.internal.update_conversation if the " <>
      "requester asks to stop the recurring Loop (ending the Task ends its Loop for good)."
  end

  defp blocked_notify_tail(:paused, _mode) do
    "This Task's Background Loop is currently paused rather than running, but has not ended. " <>
      "Keep the Task active so the Loop can be resumed once resolved; only mark it failed or " <>
      "cancelled with im_api.internal.update_conversation if the requester asks to stop the " <>
      "recurring Loop for good."
  end

  defp blocked_notify_tail(:failed, _mode) do
    "This Task's Background Loop is currently stopped in a failed state rather than running, " <>
      "so nothing will run on its own once resolved until the Worker repairs it via " <>
      "im_api.internal.send_message; mark the Task failed or cancelled with " <>
      "im_api.internal.update_conversation if the recurring Loop should end for good."
  end

  defp blocked_notify_tail(:pending, _mode) do
    "This Task's requested Background Loop is still pending (never created), so nothing will " <>
      "run on its own once resolved until the Worker receives instructions again with " <>
      "im_api.internal.send_message, or mark the Task failed with " <>
      "im_api.internal.update_conversation (which ends the requested Loop)."
  end

  defp blocked_notify_tail(nil, :fail_or_retry) do
    "The Task has not completed; use im_api.internal.update_conversation to mark it failed, " <>
      "or explicitly arrange a later retry."
  end

  defp blocked_notify_tail(nil, :fail_only) do
    "The Task has not completed; use im_api.internal.update_conversation to mark it failed."
  end

  defp loop_running_active?({:ok, %{"status" => "active"} = view}),
    do: SalixIM.TaskLoop.running?(view)

  defp loop_running_active?({:ok, _view}), do: false
  defp loop_running_active?({:error, _reason}), do: true

  defp loop_stop_state({:ok, %{"trigger" => %{}, "status" => "active"}}), do: :active
  defp loop_stop_state({:ok, %{"trigger" => %{}, "status" => "paused"}}), do: :paused
  defp loop_stop_state({:ok, %{"trigger" => %{}, "status" => "pending"}}), do: :pending
  defp loop_stop_state({:ok, %{"trigger" => %{}, "status" => "failed"}}), do: :failed
  defp loop_stop_state({:ok, _view}), do: nil
  defp loop_stop_state({:error, _reason}), do: :active

  defp now, do: SystemsClock.system_time(:millisecond)

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
