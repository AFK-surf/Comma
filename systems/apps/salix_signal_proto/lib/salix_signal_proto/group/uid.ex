defmodule SalixSignalProto.Group.Uid do
  @moduledoc """
  Service IDs inside groups (CRS-09a sections 2 and 7): the attribute points
  `M1` and `M2`, and the deterministic 65-byte UID ciphertext
  `0x00 ‖ enc(E1) ‖ enc(E2)` with `E1 = a1·M1` and `E2 = a2·E1 + M2`.

  A service ID is `{:aci, uuid}` or `{:pni, uuid}` with the 16 raw UUID bytes,
  as in `SalixSignalProto.Address`.

  Encryption runs in constant-time NIF operations. Decryption decodes `M2`
  with `SalixSignalProto.Group.Elligator.preimages/1`, which is variable
  time; the value it recovers is a member identifier that every group member
  can decrypt.
  """

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.Elligator
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.Sho

  @m1_label "Signal_ZKGroup_20200424_UID_CalcM1"

  @type service_id :: {:aci | :pni, <<_::128>>}
  @type ciphertext :: <<_::520>>

  @doc "The 17-byte tagged form: kind byte (`0x00` ACI, `0x01` PNI) and the UUID."
  @spec tagged(service_id()) :: <<_::136>>
  def tagged({:aci, <<_::binary-size(16)>> = uuid}), do: <<0>> <> uuid
  def tagged({:pni, <<_::binary-size(16)>> = uuid}), do: <<1>> <> uuid

  @doc "Parses the 17-byte tagged form."
  @spec parse_tagged(binary()) :: {:ok, service_id()} | :error
  def parse_tagged(<<0, uuid::binary-size(16)>>), do: {:ok, {:aci, uuid}}
  def parse_tagged(<<1, uuid::binary-size(16)>>), do: {:ok, {:pni, uuid}}
  def parse_tagged(_bytes), do: :error

  @doc "The compact form: the UUID for an ACI, `0x01 ‖ uuid` for a PNI."
  @spec compact(service_id()) :: binary()
  def compact({:aci, <<_::binary-size(16)>> = uuid}), do: uuid
  def compact({:pni, <<_::binary-size(16)>> = uuid}), do: <<1>> <> uuid

  @doc "`M1`: the squeeze-point of `H(CalcM1; compact form)`."
  @spec m1(service_id()) :: R.element()
  def m1(service_id) do
    {point, _state} = @m1_label |> Sho.derive(compact(service_id)) |> Sho.squeeze_point()
    point
  end

  @doc "`M2 = EncodeToG(uuid)` (CRS-09a section 7.2)."
  @spec m2(service_id() | <<_::128>>) :: R.element()
  def m2({_kind, uuid}), do: m2(uuid)
  def m2(<<_::binary-size(16)>> = uuid), do: Elligator.map(encode_bytes(uuid))

  @doc "Encrypts a service ID into its 65-byte UID ciphertext."
  @spec encrypt(Params.t(), service_id()) :: ciphertext()
  def encrypt(%Params{} = params, service_id) do
    {e1, e2} = encrypt_points(params, service_id)
    <<0, e1::binary, e2::binary>>
  end

  @doc "Returns `{E1, E2}` for a service ID."
  @spec encrypt_points(Params.t(), service_id()) :: {R.element(), R.element()}
  def encrypt_points(%Params{a1: a1, a2: a2}, service_id) do
    e1 = R.mul(a1, m1(service_id))
    {e1, R.add(R.mul(a2, e1), m2(service_id))}
  end

  @doc """
  Parses a 65-byte UID ciphertext into `{E1, E2}`. The reserved byte must be
  zero and both points must decode.
  """
  @spec parse(binary()) :: {:ok, {R.element(), R.element()}} | {:error, :invalid}
  def parse(<<0, e1::binary-size(32), e2::binary-size(32)>>) do
    if R.valid?(e1) and R.valid?(e2), do: {:ok, {e1, e2}}, else: {:error, :invalid}
  end

  def parse(_bytes), do: {:error, :invalid}

  @doc "Decrypts a 65-byte UID ciphertext (CRS-09a section 7.4)."
  @spec decrypt(Params.t(), binary()) :: {:ok, service_id()} | {:error, :invalid}
  def decrypt(%Params{} = params, ciphertext) do
    with {:ok, points} <- parse(ciphertext), do: decrypt_points(params, points)
  end

  @doc "Decrypts `{E1, E2}`."
  @spec decrypt_points(Params.t(), {R.element(), R.element()}) ::
          {:ok, service_id()} | {:error, :invalid}
  def decrypt_points(%Params{a1: a1, a2: a2}, {e1, e2}) do
    with false <- e1 == R.generator(),
         {:ok, uuid} <- decode_uuid(R.sub(e2, R.mul(a2, e1))),
         {:ok, a1_inv} <- R.scalar_invert(a1) do
      t = R.mul(a1_inv, e1)

      cond do
        t == m1({:aci, uuid}) -> {:ok, {:aci, uuid}}
        t == m1({:pni, uuid}) -> {:ok, {:pni, uuid}}
        true -> {:error, :invalid}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Recovers the UUID that `m2/1` encoded in `point`: exactly one non-negative
  `MAP` preimage must be the encoding of its own bytes 8 to 23.
  """
  @spec decode_uuid(R.element()) :: {:ok, <<_::128>>} | :error
  def decode_uuid(point) do
    with {:ok, slots} <- Elligator.preimages(point) do
      matches =
        for <<_::binary-size(8), uuid::binary-size(16), _::binary-size(8)>> = f <- slots,
            encode_bytes(uuid) == f,
            do: uuid

      case matches do
        [uuid] -> {:ok, uuid}
        _ -> :error
      end
    end
  end

  # f = SHA-256(u) with bytes 8..23 replaced by u, bit 0 of byte 0 cleared and
  # the two top bits of byte 31 cleared.
  defp encode_bytes(uuid) do
    <<first, hash1::binary-size(7), _::binary-size(16), hash2::binary-size(7), last>> =
      :crypto.hash(:sha256, uuid)

    <<Bitwise.band(first, 0xFE), hash1::binary, uuid::binary, hash2::binary,
      Bitwise.band(last, 0x3F)>>
  end
end
