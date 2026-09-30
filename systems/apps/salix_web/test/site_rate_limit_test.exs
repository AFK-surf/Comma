defmodule SalixWeb.SiteRateLimitTest do
  use ExUnit.Case, async: false

  alias SalixWeb.SiteAPI

  defmodule PodA do
    use Hammer,
      backend: Hammer.Redis,
      algorithm: :sliding_window,
      prefix: "salix:test:site-two-pods",
      timeout: 2_000
  end

  defmodule PodB do
    use Hammer,
      backend: Hammer.Redis,
      algorithm: :sliding_window,
      prefix: "salix:test:site-two-pods",
      timeout: 2_000
  end

  test "two independently connected pods share one sliding window" do
    url = Application.fetch_env!(:salix_web, :site_rate_limit_redis_url)
    start_supervised!({PodA, url: url})
    start_supervised!({PodB, url: url})
    key = "two-pods-" <> unique()

    results =
      [PodA, PodB, PodA, PodB]
      |> Enum.map(fn limiter ->
        Task.async(fn -> limiter.hit(key, 60_000, 3) end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:allow, _}, &1)) == 3
    assert Enum.count(results, &match?({:deny, _}, &1)) == 1
  end

  test "the production limiter shares quota across concurrent callers" do
    agent_id = "agent-" <> unique()

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn -> SiteAPI.State.allow?(agent_id, 3) end)
      end)
      |> Task.await_many(5_000)

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
    do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
