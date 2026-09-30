defmodule BridgeForTeams.Artifacts.Frontmatter do
  @moduledoc """
  Lenient parser for the flat frontmatter block at the top of an artifact
  document.

  Artifact documents (including report runs) are Markdown files whose first
  line is `---`, followed by one `key: value` scalar per line, closed by
  another `---` line (see `BridgeForTeams.Artifacts` for the full file
  contract). The block is agent-written, so this parser never raises and
  never rejects a file:

    * keys are downcased and trimmed; values are trimmed, with one pair of
      matching surrounding quotes (`"` or `'`) stripped;
    * lines without a `:` (or with an empty key) are skipped;
    * CRLF line endings are accepted;
    * a file that does not start with `---`, or whose block is never closed,
      has no frontmatter — the whole input is returned as the body.

  No YAML library is involved (nested structures, lists, multi-line values
  etc. are deliberately unsupported — the contract is flat scalars only).
  """

  @doc """
  Split `binary` into `{frontmatter, body}`.

  `frontmatter` is a string-keyed map of the scalar pairs found in a leading
  `---` block (`%{}` when there is none); `body` is everything after the
  closing delimiter line, unchanged. Duplicate keys keep the last value.

      iex> BridgeForTeams.Artifacts.Frontmatter.parse("---\\ntitle: Daily\\n---\\nHi")
      {%{"title" => "Daily"}, "Hi"}

      iex> BridgeForTeams.Artifacts.Frontmatter.parse("no frontmatter here")
      {%{}, "no frontmatter here"}
  """
  @spec parse(binary()) :: {%{String.t() => String.t()}, String.t()}
  def parse(binary) when is_binary(binary) do
    case String.split(binary, "\n", parts: 2) do
      [first, rest] ->
        if delimiter?(first) do
          parse_block(rest, binary)
        else
          {%{}, binary}
        end

      _no_newline ->
        {%{}, binary}
    end
  end

  # `rest` is everything after the opening delimiter line; `whole` is the
  # original input, returned untouched when the block turns out to be unclosed.
  defp parse_block(rest, whole) do
    lines = String.split(rest, "\n")

    case Enum.split_while(lines, &(not delimiter?(&1))) do
      {_pairs, []} ->
        # No closing `---`: not frontmatter after all.
        {%{}, whole}

      {pair_lines, [_closing | body_lines]} ->
        {parse_pairs(pair_lines), Enum.join(body_lines, "\n")}
    end
  end

  defp delimiter?(line), do: String.trim(line) == "---"

  defp parse_pairs(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(String.trim_trailing(line, "\r"), ":", parts: 2) do
        [key, value] ->
          case key |> String.trim() |> String.downcase() do
            "" -> acc
            key -> Map.put(acc, key, value |> String.trim() |> strip_quotes())
          end

        _no_colon ->
          acc
      end
    end)
  end

  # Strip exactly one pair of matching surrounding quotes; a lone quote or
  # mismatched pair is kept verbatim.
  defp strip_quotes(<<q, rest::binary>> = value) when q in [?", ?'] do
    if rest != "" and String.ends_with?(rest, <<q>>) do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      value
    end
  end

  defp strip_quotes(value), do: value
end
