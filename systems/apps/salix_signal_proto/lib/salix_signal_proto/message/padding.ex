defmodule SalixSignalProto.Message.Padding do
  @moduledoc """
  Padding of the serialized content container before 1:1 or sender-key
  encryption (CRS-05 §4).

  For content of `n` bytes the padded plaintext is
  `ceil((n + 2) / 80) * 80 - 1` bytes: the content, one `0x80` byte, then
  `0x00` bytes. The 1:1 cipher adds one byte of block padding, so the
  encrypted body is a multiple of 80 bytes.

  Removing the padding keeps every byte before the last `0x80`, which may be
  followed only by `0x00` bytes. Any other input is malformed, and Comma treats
  a malformed padding as an undecryptable message (CRS-05 §4, open question
  4).
  """

  @block 80

  @doc "Pads a serialized content container."
  @spec pad(binary()) :: binary()
  def pad(content) when is_binary(content) do
    n = byte_size(content)
    total = div(n + 2 + @block - 1, @block) * @block - 1
    content <> <<0x80>> <> :binary.copy(<<0>>, total - n - 1)
  end

  @doc """
  Removes the padding. Returns `{:error, :malformed}` when the last byte that
  is not `0x00` is not `0x80`, or when there is no such byte.
  """
  @spec unpad(binary()) :: {:ok, binary()} | {:error, :malformed}
  def unpad(padded) when is_binary(padded) do
    case last_non_zero(padded, byte_size(padded) - 1) do
      {0x80, index} -> {:ok, binary_part(padded, 0, index)}
      _ -> {:error, :malformed}
    end
  end

  defp last_non_zero(_padded, index) when index < 0, do: :none

  defp last_non_zero(padded, index) do
    case :binary.at(padded, index) do
      0 -> last_non_zero(padded, index - 1)
      byte -> {byte, index}
    end
  end
end
