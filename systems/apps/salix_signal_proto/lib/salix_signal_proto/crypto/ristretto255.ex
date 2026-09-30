defmodule SalixSignalProto.Crypto.Ristretto255 do
  @moduledoc """
  The ristretto255 prime-order group (RFC 9496) and its scalars, over the
  libsodium NIF.

  Elements are 32-byte canonical encodings. Scalars are 32-byte little-endian
  integers below the group order
  `l = 2^252 + 27742317777372353535851937790883648493`.

  Untrusted bytes enter through `decode/1` or `decode_scalar/1`. The other
  functions raise `ArgumentError` for an invalid element or a non-canonical
  scalar, so an unchecked value fails loudly instead of being reinterpreted.
  Scalar multiplication runs in constant time. The identity element encodes
  as 32 zero bytes and is a valid result.
  """

  alias SalixSignalProto.Crypto.Native

  @type element :: <<_::256>>
  @type scalar :: <<_::256>>

  @identity <<0::256>>
  @one <<1::little-size(256)>>

  @doc "The identity element."
  @spec identity() :: element()
  def identity, do: @identity

  @doc "The canonical generator."
  @spec generator() :: element()
  def generator, do: mul_base(@one)

  @doc "Returns `{:ok, element}` when `bytes` is a canonical element encoding."
  @spec decode(binary()) :: {:ok, element()} | :error
  def decode(bytes) when is_binary(bytes) do
    if Native.ristretto255_is_valid_point(bytes), do: {:ok, bytes}, else: :error
  end

  @doc "Returns true when `bytes` is a canonical element encoding."
  @spec valid?(binary()) :: boolean()
  def valid?(bytes) when is_binary(bytes), do: Native.ristretto255_is_valid_point(bytes)

  @doc """
  Maps 64 uniformly random bytes to an element (RFC 9496 section 4.3.4,
  element derivation).
  """
  @spec from_uniform_bytes(<<_::512>>) :: element()
  def from_uniform_bytes(<<_::binary-size(64)>> = bytes), do: Native.ristretto255_from_hash(bytes)

  @doc "Adds two elements."
  @spec add(element(), element()) :: element()
  def add(p, q), do: ok!(Native.ristretto255_add(p, q))

  @doc "Subtracts `q` from `p`."
  @spec sub(element(), element()) :: element()
  def sub(p, q), do: ok!(Native.ristretto255_sub(p, q))

  @doc "Multiplies an element by a scalar."
  @spec mul(scalar(), element()) :: element()
  def mul(scalar, element), do: Native.ristretto255_scalarmult(scalar, element)

  @doc "Multiplies the generator by a scalar."
  @spec mul_base(scalar()) :: element()
  def mul_base(scalar), do: Native.ristretto255_scalarmult_base(scalar)

  @doc "Returns `{:ok, scalar}` when `bytes` is a canonical scalar encoding."
  @spec decode_scalar(binary()) :: {:ok, scalar()} | :error
  def decode_scalar(bytes) when is_binary(bytes) do
    if Native.scalar_is_canonical(bytes), do: {:ok, bytes}, else: :error
  end

  @doc "Reduces a 64-byte little-endian integer modulo the group order."
  @spec scalar_from_wide_bytes(<<_::512>>) :: scalar()
  def scalar_from_wide_bytes(<<_::binary-size(64)>> = bytes), do: Native.scalar_reduce(bytes)

  @doc "Returns a new uniformly random nonzero scalar."
  @spec random_scalar() :: scalar()
  def random_scalar do
    scalar = scalar_from_wide_bytes(:crypto.strong_rand_bytes(64))
    if scalar == <<0::256>>, do: random_scalar(), else: scalar
  end

  @doc "Scalar addition modulo the group order."
  @spec scalar_add(scalar(), scalar()) :: scalar()
  def scalar_add(x, y), do: Native.scalar_add(x, y)

  @doc "Scalar subtraction modulo the group order."
  @spec scalar_sub(scalar(), scalar()) :: scalar()
  def scalar_sub(x, y), do: Native.scalar_sub(x, y)

  @doc "Scalar multiplication modulo the group order."
  @spec scalar_mul(scalar(), scalar()) :: scalar()
  def scalar_mul(x, y), do: Native.scalar_mul(x, y)

  @doc "Scalar negation modulo the group order."
  @spec scalar_negate(scalar()) :: scalar()
  def scalar_negate(x), do: Native.scalar_negate(x)

  @doc "Scalar inverse modulo the group order. Zero has no inverse."
  @spec scalar_invert(scalar()) :: {:ok, scalar()} | {:error, :zero_scalar}
  def scalar_invert(x) do
    case Native.scalar_invert(x) do
      :error -> {:error, :zero_scalar}
      inverse -> {:ok, inverse}
    end
  end

  # Both inputs are valid elements (checked in the NIF), so libsodium cannot
  # fail here.
  defp ok!(:error), do: raise(ArgumentError, "invalid ristretto255 element")
  defp ok!(element), do: element
end
