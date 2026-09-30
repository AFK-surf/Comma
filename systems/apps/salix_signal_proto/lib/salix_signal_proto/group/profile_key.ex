defmodule SalixSignalProto.Group.ProfileKey do
  @moduledoc """
  Profile keys as group attributes (CRS-09a section 8): the attribute points
  `M3` and `M4`, the deterministic 65-byte profile key ciphertext, and the
  commitment, version and access key of section 8.5.

  A profile key is 32 bytes and always belongs to an ACI (`{:aci, uuid}`).
  Decryption recovers all 32 bytes, including the three bits that `M4`
  masks, by trial (section 8.3). It uses the variable-time
  `SalixSignalProto.Group.Elligator.preimages/1`.
  """

  import Bitwise

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.Elligator
  alias SalixSignalProto.Group.Generators, as: G
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.Sho

  @m3_label "Signal_ZKGroup_20200424_ProfileKeyAndUid_ProfileKey_CalcM3"
  @j3_label "Signal_ZKGroup_20200424_ProfileKeyAndUid_ProfileKeyCommitment_Calcj3"
  @generate_label "Signal_ZKGroup_20200424_Random_ProfileKey_Generate"

  @type profile_key :: <<_::256>>

  @doc "`M3`: a single `MAP` of the 32-byte squeeze of `H(CalcM3; k ‖ uuid)`."
  @spec m3(profile_key(), <<_::128>>) :: R.element()
  def m3(<<_::binary-size(32)>> = key, <<_::binary-size(16)>> = uuid) do
    {point, _state} = @m3_label |> Sho.derive([key, uuid]) |> Sho.squeeze_map_point()
    point
  end

  @doc "`M4 = MAP(k')` with bit 0 of byte 0 and the two top bits of byte 31 cleared."
  @spec m4(profile_key()) :: R.element()
  def m4(<<first, middle::binary-size(30), last>>),
    do: Elligator.map(<<band(first, 0xFE), middle::binary, band(last, 0x3F)>>)

  @doc "Encrypts a profile key for the ACI `uuid` into a 65-byte ciphertext."
  @spec encrypt(Params.t(), profile_key(), <<_::128>>) :: <<_::520>>
  def encrypt(%Params{} = params, key, uuid) do
    {e1, e2} = encrypt_points(params, key, uuid)
    <<0, e1::binary, e2::binary>>
  end

  @doc "Returns `{E1, E2}` with `E1 = b1·M3` and `E2 = b2·E1 + M4`."
  @spec encrypt_points(Params.t(), profile_key(), <<_::128>>) :: {R.element(), R.element()}
  def encrypt_points(%Params{b1: b1, b2: b2}, key, uuid) do
    e1 = R.mul(b1, m3(key, uuid))
    {e1, R.add(R.mul(b2, e1), m4(key))}
  end

  @doc """
  Decrypts a 65-byte profile key ciphertext for the ACI `uuid` that the key
  belongs to (CRS-09a section 8.3).
  """
  @spec decrypt(Params.t(), binary(), <<_::128>>) :: {:ok, profile_key()} | {:error, :invalid}
  def decrypt(%Params{} = params, <<0, e1::binary-size(32), e2::binary-size(32)>>, uuid) do
    if R.valid?(e1) and R.valid?(e2),
      do: decrypt_points(params, {e1, e2}, uuid),
      else: {:error, :invalid}
  end

  def decrypt(%Params{}, _ciphertext, _uuid), do: {:error, :invalid}

  @doc "Decrypts `{E1, E2}`. Exactly one candidate must be valid."
  @spec decrypt_points(Params.t(), {R.element(), R.element()}, <<_::128>>) ::
          {:ok, profile_key()} | {:error, :invalid}
  def decrypt_points(%Params{b1: b1, b2: b2}, {e1, e2}, <<_::binary-size(16)>> = uuid) do
    with false <- e1 == R.generator(),
         {:ok, b1_inv} <- R.scalar_invert(b1),
         {:ok, slots} <- Elligator.preimages(R.sub(e2, R.mul(b2, e1))) do
      t = R.mul(b1_inv, e1)

      # Counted per slot without deduplication (CRS-09a section 8.4).
      valid =
        for <<_::binary-size(32)>> = r <- slots,
            candidate <- candidates(r),
            m3(candidate, uuid) == t,
            do: candidate

      case valid do
        [key] -> {:ok, key}
        _ -> {:error, :invalid}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp candidates(<<first, middle::binary-size(30), last>>) do
    for low <- [0, 1], high <- [0, 0x80, 0x40, 0xC0] do
      <<bor(first, low), middle::binary, bor(last, high)>>
    end
  end

  @doc """
  The 97-byte profile key commitment
  `0x00 ‖ enc(j3·G_j1 + M3) ‖ enc(j3·G_j2 + M4) ‖ enc(j3·G_j3)` (section 8.5).
  """
  @spec commitment(profile_key(), <<_::128>>) :: <<_::776>>
  def commitment(key, uuid) do
    {j1, j2, j3} = commitment_points(key, uuid)
    <<0, j1::binary, j2::binary, j3::binary>>
  end

  @doc "Returns `{J1, J2, J3}` of the commitment."
  @spec commitment_points(profile_key(), <<_::128>>) :: {R.element(), R.element(), R.element()}
  def commitment_points(key, uuid) do
    j3 = j3(key, uuid)

    {R.add(R.mul(j3, G.get(:g_j1)), m3(key, uuid)), R.add(R.mul(j3, G.get(:g_j2)), m4(key)),
     R.mul(j3, G.get(:g_j3))}
  end

  @doc "The commitment scalar `j3`."
  @spec j3(profile_key(), <<_::128>>) :: R.scalar()
  def j3(key, uuid) do
    {j3, _state} = @j3_label |> Sho.derive([key, uuid]) |> Sho.squeeze_scalar()
    j3
  end

  @doc """
  The profile key version: 64 lowercase hexadecimal characters (section
  8.5). The profile code owns it (`SalixSignalProto.Profile.version/2`).
  """
  @spec version(profile_key(), <<_::128>>) :: String.t()
  defdelegate version(key, uuid), to: SalixSignalProto.Profile

  @doc "The 16-byte access key (section 8.5), owned by `SalixSignalProto.Profile.access_key/1`."
  @spec access_key(profile_key()) :: <<_::128>>
  defdelegate access_key(key), to: SalixSignalProto.Profile

  @doc "A new random profile key (section 8.5)."
  @spec generate(<<_::256>>) :: profile_key()
  def generate(randomness \\ :crypto.strong_rand_bytes(32)) do
    {key, _state} = @generate_label |> Sho.derive(randomness) |> Sho.squeeze(32)
    key
  end
end
