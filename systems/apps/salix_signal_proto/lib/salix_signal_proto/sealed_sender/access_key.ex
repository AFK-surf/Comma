defmodule SalixSignalProto.SealedSender.AccessKey do
  @moduledoc """
  The unidentified access key (CRS-06 §4).

  An account's access key is one AES-256 block encryption of
  `0x00 * 15 || 0x02` under its 32-byte profile key. A sealed send carries
  the recipient's access key in the `Unidentified-Access-Key` header as
  standard base64 with padding. A recipient with unrestricted unidentified
  access accepts any 16-byte key; senders then send 16 zero bytes.
  """

  import Bitwise

  @block <<0::120, 0x02>>

  @doc "Derives the 16-byte access key from a 32-byte profile key."
  @spec derive(<<_::256>>) :: <<_::128>>
  def derive(<<_::binary-size(32)>> = profile_key),
    do: :crypto.crypto_one_time(:aes_256_ecb, profile_key, @block, true)

  @doc "The key senders use for a recipient with unrestricted access: 16 zero bytes."
  @spec unrestricted() :: <<_::128>>
  def unrestricted, do: <<0::128>>

  @doc "The `Unidentified-Access-Key` header value of a 16-byte key."
  @spec header(<<_::128>>) :: String.t()
  def header(<<_::binary-size(16)>> = key), do: Base.encode64(key)

  @doc """
  The legacy multi-recipient key: the XOR of the access keys of the
  recipients without unrestricted access, 16 zero bytes when there are none
  (CRS-06 §4.2).
  """
  @spec combine([<<_::128>>]) :: <<_::128>>
  def combine(keys) when is_list(keys) do
    Enum.reduce(keys, unrestricted(), fn <<key::128>>, <<acc::128>> -> <<bxor(acc, key)::128>> end)
  end
end
