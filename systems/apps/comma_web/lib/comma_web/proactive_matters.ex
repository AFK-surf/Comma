defmodule CommaWeb.ProactiveMatters do
  @moduledoc """
  Groups the proactive check's pending items into matters before one judgment.

  Items share a matter when their text or URL names the same object: a GitHub
  pull request, issue or Actions run, a Linear issue, a Notion page, a Drive
  file, a Slack thread or an email address. A Slack alert, the bot's reply in
  its thread and the next hour's alert about the same account become one
  matter, judged once. The grouping reads no provider and calls no model.

  A matter is judged through its newest item, which carries the others as
  `related`. Settling or retrying a matter applies to every item in it.
  """

  @related_limit 4
  @shared_limit 6
  @related_bytes 300

  defp patterns do
    [
      {"github", ~r<github\.com/([\w.-]+/[\w.-]+)/(?:pull|issues)/(\d+)>},
      {"github-run", ~r<github\.com/([\w.-]+/[\w.-]+)/actions/runs/(\d+)>},
      {"linear", ~r<linear\.app/[\w.-]+/issue/([A-Z][A-Z0-9]+-\d+)>},
      {"notion", ~r<notion\.so/(?:[\w.-]+/)*[\w-]*?([0-9a-f]{32})>},
      {"drive", ~r<docs\.google\.com/\w+/d/([\w-]{20,})>},
      {"drive", ~r<drive\.google\.com/file/d/([\w-]{20,})>},
      {"slack", ~r<archives/(C[A-Z0-9]+)/p\d+\?thread_ts=([\d.]+)>},
      {"email", ~r<[\w.+-]+@[\w-]+(?:\.[\w-]+)+>}
    ]
  end

  @doc "The object keys an item names in its URL, title or excerpt."
  def keys(item) do
    text = Enum.map_join([item["url"], item["title"], item["excerpt"]], "\n", &(&1 || ""))

    for {kind, pattern} <- patterns(),
        match <- Regex.scan(pattern, text),
        into: MapSet.new(),
        do: kind <> ":" <> key(kind, match)
  end

  @doc """
  The matters of `items`, in the order of their first item. Each matter is its
  newest item (by Slack `ts` or arrival order) with the others in `members`
  and summarized in `related`.
  """
  def group(items) do
    indexed = Enum.with_index(items)
    keyed = Enum.map(indexed, fn {item, index} -> {index, keys(item)} end)

    # A key that many arrivals share, such as a notification sender, names no
    # one matter.
    common =
      keyed
      |> Enum.flat_map(fn {_index, keys} -> MapSet.to_list(keys) end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > @shared_limit end)
      |> MapSet.new(&elem(&1, 0))

    keyed = Enum.map(keyed, fn {index, keys} -> {index, MapSet.difference(keys, common)} end)

    parents =
      Enum.reduce(keyed, %{}, fn {index, keys}, parents ->
        Enum.reduce(keyed, Map.put_new(parents, index, index), fn {other, other_keys}, acc ->
          if other < index and not MapSet.disjoint?(keys, other_keys),
            do: union(acc, index, other),
            else: acc
        end)
      end)

    indexed
    |> Enum.group_by(fn {_item, index} -> root(parents, index) end)
    |> Enum.sort_by(fn {root, _members} -> root end)
    |> Enum.map(fn {_root, members} -> matter(Enum.map(members, &elem(&1, 0))) end)
  end

  defp key("email", [address]), do: String.downcase(address)
  defp key(_kind, [_whole | parts]), do: Enum.join(parts, "/")

  defp matter([item]), do: Map.put(item, "members", [item])

  defp matter(items) do
    lead =
      Enum.max_by(Enum.with_index(items), fn {item, index} -> {ts(item), index} end) |> elem(0)

    related =
      for item <- items, item != lead do
        %{
          "title" => item["title"],
          "excerpt" => String.slice(item["excerpt"] || "", 0, @related_bytes)
        }
        |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
      end

    lead
    |> Map.put("members", items)
    |> Map.put("related", Enum.take(related, @related_limit))
  end

  defp ts(%{"facts" => %{"ts" => ts}}) when is_binary(ts) do
    case Float.parse(ts) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp ts(_item), do: 0.0

  defp root(parents, index) do
    case parents[index] do
      ^index -> index
      parent -> root(parents, parent)
    end
  end

  defp union(parents, a, b) do
    {ra, rb} = {root(parents, a), root(parents, b)}
    if ra == rb, do: parents, else: Map.put(parents, max(ra, rb), min(ra, rb))
  end

  @doc "Every item of the given matters."
  def items(matters), do: Enum.flat_map(matters, &(&1["members"] || [&1]))
end
