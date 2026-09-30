defmodule SalixAgent.Tools.MCPManagementTest do
  use ExUnit.Case, async: false

  alias SalixAgent.Tools.MCP

  defmodule Provider do
    @moduledoc false

    def set_owner(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
    def clear_owner, do: :persistent_term.erase({__MODULE__, :owner})

    def create_definition(agent_id, attrs) do
      record(:create_definition, [agent_id, attrs])
      {:ok, %{"mcp_id" => "mcp1_direct", "name" => attrs["name"]}}
    end

    def create_binding(agent_id, attrs) do
      record(:create_binding, [agent_id, attrs])
      {:ok, %{"binding_id" => "mpb1_direct", "alias" => attrs["alias"]}}
    end

    def update_binding(agent_id, binding_id, attrs) do
      record(:update_binding, [agent_id, binding_id, attrs])
      {:ok, Map.merge(%{"binding_id" => binding_id}, attrs)}
    end

    def set_binding_enabled(agent_id, binding_id, enabled) do
      record(:set_binding_enabled, [agent_id, binding_id, enabled])
      {:ok, %{"binding_id" => binding_id, "enabled" => enabled}}
    end

    def authorize_binding(agent_id, binding_id, params) do
      record(:authorize_binding, [agent_id, binding_id, params])

      {:ok,
       %{
         "status" => "authorization_required",
         "authorization_url" => "https://provider.example.test/oauth"
       }}
    end

    defp record(operation, args) do
      send(:persistent_term.get({__MODULE__, :owner}), {:mcp_provider_call, operation, args})
    end
  end

  defmodule RejectingCapabilityRequestStore do
    @moduledoc false

    def create_capability_request(attrs) do
      send(:persistent_term.get({Provider, :owner}), {:unexpected_capability_request, attrs})
      {:error, :mcp_management_approval_must_not_be_created}
    end
  end

  setup do
    previous_provider = Application.get_env(:salix_agent, :mcp_provider_mod)
    previous_request_store = Application.get_env(:salix_agent, :capability_request_store_mod)

    Provider.set_owner(self())
    Application.put_env(:salix_agent, :mcp_provider_mod, Provider)

    Application.put_env(
      :salix_agent,
      :capability_request_store_mod,
      RejectingCapabilityRequestStore
    )

    on_exit(fn ->
      Provider.clear_owner()
      restore_env(:mcp_provider_mod, previous_provider)
      restore_env(:capability_request_store_mod, previous_request_store)
    end)

    :ok
  end

  test "management writes execute immediately and OAuth returns the user continuation" do
    ctx = %{
      agent_id: "agt1_direct",
      session_id: "ses1_0000000000000000001",
      tool_call_id: "call-direct"
    }

    assert %{"definition" => %{"mcp_id" => "mcp1_direct"}} =
             decode(MCP.definition_create(%{name: "Direct MCP"}, ctx))

    assert_receive {:mcp_provider_call, :create_definition,
                    ["agt1_direct", %{"name" => "Direct MCP"}]}

    connect_args = %{
      mcp_id: "mcp1_direct",
      alias: "direct",
      target_ref: "remote:primary",
      placement: "server"
    }

    assert %{"binding" => %{"binding_id" => "mpb1_direct"}} =
             decode(MCP.connect(connect_args, ctx))

    assert_receive {:mcp_provider_call, :create_binding,
                    [
                      "agt1_direct",
                      %{
                        "alias" => "direct",
                        "mcp_id" => "mcp1_direct",
                        "placement" => "server",
                        "target_ref" => "remote:primary"
                      }
                    ]}

    assert %{"binding" => %{"alias" => "renamed"}} =
             decode(MCP.update(%{binding_id: "mpb1_direct", alias: "renamed"}, ctx))

    assert_receive {:mcp_provider_call, :update_binding,
                    ["agt1_direct", "mpb1_direct", %{"alias" => "renamed"}]}

    assert %{"binding" => %{"enabled" => true}} =
             decode(MCP.set_enabled(%{binding_id: "mpb1_direct", enabled: true}, ctx))

    assert_receive {:mcp_provider_call, :set_binding_enabled,
                    ["agt1_direct", "mpb1_direct", true]}

    assert %{"binding" => %{"enabled" => false}} =
             decode(MCP.set_enabled(%{binding_id: "mpb1_direct", enabled: false}, ctx))

    assert_receive {:mcp_provider_call, :set_binding_enabled,
                    ["agt1_direct", "mpb1_direct", false]}

    assert %{
             "authorization" => %{
               "status" => "authorization_required",
               "authorization_url" => "https://provider.example.test/oauth"
             }
           } = decode(MCP.authorize(%{binding_id: "mpb1_direct", scope: "read"}, ctx))

    assert_receive {:mcp_provider_call, :authorize_binding,
                    ["agt1_direct", "mpb1_direct", %{"scope" => "read"}]}

    refute_received {:unexpected_capability_request, _attrs}
  end

  test "management tool contracts contain no Salix approval replay parameter" do
    contracts =
      MCP.defs()
      |> Map.new(fn {name, description, schema, _fun, _auto_wait} ->
        {name, {description, schema}}
      end)

    for name <- [
          "mcp_manager.definition_create",
          "mcp_manager.connect",
          "mcp_manager.update",
          "mcp_manager.set_enabled",
          "mcp_manager.authorize"
        ] do
      {_description, schema} = Map.fetch!(contracts, name)

      refute Map.has_key?(schema["properties"], "approval_request_id")
    end
  end

  defp decode(result), do: Jason.decode!(result)

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)
end
