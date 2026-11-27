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

  alias SalixStore.ProactiveKernel

  @related_limit 4
  @shared_limit 6
  @related_bytes 300

  @doc "The object keys an item names in its URL, title or excerpt."
  def keys(item), do: ProactiveKernel.keys(item)

  @doc """
  The matters of `items`, in the order of their first item. Each matter is its
  newest item (by Slack `ts` or arrival order) with the others in `members`
  and summarized in `related`.
  """
  def group(items) do
    ProactiveKernel.group_candidates(items,
      shared_limit: @shared_limit,
      related_limit: @related_limit,
      related_bytes: @related_bytes
    )
  end

  @doc "Every item of the given matters."
  def items(matters), do: ProactiveKernel.items_of(matters)
end
