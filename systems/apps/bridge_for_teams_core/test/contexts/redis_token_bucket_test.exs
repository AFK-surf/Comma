defmodule BridgeForTeams.RedisTokenBucketTest do
  # The token buckets of BridgeForTeams.RateLimit (and Comma's OAuth IdP and Task Share limits):
  # SalixStore.RedisLimit.token_bucket/7 on the Redis the magic-link limits use.
  use SystemsClock.Case, async: false

  alias SalixStore.RedisLimit

  @prefix "bft:test:token-bucket"

  # Two pods' limiters, each with its own Redis connection.
  defmodule PodA do
    use Hammer, backend: Hammer.Redis, timeout: 2_000
  end

  defmodule PodB do
    use Hammer, backend: Hammer.Redis, timeout: 2_000
  end

  # The clock moves only when a test advances it: no token arrives while a test's requests are on their way to
  # Redis, however long they take.
  setup do
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)
    url = SystemsRuntime.fetch_env!(:bridge_for_teams_core, :rate_limit_redis_url)
    start_supervised!({PodA, url: url})
    start_supervised!({PodB, url: url})
    %{key: unique()}
  end

  test "two independently connected pods share one token bucket", %{key: key} do
    tasks =
      for pod <- [PodA, PodB, PodA, PodB] do
        SystemsRuntime.Task.async(fn ->
          RedisLimit.token_bucket(pod, @prefix, key, 1, 3, 1, 2_000)
        end)
      end

    results = SystemsRuntime.Task.await_many(tasks, :infinity)

    assert Enum.count(results, &match?({:allow, _}, &1)) == 3
    assert Enum.count(results, &match?({:deny, _}, &1)) == 1
  end

  test "a bucket fills on the application's clock and keeps the part of a token it earned", %{
    key: key
  } do
    # Two tokens at most, one a second.
    hit = fn -> RedisLimit.token_bucket(PodA, @prefix, key, 1, 2, 1, 2_000) end

    assert {:allow, 1} = hit.()
    assert {:allow, 0} = hit.()
    assert {:deny, 1_000} = hit.()
    SystemsClock.advance(500)
    assert {:deny, 500} = hit.()
    SystemsClock.advance(500)
    assert {:allow, 0} = hit.()
    assert {:deny, 1_000} = hit.()
  end

  defp unique,
    do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)
end
