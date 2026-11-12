defmodule Comma.Phase4WorkspaceConvergenceTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]
  import Ecto.Query

  alias Comma.Data.{ExternalOperation, Workspace, WorkspaceMembership}

  defmodule Provider do
    @table __MODULE__

    def reset(outcomes \\ [:ok]) do
      ensure_table()
      :ets.delete_all_objects(@table)
      :ets.insert(@table, {:outcomes, outcomes})
      :ok
    end

    def plan(outcomes), do: :ets.insert(@table, {:outcomes, outcomes})

    def calls do
      case :ets.lookup(@table, :calls) do
        [{:calls, count}] -> count
        [] -> 0
      end
    end

    def effective_count do
      @table
      |> :ets.tab2list()
      |> Enum.count(fn
        {{:effective, _key}, _generation} -> true
        _entry -> false
      end)
    end

    def last_vm do
      case :ets.lookup(@table, :last_vm) do
        [{:last_vm, vm}] -> vm
        [] -> nil
      end
    end

    # The group's Drive binding, as `Comma.Synchronicity.ensure_agent_key/1`
    # reads and writes it: one row per group, kept in the same table.
    def drive_binding(%{"default_group_id" => group_id}) do
      case :ets.lookup(@table, {:drive_binding, group_id}) do
        [{_key, binding}] -> {:ok, binding}
        [] -> {:error, :not_found}
      end
    end

    def put_drive_binding(%{"default_group_id" => group_id}, attrs) do
      current =
        case drive_binding(%{"default_group_id" => group_id}) do
          {:ok, binding} -> binding
          {:error, :not_found} -> %{"enabled" => true, "retired_key_ids" => []}
        end

      binding = Map.merge(current, attrs)
      :ets.insert(@table, {{:drive_binding, group_id}, binding})
      {:ok, Map.delete(binding, "api_key")}
    end

    def provision_workspace_scope(workspace) do
      call = :ets.update_counter(@table, :calls, {2, 1}, {:calls, 0})
      outcome = outcome(call)

      case outcome do
        :ok ->
          record_effect(workspace)
          :ok

        :kill_after_success ->
          record_effect(workspace)
          exit(:kill)

        :retryable ->
          {:error, :provider_unavailable}

        :terminal ->
          {:error, :invalid_workspace_configuration}
      end
    end

    def update_workspace_vm(workspace, vm) do
      :ets.insert(@table, {:last_vm, vm})
      record_effect(workspace)
      :ok
    end

    def resolve_workspace_scope(workspace), do: {:ok, workspace}

    def list_group_conversations(_workspace, _opts),
      do: {:ok, %{"data" => [], "has_more" => false, "next_cursor" => nil}}

    defp outcome(call) do
      [{:outcomes, outcomes}] = :ets.lookup(@table, :outcomes)
      Enum.at(outcomes, call - 1, List.last(outcomes))
    end

    defp record_effect(workspace) do
      key = workspace["provisioning_idempotency_key"]
      :ets.insert_new(@table, {{:effective, key}, workspace["provisioning_generation"]})
      :ok
    end

    defp ensure_table do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, write_concurrency: true])
        table -> table
      end
    rescue
      ArgumentError -> @table
    end
  end

  defmodule SynchStub do
    @behaviour Comma.Synchronicity.Client
    @impl true
    def provision_workspace(workspace_id, _name, _owner) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.get_env(:comma_core, :test_synch_pid),
        {:synch_provision, workspace_id}
      )

      case SystemsRuntime.get_env(:comma_core, :test_synch_result, :ok) do
        :ok ->
          {:ok,
           %{
             sync_org_id: "org-" <> workspace_id,
             sync_network_id: "net-" <> workspace_id,
             sync_user_id: "su",
             created: true
           }}

        other ->
          other
      end
    end

    @impl true
    def enroll_device(_workspace_id, _nk, _label, _owner), do: {:error, :not_provisioned}

    # Convergence mints the agent key right after provisioning; a stub key is
    # sealed and stored like a real one.
    @impl true
    def mint_api_key(workspace_id, _owner, name) do
      {:ok,
       %{
         key_id: "key-" <> workspace_id,
         token: "synch_" <> workspace_id,
         prefix: "synch_" <> String.slice(workspace_id, 0, 8),
         org_id: "org-" <> workspace_id,
         org_slug: "comma-" <> workspace_id,
         network: "default",
         expires_at: 0,
         name: name
       }}
    end

    @impl true
    def revoke_api_key(_workspace_id, _key_id), do: :ok
  end

  defp with_synchronicity(result) do
    SystemsRuntime.put_env(:comma_core, :synchronicity,
      base_url: "http://sync.test",
      provisioning_secret: String.duplicate("x", 32)
    )

    SystemsRuntime.put_env(:comma_core, :synchronicity_client, SynchStub)
    SystemsRuntime.put_env(:comma_core, :test_synch_result, result)
    SystemsRuntime.put_env(:comma_core, :test_synch_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.delete_env(:comma_core, :synchronicity)
      SystemsRuntime.delete_env(:comma_core, :synchronicity_client)
      SystemsRuntime.delete_env(:comma_core, :test_synch_result)
      SystemsRuntime.delete_env(:comma_core, :test_synch_pid)
    end)
  end

  setup do
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    comma_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    previous_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    SystemsRuntime.put_env(:comma_core, :salix_client, Provider)
    Provider.reset()

    on_exit(fn ->
      if previous_client,
        do: SystemsRuntime.put_env(:comma_core, :salix_client, previous_client),
        else: SystemsRuntime.delete_env(:comma_core, :salix_client)

      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(comma_owner)
    end)

    :ok
  end

  test "selfhost workspace gets one unlimited grant across convergence retries" do
    previous = SystemsRuntime.get_env(:comma_core, :selfhost)
    SystemsRuntime.put_env(:comma_core, :selfhost, true)

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:comma_core, :selfhost),
        else: SystemsRuntime.put_env(:comma_core, :selfhost, previous)
    end)

    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("selfhost")}@comma.test"})
    workspace_id = unique("wsp")
    Provider.plan([:retryable, :ok])
    {:ok, _} = Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})
    operation = operation_for!(workspace_id, 1)

    assert {:error, :provider_unavailable} =
             Comma.Workers.WorkspaceConvergence.run(operation.operation_id)

    make_due!(operation.operation_id)
    assert {:ok, _} = Comma.Workers.WorkspaceConvergence.run(operation.operation_id)
    workspace = Comma.Repo.get!(Workspace, workspace_id)

    result =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT COUNT(*) FROM credit_grants WHERE billing_account_id = $1 AND source_type = 'selfhost'",
        [workspace.billing_owner_id]
      )

    assert [[1]] = result.rows
    assert is_nil(workspace.vm)

    assert {:ok, decision} =
             BillingCore.FeeControl.authorize(%{
               repo: BillingCore.Repo,
               billing_account_id: workspace.billing_owner_id,
               resource_kind: :llm,
               action: :start,
               provider: "selfhost-test",
               sku: "test",
               mode: :enforce,
               estimated_credits: 1
             })

    assert decision.allowed?
    assert decision.entitlement_mode == :unlimited_metered
    assert decision.balance_snapshot == 0
  end

  test "workspace fact, owner, operation, and job commit atomically then retry converges" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("retry")}@comma.test"})
    workspace_id = unique("wsp")
    Provider.plan([:retryable, :ok])

    assert {:ok, pending} =
             Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})

    assert pending["status"] == "provisioning"

    workspace = Comma.Repo.get!(Workspace, workspace_id)
    assert workspace.status == "provisioning"
    assert Comma.Repo.get_by!(WorkspaceMembership, workspace_id: workspace_id).role == "owner"

    operation = operation_for!(workspace_id, 1)
    assert operation.status == "pending"
    assert Provider.calls() == 0
    assert Provider.effective_count() == 0
    assert operation.external_idempotency_key =~ workspace_id

    assert Comma.Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "Comma.Workers.WorkspaceConvergence" and
                   fragment("?->>'operation_id'", job.args) == ^operation.operation_id
             )
           )

    assert {:error, :provider_unavailable} =
             Comma.Workers.WorkspaceConvergence.run(operation.operation_id)

    operation = Comma.Repo.get!(ExternalOperation, operation.operation_id)
    assert operation.status == "retryable"
    make_due!(operation.operation_id)
    assert {:ok, succeeded} = Comma.Workers.WorkspaceConvergence.run(operation.operation_id)
    assert succeeded.status == "succeeded"
    assert Provider.calls() == 2
    assert Provider.effective_count() == 1
    assert {:ok, stored} = Comma.Workspaces.get(workspace.id)
    assert stored["id"] == workspace_id
    assert stored["status"] == "active"
  end

  test "VM recreate is a typed one-generation command and later desired VM clears it" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("vm")}@comma.test"})
    assert {:ok, workspace} = Comma.Workspaces.create_for_user(user["id"])
    assert {:ok, _} = run_workspace_generation(workspace["id"], 1)

    assert {:ok, recreated} =
             Comma.Workspaces.update(user, %{}, workspace["id"], %{
               "vm" => %{"provider" => "cloudflare", "recreate" => true}
             })

    row = Comma.Repo.get!(Workspace, workspace["id"])
    assert row.vm_recreate_generation == row.lock_version
    assert is_nil(Provider.last_vm())
    assert {:ok, _} = run_workspace_generation(workspace["id"], row.lock_version)
    assert Provider.last_vm()["recreate"] == true
    refute Map.has_key?(recreated["vm"], "recreate")

    assert {:ok, _updated} =
             Comma.Workspaces.update(user, %{}, workspace["id"], %{
               "vm" => %{"provider" => "cloudflare"}
             })

    row = Comma.Repo.get!(Workspace, workspace["id"])
    assert is_nil(row.vm_recreate_generation)
    assert Provider.last_vm()["recreate"] == true
    assert {:ok, _} = run_workspace_generation(workspace["id"], row.lock_version)
    refute Map.has_key?(Provider.last_vm(), "recreate")
  end

  test "a newer desired VM generation supersedes an older retryable operation" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("stale")}@comma.test"})
    assert {:ok, workspace} = Comma.Workspaces.create_for_user(user["id"])
    assert {:ok, _} = run_workspace_generation(workspace["id"], 1)

    Provider.plan([:retryable])

    assert {:ok, accepted} =
             Comma.Workspaces.update(user, %{}, workspace["id"], %{
               "vm" => %{"provider" => "cloudflare", "recreate" => true}
             })

    assert accepted["status"] == "active"

    stale = operation_for!(workspace["id"], 2)
    assert stale.status == "pending"

    assert {:error, :provider_unavailable} =
             Comma.Workers.WorkspaceConvergence.run(stale.operation_id)

    Provider.plan([:ok])

    assert {:ok, _workspace} =
             Comma.Workspaces.update(user, %{}, workspace["id"], %{
               "vm" => %{"provider" => "cloudflare"}
             })

    assert Comma.Repo.get!(ExternalOperation, stale.operation_id).status == "superseded"
    calls_before = Provider.calls()
    assert {:complete, superseded} = Comma.Workers.WorkspaceConvergence.run(stale.operation_id)
    assert superseded.status == "superseded"
    assert Provider.calls() == calls_before
    assert {:ok, _} = run_workspace_generation(workspace["id"], 3)
    assert Provider.last_vm() == %{"provider" => "cloudflare"}
  end

  test "external success followed by worker death recovers from the orphan without duplicate effect" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("orphan")}@comma.test"})
    workspace_id = unique("wsp")
    Provider.plan([:kill_after_success, :ok])

    assert {:ok, pending} =
             Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})

    assert pending["status"] == "provisioning"

    operation = operation_for!(workspace_id, 1)
    assert operation.status == "pending"
    assert Provider.effective_count() == 0

    {_pid, monitor} =
      spawn_monitor(fn -> Comma.Workers.WorkspaceConvergence.run(operation.operation_id) end)

    settle_receive({:DOWN, ^monitor, :process, _pid, :kill})
    operation = Comma.Repo.get!(ExternalOperation, operation.operation_id)
    assert operation.status == "executing"
    assert Provider.effective_count() == 1
    orphan!(operation.operation_id)

    assert {:ok, recovered} = Comma.Workers.WorkspaceConvergence.run(operation.operation_id)
    assert recovered.status == "succeeded"
    assert recovered.attempt == 2
    assert Comma.Repo.get!(Workspace, workspace_id).status == "active"
    assert Provider.calls() == 2
    assert Provider.effective_count() == 1
  end

  test "a Pod-killed executing job is rescued on the claim clock and the operation resumes" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("lifeline")}@comma.test"})
    workspace_id = unique("wsp")

    assert {:ok, %{"status" => "provisioning"}} =
             Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})

    operation = operation_for!(workspace_id, 1)

    job =
      Comma.Repo.one!(
        from(job in Oban.Job,
          where:
            job.worker == "Comma.Workers.WorkspaceConvergence" and
              fragment("?->>'operation_id'", job.args) == ^operation.operation_id
        )
      )

    timeout = SystemsRuntime.fetch_env!(:comma_core, :operation_claim_timeout_ms)
    stale_at = DateTime.add(SystemsClock.utc_now(), -(timeout + 1_000), :millisecond)

    Comma.Repo.update_all(
      from(candidate in ExternalOperation,
        where: candidate.operation_id == ^operation.operation_id
      ),
      set: [status: "executing", attempt: job.max_attempts, updated_at: stale_at]
    )

    Comma.Repo.update_all(
      from(candidate in Oban.Job, where: candidate.id == ^job.id),
      set: [
        state: "executing",
        attempt: job.max_attempts,
        attempted_at: stale_at,
        attempted_by: ["salix@terminated-pod", "terminated-producer"]
      ]
    )

    unrelated_job =
      %{}
      |> Comma.Workers.ProfileAvatarCleanup.new()
      |> then(&Oban.insert!(Comma.Oban, &1))

    Comma.Repo.update_all(
      from(candidate in Oban.Job, where: candidate.id == ^unrelated_job.id),
      set: [
        state: "executing",
        attempt: unrelated_job.max_attempts,
        attempted_at: stale_at,
        attempted_by: ["salix@terminated-pod", "terminated-producer"]
      ]
    )

    rescue_oban = :"operation_lifeline_test_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    start_supervised!(
      {Oban,
       name: rescue_oban,
       repo: Comma.Repo,
       peer: {Oban.Peers.Isolated, []},
       queues: [],
       plugins: [
         {Comma.ObanPlugins.OperationLifeline, interval: 10, rescue_after: timeout}
       ],
       testing: :disabled}
    )

    assert Oban.Peer.leader?(rescue_oban)

    eventually(fn ->
      rescued = Comma.Repo.get!(Oban.Job, job.id)

      if rescued.state == "available" and rescued.max_attempts == job.max_attempts + 1,
        do: :rescued
    end)

    assert %{
             state: "executing",
             max_attempts: max_attempts
           } = Comma.Repo.get!(Oban.Job, unrelated_job.id)

    assert max_attempts == unrelated_job.max_attempts

    Comma.Repo.update_all(
      from(candidate in Oban.Job,
        where:
          candidate.queue == "comma_external" and candidate.state == "available" and
            candidate.id != ^job.id
      ),
      set: [state: "scheduled", scheduled_at: DateTime.add(SystemsClock.utc_now(), 1, :hour)]
    )

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(Comma.Oban, queue: :comma_external, with_limit: 1)

    assert Comma.Repo.get!(Oban.Job, job.id).state == "completed"
    assert Comma.Repo.get!(ExternalOperation, operation.operation_id).status == "succeeded"
    assert Comma.Repo.get!(Workspace, workspace_id).status == "active"
  end

  test "two independent Repo clients create one workspace and one effective convergence" do
    workspace_id = unique("wsp")
    {repo_a, repo_b} = start_independent_repos()

    {:ok, user} =
      on_repo(repo_a, fn ->
        Comma.Accounts.create_user(%{"email" => "#{unique("race")}@comma.test"})
      end)

    on_exit(fn -> Comma.WorkspaceTestSupport.cleanup_committed_user!(repo_a, user["id"]) end)

    results =
      concurrent(repo_a, repo_b, fn ->
        Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1

    assert on_repo(repo_a, fn ->
             Comma.Repo.aggregate(
               from(workspace in Workspace, where: workspace.id == ^workspace_id),
               :count
             )
           end) == 1

    assert on_repo(repo_b, fn ->
             Comma.Repo.aggregate(
               from(operation in ExternalOperation,
                 where:
                   operation.owner_id == ^workspace_id and
                     operation.operation_type == "workspace_convergence"
               ),
               :count
             )
           end) == 1

    assert Provider.effective_count() == 0
    operation = on_repo(repo_a, fn -> operation_for!(workspace_id, 1) end)

    assert {:ok, %{status: "succeeded"}} =
             on_repo(repo_a, fn ->
               Comma.Workers.WorkspaceConvergence.run(operation.operation_id)
             end)

    assert Provider.effective_count() == 1
  end

  test "two independent Repo clients bootstrap one default Workspace" do
    {repo_a, repo_b} = start_independent_repos()

    {:ok, user} =
      on_repo(repo_a, fn ->
        Comma.Accounts.create_user(%{"email" => "#{unique("bootstrap-race")}@comma.test"})
      end)

    on_exit(fn -> Comma.WorkspaceTestSupport.cleanup_committed_user!(repo_a, user["id"]) end)

    results =
      concurrent(repo_a, repo_b, fn ->
        Comma.WorkspaceBootstrap.ensure_default(user["id"])
      end)

    assert Enum.all?(results, &match?({:ok, %{"status" => "provisioning"}}, &1))

    workspace_ids =
      Enum.map(results, fn {:ok, result} -> result["workspace"]["id"] end)

    assert [_workspace_id] = Enum.uniq(workspace_ids)
    [workspace_id | _] = workspace_ids

    assert on_repo(repo_a, fn ->
             Comma.Repo.aggregate(
               from(workspace in Workspace, where: workspace.owner_user_id == ^user["id"]),
               :count
             )
           end) == 1

    assert on_repo(repo_b, fn ->
             Comma.Repo.aggregate(
               from(operation in ExternalOperation,
                 where:
                   operation.owner_id == ^workspace_id and
                     operation.operation_type == "workspace_convergence"
               ),
               :count
             )
           end) == 1
  end

  test "Synchronicity failure leaves bootstrap and tasks ready while Drive is unavailable" do
    with_synchronicity({:error, {:retryable, :timeout}})
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("drive-outage")}@comma.test"})
    {:ok, pending} = Comma.WorkspaceBootstrap.ensure_default(user["id"])
    workspace_id = pending["workspace"]["id"]
    operation = operation_for!(workspace_id, 1)

    assert {:ok, succeeded} = Comma.Workers.WorkspaceConvergence.run(operation.operation_id)
    assert succeeded.status == "succeeded"
    refute_received {:synch_provision, ^workspace_id}
    assert %{failure: 1} = Oban.drain_queue(Comma.Oban, queue: :comma_drive)
    assert {:ok, %{"status" => "ready"}} = Comma.WorkspaceBootstrap.ensure_default(user["id"])
    workspace = Comma.Repo.get!(Workspace, workspace_id)
    assert {:ok, []} = Comma.Conversations.list(user, %{}, workspace.salix_group_id)

    assert {:ok, %{provisioned: false, agent_access: false}} =
             Comma.Synchronicity.status(user["id"])

    assert {:error, :not_provisioned} =
             Comma.Synchronicity.enroll_device(user["id"], "node", "Device")

    SystemsRuntime.put_env(:comma_core, :test_synch_result, :ok)
    assert %{success: 1} = Oban.drain_queue(Comma.Oban, queue: :comma_drive, with_scheduled: true)

    assert {:ok, %{provisioned: true, agent_access: true}} =
             Comma.Synchronicity.status(user["id"])

    assert {:ok, %{"workspace" => %{"id" => ^workspace_id}, "status" => "ready"}} =
             Comma.WorkspaceBootstrap.ensure_default(user["id"])
  end

  test "core convergence commits a separate Drive job that stores the org/network ids" do
    with_synchronicity(:ok)
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("synch")}@comma.test"})
    workspace_id = unique("wsp")

    assert {:ok, _} =
             Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})

    operation = operation_for!(workspace_id, 1)
    assert {:ok, succeeded} = Comma.Workers.WorkspaceConvergence.run(operation.operation_id)
    assert succeeded.status == "succeeded"

    workspace = Comma.Repo.get!(Workspace, workspace_id)
    assert workspace.status == "active"
    assert is_nil(workspace.sync_org_id)
    assert is_nil(workspace.sync_network_id)
    refute_received {:synch_provision, ^workspace_id}

    assert %{success: 1} = Oban.drain_queue(Comma.Oban, queue: :comma_drive)
    workspace = Comma.Repo.get!(Workspace, workspace_id)
    assert workspace.sync_org_id == "org-" <> workspace_id
    assert workspace.sync_network_id == "net-" <> workspace_id
  end

  test "a rejected Drive job can be retried without changing Workspace readiness" do
    with_synchronicity({:error, :auth})
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("drive-auth")}@comma.test"})
    {:ok, pending} = Comma.WorkspaceBootstrap.ensure_default(user["id"])
    workspace_id = pending["workspace"]["id"]
    assert {:ok, _} = run_workspace_generation(workspace_id, 1)
    assert %{cancelled: 1} = Oban.drain_queue(Comma.Oban, queue: :comma_drive)
    assert {:ok, %{"status" => "ready"}} = Comma.WorkspaceBootstrap.ensure_default(user["id"])

    SystemsRuntime.put_env(:comma_core, :test_synch_result, :ok)
    assert {:ok, first} = Comma.Synchronicity.enqueue(workspace_id)
    assert {:ok, same} = Comma.Synchronicity.enqueue(workspace_id)
    assert same.id == first.id
    assert %{success: 1} = Oban.drain_queue(Comma.Oban, queue: :comma_drive)
    assert {:ok, %{agent_access: true}} = Comma.Synchronicity.status(user["id"])
  end

  test "Drive jobs skip a Workspace deleted before execution" do
    with_synchronicity(:ok)

    {:ok, user} =
      Comma.Accounts.create_user(%{"email" => "#{unique("drive-deleted")}@comma.test"})

    {:ok, workspace} = Comma.Workspaces.create_for_user(user["id"])
    workspace_id = workspace["id"]
    assert {:ok, _} = run_workspace_generation(workspace_id, 1)

    Comma.Repo.get!(Workspace, workspace_id)
    |> Ecto.Changeset.change(status: "deleted")
    |> Comma.Repo.update!()

    assert %{success: 1} = Oban.drain_queue(Comma.Oban, queue: :comma_drive)
    refute_received {:synch_provision, ^workspace_id}
  end

  test "release recovery preserves failed operations and identities and rechecks core provisioning" do
    with_synchronicity({:error, {:retryable, :timeout}})
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("recover")}@comma.test"})
    {:ok, workspace} = Comma.Workspaces.create_for_user(user["id"])
    workspace_id = workspace["id"]
    original = Comma.Repo.get!(Workspace, workspace_id)
    failed = operation_for!(workspace_id, 1)

    original |> Ecto.Changeset.change(status: "provisioning_failed") |> Comma.Repo.update!()

    assert {:ok, {:execute, _}} = Comma.Operations.claim(failed.operation_id, 1)

    assert {:ok, {:updated, failed}} =
             Comma.Operations.terminal_failed(failed.operation_id, 1, "retry_exhausted")

    assert {:ok, %{processed: 1, next_cursor: nil}} =
             Comma.Workspaces.retry_failed_provisioning_page(nil)

    assert {:ok, %{processed: 0, next_cursor: nil}} =
             Comma.Workspaces.retry_failed_provisioning_page(nil)

    assert Comma.Repo.get!(ExternalOperation, failed.operation_id) == failed

    Provider.plan([:terminal])
    assert {:error, :invalid_workspace_configuration} = run_workspace_generation(workspace_id, 2)

    assert {:error, :workspace_provisioning_failed} =
             Comma.WorkspaceBootstrap.ensure_default(user["id"])

    Provider.plan([:ok])
    assert {:ok, %{processed: 1}} = Comma.Workspaces.retry_failed_provisioning_page(nil)
    assert {:ok, _} = run_workspace_generation(workspace_id, 3)
    assert {:ok, %{"status" => "ready"}} = Comma.WorkspaceBootstrap.ensure_default(user["id"])
    recovered = Comma.Repo.get!(Workspace, workspace_id)

    fields = [
      :id,
      :owner_user_id,
      :salix_tenant_id,
      :salix_group_id,
      :salix_router_agent_id,
      :billing_owner_id
    ]

    assert Map.take(recovered, fields) == Map.take(original, fields)
    assert {:ok, []} = Comma.Conversations.list(user, %{}, recovered.salix_group_id)
    assert %{failure: 1} = Oban.drain_queue(Comma.Oban, queue: :comma_drive)
    assert Comma.Repo.get!(Workspace, workspace_id).status == "active"
  end

  test "release recovery bounds each page and resumes after its cursor without provider calls" do
    ids =
      for _ <- 1..101 do
        {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("page")}@comma.test"})
        {:ok, workspace} = Comma.Workspaces.create_for_user(user["id"])
        workspace["id"]
      end

    Comma.Repo.update_all(from(w in Workspace, where: w.id in ^ids),
      set: [status: "provisioning_failed"]
    )

    assert {:ok, %{processed: 100, next_cursor: cursor}} =
             Comma.Workspaces.retry_failed_provisioning_page(nil)

    assert is_binary(cursor)

    assert Comma.Repo.aggregate(
             from(w in Workspace, where: w.id in ^ids and w.status == "provisioning_failed"),
             :count
           ) == 1

    assert {:ok, %{processed: 1, next_cursor: nil}} =
             Comma.Workspaces.retry_failed_provisioning_page(cursor)

    assert Comma.Repo.aggregate(
             from(op in ExternalOperation, where: op.owner_id in ^ids and op.generation == 2),
             :count
           ) == 101

    assert Provider.calls() == 0
  end

  test "release recovery leaves suspended Workspaces and inactive owners unchanged" do
    workspaces =
      for exclusion <- [:suspended, :disabled_user, :inactive_membership] do
        {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("skip")}@comma.test"})
        {:ok, workspace} = Comma.Workspaces.create_for_user(user["id"])
        status = if exclusion == :suspended, do: "suspended", else: "provisioning_failed"

        stored =
          Comma.Repo.get!(Workspace, workspace["id"])
          |> Ecto.Changeset.change(status: status)
          |> Comma.Repo.update!()

        case exclusion do
          :disabled_user ->
            Comma.Repo.get!(Comma.Accounts.User, user["id"])
            |> Ecto.Changeset.change(status: "disabled")
            |> Comma.Repo.update!()

          :inactive_membership ->
            Comma.Repo.get_by!(WorkspaceMembership, workspace_id: stored.id)
            |> Ecto.Changeset.change(status: "removed")
            |> Comma.Repo.update!()

          :suspended ->
            :ok
        end

        stored
      end

    assert {:ok, %{processed: 2, next_cursor: nil}} =
             Comma.Workspaces.retry_failed_provisioning_page(nil)

    for workspace <- workspaces do
      assert Comma.Repo.get!(Workspace, workspace.id) == workspace
      assert operation_for!(workspace.id, 1).status == "pending"
    end
  end

  defp run_workspace_generation(workspace_id, generation) do
    workspace_id
    |> operation_for!(generation)
    |> then(&Comma.Workers.WorkspaceConvergence.run(&1.operation_id))
  end

  defp operation_for!(workspace_id, generation) do
    Comma.Repo.get_by!(ExternalOperation,
      operation_type: "workspace_convergence",
      owner_id: workspace_id,
      generation: generation
    )
  end

  defp make_due!(operation_id) do
    Comma.Repo.update_all(
      from(operation in ExternalOperation, where: operation.operation_id == ^operation_id),
      set: [next_attempt_at: DateTime.add(SystemsClock.utc_now(), -1, :second)]
    )
  end

  defp orphan!(operation_id) do
    Comma.Repo.update_all(
      from(operation in ExternalOperation, where: operation.operation_id == ^operation_id),
      set: [updated_at: DateTime.add(SystemsClock.utc_now(), -600, :second)]
    )
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp start_independent_repos do
    opts = [name: nil, pool: DBConnection.ConnectionPool, pool_size: 1]
    {:ok, repo_a} = Comma.Repo.start_link(opts)
    {:ok, repo_b} = Comma.Repo.start_link(opts)
    SystemsRuntime.Proc.unlink(repo_a)
    SystemsRuntime.Proc.unlink(repo_b)

    on_exit(fn ->
      for repo <- [repo_a, repo_b], SystemsRuntime.Proc.alive?(repo), do: Supervisor.stop(repo)
    end)

    {repo_a, repo_b}
  end

  defp concurrent(repo_a, repo_b, fun) do
    parent = SystemsRuntime.Proc.self()
    ref = SystemsRuntime.Proc.make_ref()

    tasks =
      for repo <- [repo_a, repo_b] do
        SystemsRuntime.Task.async(fn ->
          SystemsRuntime.Proc.send(parent, {ref, :ready, SystemsRuntime.Proc.self()})
          SystemsRuntime.Proc.receive(do: ({^ref, :go} -> on_repo(repo, fun)))
        end)
      end

    for task <- tasks, do: settle_receive({^ref, :ready, pid} when pid == task.pid)
    for task <- tasks, do: SystemsRuntime.Proc.send(task.pid, {ref, :go})
    Enum.map(tasks, &settled_await/1)
  end

  defp on_repo(repo, fun) do
    previous = Comma.Repo.get_dynamic_repo()
    Comma.Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Comma.Repo.put_dynamic_repo(previous)
    end
  end

  defp unique(prefix),
    do: prefix <> "_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)
end
