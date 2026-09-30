defmodule Comma.AuthChallengeStoreRedisTest do
  use ExUnit.Case, async: false

  alias Comma.AuthChallengeStore.Redis

  setup do
    previous_auth = Application.get_env(:comma_core, :auth)
    redis_url = System.get_env("REDIS_TEST_URL", "redis://127.0.0.1:6379/14")
    prefix = "comma:test:auth:lifecycle:#{unique()}"

    auth =
      previous_auth
      |> Keyword.put(:challenge_store, Redis)
      |> Keyword.put(:redis_url, redis_url)
      |> Keyword.put(:redis_key_prefix, prefix)

    Application.put_env(:comma_core, :auth, auth)

    child_id = Module.concat(Redis, Connection)

    case Supervisor.start_child(CommaCore.Supervisor, Redis) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> Supervisor.restart_child(CommaCore.Supervisor, child_id)
    end

    on_exit(fn ->
      Supervisor.terminate_child(CommaCore.Supervisor, child_id)
      Supervisor.delete_child(CommaCore.Supervisor, child_id)
      Application.put_env(:comma_core, :auth, previous_auth)
    end)

    %{child_id: child_id, prefix: prefix}
  end

  test "Lua verification is atomic across concurrent callers" do
    id = "challenge-" <> unique()
    hash = :crypto.hash(:sha256, "code") |> Base.encode16(case: :lower)

    challenge = %{
      "id" => id,
      "email" => "redis@example.test",
      "code_hash" => hash,
      "attempts" => 0
    }

    assert :ok = Redis.reserve_attempt(challenge, 60, attempt_opts())

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> Redis.verify(id, hash, 3) end) end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_found})) == 1
  end

  test "missing supervised connection fails closed and restart reconnects", %{child_id: child_id} do
    assert :ok = Supervisor.terminate_child(CommaCore.Supervisor, child_id)

    assert {:error, :redis_unavailable} =
             Redis.reserve_attempt(
               %{"id" => "offline-" <> unique(), "code_hash" => "hash"},
               60,
               attempt_opts()
             )

    assert {:ok, _pid} = Supervisor.restart_child(CommaCore.Supervisor, child_id)

    assert :ok =
             Redis.reserve_attempt(
               %{"id" => "online-" <> unique(), "code_hash" => "hash"},
               60,
               attempt_opts()
             )

    assert Process.whereis(Redis.connection_name()) != nil
  end

  test "invalid verification preserves sub-second expiry instead of making a persistent key", %{
    prefix: prefix
  } do
    id = "expiring-" <> unique()

    assert :ok =
             Redis.reserve_attempt(
               %{"id" => id, "code_hash" => "expected", "attempts" => 0},
               1,
               attempt_opts()
             )

    assert {:ok, _remaining_ms} = wait_for_subsecond_ttl(prefix, id, 40)
    assert {:error, :invalid_code} = Redis.verify(id, "wrong", 3)

    assert {:ok, remaining_ms} =
             Redix.command(Redis.connection_name(), [
               "PTTL",
               challenge_key(prefix, id)
             ])

    assert remaining_ms in 1..999
    Process.sleep(remaining_ms + 50)
    assert {:error, :not_found} = Redis.verify(id, "expected", 3)
  end

  test "the supervised client reconnects after its live Redis socket is killed" do
    connection = Module.concat(Redis, Connection)
    original_pid = Process.whereis(connection)
    redis_url = get_in(Application.fetch_env!(:comma_core, :auth), [:redis_url])

    assert {:ok, client_id} = Redix.command(connection, ["CLIENT", "ID"])
    {:ok, killer} = Redix.start_link(redis_url)

    on_exit(fn ->
      if Process.alive?(killer), do: GenServer.stop(killer)
    end)

    assert {:ok, 1} =
             Redix.command(killer, ["CLIENT", "KILL", "ID", Integer.to_string(client_id)])

    assert eventually(fn ->
             Redis.reserve_attempt(
               %{"id" => "reconnected-" <> unique(), "code_hash" => "hash"},
               60,
               attempt_opts()
             ) == :ok
           end)

    assert Process.whereis(connection) == original_pid
  end

  defp wait_for_subsecond_ttl(_prefix, _id, 0), do: {:error, :ttl_did_not_advance}

  defp wait_for_subsecond_ttl(prefix, id, attempts) do
    case Redix.command(Redis.connection_name(), [
           "PTTL",
           challenge_key(prefix, id)
         ]) do
      {:ok, ttl} when ttl in 1..500 ->
        {:ok, ttl}

      {:ok, _ttl} ->
        Process.sleep(25)
        wait_for_subsecond_ttl(prefix, id, attempts - 1)

      error ->
        error
    end
  end

  defp attempt_opts do
    %{
      ip_fingerprint: "peer-" <> unique(),
      ip_request_limit: 100,
      ip_request_window_seconds: 60
    }
  end

  defp challenge_key(prefix, id), do: Enum.join([prefix, "challenge", id], ":")

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp unique,
    do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
