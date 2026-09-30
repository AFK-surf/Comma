defmodule Comma.Synchronicity.AgentKeyTest do
  @moduledoc """
  Comma mints one member org key per Workspace and hands it to Salix as the
  Workspace group's Drive binding. The control plane and the Salix binding
  store are both stubbed: what is asserted is the contract between the two.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Comma.Data.Workspace
  alias Comma.Repo
  alias Comma.Synchronicity

  @secret String.duplicate("x", 32)

  defmodule Stub do
    @behaviour Comma.Synchronicity.Client

    @impl true
    def provision_workspace(workspace_id, _name, _owner) do
      {:ok,
       %{
         sync_org_id: "org-" <> workspace_id,
         sync_org_slug: "comma-" <> workspace_id,
         sync_network_id: "net-" <> workspace_id,
         sync_user_id: "su",
         created: true
       }}
    end

    @impl true
    def enroll_device(_workspace_id, _nk, _label, _owner), do: {:error, :not_provisioned}

    @impl true
    def mint_api_key(workspace_id, owner, name) do
      send(self(), {:mint, workspace_id, owner, name})

      case Application.get_env(:comma_core, :agent_key_test_mint, :ok) do
        :ok ->
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

        other ->
          other
      end
    end

    @impl true
    def revoke_api_key(workspace_id, key_id) do
      send(self(), {:revoke, workspace_id, key_id})
      Application.get_env(:comma_core, :agent_key_test_revoke, :ok)
    end
  end

  # The Salix side, as `Comma.Salix.Client` reaches it: one binding per group,
  # kept in the application environment, with the lookup semantics of
  # `Salix.Control.DriveBindings.stored/1` (a disabled row is a row) and the
  # merge semantics of its `put/2` (a field left out keeps its value).
  defmodule SalixStub do
    @behaviour Comma.Salix.Client

    @impl true
    def provision_workspace_scope(_workspace), do: :ok
    @impl true
    def resolve_workspace_scope(workspace), do: {:ok, workspace}
    @impl true
    def get_workspace_agent_models(_workspace), do: {:error, :unused}
    @impl true
    def update_workspace_agent_model(_workspace, _role, _template_id), do: {:error, :unused}
    @impl true
    def update_workspace_vm(_workspace, _vm), do: {:error, :unused}
    @impl true
    def create_group_conversation(_workspace, _attrs), do: {:error, :unused}
    @impl true
    def ensure_group_router_conversation(_workspace), do: {:error, :unused}
    @impl true
    def append_group_router_conversation_message(_workspace, _attrs), do: {:error, :unused}
    @impl true
    def list_group_conversations(_workspace, _opts), do: {:error, :unused}
    @impl true
    def search_group_tasks(_workspace, _query, _opts), do: {:error, :unused}
    @impl true
    def get_group_conversation(_workspace, _conversation_id), do: {:error, :unused}
    @impl true
    def list_group_conversation_pins(_workspace), do: {:error, :unused}
    @impl true
    def pin_group_conversation(_workspace, _conversation_id), do: {:error, :unused}
    @impl true
    def unpin_group_conversation(_workspace, _conversation_id), do: {:error, :unused}
    @impl true
    def get_group_task_order(_workspace), do: {:error, :unused}
    @impl true
    def put_group_task_order(_workspace, _bucket, _ids), do: {:error, :unused}
    @impl true
    def conversation_activity_context(_workspace, _conversation_id), do: {:error, :unused}
    @impl true
    def list_agent_skills(_workspace), do: {:error, :unused}
    @impl true
    def append_group_conversation_message(_workspace, _conversation_id, _attrs),
      do: {:error, :unused}

    @impl true
    def get_group_conversation_messages(_workspace, _conversation_id), do: {:error, :unused}
    @impl true
    def read_agent_blob(_workspace, _agent_id, _ref, _max_bytes), do: {:error, :unused}
    @impl true
    def read_agent_file(_workspace, _path, _max_bytes), do: {:error, :unused}
    @impl true
    def write_agent_file(_workspace, _path, _body), do: {:error, :unused}

    @impl true
    def drive_binding(%{"default_group_id" => group_id}) do
      case bindings()[group_id] do
        nil -> {:error, :not_found}
        binding -> {:ok, binding}
      end
    end

    @impl true
    def put_drive_binding(%{"default_group_id" => group_id}, attrs) do
      case Application.get_env(:comma_core, :agent_key_test_binding_put, :ok) do
        :ok ->
          merged =
            (bindings()[group_id] || %{"enabled" => true, "retired_key_ids" => []})
            |> Map.merge(attrs)
            |> Map.put("group_id", group_id)

          Application.put_env(
            :comma_core,
            :agent_key_test_bindings,
            Map.put(bindings(), group_id, merged)
          )

          {:ok, Map.delete(merged, "api_key")}

        other ->
          other
      end
    end

    def seed(group_id, binding) do
      Application.put_env(
        :comma_core,
        :agent_key_test_bindings,
        Map.put(bindings(), group_id, binding)
      )
    end

    def bindings, do: Application.get_env(:comma_core, :agent_key_test_bindings, %{})
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    previous_salix = Application.get_env(:comma_core, :salix_client)

    Application.put_env(:comma_core, :synchronicity,
      base_url: "http://sync.test",
      provisioning_secret: @secret
    )

    Application.put_env(:comma_core, :synchronicity_client, Stub)
    Application.put_env(:comma_core, :salix_client, SalixStub)

    on_exit(fn ->
      Application.delete_env(:comma_core, :synchronicity)
      Application.delete_env(:comma_core, :synchronicity_client)
      Application.delete_env(:comma_core, :agent_key_test_mint)
      Application.delete_env(:comma_core, :agent_key_test_revoke)
      Application.delete_env(:comma_core, :agent_key_test_bindings)
      Application.delete_env(:comma_core, :agent_key_test_binding_put)

      case previous_salix do
        nil -> Application.delete_env(:comma_core, :salix_client)
        value -> Application.put_env(:comma_core, :salix_client, value)
      end
    end)

    :ok
  end

  defp unique(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp workspace do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique("owner") <> "@comma.test"})
    workspace_id = unique("wsp")
    {:ok, _} = Comma.Workspaces.create_for_user(user["id"], %{"workspace_id" => workspace_id})

    Repo.update_all(
      from(w in Workspace, where: w.id == ^workspace_id),
      set: [sync_org_id: "org-" <> workspace_id, sync_network_id: "net-" <> workspace_id]
    )

    {Repo.get!(Workspace, workspace_id), user["id"]}
  end

  defp binding_of(%Workspace{salix_group_id: group_id}), do: SalixStub.bindings()[group_id]

  test "the first call mints a member key and stores it as the group's Drive binding" do
    {workspace, user_id} = workspace()

    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    assert_received {:mint, workspace_id, %{subject: ^user_id}, "comma-agent"}
    assert workspace_id == workspace.id

    assert %{
             "base_url" => "http://sync.test",
             "org_slug" => org_slug,
             "network" => "default",
             "space" => "comma-drive",
             "api_key" => "synch_" <> _,
             "api_key_id" => "key-" <> _,
             "source" => "comma",
             "enabled" => true
           } = binding_of(workspace)

    assert org_slug == "comma-" <> workspace.id
  end

  test "a Comma-minted binding is left alone on repeat" do
    {workspace, _user_id} = workspace()
    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    assert_received {:mint, _, _, _}
    first = binding_of(workspace)

    assert {:ok, :present} = Synchronicity.ensure_agent_key(workspace)
    refute_received {:mint, _, _, _}
    refute_received {:revoke, _, _}
    assert binding_of(workspace) == first
  end

  test "a binding an operator entered by hand is never replaced" do
    {workspace, _user_id} = workspace()

    SalixStub.seed(workspace.salix_group_id, %{
      "source" => "manual",
      "api_key" => "synch_operator",
      "api_key_id" => ""
    })

    assert {:ok, :manual} = Synchronicity.ensure_agent_key(workspace)
    assert {:ok, :manual} = Synchronicity.rotate_agent_key(workspace.id)
    refute_received {:mint, _, _, _}
    refute_received {:revoke, _, _}
    assert binding_of(workspace)["api_key"] == "synch_operator"
  end

  test "a binding an operator disabled is a binding, and is left alone too" do
    {workspace, _user_id} = workspace()

    SalixStub.seed(workspace.salix_group_id, %{
      "source" => "manual",
      "org_slug" => "manual-org",
      "api_key" => "synch_operator",
      "api_key_id" => "",
      "enabled" => false
    })

    assert {:ok, :manual} = Synchronicity.ensure_agent_key(workspace)
    assert {:ok, :manual} = Synchronicity.rotate_agent_key(workspace.id)
    refute_received {:mint, _, _, _}
    refute_received {:revoke, _, _}

    assert %{"source" => "manual", "org_slug" => "manual-org", "enabled" => false} =
             binding_of(workspace)
  end

  test "rotation mints a new key, stores it and revokes the current one" do
    {workspace, _user_id} = workspace()
    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    old_key_id = binding_of(workspace)["api_key_id"]

    assert {:ok, :minted} = Synchronicity.rotate_agent_key(workspace.id)
    assert_received {:revoke, _workspace_id, ^old_key_id}
    assert binding_of(workspace)["api_key_id"] != old_key_id
    assert binding_of(workspace)["retired_key_ids"] == []
  end

  test "a rotation whose revocation is not confirmed says so and retries it later" do
    {workspace, _user_id} = workspace()
    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    assert_received {:mint, _, _, _}
    old_key_id = binding_of(workspace)["api_key_id"]

    Application.put_env(:comma_core, :agent_key_test_revoke, {:error, {:retryable, :timeout}})

    assert {:error, {:retryable, {:revoke_pending, %{key_ids: [^old_key_id], reason: reason}}}} =
             Synchronicity.rotate_agent_key(workspace.id)

    assert reason == {:retryable, :timeout}
    assert_received {:mint, _, _, _}
    assert_received {:revoke, _workspace_id, ^old_key_id}

    # The agent is already on the new key; the old one is on record as live.
    new_key_id = binding_of(workspace)["api_key_id"]
    assert new_key_id != old_key_id
    assert binding_of(workspace)["retired_key_ids"] == [old_key_id]

    # Convergence retries the revocation and is not done until it lands.
    assert {:error, {:retryable, {:revoke_pending, %{key_ids: [^old_key_id]}}}} =
             Synchronicity.ensure_agent_key(workspace)

    assert_received {:revoke, _workspace_id, ^old_key_id}
    refute_received {:mint, _, _, _}

    Application.put_env(:comma_core, :agent_key_test_revoke, :ok)
    assert {:ok, :present} = Synchronicity.ensure_agent_key(workspace)
    assert_received {:revoke, _workspace_id, ^old_key_id}
    assert binding_of(workspace)["api_key_id"] == new_key_id
    assert binding_of(workspace)["retired_key_ids"] == []
  end

  test "an operator takeover ends the retry: the pending ids stay listed, untouched" do
    {workspace, _user_id} = workspace()
    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    old_key_id = binding_of(workspace)["api_key_id"]

    Application.put_env(:comma_core, :agent_key_test_revoke, {:error, {:retryable, :timeout}})

    assert {:error, {:retryable, {:revoke_pending, _}}} =
             Synchronicity.rotate_agent_key(workspace.id)

    assert_received {:revoke, _workspace_id, ^old_key_id}

    # The operator disables the Drive on the group page: the row is theirs now.
    SalixStub.seed(
      workspace.salix_group_id,
      binding_of(workspace) |> Map.put("source", "manual") |> Map.put("enabled", false)
    )

    Application.put_env(:comma_core, :agent_key_test_revoke, :ok)
    assert {:ok, :manual} = Synchronicity.ensure_agent_key(workspace)
    assert {:ok, :manual} = Synchronicity.rotate_agent_key(workspace.id)
    refute_received {:revoke, _, _}
    assert binding_of(workspace)["retired_key_ids"] == [old_key_id]
    assert binding_of(workspace)["source"] == "manual"
  end

  test "a second rotation before the first revocation lands retires both keys" do
    {workspace, _user_id} = workspace()
    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    first = binding_of(workspace)["api_key_id"]

    Application.put_env(:comma_core, :agent_key_test_revoke, {:error, {:retryable, :timeout}})

    assert {:error, {:retryable, {:revoke_pending, _}}} =
             Synchronicity.rotate_agent_key(workspace.id)

    second = binding_of(workspace)["api_key_id"]

    assert {:error, {:retryable, {:revoke_pending, %{key_ids: [^first, ^second]}}}} =
             Synchronicity.rotate_agent_key(workspace.id)

    assert binding_of(workspace)["retired_key_ids"] == [first, second]

    # A key already gone counts as revoked.
    Application.put_env(:comma_core, :agent_key_test_revoke, {:error, :not_found})
    assert {:ok, :present} = Synchronicity.ensure_agent_key(workspace)
    assert binding_of(workspace)["retired_key_ids"] == []
  end

  test "a mint the control plane refuses stores nothing" do
    {workspace, _user_id} = workspace()
    Application.put_env(:comma_core, :agent_key_test_mint, {:error, {:retryable, :down}})

    assert {:error, {:retryable, :down}} = Synchronicity.ensure_agent_key(workspace)
    assert binding_of(workspace) == nil
    refute_received {:revoke, _, _}
  end

  test "a key the binding store cannot keep is revoked, not orphaned" do
    {workspace, _user_id} = workspace()
    Application.put_env(:comma_core, :agent_key_test_binding_put, {:error, :unavailable})

    assert {:error, {:retryable, {:drive_binding, :unavailable}}} =
             Synchronicity.ensure_agent_key(workspace)

    assert_received {:mint, _, _, _}
    assert_received {:revoke, _workspace_id, "key-" <> _}
    assert binding_of(workspace) == nil
  end

  test "status reports agent access once an enabled binding exists" do
    {workspace, user_id} = workspace()
    assert {:ok, %{status: "ready", agent_access: false}} = Synchronicity.status(user_id)
    assert {:ok, :minted} = Synchronicity.ensure_agent_key(workspace)
    assert {:ok, %{status: "ready", agent_access: true}} = Synchronicity.status(user_id)

    SalixStub.seed(workspace.salix_group_id, Map.put(binding_of(workspace), "enabled", false))
    assert {:ok, %{status: "ready", agent_access: false}} = Synchronicity.status(user_id)
  end

  test "an unconfigured deployment mints nothing" do
    {workspace, _user_id} = workspace()
    Application.delete_env(:comma_core, :synchronicity)
    assert {:error, :not_configured} = Synchronicity.ensure_agent_key(workspace)
    refute_received {:mint, _, _, _}
  end
end
