defmodule SalixAgent.SSH.Output do
  @moduledoc """
  Bounded output of one SSH session: a byte ring with absolute offsets.

  Offsets count every byte the session received. The ring keeps the newest
  `max` bytes; older bytes are dropped and a read from before `base` reports
  `truncated`. Readers keep their own cursor (`next_offset`), like
  `env.process_tail`.
  """

  defstruct chunks: :queue.new(), size: 0, base: 0, next: 0, max: 1_048_576

  @type t :: %__MODULE__{}

  @spec new(pos_integer()) :: t()
  def new(max), do: %__MODULE__{max: max}

  @spec append(t(), binary()) :: t()
  def append(out, ""), do: out

  def append(out, data) do
    trim(%{
      out
      | chunks: :queue.in(data, out.chunks),
        size: out.size + byte_size(data),
        next: out.next + byte_size(data)
    })
  end

  defp trim(%{size: size, max: max} = out) when size <= max, do: out

  defp trim(out) do
    {{:value, chunk}, rest} = :queue.out(out.chunks)
    excess = out.size - out.max

    if byte_size(chunk) <= excess do
      trim(%{
        out
        | chunks: rest,
          size: out.size - byte_size(chunk),
          base: out.base + byte_size(chunk)
      })
    else
      kept = binary_part(chunk, excess, byte_size(chunk) - excess)
      %{out | chunks: :queue.in_r(kept, rest), size: out.size - excess, base: out.base + excess}
    end
  end

  @doc """
  Bytes from `from` (clamped to the retained window), at most `max_bytes`.
  Returns `{start, bytes}`; `start > from` means bytes were lost.
  """
  @spec slice(t(), non_neg_integer(), pos_integer()) :: {non_neg_integer(), binary()}
  def slice(out, from, max_bytes) do
    start = from |> max(out.base) |> min(out.next)
    skip = start - out.base

    {bytes, _skip, _left} =
      out.chunks
      |> :queue.to_list()
      |> Enum.reduce_while({[], skip, max_bytes}, fn
        _chunk, {acc, _skip, 0} ->
          {:halt, {acc, 0, 0}}

        chunk, {acc, skip, left} when skip >= byte_size(chunk) ->
          {:cont, {acc, skip - byte_size(chunk), left}}

        chunk, {acc, skip, left} ->
          take = min(byte_size(chunk) - skip, left)
          {:cont, {[acc, binary_part(chunk, skip, take)], 0, left - take}}
      end)

    {start, IO.iodata_to_binary(bytes)}
  end

  @doc "The offset `tail_bytes` before the end, clamped to the retained window."
  @spec tail_start(t(), non_neg_integer()) :: non_neg_integer()
  def tail_start(out, tail_bytes), do: max(out.next - tail_bytes, out.base)

  @doc """
  Terminal output as plain text: escape sequences and control characters
  removed, CRLF as LF, a carriage return keeps only the text written after
  it on that line, backspace erases, and invalid UTF-8 is replaced.
  """
  @spec text(binary()) :: String.t()
  def text(bytes) do
    bytes
    |> SalixAgent.Utf8.scrub()
    |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\)?/, "")
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/\e[ -\/]*[0-~]/, "")
    |> String.replace(~r/\e\[?[0-?]*[ -\/]*\z/, "")
    |> String.replace("\r\n", "\n")
    |> backspaces(8)
    |> String.replace(~r/[\x00-\x07\x0B-\x0C\x0E-\x1F\x7F]/, "")
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> line |> String.split("\r") |> List.last() end)
  end

  defp backspaces(text, 0), do: text

  defp backspaces(text, passes) do
    next = String.replace(text, ~r/[^\x08\n]\x08/u, "")
    if next == text, do: String.replace(text, "\b", ""), else: backspaces(next, passes - 1)
  end
end
