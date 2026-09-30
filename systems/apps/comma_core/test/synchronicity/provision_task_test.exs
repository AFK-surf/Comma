defmodule Comma.Synchronicity.ProvisionTaskTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Comma.Data.Workspace
  alias Comma.Repo

  defmodule Stub do
    @behaviour Comma.Synchronicity.Client

    @impl true
    def provision_workspace(workspace_id, _name, _owner) do
      if pid = Application.get_env(:comma_core, :synchronicity_test_pid) do
        send(pid, {:provisioned, workspace_id})
      end

      if workspace_id in Application.get_env(:comma_core, :synchronicity_test_failures, []) do
        {:error, {:retryable, :test_unavailable}}
      else
        {:ok,
         %{
           sync_org_id: "org-" <> workspace_id,
           sync_network_id: "net-" <> workspace_id,
           sync_user_id: "sync-user",
           created: true
         }}
      end
    end

    @impl true
    def enroll_device(_workspace_id, _nk, _label, _owner), do: {:error, :not_provisioned}

    @impl true
    def mint_api_key(_workspace_id, _owner, _name), do: {:error, {:retryable, :unused}}

    @impl true
    def revoke_api_key(_workspace_id, _key_id), do: {:error, {:retryable, :unused}}
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Application.put_env(:comma_core, :synchronicity,
      base_url: "http://sync.test",
      provisioning_secret: String.duplicate("x", 32)
    )

    Application.put_env(:comma_core, :synchronicity_client, Stub)
    Application.put_env(:comma_core, :synchronicity_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:comma_core, :synchronicity)
      Application.delete_env(:comma_core, :synchronicity_client)
      Application.delete_env(:comma_core, :synchronicity_test_pid)
      Application.delete_env(:comma_core, :synchronicity_test_failures)
    end)

    :ok
  end

  test "single-workspace provisioning persists the returned ids" do
    {user_id, workspace_id} = active_workspace("single")
    handler_id = "synchronicity-provision-task-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma_product, :operation, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    run_task([workspace_id])

    assert_received {:provisioned, ^workspace_id}

    assert_received {:telemetry, [:comma_product, :operation, :stop], %{duration: duration},
                     %{
                       operation: :synchronicity_provision,
                       provider: "synchronicity",
                       outcome: :ok
                     }}

    assert is_integer(duration) and duration >= 0
    assert_ready(workspace_id, user_id)
  end

  test "bounded backfill provisions only Workspaces with missing ids" do
    {first_user, first_id} = active_workspace("batch-a")
    {second_user, second_id} = active_workspace("batch-b")
    {_ready_user, ready_id} = active_workspace("already-ready")

    Repo.update_all(
      from(w in Workspace, where: w.id == ^ready_id),
      set: [sync_org_id: "org-existing", sync_network_id: "net-existing"]
    )

    run_task(["--all-missing", "--limit", "10"])

    assert_received {:provisioned, ^first_id}
    assert_received {:provisioned, ^second_id}
    refute_received {:provisioned, ^ready_id}
    assert_ready(first_id, first_user)
    assert_ready(second_id, second_user)

    ready = Repo.get!(Workspace, ready_id)
    assert ready.sync_org_id == "org-existing"
    assert ready.sync_network_id == "net-existing"
  end

  test "a failed bounded backfill preserves earlier successes and is resumable" do
    {successful_user, successful_id} = active_workspace("resume-a")
    {failed_user, failed_id} = active_workspace("resume-z")
    Application.put_env(:comma_core, :synchronicity_test_failures, [failed_id])

    assert_raise Mix.Error, ~r/left 1 Workspace\(s\) unresolved/, fn ->
      run_task(["--all-missing", "--limit", "10"])
    end

    assert_received {:provisioned, ^successful_id}
    assert_received {:provisioned, ^failed_id}
    assert_ready(successful_id, successful_user)

    failed = Repo.get!(Workspace, failed_id)
    assert is_nil(failed.sync_org_id)
    assert is_nil(failed.sync_network_id)

    Application.put_env(:comma_core, :synchronicity_test_failures, [])
    run_task(["--all-missing", "--limit", "10"])

    refute_received {:provisioned, ^successful_id}
    assert_received {:provisioned, ^failed_id}
    assert_ready(failed_id, failed_user)
  end

  test "release-native entry provisions one Workspace without Mix" do
    {user_id, workspace_id} = active_workspace("release-single")

    output =
      capture_io(fn ->
        assert {:ok,
                %{
                  mode: :workspace,
                  workspace_id: ^workspace_id,
                  processed: 1,
                  succeeded: 1,
                  failed: 0,
                  remote_created: true
                }} = Comma.Release.provision_synchronicity(workspace_id)
      end)

    assert output =~ "Synchronicity provisioning"
    assert_received {:provisioned, ^workspace_id}
    assert_ready(workspace_id, user_id)
  end

  test "release-native entry backfills a bounded resumable batch" do
    {first_user, first_id} = active_workspace("release-batch-a")
    {second_user, second_id} = active_workspace("release-batch-b")

    output =
      capture_io(fn ->
        assert {:ok,
                %{
                  mode: :all_missing,
                  processed: 2,
                  succeeded: 2,
                  failed: 0,
                  failures: []
                }} = Comma.Release.provision_synchronicity(all_missing: true, limit: 2)
      end)

    assert output =~ "Synchronicity provisioning"
    assert_ready(first_id, first_user)
    assert_ready(second_id, second_user)
  end

  test "release-native batch raises after preserving successful rows" do
    {successful_user, successful_id} = active_workspace("release-resume-a")
    {_failed_user, failed_id} = active_workspace("release-resume-z")
    Application.put_env(:comma_core, :synchronicity_test_failures, [failed_id])

    output =
      capture_io(fn ->
        assert_raise RuntimeError, ~r/left 1 Workspace\(s\) unresolved/, fn ->
          Comma.Release.provision_synchronicity(all_missing: true, limit: 2)
        end
      end)

    assert output =~ failed_id
    assert_received {:provisioned, ^successful_id}
    assert_received {:provisioned, ^failed_id}
    assert_ready(successful_id, successful_user)

    failed = Repo.get!(Workspace, failed_id)
    assert is_nil(failed.sync_org_id)
    assert is_nil(failed.sync_network_id)
  end

  test "release-native batch requires explicit bounded all-missing mode" do
    assert_raise ArgumentError, ~r/requires all_missing: true/, fn ->
      Comma.Release.provision_synchronicity(limit: 1)
    end

    assert_raise ArgumentError, ~r/limit must be between 1 and 1000/, fn ->
      Comma.Release.provision_synchronicity(all_missing: true, limit: 0)
    end

    assert_raise ArgumentError, ~r/unknown Synchronicity provisioning options/, fn ->
      Comma.Release.provision_synchronicity(all_missing: true, limit: 1, unexpected: true)
    end
  end

  test "refresh-all pages include mapped Workspaces and exclude deleted rows" do
    {_user_a, first} = active_workspace("refresh-a")
    {_user_b, second} = active_workspace("refresh-b")
    {_user_c, deleted} = active_workspace("refresh-c")

    Repo.update_all(from(w in Workspace, where: w.id in ^[first, second]),
      set: [sync_org_id: "existing-org", sync_network_id: "existing-net"]
    )

    Repo.update_all(from(w in Workspace, where: w.id == ^deleted), set: [status: "deleted"])

    capture_io(fn ->
      assert {:ok, %{processed: 1, mode: :refresh_all, last_workspace_id: ^first}} =
               Comma.Release.provision_synchronicity(refresh_all: true, limit: 1)
    end)

    assert_received {:provisioned, ^first}
    refute_received {:provisioned, ^second}
    run_task(["--refresh-all", "--limit", "1", "--after-id", first])
    assert_received {:provisioned, ^second}
    refute_received {:provisioned, ^first}
    refute_received {:provisioned, ^deleted}

    assert {:ok, %{processed: 0, last_workspace_id: nil}} =
             Comma.Synchronicity.refresh_all(1, second)
  end

  test "refresh-all reports failures without rolling back successful mapped rows" do
    {user, first} = active_workspace("refresh-failure-a")
    {_user, second} = active_workspace("refresh-failure-b")

    Repo.update_all(from(w in Workspace, where: w.id in ^[first, second]),
      set: [sync_org_id: "existing-org", sync_network_id: "existing-net"]
    )

    Application.put_env(:comma_core, :synchronicity_test_failures, [second])

    output =
      capture_io(fn ->
        assert_raise RuntimeError, ~r/left 1 Workspace/, fn ->
          Comma.Release.provision_synchronicity(refresh_all: true, limit: 10)
        end
      end)

    assert output =~ second
    assert_received {:provisioned, ^first}
    assert_received {:provisioned, ^second}
    assert_ready(first, user)
  end

  test "refresh-all rejects ambiguous modes and invalid cursors" do
    for opts <- [
          [all_missing: true, refresh_all: true],
          [all_missing: true, after_id: "wsp-a"],
          [refresh_all: true, after_id: ""],
          [refresh_all: true, after_id: 12],
          [refresh_all: true, limit: 1001]
        ] do
      assert_raise ArgumentError, fn -> Comma.Release.provision_synchronicity(opts) end
    end

    for args <- [
          ["--all-missing", "--refresh-all"],
          ["--all-missing", "--after-id", "wsp-a"],
          ["--refresh-all", "wsp-a"]
        ] do
      assert_raise Mix.Error, fn -> run_task(args) end
    end
  end

  defp active_workspace(prefix) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{prefix}-#{suffix}@comma.test"})
    workspace_id = "wsp-#{prefix}-#{suffix}"
    {:ok, _} = Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})

    Repo.update_all(
      from(w in Workspace, where: w.id == ^workspace_id),
      set: [status: "active", sync_org_id: nil, sync_network_id: nil]
    )

    {user["id"], workspace_id}
  end

  defp run_task(args) do
    Mix.Task.reenable("comma.synchronicity.provision")
    capture_io(fn -> Mix.Tasks.Comma.Synchronicity.Provision.run(args) end)
  end

  defp assert_ready(workspace_id, user_id) do
    workspace = Repo.get!(Workspace, workspace_id)
    assert workspace.sync_org_id == "org-" <> workspace_id
    assert workspace.sync_network_id == "net-" <> workspace_id

    assert {:ok, %{configured: true, provisioned: true, status: "ready"}} =
             Comma.Synchronicity.status(user_id)
  end
end
