defmodule BridgeForTeams.DailyBrief.Sources.Slack do
  @moduledoc """
  The Slack adapter of the daily brief: turns mirror messages into
  `SourceItem`s, writes Slack mentions as people labels for the model, and
  fetches permalinks. Everything that knows Slack's formats is here.
  """

  alias BridgeForTeams.DailyBrief.{ActorRef, Members, People, SourceItem}
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.DailyBriefSetting

  @mention ~r/<@([UW][A-Z0-9]{2,32})(?:\|[^>]*)?>/
  @permalink_batch 50
  # The named-messages read takes at most 200 per channel.
  @max_roots 200

  @doc "A message of the shared stream, from the Salix mirror."
  @spec shared_item(map()) :: SourceItem.t()
  def shared_item(message) do
    %SourceItem{
      source: "slack",
      container_id: message.channel_id,
      id: message.ts,
      thread_id: message.thread_ts,
      author: ActorRef.slack(message.actor_id),
      bot?: message.actor_kind in ["bot", "app"],
      at: ts_datetime(message.ts),
      text: message.text || "",
      mentions: mentions(message.text),
      origin: message
    }
  end

  @doc "The people a Slack text mentions."
  @spec mentions(String.t() | nil) :: [ActorRef.t()]
  def mentions(text) when is_binary(text) do
    @mention |> Regex.scan(text) |> Enum.map(fn [_, id] -> ActorRef.slack(id) end) |> Enum.uniq()
  end

  def mentions(_text), do: []

  @doc "The text with each Slack mention written as its people label."
  @spec label_text(String.t(), People.t()) :: String.t()
  def label_text(text, people) do
    Regex.replace(@mention, text, fn whole, id ->
      People.label(people, ActorRef.slack(id)) || whole
    end)
  end

  @doc """
  The text with each people label written as a Slack mention, which Slack
  shows as the person's current name. The text is already escaped.
  """
  @spec mention_people(String.t(), People.t()) :: String.t()
  def mention_people(text, %People{by_label: by_label}) do
    labels =
      for {label, {ref, _member}} <- by_label, id = ActorRef.slack_id(ref), id, do: {label, id}

    case labels do
      [] ->
        text

      labels ->
        ids = Map.new(labels)

        pattern =
          labels
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort_by(&String.length/1, :desc)
          |> Enum.map_join("|", &Regex.escape/1)

        # A label ends where the ASCII name does: Chinese text may follow it directly.
        Regex.replace(~r/(#{pattern})(?![A-Za-z0-9_-])/u, text, fn _whole, label ->
          "<@#{ids[label]}>"
        end)
    end
  end

  @doc "Where an item was said, for the model: a channel name or a kind of direct message."
  @spec conversation(SourceItem.t(), %{String.t() => String.t()}) :: String.t()
  def conversation(%SourceItem{container_id: id}, names),
    do: "#" <> (names[id] || id)

  @doc """
  The first message of each thread that started before `after_at` and that
  one of the `items` continues, as earlier context. Best effort: a
  channel that cannot be read gives none.
  """
  @spec thread_roots(DailyBriefSetting.t(), [SourceItem.t()], DateTime.t()) :: [SourceItem.t()]
  def thread_roots(settings, items, after_at) do
    floor = after_at |> DateTime.to_unix(:microsecond) |> Kernel./(1_000_000)

    roots =
      for %SourceItem{thread_id: thread} = item <- items,
          is_binary(thread),
          thread != item.id,
          older?(thread, floor),
          uniq: true,
          do: {item.container_id, thread}

    with [_ | _] <- roots, {:ok, source} <- Members.source(settings) do
      roots
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {channel_id, ts} ->
        case Salix.impl().daily_brief_messages(
               Map.merge(source, %{channel_id: channel_id, ts: Enum.take(ts, @max_roots)})
             ) do
          {:ok, %{messages: messages}} -> Enum.map(messages, &shared_item/1)
          {:error, _reason} -> []
        end
      end)
    else
      _none -> []
    end
  end

  defp older?(ts, floor) do
    case Float.parse(ts) do
      {value, _} -> value < floor
      :error -> false
    end
  end

  @doc "The names of the bot's channels, by id; empty when Slack cannot list them."
  @spec channel_names(DailyBriefSetting.t()) :: %{String.t() => String.t()}
  def channel_names(settings) do
    with {:ok, source} <- Members.source(settings),
         {:ok, %{channels: channels}} <-
           Salix.impl().daily_brief_channels(Map.put(source, :member_slack_ids, [])) do
      Map.new(channels, &{&1.id, &1.name})
    else
      _unavailable -> %{}
    end
  end

  @doc """
  The names Slack shows for the Slack people among `refs`, by ref. Best
  effort: people Slack cannot name, or a failed read, are left out.
  """
  @spec user_names([ActorRef.t() | nil], DailyBriefSetting.t()) :: %{ActorRef.t() => String.t()}
  def user_names(refs, settings) do
    ids = refs |> Enum.map(&ActorRef.slack_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with [_ | _] <- ids, {:ok, source} <- Members.source(settings) do
      ids
      |> Enum.chunk_every(@max_roots)
      |> Enum.reduce(%{}, fn chunk, acc ->
        case Salix.impl().daily_brief_user_names(Map.put(source, :user_ids, chunk)) do
          {:ok, names} -> Enum.into(names, acc, fn {id, name} -> {ActorRef.slack(id), name} end)
          {:error, _reason} -> acc
        end
      end)
    else
      _none -> %{}
    end
  end

  @doc "Permalinks of the cited items that have none yet, by item key."
  @spec permalinks([SourceItem.t()], DailyBriefSetting.t()) :: map()
  def permalinks(items, settings) do
    items = Enum.reject(items, &is_binary(&1.permalink))

    with [_ | _] <- items, {:ok, salix} <- Members.source(settings) do
      by_key = Map.new(items, &{{&1.container_id, &1.id}, &1})

      items
      |> Enum.chunk_every(@permalink_batch)
      |> Enum.reduce(%{}, fn batch, acc ->
        messages = Enum.map(batch, &%{channel_id: &1.container_id, ts: &1.id})

        case Salix.impl().daily_brief_permalinks(Map.put(salix, :messages, messages)) do
          {:ok, links} ->
            Enum.reduce(links, acc, fn {key, url}, acc ->
              case Map.fetch(by_key, key) do
                {:ok, item} -> Map.put(acc, SourceItem.key(item), url)
                :error -> acc
              end
            end)

          {:error, _reason} ->
            acc
        end
      end)
    else
      _none -> %{}
    end
  end

  defp ts_datetime(ts) when is_binary(ts) do
    case Float.parse(ts) do
      {value, _} when value > 0 -> DateTime.from_unix!(trunc(value * 1_000_000), :microsecond)
      _ -> nil
    end
  end

  defp ts_datetime(_ts), do: nil
end
