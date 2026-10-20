defmodule SalixAgent.LanProbes do
  @moduledoc """
  The local device protocols that `device.lan_discover` recognizes, and what
  the Agent can do with a device that speaks one.

  Many home devices announce nothing through mDNS or SSDP, but answer one
  small datagram on their own UDP port. A gateway that advertises
  `lan_gateway.discover_probes` sends the probes of `request/1` to every host
  it finds and returns each answer. The gateway knows no protocol: the probe
  bytes come from here, and `device/1` reads the answers. A new protocol is a
  new entry here; the gateway does not change.

  `device/1` labels a discovered host with `protocol`, `kind`, `control` and
  the tool and skill for it. `control` is `open` when the device can be
  operated with no secret, and `needs_key` when the user must give one first.
  A host that also announces a known mDNS service is labeled from that.
  """

  alias SalixAgent.LanCodec.{Gree, Miio}

  @probes [
    %{id: "gree", port: Gree.port(), payload: Gree.scan()},
    %{id: "miio", port: Miio.port(), payload: Miio.hello()}
  ]
  @ids Enum.map(@probes, & &1.id)
  # Ceilings for what a gateway may advertise.
  @max_answer_bytes 1_024
  @max_total_answer_bytes 65_536

  @doc "The ids of every probe, in the order they are sent."
  def ids, do: @ids

  @doc """
  The probes to send through a gateway with the `discover_probes` capability
  `limits`, and the answer bytes to accept from it: `{probes, budget}`.
  `probes` is `[]` when the gateway cannot probe.
  """
  @spec request(term()) :: {[map()], %{answer: pos_integer(), total: pos_integer()}}
  def request(%{"max_probes" => max_probes, "max_payload_bytes" => max_payload} = limits)
      when is_integer(max_probes) and max_probes > 0 and is_integer(max_payload) do
    probes =
      @probes
      |> Enum.filter(&(byte_size(&1.payload) <= max_payload))
      |> Enum.take(max_probes)
      |> Enum.map(
        &%{"id" => &1.id, "port" => &1.port, "payload_b64" => Base.encode64(&1.payload)}
      )

    {probes,
     %{
       answer: limit(limits["max_answer_bytes"], @max_answer_bytes),
       total: limit(limits["max_total_answer_bytes"], @max_total_answer_bytes)
     }}
  end

  def request(_limits), do: {[], %{answer: @max_answer_bytes, total: @max_total_answer_bytes}}

  defp limit(value, ceiling) when is_integer(value) and value > 0, do: min(value, ceiling)
  defp limit(_value, ceiling), do: ceiling

  @doc """
  The label for a discovered host, or nil when nothing identifies it. `answers`
  maps a probe id to the datagram the host answered with.
  """
  @spec device(%{String.t() => binary()}, [String.t()]) :: map() | nil
  def device(answers, service_types) do
    Enum.find_value(@ids, &from_answer(&1, answers[&1])) || from_services(service_types)
  end

  defp from_answer("gree", answer) when is_binary(answer) do
    case Gree.parse_scan(answer) do
      {:ok, unit} ->
        %{
          "protocol" => "gree",
          "kind" => "air_conditioner",
          "control" => "open",
          "tool" => "device.gree_request",
          "skill" => "gree-ac"
        }
        |> put_present("name", unit[:name])
        |> put_present("brand", unit[:brand])

      {:error, :malformed} ->
        nil
    end
  end

  defp from_answer("miio", answer) when is_binary(answer) do
    case Miio.parse_hello(answer) do
      {:ok, _session} -> miio()
      {:error, :malformed} -> nil
    end
  end

  defp from_answer(_id, _answer), do: nil

  defp from_services(types) do
    cond do
      "_wled._tcp" in types ->
        %{
          "protocol" => "wled",
          "kind" => "light",
          "control" => "open",
          "tool" => "device.lan_request",
          "skill" => "wled"
        }

      "_miio._udp" in types ->
        miio()

      true ->
        nil
    end
  end

  # A miIO device takes commands only with its token, and it reports no model
  # before that.
  defp miio do
    %{
      "protocol" => "miio",
      "kind" => "xiaomi_device",
      "control" => "needs_key",
      "key" => "miio_token",
      "tool" => "device.miio_request",
      "skill" => "miio-lights"
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
