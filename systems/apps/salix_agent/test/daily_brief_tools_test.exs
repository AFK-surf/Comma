defmodule SalixAgent.DailyBriefToolsTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.Tools.DailyBrief, as: DailyBriefTools

  defmodule OAuthStore do
    def agent_oauth_context("router"), do: {:ok, %{tenant: "tenant", group_id: "group"}}
  end

  # The product: records what the tool handed over.
  defmodule Product do
    def set_time(group_id, origin, brief, time) do
      owner = SystemsRuntime.get_env(:salix_agent, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:set_time, group_id, origin, brief, time})
      {:ok, %{"brief" => brief, "time" => time}}
    end
  end

  setup do
    for {key, value} <- [
          oauth_store_mod: OAuthStore,
          daily_brief_mod: Product,
          daily_brief_test_owner: SystemsRuntime.Proc.self()
        ] do
      previous = SystemsRuntime.get_env(:salix_agent, key)
      SystemsRuntime.put_env(:salix_agent, key, value)

      on_exit(fn ->
        if previous,
          do: SystemsRuntime.put_env(:salix_agent, key, previous),
          else: SystemsRuntime.delete_env(:salix_agent, key)
      end)
    end

    :ok
  end

  test "the Router's request reaches the product with the signed origin, not text" do
    origin = %{"provider" => "slack", "provider_context" => %{"user_id" => "U1"}}

    assert DailyBriefTools.set_time(%{"brief" => "mine", "time" => "08:30"}, %{
             agent_id: "router",
             trusted_origin: origin
           }) == ~s({"brief":"mine","time":"08:30"})

    assert_received {:set_time, "group", ^origin, "mine", "08:30"}
  end

  test "a turn several Slack users wrote in changes nothing" do
    alice = %{"provider" => "slack", "provider_context" => %{"user_id" => "UALICE"}}
    bob = %{"provider" => "slack", "provider_context" => %{"user_id" => "UBOB"}}

    assert_raise RuntimeError, ~r/requester_ambiguous/, fn ->
      DailyBriefTools.set_time(%{"brief" => "team", "time" => "07:00"}, %{
        agent_id: "router",
        trusted_origin: alice,
        trusted_origins: [bob, alice]
      })
    end

    refute_received {:set_time, _, _, _, _}
  end
end
