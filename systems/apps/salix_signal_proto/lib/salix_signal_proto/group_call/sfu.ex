defmodule SalixSignalProto.GroupCall.Sfu do
  @moduledoc """
  Bodies of the group-call HTTP API (CRS-14 sections 4.1 and 5): the
  membership token response of the storage service and the SFU's peek and
  join exchanges. The HTTP client is `SalixSignal.GroupCall.Sfu`.

  A peek is `%{era_id, max_devices, creator, devices, pending}`. Each device
  is `%{demux_id, opaque_user_id, requires_svc}`. A group with no active
  call peeks as `era_id: nil` and no devices.
  """

  alias SalixSignalProto.GroupCall.Wire

  @type device :: %{
          demux_id: non_neg_integer(),
          opaque_user_id: String.t() | nil,
          requires_svc: boolean()
        }
  @type peek :: %{
          era_id: String.t() | nil,
          max_devices: non_neg_integer() | nil,
          creator: String.t() | nil,
          devices: [device()],
          pending: [device()]
        }
  @type join :: %{
          demux_id: non_neg_integer(),
          udp: [{:inet.ip_address(), :inet.port_number()}],
          tcp: [{:inet.ip_address(), :inet.port_number()}],
          tls: [{:inet.ip_address(), :inet.port_number()}],
          hostname: String.t() | nil,
          ice_ufrag: String.t(),
          ice_pwd: String.t(),
          public_key: <<_::256>>,
          creator: String.t(),
          era_id: String.t(),
          status: :active | :pending | :blocked
        }

  @max_u32 0xFFFFFFFF

  @doc "The path of the SFU resource under the base URL (section 5.1)."
  def path, do: "/v2/conference/participants"

  @doc "The storage-service path of the membership token (section 4.1)."
  def token_path, do: "/v2/groups/token"

  @doc "The membership token from the storage-service response body. It contains a `:`."
  @spec decode_token(binary()) :: {:ok, String.t()} | {:error, :invalid}
  def decode_token(body) when is_binary(body) do
    case Wire.TokenResponse.decode(body) do
      %Wire.TokenResponse{token: token} when is_binary(token) ->
        if String.contains?(token, ":"), do: {:ok, token}, else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  @doc "Encodes a token response. The fake storage service in tests uses it."
  @spec encode_token(String.t()) :: binary()
  def encode_token(token), do: Wire.TokenResponse.encode(%Wire.TokenResponse{token: token})

  # -- Peek (sections 5.2, 5.3) ------------------------------------------------

  @doc """
  Reads a peek response. 200 with a JSON body is a peek; 404 with an empty
  body means no call. A 404 with a JSON body belongs to call links and is an
  error here, like any other status.
  """
  @spec decode_peek(non_neg_integer(), binary()) :: {:ok, peek()} | {:error, term()}
  def decode_peek(200, body) do
    with {:ok, %{} = json} <- json(body),
         {:ok, devices} <- devices(json["participants"] || []),
         {:ok, pending} <- devices(json["pendingClients"] || []) do
      {:ok,
       %{
         era_id: string(json["conferenceId"]),
         max_devices: uint(json["maxDevices"]),
         creator: string(json["creator"]),
         devices: devices,
         pending: pending
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  def decode_peek(404, ""), do: {:ok, no_call()}
  def decode_peek(404, _body), do: {:error, :call_link}
  def decode_peek(status, _body), do: {:error, {:status, status}}

  @doc "The peek of a group without an active call."
  @spec no_call() :: peek()
  def no_call, do: %{era_id: nil, max_devices: nil, creator: nil, devices: [], pending: []}

  defp devices(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"demuxId" => demux} = entry, {:ok, acc} when is_integer(demux) and demux in 0..@max_u32 ->
        device = %{
          demux_id: demux,
          opaque_user_id: string(entry["opaqueUserId"]),
          requires_svc: entry["requiresSvc"] == true
        }

        {:cont, {:ok, [device | acc]}}

      _entry, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, devices} -> {:ok, Enum.reverse(devices)}
      :error -> :error
    end
  end

  defp devices(_list), do: :error

  # -- Join (section 5.4) ------------------------------------------------------

  @doc """
  The JSON body of a join. `public_key` is the client's fresh 32-byte
  X25519 public key; `extra` the HKDF extra info (empty for group calls).
  An audio-only client does not ask for SVC video.
  """
  @spec join_body(%{
          required(:ice_ufrag) => String.t(),
          required(:ice_pwd) => String.t(),
          required(:public_key) => <<_::256>>,
          optional(:extra) => binary()
        }) :: map()
  def join_body(%{ice_ufrag: ufrag, ice_pwd: pwd, public_key: <<_::binary-32>> = key} = args) do
    %{
      "iceUfrag" => ufrag,
      "icePwd" => pwd,
      "dhePublicKey" => Base.encode16(key, case: :lower),
      "hkdfExtraInfo" => Base.encode16(Map.get(args, :extra, ""), case: :lower),
      "requiresSvc" => false
    }
  end

  @doc """
  Reads a join response. 413 means the call is full. An unknown
  `clientStatus` reads as `:pending`.
  """
  @spec decode_join(non_neg_integer(), binary()) :: {:ok, join()} | {:error, term()}
  def decode_join(200, body) do
    with {:ok, %{} = json} <- json(body),
         demux when is_integer(demux) and demux in 0..@max_u32 <- json["demuxId"],
         ufrag when is_binary(ufrag) <- json["iceUfrag"],
         pwd when is_binary(pwd) <- json["icePwd"],
         {:ok, <<_::binary-32>> = key} <- hex(json["dhePublicKey"]),
         era when is_binary(era) <- json["conferenceId"],
         {:ok, udp} <- addresses(json["udpAddresses"]),
         {:ok, tcp} <- addresses(json["tcpAddresses"]),
         {:ok, tls} <- addresses(json["tlsAddresses"]) do
      {:ok,
       %{
         demux_id: demux,
         udp: udp,
         tcp: tcp,
         tls: tls,
         hostname: string(json["hostname"]),
         ice_ufrag: ufrag,
         ice_pwd: pwd,
         public_key: key,
         creator: string(json["callCreator"]) || "",
         era_id: era,
         status: client_status(json["clientStatus"])
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  def decode_join(413, _body), do: {:error, :full}
  def decode_join(status, _body), do: {:error, {:status, status}}

  defp client_status("ACTIVE"), do: :active
  defp client_status("BLOCKED"), do: :blocked
  defp client_status(_status), do: :pending

  @doc """
  The SFU's UDP ICE candidates from a join response (section 6.1): one host
  candidate on component 1 for every UDP address, in the RFC 8839 grammar
  with the `candidate:` prefix. TCP and TLS addresses are not offered: the
  ICE agent of this client runs over UDP.
  """
  @spec udp_candidates(join()) :: [String.t()]
  def udp_candidates(%{udp: udp}) do
    udp
    |> Enum.with_index(1)
    |> Enum.map(fn {{ip, port}, index} ->
      # Earlier addresses get higher priority (RFC 8445 section 5.1.2).
      priority = 2_130_706_431 - index

      "candidate:#{index} 1 udp #{priority} #{:inet.ntoa(ip)} #{port} typ host"
    end)
  end

  defp addresses(nil), do: {:ok, []}

  defp addresses(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case address(entry) do
        {:ok, address} -> {:cont, {:ok, [address | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  defp addresses(_list), do: :error

  # `a.b.c.d:port` or `[v6]:port`.
  defp address(entry) when is_binary(entry) do
    {host, port} =
      case Regex.run(~r/\A\[([^\]]+)\]:(\d+)\z/, entry) do
        [_, host, port] ->
          {host, port}

        nil ->
          case String.split(entry, ":") do
            [host, port] -> {host, port}
            _ -> {nil, nil}
          end
      end

    with true <- is_binary(host),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(host)),
         {port, ""} when port in 1..65_535 <- Integer.parse(port) do
      {:ok, {ip, port}}
    else
      _ -> :error
    end
  end

  defp address(_entry), do: :error

  # -- Helpers -----------------------------------------------------------------

  defp json(body) do
    case JSON.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> :error
    end
  end

  defp hex(value) when is_binary(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp hex(_value), do: :error

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp uint(value) when is_integer(value) and value >= 0, do: value
  defp uint(_value), do: nil
end
