defmodule BridgeForTeams.RateLimitTest do
  use ExUnit.Case, async: false

  alias BridgeForTeams.RateLimit

  defmodule PodA do
    use Hammer,
      backend: Hammer.Redis,
      algorithm: :token_bucket,
      prefix: "bft:test:two-pods",
      timeout: 2_000
  end

  defmodule PodB do
    use Hammer,
      backend: Hammer.Redis,
      algorithm: :token_bucket,
      prefix: "bft:test:two-pods",
      timeout: 2_000
  end

  test "allows up to burst then rate-limits" do
    key = {:rl, make_ref()}
    # burst 3, no refill within the test window
    assert {:ok, 2} = RateLimit.hit(key, 1, burst: 3, rate: 0.0)
    assert {:ok, 1} = RateLimit.hit(key, 1, burst: 3, rate: 0.0)
    assert {:ok, 0} = RateLimit.hit(key, 1, burst: 3, rate: 0.0)
    assert {:error, :rate_limited} = RateLimit.hit(key, 1, burst: 3, rate: 0.0)
  end

  test "cost greater than one" do
    key = {:rl_cost, make_ref()}
    assert {:ok, 2} = RateLimit.hit(key, 3, burst: 5, rate: 0.0)
    assert {:error, :rate_limited} = RateLimit.hit(key, 3, burst: 5, rate: 0.0)
  end

  test "separate keys have independent buckets" do
    k1 = {:rl_a, make_ref()}
    k2 = {:rl_b, make_ref()}

    assert {:error, :rate_limited} =
             (
               RateLimit.hit(k1, 1, burst: 1, rate: 0.0)
               RateLimit.hit(k1, 1, burst: 1, rate: 0.0)
             )

    assert {:ok, 0} = RateLimit.hit(k2, 1, burst: 1, rate: 0.0)
  end

  test "two independently connected pods share one token bucket" do
    url = Application.fetch_env!(:bridge_for_teams_core, :rate_limit_redis_url)
    start_supervised!({PodA, url: url})
    start_supervised!({PodB, url: url})
    key = "two-pods-" <> unique()

    results =
      [PodA, PodB, PodA, PodB]
      |> Enum.map(fn limiter ->
        Task.async(fn -> limiter.hit(key, 1, 3, 1) end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:allow, _}, &1)) == 3
    assert Enum.count(results, &match?({:deny, _}, &1)) == 1
  end

  test "connection loss fails closed, emits telemetry, and supervised restart recovers" do
    handler = "bft-rate-limit-#{unique()}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:bridge_for_teams, :rate_limit, :decision],
        fn event, measurements, metadata, _ ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Supervisor.terminate_child(
               BridgeForTeams.Supervisor,
               BridgeForTeams.RateLimit.Redis
             )

    assert {:error, :rate_limiter_unavailable} =
             RateLimit.hit({:unavailable, unique()}, 1, burst: 1, rate: 1.0)

    assert_receive {
      [:bridge_for_teams, :rate_limit, :decision],
      %{count: 1},
      %{policy: :magic_link, outcome: :unavailable}
    }

    assert {:ok, _pid} =
             Supervisor.restart_child(
               BridgeForTeams.Supervisor,
               BridgeForTeams.RateLimit.Redis
             )

    assert {:ok, 0} = RateLimit.hit({:recovered, unique()}, 1, burst: 1, rate: 1.0)
  end

  defp unique,
    do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
