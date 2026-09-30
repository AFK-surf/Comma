defmodule SalixIM.SlackMessageMirror.BlockText do
  @moduledoc """
  Flattens Slack `blocks` and `attachments` into searchable plain text.

  A message's `text` field is only the whole story when a human typed it. Slack
  fills `text` with the mrkdwn source for client-composed messages, but an app
  posting through `chat.postMessage` puts its content in `blocks` and may leave
  `text` as a short notification fallback or nothing at all. Our own Task cards
  are exactly that shape, and so is most of what alerting and issue-tracker
  integrations post. Storing only `text` loses the body of precisely the
  messages an agent is most often asked about, and loses it as an empty message
  rather than a gap.

  ## The walk is by key, not by block type

  Block Kit has dozens of block and element types and Slack adds more; this
  repo alone emits `card`, `plan`, `task_card`, `markdown` and `table`. A
  flattener that enumerated types dropped every type it had not heard of, and
  did so silently. This one never looks at a block's type to decide whether to
  read it. It walks the whole payload and collects every string found under a
  key that Block Kit uses for human-readable content — `text`, `title`,
  `alt_text`, `label`, `placeholder`, and so on — at any depth. A block type
  invented tomorrow is indexed today, because its words still live under
  `text`.

  What is NOT collected is decided the same way: `value`, `url`, `image_url`,
  `action_id` and every other key are skipped whatever they hold. `value` is
  app-defined control state on a block and human content on a legacy
  attachment field, so the two payloads are walked with two key sets.

  ## Mentions are rendered the way `text` renders them

  The rich-text elements that stand for something rather than saying it —
  `user`, `channel`, `usergroup`, `broadcast`, `emoji`, `link` — are the only
  shapes read by type. A `user` element becomes `<@U123>`, the same markup
  Slack puts in `text`, so one query finds a mention whether it arrived through
  the fallback or through a block.

  ## Deduplication against `text` is by containment, not by assumption

  A client-composed message carries both: `text` holds the mrkdwn and `blocks`
  holds an equivalent `rich_text`. Flattening both would index every human
  message twice. What must NOT be inferred is that a non-empty `text` means
  the blocks are redundant — an app can post a one-line fallback in `text` and
  the real body in a block. So every fragment is collected, and one is dropped
  only when `text` already contains it verbatim, which is lossless by
  construction.
  """

  @max_chars 64_000

  # Keys under which Block Kit puts words meant for a person. Applies at every
  # depth: a text object's `text`, a button's `text`, an option's `text`.
  @block_text_keys ~w(
    text alt_text title subtitle body subtext description label hint
    placeholder fallback pretext status
  )

  # Legacy attachments say `value` for a field's content and add a few names
  # of their own.
  @attachment_text_keys @block_text_keys ++ ~w(value author_name footer)

  @doc """
  Returns the flattened searchable text of one Slack message.

  `:dedupe_against` is the message's own `text`; fragments already contained in
  it are dropped. See the moduledoc for why containment rather than a rule
  about which blocks to trust.
  """
  @spec flatten(map(), keyword()) :: String.t()
  def flatten(message, opts \\ [])

  def flatten(message, opts) when is_map(message) do
    text = opts |> Keyword.get(:dedupe_against, "") |> to_string()

    (walk(message["blocks"], @block_text_keys) ++
       walk(message["attachments"], @attachment_text_keys))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&already_indexed?(&1, text))
    # `fallback` usually repeats `text`, and a card often repeats its header in
    # a section. The index gains nothing from either.
    |> Enum.uniq()
    |> Enum.join("\n")
    |> truncate()
  end

  def flatten(_message, _opts), do: ""

  @doc false
  def max_chars, do: @max_chars

  defp already_indexed?(_fragment, ""), do: false
  defp already_indexed?(fragment, text), do: String.contains?(text, fragment)

  defp walk(list, keys) when is_list(list), do: Enum.flat_map(list, &walk(&1, keys))

  # The elements that stand for something. Each is rendered as `text` would
  # render it and nothing else inside it is read.
  defp walk(%{"type" => "user"} = element, _keys), do: [mention("@", element["user_id"])]
  defp walk(%{"type" => "channel"} = element, _keys), do: [mention("#", element["channel_id"])]

  defp walk(%{"type" => "usergroup"} = element, _keys),
    do: [mention("!subteam^", element["usergroup_id"])]

  defp walk(%{"type" => "broadcast"} = element, _keys), do: [mention("!", element["range"])]

  defp walk(%{"type" => "emoji"} = element, _keys) do
    case trim(element["name"]) do
      "" -> []
      name -> [":#{name}:"]
    end
  end

  # A link's visible words if it has any, else the address itself, which is
  # what a reader would otherwise see.
  defp walk(%{"type" => "link"} = element, _keys),
    do: [Enum.find([trim(element["text"]), trim(element["url"])], "", &(&1 != ""))]

  defp walk(%{} = map, keys) do
    Enum.flat_map(map, fn
      {key, value} when is_binary(value) -> if key in keys, do: [trim(value)], else: []
      {_key, value} when is_map(value) or is_list(value) -> walk(value, keys)
      {_key, _scalar} -> []
    end)
  end

  defp walk(_scalar, _keys), do: []

  defp mention(_prefix, id) when not is_binary(id), do: ""

  defp mention(prefix, id) do
    case String.trim(id) do
      "" -> ""
      id -> "<#{prefix}#{id}>"
    end
  end

  # Truncation rather than rejection: this is a derived search projection, not
  # the message. Dropping the row would lose a message Slack still has, and the
  # untruncated content stays available in the retained `blocks`.
  defp truncate(text) do
    if String.length(text) > @max_chars, do: String.slice(text, 0, @max_chars), else: text
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
