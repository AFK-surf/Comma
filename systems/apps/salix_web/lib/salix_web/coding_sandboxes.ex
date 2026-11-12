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
      budget runs again from the remake, once per generation.
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
      if workload.spec["invited"] != true, do: invite(workload)
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

  defp invite(workload) do
    spec = workload.spec

    invitation = %{
      tenant_id: spec["tenant_id"],
      group_id: spec["group_id"],
      conversation_id: spec["conversation_id"],
      device_id: spec["device_id"],
      start: spec["start"]
    }

    with {:ok, session} <- StationTasks.invite(invitation),
         :ok <-
           StationTasks.joined(
             Map.merge(invitation, %{session: session, agent_id: spec["agent_id"]})
           ) do
      update(workload, fn spec ->
        spec |> Map.put("invited", true) |> Map.delete("invite_outcome")
      end)
    else
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
        SalixWeb.ComputeProviders.Cloudflare.VMAuthorization.Noop
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
          {:ok, %{"state" => state} = s} when state in @gone ->
            stop(workload, "failed", "the sandbox stopped: #{s["failure"] || state}")

          {:ok, %{"state" => "pending"} = s} ->
            if s["data_status"] == "retained" and
                 elapsed_ms(spec["created_at"]) >= @pinned_remake_ms,
               do: unplaced(workload),
               else: workload |> rotate_github() |> next(@starting_check_ms)

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
      author = git_author(spec, user)

      recorded = %{
        "sandbox" => name,
        "disk" => name,
        "created" => false,
        "github_expires_at" => github && github.expires_at
      }

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
              deleted.(workload)
            )

          {:error, reason} ->
            retry(workload, describe(reason))
        end
    end
  end

  defp github_identity(spec) do
    with {:ok, %{token: token} = github} <- github().token(spec["tenant_id"], spec["group_id"]),
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
             github().token(spec["tenant_id"], spec["group_id"]),
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
          idle_check(workload)

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

  # Stop an idle Session's sandbox after 3 minutes for a Task in review or
  # ended, otherwise after 2 hours. Local repository work stays on its disk.
  defp idle_check(%{spec: spec} = workload) do
    case StationTasks.session_status(spec["group_id"], spec["conversation_id"]) do
      {:ok, %{state: :idle, pending: 0, for_ms: for_ms} = status} when is_integer(for_ms) ->
        stop_after = if resting?(spec), do: @resting_idle_ms, else: @idle_stop_ms

        if for_ms >= stop_after do
          notice_unsaved(workload, status)
          stop(workload, "stopped", nil)
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

  defp notice_unsaved(%{spec: spec}, %{dirty: dirty, unpushed: unpushed})
       when dirty or unpushed do
    what =
      [dirty && "uncommitted changes", unpushed && "commits that were not pushed"]
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
  end

  defp notice_unsaved(_workload, _status), do: :ok

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
  it: `{:ok, usage}` (nil when the Session made no model calls), or `:error`
  for a page that says none, which leaves the kept one as it is.
  """
  def usage_part(%{"usage" => usage}), do: {:ok, usage}
  def usage_part(_page), do: :error

  defp changes_read({:ok, %{"files" => files}}) when is_list(files),
    do: {:ok, change_totals(files)}

  defp changes_read(_answer), do: :error

  defp pull_request_read(tenant, group, %{"owner" => owner, "name" => name, "branch" => branch})
       when is_binary(branch) and branch != "" do
    with {:ok, %{token: token}} <- github().token(tenant, group),
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

  defp keep({part, {:ok, value}}, facts, at) do
    if later_kept?(facts[part], at),
      do: facts,
      else: Map.put(facts, part, %{"at" => DateTime.to_iso8601(at), "value" => value})
  end

  defp keep(_part, facts, _at), do: facts

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
