defmodule BridgeForTeams.DailyBrief.Sources.LarkSuite do
  @moduledoc """
  The Feishu and Lark adapter of the daily brief, shared by
  `Sources.Feishu` and `Sources.Lark`: each passes its provider. Turns mirror
  messages into `SourceItem`s, writes mentions as people labels for the model
  and back, and links to chats.

  Inside a brief's text a person is written `<@ou_…>`, the same markup the
  Slack path uses for a Slack id; `Sinks.Feishu` and `Sinks.Lark` turn it
  into the card's `<at id=…></at>`. A message's `ts` is its message id and
  `thread_ts` its thread's root message id; `at_us` is when it was sent.
  Feishu and Lark give the bot no link to one message, so a message's link
  opens its chat.
  """

  alias BridgeForTeams.DailyBrief.{ActorRef, Members, People, SourceItem, Sources}
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.DailyBriefSetting

  @mention ~r/<@(ou_[A-Za-z0-9_-]{2,64})>/
  @open_id ~r/^ou_[A-Za-z0-9_-]{2,64}$/
  @max_roots 200
  @permalink_batch 50

  @doc "Links of the cited items that have none yet, by item key."
  @spec permalinks(String.t(), [SourceItem.t()], DailyBriefSetting.t()) :: map()
  def permalinks(_provider, items, settings) do
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

  @doc "A message of the shared stream."
  @spec shared_item(String.t(), map()) :: SourceItem.t()
  def shared_item(provider, message) do
    %SourceItem{
      source: provider,
      container_id: message.channel_id,
      id: message.ts,
      thread_id: message[:thread_ts],
      author: ActorRef.of(provider, message.actor_id),
      bot?: message.actor_kind in ["bot", "app"],
      at: at(message[:at_us]),
      text: message.text || "",
      mentions:
        message
        |> Map.get(:mentions, [])
        |> List.wrap()
        |> Enum.map(&ActorRef.of(provider, &1))
        |> Enum.concat(mentions(provider, message.text))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      permalink: message[:permalink],
      origin: message
    }
  end

  @doc "The people a brief's text mentions (`<@ou_…>`)."
  @spec mentions(String.t(), String.t() | nil) :: [ActorRef.t()]
  def mentions(provider, text) when is_binary(text) do
    @mention
    |> Regex.scan(text)
    |> Enum.map(fn [_, id] -> ActorRef.of(provider, id) end)
    |> Enum.uniq()
  end

  def mentions(_provider, _text), do: []

  @doc "The text with each `<@ou_…>` written as its people label."
  @spec label_text(String.t(), String.t(), People.t()) :: String.t()
  def label_text(provider, text, people) do
    Regex.replace(@mention, text, fn whole, id ->
      People.label(people, ActorRef.of(provider, id)) || whole
    end)
  end

  @doc "The text with each people label written as `<@ou_…>`, or as a plain name."
  @spec mention_people(String.t(), String.t(), People.t()) :: String.t()
  def mention_people(provider, text, %People{by_label: by_label} = people) do
    labels =
      for {label, {ref, _member}} <- by_label, id = ActorRef.id_of(provider, ref), id do
        replacement =
          cond do
            People.mentionable?(people, ref) and Regex.match?(@open_id, id) ->
              "<@#{id}>"

            Regex.match?(~r/^@ou_[A-Za-z0-9_-]{2,64}(-\d+)?$/, label) ->
              "某人"

            true ->
              label |> String.trim_leading("@") |> String.replace("_", " ")
          end

        {label, replacement}
      end

    case labels do
      [] ->
        text

      labels ->
        replacements = Map.new(labels)

        pattern =
          labels
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort_by(&String.length/1, :desc)
          |> Enum.map_join("|", &Regex.escape/1)

        Regex.replace(~r/(#{pattern})(?![A-Za-z0-9_-])/u, text, fn _whole, label ->
          replacements[label]
        end)
    end
  end

  @doc "Where an item was said, for the model: the group's name."
  @spec conversation(SourceItem.t(), map()) :: String.t()
  def conversation(%SourceItem{container_id: id}, names), do: names[id] || id

  @doc """
  The first message of each thread that started before `after_at` and that
  one of the `items` continues, as earlier context. Best effort.
  """
  @spec thread_roots(DailyBriefSetting.t(), [SourceItem.t()], DateTime.t()) :: [SourceItem.t()]
  def thread_roots(settings, items, after_at) do
    provider = Members.provider(settings)
    present = MapSet.new(items, &{&1.container_id, &1.id})

    roots =
      for %SourceItem{thread_id: thread} = item <- items,
          is_binary(thread),
          thread != item.id,
          not MapSet.member?(present, {item.container_id, thread}),
          uniq: true,
          do: {item.container_id, thread}

    with [_ | _] <- roots, {:ok, source} <- Members.source(settings) do
      roots
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {chat_id, ids} ->
        case Salix.impl().daily_brief_messages(
               Map.merge(source, %{channel_id: chat_id, ts: Enum.take(ids, @max_roots)})
             ) do
          {:ok, %{messages: messages}} ->
            messages
            |> Enum.map(&shared_item(provider, &1))
            |> Enum.filter(&(&1.at && DateTime.compare(&1.at, after_at) == :lt))

          {:error, _reason} ->
            []
        end
      end)
    else
      _none -> []
    end
  end

  @doc "The names of the bot's readable groups, by id; empty when they cannot be listed."
  @spec channel_names(DailyBriefSetting.t(), map() | nil) :: %{String.t() => String.t()}
  def channel_names(_settings, %{channel_names: names}) when is_map(names), do: names
  def channel_names(settings, _shared), do: channel_names(settings)

  @spec channel_names(DailyBriefSetting.t()) :: %{String.t() => String.t()}
  def channel_names(settings) do
    with {:ok, source} <- Members.source(settings),
         {:ok, %{channels: channels}} <-
           Salix.impl().daily_brief_channels(Sources.channels_request(source)) do
      Map.new(channels, &{&1.id, &1.name})
    else
      _unavailable -> %{}
    end
  end

  @doc "The names the directory shows for the provider's people among `refs`, by ref."
  @spec user_names(String.t(), [ActorRef.t() | nil], DailyBriefSetting.t()) :: map()
  def user_names(provider, refs, settings) do
    ids =
      refs |> Enum.map(&ActorRef.id_of(provider, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with [_ | _] <- ids, {:ok, source} <- Members.source(settings) do
      ids
      |> Enum.chunk_every(@max_roots)
      |> Enum.reduce(%{}, fn chunk, acc ->
        case Salix.impl().daily_brief_user_names(Map.put(source, :user_ids, chunk)) do
          {:ok, names} ->
            Enum.into(names, acc, fn {id, name} -> {ActorRef.of(provider, id), name} end)

          {:error, _reason} ->
            acc
        end
      end)
    else
      _none -> %{}
    end
  end

  defp at(us) when is_integer(us) and us > 0, do: DateTime.from_unix!(us, :microsecond)
  defp at(_us), do: nil
end
