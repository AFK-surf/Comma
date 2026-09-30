defmodule SalixSignalProto.Attachment.IncrementalMac do
  @moduledoc """
  The incremental MAC of an attachment blob (CRS-10 section 9).

  For a stream `data`, key `mac_key` and chunk size `c`, the incremental MAC
  is the concatenation of `HMAC-SHA256(mac_key, data[0 .. j*c))` for every
  `j >= 1` with `j * c <= len(data)`, then one final
  `HMAC-SHA256(mac_key, data)`. Each value covers the whole prefix, not the
  chunk alone. For attachments the stream is the whole encrypted blob and
  the key is the MAC key of the attachment keys.

  `validator/3`, `update/2` and `finish/1` check a stream as it arrives: a
  prefix is verified at each chunk boundary, so a receiver can use it before
  the whole blob is present. The ordinary MAC and digest checks
  (`SalixSignalProto.Attachment.decrypt/4`) still apply to the whole blob.

  HMAC is computed here from SHA-256 hash states (RFC 2104), because an OTP
  `:crypto` hash state stays usable after it is finalized and an HMAC state
  does not.
  """

  import Bitwise

  @block 64
  @mac_bytes 32
  @small_limit 256 * 65_536
  @large_limit 256 * 2_097_152

  defmodule Validator do
    @moduledoc "State of a stream check. Build it with `SalixSignalProto.Attachment.IncrementalMac.validator/3`."
    @enforce_keys [:outer_key, :inner, :chunk_size, :expected, :position, :verified]
    defstruct [:outer_key, :inner, :chunk_size, :expected, :position, :verified]

    @type t :: %__MODULE__{}
  end

  @doc """
  The chunk size a sender uses for a blob of `blob_size` bytes: 65,536 below
  16 MiB, `ceil(blob_size / 256)` below 512 MiB, and 2,097,152 above
  (CRS-10 section 9.3). A receiver uses the pointer's value instead.
  """
  @spec chunk_size(non_neg_integer()) :: pos_integer()
  def chunk_size(blob_size) when is_integer(blob_size) and blob_size >= 0 do
    cond do
      blob_size < @small_limit -> 65_536
      blob_size < @large_limit -> div(blob_size + 255, 256)
      true -> 2_097_152
    end
  end

  @doc "Computes the incremental MAC of `data`."
  @spec compute(binary(), binary(), pos_integer()) :: binary()
  def compute(mac_key, data, chunk_size)
      when is_binary(mac_key) and is_binary(data) and is_integer(chunk_size) and chunk_size > 0 do
    {outer_key, inner} = start(mac_key)
    total = byte_size(data)
    boundaries = div(total, chunk_size)

    {macs, inner} =
      Enum.map_reduce(1..boundaries//1, inner, fn j, inner ->
        inner = :crypto.hash_update(inner, binary_part(data, (j - 1) * chunk_size, chunk_size))
        {finish_mac(outer_key, inner), inner}
      end)

    rest = binary_part(data, boundaries * chunk_size, total - boundaries * chunk_size)
    IO.iodata_to_binary([macs, finish_mac(outer_key, :crypto.hash_update(inner, rest))])
  end

  @doc """
  Checks `data` against an incremental MAC in one call. Returns `:ok` or
  `{:error, :mismatch}`.
  """
  @spec verify(binary(), binary(), pos_integer(), binary()) :: :ok | {:error, :mismatch}
  def verify(mac_key, data, chunk_size, macs) when is_binary(data) do
    with {:ok, validator} <- validator(mac_key, chunk_size, macs),
         {:ok, validator, _verified} <- update(validator, data),
         :ok <- finish(validator) do
      :ok
    else
      {:error, _} -> {:error, :mismatch}
    end
  end

  @doc """
  Starts a stream check. `macs` is the pointer's incremental MAC and
  `chunk_size` the pointer's chunk size. A MAC list that is empty or not a
  whole number of 32-byte values, or a chunk size that is not positive, is
  `{:error, :invalid}`.
  """
  @spec validator(binary(), pos_integer(), binary()) :: {:ok, Validator.t()} | {:error, :invalid}
  def validator(mac_key, chunk_size, macs)
      when is_binary(mac_key) and is_integer(chunk_size) and is_binary(macs) do
    if chunk_size > 0 and byte_size(macs) >= @mac_bytes and rem(byte_size(macs), @mac_bytes) == 0 do
      {outer_key, inner} = start(mac_key)

      {:ok,
       %Validator{
         outer_key: outer_key,
         inner: inner,
         chunk_size: chunk_size,
         expected: macs,
         position: 0,
         verified: 0
       }}
    else
      {:error, :invalid}
    end
  end

  def validator(_mac_key, _chunk_size, _macs), do: {:error, :invalid}

  @doc """
  Feeds the next bytes of the stream. Returns the new state and the number
  of leading stream bytes verified so far, or `{:error, :mismatch}` when a
  chunk boundary MAC differs or no expected value is left for it.
  """
  @spec update(Validator.t(), binary()) ::
          {:ok, Validator.t(), non_neg_integer()} | {:error, :mismatch}
  def update(%Validator{} = validator, data) when is_binary(data) do
    case feed(validator, data) do
      {:ok, validator} -> {:ok, validator, validator.verified}
      error -> error
    end
  end

  @doc """
  Ends the stream. Exactly one expected value must remain, and it must equal
  the MAC of the whole stream.
  """
  @spec finish(Validator.t()) :: :ok | {:error, :mismatch}
  def finish(%Validator{expected: expected} = validator) do
    if byte_size(expected) == @mac_bytes and
         :crypto.hash_equals(finish_mac(validator.outer_key, validator.inner), expected) do
      :ok
    else
      {:error, :mismatch}
    end
  end

  defp feed(validator, <<>>), do: {:ok, validator}

  defp feed(%Validator{chunk_size: chunk, position: position} = validator, data) do
    to_boundary = chunk - rem(position, chunk)

    if byte_size(data) < to_boundary do
      {:ok,
       %{
         validator
         | inner: :crypto.hash_update(validator.inner, data),
           position: position + byte_size(data)
       }}
    else
      <<head::binary-size(^to_boundary), rest::binary>> = data
      inner = :crypto.hash_update(validator.inner, head)
      position = position + to_boundary

      case validator.expected do
        <<next::binary-size(@mac_bytes), remaining::binary>> ->
          if :crypto.hash_equals(finish_mac(validator.outer_key, inner), next) do
            feed(
              %{
                validator
                | inner: inner,
                  position: position,
                  expected: remaining,
                  verified: position
              },
              rest
            )
          else
            {:error, :mismatch}
          end

        _ ->
          {:error, :mismatch}
      end
    end
  end

  # RFC 2104 with SHA-256: keys longer than the block are hashed first.
  defp start(mac_key) do
    key = if byte_size(mac_key) > @block, do: :crypto.hash(:sha256, mac_key), else: mac_key
    key = key <> :binary.copy(<<0>>, @block - byte_size(key))
    inner = :crypto.hash_update(:crypto.hash_init(:sha256), xor_bytes(key, 0x36))
    {xor_bytes(key, 0x5C), inner}
  end

  defp finish_mac(outer_key, inner) do
    :crypto.hash(:sha256, [outer_key, :crypto.hash_final(inner)])
  end

  defp xor_bytes(key, pad), do: for(<<byte <- key>>, into: <<>>, do: <<bxor(byte, pad)>>)
end
