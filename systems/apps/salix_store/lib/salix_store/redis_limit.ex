defmodule SalixStore.RedisLimit do
  @moduledoc """
  Rate limits kept in Redis, shared by every pod, on the Redis connection that
  a `Hammer.Redis` limiter supervises.

  Every limit reads the application's clock (`SystemsClock`, the machine's in
  production): each request carries the time it was made, and the script
  counts on it. Under a test clock a limit moves only as that clock does.
  Neither Redis's `TIME` nor Hammer's own scripts are used: they read a clock
  no test controls.

  A sliding window names each admitted request by its time and its place in
  the window. Requests at one time see the window grow by each one admitted
  before them, so no two admitted requests share a name (Hammer.Redis 7.1
  names them by time alone: a burst at one time counted once).
  """

  @sliding_window """
  local key = KEYS[1]
  local window = tonumber(ARGV[1]) * 1000
  local limit = tonumber(ARGV[2])
  local now = tonumber(ARGV[3])
  redis.call("ZREMRANGEBYSCORE", key, "-inf", now - window)
  local count = tonumber(redis.call("ZCARD", key))
  if count < limit then
    redis.call("ZADD", key, now, ARGV[3] .. "." .. (count + 1))
    redis.call("PEXPIRE", key, ARGV[1])
    return {1, count + 1}
  else
    local oldest = tonumber(redis.call("ZRANGE", key, 0, 0, "WITHSCORES")[2])
    return {0, math.ceil((oldest + window - now) / 1000)}
  end
  """

  # A bucket holds `level` tokens as of `at` (milliseconds). Whole tokens are
  # credited for the time since `at`, and `at` moves on by the time they took,
  # so a request between two tokens does not lose the part already earned. A
  # full bucket earns nothing more: its `at` is the request's time.
  @token_bucket """
  local key = KEYS[1]
  local capacity = tonumber(ARGV[1])
  local rate = tonumber(ARGV[2])
  local cost = tonumber(ARGV[3])
  local now = tonumber(ARGV[4])
  local bucket = redis.call("HMGET", key, "level", "at")
  local level = tonumber(bucket[1]) or capacity
  local at = tonumber(bucket[2]) or now
  local credited = math.floor(math.max(0, now - at) * rate / 1000)
  local tokens = level + credited
  if tokens >= capacity then
    tokens = capacity
    at = now
  else
    at = at + credited * 1000 / rate
  end
  if tokens >= cost then
    local left = tokens - cost
    redis.call("HSET", key, "level", left, "at", at)
    redis.call("PEXPIRE", key, math.ceil((capacity - left) * 1000 / rate) + 60000)
    return {1, left}
  else
    return {0, math.ceil(at + (cost - tokens) * 1000 / rate - now)}
  end
  """

  @doc """
  Admits one request to `key` when fewer than `limit` requests are in its
  window of `window_ms`: `{:allow, count}` or `{:deny, retry_after_ms}`.
  `connection` is the name of the limiter module, whose Redis connection it
  uses.
  """
  @spec sliding_window(atom(), String.t(), String.t(), pos_integer(), pos_integer(), timeout()) ::
          {:allow, pos_integer()} | {:deny, integer()}
  def sliding_window(connection, prefix, key, window_ms, limit, timeout) do
    now = SystemsClock.system_time(:microsecond)

    {:ok, reply} =
      Redix.command(
        connection,
        sliding_window_command(prefix, key, window_ms, limit, now),
        timeout: timeout
      )

    decision(reply)
  end

  @doc """
  The Redis command for one sliding-window request made at `now`
  (microseconds of the application's clock), whose reply `decision/1` reads.
  """
  @spec sliding_window_command(String.t(), String.t(), pos_integer(), pos_integer(), integer()) ::
          [String.t() | integer()]
  def sliding_window_command(prefix, key, window_ms, limit, now),
    do: ["EVAL", @sliding_window, "1", "#{prefix}:#{key}:#{window_ms}", window_ms, limit, now]

  @doc """
  Takes `cost` tokens from the bucket `key`, which holds at most `capacity`
  and gains `rate` tokens a second: `{:allow, tokens_left}` or
  `{:deny, retry_after_ms}`. `connection` is the name of the limiter module,
  whose Redis connection it uses.
  """
  @spec token_bucket(
          atom(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          timeout()
        ) :: {:allow, non_neg_integer()} | {:deny, integer()}
  def token_bucket(connection, prefix, key, rate, capacity, cost, timeout) do
    now = SystemsClock.system_time(:millisecond)

    {:ok, reply} =
      Redix.command(
        connection,
        ["EVAL", @token_bucket, "1", "#{prefix}:#{key}", capacity, rate, cost, now],
        timeout: timeout
      )

    decision(reply)
  end

  @doc false
  def decision([1, count]), do: {:allow, count}
  def decision([0, retry_after_ms]), do: {:deny, retry_after_ms}
end
