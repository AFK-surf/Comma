defmodule SalixAgent.LanCodec do
  @moduledoc """
  Encrypted local device protocols that Salix speaks through a LAN gateway's
  `udp_request` (miIO now; Gree and Tuya local next). The cloud holds the
  crypto; the gateway only carries datagrams.

  A codec builds a hello (or none), reads the device session out of the
  hello reply, and encodes requests and decodes replies with the device key.
  `request/6` drives one exchange: hello when no session is cached, then the
  command. Sessions (never keys) are cached per `{gateway, host}` for
  60 seconds. A command without a matching reply invalidates the session.
  Commands are never replayed automatically. Read device state before retrying.
  """

  alias SalixAgent.Tools.LanGateway

  @type session :: %{required(:stamp) => non_neg_integer(), optional(atom()) => term()}

  @callback port() :: pos_integer()
  @callback hello() :: binary() | nil
  @callback parse_hello(binary()) :: {:ok, session()} | {:error, :malformed}
  @callback key(String.t()) :: {:ok, binary()} | {:error, :bad_token}
  @callback encode(request :: map(), key :: binary(), session()) :: binary()
  @callback decode(binary(), key :: binary()) ::
              {:ok, map(), session()} | {:error, :checksum | :malformed}

  @table :salix_agent_lan_codec_sessions
  @session_ttl_ms 60_000
  @hello_timeout_ms 2_000
  @command_timeout_ms 3_000
  # The gateway collects this bounded batch on one socket, with one send and
  # one deadline. Its receive budget is 16 packets or 64 KiB, whichever comes first.
  @command_max_responses 16
  @max_sessions 1_024

  @doc false
  def create_table, do: SystemsRuntime.ETS.new(@table, [:named_table, :public, :set])

  @doc """
  Send `request` (a map with `"method"` and `"params"`) to `host` through the
  gateway `device_id` and return `{:ok, reply}` with the decoded reply, or the
  tool failure to return. Message ids come from one node-wide counter, so
  concurrent requests to a device never repeat an id that the device would
  answer from its cache.
  """
  def request(codec, device_id, host, key, request, ctx) do
    cache_key = {codec, device_id, host}

    case cached(cache_key) do
      {:ok, session} ->
        codec
        |> command(device_id, host, key, request, session, ctx)
        |> finish(cache_key, device_id)

      :miss ->
        fresh(codec, cache_key, device_id, host, key, request, ctx)
    end
  end

  defp fresh(codec, cache_key, device_id, host, key, request, ctx) do
    with {:ok, session} <- handshake(codec, device_id, host, ctx) do
      codec
      |> command(device_id, host, key, request, session, ctx)
      |> finish(cache_key, device_id)
    end
  end

  defp handshake(codec, device_id, host, ctx) do
    session = %{stamp: 0, at: now()}

    case codec.hello() do
      nil ->
        {:ok, session}

      hello ->
        case exchange(device_id, host, codec.port(), hello, @hello_timeout_ms, 1, ctx) do
          {:ok, []} ->
            failure(
              device_id,
              "device_not_answering",
              "The device at #{host} is not answering on UDP #{codec.port()}. Check the address with device.lan_discover and that the device is powered."
            )

          {:ok, [reply | _]} ->
            with {:ok, bytes} <- Base.decode64(reply["payload_b64"]),
                 {:ok, parsed} <- codec.parse_hello(bytes) do
              {:ok, Map.merge(session, parsed)}
            else
              _ -> malformed(device_id, host)
            end

          failure ->
            failure
        end
    end
  end

  defp command(codec, device_id, host, key, request, session, ctx) do
    elapsed = div(now() - session.at, 1_000)
    request = Map.put(request, "id", next_id())
    packet = codec.encode(request, key, %{session | stamp: session.stamp + elapsed + 1})

    case exchange(
           device_id,
           host,
           codec.port(),
           packet,
           @command_timeout_ms,
           @command_max_responses,
           ctx
         ) do
      {:ok, replies} ->
        Enum.reduce_while(replies, {:no_reply, session}, fn reply, outcome ->
          decoded =
            with {:ok, bytes} <- Base.decode64(reply["payload_b64"]),
                 do: codec.decode(bytes, key)

          case decoded do
            {:ok, payload, parsed} ->
              # The sent request owns the message id. The hello owns the device
              # id. A stale or other-device packet must not complete this command
              # or replace the cached session, even with a valid checksum.
              if payload["id"] == request["id"] and parsed[:device_id] == session[:device_id] do
                {:halt, {:ok, payload, Map.merge(session, parsed)}}
              else
                {:cont, outcome}
              end

            {:error, :checksum} ->
              {:cont,
               failure(
                 device_id,
                 "bad_token",
                 "The saved token could not verify the reply. Ask the user to check the token and save it with device.secret_save."
               )}

            _ ->
              {:cont, malformed(device_id, host)}
          end
        end)

      failure ->
        failure
    end
  end

  defp finish({:ok, payload, session}, cache_key, device_id) do
    remember(cache_key, %{session | at: now()})

    case payload do
      %{"error" => error} ->
        code = if is_map(error), do: error["code"]
        message = if is_map(error), do: error["message"], else: error

        failure(
          device_id,
          "device_error",
          "The device answered with an error#{if code, do: " #{code}"}: #{String.slice(to_string(message), 0, 300)}"
        )

      _ ->
        {:ok, payload}
    end
  end

  defp finish({:no_reply, _session}, cache_key, device_id) do
    SystemsRuntime.ETS.delete(@table, cache_key)

    failure(
      device_id,
      "device_no_reply",
      "The device did not return a matching command reply. The command may have executed. Read its state before retrying."
    )
  end

  defp finish(failure, cache_key, _device_id) do
    SystemsRuntime.ETS.delete(@table, cache_key)
    failure
  end

  defp exchange(device_id, host, port, packet, timeout_ms, max_responses, ctx) do
    params = %{
      "host" => host,
      "port" => port,
      "payload_b64" => Base.encode64(packet),
      "timeout_ms" => timeout_ms,
      "max_responses" => max_responses
    }

    with {:ok, %{"responses" => responses}} <- LanGateway.udp_request(device_id, ctx, params) do
      {:ok, responses}
    end
  end

  defp malformed(device_id, host),
    do:
      failure(
        device_id,
        "device_reply_malformed",
        "The device at #{host} answered with a packet this protocol does not recognize."
      )

  defp failure(device_id, code, message), do: LanGateway.failure(device_id, code, message)

  defp cached(cache_key) do
    case SystemsRuntime.ETS.lookup(@table, cache_key) do
      [{^cache_key, session, expires_at}] ->
        if now() < expires_at, do: {:ok, session}, else: :miss

      [] ->
        :miss
    end
  end

  defp remember(cache_key, session) do
    if SystemsRuntime.ETS.info(@table, :size) >= @max_sessions do
      now = now()
      SystemsRuntime.ETS.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])

      if SystemsRuntime.ETS.info(@table, :size) >= @max_sessions,
        do: SystemsRuntime.ETS.delete_all_objects(@table)
    end

    SystemsRuntime.ETS.insert(@table, {cache_key, session, now() + @session_ttl_ms})
  end

  # miIO ids run from 1 to 9999.
  defp next_id, do: rem(SystemsRuntime.Proc.unique_integer([:positive, :monotonic]), 9_999) + 1

  defp now, do: SystemsClock.monotonic_time(:millisecond)
end
