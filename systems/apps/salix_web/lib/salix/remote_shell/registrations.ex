defmodule Salix.RemoteShell.Registrations do
  @moduledoc "Expiring registration handoffs. Redis owns first submission and claim transitions."

  @connection __MODULE__.Redis
  @prefix "salix:remote-shell:registration:v1:"
  @timeout 2_000

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :worker}
  end

  def start_link(_opts) do
    Redix.start_link(Application.fetch_env!(:salix_web, :site_rate_limit_redis_url),
      name: @connection
    )
  end

  def create(id, expires) do
    row = Jason.encode!(%{status: "pending", expires_at: expires})

    case command(["SET", key(id), row, "NX", "EXAT", Integer.to_string(expires)]) do
      {:ok, "OK"} -> :ok
      {:ok, nil} -> {:error, :registration_conflict}
      error -> error
    end
  end

  def get(id) do
    with {:ok, value} <- command(["GET", key(id)]), do: decode(value)
  end

  def submit(id, device_key, expires) do
    eval(
      id,
      """
      local raw = redis.call('GET', KEYS[1])
      if not raw then return nil end
      local row = cjson.decode(raw)
      if row.status == 'cancelled' then return 'cancelled' end
      if tonumber(ARGV[2]) ~= row.expires_at then return 'conflict' end
      if row.device_key then
        if row.device_key == ARGV[1] then return raw else return 'conflict' end
      end
      row.device_key = ARGV[1]
      row.status = 'submitted'
      raw = cjson.encode(row)
      redis.call('SET', KEYS[1], raw, 'KEEPTTL')
      return raw
      """,
      [device_key, expires]
    )
  end

  def claim(id, owner) do
    eval(
      id,
      """
      local raw = redis.call('GET', KEYS[1])
      if not raw then return nil end
      local row = cjson.decode(raw)
      local now = tonumber(redis.call('TIME')[1])
      if row.status == 'submitted' or
         (row.status == 'registering' and row.claim_expires_at <= now) then
        row.status = 'registering'
        row.claim = ARGV[1]
        row.claim_expires_at = math.min(row.expires_at, now + 90)
        raw = cjson.encode(row)
        redis.call('SET', KEYS[1], raw, 'KEEPTTL')
      end
      return raw
      """,
      [owner]
    )
  end

  def finish(id, owner, result) do
    encoded =
      case result do
        {:ok, value} -> Jason.encode!(value)
        _ -> ""
      end

    eval(
      id,
      """
      local raw = redis.call('GET', KEYS[1])
      if not raw then return nil end
      local row = cjson.decode(raw)
      if row.status == 'cancelled' then return 'cancelled' end
      if row.claim ~= ARGV[1] then return 'conflict' end
      row.claim = nil
      row.claim_expires_at = nil
      if ARGV[2] == '' then
        row.status = 'submitted'
      else
        row.status = 'ready'
        row.result = cjson.decode(ARGV[2])
      end
      raw = cjson.encode(row)
      redis.call('SET', KEYS[1], raw, 'KEEPTTL')
      return raw
      """,
      [owner, encoded]
    )
  end

  def cancel(id) do
    eval(
      id,
      """
      local raw = redis.call('GET', KEYS[1])
      if not raw then return nil end
      local row = cjson.decode(raw)
      row.status = 'cancelled'
      raw = cjson.encode(row)
      redis.call('SET', KEYS[1], raw, 'KEEPTTL')
      return raw
      """,
      []
    )
  end

  def active?(id, device_key) do
    case get(id) do
      {:ok, %{"status" => "ready", "device_key" => ^device_key}} -> :ok
      {:ok, _} -> {:error, :registration_cancelled}
      error -> error
    end
  end

  def notify(id),
    do: Phoenix.PubSub.broadcast(SalixWeb.PubSub, topic(id), {:remote_shell_registration, id})

  def subscribe(id), do: Phoenix.PubSub.subscribe(SalixWeb.PubSub, topic(id))
  def unsubscribe(id), do: Phoenix.PubSub.unsubscribe(SalixWeb.PubSub, topic(id))
  defp topic(id), do: "remote-shell-registration:" <> id
  defp key(id), do: @prefix <> id

  defp eval(id, script, args) do
    with {:ok, value} <- command(["EVAL", script, "1", key(id) | Enum.map(args, &to_string/1)]),
         do: decode(value)
  end

  defp decode(nil), do: {:error, :registration_expired}
  defp decode("cancelled"), do: {:error, :registration_cancelled}
  defp decode("conflict"), do: {:error, :registration_conflict}
  defp decode(value), do: Jason.decode(value)

  defp command(args) do
    case Redix.command(@connection, args, timeout: @timeout) do
      {:ok, _} = result -> result
      _ -> {:error, :registration_store_unavailable}
    end
  catch
    :exit, _ -> {:error, :registration_store_unavailable}
  end
end
