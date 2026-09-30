defmodule BridgeForTeams.Artifacts.Document do
  @moduledoc """
  Parser for artifact documents: flat frontmatter plus a body of Markdown
  interleaved with fenced `bft:block` JSON.

  An artifact file (see `BridgeForTeams.Artifacts` for the path contract)
  looks like:

      ---
      title: Competitor scan
      kind: brief
      ---
      Prose in **markdown**.

      ```bft:block
      {"type": "kpis", "items": [{"label": "ARR", "value": "$1.2M"}]}
      ```

      More prose.

  `parse/1` splits that into ordered segments the dashboard can render
  natively. Like the rest of the artifact pipeline it is lenient and never
  raises — the file is agent-written. A fence whose JSON does not decode, or
  does not normalize under `BridgeForTeams.Artifacts.Blocks`, becomes an
  `:invalid_block` segment carrying the raw fence text (renderers show a
  quiet placeholder, never the raw JSON as markup).
  """

  alias BridgeForTeams.Artifacts.Blocks
  alias BridgeForTeams.Artifacts.Frontmatter

  # Same fence discipline as structured JSON fences in board updates:
  # opening line, lazy body, closing backticks.
  @fence ~r/```bft:block\s*\n(.*?)```/s
  @max_blocks 32

  @typedoc """
  One ordered piece of a document body: prose, a normalized block, or a
  fence that failed to decode/normalize (carrying its raw inner text).
  """
  @type segment ::
          {:markdown, String.t()}
          | {:block, Blocks.block()}
          | {:invalid_block, String.t()}

  @doc """
  Parse an artifact document into its frontmatter and ordered body segments.

  `meta` is the string-keyed frontmatter map (`%{}` when the file has none —
  the whole input is then treated as body). `segments` preserves document
  order; empty/whitespace-only markdown stretches are dropped, and markdown
  segments are trimmed. At most #{@max_blocks} fences are honored per
  document — every fence past that renders as `:invalid_block` regardless of
  its content.

      iex> BridgeForTeams.Artifacts.Document.parse("Hello **there**")
      %{meta: %{}, segments: [{:markdown, "Hello **there**"}]}
  """
  @spec parse(binary()) :: %{meta: %{String.t() => String.t()}, segments: [segment()]}
  def parse(binary) when is_binary(binary) do
    {meta, body} = Frontmatter.parse(binary)
    %{meta: meta, segments: split_segments(body)}
  end

  defp split_segments(body) do
    # `Regex.split(..., include_captures: true)` alternates strictly between
    # (possibly empty) markdown stretches and whole fence matches, starting
    # with markdown — so even-indexed parts are prose, odd-indexed are fences.
    {segments, _fences_seen} =
      @fence
      |> Regex.split(body, include_captures: true)
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn
        {text, index}, seen when rem(index, 2) == 0 ->
          {markdown_segment(text), seen}

        {fence, _index}, seen ->
          {[fence_segment(fence, seen)], seen + 1}
      end)

    List.flatten(segments)
  end

  defp markdown_segment(text) do
    case String.trim(text) do
      "" -> []
      markdown -> [{:markdown, markdown}]
    end
  end

  defp fence_segment(fence, seen) do
    [_whole, raw] = Regex.run(@fence, fence)
    raw = String.trim(raw)

    with true <- seen < @max_blocks,
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, block} <- Blocks.normalize(decoded) do
      {:block, block}
    else
      _over_cap_or_invalid -> {:invalid_block, raw}
    end
  end
end
