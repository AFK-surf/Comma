defmodule BridgeForTeams.RateLimitTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]
  alias BridgeForTeams.RateLimit

  test "allows up to burst then rate-limits" do
    key = {:rl, SystemsRuntime.Proc.make_ref()}
    # burst 3, no refill within the test window
    assert {:ok, 2} = RateLimit.hit(key, 1, burst: 3, rate: 0.0)
    assert {:ok, 1} = RateLimit.hit(key, 1, burst: 3, rate: 0.0)
    assert {:ok, 0} = RateLimit.hit(key, 1, burst: 3, rate: 0.0)
    assert {:error, :rate_limited} = RateLimit.hit(key, 1, burst: 3, rate: 0.0)
  end

  test "cost greater than one" do
    key = {:rl_cost, SystemsRuntime.Proc.make_ref()}
    assert {:ok, 2} = RateLimit.hit(key, 3, burst: 5, rate: 0.0)
    assert {:error, :rate_limited} = RateLimit.hit(key, 3, burst: 5, rate: 0.0)
  end

  test "separate keys have independent buckets" do
    k1 = {:rl_a, SystemsRuntime.Proc.make_ref()}
    k2 = {:rl_b, SystemsRuntime.Proc.make_ref()}

    assert {:error, :rate_limited} =
             (
               RateLimit.hit(k1, 1, burst: 1, rate: 0.0)
               RateLimit.hit(k1, 1, burst: 1, rate: 0.0)
             )

    assert {:ok, 0} = RateLimit.hit(k2, 1, burst: 1, rate: 0.0)
  end

  test "connection loss fails closed, emits telemetry, and supervised restart recovers" do
    handler = "bft-rate-limit-#{unique()}"
    parent = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:bridge_for_teams, :rate_limit, :decision],
        fn event, measurements, metadata, _ ->
          SystemsRuntime.Proc.send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    assert :ok =
             Supervisor.terminate_child(
               BridgeForTeams.Supervisor,
               BridgeForTeams.RateLimit.Redis
             )

    assert {:error, :rate_limiter_unavailable} =
             RateLimit.hit({:unavailable, unique()}, 1, burst: 1, rate: 1.0)

    settle_receive({
      [:bridge_for_teams, :rate_limit, :decision],
      %{count: 1},
      %{policy: :magic_link, outcome: :unavailable}
    })

    assert {:ok, _pid} =
             Supervisor.restart_child(
               BridgeForTeams.Supervisor,
               BridgeForTeams.RateLimit.Redis
             )

    assert {:ok, 0} = RateLimit.hit({:recovered, unique()}, 1, burst: 1, rate: 1.0)
  end

  defp unique,
    do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)
end
