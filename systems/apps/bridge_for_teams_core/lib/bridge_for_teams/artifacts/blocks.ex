defmodule BridgeForTeams.Artifacts.Blocks do
  @moduledoc """
  The closed v1 vocabulary of structured artifact blocks, with lenient
  normalization.

  Agents embed blocks in artifact documents as fenced `bft:block` JSON (split
  out by `BridgeForTeams.Artifacts.Document`) and may attach one as the
  `"hero"` of a task-update payload. Either way the JSON is agent-written, so
  `normalize/1` never raises: it coerces what it can, drops what it can't,
  and only returns `:invalid` when nothing usable remains.

  Vocabulary (`types/0`):

    * `"kpis"` — `items` of `%{"label", "value"}` plus optional `"delta"`
      and `"note"`;
    * `"table"` — `"columns"` (list of strings) and `"rows"` (list of
      string lists, each padded/truncated to the column count);
    * `"list"` — `items` of strings, with an optional `"style"` in
      `plain | risks | actions | watch` (anything else becomes `"plain"`);
    * `"links"` — `items` of `%{"title", "url"}`; the url must parse as
      http(s) with a host or the item is dropped (no `javascript:`, `data:`
      etc. ever survives normalization);
    * `"timeline"` — `items` of `%{"date", "event"}`;
    * `"entities"` — `items` of `%{"name"}` plus optional `"detail"`.

  Leniency rules, applied uniformly:

    * scalar fields accept strings, numbers and booleans (coerced with
      `to_string/1`); anything else counts as missing;
    * unknown keys are dropped;
    * predictable key near-misses are accepted as synonyms: `"kind"` for
      `"type"`, `"headers"` for a table's `"columns"`, and `"label"` /
      `"title"` / `"name"` for one another on kpis, links and entities
      items (agents blend these constantly — the frontmatter schema says
      `kind:` and the kpis example says `label`, so the drift is primed by
      our own contract prompt);
    * an optional block-level `"title"` is kept as a caption on any block;
    * a single item given where a list is expected is wrapped into a list;
    * items missing a required field are dropped;
    * at most 24 items (columns / rows) per block — the excess is truncated;
    * strings are trimmed and sliced: labels/titles/names/columns to 120
      characters, kpi values to 40, everything else to 500;
    * a block that still fails (unknown `"type"`, unusable required fields)
      but carries usable string `items` degrades to a plain `"list"` — a
      near-miss must never render worse than prose would have. Only when
      nothing usable remains is the result `:invalid`.
  """

  @types ~w(kpis table list links timeline entities)
  @list_styles ~w(plain risks actions watch)

  @max_items 24
  @name_max 120
  @value_max 40
  @text_max 500

  @typedoc "A normalized, string-keyed block map (`%{\"type\" => ..., ...}`)."
  @type block :: %{optional(String.t()) => term()}

  @doc """
  The closed list of block types this vocabulary version understands.
  """
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  Normalize a decoded `bft:block` JSON object into its canonical shape.

  Returns `{:ok, block}` — a string-keyed map holding only known, coerced,
  capped fields — or `:invalid` when the input is not a map or has nothing
  usable left after normalization (including the string-items fallback).

      iex> BridgeForTeams.Artifacts.Blocks.normalize(%{"type" => "kpis", "items" => %{"label" => "ARR", "value" => 12}})
      {:ok, %{"type" => "kpis", "items" => [%{"label" => "ARR", "value" => "12"}]}}

      iex> BridgeForTeams.Artifacts.Blocks.normalize(%{"kind" => "list", "items" => ["reuse the synonym"]})
      {:ok, %{"type" => "list", "style" => "plain", "items" => ["reuse the synonym"]}}

      iex> BridgeForTeams.Artifacts.Blocks.normalize(%{"type" => "chart", "items" => [%{"x" => 1}]})
      :invalid
  """
  @spec normalize(term()) :: {:ok, block()} | :invalid
  def normalize(raw) when is_map(raw) do
    raw = canonicalize(raw)

    result =
      case Map.get(raw, "type") do
        type when is_binary(type) ->
          do_normalize(type |> String.trim() |> String.downcase(), raw)

        _missing ->
          :invalid
      end

    result
    |> or_fallback_list(raw)
    |> put_block_title(raw)
  end

  def normalize(_other), do: :invalid

  # Accepted top-level key synonyms; the canonical key wins when both exist.
  defp canonicalize(raw) do
    raw
    |> put_synonym("type", "kind")
    |> put_synonym("columns", "headers")
  end

  defp put_synonym(map, canonical, synonym) do
    case {Map.get(map, canonical), Map.get(map, synonym)} do
      {nil, value} when value != nil -> Map.put(map, canonical, value)
      _canonical_wins -> map
    end
  end

  # A block that failed typed normalization but still carries usable string
  # items renders as a plain list rather than the opaque invalid card.
  defp or_fallback_list({:ok, _block} = ok, _raw), do: ok

  defp or_fallback_list(:invalid, raw) do
    case raw |> normalize_items(&List.wrap(text(&1, @text_max))) |> wrap("list") do
      {:ok, block} -> {:ok, Map.put(block, "style", "plain")}
      :invalid -> :invalid
    end
  end

  defp put_block_title({:ok, block}, raw),
    do: {:ok, put_optional(block, "title", text(Map.get(raw, "title"), @name_max))}

  defp put_block_title(:invalid, _raw), do: :invalid

  defp do_normalize("kpis", raw) do
    raw
    |> normalize_items(fn item ->
      with true <- is_map(item),
           label when is_binary(label) <- first_text(item, ~w(label title name), @name_max),
           value when is_binary(value) <- text(Map.get(item, "value"), @value_max) do
        [
          %{"label" => label, "value" => value}
          |> put_optional("delta", text(Map.get(item, "delta"), @text_max))
          |> put_optional("note", text(Map.get(item, "note"), @text_max))
        ]
      else
        _missing -> []
      end
    end)
    |> wrap("kpis")
  end

  defp do_normalize("table", raw) do
    columns =
      raw
      |> Map.get("columns")
      |> as_list()
      |> Enum.flat_map(&List.wrap(text(&1, @name_max)))
      |> Enum.take(@max_items)

    # Rows only make sense against a usable column set — bail before shaping
    # them so a scalar row never pads against a zero/negative width.
    if columns == [] do
      :invalid
    else
      rows =
        raw
        |> Map.get("rows")
        |> as_list()
        |> Enum.flat_map(&normalize_row(&1, length(columns)))
        |> Enum.take(@max_items)

      if rows == [] do
        :invalid
      else
        {:ok, %{"type" => "table", "columns" => columns, "rows" => rows}}
      end
    end
  end

  defp do_normalize("list", raw) do
    style =
      case coerce(Map.get(raw, "style")) do
        style when is_binary(style) ->
          style = style |> String.trim() |> String.downcase()
          if style in @list_styles, do: style, else: "plain"

        _missing ->
          "plain"
      end

    case raw |> normalize_items(&List.wrap(text(&1, @text_max))) |> wrap("list") do
      {:ok, block} -> {:ok, Map.put(block, "style", style)}
      :invalid -> :invalid
    end
  end

  defp do_normalize("links", raw) do
    raw
    |> normalize_items(fn item ->
      with true <- is_map(item),
           url when is_binary(url) <- http_url(Map.get(item, "url")) do
        title =
          first_text(item, ~w(title label name), @name_max) || String.slice(url, 0, @name_max)

        [%{"title" => title, "url" => url}]
      else
        _invalid -> []
      end
    end)
    |> wrap("links")
  end

  defp do_normalize("timeline", raw) do
    raw
    |> normalize_items(fn item ->
      with true <- is_map(item),
           date when is_binary(date) <- text(Map.get(item, "date"), @text_max),
           event when is_binary(event) <- text(Map.get(item, "event"), @text_max) do
        [%{"date" => date, "event" => event}]
      else
        _missing -> []
      end
    end)
    |> wrap("timeline")
  end

  defp do_normalize("entities", raw) do
    raw
    |> normalize_items(fn item ->
      with true <- is_map(item),
           name when is_binary(name) <- first_text(item, ~w(name title label), @name_max) do
        [put_optional(%{"name" => name}, "detail", text(Map.get(item, "detail"), @text_max))]
      else
        _missing -> []
      end
    end)
    |> wrap("entities")
  end

  defp do_normalize(_unknown_type, _raw), do: :invalid

  defp normalize_items(raw, item_fun) do
    raw
    |> Map.get("items")
    |> as_list()
    |> Enum.flat_map(item_fun)
    |> Enum.take(@max_items)
  end

  defp wrap([], _type), do: :invalid
  defp wrap(items, type), do: {:ok, %{"type" => type, "items" => items}}

  # A single item given where a list is expected wraps into a list.
  defp as_list(nil), do: []
  defp as_list(list) when is_list(list), do: list
  defp as_list(single), do: [single]

  # A row must line up with the columns: cells are coerced (unusable cells
  # become ""), truncated or padded to the column count. A bare scalar is a
  # one-cell row; anything else unusable drops the row.
  defp normalize_row(row, width) when is_list(row) do
    cells =
      row
      |> Enum.map(&(text(&1, @text_max) || ""))
      |> Enum.take(width)

    [cells ++ List.duplicate("", width - length(cells))]
  end

  defp normalize_row(row, width) do
    case text(row, @text_max) do
      nil -> []
      cell -> [[cell | List.duplicate("", width - 1)]]
    end
  end

  # The first usable value among synonym item keys, canonical key first.
  defp first_text(item, keys, max) do
    Enum.find_value(keys, &text(Map.get(item, &1), max))
  end

  # Coerced + trimmed + sliced scalar, or nil when the value is unusable.
  defp text(value, max) do
    case coerce(value) do
      nil ->
        nil

      string ->
        case String.trim(string) do
          "" -> nil
          trimmed -> String.slice(trimmed, 0, max)
        end
    end
  end

  defp coerce(value) when is_binary(value), do: value
  defp coerce(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp coerce(_other), do: nil

  # Only absolute http(s) URLs with a host survive; javascript:, data:, ftp:,
  # protocol-relative and bare-path values are all rejected.
  defp http_url(value) do
    case text(value, @text_max) do
      nil ->
        nil

      url ->
        uri = URI.parse(url)
        scheme = uri.scheme && String.downcase(uri.scheme)

        if scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
          url
        else
          nil
        end
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
