defmodule SalixWeb.SiteRateLimitTest do
  use SystemsClock.Case, async: false

  alias SalixWeb.SiteAPI

  alias SalixStore.RedisLimit

  @prefix "salix:test:site-two-pods"

  # Two pods' limiters, each with its own Redis connection.
  defmodule PodA do
    use Hammer, backend: Hammer.Redis, timeout: 2_000
  end

  defmodule PodB do
    use Hammer, backend: Hammer.Redis, timeout: 2_000
  end

  test "two independently connected pods share one sliding window" do
    url = SystemsRuntime.fetch_env!(:salix_web, :site_rate_limit_redis_url)
    start_supervised!({PodA, url: url})
    start_supervised!({PodB, url: url})
    key = "two-pods-" <> unique()

    results =
      [PodA, PodB, PodA, PodB]
      |> Enum.map(fn pod ->
        SystemsRuntime.Task.async(fn ->
          RedisLimit.sliding_window(pod, @prefix, key, 60_000, 3, 2_000)
        end)
      end)
      |> SystemsRuntime.Task.await_many(:infinity)

    assert Enum.count(results, &match?({:allow, _}, &1)) == 3
    assert Enum.count(results, &match?({:deny, _}, &1)) == 1
  end

  test "a burst that reaches Redis in one read counts each request" do
    url = SystemsRuntime.fetch_env!(:salix_web, :site_rate_limit_redis_url)
    start_supervised!({PodA, url: url})
    key = "burst-" <> unique()

    # Pipelined requests made at one time.
    now = SystemsClock.system_time(:microsecond)

    {:ok, replies} =
      Redix.pipeline(
        PodA,
        List.duplicate(RedisLimit.sliding_window_command(@prefix, key, 60_000, 3, now), 5)
      )

    assert [{:allow, 1}, {:allow, 2}, {:allow, 3}, {:deny, _}, {:deny, _}] =
             Enum.map(replies, &RedisLimit.decision/1)
  end

  test "the window moves with the application's clock" do
    url = SystemsRuntime.fetch_env!(:salix_web, :site_rate_limit_redis_url)
    start_supervised!({PodA, url: url})
    key = "clock-" <> unique()
    hit = fn -> RedisLimit.sliding_window(PodA, @prefix, key, 60_000, 2, 2_000) end
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)

    assert {:allow, 1} = hit.()
    SystemsClock.advance(30_000)
    assert {:allow, 2} = hit.()
    assert {:deny, 30_000} = hit.()

    # The first request leaves the window; the second is still in it.
    SystemsClock.advance(30_000)
    assert {:allow, 2} = hit.()
    assert {:deny, 30_000} = hit.()
  end

  test "the production limiter shares quota across concurrent callers" do
    agent_id = "agent-" <> unique()

    results =
      1..4
      |> Enum.map(fn _ ->
        SystemsRuntime.Task.async(fn -> SiteAPI.State.allow?(agent_id, 3) end)
      end)
      |> SystemsRuntime.Task.await_many(:infinity)

    assert Enum.count(results, & &1) == 3
    assert Enum.count(results, &(not &1)) == 1
  end

  test "connection loss fails closed and supervisor restart recovers" do
    assert :ok =
             Supervisor.terminate_child(
               SalixWeb.Supervisor,
               SalixWeb.SiteAPI.RateLimit
             )

    refute SiteAPI.State.allow?("unavailable-" <> unique(), 1)

    assert {:ok, _pid} =
             Supervisor.restart_child(
               SalixWeb.Supervisor,
               SalixWeb.SiteAPI.RateLimit
             )

    assert SiteAPI.State.allow?("recovered-" <> unique(), 1)
  end

  defp unique,
    do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)
end
