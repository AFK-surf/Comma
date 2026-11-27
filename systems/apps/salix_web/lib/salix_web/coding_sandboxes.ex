defmodule SalixWeb.CodingSandboxes do
  @moduledoc """
  The lifecycle of sandbox Tasks' sandboxes (`runs_on {kind: sandbox}`): one
  L4ES sandbox at a time per Task, running the Comma station, which Salix
  invites to the Task once it connects. A Task with a repository (`repo`) is
  a coding Task: its sandbox gets a GitHub grant and a git identity, and its
  station prepares the checkout. A Task without one gets the same
  sandbox, lifecycle and metering, and nothing of GitHub. The facts live on
  the Task's Compute Workload (`SalixStore.CodingSandboxes`); this module
  acts on them.

    * `reserve/1`: the Task is about to be made. Its Workload is written in
      state `starting`, due for a check at once.
    * Checks (`check_due/0`, every #{div(15_000, 1000)} s on each node, at most
      #{20} Workloads a pass, claimed with a lease): a `starting` Workload
      without a sandbox gets one (`SalixWeb.L4ES.create/3`) of the release's
      image (`SalixWeb.L4ES.ensure_image/1`), with the Workload's connect
      credential as a secret and, for a coding Task, a GitHub grant: `write`
      on the Task's repository, pushes to the Task's branch only, and the
      Group's GitHub token, which L4ES keeps out of the sandbox (its node's
      proxy uses it).
      An existing sandbox keeps its saved ACL, including Router updates
      through `update_github/3`.
      A sandbox that does not connect within 5 minutes is stopped and `failed`. A
      `ready` Workload is checked every 5 minutes: a sandbox L4ES no longer
      runs is `lost`, and an active Task is told once, as a notice that asks
      for a reply and restarts nothing; an idle Session (nothing running,
      nothing pending, `task.status`) of a Task in review or ended for 3
      minutes, or of any Task for 2 hours, has its sandbox stopped
      (`stopped`). Shutdown leaves
      the repository unchanged and reports uncommitted or unpushed work on
      the sandbox disk. A Task going into review is checked at once (`task_status/3`). A GitHub token that
      expires is replaced in L4ES 45 s before it does, once the credential
      store has refreshed it (`rotate_github/1`).
    * `connected/1`: the sandbox's station connected: `ready`, and invited to
      the Task the first time (`SalixWeb.StationTasks.invite/1`).
    * `wake/2`: a Task that has not ended has a Message for its `stopped` or
      `lost` sandbox, or for the `ended` one of a Task made active again: the
      next generation
      (`SalixStore.CodingSandboxes.advance/2`), with a new connect
      credential. Its sandbox is the Task's sandbox before, started again
      from the data disk L4ES kept (`disk`): its station goes on with its
      Session, workspace and thread of the Task. A disk L4ES gave up starts
      empty: the station has no thread of the Task, so it is invited again
      with the stored `start` and given the whole Task (`SalixWeb.StationTasks`).
      A sandbox L4ES refuses to start as asked (409: another disk size, say)
      is deleted with its disk and made again, unless it is still stopping.
      So is one still pending on its kept disk 150 s after L4ES accepted its
      start: its node is draining, and L4ES holds the sandbox for it longer
      than the start budget. The Task is told of the new disk, and the start
      budget runs again from the remake, once per generation. A start L4ES
      failed is made again too, at most twice and within the start budget,
      only when its disk never ran or L4ES reports it missing; one that may
      hold the Task's work fails, and a reply starts it again from its disk.
      A remade sandbox takes a new name: L4ES keeps the old one until its node
      confirms the delete.
    * `task_status/3`: the Task ended or was archived: its sandbox is stopped
      (`ended`). As at any stop, L4ES keeps its disk. A Task made active again
      has its sandbox woken as by a Message, only when the Task's latest
      Message of a person or Agent is one the Worker has not answered. A
      Message that comes while the Task is ended asks for no sandbox: the end
      would stop it at the next check.
    * `turn_ended/2`: the Task's Session ended a turn. Its token use, its
      change totals and its branch's pull request are read then and kept on
      the Workload (`facts`, `remember/4`), so a Task panel opened later shows
      them before the sandbox answers it. The sandbox and GitHub stay the
      records: `facts` is what they answered last.

  Each start is timed from `starting` to the station's connection or to
  giving up, each run's end counted, and the fleet published once a minute
  per node (`salix.sandbox.*` in `Salix.Telemetry`;
  `SalixWeb.CodingSandboxes.FleetMetrics`).

  A sandbox start is authorized against the Workspace's billing account
  first (`authorize/4`: `config :salix_web, :vm_authorization_mod`, the
  fee control's `resource_kind` vm, provider `l4es`, sku `sandbox-<size>`),
  when the Task is placed on a sandbox (`Salix.Bindings.AgentConversations`)
  and when a stopped sandbox is woken (`wake/2`): a Workspace that cannot
  pay gets no Task, or a notice in the Task and its sandbox left stopped. A
  Group with no billing account is neither charged nor refused. Sandbox time
  from `ready` to its end is metered as VM time (provider `l4es`, sku
  `sandbox-<size>`), through `config :salix_web, :vm_metering_mod`.
  """

  use GenServer
  require Logger

  alias SalixStore.CodingSandboxes, as: Store
  alias SalixStore.Compute.WorkloadCredential
  alias SalixWeb.{L4ES, StationTasks}

  @pass_ms 15_000
  @page 20
  @lease_ms 120_000
  @starting_check_ms 30_000
  @ready_check_ms 300_000
  # A sandbox L4ES did not stop is asked again this often.
  @leftover_retry_ms 60_000
  # A lost sandbox's notice that was not written is written again this often.
  @lost_notice_retry_ms 60_000
  # States of a sandbox that no longer runs.
  @gone ~w(failed deleted lost stopping stopped)
  # Workload states a Message starts a next generation from.
  @wakeable ~w(stopped lost ended failed)
  @start_budget_ms 300_000
  # A station that answered a heartbeat this recently is live: Salix sends
  # one every 15 s and drops a connection unanswered for 45 s.
  @heartbeat_fresh_ms 60_000
  # A sandbox started again from its disk, still pending on that disk this
  # long after L4ES accepted the start, is made again on a new disk
  # (`unplaced/1`): after L4ES's 120 s failover grace, within which it moves
  # the sandbox off a dead or full node itself, and well within the budget.
  @pinned_remake_ms 150_000
  # A sandbox L4ES failed to start, with no disk of the Task's on a node, is
  # made again this many times within the start budget (`failed_start/2`).
  @failed_start_retries 2
  # A sandbox's GitHub token is replaced this long before it expires: within
  # the credential store's refresh leeway (60 s), so the token read is new.
  @github_rotate_ms 45_000
  # The calls a create waits for (`create_sandbox/1`), within the check's lease.
  @prepare_timeout_ms 90_000
  # Each read of what a turn left (`turn_ended/2`): the station's, as a Task
  # panel's own read is bounded.
  @facts_read_ms 20_000
  @idle_stop_ms :timer.hours(2)
  # How long the Session of a Task in review or ended is idle before its
  # sandbox stops: a quick follow-up finds it still up.
  @resting_idle_ms :timer.minutes(3)
  @ended ~w(completed cancelled failed archived)
  # The fleet gauges (SalixWeb.CodingSandboxes.FleetMetrics): one aggregate
  # read per node per minute on the pass, no timer of its own.
  @fleet_metrics_every_ms 60_000
  # A Task whose work is done for now: in review, or ended. Its sandbox stops
  # once its Session is idle for 3 minutes (`idle_check/1`); a Task made active
  # again starts it from its disk (`check/1`).
  @resting ["ready_for_review" | @ended]

  # --- Reservation and events

  @doc """
  Writes the Workload of a sandbox Task about to be made, in state
  `starting`. Refused when sandboxes are off.
  """
  def reserve(%{tenant_id: tenant, group_id: group, conversation_id: conversation} = r) do
    if L4ES.enabled?() do
      case Store.create(%{
             tenant_id: tenant,
             group_id: group,
             conversation_id: conversation,
             workspace: L4ES.workspace_ref(group),
             repo: r.repo,
             agent_id: r.agent_id,
             start: r.start,
             starts: r[:starts],
             account_id: r[:account_id],
             requester: r[:requester],
             size: L4ES.config().size
           }) do
        {:ok, _workload} ->
          poke()
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :sandbox_unavailable}
    end
  end

  @doc "Replaces the GitHub ACL of the Task's existing sandbox, including a stopped sandbox."
  def update_github(group, conversation, github) when is_map(github) or github == false do
    with true <- byte_size(Jason.encode!(github)) <= 16_384,
         {:ok, tenant} <- tenant_of(group),
         {:ok, %{spec: %{"group_id" => ^group} = spec}} <-
           Store.get_by_conversation(tenant, conversation),
         name when is_binary(name) <- spec["sandbox"] || spec["disk"] do
      L4ES.update_github(group, name, github)
    else
      false -> {:error, "The GitHub ACL must not exceed 16 KiB"}
      nil -> {:error, "The coding sandbox has not been created yet. Retry after it starts"}
      {:ok, _} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def update_github(_group, _conversation, _github),
    do: {:error, "github must be an ACL object or false"}

  @doc """
  `user` asks to see the screen of Task `conversation`'s sandbox. Only the
  person whose Task it is may (`screen_owner/2`). The sandbox's station is told to admit them on the mesh
  for a few minutes (`SalixWeb.StationPlace.show_screen/2`), and the Device
  the sandbox runs as is given: a client views its display as a computer's,
  and asks again while it views. Nothing runs for a sandbox no one asks to
  see.

  `{:error, :sandbox_not_running}` when no sandbox is ready, `:forbidden`
  for anyone else and for that person with no role in the Group or a
  read-only one, `:sandbox_has_no_screen` when the sandbox's station has not
  said it serves one (an image from before, or a station that has yet to
  prove its key), `:station_unreachable` when it could not be told.
  """
  def show_screen(tenant, group, conversation, user) when is_binary(user) do
    with {:ok, %{spec: %{"state" => "ready"} = spec}} <-
           Store.get_by_conversation(tenant, conversation),
         %{"device_id" => device, "connector_run_id" => run}
         when is_binary(device) and is_binary(run) <- spec do
      with ^user <- screen_person(spec),
           :ok <- serves_screen(tenant, group, device),
           :ok <-
             SalixWeb.StationPlace.show_screen(
               %{tenant_id: tenant, group_id: group, connector_run_id: run},
               user
             ) do
        {:ok, device}
      else
        {:error, reason} when reason in [:sandbox_has_no_screen, :station_unreachable] ->
          {:error, reason}

        _ ->
          {:error, :forbidden}
      end
    else
      _ -> {:error, :sandbox_not_running}
    end
  end

  defp serves_screen(tenant, group, device) do
    with {:ok, device} <- SalixEnv.Registry.get_device(tenant, group, device),
         true <- serves_screen?(device) do
      :ok
    else
      _ -> {:error, :sandbox_has_no_screen}
    end
  end

  @doc """
  Whether the station of a sandbox's Device (`SalixEnv.Registry.get_device/3`)
  serves its display now: it is connected, and said so with its station's id.
  The one rule for `show_screen/4` and for what a client is told of the
  sandbox.
  """
  def serves_screen?(%{
        "status" => "connected",
        "meta" => %{"station_id" => station, "capabilities" => %{"screen_view" => true}}
      })
      when is_binary(station),
      do: true

  def serves_screen?(_device), do: false

  # The process groups `SalixWeb.StationTaskIndex` starts, across the cluster.
  @pg SalixWeb.StationTaskIndex.PG

  @doc """
  What the station of a sandbox says of itself that its Task's run shows
  (`CommaWeb.SalixClient.task_run/2`), of its connection's `capabilities`:
  the models it runs, whether it serves its display, and whether something is
  on that display now (`screen_active`: a Session's browser is open on it).
  """
  def station_says(%{} = capabilities),
    do: Map.take(capabilities, ~w(task_models screen_view screen_active))

  def station_says(_capabilities), do: %{}

  @doc """
  Whether something is on the display of a sandbox's Device now, as its
  station says (`SalixEnv.Registry.get_device/3`).
  """
  def screen_active?(%{"meta" => %{"capabilities" => %{"screen_active" => true}}}), do: true
  def screen_active?(_device), do: false

  @doc """
  Sends `subscriber` `{:coding_sandbox_said, conversation}` each time the
  station of that Task's sandbox says something new of itself
  (`station_says/1`), until it exits. The message carries no fact: who
  hears it reads the Task's run again.
  """
  def subscribe_station(tenant, conversation, subscriber)
      when is_binary(tenant) and is_binary(conversation) and is_pid(subscriber) do
    :pg.join(@pg, {:coding_sandbox, tenant, conversation}, subscriber)
  end

  @doc """
  The station of sandbox `device` said something new of itself, and it is
  kept: the Task's open streams are told (`subscribe_station/3`). At most
  once for each change of `station_says/1` on a connection: as it connects,
  and as a Session's browser opens or goes.
  """
  def station_said(tenant, "dev-sbx-" <> conversation) when is_binary(tenant) do
    for pid <- :pg.get_members(@pg, {:coding_sandbox, tenant, conversation}),
        do: SystemsRuntime.Proc.send(pid, {:coding_sandbox_said, conversation})

    :ok
  end

  def station_said(_tenant, _device), do: :ok

  @doc """
  Whom the sandbox of `spec` shows its screen to: the person whose Task it
  is, of its Task conversation `conversation`. That is the person the sandbox
  was made for (`requester`), else the Task's Comma owner (`owner_user_id`),
  else the Comma user who asked for it (`source_refs.ifc_requester`). A Task
  the Router made from a person's message names no owner; the server writes
  who asked when it makes the Task, and no agent can change it
  (`SalixIM.IFCSourceRefs`). A provider user who asked in a Slack or Feishu
  chat is no Comma user: no one is shown the screen. Nil when no one is.
  This names the person; `show_screen/4` still checks their role at each ask.
  """
  def screen_owner(%{"requester" => owner}, _conversation) when is_binary(owner) and owner != "",
    do: owner

  def screen_owner(_spec, %{"owner_user_id" => owner}) when is_binary(owner) and owner != "",
    do: owner

  def screen_owner(_spec, %{"source_refs" => %{"ifc_requester" => principal}})
      when is_binary(principal) do
    case SalixIFC.Codec.decode_principal(principal) do
      {:ok, {:comma_user, user}} -> user
      _other -> nil
    end
  end

  def screen_owner(_spec, _conversation), do: nil

  # `screen_owner/2` of the sandbox, its Task conversation read only when the
  # sandbox does not name the person.
  defp screen_person(%{"requester" => owner} = spec) when is_binary(owner) and owner != "",
    do: screen_owner(spec, nil)

  defp screen_person(spec) do
    case StationTasks.task(spec["group_id"], spec["conversation_id"]) do
      {:ok, task} -> screen_owner(spec, task)
      _unread -> nil
    end
  end

  @doc "The station of a coding Task connected with its exact Workload generation and run."
  def connected(%{tenant_id: tenant, device_id: device} = connection) do
    with {:ok, workload} <- Store.get_by_device(tenant, device),
         {:ok, workload} <-
           SalixEnv.StationConnection.with_current(
             connection,
             fn _owner ->
               Store.update(workload.id, fn w ->
                 if w.spec["state"] in ~w(starting ready) do
                   # Under the row lock: a run whose station connects twice
                   # is timed once, by the connection that found it starting.
                   if w.spec["state"] == "starting", do: started(w, :ok)

                   # The run's ready time is when its station first connected;
                   # a stop leaves the key as nil, so each generation sets it anew
                   # (`meter/1` reads it) and a connection again in the same run
                   # keeps it.
                   ready_at =
                     if w.spec["state"] == "starting",
                       do: now_ms(),
                       else: w.spec["ready_at"] || now_ms()

                   {:ok,
                    w.spec
                    |> Map.merge(%{"state" => "ready", "reason" => nil, "ready_at" => ready_at})
                    |> Map.put("next_check_at", iso_in(check_in(w.spec, @ready_check_ms)))
                    |> Map.put("connector_run_id", connection.connector_run_id)}
                 else
                   {:error, :not_starting}
                 end
               end)
             end,
             lock: true
           ) do
      # Only reconcile when the primary has not been invited yet or there are secondary slots to reconcile.
      if workload.spec["invited"] != true or length(spec_starts(workload.spec)) > 1 do
        reconcile_invites(workload)
      end

      :ok
    else
      # Only a coding Task's station reaches here (`SalixWeb.ConnectorSocket`):
      # the Workload is gone, the connection is not the current run or
      # generation, or the Workload is not starting. Often benign (a late old
      # run whose replacement connects itself, a Workload being stopped), but
      # it is the one trace of a start that then waits out its budget.
      other ->
        Logger.warning(
          "a coding sandbox's station connected but its Workload was not marked ready: " <>
            "tenant=#{tenant} device=#{device} workload=#{connection[:workload_id]} " <>
            "generation=#{connection[:workload_generation]} run=#{connection[:connector_run_id]} " <>
            "#{inspect(other)}"
        )

        :ok
    end
  end

  @doc """
  Reconciles `spec["starts"]` (or single-session `spec["start"]`) directly against
  idempotent Station `task.invite` and `StationTaskSessions` — no `invited_slots`
  shadow state. For multi-session Tasks, checks `"multi_session_tasks"` capability
  before starting any session so an older sandbox image fails cleanly without
  partial starts.
  """
  def reconcile_invites(workload) do
    spec = workload.spec
    starts = spec_starts(spec)
    multi? = length(starts) > 1

    with :ok <- check_sandbox_multi_capability(spec, multi?),
         {:ok, existing_rows} <-
           SalixStore.StationTaskSessions.of_task(spec["group_id"], spec["conversation_id"]) do
      existing_by_slot =
        existing_rows
        |> Enum.reject(&SalixStore.StationTaskSessions.awaited?/1)
        |> Enum.filter(&(&1.device_id == spec["device_id"]))
        |> Map.new(fn row ->
          slot = get_in(row.start || %{}, ["slot"]) || "lead"
          {slot, row}
        end)

      primary_slot =
        case Enum.find(starts, &(&1["is_primary"] == true)) || List.first(starts) do
          %{"slot" => s} when is_binary(s) and s != "" -> s
          _ -> "lead"
        end

      primary_already_joined? =
        spec["invited"] == true or Map.has_key?(existing_by_slot, primary_slot)

      now_ms = SystemsClock.system_time(:millisecond)
      by_slot = get_in(spec, ["pending_secondaries", "by_slot"]) || %{}

      {result, dropped_slots, succeeded_slots, stale_slots, transient_failures, deferred_slots,
       primary_joined?} =
        starts
        |> Enum.with_index()
        |> Enum.reduce_while(
          {:ok, [], [], [], [], [], primary_already_joined?},
          fn {entry, idx}, {:ok, dropped, succeeded, stale, failures, deferred, p_joined?} ->
            slot = entry["slot"] || "lead"
            join? = idx > 0 and entry["is_primary"] != true
            next_retry_ms = get_in(by_slot, [slot, "next_retry_at_ms"])

            my_seq =
              entry["start_seq"] ||
                get_in(by_slot, [slot, "latest_seq"]) ||
                get_in(spec, ["slot_seq_hwm", slot]) || 0

            slot_meta = Map.get(by_slot, slot) || %{}
            pending_deact? = slot_meta["pending_deactivation"] == true
            deact_seq = slot_meta["deactivation_seq"] || 0
            existing_row = Map.get(existing_by_slot, slot)

            existing_seq =
              if existing_row, do: get_in(existing_row.start || %{}, ["start_seq"]) || 0, else: 0

            cond do
              (existing_row != nil and (my_seq == 0 or existing_seq >= my_seq)) or
                  (not join? and spec["invited"] == true) ->
                {:cont,
                 {:ok, dropped, [{slot, existing_seq} | succeeded], stale, failures, deferred,
                  p_joined? or slot == primary_slot}}

              join? and p_joined? and pending_deact? and my_seq <= deact_seq ->
                if is_integer(next_retry_ms) and next_retry_ms > now_ms do
                  {:cont,
                   {:ok, dropped, succeeded, stale, failures, [slot | deferred], p_joined?}}
                else
                  deact_entry =
                    if is_binary(slot_meta["participant_id"]) and
                         slot_meta["participant_id"] != "",
                       do: Map.put_new(entry, "participant_id", slot_meta["participant_id"]),
                       else: entry

                  case deactivate_sandbox_slot_participant(
                         spec["group_id"],
                         spec["conversation_id"],
                         deact_entry,
                         spec["device_id"],
                         workload_id: workload.id,
                         expected_seq: deact_seq,
                         require_pending_deact?: true
                       ) do
                    :ok ->
                      {:cont,
                       {:ok, [dropped_slot_snapshot(spec, deact_entry) | dropped], succeeded,
                        stale, failures, deferred, p_joined?}}

                    {:error, :superseded} ->
                      {:cont,
                       {:ok, dropped, succeeded, [{slot, my_seq} | stale], failures, deferred,
                        p_joined?}}

                    {:ok, :already_bound} ->
                      demoted_token = entry["demoted_binding_token"] || entry["demoted_session"]

                      if sandbox_slot_binding_state(spec, slot, demoted_token, my_seq) == :yes do
                        {:cont,
                         {:ok, dropped, [{slot, my_seq} | succeeded], stale, failures, deferred,
                          p_joined?}}
                      else
                        {:cont,
                         {:ok, dropped, succeeded, stale,
                          [
                            {slot,
                             {:pending_deactivation, deact_seq, entry_participant_id(deact_entry)}}
                            | failures
                          ], deferred, p_joined?}}
                      end

                    {:error, _deact_err} ->
                      {:cont,
                       {:ok, dropped, succeeded, stale,
                        [
                          {slot,
                           {:pending_deactivation, deact_seq, entry_participant_id(deact_entry)}}
                          | failures
                        ], deferred, p_joined?}}
                  end
                end

              join? and p_joined? and is_integer(next_retry_ms) and next_retry_ms > now_ms ->
                # Backed-off secondary slot: skip for now and keep attempting subsequent slots (e.g. `qa`).
                {:cont, {:ok, dropped, succeeded, stale, failures, [slot | deferred], p_joined?}}

              true ->
                invitation =
                  %{
                    tenant_id: spec["tenant_id"],
                    group_id: spec["group_id"],
                    conversation_id: spec["conversation_id"],
                    device_id: spec["device_id"],
                    start: entry["start"],
                    slot: slot,
                    join: join?,
                    multi_session: multi?
                  }

                explicit_seq = if my_seq > 0, do: my_seq, else: nil

                with {:ok, {session, used_run_id}} <- StationTasks.invite_with_run(invitation),
                     :ok <-
                       StationTasks.register_slot_binding(
                         invitation
                         |> build_slot_binding_entry(
                           spec,
                           entry,
                           session,
                           used_run_id,
                           explicit_seq
                         )
                         |> Map.put(:pre_join_check, fn ->
                           verify_reconcile_slot_live(workload.id, slot, my_seq)
                         end)
                       ) do
                  {:cont,
                   {:ok, dropped, [{slot, my_seq} | succeeded], stale, failures, deferred,
                    p_joined? or slot == primary_slot}}
                else
                  {:error, {:stale_slot_binding, _reason}} when join? and p_joined? ->
                    {:cont,
                     {:ok, dropped, succeeded, [{slot, my_seq} | stale], failures, deferred,
                      p_joined?}}

                  {:error, {:station_refused, why} = reason}
                  when join? and p_joined? and is_binary(why) ->
                    cond do
                      String.contains?(why, "no_active_primary") ->
                        {:cont,
                         {:ok, dropped, succeeded, stale, [{slot, reason} | failures], deferred,
                          p_joined?}}

                      verify_reconcile_slot_live(workload.id, slot, my_seq) != :ok ->
                        # Superseded by a newer generation (e.g. B(2)) while this invite was in-flight:
                        # never deactivate participant, never drop `starts`, only trim `seq <= my_seq`.
                        {:cont,
                         {:ok, dropped, succeeded, [{slot, my_seq} | stale], failures, deferred,
                          p_joined?}}

                      true ->
                        Logger.warning(
                          "coding sandbox secondary slot #{slot} permanently refused (#{inspect(reason)}); keeping healthy primary sandbox alive and deactivating unbound secondary participant: task=#{spec["conversation_id"]}"
                        )

                        case deactivate_sandbox_slot_participant(
                               spec["group_id"],
                               spec["conversation_id"],
                               entry,
                               spec["device_id"],
                               workload_id: workload.id,
                               expected_seq: my_seq
                             ) do
                          {:error, :superseded} ->
                            {:cont,
                             {:ok, dropped, succeeded, [{slot, my_seq} | stale], failures,
                              deferred, p_joined?}}

                          {:ok, :already_bound} ->
                            # Only clear pending when an active binding row with `start_seq >= my_seq`
                            # (and a different binding_token) is confirmed in DB; otherwise keep retrying.
                            demoted_token =
                              entry["demoted_binding_token"] || entry["demoted_session"]

                            if sandbox_slot_binding_state(spec, slot, demoted_token, my_seq) ==
                                 :yes do
                              {:cont,
                               {:ok, dropped, [{slot, my_seq} | succeeded], stale, failures,
                                deferred, p_joined?}}
                            else
                              {:cont,
                               {:ok, dropped, succeeded, stale, [{slot, reason} | failures],
                                deferred, p_joined?}}
                            end

                          :ok ->
                            notify_sandbox_slot_refused(spec, slot, reason)

                            {:cont,
                             {:ok, [dropped_slot_snapshot(spec, entry) | dropped], succeeded,
                              stale, failures, deferred, p_joined?}}

                          {:error, _deact_err} ->
                            {:cont,
                             {:ok, dropped, succeeded, stale,
                              [
                                {slot,
                                 {:pending_deactivation, my_seq, entry_participant_id(entry)}}
                                | failures
                              ], deferred, p_joined?}}
                        end
                    end

                  {:error, :station_outdated = reason} when join? and p_joined? ->
                    if verify_reconcile_slot_live(workload.id, slot, my_seq) != :ok do
                      {:cont,
                       {:ok, dropped, succeeded, [{slot, my_seq} | stale], failures, deferred,
                        p_joined?}}
                    else
                      Logger.warning(
                        "coding sandbox secondary slot #{slot} refused (station_outdated); keeping healthy primary sandbox alive and deactivating unbound secondary participant: task=#{spec["conversation_id"]}"
                      )

                      case deactivate_sandbox_slot_participant(
                             spec["group_id"],
                             spec["conversation_id"],
                             entry,
                             spec["device_id"],
                             workload_id: workload.id,
                             expected_seq: my_seq
                           ) do
                        {:error, :superseded} ->
                          {:cont,
                           {:ok, dropped, succeeded, [{slot, my_seq} | stale], failures, deferred,
                            p_joined?}}

                        {:ok, :already_bound} ->
                          demoted_token =
                            entry["demoted_binding_token"] || entry["demoted_session"]

                          if sandbox_slot_binding_state(spec, slot, demoted_token, my_seq) == :yes do
                            {:cont,
                             {:ok, dropped, [{slot, my_seq} | succeeded], stale, failures,
                              deferred, p_joined?}}
                          else
                            {:cont,
                             {:ok, dropped, succeeded, stale, [{slot, reason} | failures],
                              deferred, p_joined?}}
                          end

                        :ok ->
                          notify_sandbox_slot_refused(spec, slot, reason)

                          {:cont,
                           {:ok, [dropped_slot_snapshot(spec, entry) | dropped], succeeded, stale,
                            failures, deferred, p_joined?}}

                        {:error, _deact_err} ->
                          {:cont,
                           {:ok, dropped, succeeded, stale,
                            [
                              {slot, {:pending_deactivation, my_seq, entry_participant_id(entry)}}
                              | failures
                            ], deferred, p_joined?}}
                      end
                    end

                  {:error, reason} when join? and p_joined? ->
                    # Primary is already healthy: back off THIS secondary slot only and
                    # continue attempting subsequent slots (e.g. `qa`) without starving them.
                    Logger.warning(
                      "coding sandbox secondary slot #{slot} transient invite error (#{inspect(reason)}); keeping healthy primary sandbox alive and continuing remaining slots: task=#{spec["conversation_id"]}"
                    )

                    {:cont,
                     {:ok, dropped, succeeded, stale, [{slot, reason} | failures], deferred,
                      p_joined?}}

                  {:error, _} = err ->
                    {:halt, {err, dropped, succeeded, stale, failures, deferred, p_joined?}}
                end
            end
          end
        )

      _ = primary_joined?

      case result do
        :ok when transient_failures != [] or deferred_slots != [] or stale_slots != [] ->
          schedule_secondary_retries(
            workload,
            spec,
            Enum.reverse(transient_failures),
            dropped_slots,
            succeeded_slots,
            primary_joined?,
            nil,
            false,
            stale_slots
          )

        :ok ->
          if spec["invited"] != true or spec["invite_outcome"] != nil or
               spec["pending_secondaries"] != nil or dropped_slots != [] or
               succeeded_slots != [] do
            update(workload, fn s ->
              {next_s, next_by_slot} =
                apply_reconcile_slot_updates(s, succeeded_slots, [], dropped_slots)

              has_remaining? = map_size(next_by_slot) > 0

              next_s
              |> Map.put("invited", true)
              |> Map.delete("invite_outcome")
              |> put_pending_secondaries(next_by_slot, has_remaining?)
              |> then(fn cur ->
                if has_remaining? do
                  Map.put(cur, "next_check_at", iso_in(@starting_check_ms))
                else
                  cur
                end
              end)
            end)
          else
            :ok
          end

        {:error, {:secondary_transient, failed_slot, why}} ->
          schedule_secondary_retry(workload, spec, failed_slot, dropped_slots, why)

        {:error, {:station_transient, why}} ->
          Logger.warning(
            "coding sandbox primary invite transient error (#{inspect(why)}); keeping sandbox alive and scheduling retry: task=#{spec["conversation_id"]}"
          )

          update(workload, fn s ->
            by_slot = get_in(s, ["pending_secondaries", "by_slot"]) || %{}

            s
            |> put_pending_secondaries(by_slot, true)
            |> Map.put("reason", describe(why))
            |> put_earliest_next_check_at(iso_in(@starting_check_ms))
          end)

        {:error, {:station_invite_unknown, why}} ->
          update(
            workload,
            &Map.merge(&1, %{
              "invite_outcome" => "unknown",
              "reason" => describe(why),
              "next_check_at" => iso_in(@starting_check_ms)
            })
          )

        {:error, reason}
        when is_map_key(spec, "invite_outcome") and
               :erlang.map_get("invite_outcome", spec) == "unknown" ->
          retry(workload, "the invitation outcome is still unknown: #{describe(reason)}")

        {:error, reason} ->
          Logger.warning(
            "a coding sandbox's station did not take its Task: task=#{spec["conversation_id"]} #{inspect(reason)}"
          )

          stop(workload, "failed", "the sandbox did not take the Task: #{describe(reason)}")
      end
    else
      {:error, :station_outdated} ->
        case sandbox_primary_joined(spec) do
          :yes ->
            case SalixStore.StationTaskSessions.of_task(spec["group_id"], spec["conversation_id"]) do
              {:ok, rows} ->
                Logger.warning(
                  "coding sandbox image lacks multi_session_tasks capability; keeping healthy primary sandbox alive and stripping unjoined secondary starts: task=#{spec["conversation_id"]}"
                )

                existing_bound_slots =
                  rows
                  |> Enum.filter(
                    &(not SalixStore.StationTaskSessions.awaited?(&1) and
                        &1.device_id == spec["device_id"])
                  )
                  |> MapSet.new(fn r -> get_in(r.start || %{}, ["slot"]) || "lead" end)

                {_keep_entries, stripped_secondaries} =
                  Enum.split_with(starts, fn entry ->
                    slot = entry["slot"] || "lead"

                    entry["is_primary"] == true or slot == "lead" or
                      MapSet.member?(existing_bound_slots, slot)
                  end)

                {deactivated, failed_deact} =
                  Enum.reduce(stripped_secondaries, {[], []}, fn entry, {deact_acc, fail_acc} ->
                    slot = entry["slot"] || "lead"

                    my_seq =
                      entry["start_seq"] ||
                        get_in(spec, ["pending_secondaries", "by_slot", slot, "latest_seq"]) ||
                        get_in(spec, ["slot_seq_hwm", slot]) || 0

                    case deactivate_sandbox_slot_participant(
                           spec["group_id"],
                           spec["conversation_id"],
                           entry,
                           spec["device_id"],
                           workload_id: workload.id,
                           expected_seq: my_seq
                         ) do
                      {:error, :superseded} ->
                        # A newer generation (e.g. C(3)) already superseded this slot:
                        # never deactivate its participant and never drop its `starts` entry.
                        {deact_acc, fail_acc}

                      {:ok, :already_bound} ->
                        {deact_acc, fail_acc ++ [entry]}

                      :ok ->
                        notify_sandbox_slot_refused(spec, slot, :station_outdated)
                        {deact_acc ++ [entry], fail_acc}

                      {:error, _} ->
                        {deact_acc, fail_acc ++ [entry]}
                    end
                  end)

                deactivated_snapshots = Enum.map(deactivated, &dropped_slot_snapshot(spec, &1))

                if failed_deact != [] do
                  schedule_secondary_retry(
                    workload,
                    spec,
                    hd(failed_deact)["slot"],
                    deactivated_snapshots,
                    :station_outdated
                  )
                else
                  update(workload, fn s ->
                    safe_dropped_set = safe_drop_slot_set(s, deactivated_snapshots)

                    kept_starts =
                      case Enum.reject(
                             spec_starts(s),
                             &MapSet.member?(safe_dropped_set, &1["slot"])
                           ) do
                        [] -> Enum.take(spec_starts(s), 1)
                        list -> list
                      end

                    latest_by_slot =
                      (get_in(s, ["pending_secondaries", "by_slot"]) || %{})
                      |> Enum.reject(fn {k, _} -> MapSet.member?(safe_dropped_set, k) end)
                      |> Map.new()

                    reconcile_pending? =
                      get_in(s, ["pending_secondaries", "reconcile_pending"]) == true

                    s
                    |> Map.put("starts", kept_starts)
                    |> put_pending_secondaries(latest_by_slot, reconcile_pending?)
                  end)
                end

              {:error, of_err} ->
                Logger.warning(
                  "coding sandbox could not read StationTaskSessions during station_outdated check (#{inspect(of_err)}); retrying without deactivating secondaries: task=#{spec["conversation_id"]}"
                )

                schedule_secondary_retry(workload, spec, nil, [], of_err, true)
            end

          :unknown ->
            Logger.warning(
              "coding sandbox primary binding state unknown during station_outdated check; retrying without stopping sandbox: task=#{spec["conversation_id"]}"
            )

            schedule_secondary_retry(workload, spec, nil, [], :station_outdated, false)

          :no ->
            Logger.warning(
              "coding sandbox image lacks multi_session_tasks capability: task=#{spec["conversation_id"]}"
            )

            stop(
              workload,
              "failed",
              "the sandbox station image does not support multi-session Tasks (station_outdated)"
            )
        end

      {:error, reason} ->
        case sandbox_primary_joined(spec) do
          state when state in [:yes, :unknown] ->
            Logger.warning(
              "coding sandbox secondary reconciliation check failed (#{inspect(reason)}, primary=#{state}); keeping sandbox alive for retry: task=#{spec["conversation_id"]}"
            )

            schedule_secondary_retry(workload, spec, nil, [], reason, state == :yes)

          :no ->
            Logger.warning(
              "a coding sandbox's station did not take its Task: task=#{spec["conversation_id"]} #{inspect(reason)}"
            )

            stop(workload, "failed", "the sandbox did not take the Task: #{describe(reason)}")
        end
    end
  end

  @max_secondary_retries 5

  # Per-slot bounded backoff for unjoined secondary slots on an already-healthy sandbox.
  # - Only increments `pending_secondaries["by_slot"][failed_slot]["attempts"]` (never touching
  #   unattempted slots like `qa`).
  # - Never auto-deactivates a slot on transient timeouts/errors: after `@max_secondary_retries`,
  #   backs off to `@ready_check_ms` so only explicit `:station_refused` / `:station_outdated`
  #   deactivates a participant.
  # - Only persists `"invited" => true` when `primary_joined? == true` (NEVER on `:unknown`).
  defp schedule_secondary_retry(
         workload,
         spec,
         failed_slot,
         dropped_slots,
         why,
         primary_joined? \\ true
       ) do
    failures =
      if is_binary(failed_slot) and failed_slot != "",
        do: [{failed_slot, why}],
        else: []

    reconcile_pending? = failures == []

    schedule_secondary_retries(
      workload,
      spec,
      failures,
      dropped_slots,
      [],
      primary_joined?,
      why,
      reconcile_pending?
    )
  end

  defp schedule_secondary_retries(
         workload,
         spec,
         transient_failures,
         dropped_slots,
         succeeded_slots,
         primary_joined?,
         fallback_why,
         reconcile_pending?,
         stale_slots \\ []
       ) do
    now_ms = SystemsClock.system_time(:millisecond)

    reason_text =
      case transient_failures do
        [{_slot, why} | _] -> describe(why)
        [] when fallback_why != nil -> describe(fallback_why)
        [] -> spec["reason"] || "secondary slots pending retry"
      end

    update(workload, fn s ->
      {updated_s, base_by_slot} =
        apply_reconcile_slot_updates(s, succeeded_slots, stale_slots, dropped_slots)

      next_by_slot =
        Enum.reduce(transient_failures, base_by_slot, fn {slot, why}, acc ->
          if is_binary(slot) and slot != "" do
            prev = Map.get(acc, slot) || %{}
            attempts = (prev["attempts"] || 0) + 1

            delay =
              if attempts > @max_secondary_retries, do: @ready_check_ms, else: @starting_check_ms

            extra =
              case why do
                {:pending_deactivation, deact_seq, pid} ->
                  %{
                    "pending_deactivation" => true,
                    "deactivation_seq" => deact_seq,
                    "participant_id" => pid
                  }

                _ ->
                  %{}
              end

            Map.put(
              acc,
              slot,
              prev
              |> Map.merge(%{
                "attempts" => attempts,
                "next_retry_at_ms" => now_ms + delay
              })
              |> Map.merge(extra)
            )
          else
            acc
          end
        end)

      keep_reconcile? =
        reconcile_pending? or
          get_in(s, ["pending_secondaries", "reconcile_pending"]) == true or
          map_size(next_by_slot) > 0

      backoff_ms =
        next_by_slot
        |> Map.values()
        |> Enum.map(& &1["next_retry_at_ms"])
        |> Enum.filter(&is_integer/1)
        |> case do
          [] -> @starting_check_ms
          times -> max(1_000, Enum.min(times) - now_ms)
        end

      updated_s
      |> then(&if(primary_joined?, do: Map.put(&1, "invited", true), else: &1))
      |> put_pending_secondaries(next_by_slot, keep_reconcile?)
      |> then(fn cur ->
        if map_size(next_by_slot) == 0 and not keep_reconcile? do
          cur
        else
          cur
          |> Map.put("reason", reason_text)
          |> Map.put("next_check_at", iso_in(backoff_ms))
        end
      end)
    end)
  end

  defp apply_reconcile_slot_updates(s, succeeded_slots, stale_slots, dropped_slots) do
    safe_dropped_set = safe_drop_slot_set(s, dropped_slots)
    initial_by_slot = get_in(s, ["pending_secondaries", "by_slot"]) || %{}

    by_slot_after_drop =
      initial_by_slot
      |> Enum.reject(fn {k, _} -> MapSet.member?(safe_dropped_set, k) end)
      |> Map.new()

    s_after_drop =
      if MapSet.size(safe_dropped_set) > 0 do
        kept = Enum.reject(spec_starts(s), &MapSet.member?(safe_dropped_set, &1["slot"]))
        Map.put(s, "starts", kept)
      else
        s
      end

    # Apply generation-fenced updates for succeeded slots: only clear `request_seqs` with
    # `seq <= my_seq` and advance `slot_confirmed_seq` only when `my_seq >= live_seq`.
    {s_after_succ, by_slot_after_succ} =
      Enum.reduce(succeeded_slots, {s_after_drop, by_slot_after_drop}, fn item, {acc_s, acc_bs} ->
        {slot, my_seq} =
          case item do
            {sl, sq} when is_binary(sl) -> {sl, sq || 0}
            sl when is_binary(sl) -> {sl, 0}
          end

        if MapSet.member?(safe_dropped_set, slot) do
          {acc_s, acc_bs}
        else
          cur_entry = Enum.find(spec_starts(acc_s), &(&1["slot"] == slot))
          slot_meta = Map.get(acc_bs, slot)
          hwm = get_in(acc_s, ["slot_seq_hwm", slot]) || 0

          live_seq =
            Enum.max([
              (is_map(cur_entry) && cur_entry["start_seq"]) || 0,
              (is_map(slot_meta) && slot_meta["latest_seq"]) || 0,
              hwm
            ])

          next_s =
            if cur_entry != nil and my_seq >= live_seq and my_seq > 0 do
              prev_conf = get_in(acc_s, ["slot_confirmed_seq", slot]) || 0

              Map.put(
                acc_s,
                "slot_confirmed_seq",
                Map.put(acc_s["slot_confirmed_seq"] || %{}, slot, max(prev_conf, my_seq))
              )
            else
              acc_s
            end

          next_bs = trim_slot_meta_by_seq(acc_bs, acc_s, slot, my_seq, true)
          {next_s, next_bs}
        end
      end)

    # Apply generation-fenced updates for stale slots: NEVER touch `starts` or `slot_confirmed_seq`,
    # only trim `request_seqs` with `seq <= my_seq`, preserving newer requests (e.g. B(2)) & backoff!
    final_by_slot =
      Enum.reduce(stale_slots, by_slot_after_succ, fn {slot, my_seq}, acc_bs ->
        if MapSet.member?(safe_dropped_set, slot) do
          acc_bs
        else
          trim_slot_meta_by_seq(acc_bs, s_after_succ, slot, my_seq || 0, false)
        end
      end)

    {s_after_succ, final_by_slot}
  end

  defp trim_slot_meta_by_seq(by_slot, spec, slot, my_seq, clear_backoff_if_empty?) do
    case Map.get(by_slot, slot) do
      %{} = slot_meta ->
        req_seqs =
          case slot_meta["request_seqs"] do
            %{} = m -> m
            _ -> Map.new(slot_request_ids(spec, slot), &{&1, slot_meta["latest_seq"] || 0})
          end

        remaining_seqs =
          req_seqs
          |> Enum.reject(fn {_id, seq} -> (seq || 0) <= my_seq end)
          |> Map.new()

        has_backoff? =
          is_integer(slot_meta["next_retry_at_ms"]) or (slot_meta["attempts"] || 0) > 0

        cond do
          map_size(remaining_seqs) > 0 ->
            updated_meta =
              slot_meta
              |> Map.delete("request_id")
              |> Map.put("request_ids", Map.keys(remaining_seqs))
              |> Map.put("request_seqs", remaining_seqs)
              |> then(fn m ->
                if clear_backoff_if_empty? do
                  m |> Map.delete("attempts") |> Map.delete("next_retry_at_ms")
                else
                  m
                end
              end)

            Map.put(by_slot, slot, updated_meta)

          not clear_backoff_if_empty? and has_backoff? ->
            Map.put(
              by_slot,
              slot,
              slot_meta
              |> Map.delete("request_id")
              |> Map.delete("request_ids")
              |> Map.delete("request_seqs")
            )

          true ->
            Map.delete(by_slot, slot)
        end

      _ ->
        by_slot
    end
  end

  defp verify_reconcile_slot_live(workload_id, slot, my_seq) do
    case Store.get(workload_id) do
      {:ok, w} ->
        cur_entry = Enum.find(spec_starts(w.spec), &(&1["slot"] == slot))
        slot_meta = get_in(w.spec, ["pending_secondaries", "by_slot", slot]) || %{}
        hwm = get_in(w.spec, ["slot_seq_hwm", slot]) || 0

        live_seq =
          Enum.max([
            (is_map(cur_entry) && cur_entry["start_seq"]) || 0,
            slot_meta["latest_seq"] || 0,
            hwm
          ])

        if cur_entry != nil and my_seq >= live_seq do
          :ok
        else
          {:error, {:stale_slot_binding, :superseded}}
        end

      {:error, :not_found} ->
        {:error, {:stale_slot_binding, :superseded}}
    end
  end

  defp put_pending_secondaries(spec, by_slot, keep_reconcile?) do
    cond do
      map_size(by_slot) == 0 and not keep_reconcile? ->
        Map.delete(spec, "pending_secondaries")

      keep_reconcile? ->
        Map.put(spec, "pending_secondaries", %{
          "by_slot" => by_slot,
          "reconcile_pending" => true
        })

      true ->
        Map.put(spec, "pending_secondaries", %{"by_slot" => by_slot})
    end
  end

  defp put_earliest_next_check_at(spec, candidate_iso) when is_binary(candidate_iso) do
    case {spec["next_check_at"], DateTime.from_iso8601(candidate_iso)} do
      {existing_iso, {:ok, candidate_dt, _}} when is_binary(existing_iso) ->
        case DateTime.from_iso8601(existing_iso) do
          {:ok, existing_dt, _} ->
            if DateTime.compare(existing_dt, candidate_dt) != :gt,
              do: spec,
              else: Map.put(spec, "next_check_at", candidate_iso)

          _ ->
            Map.put(spec, "next_check_at", candidate_iso)
        end

      _ ->
        Map.put(spec, "next_check_at", candidate_iso)
    end
  end

  defp entry_participant_id(entry) when is_map(entry) do
    entry["participant_id"] || get_in(entry["start"] || %{}, ["participant_id"])
  end

  defp entry_participant_id(_), do: nil

  defp slot_request_ids(spec, slot) do
    case get_in(spec, ["pending_secondaries", "by_slot", slot]) do
      %{"request_ids" => list} when is_list(list) -> list
      %{"request_id" => id} when is_binary(id) -> [id]
      _ -> []
    end
  end

  defp dropped_slot_snapshot(spec, entry) when is_map(entry) do
    slot = entry["slot"]

    %{
      slot: slot,
      participant_id: entry_participant_id(entry),
      request_ids: slot_request_ids(spec, slot),
      start_seq: entry["start_seq"] || 0
    }
  end

  defp safe_drop_slot_set(latest_spec, dropped_items) do
    dropped_items
    |> Enum.reduce(MapSet.new(), fn
      %{slot: slot} = snap, acc when is_binary(slot) ->
        if slot_superseded?(latest_spec, snap), do: acc, else: MapSet.put(acc, slot)

      slot, acc when is_binary(slot) ->
        MapSet.put(acc, slot)

      _, acc ->
        acc
    end)
  end

  defp slot_superseded?(latest_spec, %{
         slot: slot,
         participant_id: old_pid,
         request_ids: old_ids,
         start_seq: old_seq
       }) do
    cur_entry = Enum.find(spec_starts(latest_spec), &(&1["slot"] == slot))
    cur_pid = entry_participant_id(cur_entry)

    pid_changed? =
      is_binary(cur_pid) and cur_pid != "" and cur_pid != old_pid

    cur_seq = (is_map(cur_entry) && cur_entry["start_seq"]) || 0
    latest_seq = get_in(latest_spec, ["pending_secondaries", "by_slot", slot, "latest_seq"]) || 0
    hwm_seq = get_in(latest_spec, ["slot_seq_hwm", slot]) || 0
    seq_advanced? = cur_seq > old_seq or latest_seq > old_seq or hwm_seq > old_seq

    old_id_set = MapSet.new(old_ids)
    latest_ids = slot_request_ids(latest_spec, slot)
    has_new_request? = Enum.any?(latest_ids, &(not MapSet.member?(old_id_set, &1)))

    pid_changed? or seq_advanced? or has_new_request?
  end

  # Tri-state check (`:yes | :no | :unknown`) so DB read failures never falsely
  # classify a healthy primary sandbox as unjoined and trigger `stop("failed")`.
  defp sandbox_primary_joined(spec) do
    if spec["invited"] == true do
      :yes
    else
      case SalixStore.StationTaskSessions.of_task(spec["group_id"], spec["conversation_id"]) do
        {:ok, rows} ->
          if Enum.any?(
               rows,
               &(not SalixStore.StationTaskSessions.awaited?(&1) and
                   &1.device_id == spec["device_id"])
             ),
             do: :yes,
             else: :no

        {:error, _} ->
          :unknown
      end
    end
  end

  defp notify_sandbox_slot_refused(spec, slot, reason) when is_binary(slot) and slot != "" do
    _ =
      StationTasks.notice(
        spec["group_id"],
        spec["conversation_id"],
        spec["agent_id"],
        "slot-refused:#{slot}",
        "Secondary session slot #{slot} could not join the sandbox (#{describe(reason)}) and was deactivated; remaining sessions continue."
      )

    :ok
  end

  defp notify_sandbox_slot_refused(_spec, _slot, _reason), do: :ok

  defp spec_starts(%{"starts" => [_ | _] = starts}) do
    Enum.sort_by(starts, fn s -> if s["is_primary"] == true, do: 0, else: 1 end)
  end

  defp spec_starts(%{"start" => start, "agent_id" => agent_id}) do
    [%{"slot" => "lead", "is_primary" => true, "agent_id" => agent_id, "start" => start}]
  end

  # Tri-state check (`:yes | :no | :unknown`) comparing `binding_token` (or legacy `session`)
  # so DB read errors NEVER falsely classify a slot as unbound.
  defp sandbox_slot_binding_state(spec, slot, demoted_token, min_seq \\ nil) do
    case SalixStore.StationTaskSessions.of_task(spec["group_id"], spec["conversation_id"]) do
      {:ok, rows} ->
        if Enum.any?(rows, fn r ->
             current_token = get_in(r.start || %{}, ["binding_token"]) || r.session
             row_seq = get_in(r.start || %{}, ["start_seq"]) || 0

             not SalixStore.StationTaskSessions.awaited?(r) and r.device_id == spec["device_id"] and
               (get_in(r.start || %{}, ["slot"]) || "lead") == slot and
               (is_nil(demoted_token) or current_token != demoted_token) and
               (not is_integer(min_seq) or min_seq <= 0 or row_seq >= min_seq)
           end),
           do: :yes,
           else: :no

      {:error, _} ->
        :unknown
    end
  end

  defp call_sandbox_deactivate_unbound(group_id, conversation_id, pid, stale_token, verify_fun) do
    mod = StationTasks.conversations_module()

    if function_exported?(mod, :deactivate_unbound_task_participant, 5) do
      mod.deactivate_unbound_task_participant(
        group_id,
        conversation_id,
        pid,
        stale_token,
        verify_fun
      )
    else
      SalixIM.ConversationServer.deactivate_unbound_task_participant(
        group_id,
        conversation_id,
        pid,
        stale_token,
        verify_fun
      )
    end
  end

  defp deactivate_sandbox_slot_participant(
         group_id,
         conversation_id,
         entry,
         device_id,
         opts
       ) do
    pid = entry["participant_id"] || get_in(entry, ["start", "participant_id"])
    stale_token = entry["demoted_binding_token"] || entry["demoted_session"]
    slot = entry["slot"] || get_in(entry, ["start", "slot"])
    workload_id = Keyword.get(opts, :workload_id)
    expected_seq = Keyword.get(opts, :expected_seq)
    require_pending_deact? = Keyword.get(opts, :require_pending_deact?, false)

    base_verify_fun =
      StationTasks.slot_verify_unbound_fun(group_id, conversation_id, device_id, slot)

    verify_unbound_fun =
      if is_binary(workload_id) and is_integer(expected_seq) do
        fn stale_tok ->
          case SalixStore.StationTaskSessions.with_device_lock(
                 group_id,
                 conversation_id,
                 device_id,
                 fn ->
                   case Store.get(workload_id) do
                     {:ok, w} ->
                       cur_entry = Enum.find(spec_starts(w.spec), &(&1["slot"] == slot))
                       slot_meta = get_in(w.spec, ["pending_secondaries", "by_slot", slot]) || %{}
                       hwm = get_in(w.spec, ["slot_seq_hwm", slot]) || 0

                       live_seq =
                         Enum.max([
                           (is_map(cur_entry) && cur_entry["start_seq"]) || 0,
                           slot_meta["latest_seq"] || 0,
                           hwm
                         ])

                       if live_seq > expected_seq or
                            (require_pending_deact? and slot_meta["pending_deactivation"] != true) do
                         {:ok, {:abort, :superseded}}
                       else
                         {:ok, base_verify_fun.(stale_tok)}
                       end

                     {:error, :not_found} ->
                       {:ok, base_verify_fun.(stale_tok)}
                   end
                 end
               ) do
            {:ok, verdict} -> verdict
            {:error, _} -> :unknown
          end
        end
      else
        base_verify_fun
      end

    if is_binary(pid) and pid != "" do
      case call_sandbox_deactivate_unbound(
             group_id,
             conversation_id,
             pid,
             stale_token,
             verify_unbound_fun
           ) do
        {:ok, :already_bound} -> {:ok, :already_bound}
        {:ok, _} -> :ok
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      slot = entry["slot"]

      if is_binary(slot) and slot != "" do
        case SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id) do
          {:ok, %{"participants" => parts}} when is_list(parts) ->
            case Enum.find(
                   parts,
                   &(&1["actor_type"] == "agent" and &1["role_label"] == "worker" and
                       &1["target_key"] == slot and &1["state"] != "inactive")
                 ) do
              %{"participant_id" => found_pid} ->
                case call_sandbox_deactivate_unbound(
                       group_id,
                       conversation_id,
                       found_pid,
                       stale_token,
                       verify_unbound_fun
                     ) do
                  {:ok, :already_bound} -> {:ok, :already_bound}
                  {:ok, _} -> :ok
                  :ok -> :ok
                  {:error, :not_found} -> :ok
                  {:error, reason} -> {:error, reason}
                end

              nil ->
                :ok
            end

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      else
        :ok
      end
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp check_sandbox_multi_capability(_spec, false), do: :ok

  defp check_sandbox_multi_capability(spec, true) do
    case SalixEnv.Registry.get_device(spec["tenant_id"], spec["group_id"], spec["device_id"]) do
      {:ok, %{"meta" => %{"capabilities" => capabilities}}} when is_map(capabilities) ->
        if SalixStore.StationReadiness.multi_session_ready?(capabilities),
          do: :ok,
          else: {:error, :station_outdated}

      {:ok, _device_without_caps} ->
        {:error, :station_outdated}

      {:error, reason} ->
        {:error, {:registry_unavailable, reason}}
    end
  end

  defp invite(workload), do: reconcile_invites(workload)

  @doc """
  Appends a dynamically added secondary session start entry to a sandbox Task's
  `spec["starts"]`.
  - When the sandbox is already `ready`, checks `multi_session_tasks` capability
    and invites + joins the new slot directly FIRST. Any failure returns
    `{:error, reason}` cleanly without stopping the healthy sandbox or persisting
    the failed slot into `spec["starts"]`.
  - When the sandbox is not yet `ready` (`starting`, `stopped`, etc.), appends
    to `spec["starts"]` so `connected/1` reconciles it when the sandbox connects.
  """
  def add_session_start(tenant, conversation, %{"slot" => slot} = entry)
      when is_binary(tenant) and is_binary(conversation) and is_binary(slot) do
    with {:ok, workload} <- Store.get_by_conversation(tenant, conversation) do
      if workload.spec["state"] == "ready" do
        spec = workload.spec

        invitation = %{
          tenant_id: spec["tenant_id"],
          group_id: spec["group_id"],
          conversation_id: spec["conversation_id"],
          device_id: spec["device_id"],
          start: entry["start"],
          slot: slot,
          join: true,
          multi_session: true
        }

        # Persist the pending start into `spec["starts"]` + `pending_secondaries`
        # with a unique `request_id` BEFORE firing `task.invite`; if persistence fails, send 0 RPCs.
        request_id =
          case entry["invite_id"] do
            id when is_binary(id) and id != "" -> id
            _ -> SalixStore.Ids.new_session_id()
          end

        with :ok <- check_sandbox_multi_capability(spec, true),
             {:ok, _persisted, my_seq} <-
               reserve_sandbox_slot_start(
                 workload.id,
                 spec,
                 slot,
                 entry,
                 request_id
               ) do
          case StationTasks.invite_with_run(invitation) do
            {:ok, {session, used_run_id}} when is_binary(session) ->
              case StationTasks.register_slot_binding(
                     invitation
                     |> build_slot_binding_entry(spec, entry, session, used_run_id, my_seq)
                     |> Map.put(:pre_join_check, fn ->
                       verify_slot_request_live(workload.id, slot, request_id, my_seq)
                     end)
                   ) do
                :ok ->
                  _ = confirm_start_entry(workload.id, slot, entry, request_id, my_seq)
                  :ok

                {:error, {:stale_slot_binding, _live_session}} ->
                  # Authoritatively verify whether DB holds an active binding with
                  # `start_seq >= my_seq` BEFORE dropping the request anchor!
                  case sandbox_slot_binding_state(spec, slot, nil, my_seq) do
                    :yes ->
                      _ = drop_stale_request_id(workload.id, slot, request_id)
                      :ok

                    :no ->
                      # Single atomic Store.update: either keeps remaining requests/backoff and
                      # drops only `request_id`, OR atomically converts the last unconfirmed
                      # request into a persisted `pending_deactivation: true` anchor so a crash
                      # or deactivation failure can NEVER lose the retry anchor!
                      case transition_stale_request_to_deactivation_or_drop(
                             workload.id,
                             slot,
                             request_id,
                             entry_participant_id(entry)
                           ) do
                        {:ok, {:pending_deactivation, live_seq}} ->
                          case deactivate_sandbox_slot_participant(
                                 spec["group_id"],
                                 spec["conversation_id"],
                                 entry,
                                 spec["device_id"],
                                 workload_id: workload.id,
                                 expected_seq: live_seq,
                                 require_pending_deact?: true
                               ) do
                            :ok ->
                              _ = cleanup_unconfirmed_stale_slot(workload.id, slot, live_seq)
                              {:error, :stale_slot_binding}

                            {:ok, :already_bound} ->
                              if sandbox_slot_binding_state(spec, slot, nil, my_seq) == :yes do
                                _ = clear_slot_pending_deactivation(workload.id, slot, live_seq)
                                :ok
                              else
                                {:error, :stale_slot_binding}
                              end

                            {:error, :superseded} ->
                              {:error, :stale_slot_binding}

                            {:error, _deact_err} ->
                              # `pending_deactivation: true` + `reconcile_pending: true` are
                              # already atomically persisted; periodic `reconcile_invites` will finish.
                              {:error, :stale_slot_binding}
                          end

                        {:ok, :keep} ->
                          {:error, :stale_slot_binding}

                        {:error, _store_err} ->
                          # Original `request_id` was NOT dropped; periodic check will reconcile.
                          {:error, :binding_state_unavailable}
                      end

                    :unknown ->
                      _ =
                        Store.update(workload.id, fn w ->
                          by_slot = get_in(w.spec, ["pending_secondaries", "by_slot"]) || %{}
                          {:ok, put_pending_secondaries(w.spec, by_slot, true)}
                        end)

                      {:error, :binding_state_unavailable}
                  end

                {:error, _} = err ->
                  err
              end

            {:error, reason} = err ->
              permanent_refusal? =
                reason == :station_outdated or
                  (match?({:station_refused, _}, reason) and
                     not (is_binary(elem(reason, 1)) and
                            String.contains?(elem(reason, 1), "no_active_primary")))

              if permanent_refusal? and sandbox_slot_binding_state(spec, slot, nil) == :no do
                _ = remove_start_entry(workload.id, slot, request_id, my_seq)
              end

              err
          end
        end
      else
        request_id =
          case entry["invite_id"] do
            id when is_binary(id) and id != "" -> id
            _ -> SalixStore.Ids.new_session_id()
          end

        with {:ok, _persisted, _my_seq} <-
               reserve_sandbox_slot_start(
                 workload.id,
                 workload.spec,
                 slot,
                 entry,
                 request_id,
                 reconcile_pending?: true
               ) do
          :ok
        end
      end
    end
  end

  # Serializes version allocation (`append_pending_start_entry`) through the same
  # `ConversationParticipantActor` mailbox as `deactivate_if_unbound` and `bind_station_session`
  # (global lock order: Actor -> `lock_device_tx` -> `workloads` / `station_task_sessions`),
  # eliminating any window where `C(3)` reserves a generation while `B(2)` deactivates the participant.
  defp reserve_sandbox_slot_start(workload_id, spec, slot, entry, request_id, opts \\ []) do
    reserve_fun = fn ->
      append_pending_start_entry(workload_id, spec, slot, entry, request_id, opts)
    end

    pid = entry_participant_id(entry)

    if is_binary(pid) and pid != "" do
      mod = StationTasks.conversations_module()

      res =
        if function_exported?(mod, :reserve_task_participant_session, 4) do
          mod.reserve_task_participant_session(
            spec["group_id"],
            spec["conversation_id"],
            pid,
            reserve_fun
          )
        else
          SalixIM.ConversationServer.reserve_task_participant_session(
            spec["group_id"],
            spec["conversation_id"],
            pid,
            reserve_fun
          )
        end

      case res do
        {:error, :not_found} when mod != SalixWeb.StationTasks.Conversations ->
          reserve_fun.()

        other ->
          other
      end
    else
      reserve_fun.()
    end
  end

  defp append_pending_start_entry(workload_id, spec, slot, entry, request_id, opts) do
    force_reconcile? = Keyword.get(opts, :reconcile_pending?, false)

    do_append = fn ->
      case check_sandbox_slot_config_conflict(spec, slot, entry) do
        :ok ->
          case Store.update(workload_id, fn w ->
                 existing = spec_starts(w.spec)
                 prev_slot = get_in(w.spec, ["pending_secondaries", "by_slot", slot]) || %{}
                 cur_idx = Enum.find_index(existing, &(&1["slot"] == slot))
                 cur_entry = if cur_idx, do: Enum.at(existing, cur_idx), else: nil

                 hwm = get_in(w.spec, ["slot_seq_hwm", slot]) || 0

                 next_seq =
                   Enum.max([
                     (is_map(cur_entry) && cur_entry["start_seq"]) || 0,
                     prev_slot["latest_seq"] || 0,
                     hwm
                   ]) + 1

                 next_hwm_map = Map.put(w.spec["slot_seq_hwm"] || %{}, slot, next_seq)

                 next_starts =
                   case cur_idx do
                     nil ->
                       existing ++ [Map.put(entry, "start_seq", next_seq)]

                     idx ->
                       new_pid = entry_participant_id(entry)
                       cur_pid = entry_participant_id(cur_entry)

                       updated_entry =
                         if is_map(entry["start"]) do
                           entry
                           |> then(fn e ->
                             if (is_nil(new_pid) or new_pid == "") and is_binary(cur_pid) and
                                  cur_pid != "",
                                do: Map.put(e, "participant_id", cur_pid),
                                else: e
                           end)
                           |> Map.put("start_seq", next_seq)
                         else
                           Map.put(cur_entry, "start_seq", next_seq)
                         end

                       List.replace_at(existing, idx, updated_entry)
                   end

                 prev_ids = slot_request_ids(w.spec, slot)

                 next_ids =
                   if request_id in prev_ids, do: prev_ids, else: prev_ids ++ [request_id]

                 prev_req_seqs =
                   case prev_slot["request_seqs"] do
                     %{} = m -> m
                     _ -> Map.new(prev_ids, &{&1, prev_slot["latest_seq"] || 0})
                   end

                 next_req_seqs = Map.put(prev_req_seqs, request_id, next_seq)

                 by_slot =
                   (get_in(w.spec, ["pending_secondaries", "by_slot"]) || %{})
                   |> Map.put(
                     slot,
                     prev_slot
                     |> Map.delete("request_id")
                     |> Map.delete("pending_deactivation")
                     |> Map.delete("deactivation_seq")
                     |> Map.delete("deactivation_participant_id")
                     |> Map.merge(%{
                       "attempts" => prev_slot["attempts"] || 0,
                       "latest_seq" => next_seq,
                       "request_ids" => next_ids,
                       "request_seqs" => next_req_seqs
                     })
                   )

                 reconcile_pending? =
                   force_reconcile? or
                     get_in(w.spec, ["pending_secondaries", "reconcile_pending"]) == true

                 next_spec =
                   w.spec
                   |> Map.put("starts", next_starts)
                   |> Map.put("slot_seq_hwm", next_hwm_map)
                   |> put_pending_secondaries(by_slot, reconcile_pending?)
                   |> then(fn s ->
                     if force_reconcile?,
                       do: put_earliest_next_check_at(s, iso_in(@starting_check_ms)),
                       else: s
                   end)

                 {:ok, next_spec}
               end) do
            {:ok, updated} ->
              assigned_seq =
                get_in(updated.spec, [
                  "pending_secondaries",
                  "by_slot",
                  slot,
                  "request_seqs",
                  request_id
                ]) ||
                  get_in(updated.spec, ["pending_secondaries", "by_slot", slot, "latest_seq"]) ||
                  1

              _ =
                SalixStore.StationTaskSessions.advance_slot_seq_hwm(
                  spec["group_id"],
                  spec["conversation_id"],
                  spec["device_id"],
                  slot,
                  assigned_seq
                )

              {:ok, {updated, assigned_seq}}

            other ->
              other
          end

        {:error, _} = conflict_err ->
          conflict_err
      end
    end

    case SalixStore.StationTaskSessions.with_device_lock(
           spec["group_id"],
           spec["conversation_id"],
           spec["device_id"],
           do_append
         ) do
      {:ok, {updated, assigned_seq}} -> {:ok, updated, assigned_seq}
      other -> other
    end
  end

  defp check_sandbox_slot_config_conflict(spec, slot, entry) do
    new_start = entry["start"]

    if is_map(new_start) do
      case SalixStore.StationTaskSessions.of_task(spec["group_id"], spec["conversation_id"]) do
        {:ok, rows} ->
          active_row =
            Enum.find(rows, fn r ->
              not SalixStore.StationTaskSessions.awaited?(r) and
                r.device_id == spec["device_id"] and
                (get_in(r.start || %{}, ["slot"]) || "lead") == slot
            end)

          if active_row && slot_config_conflicts?(active_row.start, new_start) do
            {:error, :slot_config_conflict}
          else
            :ok
          end

        {:error, _} = err ->
          err
      end
    else
      :ok
    end
  end

  defp slot_config_conflicts?(existing_start, new_start)
       when is_map(existing_start) and is_map(new_start) do
    Enum.any?(~w(model runtime harness profile effort), fn key ->
      old_val = existing_start[key]
      new_val = new_start[key]

      is_binary(new_val) and new_val != "" and old_val != new_val
    end)
  end

  defp slot_config_conflicts?(_, _), do: false

  defp build_slot_binding_entry(
         invitation,
         spec,
         entry,
         session,
         used_run_id,
         explicit_seq
       ) do
    slot = invitation[:slot] || entry["slot"] || "lead"

    effective_seq =
      explicit_seq ||
        entry["start_seq"] ||
        get_in(spec, ["pending_secondaries", "by_slot", slot, "latest_seq"]) ||
        get_in(spec, ["slot_seq_hwm", slot])

    start_map =
      (entry["start"] || %{})
      |> then(fn m ->
        if is_integer(effective_seq) and effective_seq > 0 do
          Map.put(m, "start_seq", effective_seq)
        else
          m
        end
      end)
      |> then(fn m ->
        if is_binary(used_run_id) and used_run_id != "" do
          Map.put(m, "connector_run_id", used_run_id)
        else
          m
        end
      end)

    Map.merge(invitation, %{
      session: session,
      agent_id: entry["agent_id"] || spec["agent_id"],
      participant_id: entry["participant_id"],
      start: start_map
    })
  end

  defp verify_slot_request_live(workload_id, slot, request_id, my_seq) do
    case Store.get(workload_id) do
      {:ok, w} ->
        starts = spec_starts(w.spec)
        slot_present? = Enum.any?(starts, &(&1["slot"] == slot))
        hwm = get_in(w.spec, ["slot_seq_hwm", slot]) || 0
        slot_meta = get_in(w.spec, ["pending_secondaries", "by_slot", slot]) || %{}

        req_present? =
          case slot_meta["request_seqs"] do
            %{} = m -> Map.has_key?(m, request_id)
            _ -> request_id in slot_request_ids(w.spec, slot)
          end

        if slot_present? and my_seq >= hwm and req_present? do
          :ok
        else
          {:error, {:stale_slot_binding, :slot_removed}}
        end

      {:error, :not_found} ->
        {:error, {:stale_slot_binding, :slot_removed}}
    end
  end

  # Single atomic Store.update for online stale cleanup when DB has NO `>= my_seq` binding:
  # - If removing `request_id` still leaves other in-flight requests, independent backoff, or
  #   `confirmed_seq >= live_seq`, drops ONLY `request_id` and returns `{:ok, :keep}`.
  # - Otherwise atomically converts the slot in-place into `pending_deactivation: true` with
  #   `reconcile_pending: true` + `next_check_at`, returning `{:ok, {:pending_deactivation, live_seq}}`.
  # - If `Store.update` itself fails, `request_id` remains untouched so periodic reconcile recovers.
  defp transition_stale_request_to_deactivation_or_drop(
         workload_id,
         slot,
         request_id,
         participant_id
       ) do
    outcome_ref = :atomics.new(1, [])
    now = now_ms()

    case Store.update(workload_id, fn w ->
           all_by_slot = get_in(w.spec, ["pending_secondaries", "by_slot"]) || %{}
           slot_meta = Map.get(all_by_slot, slot) || %{}

           reconcile_pending? =
             get_in(w.spec, ["pending_secondaries", "reconcile_pending"]) == true

           req_seqs =
             case slot_meta["request_seqs"] do
               %{} = m -> m
               _ -> Map.new(slot_request_ids(w.spec, slot), &{&1, slot_meta["latest_seq"] || 0})
             end

           remaining_seqs = Map.delete(req_seqs, request_id)

           has_backoff? =
             is_integer(slot_meta["next_retry_at_ms"]) or (slot_meta["attempts"] || 0) > 0

           cur_entry = Enum.find(spec_starts(w.spec), &(&1["slot"] == slot))
           hwm = get_in(w.spec, ["slot_seq_hwm", slot]) || 0

           live_seq =
             Enum.max([
               (is_map(cur_entry) && cur_entry["start_seq"]) || 0,
               slot_meta["latest_seq"] || 0,
               hwm
             ])

           confirmed_seq = get_in(w.spec, ["slot_confirmed_seq", slot]) || 0

           if map_size(remaining_seqs) == 0 and not has_backoff? and confirmed_seq < live_seq do
             :atomics.put(outcome_ref, 1, live_seq)

             next_slot =
               slot_meta
               |> Map.delete("request_id")
               |> Map.delete("request_ids")
               |> Map.delete("request_seqs")
               |> Map.merge(%{
                 "pending_deactivation" => true,
                 "deactivation_seq" => max(slot_meta["deactivation_seq"] || 0, live_seq),
                 "participant_id" => participant_id || slot_meta["participant_id"],
                 "attempts" => max(slot_meta["attempts"] || 0, 1),
                 "next_retry_at_ms" => now + @starting_check_ms
               })

             next_by_slot = Map.put(all_by_slot, slot, next_slot)

             {:ok,
              w.spec
              |> put_pending_secondaries(next_by_slot, true)
              |> put_earliest_next_check_at(iso_in(@starting_check_ms))}
           else
             :atomics.put(outcome_ref, 1, 0)

             has_id? =
               Map.has_key?(req_seqs, request_id) or request_id in slot_request_ids(w.spec, slot)

             if not has_id? do
               {:ok, w.spec}
             else
               next_by_slot =
                 cond do
                   map_size(remaining_seqs) > 0 ->
                     Map.put(
                       all_by_slot,
                       slot,
                       slot_meta
                       |> Map.delete("request_id")
                       |> Map.put("request_ids", Map.keys(remaining_seqs))
                       |> Map.put("request_seqs", remaining_seqs)
                     )

                   has_backoff? ->
                     Map.put(
                       all_by_slot,
                       slot,
                       slot_meta
                       |> Map.delete("request_id")
                       |> Map.delete("request_ids")
                       |> Map.delete("request_seqs")
                     )

                   true ->
                     Map.delete(all_by_slot, slot)
                 end

               {:ok, put_pending_secondaries(w.spec, next_by_slot, reconcile_pending?)}
             end
           end
         end) do
      {:ok, _} ->
        case :atomics.get(outcome_ref, 1) do
          0 -> {:ok, :keep}
          seq -> {:ok, {:pending_deactivation, seq}}
        end

      other ->
        other
    end
  end

  defp clear_slot_pending_deactivation(workload_id, slot, expected_seq) do
    Store.update(workload_id, fn w ->
      all_by_slot = get_in(w.spec, ["pending_secondaries", "by_slot"]) || %{}
      slot_meta = Map.get(all_by_slot, slot) || %{}
      cur_entry = Enum.find(spec_starts(w.spec), &(&1["slot"] == slot))
      hwm = get_in(w.spec, ["slot_seq_hwm", slot]) || 0

      live_seq =
        Enum.max([
          (is_map(cur_entry) && cur_entry["start_seq"]) || 0,
          slot_meta["latest_seq"] || 0,
          hwm
        ])

      if live_seq <= expected_seq and slot_meta["pending_deactivation"] == true do
        reconcile_pending? =
          get_in(w.spec, ["pending_secondaries", "reconcile_pending"]) == true

        by_slot = Map.delete(all_by_slot, slot)

        {:ok,
         put_pending_secondaries(w.spec, by_slot, reconcile_pending? and map_size(by_slot) > 0)}
      else
        {:ok, w.spec}
      end
    end)
  end

  # After guarded deactivation confirms `:ok`: removes the orphaned `spec["starts"]` entry
  # ONLY if `live_seq <= expected_seq` (preserving any newer concurrent generation C(3) and `slot_seq_hwm`).
  defp cleanup_unconfirmed_stale_slot(workload_id, slot, expected_seq) do
    cleaned_ref = :atomics.new(1, [])

    case Store.update(workload_id, fn w ->
           all_by_slot = get_in(w.spec, ["pending_secondaries", "by_slot"]) || %{}
           slot_meta = Map.get(all_by_slot, slot) || %{}

           reconcile_pending? =
             get_in(w.spec, ["pending_secondaries", "reconcile_pending"]) == true

           req_seqs =
             case slot_meta["request_seqs"] do
               %{} = m -> m
               _ -> Map.new(slot_request_ids(w.spec, slot), &{&1, slot_meta["latest_seq"] || 0})
             end

           cur_entry = Enum.find(spec_starts(w.spec), &(&1["slot"] == slot))
           hwm = get_in(w.spec, ["slot_seq_hwm", slot]) || 0

           live_seq =
             Enum.max([
               (is_map(cur_entry) && cur_entry["start_seq"]) || 0,
               slot_meta["latest_seq"] || 0,
               hwm
             ])

           confirmed_seq = get_in(w.spec, ["slot_confirmed_seq", slot]) || 0

           if live_seq <= expected_seq and map_size(req_seqs) == 0 and confirmed_seq < live_seq do
             :atomics.put(cleaned_ref, 1, 1)
             kept = Enum.reject(spec_starts(w.spec), &(&1["slot"] == slot))
             by_slot = Map.delete(all_by_slot, slot)

             {:ok,
              w.spec
              |> Map.put("starts", kept)
              |> put_pending_secondaries(
                by_slot,
                reconcile_pending? and map_size(by_slot) > 0
              )}
           else
             {:ok, w.spec}
           end
         end) do
      {:ok, _} ->
        if :atomics.get(cleaned_ref, 1) == 1, do: {:ok, :cleaned}, else: {:ok, :kept}

      other ->
        other
    end
  end

  # Drops ONLY `request_id` from `pending_secondaries["by_slot"][slot]` without touching
  # `spec["starts"]`, `slot_confirmed_seq`, or independent background backoff state.
  # No-op if `request_id` is not present.
  @doc false
  def drop_stale_request_id(workload_id, slot, request_id) do
    Store.update(workload_id, fn w ->
      all_by_slot = get_in(w.spec, ["pending_secondaries", "by_slot"]) || %{}
      slot_meta = Map.get(all_by_slot, slot)
      reconcile_pending? = get_in(w.spec, ["pending_secondaries", "reconcile_pending"]) == true

      if is_map(slot_meta) do
        req_seqs =
          case slot_meta["request_seqs"] do
            %{} = m -> m
            _ -> Map.new(slot_request_ids(w.spec, slot), &{&1, slot_meta["latest_seq"] || 0})
          end

        has_id? =
          Map.has_key?(req_seqs, request_id) or request_id in slot_request_ids(w.spec, slot)

        if not has_id? do
          {:ok, w.spec}
        else
          remaining_seqs = Map.delete(req_seqs, request_id)

          has_backoff? =
            is_integer(slot_meta["next_retry_at_ms"]) or (slot_meta["attempts"] || 0) > 0

          by_slot =
            cond do
              map_size(remaining_seqs) > 0 ->
                Map.put(
                  all_by_slot,
                  slot,
                  slot_meta
                  |> Map.delete("request_id")
                  |> Map.put("request_ids", Map.keys(remaining_seqs))
                  |> Map.put("request_seqs", remaining_seqs)
                )

              has_backoff? ->
                Map.put(
                  all_by_slot,
                  slot,
                  slot_meta
                  |> Map.delete("request_id")
                  |> Map.delete("request_ids")
                  |> Map.delete("request_seqs")
                )

              true ->
                Map.delete(all_by_slot, slot)
            end

          {:ok, put_pending_secondaries(w.spec, by_slot, reconcile_pending?)}
        end
      else
        {:ok, w.spec}
      end
    end)
  end

  # Monotonic `start_seq`-fenced confirmation:
  # - If `my_seq < live_seq` OR the slot is no longer alive (`cur_idx == nil` and `request_id`
  #   not in `req_seqs`), NEVER overwrite or resurrect `spec["starts"]` and NEVER clear newer
  #   requests (`seq > my_seq`); only drop A's `request_id` if present.
  # - Otherwise, ensure `starts[slot]["start_seq"] == my_seq` and clear `seq <= my_seq`.
  @doc false
  def confirm_start_entry(workload_id, slot, entry, request_id, my_seq) do
    Store.update(workload_id, fn w ->
      existing = spec_starts(w.spec)
      cur_idx = Enum.find_index(existing, &(&1["slot"] == slot))
      cur_entry = if cur_idx, do: Enum.at(existing, cur_idx), else: nil
      all_by_slot = get_in(w.spec, ["pending_secondaries", "by_slot"]) || %{}
      slot_meta = Map.get(all_by_slot, slot) || %{}
      reconcile_pending? = get_in(w.spec, ["pending_secondaries", "reconcile_pending"]) == true
      hwm = get_in(w.spec, ["slot_seq_hwm", slot]) || 0

      live_seq =
        Enum.max([
          (is_map(cur_entry) && cur_entry["start_seq"]) || 0,
          slot_meta["latest_seq"] || 0,
          hwm
        ])

      req_seqs =
        case slot_meta["request_seqs"] do
          %{} = m -> m
          _ -> Map.new(slot_request_ids(w.spec, slot), &{&1, slot_meta["latest_seq"] || 0})
        end

      still_alive? = cur_idx != nil or Map.has_key?(req_seqs, request_id)

      if my_seq < live_seq or not still_alive? do
        has_id? =
          Map.has_key?(req_seqs, request_id) or request_id in slot_request_ids(w.spec, slot)

        if not has_id? do
          {:ok, w.spec}
        else
          remaining_seqs = Map.delete(req_seqs, request_id)

          has_backoff? =
            is_integer(slot_meta["next_retry_at_ms"]) or (slot_meta["attempts"] || 0) > 0

          by_slot =
            cond do
              map_size(remaining_seqs) > 0 ->
                Map.put(
                  all_by_slot,
                  slot,
                  slot_meta
                  |> Map.delete("request_id")
                  |> Map.put("request_ids", Map.keys(remaining_seqs))
                  |> Map.put("request_seqs", remaining_seqs)
                )

              has_backoff? ->
                Map.put(
                  all_by_slot,
                  slot,
                  slot_meta
                  |> Map.delete("request_id")
                  |> Map.delete("request_ids")
                  |> Map.delete("request_seqs")
                )

              true ->
                Map.delete(all_by_slot, slot)
            end

          {:ok, put_pending_secondaries(w.spec, by_slot, reconcile_pending?)}
        end
      else
        next_starts =
          case cur_idx do
            nil ->
              existing ++ [Map.put(entry, "start_seq", my_seq)]

            idx ->
              List.replace_at(existing, idx, Map.put(cur_entry, "start_seq", my_seq))
          end

        remaining_seqs =
          req_seqs
          |> Enum.reject(fn {id, seq} -> id == request_id or seq <= my_seq end)
          |> Map.new()

        by_slot =
          if map_size(remaining_seqs) == 0 do
            Map.delete(all_by_slot, slot)
          else
            Map.put(
              all_by_slot,
              slot,
              slot_meta
              |> Map.delete("request_id")
              |> Map.put("request_ids", Map.keys(remaining_seqs))
              |> Map.put("request_seqs", remaining_seqs)
            )
          end

        prev_confirmed = get_in(w.spec, ["slot_confirmed_seq", slot]) || 0

        next_confirmed_map =
          Map.put(w.spec["slot_confirmed_seq"] || %{}, slot, max(prev_confirmed, my_seq))

        {:ok,
         w.spec
         |> Map.put("starts", next_starts)
         |> Map.put("slot_confirmed_seq", next_confirmed_map)
         |> put_pending_secondaries(by_slot, reconcile_pending?)}
      end
    end)
  end

  # Monotonic `start_seq`-fenced removal: removes ONLY `expected_request_id`; when no
  # remaining in-flight requests exist AND `slot_confirmed_seq[slot] < live_seq` (no
  # request in this generation ever confirmed, and caller verified no DB binding), removes
  # `slot` from `spec["starts"]` while preserving `slot_seq_hwm[slot]`.
  defp remove_start_entry(workload_id, slot, expected_request_id, _my_seq) do
    Store.update(workload_id, fn w ->
      all_by_slot = get_in(w.spec, ["pending_secondaries", "by_slot"]) || %{}
      slot_meta = Map.get(all_by_slot, slot)
      reconcile_pending? = get_in(w.spec, ["pending_secondaries", "reconcile_pending"]) == true

      ids = slot_request_ids(w.spec, slot)

      if expected_request_id in ids do
        req_seqs =
          case slot_meta["request_seqs"] do
            %{} = m -> m
            _ -> Map.new(ids, &{&1, slot_meta["latest_seq"] || 0})
          end

        remaining_seqs = Map.delete(req_seqs, expected_request_id)
        remaining_ids = Map.keys(remaining_seqs)
        cur_entry = Enum.find(spec_starts(w.spec), &(&1["slot"] == slot))

        live_seq =
          max((is_map(cur_entry) && cur_entry["start_seq"]) || 0, slot_meta["latest_seq"] || 0)

        confirmed_seq = get_in(w.spec, ["slot_confirmed_seq", slot]) || 0

        if map_size(remaining_seqs) == 0 and confirmed_seq < live_seq do
          kept = Enum.reject(spec_starts(w.spec), &(&1["slot"] == slot))
          by_slot = Map.delete(all_by_slot, slot)

          {:ok,
           w.spec
           |> Map.put("starts", kept)
           |> put_pending_secondaries(by_slot, reconcile_pending?)}
        else
          by_slot =
            if map_size(remaining_seqs) == 0 do
              Map.delete(all_by_slot, slot)
            else
              Map.put(
                all_by_slot,
                slot,
                slot_meta
                |> Map.delete("request_id")
                |> Map.put("request_ids", remaining_ids)
                |> Map.put("request_seqs", remaining_seqs)
              )
            end

          {:ok, put_pending_secondaries(w.spec, by_slot, reconcile_pending?)}
        end
      else
        {:ok, w.spec}
      end
    end)
  end

  @doc """
  Hydrates committed `participant_id`s onto reserved sandbox start specs after
  `ConversationServer.create_task` commits, so when the sandbox connects and
  reconciles invites every slot carries its exact `participant_id`.
  """
  def hydrate_participant_ids(tenant, conversation, pid_by_slot)
      when is_binary(tenant) and is_binary(conversation) and is_map(pid_by_slot) do
    if map_size(pid_by_slot) == 0 do
      :ok
    else
      case Store.get_by_conversation(tenant, conversation) do
        {:ok, workload} ->
          _ =
            Store.update(workload.id, fn w ->
              spec = w.spec

              updated_starts =
                spec_starts(spec)
                |> Enum.map(fn entry ->
                  slot = entry["slot"] || "lead"

                  case Map.get(pid_by_slot, slot) do
                    pid when is_binary(pid) and pid != "" ->
                      entry
                      |> Map.put("participant_id", pid)
                      |> Map.update(
                        "start",
                        %{"participant_id" => pid},
                        &Map.put(&1, "participant_id", pid)
                      )

                    _ ->
                      entry
                  end
                end)

              updated_spec = Map.put(spec, "starts", updated_starts)

              updated_spec =
                case {Map.get(pid_by_slot, "lead"), updated_spec["start"]} do
                  {pid, %{} = lead_start} when is_binary(pid) and pid != "" ->
                    Map.put(updated_spec, "start", Map.put(lead_start, "participant_id", pid))

                  _ ->
                    updated_spec
                end

              {:ok, updated_spec}
            end)

          :ok

        {:error, :not_found} ->
          :ok
      end
    end
  end

  @doc """
  The Task has work for its sandbox's station, which is not connected: a
  `stopped`, `lost`, `failed` or `ended` sandbox is replaced by a new one,
  unless the Task ended. A sandbox on its way is left to come. What Salix
  itself last said in the Task about the sandbox (`StationTasks.notice/5`) is
  for the person, not work for the station: it wakes nothing, or a start that
  failed would be started again by the notice of its failure, without end. A
  person's or the Router's Message after it does. A Message sent while the
  sandbox starts is left to that start: if it fails, its notice asks for a new
  reply.

  A Message in a Task that ended (completed, cancelled, failed or archived)
  wakes nothing: an ended Task's Worker is not asked again. The Router takes
  part in the Task and answers such a Message; its own Message after the end,
  its report, is no work for the Worker. When the work continues, the Router
  makes the Task active again, and that status wakes the sandbox from its
  disk (`task_status/3`, `check/1`). A Task that ends after the wake read its
  status is caught by the next generation's own check (`start_next/3`).
  """
  def wake(group, device) do
    with {:ok, tenant} <- tenant_of(group),
         {:ok, workload} <- Store.get_by_device(tenant, device),
         true <- workload.spec["state"] in @wakeable,
         false <- task_ended?(group, workload.spec["conversation_id"]),
         true <- work?(group, workload.spec["conversation_id"]) do
      start_next(tenant, group, workload)
    end

    :ok
  end

  # The next generation of a Workload whose Task has work for it, once its
  # Workspace can pay for it. It is made with `end` set: its first check reads
  # the Task's status once more (`check/1`), so a Task that ended since the
  # wake or reopen read it, during the fee decision say, ends the generation
  # before its sandbox is made, instead of stopping that sandbox as it is made.
  defp start_next(tenant, group, %{spec: spec} = workload) do
    case authorize(tenant, group, "sandbox_wake", "system", spec["size"]) do
      :ok ->
        case Store.advance(workload.id, %{
               "end" => true,
               "reopened" => nil,
               "failed_start_retries" => nil,
               "next_check_at" => iso_in(0)
             }) do
          {:ok, _} ->
            poke()

          {:error, reason} ->
            Logger.warning("a coding sandbox was not replaced: #{inspect(reason)}")
        end

      {:error, {:billing_unavailable, decision}} ->
        # The sandbox stays as it is; the Task is told once per refusal
        # reason and generation, and a reply once credits are there wakes it.
        reason = SalixAgent.BillingAvailability.error(decision)

        StationTasks.notice(
          group,
          spec["conversation_id"],
          spec["agent_id"],
          "billing:#{workload.generation}:#{reason["reason"]}",
          "The sandbox cannot start: #{reason["message"]} Reply to try again."
        )

      {:error, reason} ->
        # The fee control itself did not answer (a store timeout, say): the
        # sandbox stays as it is, and the Task is told once per generation.
        Logger.warning("a coding sandbox's billing was not decided: #{inspect(reason)}")

        StationTasks.notice(
          group,
          spec["conversation_id"],
          spec["agent_id"],
          "billing-error:#{workload.generation}",
          "The sandbox was not started: billing is temporarily unavailable. Reply later to try again."
        )
    end
  end

  # Whether the Task's last Message is work for its sandbox: any but Salix's
  # own sandbox notice or an event, such as the Task's status published to its
  # provider. A Task with no Message, or one whose Messages cannot be read now,
  # is woken as before.
  defp work?(group, conversation) do
    case StationTasks.last_message(group, conversation) do
      {:ok, %{"metadata" => %{"kind" => "sandbox_notice"}}} -> false
      {:ok, %{"kind" => "app_event"}} -> false
      _ -> true
    end
  end

  # Whether the Task ended. A status that cannot be read now holds no wake
  # back: the next generation's first check reads it again before its sandbox
  # is made (`start_next/3`).
  defp task_ended?(group, conversation) do
    match?(
      {:ok, status} when status in @ended,
      StationTasks.current_status(group, conversation)
    )
  end

  @doc """
  Authorizes a sandbox start for Group `group` against the Workspace's
  billing account, as a Group Cloud VM's start is: the fee control's
  `resource_kind` vm, provider `l4es`, sku `sandbox-<size>` (`config
  :salix_web, :vm_authorization_mod`). `entrypoint` and `actor_type` name
  what asks (`sandbox_place` for a user's Task, `sandbox_wake` for the
  system); `size` is the sandbox's (its spec's, for one that exists; the
  deployment's for one about to be reserved), so the sku authorized is the
  one metered. `:ok`, `{:error, {:billing_unavailable, decision}}` (the fee
  control refused), or `{:error, reason}` (it did not answer); a Group with
  no billing account is `:ok` and never charged.

  The product may refuse a Workspace managed sandboxes before any fee
  decision (`config :salix_web, :sandbox_admission`, a module with
  `admitted?/2`): that is `{:error, {:billing_unavailable, %{reason:
  "sandbox_restricted"}}}`, a denial that asking again does not change. The
  Workspace's own stations are not asked about.
  """
  def authorize(tenant, group, entrypoint, actor_type, size \\ nil) do
    if admitted?(tenant, group),
      do: authorize_billing(tenant, group, entrypoint, actor_type, size),
      else: {:error, {:billing_unavailable, %{reason: "sandbox_restricted"}}}
  end

  defp admitted?(tenant, group) do
    case SystemsRuntime.get_env(:salix_web, :sandbox_admission) do
      nil -> true
      mod -> mod.admitted?(tenant, group)
    end
  end

  defp authorize_billing(tenant, group, entrypoint, actor_type, size) do
    owner =
      case SalixIM.GroupDirectory.get_group(group) do
        {:ok, record} -> record["billing_owner"] || %{}
        _ -> %{}
      end

    case owner["billing_account_id"] do
      account when is_binary(account) and account != "" ->
        vm_authorizer().authorize_vm(%{
          billing_owner: owner,
          group_id: group,
          tenant_id: tenant,
          action: :start,
          entrypoint: entrypoint,
          actor_type: actor_type,
          provider: "l4es",
          sku: "sandbox-" <> (size || L4ES.config()[:size] || "default"),
          source_key: "vm:l4es:#{account}:#{entrypoint}"
        })

      _none ->
        :ok
    end
  end

  defp vm_authorizer,
    do:
      SystemsRuntime.get_env(
        :salix_web,
        :vm_authorization_mod,
        SalixWeb.VMAuthorization.Noop
      )

  @doc """
  A Message was added to a Task whose station never took it: a coding Task
  whose sandbox failed or stopped before its station was invited gets a new
  sandbox. Any other Task is left alone.
  """
  def appended(group, conversation) do
    with {:ok, tenant} <- tenant_of(group),
         {:ok, workload} <- Store.get_by_conversation(tenant, conversation) do
      wake(group, workload.spec["device_id"])
    end

    :ok
  end

  @doc """
  A coding Task's status changed: an ended or archived Task gives up its
  sandbox. It is called from the Task's actor, so it only marks the sandbox;
  the check reads the Task's status now before ending it (`check/1`).
  """
  def task_status(group, conversation, status) when status in @ended do
    with {:ok, tenant} <- tenant_of(group),
         {:ok, workload} <- Store.get_by_conversation(tenant, conversation),
         false <- workload.spec["state"] in ~w(ended) do
      Store.update(workload.id, fn w ->
        {:ok, Map.merge(w.spec, %{"end" => true, "next_check_at" => iso_in(0)})}
      end)

      poke()
    end

    :ok
  end

  # In review: the sandbox is checked now, and stops once its Session is idle.
  def task_status(group, conversation, "ready_for_review") do
    with {:ok, tenant} <- tenant_of(group),
         {:ok, workload} <- Store.get_by_conversation(tenant, conversation),
         "ready" <- workload.spec["state"] do
      Store.update(workload.id, fn w -> {:ok, Map.put(w.spec, "next_check_at", iso_in(0))} end)
      poke()
    end

    :ok
  end

  # Made active again: the check decides, with the Task's Messages read and
  # the old run's stop known. Read here, the actor would wait for them.
  def task_status(group, conversation, "active") do
    with {:ok, tenant} <- tenant_of(group),
         {:ok, workload} <- Store.get_by_conversation(tenant, conversation),
         true <- workload.spec["state"] in @wakeable do
      Store.update(workload.id, fn w ->
        {:ok, Map.merge(w.spec, %{"reopened" => true, "next_check_at" => iso_in(0)})}
      end)

      poke()
    end

    :ok
  end

  def task_status(_group, _conversation, _status), do: :ok

  # --- The checks

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule(@pass_ms)
    {:ok, %{fleet_metrics_at: nil}}
  end

  @impl true
  def handle_info(:pass, state) do
    check_due()
    schedule(@pass_ms)
    {:noreply, fleet_metrics(state)}
  end

  def handle_info(:poke, state) do
    check_due()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(ms), do: SystemsClock.send_after(self(), :pass, ms)

  defp fleet_metrics(state) do
    now = SystemsClock.monotonic_time(:millisecond)

    if is_nil(state.fleet_metrics_at) or now - state.fleet_metrics_at >= @fleet_metrics_every_ms do
      _ = __MODULE__.FleetMetrics.emit()
      %{state | fleet_metrics_at: now}
    else
      state
    end
  end

  # Checks the due Workloads now, on this node, instead of at the next pass.
  defp poke do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :poke)
    end
  end

  @doc "Checks the Workloads due now: at most #{@page}."
  def check_due do
    case Store.claim_due(@page, @lease_ms) do
      {:ok, workloads} -> Enum.each(workloads, &(&1 |> sweep() |> check()))
      {:error, reason} -> Logger.warning("coding sandboxes not checked: #{inspect(reason)}")
    end
  end

  @doc false
  # A Task made active again. A Task no longer active, or whose Worker has
  # answered, wakes nothing, and what cannot be read is read again: a start is
  # billed, and an unknown answer is no reason for one. `wake/2` keeps its own
  # billing and generation fences; until the old run has stopped it cannot
  # replace it.
  def check(%{spec: %{"reopened" => true, "state" => state} = spec} = workload)
      when state in @wakeable do
    with [] <- leftover(spec),
         {:ok, "active"} <- StationTasks.current_status(spec["group_id"], spec["conversation_id"]),
         {:ok, true} <-
           StationTasks.worker_owes_answer?(
             spec["group_id"],
             spec["conversation_id"],
             spec["agent_id"]
           ) do
      # The status published for the reopen may be the Task's last Message, so
      # this is not `wake/2`'s decision.
      with {:ok, tenant} <- tenant_of(spec["group_id"]),
           do: start_next(tenant, spec["group_id"], workload)

      # The reopen is answered, started or not (a refusal is told once); the
      # next check reads the status again, as a start's own does.
      Store.update(workload.id, fn w ->
        {:ok,
         w.spec
         |> Map.delete("reopened")
         |> Map.merge(%{"end" => true, "next_check_at" => iso_in(0)})}
      end)

      :ok
    else
      [_ | _] ->
        next(workload, @leftover_retry_ms)

      {:ok, _status_or_answered} ->
        reopen_decided(workload)

      {:error, :not_found} ->
        reopen_decided(workload)

      {:error, reason} ->
        Logger.warning("a reopened Task was not read: #{inspect(reason)}")
        next(workload, @ready_check_ms)
    end
  end

  # A status is also published again on recovery, after a message may have
  # reopened the Task, and a next generation is made with `end` set
  # (`start_next/3`): the Task's status now decides. A Task that goes on is
  # checked on in the same claim, so a start loses no time to it. A status
  # that cannot be read ends a sandbox that exists, or a generation that
  # stopped, as before. A starting generation with no sandbox yet reads it
  # again instead, so a passing fault loses no wake, within the start budget:
  # after it, the start fails and the Task is told. A Task that is gone ends it.
  def check(%{spec: %{"end" => true, "state" => "ended"}} = workload), do: clear(workload)

  def check(%{spec: %{"end" => true} = spec} = workload) do
    starting? = spec["state"] == "starting" and is_nil(spec["sandbox"])

    case StationTasks.current_status(spec["group_id"], spec["conversation_id"]) do
      {:ok, status} when status not in @ended ->
        case update(workload, &Map.delete(&1, "end")) do
          {:ok, workload} -> check(workload)
          :error -> :ok
        end

      {:error, reason} when reason != :not_found and starting? ->
        if elapsed_ms(spec["state_at"]) > @start_budget_ms do
          stop(workload, "failed", "the Task's status was not read within 5 minutes")
        else
          Logger.warning("a woken sandbox's Task was not read: #{inspect(reason)}")
          next(workload, @starting_check_ms)
        end

      _ended_or_gone ->
        stop(workload, "ended", nil)
    end
  end

  def check(%{spec: %{"state" => "starting"} = spec} = workload) do
    cond do
      elapsed_ms(spec["remade_at"] || spec["state_at"]) > @start_budget_ms ->
        stop(
          workload,
          "failed",
          "the sandbox did not start within 5 minutes" <>
            if(spec["remade_at"], do: " of being made again", else: "") <> last_reason(spec)
        )

      # Not made yet, or its create was not answered (`created` false).
      is_nil(spec["sandbox"]) or spec["created"] == false ->
        create_sandbox(workload)

      true ->
        case L4ES.get(spec["group_id"], spec["sandbox"]) do
          {:ok, %{"state" => "failed"} = s} ->
            failed_start(workload, s)

          {:ok, %{"state" => state} = s} when state in @gone ->
            stop(workload, "failed", "the sandbox stopped: #{s["failure"] || state}")

          {:ok, %{"state" => "pending"} = s} ->
            if s["data_status"] == "retained" and
                 elapsed_ms(spec["created_at"]) >= @pinned_remake_ms,
               do: unplaced(workload),
               else: workload |> rotate_github() |> waiting(waiting_for(s))

          {:ok, %{"state" => _starting_or_running} = s} ->
            workload |> rotate_github() |> waiting(waiting_for(s))

          _ ->
            workload |> rotate_github() |> next(@starting_check_ms)
        end
    end
  end

  def check(%{spec: %{"state" => "ready", "invite_outcome" => "unknown"}} = workload),
    do: invite(workload)

  def check(%{spec: %{"state" => "ready"} = spec} = workload) do
    case L4ES.get(spec["group_id"], spec["sandbox"]) do
      {:ok, %{"state" => state}} when state in @gone ->
        stop(workload, "lost", "the sandbox ended outside Comma (#{state})")

      {:error, :not_found} ->
        stop(workload, "lost", "the sandbox ended outside Comma")

      _ ->
        workload |> rotate_github() |> station_check()
    end
  end

  # The state is written first, so a Message from now on wakes the sandbox.
  # The notice stays due on the Workload until it is written.
  def check(%{spec: %{"state" => "lost", "lost_notice" => true} = spec} = workload) do
    with {:ok, "active"} <- StationTasks.current_status(spec["group_id"], spec["conversation_id"]),
         {:ok, _message} <- notice_lost(workload) do
      told_lost(workload)
    else
      # Nobody waits in a Task in review or ended, and there is none to tell
      # in one that is gone or has no Worker.
      {:ok, _status} ->
        told_lost(workload)

      {:error, reason} when reason in [:not_found, :not_taking_part] ->
        told_lost(workload)

      {:error, reason} ->
        Logger.warning("a lost coding sandbox's notice was not written: #{inspect(reason)}")
        next(workload, @lost_notice_retry_ms)
    end
  end

  def check(workload), do: clear(workload)

  defp notice_lost(%{spec: spec} = workload) do
    StationTasks.notice(
      spec["group_id"],
      spec["conversation_id"],
      spec["agent_id"],
      "lost:#{workload.generation}",
      "The sandbox stopped unexpectedly, and this Task has not completed. Its last work may " <>
        "have finished, or not: nothing is run again on its own, so check what is already " <>
        "done before asking for it again. Reply to continue from the sandbox's disk."
    )
  end

  defp told_lost(workload) do
    update(workload, &Map.delete(&1, "lost_notice"))
    clear(workload)
  end

  # A start L4ES failed, such as a node whose download of the system image
  # broke off, is made again as a new sandbox, at most `@failed_start_retries`
  # times and within the start budget, which keeps running from the first
  # start. Only one whose disk cannot hold the Task's work: a disk made in
  # this generation (`disk_generation`: a new sandbox, or one made again under
  # a new name), which has not run yet, since a run that connects ends the
  # start; or one L4ES reports `missing`. L4ES's `data_status` alone does not
  # tell: a node's reboot resets it to `unknown` while the disk is still
  # there. Any other fails as before, keeping its disk, and a reply starts it
  # again from that disk. A Workload made before `disk_generation` was
  # recorded has none, and is never remade here.
  defp failed_start(%{spec: spec} = workload, %{"state" => state} = s) do
    why = s["failure"] || state
    retries = spec["failed_start_retries"] || 0

    no_work_on_disk? =
      spec["disk_generation"] == workload.generation or s["data_status"] == "missing"

    if no_work_on_disk? and retries < @failed_start_retries do
      Logger.warning(
        "a coding sandbox L4ES failed to start is made again: task=#{spec["conversation_id"]} " <>
          "sandbox=#{spec["sandbox"]} #{why}"
      )

      case update(
             workload,
             &Map.merge(&1, %{"created" => false, "failed_start_retries" => retries + 1})
           ) do
        {:ok, workload} -> remake(workload, "L4ES failed to start it: #{why}")
        :error -> :ok
      end
    else
      stop(workload, "failed", "the sandbox stopped: #{why}")
    end
  end

  # A sandbox started again from its disk, still pending with its data
  # `retained` on a node, waits for that node. L4ES moves it to another node
  # 120 s after the start when its node is dead or full, but holds it 900 s
  # for a draining node (`SBX_DRAINING_FAILOVER_GRACE_S`), longer than the
  # start budget: the start would fail at 5 minutes, and a reply would start
  # the same wait. The disk is a cache (docs/compute-devices.md "Coding
  # sandboxes"): the sandbox is deleted with it and made again, as a new
  # sandbox any node takes (`remake/2`). Once the delete is accepted, the
  # Task is told, and the start budget runs again from then (`remade_at`):
  # the new sandbox is made as any new one, so this happens once per
  # generation, and the metered start still counts from the wake. The
  # draining node destroys the old one; until it confirms, the name is still
  # stopping and the create is retried. A new sandbox (data `unknown`) or one
  # moved off its disk (`missing`) waits for capacity within the budget.
  defp unplaced(%{spec: spec} = workload) do
    why = "no node took it within #{div(@pinned_remake_ms, 1000)} s"

    Logger.warning(
      "a woken coding sandbox is made again on a new disk: task=#{spec["conversation_id"]} " <>
        "sandbox=#{spec["sandbox"]} #{why}"
    )

    case update(workload, &Map.put(&1, "created", false)) do
      {:ok, workload} ->
        remake(workload, why, fn workload ->
          tell_remade(workload)
          %{"remade_at" => DateTime.to_iso8601(SystemsClock.utc_now())}
        end)

      :error ->
        :ok
    end
  end

  # A notice that is not written is not written again: the Task's next turn
  # finds a fresh checkout, and the remake is in the log.
  defp tell_remade(%{spec: spec} = workload) do
    case StationTasks.notice(
           spec["group_id"],
           spec["conversation_id"],
           spec["agent_id"],
           "remade:#{workload.generation}",
           "The sandbox is made again on a new disk: the node that held its disk did not " <>
             "take it. Local files on the old disk, including uncommitted changes and " <>
             "unpushed commits, are gone."
         ) do
      {:error, reason} ->
        Logger.warning("a remade coding sandbox's notice was not written: #{inspect(reason)}")

      _written_or_nobody ->
        :ok
    end
  end

  defp create_sandbox(%{spec: spec} = workload) do
    name = spec["disk"] || sandbox_name(spec["conversation_id"], workload.generation)
    coding? = is_map(spec["repo"])

    # What the create needs, each from another service, asked for together;
    # the members' sync holds nothing back. Only a coding Task asks GitHub.
    [identity, image, _members, grant] =
      together([
        fn -> if coding?, do: github_identity(spec), else: {:ok, nil} end,
        fn -> L4ES.ensure_image(spec["group_id"]) end,
        fn -> sync_members(spec) end,
        fn -> if coding?, do: initial_github_grant(spec, name), else: {:ok, nil} end
      ])

    with {:ok, identity} <- identity,
         {:ok, image} <- image,
         {:ok, grant} <- grant,
         {:ok, credential} <- WorkloadCredential.issue_connect(workload.id, workload.generation) do
      # The Task's sandbox, the same for each generation: L4ES starts it again
      # from its disk. It is named after the generation it was first made in.
      # Its name is kept before it is asked for: a create that is never
      # answered (Salix stopped meanwhile) is asked again, or its sandbox
      # stopped, by name.
      {github, user} = identity || {nil, nil}
      # Only coding Tasks with a GitHub repo commit under a git author; repo-less
      # sandboxes (including member/guest-triggered collaboration sandboxes) never
      # receive the host's personal email in environment variables.
      author = if coding?, do: git_author(spec, user), else: nil

      recorded =
        %{
          "sandbox" => name,
          "disk" => name,
          "created" => false,
          "github_expires_at" => github && github.expires_at
        }
        |> then(
          &if(is_nil(spec["disk"]),
            do: Map.put(&1, "disk_generation", workload.generation),
            else: &1
          )
        )

      update(workload, &Map.merge(&1, recorded))
      workload = %{workload | spec: Map.merge(spec, recorded)}

      env =
        case author do
          %{name: name, email: email} ->
            %{"COMMA_GIT_USER_NAME" => name, "COMMA_GIT_USER_EMAIL" => email}

          nil ->
            %{}
        end

      case L4ES.create(spec["group_id"], name,
             env: Map.put(env, "SALIX_SERVER", SalixEnv.Ports.PublicURL.connector_server_url()),
             secrets: %{"SALIX_WORKLOAD_CREDENTIAL" => credential},
             github: grant,
             github_token: github && github.token,
             metadata: %{"task" => spec["conversation_id"], "workload" => workload.id},
             image: image,
             size: spec["size"]
           ) do
        {:ok, _sandbox} ->
          created(workload)

        {:error, {:refused, 409, why}} ->
          Logger.warning("L4ES refused the coding sandbox #{name}: #{why || "no reason given"}")
          SalixWeb.L4ESRecent.forget(spec["group_id"])
          remake(workload, why)

        # Its image was removed in L4ES since this node remembered it: the
        # next create adds it again.
        {:error, {:image_gone, why}} ->
          SalixWeb.L4ESRecent.forget(spec["group_id"])
          retry(workload, why)

        # Perhaps for what this node remembered of the workspace: the next
        # create asks again.
        {:error, {:refused, _status, why}} ->
          SalixWeb.L4ESRecent.forget(spec["group_id"])
          stop(workload, "failed", "L4ES refused the sandbox: #{why || "no reason given"}")

        {:error, {:quota, why}} ->
          retry(workload, why)

        {:error, reason} ->
          retry(workload, describe(reason))
      end
    else
      {:error, reason} when reason in [:github_not_connected, :github_reauthorization_required] ->
        stop(workload, "failed", describe(reason))

      {:error, reason} ->
        retry(workload, describe(reason))
    end
  end

  # A sandbox L4ES cannot start as asked (another disk size, a running one
  # asked to change) is deleted, disk and all, and made again at the next
  # check. One still stopping (a Message just after an idle stop) is waited
  # for instead, so its disk is kept. `deleted` runs once L4ES accepted the
  # delete, and what it returns is recorded on the Workload with the retry.
  #
  # The new sandbox takes a new name (`remade_name/1`). L4ES keeps a deleted
  # sandbox's name until its node confirms the delete, and refuses a create
  # of that name meanwhile ("still stopping"): a node that is down or being
  # reimaged confirms nothing for hours, and the start would wait on it.
  defp remake(%{spec: %{"sandbox" => name} = spec} = workload, why, deleted \\ fn _ -> %{} end) do
    case L4ES.get(spec["group_id"], name) do
      {:ok, %{"state" => state}} when state in ~w(stopping deleting) ->
        retry(workload, "the sandbox is still stopping")

      {:error, reason} when reason != :not_found ->
        retry(workload, describe(reason))

      _found_or_gone ->
        case L4ES.delete(spec["group_id"], name) do
          :ok ->
            retry(
              workload,
              "the sandbox is made again: #{why || "L4ES refused it"}",
              Map.merge(deleted.(workload), remade_name(workload))
            )

          {:error, reason} ->
            retry(workload, describe(reason))
        end
    end
  end

  # The name of a sandbox made again in place of a deleted one: the
  # generation's name with the count of remakes so far, which no earlier
  # sandbox of the Task had.
  defp remade_name(%{spec: spec} = workload) do
    remakes = (spec["remakes"] || 0) + 1

    %{
      "disk" => "#{sandbox_name(spec["conversation_id"], workload.generation)}-r#{remakes}",
      "disk_generation" => workload.generation,
      "remakes" => remakes
    }
  end

  @doc """
  The Group that holds the connected GitHub OAuth account for `group_id`:
  an isolated Collaborative Task Group (`purpose: "collaboration"`) resolves
  its host Workspace's home Group (`billing_owner.home_group_id`); any other
  Group resolves to itself.
  """
  def github_group_id(group_id) when is_binary(group_id) do
    case Salix.Control.Groups.get(group_id) do
      {:ok, %{"purpose" => "collaboration", "billing_owner" => %{"home_group_id" => home}}}
      when is_binary(home) and home != "" ->
        home

      _ ->
        group_id
    end
  end

  def github_group_id(group_id), do: group_id

  defp github_identity(spec) do
    with {:ok, %{token: token} = github} <-
           github().token(spec["tenant_id"], github_group_id(spec["group_id"])),
         {:ok, user} <- github().user(token),
         do: {:ok, {github, user}}
  end

  # Omit github for an existing identity: L4ES preserves its current ACL,
  # including a removed grant. Replaying the initial grant would undo edits.
  defp initial_github_grant(spec, name) do
    case L4ES.get(spec["group_id"], name) do
      {:ok, _} -> {:ok, nil}
      {:error, :not_found} -> {:ok, github_grant(spec["repo"])}
      {:error, _} = error -> error
    end
  end

  # What the sandbox may do on GitHub (l4h-sandbox docs/sandbox-lifecycle-api.md
  # "GitHub access"): read and write the Task's repository, and push only
  # the Task's branch. Other repositories go without the token.
  defp github_grant(%{"owner" => owner, "name" => name, "branch" => branch}) do
    %{
      "repos" => %{"#{owner}/#{name}" => "write"},
      "push_refs" => ["refs/heads/" <> branch]
    }
  end

  # The token the sandbox's proxy uses, replaced shortly before it expires
  # (`github_expires_at`, ms). One not replaced (GitHub or L4ES did not
  # answer) is tried again at the next check.
  defp rotate_github(%{spec: %{"github_expires_at" => at} = spec} = workload)
       when is_integer(at) do
    if at - now_ms() > @github_rotate_ms do
      workload
    else
      with {:ok, %{token: token, expires_at: next}} <-
             github().token(spec["tenant_id"], github_group_id(spec["group_id"])),
           :ok <- L4ES.put_github_token(spec["group_id"], spec["sandbox"], token) do
        update(workload, &Map.put(&1, "github_expires_at", next))
        %{workload | spec: Map.put(spec, "github_expires_at", next)}
      else
        error ->
          Logger.warning("a coding sandbox's GitHub token was not replaced: #{inspect(error)}")
          workload
      end
    end
  end

  defp rotate_github(workload), do: workload

  # `ms`, or less: until the sandbox's GitHub token is due to be replaced.
  defp check_in(%{"github_expires_at" => at}, ms) when is_integer(at) do
    case at - @github_rotate_ms - now_ms() do
      due when due > 0 -> min(ms, due)
      _past -> ms
    end
  end

  defp check_in(_spec, ms), do: ms

  # `funs` run at once; their answers in order. One that does not answer in
  # time is stopped and answers `{:error, :timeout}`.
  defp together(funs) do
    funs
    |> SystemsClock.async_stream(& &1.(),
      max_concurrency: length(funs),
      timeout: @prepare_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, answer} -> answer
      {:exit, _reason} -> {:error, :timeout}
    end)
  end

  # The Workspace's members as L4ES members, so that each, signed in to L4ES
  # with Comma, opens the sandbox's terminal there. The product says who
  # they are (`config :salix_web, :coding_members`, a module with
  # `members/2`); a sync that fails is tried again with the next sandbox
  # and does not hold this one back.
  defp sync_members(spec) do
    with mod when not is_nil(mod) <- SystemsRuntime.get_env(:salix_web, :coding_members),
         {:ok, members} <- mod.members(spec["tenant_id"], spec["group_id"]),
         :ok <- L4ES.set_members(spec["group_id"], members) do
      :ok
    else
      nil ->
        :ok

      error ->
        Logger.warning("a coding sandbox's members were not set: #{inspect(error)}")
        :ok
    end
  end

  # Who the sandbox commits as: the Task's owner as the product knows them
  # (`config :salix_web, :coding_git_author`), else the GitHub account; nil
  # for a Task without a repository and no owner identity.
  defp git_author(spec, github_user) do
    with {:ok, owner} <- task_owner(spec),
         mod when not is_nil(mod) <- SystemsRuntime.get_env(:salix_web, :coding_git_author),
         {:ok, %{name: name, email: email}} when is_binary(email) and email != "" <-
           mod.identity(owner) do
      %{name: name, email: email}
    else
      _ -> if github_user, do: %{name: github_user.login, email: github_user.email}
    end
  end

  defp task_owner(%{"requester" => owner}) when is_binary(owner) and owner != "", do: {:ok, owner}

  defp task_owner(spec), do: StationTasks.owner(spec["group_id"], spec["conversation_id"])

  # L4ES accepted the start, of a new sandbox or of one started again from
  # its disk; `check/1` watches its placement from now (`created_at`).
  defp created(workload) do
    update(workload, fn s ->
      Map.merge(s, %{
        "created" => true,
        "created_at" => DateTime.to_iso8601(SystemsClock.utc_now()),
        "next_check_at" => iso_in(@starting_check_ms)
      })
    end)
  end

  defp retry(workload, why, recorded \\ %{}) do
    update(workload, fn s ->
      s
      |> Map.merge(recorded)
      |> Map.merge(%{"reason" => why, "next_check_at" => iso_in(@starting_check_ms)})
    end)
  end

  # A running sandbox whose station has not answered a heartbeat for the
  # start budget fails like a start that never connected: it is stopped, the
  # Task is told, and a Message starts it again from its disk. This covers a
  # station that stays disconnected and one that reconnects but never answers:
  # a connection alone proves nothing. Only a device record read from the
  # Registry proves silence: a sandbox whose device cannot be read, or whose
  # first silence cannot be written, keeps running and has its idle check.
  # A station never heard since Salix started writing heartbeats is counted
  # from when a check first saw that (`unheard_at`), and no run is counted
  # from before its station first connected (`ready_at`).
  defp station_check(%{spec: spec} = workload) do
    with {:ok, device} <-
           SalixEnv.Registry.get_device(spec["tenant_id"], spec["group_id"], spec["device_id"]),
         {:ok, heard, workload} <- last_heard(workload, device["heartbeat_at"]) do
      silent_ms = now_ms() - max(heard, spec["ready_at"] || 0)

      cond do
        silent_ms > @start_budget_ms ->
          stop(workload, "failed", "its station stopped answering and did not come back")

        device["status"] == "connected" and silent_ms < @heartbeat_fresh_ms ->
          case idle_check(workload) do
            :stopped ->
              :ok

            _running ->
              if is_map(spec["pending_secondaries"]) do
                _ = reconcile_invites(workload)
              end

              :ok
          end

        true ->
          next(workload, @start_budget_ms - silent_ms + 1)
      end
    else
      {:error, reason} ->
        Logger.warning(
          "a coding sandbox's station liveness is unknown: workload=#{workload.id} " <>
            "generation=#{workload.generation} #{inspect(reason)}"
        )

        idle_check(workload)
    end
  end

  defp last_heard(workload, at) when is_integer(at), do: {:ok, at, workload}

  defp last_heard(%{spec: %{"unheard_at" => at}} = workload, _none) when is_integer(at),
    do: {:ok, at, workload}

  defp last_heard(workload, _none) do
    at = now_ms()

    case update(workload, &Map.put(&1, "unheard_at", at)) do
      {:ok, workload} -> {:ok, at, workload}
      :error -> {:error, :unheard_at_not_written}
    end
  end

  # Stop an idle sandbox only when ALL active Sessions are `:idle` with
  # `pending == 0` and `min(for_ms) >= stop_after` (3 minutes for a Task in
  # review or ended, otherwise 2 hours). Never stops on `:unknown`.
  defp idle_check(%{spec: spec} = workload) do
    case StationTasks.session_statuses(spec["group_id"], spec["conversation_id"]) do
      {:ok, %{state: :idle, pending: 0, for_ms: for_ms} = status} when is_integer(for_ms) ->
        stop_after = if resting?(spec), do: @resting_idle_ms, else: @idle_stop_ms

        if for_ms >= stop_after do
          notice_unsaved(workload, status)
          stop(workload, "stopped", nil)
          :stopped
        else
          next(workload, min(@ready_check_ms, stop_after - for_ms))
        end

      _busy_or_unknown ->
        next(workload, @ready_check_ms)
    end
  end

  defp resting?(spec) do
    match?(
      {:ok, status} when status in @resting,
      StationTasks.current_status(spec["group_id"], spec["conversation_id"])
    )
  end

  defp reopen_decided(workload) do
    Store.update(workload.id, &{:ok, Map.delete(&1.spec, "reopened")})
    :ok
  end

  defp notice_unsaved(%{spec: spec}, status) do
    dirty = Map.get(status, :dirty) == true
    unpushed = Map.get(status, :unpushed) == true
    unmerged = Map.get(status, :unmerged) == true
    standing_unknown = Map.get(status, :standing_unknown) == true

    if dirty or unpushed or unmerged or standing_unknown do
      what =
        [
          dirty && "uncommitted changes",
          unpushed && "commits that were not pushed",
          unmerged && "unmerged commits on isolated session branches",
          standing_unknown && "unknown workspace git standing"
        ]
        |> Enum.filter(& &1)
        |> Enum.join(" and ")

      StationTasks.notice(
        spec["group_id"],
        spec["conversation_id"],
        spec["agent_id"],
        "idle-limit:#{spec["sandbox"]}",
        "The sandbox stopped after being idle. It had #{what} on " <>
          "#{get_in(spec, ["repo", "branch"])}. They stay on its disk only until the sandbox " <>
          "service needs the space. Reply to continue."
      )
    else
      :ok
    end
  end

  # Stops the sandbox, if there is one (L4ES keeps its disk), and records the
  # end state.
  defp stop(%{spec: spec} = workload, state, reason) do
    # L4ES runs a sandbox until it is stopped (`keep`): one that was not is
    # stopped again at the next checks (`sweep/1`), whatever the Task does.
    leftover =
      if is_binary(spec["sandbox"]),
        do: Enum.uniq(leftover(spec) ++ unstopped(spec["group_id"], [spec["sandbox"]])),
        else: leftover(spec)

    meter(workload)

    if state == "failed" and is_binary(reason) do
      StationTasks.notice(
        spec["group_id"],
        spec["conversation_id"],
        spec["agent_id"],
        "failed:#{workload.generation}",
        "The sandbox could not run: #{reason}. Reply to try again."
      )
    end

    update(workload, fn s ->
      # Under the row lock, with the generation checked, so an end is counted
      # once and only as it is written. A generation that never asked L4ES
      # for its sandbox ends none. A start given up on is a failed start; a
      # Task that ended before its sandbox connected made no start.
      if s["state"] in ~w(starting ready) and is_binary(s["sandbox"]),
        do: SystemsRuntime.Telemetry.execute([:salix_web, :sandbox, :end], %{}, %{state: state})

      if s["state"] == "starting" and state == "failed",
        do: started(%{workload | spec: s}, :failed)

      s
      |> Map.merge(%{
        "state" => state,
        "state_at" => DateTime.to_iso8601(SystemsClock.utc_now()),
        "reason" => reason,
        "sandbox" => nil,
        "created" => nil,
        "created_at" => nil,
        "remade_at" => nil,
        "ready_at" => nil,
        "unheard_at" => nil,
        "github_expires_at" => nil,
        "leftover" => leftover,
        "next_check_at" =>
          cond do
            state == "lost" -> iso_in(0)
            leftover == [] -> nil
            true -> iso_in(@leftover_retry_ms)
          end
      })
      |> then(fn s -> if state == "ended", do: s, else: Map.delete(s, "end") end)
      |> then(fn s ->
        if state == "lost",
          do: Map.put(s, "lost_notice", true),
          else: Map.delete(s, "lost_notice")
      end)
    end)
  end

  # Stops the sandboxes a stop could not, before the Workload is checked;
  # those still not stopped stay for the next checks.
  defp sweep(%{spec: spec} = workload) do
    case leftover(spec) do
      [] ->
        workload

      names ->
        left = unstopped(spec["group_id"], names)
        update(workload, &Map.put(&1, "leftover", left))
        %{workload | spec: Map.put(spec, "leftover", left)}
    end
  end

  defp leftover(spec), do: List.wrap(spec["leftover"])

  defp unstopped(group, names) do
    Enum.reject(names, fn name ->
      case L4ES.stop(group, name) do
        :ok ->
          true

        error ->
          Logger.warning("a coding sandbox was not stopped: #{name} #{inspect(error)}")
          false
      end
    end)
  end

  defp next(workload, ms),
    do: update(workload, &Map.put(&1, "next_check_at", iso_in(check_in(&1, ms))))

  # A start still under way: what it waits for is its reason, so a start
  # that runs out of budget says it (`check/1`).
  defp waiting(workload, why) do
    update(workload, fn s ->
      s
      |> Map.put("reason", why)
      |> Map.put("next_check_at", iso_in(check_in(s, @starting_check_ms)))
    end)
  end

  # What a made sandbox that has not connected waits for, as L4ES reports it.
  defp waiting_for(%{"state" => "pending", "data_status" => "retained"}),
    do: "its disk's L4ES node has not taken it back"

  defp waiting_for(%{"state" => "pending"}), do: "no L4ES node had room for it"

  defp waiting_for(%{"state" => "running"}),
    do: "the sandbox runs, but its station has not connected"

  defp waiting_for(%{"state" => state}), do: "L4ES is still starting it (#{state})"

  # Nothing to check until something changes, unless a sandbox is still to be stopped.
  defp clear(workload) do
    update(workload, fn s ->
      at = if leftover(s) == [], do: nil, else: iso_in(@leftover_retry_ms)
      Map.put(s, "next_check_at", at)
    end)
  end

  # Writes the spec under the row lock, for this generation only: `{:ok, workload}`
  # as written, or `:error` once logged.
  defp update(workload, fun) do
    case Store.update(workload.id, fn w ->
           if w.generation == workload.generation,
             do: {:ok, fun.(w.spec)},
             else: {:error, :stale_generation}
         end) do
      {:ok, workload} ->
        {:ok, workload}

      {:error, reason} ->
        Logger.warning(
          "a coding sandbox was not updated: workload=#{workload.id} generation=#{workload.generation} #{inspect(reason)}"
        )

        :error
    end
  end

  # Ready time as VM time; a meter that does not take it loses the interval
  # (no checkpoint is kept for a sandbox, whose life is one interval).
  defp meter(%{spec: %{"ready_at" => start} = spec} = workload) when is_integer(start) do
    now = now_ms()
    seconds = max(div(now - start, 1_000), 0)

    with true <- seconds > 0,
         mod when not is_nil(mod) <- SystemsRuntime.get_env(:salix_web, :vm_metering_mod) do
      owner =
        case SalixIM.GroupDirectory.get_group(spec["group_id"]) do
          {:ok, group} -> group["billing_owner"] || %{}
          _ -> %{}
        end

      mod.meter_vm_interval(%{
        source: "salix_web.coding_sandbox",
        source_key: "vm:l4es:#{workload.id}:#{workload.generation}:#{start}",
        entrypoint: "coding_sandbox",
        actor_type: "system",
        provider: "l4es",
        sku: "sandbox-" <> (spec["size"] || "default"),
        duration_seconds: seconds,
        quantity: seconds,
        metered_at: DateTime.from_unix!(now, :millisecond),
        interval_start_ms: start,
        interval_end_ms: now,
        tenant_id: spec["tenant_id"],
        group_id: spec["group_id"],
        env_id: spec["transport_id"],
        provider_resource_name: spec["sandbox"],
        owner_snapshot: owner,
        quality: []
      })
    end

    :ok
  rescue
    error -> Logger.warning("coding sandbox time not metered: #{Exception.message(error)}")
  end

  defp meter(_workload), do: :ok

  # --- What the session's sandbox and GitHub answered last

  @doc """
  The Task's Session ended a turn (`SalixWeb.StationTasks`): what the turn
  left is read now and kept (`remember/4`). Never waits: the three reads run
  in a task of their own, side by side, each within #{div(@facts_read_ms, 1000)} s.
  A part that is not read keeps what was kept before.
  """
  def turn_ended(group, conversation) do
    SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
      read_facts(group, conversation)
    end)

    :ok
  end

  defp read_facts(group, conversation) do
    at = SystemsClock.utc_now()

    with {:ok, tenant} <- tenant_of(group),
         {:ok, workload} <- Store.get_by_conversation(tenant, conversation) do
      repo = workload.spec["repo"]

      [usage, changes, pull_request] =
        together([
          fn -> usage_read(ask_station(group, conversation, "task.history", %{"limit" => 1})) end,
          fn ->
            if is_map(repo),
              do: changes_read(ask_station(group, conversation, "task.diff", %{})),
              else: :error
          end,
          fn -> pull_request_read(tenant, group, repo) end
        ])

      remember(
        tenant,
        conversation,
        %{"usage" => usage, "changes" => changes, "pull_request" => pull_request},
        at
      )
    end
  end

  defp ask_station(group, conversation, method, params),
    do: StationTasks.ask(group, conversation, method, params, @facts_read_ms)

  # A history page of one entry: the token use comes with any page.
  defp usage_read({:ok, page}), do: usage_part(page)
  defp usage_read(_answer), do: :error

  @doc """
  The token use a history page (`task.history`) says, as `remember/4` takes
  it: prefers aggregate `task_usage` (with `by_slot`, `models`, `partial`),
  falling back to single-session `usage`. Returns `{:ok, usage}` (nil when
  no model calls were made), or `:error` for a page that says none, which
  leaves the kept one as it is.
  """
  def usage_part(%{"task_usage" => task_usage}) when is_map(task_usage), do: {:ok, task_usage}
  def usage_part(%{"usage" => usage}), do: {:ok, usage}
  def usage_part(_page), do: :error

  defp changes_read({:ok, %{"files" => files}}) when is_list(files),
    do: {:ok, change_totals(files)}

  defp changes_read(_answer), do: :error

  defp pull_request_read(tenant, group, %{"owner" => owner, "name" => name, "branch" => branch})
       when is_binary(branch) and branch != "" do
    with {:ok, %{token: token}} <- github().token(tenant, github_group_id(group)),
         {:ok, pull_request} <- github().pull_request(token, owner, name, branch) do
      {:ok, pull_request_fact(pull_request)}
    else
      _ -> :error
    end
  end

  defp pull_request_read(_tenant, _group, _repo), do: :error

  @doc """
  What a diff's files (`additions`, `deletions`) change in all, as `facts`
  keeps it: how many files, and the lines they add and remove.
  """
  def change_totals(files) when is_list(files) do
    %{
      "files" => length(files),
      "additions" => files |> Enum.map(&lines(&1, :additions)) |> Enum.sum(),
      "deletions" => files |> Enum.map(&lines(&1, :deletions)) |> Enum.sum()
    }
  end

  # The station's diff names its counts with strings, GitHub's compare with atoms.
  defp lines(file, key), do: Map.get(file, key) || Map.get(file, Atom.to_string(key)) || 0

  @doc """
  A pull request as `facts` keeps it: as `SalixWeb.GitHub.pull_request/4`
  answers it, without its description. Nil: the branch has none.
  """
  def pull_request_fact(nil), do: nil
  def pull_request_fact(pull_request), do: pull_request |> Map.delete(:body) |> stringify()

  defp stringify(map), do: map |> Jason.encode!() |> Jason.decode!()

  @doc """
  Keeps `parts` of what a read that started at `at` (a `DateTime`) found, on
  the Workload of Task `conversation` (`facts`): `usage`, `changes` and
  `pull_request`, each `{:ok, value}`; anything else leaves its part as it
  is. A part a later read kept already stays. Each part is kept with when
  its read started: `%{"at" => iso8601, "value" => value}`.
  """
  def remember(tenant, conversation, parts, %DateTime{} = at) do
    with {:ok, workload} <- Store.get_by_conversation(tenant, conversation) do
      Store.update(workload.id, fn w ->
        facts = w.spec["facts"] || %{}
        kept = Enum.reduce(parts, facts, &keep(&1, &2, at))

        if kept == facts,
          do: {:error, :unchanged},
          else: {:ok, Map.put(w.spec, "facts", kept)}
      end)
    end

    :ok
  end

  defp keep({"usage", {:ok, value}}, facts, at) do
    existing_at = get_in(facts, ["usage", "at"])
    existing = get_in(facts, ["usage", "value"])
    merged = merge_usage(existing, value, at, existing_at)

    if later_kept?(facts["usage"], at) and merged == existing do
      facts
    else
      at_iso =
        if later_kept?(facts["usage"], at),
          do: existing_at || DateTime.to_iso8601(at),
          else: DateTime.to_iso8601(at)

      Map.put(facts, "usage", %{"at" => at_iso, "value" => merged})
    end
  end

  defp keep({part, {:ok, value}}, facts, at) do
    if later_kept?(facts[part], at),
      do: facts,
      else: Map.put(facts, part, %{"at" => DateTime.to_iso8601(at), "value" => value})
  end

  defp keep(_part, facts, _at), do: facts

  # Monotonic merge of Task usage by unique `session_id` with timestamp-fenced
  # `by_slot` bindings so out-of-order samples (`t0: A=10 -> t1: B=5 -> t0: A=10`)
  # never double-count a retired session and never revert a slot to an older session.
  defp merge_usage(nil, incoming, at, _existing_at) do
    if is_map(incoming) and is_map(incoming["by_slot"]) do
      merge_slot_usage(%{}, incoming, at, nil)
    else
      incoming
    end
  end

  defp merge_usage(%{} = existing, nil, _at, _existing_at), do: existing
  defp merge_usage(_existing, nil, _at, _existing_at), do: nil

  defp merge_usage(%{} = existing, %{} = incoming, at, existing_at) do
    if is_map(existing["by_slot"]) or is_map(incoming["by_slot"]) do
      merge_slot_usage(existing, incoming, at, existing_at)
    else
      merge_usage_counters(existing, incoming)
    end
  end

  defp merge_usage(_existing, incoming, _at, _existing_at), do: incoming

  @usage_numeric_keys ~w(modelCalls inputTokens cachedTokens outputTokens)

  defp merge_slot_usage(existing, incoming, at, existing_at) do
    at_iso = DateTime.to_iso8601(at)
    existing_slots = existing["by_slot"] || %{}
    incoming_slots = incoming["by_slot"] || %{}

    # Canonical per-session monotonic table: every `session_id` appears at most once.
    # When transitioning from flat single-session usage (no `by_slot` / `sessions`),
    # attribute the flat prior usage to the primary session id (or `"__legacy_primary__"`)
    # so even if primary is unreadable in the first multi-session sample, totals sum
    # `prior_primary + new_secondary` rather than `max(prior_primary, new_secondary)`.
    flat_legacy? =
      not is_map(existing["by_slot"]) and not is_map(existing["sessions"]) and
        Enum.any?(@usage_numeric_keys, &is_number(Map.get(existing, &1)))

    seed_sessions =
      existing["sessions"] ||
        %{}
        |> then(fn acc ->
          if flat_legacy? do
            legacy_sid =
              Enum.find_value(incoming_slots, fn {_slot, entry} ->
                if is_map(entry) and entry["is_primary"] == true and
                     is_binary(entry["session"]) and entry["session"] != "",
                   do: entry["session"]
              end) ||
                case get_in(incoming_slots, ["lead", "session"]) do
                  s when is_binary(s) and s != "" -> s
                  _ -> "__legacy_primary__"
                end

            legacy_usage = Map.take(existing, @usage_numeric_keys ++ ["model", "models"])
            Map.put(acc, legacy_sid, legacy_usage)
          else
            acc
          end
        end)
        |> then(fn acc ->
          Enum.reduce(existing["retired_sessions"] || %{}, acc, fn {sid, u}, s_acc ->
            if is_binary(sid) and is_map(u),
              do: Map.update(s_acc, sid, u, &merge_usage_counters(&1, u)),
              else: s_acc
          end)
        end)
        |> then(fn acc ->
          Enum.reduce(existing_slots, acc, fn {_slot, entry}, s_acc ->
            sid = entry["session"]
            u = entry["usage"]

            if is_binary(sid) and sid != "" and is_map(u),
              do: Map.update(s_acc, sid, u, &merge_usage_counters(&1, u)),
              else: s_acc
          end)
        end)

    {merged_slots, merged_sessions} =
      Enum.reduce(incoming_slots, {existing_slots, seed_sessions}, fn {slot, inc_entry},
                                                                      {slots_acc, sess_acc} ->
        inc_sess = inc_entry["session"]
        inc_usage = inc_entry["usage"]

        sess_acc =
          if is_binary(inc_sess) and inc_sess != "" and is_map(inc_usage) do
            Map.update(sess_acc, inc_sess, inc_usage, &merge_usage_counters(&1, inc_usage))
          else
            sess_acc
          end

        case Map.get(slots_acc, slot) do
          nil ->
            next_entry =
              inc_entry
              |> Map.put("at", at_iso)
              |> put_session_usage(inc_sess, sess_acc)

            {Map.put(slots_acc, slot, next_entry), sess_acc}

          cur_entry ->
            cur_sess = cur_entry["session"]
            cur_at = cur_entry["at"] || existing_at
            late_sample? = is_binary(cur_at) and later_kept?(%{"at" => cur_at}, at)

            cond do
              is_binary(cur_sess) and is_binary(inc_sess) and cur_sess != inc_sess and
                  late_sample? ->
                # Out-of-order late sample for an older session: `sess_acc[inc_sess]` was
                # already updated monotonically above; keep current slot bound to `cur_sess`.
                {slots_acc, sess_acc}

              is_binary(cur_sess) and is_binary(inc_sess) and cur_sess != inc_sess ->
                # Newer sample switched this slot to `inc_sess`.
                next_entry =
                  inc_entry
                  |> Map.put("at", at_iso)
                  |> put_session_usage(inc_sess, sess_acc)

                {Map.put(slots_acc, slot, next_entry), sess_acc}

              true ->
                merged_entry =
                  cur_entry
                  |> Map.merge(inc_entry)
                  |> Map.put("at", if(late_sample?, do: cur_at, else: at_iso))
                  |> Map.put(
                    "usage",
                    cond do
                      is_binary(inc_sess) and Map.has_key?(sess_acc, inc_sess) ->
                        Map.get(sess_acc, inc_sess)

                      true ->
                        merge_optional_usage(cur_entry["usage"], inc_usage)
                    end
                  )
                  |> then(fn e ->
                    if inc_entry["unreadable"] == true and not late_sample?,
                      do: Map.put(e, "unreadable", true),
                      else: Map.delete(e, "unreadable")
                  end)

                {Map.put(slots_acc, slot, merged_entry), sess_acc}
            end
        end
      end)

    # Sum strictly over unique sessions (plus any sessionless slot entries), so no
    # session can ever be double-counted between `by_slot` and retired history.
    active_sids =
      merged_slots
      |> Map.values()
      |> Enum.map(& &1["session"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> MapSet.new()

    sessionless_usages =
      merged_slots
      |> Map.values()
      |> Enum.filter(fn e -> not (is_binary(e["session"]) and e["session"] != "") end)
      |> Enum.map(& &1["usage"])
      |> Enum.filter(&is_map/1)

    all_usages = Map.values(merged_sessions) ++ sessionless_usages

    retired_sessions =
      merged_sessions
      |> Enum.reject(fn {sid, _u} -> MapSet.member?(active_sids, sid) end)
      |> Map.new()

    partial? =
      incoming["partial"] == true or
        Enum.any?(merged_slots, fn {_slot, entry} -> entry["unreadable"] == true end)

    models =
      Enum.reduce(all_usages, %{}, fn u, acc ->
        cond do
          is_map(u["models"]) and map_size(u["models"]) > 0 ->
            Enum.reduce(u["models"], acc, fn {model, counts}, m_acc ->
              Map.update(m_acc, model, counts, &sum_usage_counters(&1, counts))
            end)

          is_binary(u["model"]) and u["model"] != "" ->
            counts = Map.take(u, @usage_numeric_keys)
            Map.update(acc, u["model"], counts, &sum_usage_counters(&1, counts))

          true ->
            acc
        end
      end)

    totals =
      Enum.reduce(all_usages, %{}, fn u, acc -> sum_usage_counters(acc, u) end)

    base =
      existing
      |> Map.merge(incoming)
      |> Map.merge(totals)
      |> Map.put("by_slot", merged_slots)
      |> Map.put("sessions", merged_sessions)
      |> Map.put("models", models)
      |> Map.delete("prior_floor")
      |> then(fn m ->
        if map_size(retired_sessions) > 0,
          do: Map.put(m, "retired_sessions", retired_sessions),
          else: Map.delete(m, "retired_sessions")
      end)

    if partial?, do: Map.put(base, "partial", true), else: Map.delete(base, "partial")
  end

  defp put_session_usage(entry, sid, sess_acc)
       when is_binary(sid) and sid != "" do
    case Map.get(sess_acc, sid) do
      %{} = u -> Map.put(entry, "usage", u)
      _ -> entry
    end
  end

  defp put_session_usage(entry, _sid, _sess_acc), do: entry

  defp merge_optional_usage(nil, inc), do: inc
  defp merge_optional_usage(cur, nil), do: cur
  defp merge_optional_usage(%{} = cur, %{} = inc), do: merge_usage_counters(cur, inc)

  defp merge_usage_counters(cur, inc) do
    merged =
      Enum.reduce(@usage_numeric_keys, Map.merge(cur, inc), fn key, acc ->
        v1 = Map.get(cur, key)
        v2 = Map.get(inc, key)

        cond do
          is_number(v1) and is_number(v2) -> Map.put(acc, key, max(v1, v2))
          is_number(v1) -> Map.put(acc, key, v1)
          is_number(v2) -> Map.put(acc, key, v2)
          true -> acc
        end
      end)

    if is_map(cur["models"]) or is_map(inc["models"]) do
      models =
        Map.merge(cur["models"] || %{}, inc["models"] || %{}, fn _k, m1, m2 ->
          merge_usage_counters(m1 || %{}, m2 || %{})
        end)

      Map.put(merged, "models", models)
    else
      merged
    end
  end

  defp sum_usage_counters(acc, u) do
    Enum.reduce(@usage_numeric_keys, acc, fn key, m ->
      v = Map.get(u, key)

      if is_number(v) do
        Map.update(m, key, v, &(&1 + v))
      else
        m
      end
    end)
  end

  defp later_kept?(%{"at" => kept}, at) do
    case DateTime.from_iso8601(kept) do
      {:ok, kept, _} -> DateTime.compare(kept, at) == :gt
      _ -> false
    end
  end

  defp later_kept?(_kept, _at), do: false

  # The GitHub client (`SalixWeb.GitHub`; tests give another, `config :salix_web, :coding_github`).
  @doc false
  def github, do: SystemsRuntime.get_env(:salix_web, :coding_github, SalixWeb.GitHub)

  @doc """
  The web terminal links of those of coding Tasks `conversations` (of
  Group `group`) that have a sandbox, by Task, in one read: L4ES's
  `/t/comma:<group>/<sandbox>`, which a member of the Workspace opens signed
  in to L4ES with Comma. They name the sandbox the Task's creates make, so
  one is good while that sandbox runs; it is no credential.
  """
  def terminal_urls(group, conversations) when is_list(conversations) do
    with %{url: url} <- L4ES.config(),
         {:ok, tenant} <- tenant_of(group) do
      for {conversation, w} <- Store.get_by_conversations(tenant, conversations), into: %{} do
        name = w.spec["disk"] || sandbox_name(conversation, w.generation)
        {conversation, url <> "/t/" <> L4ES.workspace_ref(group) <> "/" <> name}
      end
    else
      _ -> %{}
    end
  end

  @doc "The L4ES name of a Task's sandbox first made in `generation`."
  def sandbox_name(conversation, generation) do
    body =
      conversation
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")
      |> String.slice(-16, 16)

    "t-#{body}-g#{generation}"
  end

  defp tenant_of(group) do
    case SalixIM.GroupDirectory.get_group(group) do
      {:ok, %{"tenant_id" => tenant}} -> {:ok, tenant}
      _ -> {:error, :group_not_found}
    end
  end

  defp describe(:github_not_connected), do: "the Workspace has no GitHub account connected"

  defp describe(:github_reauthorization_required),
    do: "the Workspace's GitHub connection needs signing in again"

  defp describe(:sandbox_unavailable), do: "coding sandboxes are not set up"

  defp describe(:image_not_published),
    do: "the sandbox image of this release is not published yet"

  defp describe(:image_unverified),
    do:
      "the sandbox image of this release has no dm-verity descriptor, which L4ES needs to boot it"

  defp describe(reason) when reason in [:manifest_unreachable, :bad_manifest, :bad_manifest_url],
    do: "the sandbox image of this release could not be read"

  defp describe(:l4es_unreachable), do: "L4ES could not be reached"
  # A reply alone starts the same refusal again: say what changes it.
  defp describe({:station_refused, "task.invite: no " <> rest = why}) do
    case Regex.run(~r/^(claude|codex) profile configured$/, rest) do
      [_, runtime] ->
        "the workspace lends a sandbox no #{runtime} account: add one in Settings > Model & API, " <>
          "or ask for this work with another runtime"

      nil ->
        why
    end
  end

  defp describe({:station_refused, why}), do: why
  defp describe(:device_offline), do: "its station disconnected"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # The start's end (`salix.sandbox.start.duration.seconds`): from the
  # Workload's `starting` to its station's connection, or to giving up on it
  # (`failed`). A Task that ends, or is stopped, while its sandbox starts is
  # not a start that failed: `salix.sandbox.ends.total` counts it.
  defp started(%{spec: spec} = workload, outcome) do
    SystemsRuntime.Telemetry.execute(
      [:salix_web, :sandbox, :start],
      %{duration: max(elapsed_ms(spec["state_at"]), 0)},
      %{kind: if(workload.generation == 1, do: :create, else: :wake), outcome: outcome}
    )
  end

  defp last_reason(%{"reason" => why}) when is_binary(why) and why != "", do: " (#{why})"
  defp last_reason(_spec), do: ""

  defp elapsed_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.diff(SystemsClock.utc_now(), at, :millisecond)
      _ -> 0
    end
  end

  defp elapsed_ms(_), do: 0

  defp iso_in(ms),
    do: SystemsClock.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()

  defp now_ms, do: SystemsClock.system_time(:millisecond)
end
