defmodule SalixAgent.LanCodec.Gree do
  @moduledoc """
  Gree air conditioners over UDP 7000, after greeclimate's `cipher.py` and
  `network.py`.

  Every datagram is a JSON envelope. A scan is the plain envelope
  `{"t":"scan"}`. Every other message carries an encrypted JSON `pack`:
  `{"cid":"app","i":0|1,"t":"pack","uid":0,"tcid":mac,"pack":base64}`.

  Two ciphers exist. Older Wi-Fi modules use AES-128-ECB with PKCS#7 padding.
  Newer ones use AES-128-GCM with a fixed nonce and associated data, and add
  the base64 `tag` to the envelope. A reply is read with the cipher its
  envelope shows: GCM when it has a `tag`, ECB otherwise.

  The scan reply and the bind exchange use a key that is the same for every
  device. The bind reply hands out the device key, which encrypts status and
  command packs. Any host on the network can bind, so the key is not a secret
  the user has to give; it is still never returned or logged.

  This module only builds and reads datagrams. `SalixAgent.Tools.Gree` sends
  them through a LAN gateway.

  Handwritten because no maintained Elixir Gree library exists; greeclimate is
  the reference, and the tests check packets that it produced.
  """

  @port 7000
  @generic_keys %{ecb: "a3K8Bx%2r8Y7#xDh", gcm: "{yxAHAY_Lm6pbC/<"}
  @gcm_nonce <<0x54, 0x40, 0x78, 0x44, 0x49, 0x67, 0x5A, 0x51, 0x6C, 0x5E, 0x63, 0x13>>
  @gcm_aad "qualcomm-test"
  @scan ~s({"t":"scan"})
  @max_text_chars 64

  @type cipher :: :ecb | :gcm

  def port, do: @port

  @doc "The scan datagram. A Gree device answers it with its identity."
  def scan, do: @scan

  @doc """
  Read a scan reply: the device's `mac`, the cipher its module speaks and the
  bounded, printable `name`, `brand`, `model` and `version` it reports.
  """
  @spec parse_scan(binary()) :: {:ok, map()} | {:error, :malformed}
  def parse_scan(datagram) do
    with {:ok, %{"t" => "dev"} = pack, cipher} <- open(datagram, &Map.fetch!(@generic_keys, &1)),
         {:ok, mac} <- mac(pack["mac"] || pack["cid"]) do
      info =
        for {field, key} <- [name: "name", brand: "brand", model: "model", version: "ver"],
            text = text(pack[key]),
            into: %{mac: mac, cipher: cipher},
            do: {field, text}

      {:ok, info}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc "The bind request that asks the device at `mac` for its key."
  @spec bind(String.t(), cipher()) :: binary()
  def bind(mac, cipher),
    do: seal(%{"mac" => mac, "t" => "bind", "uid" => 0}, mac, @generic_keys[cipher], cipher, 1)

  @doc "Read a bind reply from `mac`: the 16-byte device key."
  @spec parse_bind(binary(), String.t()) :: {:ok, binary()} | {:error, :malformed}
  def parse_bind(datagram, mac) do
    case open(datagram, &Map.fetch!(@generic_keys, &1)) do
      {:ok, %{"t" => "bindok", "mac" => ^mac, "key" => <<_::binary-16>> = key}, _cipher} ->
        {:ok, key}

      _ ->
        {:error, :malformed}
    end
  end

  @doc "A status request for `cols`, encrypted with the device key."
  @spec status(String.t(), binary(), cipher(), [String.t()]) :: binary()
  def status(mac, key, cipher, cols),
    do: seal(%{"cols" => cols, "mac" => mac, "t" => "status"}, mac, key, cipher, 0)

  @doc "A command that sets each column of `opt` to the value at its place in `p`."
  @spec command(String.t(), binary(), cipher(), [String.t()], [integer()]) :: binary()
  def command(mac, key, cipher, opt, p),
    do: seal(%{"opt" => opt, "p" => p, "t" => "cmd"}, mac, key, cipher, 0)

  @doc """
  Read a status (`dat`) or command (`res`) reply from `mac`: the columns it
  names with their values, or the device's refusal code.
  """
  @spec parse_reply(binary(), String.t(), binary()) ::
          {:ok, %{String.t() => term()}} | {:error, :malformed | {:refused, integer()}}
  def parse_reply(datagram, mac, key) do
    case open(datagram, fn _cipher -> key end) do
      {:ok, %{"mac" => ^mac, "r" => r}, _cipher} when is_integer(r) and r != 200 ->
        {:error, {:refused, r}}

      {:ok, %{"t" => "dat", "mac" => ^mac, "cols" => cols, "dat" => dat}, _cipher} ->
        columns(cols, dat)

      {:ok, %{"t" => "res", "mac" => ^mac, "opt" => opt} = pack, _cipher} ->
        # Some modules answer with an empty `val` and the values in `p`.
        columns(opt, if(pack["val"] in [nil, []], do: pack["p"], else: pack["val"]))

      _ ->
        {:error, :malformed}
    end
  end

  defp columns(names, values)
       when is_list(names) and is_list(values) and length(names) == length(values) do
    if Enum.all?(names, &is_binary/1),
      do: {:ok, Map.new(Enum.zip(names, values))},
      else: {:error, :malformed}
  end

  defp columns(_names, _values), do: {:error, :malformed}

  defp seal(pack, mac, key, cipher, i) do
    envelope = %{"cid" => "app", "i" => i, "t" => "pack", "uid" => 0, "tcid" => mac}

    Jason.encode!(Map.merge(envelope, encrypt(Jason.encode!(pack), key, cipher)))
  end

  # The envelope's own fields are not authenticated. Only the pack is trusted.
  defp open(datagram, key_for) do
    with {:ok, %{"pack" => pack} = envelope} when is_binary(pack) <- Jason.decode(datagram),
         {:ok, ciphertext} <- Base.decode64(pack),
         cipher = if(is_binary(envelope["tag"]), do: :gcm, else: :ecb),
         {:ok, plaintext} <- decrypt(ciphertext, envelope["tag"], key_for.(cipher), cipher),
         {:ok, opened} when is_map(opened) <- Jason.decode(plaintext) do
      {:ok, opened, cipher}
    else
      _ -> {:error, :malformed}
    end
  end

  defp encrypt(plaintext, key, :ecb) do
    n = 16 - rem(byte_size(plaintext), 16)
    padded = plaintext <> :binary.copy(<<n>>, n)
    %{"pack" => Base.encode64(:crypto.crypto_one_time(:aes_128_ecb, key, padded, true))}
  end

  defp encrypt(plaintext, key, :gcm) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, key, @gcm_nonce, plaintext, @gcm_aad, true)

    %{"pack" => Base.encode64(ciphertext), "tag" => Base.encode64(tag)}
  end

  defp decrypt(ciphertext, _tag, key, :ecb)
       when byte_size(ciphertext) > 0 and rem(byte_size(ciphertext), 16) == 0 do
    # Devices pad with PKCS#7 or NUL bytes; the JSON ends at its last brace.
    plaintext = :crypto.crypto_one_time(:aes_128_ecb, key, ciphertext, false)

    case :binary.matches(plaintext, "}") do
      [] -> {:error, :malformed}
      matches -> {:ok, binary_part(plaintext, 0, elem(List.last(matches), 0) + 1)}
    end
  end

  defp decrypt(ciphertext, tag, key, :gcm) do
    with {:ok, <<_::binary-16>> = tag} <- Base.decode64(tag),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_128_gcm,
             key,
             @gcm_nonce,
             ciphertext,
             @gcm_aad,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> {:error, :malformed}
    end
  end

  defp decrypt(_ciphertext, _tag, _key, _cipher), do: {:error, :malformed}

  defp mac(mac) when is_binary(mac) do
    if Regex.match?(~r/\A[0-9A-Za-z@]{1,40}\z/, mac), do: {:ok, mac}, else: {:error, :malformed}
  end

  defp mac(_mac), do: {:error, :malformed}

  # Text that the device reports about itself reaches the model: printable
  # characters only, bounded.
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
end
