defmodule Comma.Synchronicity.EnrollDeviceTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:enroll, workspace_id, nk, label, owner}
      )

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
    SystemsRuntime.put_env(:comma_core, :synchronicity,
      base_url: "http://sync.test",
      provisioning_secret: String.duplicate("x", 32)
    )

    SystemsRuntime.put_env(:comma_core, :synchronicity_client, Stub)

    on_exit(fn ->
      SystemsRuntime.delete_env(:comma_core, :synchronicity)
      SystemsRuntime.delete_env(:comma_core, :synchronicity_client)
    end)
  end

  defp unique(prefix),
    do: prefix <> "-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

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
end
