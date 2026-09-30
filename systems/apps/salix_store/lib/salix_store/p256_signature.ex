defmodule SalixStore.P256Signature do
  @moduledoc """
  Application Signature V1 codec for P-256/SHA-256.

  Public keys are compressed SEC1 points. Signatures are fixed-width
  `r || s` and must use the low-S representative. This is the same
  fail-closed wire contract enforced by Agent VMM's Go verifier.
  """

  import Bitwise

  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @half_order div(@p256_order, 2)

  def valid_low_s?(<<r::binary-size(32), s::binary-size(32)>>) do
    r_value = :binary.decode_unsigned(r)
    s_value = :binary.decode_unsigned(s)
    r_value > 0 and r_value < @p256_order and s_value > 0 and s_value <= @half_order
  end

  def valid_low_s?(_), do: false

  def verify(payload, <<r::binary-size(32), s::binary-size(32)>> = signature, public_key)
      when is_binary(payload) and is_binary(public_key) and byte_size(public_key) == 33 do
    valid_low_s?(signature) and
      :crypto.verify(:ecdsa, :sha256, payload, der_signature(r, s), [public_key, :secp256r1])
  rescue
    _ -> false
  end

  def verify(_, _, _), do: false

  defp der_signature(r, s) do
    r = der_integer(r)
    s = der_integer(s)
    <<0x30, byte_size(r) + byte_size(s), r::binary, s::binary>>
  end

  defp der_integer(value) do
    value = value |> :binary.bin_to_list() |> Enum.drop_while(&(&1 == 0)) |> :binary.list_to_bin()

    value =
      if value == <<>> or (:binary.first(value) &&& 0x80) != 0,
        do: <<0, value::binary>>,
        else: value

    <<0x02, byte_size(value), value::binary>>
  end
end
