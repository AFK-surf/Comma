defmodule Comma.AuthChallengeStore.Redis do
  @moduledoc """
  Redis-backed auth challenge and abuse-control store.

  Email and IP rate-limit keys receive only server-HMAC fingerprints. Challenge
  payloads remain short-lived and are consumed atomically. Every Lua script
  declares all keys up front; v1 expects one Redis primary/database rather than
  distributing these multi-key scripts across Redis Cluster hash slots.
  """

  @behaviour Comma.AuthChallengeStore

  @connection_name Comma.AuthChallengeStore.Redis.Connection

  @reserve_attempt_script """
  local peer_window_key = KEYS[1]
  local challenge_key = KEYS[2]

  local challenge_json = ARGV[1]
  local challenge_ttl = tonumber(ARGV[2])
  local peer_limit = tonumber(ARGV[3])
  local peer_window_seconds = tonumber(ARGV[4])

  local function positive_ttl(key)
    local ttl = redis.call("PTTL", key)
    if ttl > 0 then
      return ttl
    end
    return peer_window_seconds * 1000
  end

  if redis.call("EXISTS", challenge_key) == 1 then
    return {"challenge_collision", 0}
  end

  local peer_count = tonumber(redis.call("GET", peer_window_key) or "0")
  if peer_count >= peer_limit then
    return {"rate_limited", positive_ttl(peer_window_key)}
  end

  local stored = redis.call(
    "SET",
    challenge_key,
    challenge_json,
    "EX",
    challenge_ttl,
    "NX"
  )

  if not stored then
    return {"challenge_collision", 0}
  end

  peer_count = redis.call("INCR", peer_window_key)
  if peer_count == 1 then
    redis.call("EXPIRE", peer_window_key, peer_window_seconds)
  end

  return {"ok", 0}
  """

  @reserve_script """
  local circuit_key = KEYS[1]
  local cooldown_key = KEYS[2]
  local email_window_key = KEYS[3]
  local ip_window_key = KEYS[4]
  local challenge_key = KEYS[5]

  local challenge_json = ARGV[1]
  local challenge_ttl = tonumber(ARGV[2])
  local cooldown_seconds = tonumber(ARGV[3])
  local email_limit = tonumber(ARGV[4])
  local email_window_seconds = tonumber(ARGV[5])
  local ip_limit = tonumber(ARGV[6])
  local ip_window_seconds = tonumber(ARGV[7])

  local function positive_ttl(key, fallback_seconds)
    local ttl = redis.call("PTTL", key)
    if ttl > 0 then
      return ttl
    end
    return fallback_seconds * 1000
  end

  if redis.call("EXISTS", circuit_key) == 1 then
    return {"provider_unavailable", positive_ttl(circuit_key, 1)}
  end

  if cooldown_seconds > 0 and redis.call("EXISTS", cooldown_key) == 1 then
    return {"rate_limited", positive_ttl(cooldown_key, cooldown_seconds)}
  end

  if redis.call("EXISTS", challenge_key) == 1 then
    return {"challenge_collision", 0}
  end

  local email_count = tonumber(redis.call("GET", email_window_key) or "0")
  if email_count >= email_limit then
    return {"rate_limited", positive_ttl(email_window_key, email_window_seconds)}
  end

  local ip_count = tonumber(redis.call("GET", ip_window_key) or "0")
  if ip_count >= ip_limit then
    return {"rate_limited", positive_ttl(ip_window_key, ip_window_seconds)}
  end

  email_count = redis.call("INCR", email_window_key)
  if email_count == 1 then
    redis.call("EXPIRE", email_window_key, email_window_seconds)
  end

  ip_count = redis.call("INCR", ip_window_key)
  if ip_count == 1 then
    redis.call("EXPIRE", ip_window_key, ip_window_seconds)
  end

  if cooldown_seconds > 0 then
    redis.call("SET", cooldown_key, "1", "EX", cooldown_seconds)
  end

  local stored = redis.call(
    "SET",
    challenge_key,
    challenge_json,
    "EX",
    challenge_ttl,
    "NX"
  )

  if not stored then
    return {"challenge_collision", 0}
  end

  return {"ok", 0}
  """

  @consume_script """
  local key = KEYS[1]
  local expected = ARGV[1]
  local max_attempts = tonumber(ARGV[2])
  local raw = redis.call("GET", key)

  if not raw then
    return {"not_found", ""}
  end

  local challenge = cjson.decode(raw)

  if challenge["code_hash"] == expected then
    redis.call("DEL", key)
    return {"ok", raw}
  end

  local attempts = tonumber(challenge["attempts"] or 0) + 1

  if attempts >= max_attempts then
    redis.call("DEL", key)
    return {"too_many_attempts", ""}
  end

  challenge["attempts"] = attempts
  local ttl = redis.call("PTTL", key)

  if ttl > 0 then
    redis.call("SET", key, cjson.encode(challenge), "PX", ttl)
  else
    redis.call("DEL", key)
  end

  return {"invalid_code", ""}
  """

  @verify_script """
  local challenge_key = KEYS[1]
  local failure_window_key = KEYS[2]
  local expected = ARGV[1]
  local max_attempts = tonumber(ARGV[2])
  local failure_limit = tonumber(ARGV[3])
  local failure_window_seconds = tonumber(ARGV[4])
  local raw = redis.call("GET", challenge_key)

  local function positive_ttl(key)
    local ttl = redis.call("PTTL", key)
    if ttl > 0 then
      return ttl
    end
    return failure_window_seconds * 1000
  end

  if not raw then
    return {"not_found", "", 0}
  end

  local challenge = cjson.decode(raw)
  local failures = tonumber(redis.call("GET", failure_window_key) or "0")

  if failures >= failure_limit then
    return {"rate_limited", "", positive_ttl(failure_window_key)}
  end

  if challenge["code_hash"] == expected then
    redis.call("DEL", challenge_key)
    redis.call("DEL", failure_window_key)
    return {"ok", raw, 0}
  end

  local attempts = tonumber(challenge["attempts"] or 0) + 1
  failures = redis.call("INCR", failure_window_key)
  if failures == 1 then
    redis.call("EXPIRE", failure_window_key, failure_window_seconds)
  end

  if attempts >= max_attempts then
    redis.call("DEL", challenge_key)
  else
    challenge["attempts"] = attempts
    local ttl = redis.call("PTTL", challenge_key)
    if ttl > 0 then
      redis.call("SET", challenge_key, cjson.encode(challenge), "PX", ttl)
    else
      redis.call("DEL", challenge_key)
    end
  end

  if failures >= failure_limit then
    return {"rate_limited", "", positive_ttl(failure_window_key)}
  end

  if attempts >= max_attempts then
    return {"too_many_attempts", "", 0}
  end

  return {"invalid_code", "", 0}
  """

  @delivery_failure_script """
  local failure_key = KEYS[1]
  local circuit_key = KEYS[2]
  local threshold = tonumber(ARGV[1])
  local failure_window_seconds = tonumber(ARGV[2])
  local open_seconds = tonumber(ARGV[3])

  if redis.call("EXISTS", circuit_key) == 1 then
    return {"open", redis.call("PTTL", circuit_key)}
  end

  local failures = redis.call("INCR", failure_key)
  if failures == 1 then
    redis.call("EXPIRE", failure_key, failure_window_seconds)
  end

  if failures >= threshold then
    redis.call("SET", circuit_key, "1", "EX", open_seconds)
    return {"open", open_seconds * 1000}
  end

  return {"closed", 0}
  """

  @doc false
  def connection_name, do: @connection_name

  def child_spec(_opts) do
    %{
      id: @connection_name,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker
    }
  end

  def start_link(_opts) do
    Redix.start_link(redis_url(), name: @connection_name)
  end

  @impl true
  def reserve_attempt(%{"id" => id} = challenge, ttl_seconds, opts)
      when is_binary(id) and is_map(opts) do
    keys = [
      google_attempt_peer_window_key(Map.fetch!(opts, :ip_fingerprint)),
      challenge_key(id)
    ]

    args = [
      Jason.encode!(challenge),
      ttl_seconds,
      Map.fetch!(opts, :ip_request_limit),
      Map.fetch!(opts, :ip_request_window_seconds)
    ]

    with_connection(:reserve_attempt, fn conn ->
      case command(
             conn,
             :reserve_attempt,
             ["EVAL", @reserve_attempt_script, Integer.to_string(length(keys))] ++
               keys ++ stringify(args)
           ) do
        {:ok, ["ok", _retry_ms]} ->
          :ok

        {:ok, ["rate_limited", retry_ms]} ->
          {:error, :rate_limited, retry_seconds(retry_ms)}

        {:ok, ["challenge_collision", _retry_ms]} ->
          {:error, :challenge_collision}

        {:ok, [status, _retry_ms]} ->
          {:error, {:unexpected_attempt_reserve_status, status}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  @impl true
  def verify(id, code_hash, max_attempts) when is_binary(id) and is_binary(code_hash) do
    with_connection(:verify_attempt, fn conn ->
      case command(conn, :verify_attempt, [
             "EVAL",
             @consume_script,
             "1",
             challenge_key(id),
             code_hash,
             Integer.to_string(max_attempts)
           ]) do
        {:ok, ["ok", raw]} -> {:ok, Jason.decode!(raw)}
        {:ok, ["not_found", _raw]} -> {:error, :not_found}
        {:ok, ["invalid_code", _raw]} -> {:error, :invalid_code}
        {:ok, ["too_many_attempts", _raw]} -> {:error, :too_many_attempts}
        {:ok, [status, _raw]} -> {:error, status}
        {:error, _reason} = error -> error
      end
    end)
  end

  @impl true
  def reserve(
        %{"id" => id, "email_fingerprint" => email_fingerprint} = challenge,
        ttl_seconds,
        opts
      )
      when is_binary(id) and is_binary(email_fingerprint) and is_map(opts) do
    keys = [
      circuit_key(),
      cooldown_key(email_fingerprint),
      email_window_key(email_fingerprint),
      ip_window_key(Map.fetch!(opts, :ip_fingerprint)),
      challenge_key(id)
    ]

    args = [
      Jason.encode!(challenge),
      ttl_seconds,
      Map.fetch!(opts, :resend_cooldown_seconds),
      Map.fetch!(opts, :email_request_limit),
      Map.fetch!(opts, :email_request_window_seconds),
      Map.fetch!(opts, :ip_request_limit),
      Map.fetch!(opts, :ip_request_window_seconds)
    ]

    with_connection(:reserve, fn conn ->
      case command(
             conn,
             :reserve,
             ["EVAL", @reserve_script, Integer.to_string(length(keys))] ++ keys ++ stringify(args)
           ) do
        {:ok, ["ok", _retry_ms]} ->
          :ok

        {:ok, ["rate_limited", retry_ms]} ->
          {:error, :rate_limited, retry_seconds(retry_ms)}

        {:ok, ["provider_unavailable", retry_ms]} ->
          {:error, :provider_unavailable, retry_seconds(retry_ms)}

        {:ok, ["challenge_collision", _retry_ms]} ->
          {:error, :challenge_collision}

        {:ok, [status, _retry_ms]} ->
          {:error, {:unexpected_reserve_status, status}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  @impl true
  def verify(id, code_hash, max_attempts, opts)
      when is_binary(id) and is_binary(code_hash) and is_map(opts) do
    with_connection(:verify, fn conn ->
      with {:ok, raw} when is_binary(raw) <-
             command(conn, :verify, ["GET", challenge_key(id)]),
           {:ok, %{"email_fingerprint" => email_fingerprint}}
           when is_binary(email_fingerprint) and email_fingerprint != "" <- Jason.decode(raw) do
        keys = [challenge_key(id), verification_window_key(email_fingerprint)]

        args = [
          code_hash,
          max_attempts,
          Map.fetch!(opts, :verification_failure_limit),
          Map.fetch!(opts, :verification_failure_window_seconds)
        ]

        case command(
               conn,
               :verify,
               ["EVAL", @verify_script, "2"] ++ keys ++ stringify(args)
             ) do
          {:ok, [status, result_raw, retry_ms]} -> decode_verify(status, result_raw, retry_ms)
          {:error, _reason} = error -> error
        end
      else
        {:ok, nil} -> {:error, :not_found}
        {:ok, _invalid} -> {:error, :invalid_challenge}
        {:error, %Jason.DecodeError{}} -> {:error, :invalid_challenge}
        {:error, _reason} = error -> error
      end
    end)
  end

  @impl true
  def record_delivery(:ok, _opts) do
    with_connection(:record_delivery, fn conn ->
      case command(conn, :record_delivery, ["DEL", delivery_failure_key(), circuit_key()]) do
        {:ok, _count} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  def record_delivery(:error, opts) when is_map(opts) do
    args = [
      Map.fetch!(opts, :provider_failure_threshold),
      Map.fetch!(opts, :provider_failure_window_seconds),
      Map.fetch!(opts, :provider_circuit_open_seconds)
    ]

    with_connection(:record_delivery, fn conn ->
      case command(
             conn,
             :record_delivery,
             ["EVAL", @delivery_failure_script, "2", delivery_failure_key(), circuit_key()] ++
               stringify(args)
           ) do
        {:ok, ["closed", _retry_ms]} -> :ok
        {:ok, ["open", _retry_ms]} -> {:ok, :circuit_open}
        {:ok, [status, _retry_ms]} -> {:error, {:unexpected_circuit_status, status}}
        {:error, _reason} = error -> error
      end
    end)
  end

  @impl true
  def delete(id) when is_binary(id) do
    with_connection(:delete, fn conn ->
      case command(conn, :delete, ["DEL", challenge_key(id)]) do
        {:ok, _count} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  defp decode_verify("ok", raw, _retry_ms), do: {:ok, Jason.decode!(raw)}
  defp decode_verify("not_found", _raw, _retry_ms), do: {:error, :not_found}
  defp decode_verify("invalid_code", _raw, _retry_ms), do: {:error, :invalid_code}
  defp decode_verify("too_many_attempts", _raw, _retry_ms), do: {:error, :too_many_attempts}

  defp decode_verify("rate_limited", _raw, retry_ms),
    do: {:error, :rate_limited, retry_seconds(retry_ms)}

  defp decode_verify(other, _raw, _retry_ms), do: {:error, other}

  defp with_connection(operation, fun) do
    case Process.whereis(@connection_name) do
      nil -> observe_failure(operation, {:error, :redis_unavailable})
      _pid -> fun.(@connection_name)
    end
  end

  defp command(connection, operation, redis_command) do
    case Redix.command(connection, redis_command) do
      {:error, _reason} = error -> observe_failure(operation, error)
      result -> result
    end
  rescue
    _error -> observe_failure(operation, {:error, :redis_unavailable})
  catch
    :exit, _reason -> observe_failure(operation, {:error, :redis_unavailable})
  end

  defp redis_url do
    System.get_env("REDIS_URL") ||
      System.get_env("COMMA_REDIS_URL") ||
      get_in(Application.get_env(:comma_core, :auth, []), [:redis_url]) ||
      "redis://127.0.0.1:6379/0"
  end

  defp observe_failure(operation, error) do
    :telemetry.execute(
      [:comma, :auth_challenge, :redis, :error],
      %{count: 1},
      %{operation: operation}
    )

    error
  end

  defp prefix do
    get_in(Application.get_env(:comma_core, :auth, []), [:redis_key_prefix]) || "comma:auth:v1"
  end

  defp challenge_key(id), do: join("challenge", id)
  defp cooldown_key(fingerprint), do: join("request:cooldown", fingerprint)
  defp email_window_key(fingerprint), do: join("request:email", fingerprint)
  defp ip_window_key(fingerprint), do: join("request:ip", fingerprint)
  defp verification_window_key(fingerprint), do: join("verify:email", fingerprint)
  defp google_attempt_peer_window_key(fingerprint), do: join("google_attempt:peer", fingerprint)
  defp delivery_failure_key, do: join("delivery", "failures")
  defp circuit_key, do: join("delivery", "circuit")
  defp join(scope, value), do: Enum.join([prefix(), scope, value], ":")

  defp stringify(values), do: Enum.map(values, &to_string/1)

  defp retry_seconds(milliseconds) when is_integer(milliseconds) and milliseconds > 0,
    do: max(div(milliseconds + 999, 1_000), 1)

  defp retry_seconds(_milliseconds), do: 1
end
