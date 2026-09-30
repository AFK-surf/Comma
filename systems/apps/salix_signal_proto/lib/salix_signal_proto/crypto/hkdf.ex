defmodule SalixSignalProto.Crypto.Hkdf do
  @moduledoc """
  HKDF (RFC 5869) with HMAC-SHA256 or HMAC-SHA512.
  """

  @type hash :: :sha256 | :sha512

  @doc """
  Derives `length` bytes: `expand(extract(salt, ikm), info, length)`. An empty
  salt means a string of hash-length zero bytes (RFC 5869 section 2.2).
  """
  @spec derive(binary(), binary(), iodata(), pos_integer(), hash()) :: binary()
  def derive(ikm, salt, info, length, hash \\ :sha256) do
    salt |> extract(ikm, hash) |> expand(info, length, hash)
  end

  @doc "HKDF-Extract: returns the pseudorandom key."
  @spec extract(binary(), binary(), hash()) :: binary()
  def extract(salt, ikm, hash \\ :sha256) when is_binary(salt) and is_binary(ikm) do
    salt = if salt == "", do: <<0::size(hash_bytes(hash) * 8)>>, else: salt
    :crypto.mac(:hmac, hash, salt, ikm)
  end

  @doc """
  HKDF-Expand: returns `length` bytes of output keying material. `length` must
  be at most 255 times the hash length.
  """
  @spec expand(binary(), iodata(), pos_integer(), hash()) :: binary()
  def expand(prk, info, length, hash \\ :sha256)
      when is_binary(prk) and is_integer(length) and length > 0 do
    hash_len = hash_bytes(hash)

    if length > 255 * hash_len do
      raise ArgumentError, "HKDF output length #{length} exceeds #{255 * hash_len} bytes"
    end

    blocks = div(length + hash_len - 1, hash_len)

    {output, _previous} =
      Enum.reduce(1..blocks, {[], ""}, fn counter, {acc, previous} ->
        block = :crypto.mac(:hmac, hash, prk, [previous, info, <<counter>>])
        {[acc, block], block}
      end)

    binary_part(IO.iodata_to_binary(output), 0, length)
  end

  defp hash_bytes(:sha256), do: 32
  defp hash_bytes(:sha512), do: 64
end
