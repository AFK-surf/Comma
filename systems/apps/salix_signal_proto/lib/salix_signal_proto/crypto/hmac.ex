defmodule SalixSignalProto.Crypto.Hmac do
  @moduledoc "HMAC-SHA256 and constant-time comparison through OTP `:crypto`."

  @doc "Returns HMAC-SHA256(key, data)."
  @spec sha256(binary(), iodata()) :: <<_::256>>
  def sha256(key, data) when is_binary(key), do: :crypto.mac(:hmac, :sha256, key, data)

  @doc """
  Compares two binaries in constant time for equal sizes. Binaries of
  different sizes are unequal.
  """
  @spec equal?(binary(), binary()) :: boolean()
  def equal?(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end
end
