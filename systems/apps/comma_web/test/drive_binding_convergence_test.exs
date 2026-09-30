defmodule CommaWeb.DriveBindingConvergenceTest do
  @moduledoc """
  Comma's agent-key convergence against the real Salix binding store, through
  `CommaWeb.SalixClient`: the lookup Comma writes from is the row as stored, not
  the enabled handle the agent mount uses, so a binding an operator disabled
  is never replaced.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Comma.Data.Workspace
  alias Comma.Repo
  alias Comma.Synchronicity
  alias Salix.Control.DriveBindings

  @secret String.duplicate("x", 32)

  defmodule ControlPlane do
    @behaviour Comma.Synchronicity.Client

    @impl true
    def provision_workspace(_workspace_id, _name, _owner), do: {:error, :auth}

    @impl true
    def enroll_device(_workspace_id, _nk, _label, _owner), do: {:error, :not_provisioned}

    @impl true
    def mint_api_key(workspace_id, _owner, _name) do
      send(self(), {:mint, workspace_id})
      key_id = "key-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok,
       %{
         key_id: key_id,
         token: "synch_" <> key_id,
         prefix: "synch_" <> String.slice(key_id, 0, 8),
         org_id: "org-" <> workspace_id,
         org_slug: "comma-" <> workspace_id,
         network: "default",
         expires_at: 0
       }}
    end

    @impl true
    def revoke_api_key(workspace_id, key_id) do
      send(self(), {:revoke, workspace_id, key_id})
      Application.get_env(:comma_core, :drive_binding_test_revoke, :ok)
    end
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    previous = Application.get_env(:comma_core, :synchronicity)
    previous_client = Application.get_env(:comma_core, :synchronicity_client)

    Application.put_env(:comma_core, :synchronicity,
      base_url: "https://sync.test",
      provisioning_secret: @secret
    )

    Application.put_env(:comma_core, :synchronicity_client, ControlPlane)

    on_exit(fn ->
      restore(:synchronicity, previous)
      restore(:synchronicity_client, previous_client)
      Application.delete_env(:comma_core, :drive_binding_test_revoke)
    end)

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "drive-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace_id = "wsp-drive-#{System.unique_integer([:positive])}"
    {:ok, _} = Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})

    Repo.update_all(
      from(w in Workspace, where: w.id == ^workspace_id),
      set: [sync_org_id: "org-" <> workspace_id, sync_network_id: "net-" <> workspace_id]
    )

    workspace = Repo.get!(Workspace, workspace_id)
    on_exit(fn -> DriveBindings.delete(workspace.salix_group_id) end)

    {:ok, workspace: workspace, group_id: workspace.salix_group_id}
  end

  defp restore(key, nil), do: Application.delete_env(:comma_core, key)
  defp restore(key, value), do: Application.put_env(:comma_core, key, value)

  test "a disabled operator binding is preserved, not reminted over", %{
    workspace: workspace,
    group_id: group_id
  } do
    assert {:ok, _} =
             DriveBindings.put(group_id, %{
               "org_slug" => "manual-org",
               "api_key" => "synch_operator",
               "source" => "manual",
               "enabled" => false
             })

    # The mount sees no usable binding; convergence still sees the row.
    assert {:error, :not_configured} = DriveBindings.get(group_id)
    assert {:ok, %{"source" => "manual", "enabled" => false}} = DriveBindings.stored(group_id)

    assert {:ok, :manual} = Synchronicity.ensure_agent_key(workspace)
    assert {:ok, :manual} = Synchronicity.rotate_agent_key(workspace.id)
    refute_received {:mint, _}
    refute_received {:revoke, _, _}

    assert {:ok,
            %{
              "source" => "manual",
              "org_slug" => "manual-org",
              "api_key" => "synch_operator",
              "enabled" => false
            }} = DriveBindings.stored(group_id)
  end

  test "a group without a row gets a Comma binding the mount can use", %{
    workspace: workspace,
    group_id: group_id
  } do
    assert {:error, :not_found} = DriveBindings.stored(group_id)
    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    assert_received {:mint, _}

    assert {:ok, %{"source" => "comma", "enabled" => true, "retired_key_ids" => []} = row} =
             DriveBindings.stored(group_id)

    assert row["org_slug"] == "comma-" <> workspace.id
    assert {:ok, %{"org_slug" => org_slug}} = DriveBindings.get(group_id)
    assert org_slug == row["org_slug"]

    # Saving in the dashboard hands the row to the operator; Comma then leaves it.
    assert {:ok, _} = DriveBindings.put(group_id, %{"source" => "manual", "enabled" => false})
    assert {:ok, :manual} = Synchronicity.ensure_agent_key(workspace)
    assert {:ok, %{"source" => "manual", "api_key_id" => key_id}} = DriveBindings.stored(group_id)
    assert key_id == row["api_key_id"]
  end

  test "a takeover after a pending revocation keeps the ids listed and stops the retry", %{
    workspace: workspace,
    group_id: group_id
  } do
    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    {:ok, %{"api_key_id" => old_key_id}} = DriveBindings.stored(group_id)

    Application.put_env(:comma_core, :drive_binding_test_revoke, {:error, {:retryable, :timeout}})

    assert {:error, {:retryable, {:revoke_pending, %{key_ids: [^old_key_id]}}}} =
             Synchronicity.rotate_agent_key(workspace.id)

    assert_received {:revoke, _, ^old_key_id}
    assert {:ok, %{"retired_key_ids" => [^old_key_id]}} = DriveBindings.stored(group_id)

    # The operator disables the Drive on the group page, which is a `drive-save`.
    assert {:ok, %{"source" => "manual", "retired_key_ids" => [^old_key_id]}} =
             DriveBindings.put(group_id, %{"source" => "manual", "enabled" => false})

    Application.put_env(:comma_core, :drive_binding_test_revoke, :ok)
    assert {:ok, :manual} = Synchronicity.ensure_agent_key(workspace)
    assert {:ok, :manual} = Synchronicity.rotate_agent_key(workspace.id)
    refute_received {:revoke, _, ^old_key_id}

    assert {:ok, %{"source" => "manual", "enabled" => false, "retired_key_ids" => [^old_key_id]}} =
             DriveBindings.stored(group_id)
  end
end
