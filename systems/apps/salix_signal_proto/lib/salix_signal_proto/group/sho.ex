defmodule SalixSignalProto.Group.Sho do
  @moduledoc """
  The stateful hash objects of the group credential system (CRS-09a section 3).

  A state holds a 32-byte chaining value, a mode (`:ratcheted` or
  `:absorbing`) and a pending buffer. The functions are pure: each returns the
  new state.

  * SHO-HMAC (`new/1`, section 3.1) is used by almost every derivation.
  * SHO-SHA256 (`new_sha256/1`, section 3.2) derives only the generic
    credential generator table (section 4.3).

  `derive/2` is the shorthand `H(L; d)` of the section: start with label `L`,
  absorb `d` and ratchet.
  """

  alias SalixSignalProto.Crypto.Ristretto255
  alias SalixSignalProto.Group.Elligator

  defstruct [:kind, :cv, mode: :ratcheted, buffer: []]

  @type t :: %__MODULE__{
          kind: :hmac | :sha256,
          cv: <<_::256>>,
          mode: :ratcheted | :absorbing,
          buffer: iodata()
        }

  @doc "Starts a SHO-HMAC state with `label`."
  @spec new(binary()) :: t()
  def new(label) when is_binary(label) do
    %__MODULE__{kind: :hmac, cv: hm(<<0::256>>, [label, 0])}
  end

  @doc "Starts a SHO-SHA256 state with `label`."
  @spec new_sha256(binary()) :: t()
  def new_sha256(label) when is_binary(label) do
    %__MODULE__{kind: :sha256, cv: sha(sha([<<0::512>>, <<0::256>>, label]))}
  end

  @doc "`H(label; data)`: starts with `label`, absorbs `data` and ratchets."
  @spec derive(binary(), iodata()) :: t()
  def derive(label, data), do: label |> new() |> absorb(data) |> ratchet()

  @doc """
  Appends `data` to the pending buffer. Absorbing, even an empty string,
  enters absorbing mode, so the next ratchet changes the chaining value.
  """
  @spec absorb(t(), iodata()) :: t()
  def absorb(%__MODULE__{kind: :sha256, mode: :ratcheted, cv: cv} = state, data),
    do: %{state | mode: :absorbing, buffer: [<<0::512>>, cv, data]}

  def absorb(%__MODULE__{mode: :ratcheted} = state, data),
    do: %{state | mode: :absorbing, buffer: [data]}

  def absorb(%__MODULE__{mode: :absorbing, buffer: buffer} = state, data),
    do: %{state | buffer: [buffer, data]}

  @doc "Folds the pending buffer into the chaining value. No change when ratcheted."
  @spec ratchet(t()) :: t()
  def ratchet(%__MODULE__{mode: :ratcheted} = state), do: state

  def ratchet(%__MODULE__{kind: :hmac, cv: cv, buffer: buffer} = state),
    do: %{state | cv: hm(cv, [buffer, 0]), mode: :ratcheted, buffer: []}

  def ratchet(%__MODULE__{kind: :sha256, buffer: buffer} = state),
    do: %{state | cv: sha(sha(buffer)), mode: :ratcheted, buffer: []}

  @doc "Absorbs `data` and ratchets."
  @spec absorb_and_ratchet(t(), iodata()) :: t()
  def absorb_and_ratchet(state, data), do: state |> absorb(data) |> ratchet()

  @doc """
  Squeezes `n` bytes. The state must be ratcheted. Returns `{bytes, state}`.
  """
  @spec squeeze(t(), non_neg_integer()) :: {binary(), t()}
  def squeeze(%__MODULE__{mode: :ratcheted, cv: cv, kind: kind} = state, n)
      when is_integer(n) and n >= 0 do
    blocks = div(n + 31, 32)

    output =
      for i <- 0..(blocks - 1)//1, into: <<>>, do: block(kind, cv, i)

    {binary_part(output, 0, n), %{state | cv: finish(kind, cv, n)}}
  end

  @doc "Squeezes 64 bytes and reduces them modulo the group order."
  @spec squeeze_scalar(t()) :: {Ristretto255.scalar(), t()}
  def squeeze_scalar(state) do
    {bytes, state} = squeeze(state, 64)
    {Ristretto255.scalar_from_wide_bytes(bytes), state}
  end

  @doc "Squeezes 64 bytes and applies the RFC 9496 one-way map."
  @spec squeeze_point(t()) :: {Ristretto255.element(), t()}
  def squeeze_point(state) do
    {bytes, state} = squeeze(state, 64)
    {Ristretto255.from_uniform_bytes(bytes), state}
  end

  @doc "Squeezes 32 bytes and applies a single Elligator MAP (used only for `M3`)."
  @spec squeeze_map_point(t()) :: {Ristretto255.element(), t()}
  def squeeze_map_point(state) do
    {bytes, state} = squeeze(state, 32)
    {Elligator.map(bytes), state}
  end

  @doc "Squeezes `count` scalars in order."
  @spec squeeze_scalars(t(), non_neg_integer()) :: {[Ristretto255.scalar()], t()}
  def squeeze_scalars(state, count) do
    Enum.map_reduce(List.duplicate(nil, count), state, fn nil, s -> squeeze_scalar(s) end)
  end

  defp block(:hmac, cv, i), do: hm(cv, [<<i::64>>, 1])
  defp block(:sha256, cv, i), do: sha([<<0::504>>, 1, cv, <<i::64>>])

  defp finish(:hmac, cv, n), do: hm(cv, [<<n::64>>, 2])
  defp finish(:sha256, cv, n), do: sha([<<0::504>>, 2, cv, <<n::64>>])

  defp hm(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha(data), do: :crypto.hash(:sha256, data)
end
