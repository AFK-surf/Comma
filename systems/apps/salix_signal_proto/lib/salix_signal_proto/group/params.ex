defmodule SalixSignalProto.Group.Params do
  @moduledoc """
  Group keys (CRS-09a section 6): the 32-byte master key, the group
  identifier, the blob key and the two ristretto255 key pairs derived from it.

  | Form | Bytes | Layout |
  | --- | --- | --- |
  | Secret params | 289 | `0x00 ‖ K ‖ gid ‖ kb ‖ sc(a1) ‖ sc(a2) ‖ enc(A) ‖ sc(b1) ‖ sc(b2) ‖ enc(Bpk)` |
  | Public params | 97 | `0x00 ‖ gid ‖ enc(A) ‖ enc(Bpk)` |

  The public params are the group's public key on the storage service
  (CRS-09b). The identifier names the group in messages.
  """

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.Generators, as: G
  alias SalixSignalProto.Group.Sho

  @derive_label "Signal_ZKGroup_20200424_GroupMasterKey_GroupSecretParams_DeriveFromMasterKey"
  @generate_label "Signal_ZKGroup_20200424_Random_GroupSecretParams_Generate"

  @enforce_keys [:master_key, :group_id, :blob_key, :a1, :a2, :a, :b1, :b2, :b]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          master_key: <<_::256>>,
          group_id: <<_::256>>,
          blob_key: <<_::256>>,
          a1: R.scalar(),
          a2: R.scalar(),
          a: R.element(),
          b1: R.scalar(),
          b2: R.scalar(),
          b: R.element()
        }

  @doc "Derives the group secret params from a 32-byte master key."
  @spec from_master_key(<<_::256>>) :: t()
  def from_master_key(<<_::binary-size(32)>> = master_key) do
    state = Sho.derive(@derive_label, master_key)
    {group_id, state} = Sho.squeeze(state, 32)
    {blob_key, state} = Sho.squeeze(state, 32)
    {[a1, a2, b1, b2], _state} = Sho.squeeze_scalars(state, 4)

    %__MODULE__{
      master_key: master_key,
      group_id: group_id,
      blob_key: blob_key,
      a1: a1,
      a2: a2,
      a: R.add(R.mul(a1, G.get(:g_a1)), R.mul(a2, G.get(:g_a2))),
      b1: b1,
      b2: b2,
      b: R.add(R.mul(b1, G.get(:g_b1)), R.mul(b2, G.get(:g_b2)))
    }
  end

  @doc "A new master key from 32 bytes of randomness (CRS-09a section 6.1)."
  @spec generate_master_key(<<_::256>>) :: <<_::256>>
  def generate_master_key(randomness \\ :crypto.strong_rand_bytes(32))

  def generate_master_key(<<_::binary-size(32)>> = randomness) do
    {master_key, _state} = @generate_label |> Sho.derive(randomness) |> Sho.squeeze(32)
    master_key
  end

  @doc "Serializes the 289-byte secret params."
  @spec encode(t()) :: <<_::2312>>
  def encode(%__MODULE__{} = p) do
    <<0, p.master_key::binary, p.group_id::binary, p.blob_key::binary, p.a1::binary, p.a2::binary,
      p.a::binary, p.b1::binary, p.b2::binary, p.b::binary>>
  end

  @doc """
  Parses 289-byte secret params. The derived values must match the master
  key, so a stored value cannot carry keys that the master key does not give.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid}
  def decode(<<0, master_key::binary-size(32), _rest::binary-size(256)>> = bytes) do
    params = from_master_key(master_key)
    if encode(params) == bytes, do: {:ok, params}, else: {:error, :invalid}
  end

  def decode(_bytes), do: {:error, :invalid}

  @doc "The 97-byte public params."
  @spec public_params(t()) :: <<_::776>>
  def public_params(%__MODULE__{group_id: gid, a: a, b: b}),
    do: <<0, gid::binary, a::binary, b::binary>>

  @doc """
  Parses 97-byte public params into `{group_id, a, b}`. Both points must be
  valid encodings.
  """
  @spec decode_public_params(binary()) ::
          {:ok, {<<_::256>>, R.element(), R.element()}} | {:error, :invalid}
  def decode_public_params(<<0, gid::binary-size(32), a::binary-size(32), b::binary-size(32)>>) do
    if R.valid?(a) and R.valid?(b), do: {:ok, {gid, a, b}}, else: {:error, :invalid}
  end

  def decode_public_params(_bytes), do: {:error, :invalid}
end
