defmodule SalixAgent.Tools.Gree do
  @moduledoc """
  `device.gree_request`: read or set the state of a Gree air conditioner on
  the user's network, sent through a LAN gateway's `udp_request`. Salix
  encrypts and decrypts (`SalixAgent.LanCodec.Gree`); the gateway only carries
  the datagrams.

  One call is three exchanges with the device: a scan that returns its `mac`
  and cipher, a bind that returns its key, and the status or command. Nothing
  is kept between calls. The key is used only as the codec key, so it never
  enters the call, its result or the transcript.

  A module that answers the scan with the older cipher can still require the
  newer one to bind, so a bind without an answer is sent once more with it.
  """

  alias SalixAgent.LanCodec.Gree
  alias SalixAgent.Tools.LanGateway

  @timeout_ms 2_000
  @max_columns 24
  @column ~r/\A[A-Za-z0-9]{1,24}\z/

  def defs do
    [
      {"device.gree_request",
       "Read or set the state of a Gree air conditioner (UDP 7000) on the user's network, through a gateway device whose lan_gateway methods include udp_request. Give status with the columns to read, such as Pow, Mod, SetTem and WdSpd, or set with the columns to change and their integer values. The platform binds to the unit itself; no key is needed. Returns the unit's name and the values it reports. Read the state back after a change.",
       schema(), &__MODULE__.request/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(), [safety: "write"]}
    ]
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ~w(device_id host),
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" => "Gateway device_id from device.list or device.get."
        },
        "host" => %{
          "type" => "string",
          "description" => "IP address of the air conditioner on the gateway's network."
        },
        "status" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_columns,
          "items" => %{"type" => "string"},
          "description" => "Columns to read. Give status or set, not both."
        },
        "set" => %{
          "type" => "object",
          "minProperties" => 1,
          "maxProperties" => @max_columns,
          "additionalProperties" => %{"type" => "integer"},
          "description" => "Columns to change, each with its integer value."
        }
      }
    }
  end

  @doc false
  def request(args, ctx) do
    device_id = required!(args, "device_id")
    host = required!(args, "host")
    build = operation!(args)

    with {:ok, unit} <- scan(device_id, host, ctx),
         {:ok, key, cipher} <- bind(device_id, host, unit, ctx),
         {:ok, values} <- run(device_id, host, unit.mac, key, build.(unit.mac, key, cipher), ctx) do
      %{"host" => host, "mac" => unit.mac, "values" => values}
      |> put_present("name", unit[:name])
      |> put_present("model", unit[:model])
      |> Jason.encode!()
    end
  end

  defp operation!(%{"status" => _, "set" => _}), do: raise("give status or set, not both")

  defp operation!(%{"status" => cols}) when is_list(cols) and cols != [] do
    columns!(cols)
    &Gree.status(&1, &2, &3, cols)
  end

  defp operation!(%{"set" => set}) when is_map(set) and map_size(set) > 0 do
    {opt, p} = set |> Enum.sort() |> Enum.unzip()
    columns!(opt)
    unless Enum.all?(p, &is_integer/1), do: raise("set values must be integers")
    &Gree.command(&1, &2, &3, opt, p)
  end

  defp operation!(_args), do: raise("give status (columns to read) or set (columns to change)")

  defp columns!(names) do
    unless length(names) <= @max_columns and
             Enum.all?(names, &(is_binary(&1) and Regex.match?(@column, &1))),
           do: raise("columns must be at most #{@max_columns} names of letters and digits")
  end

  defp scan(device_id, host, ctx) do
    case exchange(device_id, host, Gree.scan(), ctx) do
      {:ok, nil} ->
        LanGateway.failure(
          device_id,
          "device_not_answering",
          "The device at #{host} is not answering on UDP #{Gree.port()}. Check the address with device.lan_discover and that the unit has power."
        )

      {:ok, reply} ->
        with {:error, :malformed} <- Gree.parse_scan(reply), do: malformed(device_id, host)

      failure ->
        failure
    end
  end

  defp bind(device_id, host, unit, ctx) do
    ciphers = if unit.cipher == :ecb, do: [:ecb, :gcm], else: [:gcm]

    Enum.reduce_while(ciphers, nil, fn cipher, _previous ->
      case exchange(device_id, host, Gree.bind(unit.mac, cipher), ctx) do
        {:ok, nil} ->
          {:cont,
           LanGateway.failure(
             device_id,
             "device_bind_failed",
             "The unit at #{host} did not answer the bind request, so it cannot be controlled from this network. Its Wi-Fi module may only accept its own app."
           )}

        {:ok, reply} ->
          case Gree.parse_bind(reply, unit.mac) do
            {:ok, key} -> {:halt, {:ok, key, cipher}}
            {:error, :malformed} -> {:halt, malformed(device_id, host)}
          end

        failure ->
          {:halt, failure}
      end
    end)
  end

  defp run(device_id, host, mac, key, packet, ctx) do
    case exchange(device_id, host, packet, ctx) do
      {:ok, nil} ->
        LanGateway.failure(
          device_id,
          "device_no_reply",
          "The unit did not answer the request. A change may have been applied. Read its state before retrying."
        )

      {:ok, reply} ->
        case Gree.parse_reply(reply, mac, key) do
          {:ok, values} ->
            {:ok, values}

          {:error, {:refused, code}} ->
            LanGateway.failure(
              device_id,
              "device_error",
              "The unit refused the request with code #{code}."
            )

          {:error, :malformed} ->
            malformed(device_id, host)
        end

      failure ->
        failure
    end
  end

  # Each request leaves from a fresh gateway socket, so the first answer from
  # the host belongs to it.
  defp exchange(device_id, host, packet, ctx) do
    params = %{
      "host" => host,
      "port" => Gree.port(),
      "payload_b64" => Base.encode64(packet),
      "timeout_ms" => @timeout_ms,
      "max_responses" => 1
    }

    with {:ok, %{"responses" => responses}} <- LanGateway.udp_request(device_id, ctx, params) do
      case responses do
        # Bytes that are not base64 read as a malformed reply.
        [%{"payload_b64" => payload} | _] -> {:ok, payload |> Base.decode64() |> elem_or("")}
        _ -> {:ok, nil}
      end
    end
  end

  defp elem_or({:ok, bytes}, _default), do: bytes
  defp elem_or(:error, default), do: default

  defp malformed(device_id, host),
    do:
      LanGateway.failure(
        device_id,
        "device_reply_malformed",
        "The device at #{host} answered with a packet that is not the Gree protocol."
      )

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp required!(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "#{key} is required"
    end
  end
end
