defmodule SalixAgent.RecommendationPolicyTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentActor, RecommendationPolicy}

  defmodule Adapter do
    def authorize_disclosure(_ctx, "recommendation.publish"), do: :ok
    def authorize_disclosure(_ctx, _name), do: {:error, :forbidden}
    def authorize_tool(_ctx, "recommendation.publish", _args), do: :ok
    def authorize_tool(_ctx, _name, _args), do: {:error, :forbidden}
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :recommendation_adapter_mod)
    SystemsRuntime.put_env(:salix_agent, :recommendation_adapter_mod, Adapter)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :recommendation_adapter_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :recommendation_adapter_mod)
    end)
  end

  test "uses one pre-resolved policy for disclosure and dispatch" do
    restricted = %{recommendation_policy: :restricted}

    assert RecommendationPolicy.allowed_disclosure?(restricted, %{
             "name" => "recommendation.publish",
             "safety" => "write"
           })

    refute RecommendationPolicy.allowed_disclosure?(restricted, %{
             "name" => "web.search",
             "safety" => "read"
           })

    assert RecommendationPolicy.allowed_tool?(restricted, "recommendation.publish", %{})
    refute RecommendationPolicy.allowed_tool?(restricted, "web.search", %{})

    disclosed = %{tool_disclosure: %{"recommendation_policy" => "restricted"}}
    refute RecommendationPolicy.allowed_tool?(disclosed, "web.search", %{})
  end

  test "fails closed for unresolved policy and missing control records" do
    unresolved = %{recommendation_policy: :unresolved}
    refute RecommendationPolicy.allowed_tool?(unresolved, "web.search", %{})

    refute RecommendationPolicy.allowed_disclosure?(unresolved, %{
             "name" => "web.search",
             "safety" => "read"
           })

    assert {:error, :not_found} =
             SalixAgent.RoundConfig.build_runtime_session_config(
               "agt1_00000000000000000000000000",
               "worker",
               %{}
             )
  end
end
