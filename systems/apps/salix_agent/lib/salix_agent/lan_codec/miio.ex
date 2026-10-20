defmodule SalixAgent.LanCodec.Miio do
  @moduledoc """
  Xiaomi miIO over UDP 54321, after python-miio's `miio/protocol.py`.

  Every packet starts with a 32-byte header: magic `0x2131`, total length,
  `0x00000000`, the 4-byte device id, a 4-byte stamp and a 16-byte checksum.
  A hello is that header with every other byte `0xFF`; the device answers
  with its id and stamp. A command carries a payload encrypted with
  AES-128-CBC (key `MD5(token)`, iv `MD5(key ‖ token)`, PKCS#7) and the
  checksum `MD5(header[0..16] ‖ token ‖ ciphertext)`.

  The payload is JSON `{"id", "method", "params"}` followed by a NUL byte, as
  python-miio sends it. Replies are checked and decrypted the same way.

  Handwritten because no maintained Elixir miIO library exists; python-miio
  is the reference, and the tests check its packet vectors.
  """

  @behaviour SalixAgent.LanCodec

  @magic 0x2131
  @header_bytes 32
  @hello <<@magic::16, @header_bytes::16, :binary.copy(<<0xFF>>, 28)::binary>>

  @impl true
  def port, do: 54_321

  @impl true
  def hello, do: @hello

  @impl true
  def parse_hello(
        <<@magic::16, @header_bytes::16, _unknown::32, device_id::binary-4, stamp::32,
          _checksum::binary-16>>
      ),
      do: {:ok, %{device_id: device_id, stamp: stamp}}

  def parse_hello(_reply), do: {:error, :malformed}

  @impl true
  def key(token) when is_binary(token) do
    case Base.decode16(token, case: :mixed) do
      {:ok, <<_::binary-16>> = key} -> {:ok, key}
      _ -> {:error, :bad_token}
    end
  end

  @impl true
  def encode(%{"id" => _, "method" => _} = request, token, %{device_id: device_id, stamp: stamp}) do
    build(Jason.encode!(request) <> <<0>>, token, device_id, stamp)
  end

  @impl true
  def decode(packet, token) do
    with {:ok, header, checksum, ciphertext} <- split(packet),
         true <- checksum == checksum(header, token, ciphertext) || {:error, :checksum},
         {:ok, plaintext} <- decrypt(ciphertext, token),
         {:ok, payload} <- json(plaintext) do
      <<_::binary-8, device_id::binary-4, stamp::32>> = header
      {:ok, payload, %{device_id: device_id, stamp: stamp}}
    end
  end

  @doc false
  def build(plaintext, token, device_id, stamp) do
    ciphertext = encrypt(plaintext, token)

    header =
      <<@magic::16, @header_bytes + byte_size(ciphertext)::16, 0::32, device_id::binary-4,
        stamp::32>>

    header <> checksum(header, token, ciphertext) <> ciphertext
  end

  @doc false
  def encrypt(plaintext, token) do
    {key, iv} = key_iv(token)
    :crypto.crypto_one_time(:aes_128_cbc, key, iv, pad(plaintext), true)
  end

  @doc false
  def decrypt(ciphertext, token)
      when byte_size(ciphertext) > 0 and rem(byte_size(ciphertext), 16) == 0 do
    {key, iv} = key_iv(token)
    unpad(:crypto.crypto_one_time(:aes_128_cbc, key, iv, ciphertext, false))
  end

  def decrypt(_ciphertext, _token), do: {:error, :malformed}

  defp key_iv(token) do
    key = :crypto.hash(:md5, token)
    {key, :crypto.hash(:md5, key <> token)}
  end

  defp checksum(header, token, ciphertext), do: :crypto.hash(:md5, header <> token <> ciphertext)

  defp split(<<@magic::16, length::16, _::binary-12, _::binary>> = packet)
       when length == byte_size(packet) and length > @header_bytes do
    <<header::binary-16, checksum::binary-16, ciphertext::binary>> = packet
    {:ok, header, checksum, ciphertext}
  end

  defp split(_packet), do: {:error, :malformed}

  defp pad(data) do
    n = 16 - rem(byte_size(data), 16)
    data <> :binary.copy(<<n>>, n)
  end

  defp unpad(data) do
    n = :binary.last(data)

    if n in 1..16 and byte_size(data) >= n and
         binary_part(data, byte_size(data) - n, n) == :binary.copy(<<n>>, n),
       do: {:ok, binary_part(data, 0, byte_size(data) - n)},
       else: {:error, :malformed}
  end

  # Devices end the JSON with NUL bytes; some add bytes after a NUL.
  defp json(plaintext) do
    text = plaintext |> :binary.split(<<0>>) |> hd()

    case Jason.decode(text) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed}
    end
  end
end
