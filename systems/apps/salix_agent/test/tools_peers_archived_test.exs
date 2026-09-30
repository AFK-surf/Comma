defmodule SalixAgent.ToolsPeersArchivedTest do
  @moduledoc """
  Regression coverage for BRI-1638: archived peer-agent control records must not
  be listed.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentControl, AgentManagement}
  alias SalixStore.{Keys, S3}

  defmodule OAuthStubStore do
    @moduledoc false
    @behaviour SalixAgent.OAuthStore

    defp cfg, do: Application.get_env(:salix_agent, :archived_oauth_store_stub, %{})

    @impl true
    def agent_oauth_context(_agent_id), do: {:ok, cfg().context}

    @impl true
    def provider_app(_tenant, _provider), do: {:error, :not_configured}

    @impl true
    def bindings_for_group(_group_id), do: {:ok, []}

    @impl true
    def public_base_url, do: nil

    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule NoopPlacement do
    @moduledoc false
    @behaviour SalixAgent.Placement

    @impl true
    def ensure_started(_agent_id, _opts), do: {:error, :not_started}

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  setup do
    ensure_registry_started()
    SalixAgent.TestSupport.stop_all_agents()

    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_oauth_mod = Application.get_env(:salix_agent, :oauth_store_mod)
    prev_oauth_stub = Application.get_env(:salix_agent, :archived_oauth_store_stub)
    prev_placement = Application.get_env(:salix_agent, :placement)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)

    Application.put_env(:salix_agent, :oauth_store_mod, OAuthStubStore)

    Application.put_env(:salix_agent, :archived_oauth_store_stub, %{
      context: %{tenant: tenant_id, group_id: group_id}
    })

    Application.put_env(:salix_agent, :placement, NoopPlacement)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, prev_s3)
      restore_env(:salix_agent, :oauth_store_mod, prev_oauth_mod)
      restore_env(:salix_agent, :archived_oauth_store_stub, prev_oauth_stub)
      restore_env(:salix_agent, :placement, prev_placement)
    end)

    agent = SalixStore.Ids.new_agent_id(group_id)
    {:ok, agent: agent, ctx: %{agent_id: agent}, group_id: group_id}
  end

  defp ensure_registry_started do
    if Process.whereis(SalixAgent.Registry) do
      :ok
    else
      start_supervised!({Registry, keys: :unique, name: SalixAgent.Registry})
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp seed_agent(id, record), do: {:ok, _} = S3.put(Keys.ctl_agent(id), Jason.encode!(record))

  defp seed_agent_record(id, group_id, extra \\ %{}) do
    seed_agent(
      id,
      Map.merge(
        %{
          "agent_id" => id,
          "tenant_id" => SalixStore.Ids.tenant_id_from_group!(group_id),
          "template" => "worker",
          "group_id" => group_id,
          "role" => "worker",
          "heartbeat_schedule_id" => SalixStore.Ids.new_schedule_id()
        },
        extra
      )
    )
  end

  defp listed_ids(ctx, args \\ %{}) do
    AgentManagement.run(:list, args, ctx)
    |> then(fn {:ok, page} -> page end)
    |> Map.fetch!("items")
    |> Enum.map(& &1["agent_id"])
  end

  test "AgentControl.archived? uses archived_at key presence" do
    refute AgentControl.archived?(%{})
    assert AgentControl.archived?(%{"archived_at" => 0})
    assert AgentControl.archived?(%{"archived_at" => nil})
    assert AgentControl.archived?(%{"archived_at" => ""})
  end

  test "AgentControl.delete writes an integer archived_at timestamp", %{
    group_id: group_id
  } do
    deleted_id = SalixStore.Ids.new_agent_id(group_id)

    seed_agent_record(deleted_id, group_id, %{
      "status" => "idle",
      "configuration_authority" => "salix"
    })

    assert {:ok, updated} = AgentControl.delete(deleted_id)
    assert updated["status"] == "cancelled"
    assert AgentControl.archived?(updated)
    assert is_integer(updated["archived_at"])

    assert {:ok, stored} = AgentControl.get_record(deleted_id)
    assert stored["archived_at"] == updated["archived_at"]
  end

  test "agent.list excludes archived agents", %{agent: agent, ctx: ctx, group_id: group_id} do
    visible_id = SalixStore.Ids.new_agent_id(group_id)
    archived_id = SalixStore.Ids.new_agent_id(group_id)

    seed_agent_record(agent, group_id, %{
      "template" => "router",
      "role" => "router",
      "router_session_id" => SalixStore.Ids.new_session_id()
    })

    seed_agent_record(visible_id, group_id)

    seed_agent_record(archived_id, group_id, %{
      "archived_at" => 1_771_846_400,
      "status" => "idle"
    })

    ids = listed_ids(ctx)
    assert visible_id in ids
    refute archived_id in ids

    all_ids = listed_ids(ctx, %{"lifecycle" => "all"})
    assert visible_id in all_ids
    assert archived_id in all_ids
  end
end
