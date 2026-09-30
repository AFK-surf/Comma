defmodule Comma.Synchronicity.EnrollDeviceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Comma.Data.Workspace
  alias Comma.Repo

  defmodule Stub do
    @behaviour Comma.Synchronicity.Client

    @impl true
    def provision_workspace(workspace_id, _name, _owner) do
      {:ok,
       %{
         sync_org_id: "org-" <> workspace_id,
         sync_network_id: "net-" <> workspace_id,
         sync_user_id: "su",
         created: true
       }}
    end

    @impl true
    def enroll_device(workspace_id, nk, label, owner) do
      send(self(), {:enroll, workspace_id, nk, label, owner})

      {:ok,
       %{
         device_id: "dev-" <> workspace_id,
         network: "default",
         domain: "default.comma-x.sync.test",
         created: true
       }}
    end

    @impl true
    def mint_api_key(_workspace_id, _owner, _name), do: {:error, {:retryable, :unused}}

    @impl true
    def revoke_api_key(_workspace_id, _key_id), do: {:error, {:retryable, :unused}}
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp configure do
    Application.put_env(:comma_core, :synchronicity,
      base_url: "http://sync.test",
      provisioning_secret: String.duplicate("x", 32)
    )

    Application.put_env(:comma_core, :synchronicity_client, Stub)

    on_exit(fn ->
      Application.delete_env(:comma_core, :synchronicity)
      Application.delete_env(:comma_core, :synchronicity_client)
    end)
  end

  defp unique(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp new_user, do: Comma.Accounts.create_user(%{"email" => unique("dev") <> "@comma.test"})

  defp workspace(network_id) do
    {:ok, user} = new_user()
    workspace_id = unique("wsp")
    {:ok, _} = Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})

    if is_binary(network_id) do
      Repo.update_all(
        from(w in Workspace, where: w.id == ^workspace_id),
        set: [sync_org_id: "org-" <> workspace_id, sync_network_id: network_id]
      )
    end

    user["id"]
  end

  test "enrolls a provisioned Workspace's device and passes the owner subject" do
    configure()
    user_id = workspace("net-1")

    assert {:ok, %{device_id: "dev-" <> _, domain: "default.comma-x.sync.test", created: true}} =
             Comma.Synchronicity.enroll_device(user_id, "nk-z32", "laptop")

    assert_received {:enroll, _workspace_id, "nk-z32", "laptop", %{subject: ^user_id}}
  end

  test "a Workspace with no assigned network is not provisioned yet" do
    configure()
    user_id = workspace(nil)

    assert {:error, :not_provisioned} =
             Comma.Synchronicity.enroll_device(user_id, "nk-z32", "laptop")
  end

  test "a user with no Workspace is workspace_not_found" do
    configure()
    {:ok, user} = new_user()

    assert {:error, :workspace_not_found} =
             Comma.Synchronicity.enroll_device(user["id"], "nk-z32", "laptop")
  end

  test "a missing nk is rejected before any S2S call" do
    configure()
    user_id = workspace("net-1")

    assert {:error, {:invalid, :nk}} = Comma.Synchronicity.enroll_device(user_id, nil, "laptop")
    refute_received {:enroll, _, _, _, _}
  end

  test "an unconfigured deployment reports not_configured" do
    assert {:error, :not_configured} =
             Comma.Synchronicity.enroll_device("usr_absent", "nk-z32", "laptop")
  end
end
