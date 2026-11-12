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
  the tool, skill and, for a device a LAN script operates, the script for it. `control` is `open` when the device can be
  operated with no secret, and `needs_key` when the user must give one first.
  A host that also announces a known mDNS service is labeled from that.
  """

  # A Gree unit answers this scan on UDP 7000 with its identity, sealed with a
  # key that is the same for every unit: AES-128-ECB for older modules,
  # AES-128-GCM (fixed nonce and associated data, a `tag` beside the pack) for
  # newer ones, after greeclimate's cipher.py.
  @gree_scan ~s({"t":"scan"})
  @gree_keys %{ecb: "a3K8Bx%2r8Y7#xDh", gcm: "{yxAHAY_Lm6pbC/<"}
  @gree_nonce <<0x54, 0x40, 0x78, 0x44, 0x49, 0x67, 0x5A, 0x51, 0x6C, 0x5E, 0x63, 0x13>>
  @gree_aad "qualcomm-test"
  @max_text_chars 64
  # A miIO device answers this hello on UDP 54321 with a 32-byte header,
  # after python-miio's protocol.py.
  @miio_hello <<0x21, 0x31, 0x00, 0x20, :binary.copy(<<0xFF>>, 28)::binary>>

  # mDNS services a network printer announces (IPP, raw printing on 9100).
  @printer_services ~w(_ipp._tcp _ipps._tcp _printer._tcp _pdl-datastream._tcp)

  @probes [
    %{id: "gree", port: 7_000, payload: @gree_scan},
    %{id: "miio", port: 54_321, payload: @miio_hello}
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
    case gree_unit(answer) do
      %{} = unit ->
        %{
          "protocol" => "gree",
          "kind" => "air_conditioner",
          "control" => "open",
          "tool" => "device.lan_script",
          "skill" => "gree-ac",
          "script" => "/.runtime/skills/gree-ac/gree.js"
        }
        |> put_present("name", text(unit["name"]))
        |> put_present("brand", text(unit["brand"]))

      nil ->
        nil
    end
  end

  defp from_answer("miio", <<0x21, 0x31, 0x00, 0x20, _::binary-28>>), do: miio()

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

      Enum.any?(types, &(&1 in @printer_services)) ->
        %{
          "protocol" => "ipp",
          "kind" => "printer",
          "control" => "open",
          "tool" => "device.lan_script",
          "skill" => "lan-printer",
          "script" => "/.runtime/skills/lan-printer/ipp.js"
        }

      "_home-assistant._tcp" in types ->
        %{
          "protocol" => "home_assistant",
          "kind" => "home_hub",
          "control" => "needs_key",
          "key" => "api_token",
          "tool" => "device.lan_script",
          "skill" => "home-assistant",
          "script" => "/.runtime/skills/home-assistant/ha.js"
        }

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
      "tool" => "device.lan_script",
      "skill" => "miio-lights",
      "script" => "/.runtime/skills/miio-lights/miio.js"
    }
  end

  # The scan reply's pack, when it is a Gree unit's identity. The envelope's
  # own fields are not authenticated; only the pack is trusted.
  defp gree_unit(datagram) do
    with {:ok, %{"pack" => pack} = envelope} when is_binary(pack) <- Jason.decode(datagram),
         {:ok, ciphertext} <- Base.decode64(pack),
         {:ok, plaintext} <- gree_open(ciphertext, envelope["tag"]),
         {:ok, %{"t" => "dev"} = unit} <- Jason.decode(plaintext),
         mac when is_binary(mac) <- unit["mac"] || unit["cid"],
         true <- Regex.match?(~r/\A[0-9A-Za-z@]{1,40}\z/, mac) do
      unit
    else
      _ -> nil
    end
  end

  defp gree_open(ciphertext, nil)
       when byte_size(ciphertext) > 0 and rem(byte_size(ciphertext), 16) == 0 do
    # Units pad with PKCS#7 or NUL bytes; the JSON ends at its last brace.
    plaintext = :crypto.crypto_one_time(:aes_128_ecb, @gree_keys.ecb, ciphertext, false)

    case :binary.matches(plaintext, "}") do
      [] -> :error
      matches -> {:ok, binary_part(plaintext, 0, elem(List.last(matches), 0) + 1)}
    end
  end

  defp gree_open(ciphertext, tag) when is_binary(tag) do
    with {:ok, <<_::binary-16>> = tag} <- Base.decode64(tag),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_128_gcm,
             @gree_keys.gcm,
             @gree_nonce,
             ciphertext,
             @gree_aad,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  end

  defp gree_open(_ciphertext, _tag), do: :error

  # Text the unit reports about itself reaches the model: printable characters
  # only, bounded.
  defp text(value) when is_binary(value) do
    text =
      value
      |> String.replace_invalid("")
      |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
      |> String.slice(0, @max_text_chars)
      |> String.trim()

    if text != "", do: text
  end

  defp text(_value), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
