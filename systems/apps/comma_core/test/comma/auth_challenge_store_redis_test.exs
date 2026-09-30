defmodule Comma.AuthChallengeStore.RedisTest do
  use ExUnit.Case, async: false

  alias Comma.AuthChallengeStore.Redis
  alias Comma.Auth.GoogleLoginAttempts

  @redis_url System.get_env("COMMA_TEST_REDIS_URL", "redis://127.0.0.1:6379/0")

  setup do
    previous_auth = Application.get_env(:comma_core, :auth)
    prefix = "comma:test:auth:#{System.unique_integer([:positive, :monotonic])}"

    Application.put_env(
      :comma_core,
      :auth,
      Keyword.merge(previous_auth || [], redis_url: @redis_url, redis_key_prefix: prefix)
    )

    start_supervised!({Redix, {@redis_url, [name: Redis.connection_name(), sync_connect: true]}})

    {:ok, connection} = Redix.start_link(@redis_url)
    assert {:ok, "PONG"} = Redix.command(connection, ["PING"])

    on_exit(fn ->
      {:ok, cleanup_connection} = Redix.start_link(@redis_url)
      delete_test_keys(cleanup_connection, prefix)
      GenServer.stop(cleanup_connection)
      restore_env(:comma_core, :auth, previous_auth)
    end)

    %{connection: connection, prefix: prefix}
  end

  test "request reservation atomically enforces email cooldown and fixed windows" do
    cooldown_opts = request_opts(resend_cooldown_seconds: 30)

    assert :ok = Redis.reserve(challenge("cooldown-1", "email-a"), 60, cooldown_opts)

    assert {:error, :rate_limited, retry_after} =
             Redis.reserve(challenge("cooldown-2", "email-a"), 60, cooldown_opts)

    assert retry_after in 1..30

    email_opts = request_opts(email_request_limit: 2)
    assert :ok = Redis.reserve(challenge("email-1", "email-b"), 60, email_opts)
    assert :ok = Redis.reserve(challenge("email-2", "email-b"), 60, email_opts)

    assert {:error, :rate_limited, retry_after} =
             Redis.reserve(challenge("email-3", "email-b"), 60, email_opts)

    assert retry_after in 1..60

    ip_opts = request_opts(ip_request_limit: 2, ip_fingerprint: "shared-ip")
    assert :ok = Redis.reserve(challenge("ip-1", "email-c"), 60, ip_opts)
    assert :ok = Redis.reserve(challenge("ip-2", "email-d"), 60, ip_opts)

    assert {:error, :rate_limited, retry_after} =
             Redis.reserve(challenge("ip-3", "email-e"), 60, ip_opts)

    assert retry_after in 1..60
  end

  test "concurrent request reservations cannot exceed the shared email window" do
    opts = request_opts(email_request_limit: 5)

    results =
      1..16
      |> Enum.map(fn index ->
        Task.async(fn ->
          Redis.reserve(challenge("request-race-#{index}", "shared-email"), 60, opts)
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:error, :rate_limited, _retry_after}, &1)) == 11
  end

  test "Google attempt peer limits are atomic and Redis stores only the HMAC fingerprint", %{
    connection: connection,
    prefix: prefix
  } do
    raw_ip = "203.0.113.88"
    rate_limit_secret = "redis-google-attempt-rate-limit-secret"
    current_auth = Application.fetch_env!(:comma_core, :auth)

    Application.put_env(
      :comma_core,
      :auth,
      current_auth
      |> Keyword.put(:challenge_store, Redis)
      |> Keyword.put(:rate_limit_secret, rate_limit_secret)
      |> Keyword.put(:ip_request_limit, 5)
      |> Keyword.put(:ip_request_window_seconds, 60)
    )

    results =
      1..16
      |> Enum.map(fn _index ->
        Task.async(fn -> GoogleLoginAttempts.create("web", %{"remote_ip" => raw_ip}) end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, %{"attempt_id" => "gla_" <> _}}, &1)) == 5

    assert Enum.count(results, &match?({:error, :rate_limited, _retry_after}, &1)) ==
             11

    expected_fingerprint =
      :crypto.mac(:hmac, :sha256, rate_limit_secret, "google_attempt_peer:" <> raw_ip)
      |> Base.url_encode64(padding: false)

    keys = scan_keys(connection, prefix)

    stored_values =
      Enum.map(keys, fn key ->
        assert {:ok, value} = Redix.command(connection, ["GET", key])
        value || ""
      end)

    stored = Enum.join(keys ++ stored_values, "\n")

    refute stored =~ raw_ip
    assert stored =~ expected_fingerprint
    assert Enum.count(keys, &String.contains?(&1, ":google_attempt:peer:")) == 1
    assert Enum.count(keys, &String.contains?(&1, ":challenge:gla_")) == 5
  end

  test "verification failures cannot be bypassed with a second challenge" do
    assert :ok = Redis.reserve(challenge("verify-1", "same-email"), 60, request_opts())
    assert :ok = Redis.reserve(challenge("verify-2", "same-email"), 60, request_opts())

    opts = verification_opts(verification_failure_limit: 2)

    assert {:error, :invalid_code} = Redis.verify("verify-1", "wrong", 5, opts)

    assert {:error, :rate_limited, retry_after} =
             Redis.verify("verify-2", "wrong", 5, opts)

    assert retry_after in 1..60
    assert {:error, :rate_limited, _retry_after} = Redis.verify("verify-2", "correct", 5, opts)

    assert :ok = Redis.reserve(challenge("attempts", "another-email"), 60, request_opts())
    assert {:error, :invalid_code} = Redis.verify("attempts", "wrong", 2, verification_opts())

    assert {:error, :too_many_attempts} =
             Redis.verify("attempts", "still-wrong", 2, verification_opts())

    assert {:error, :not_found} =
             Redis.verify("attempts", "correct", 2, verification_opts())
  end

  test "concurrent verification consumes a challenge exactly once" do
    assert :ok = Redis.reserve(challenge("concurrent", "email-f"), 60, request_opts())

    results =
      1..16
      |> Enum.map(fn _index ->
        Task.async(fn -> Redis.verify("concurrent", "correct", 5, verification_opts()) end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, %{"id" => "concurrent"}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :not_found}, &1)) == 15
  end

  test "expired challenges cannot be verified or restored" do
    assert :ok = Redis.reserve(challenge("expires", "email-expiry"), 1, request_opts())

    Process.sleep(1_100)

    assert {:error, :not_found} =
             Redis.verify("expires", "correct", 5, verification_opts())

    assert {:error, :not_found} =
             Redis.verify("expires", "correct", 5, verification_opts())
  end

  test "provider failures open a shared circuit and success resets it" do
    opts = circuit_opts(provider_failure_threshold: 2)

    assert :ok = Redis.record_delivery(:error, opts)
    assert {:ok, :circuit_open} = Redis.record_delivery(:error, opts)

    assert {:error, :provider_unavailable, retry_after} =
             Redis.reserve(challenge("blocked", "email-g"), 60, request_opts())

    assert retry_after in 1..60

    assert :ok = Redis.record_delivery(:ok, opts)
    assert :ok = Redis.reserve(challenge("unblocked", "email-g"), 60, request_opts())
  end

  test "missing supervised connection fails closed without opening a temporary connection" do
    assert :ok = stop_supervised(Redix)
    assert Process.whereis(Redis.connection_name()) == nil

    assert {:error, :redis_unavailable} =
             Redis.reserve_attempt(
               challenge("offline-attempt", "unused"),
               60,
               %{
                 ip_fingerprint: "offline-peer",
                 ip_request_limit: 5,
                 ip_request_window_seconds: 60
               }
             )

    assert Process.whereis(Redis.connection_name()) == nil
  end

  test "Redis challenge keys contain no raw email or IP", %{
    connection: connection,
    prefix: prefix
  } do
    raw_email = "peng+comma@gmail.com"
    raw_ip = "203.0.113.42"

    opts = request_opts(ip_fingerprint: "hmac-ip-fingerprint")

    assert :ok =
             Redis.reserve(
               challenge("redaction", "hmac-email-fingerprint", raw_email),
               60,
               opts
             )

    keys = scan_keys(connection, prefix)
    joined_keys = Enum.join(keys, "\n")

    refute joined_keys =~ raw_email
    refute joined_keys =~ raw_ip
    assert joined_keys =~ "hmac-email-fingerprint"
    assert joined_keys =~ "hmac-ip-fingerprint"
  end

  defp challenge(id, email_fingerprint, email \\ "person@example.com") do
    %{
      "id" => id,
      "purpose" => "email_login",
      "email" => email,
      "email_fingerprint" => email_fingerprint,
      "code_hash" => "correct",
      "attempts" => 0
    }
  end

  defp request_opts(overrides \\ []) do
    Map.merge(
      %{
        ip_fingerprint: "ip-#{System.unique_integer([:positive])}",
        resend_cooldown_seconds: 0,
        email_request_limit: 100,
        email_request_window_seconds: 60,
        ip_request_limit: 100,
        ip_request_window_seconds: 60
      },
      Map.new(overrides)
    )
  end

  defp verification_opts(overrides \\ []) do
    Map.merge(
      %{verification_failure_limit: 100, verification_failure_window_seconds: 60},
      Map.new(overrides)
    )
  end

  defp circuit_opts(overrides) do
    Map.merge(
      %{
        provider_failure_threshold: 100,
        provider_failure_window_seconds: 60,
        provider_circuit_open_seconds: 60
      },
      Map.new(overrides)
    )
  end

  defp scan_keys(connection, prefix, cursor \\ "0", acc \\ []) do
    {:ok, [next_cursor, keys]} =
      Redix.command(connection, ["SCAN", cursor, "MATCH", "#{prefix}:*", "COUNT", "100"])

    acc = keys ++ acc
    if next_cursor == "0", do: acc, else: scan_keys(connection, prefix, next_cursor, acc)
  end

  defp delete_test_keys(connection, prefix) do
    case scan_keys(connection, prefix) do
      [] -> :ok
      keys -> Redix.command(connection, ["UNLINK" | keys])
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
