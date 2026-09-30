defmodule SalixSignalProto.Session.Spqr.Message do
  @moduledoc """
  The post-quantum message in field 5 of a double-ratchet message
  (CRS-04b §4): `version (1 byte) || epoch (varint) || index (varint) ||
  type (1 byte) [|| chunk index (varint) || chunk (32 bytes)]`, with
  trailing bytes ignored.

  | Type | Meaning | Chunk |
  | --- | --- | --- |
  | 0 | none | no |
  | 1 | header chunk | yes |
  | 2 | key-part chunk | yes |
  | 3 | key-part chunk with ciphertext-1 acknowledgement | yes |
  | 4 | ciphertext-1 acknowledgement | no |
  | 5 | ciphertext-1 chunk | yes |
  | 6 | ciphertext-2 chunk | yes |

  For a version of 2 or more only the epoch and index are read (CRS-04b
  §11).
  """

  import Bitwise

  defstruct [:version, :epoch, :index, :type, :chunk_index, :chunk]

  @type t :: %__MODULE__{
          version: pos_integer(),
          epoch: pos_integer(),
          index: non_neg_integer(),
          type: 0..6 | nil,
          chunk_index: non_neg_integer() | nil,
          chunk: <<_::256>> | nil
        }

  @chunk_types [1, 2, 3, 5, 6]
  @max_index 0xFFFFFFFF
  @max_chunk_index 65_535

  @doc "Encodes a version-1 message."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{epoch: epoch, index: index, type: type} = message) do
    head = <<1>> <> varint(epoch) <> varint(index) <> <<type>>

    if type in @chunk_types,
      do: head <> varint(message.chunk_index) <> message.chunk,
      else: head
  end

  @doc """
  Parses a post-quantum message. Returns `{:error, :version}` for an empty
  message or version 0, and `{:error, :malformed}` for a message that does
  not parse.
  """
  @spec decode(binary() | nil) :: {:ok, t()} | {:error, :version | :malformed}
  def decode(nil), do: {:error, :version}
  def decode(<<>>), do: {:error, :version}
  def decode(<<0, _::binary>>), do: {:error, :version}

  def decode(<<version, rest::binary>>) do
    with {:ok, epoch, rest} when epoch >= 1 <- read_varint(rest),
         {:ok, index, rest} when index <= @max_index <- read_varint(rest) do
      message = %__MODULE__{version: version, epoch: epoch, index: index}
      if version == 1, do: decode_body(message, rest), else: {:ok, message}
    else
      _ -> {:error, :malformed}
    end
  end

  defp decode_body(message, <<type, rest::binary>>) when type in @chunk_types do
    with {:ok, chunk_index, <<chunk::binary-size(32), _trailing::binary>>}
         when chunk_index <= @max_chunk_index <- read_varint(rest) do
      {:ok, %{message | type: type, chunk_index: chunk_index, chunk: chunk}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp decode_body(message, <<type, _trailing::binary>>) when type in [0, 4],
    do: {:ok, %{message | type: type}}

  defp decode_body(_message, _rest), do: {:error, :malformed}

  # Protocol Buffers varint: at most 10 bytes.
  defp read_varint(bytes), do: read_varint(bytes, 0, 0)

  defp read_varint(_bytes, _value, 10), do: :error
  defp read_varint(<<>>, _value, _count), do: :error

  defp read_varint(<<byte, rest::binary>>, value, count) do
    value = value ||| (byte &&& 0x7F) <<< (7 * count)
    if byte < 0x80, do: {:ok, value, rest}, else: read_varint(rest, value, count + 1)
  end

  defp varint(value) when value < 0x80, do: <<value>>
  defp varint(value), do: <<(value &&& 0x7F) ||| 0x80>> <> varint(value >>> 7)
end
