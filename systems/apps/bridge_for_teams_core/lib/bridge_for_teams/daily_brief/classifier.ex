defmodule BridgeForTeams.DailyBrief.Classifier do
  @moduledoc """
  Deterministic relevance of one message to one member, before any model reads it.

  P0 reasons: the message mentions the member, names one of the member's
  aliases, replies in a thread the member wrote in, or is the member's own.
  P1 reasons: it names one of the member's project terms, or a person wrote
  it in one of the member's main channels. A bot message counts only when it
  mentions or names the member (meeting notes list who attended), replies in
  a thread the member wrote in, or is in a main channel the member reads with
  its bot messages.
  """

  @p0 [:mention, :alias, :thread, :own]
  # A bot's short notice that names someone ("XP deployed") is not theirs to
  # read; meeting notes listing who attended run to thousands of characters.
  @write_up_length 800

  @type member :: %{
          user_id: String.t(),
          alias_pattern: Regex.t() | nil,
          project_pattern: Regex.t() | nil,
          threads: MapSet.t({String.t(), String.t()}),
          channels: %{humans: MapSet.t(String.t()), bots: MapSet.t(String.t())}
        }

  @doc """
  Builds the per-member matcher once per run. `user_id` is the member's id in
  the provider: a Slack user id, or a Feishu or Lark open id.
  """
  @spec member(String.t(), [%{term: String.t(), kind: String.t()}], [map()], map()) :: member()
  def member(user_id, aliases, threads, channels \\ nil) do
    %{
      user_id: user_id,
      alias_pattern:
        pattern(for %{kind: kind, term: term} <- aliases, kind in ["name", "handle"], do: term),
      project_pattern: pattern(for %{kind: "project", term: term} <- aliases, do: term),
      threads: MapSet.new(threads, &{&1.channel_id, &1.thread_ts}),
      channels: channels || %{humans: MapSet.new(), bots: MapSet.new()}
    }
  end

  @spec reasons(map(), member()) :: [atom()]
  def reasons(message, member) do
    text = message.text || ""
    own? = message.actor_id == member.user_id
    bot? = message.actor_kind in ["bot", "app"]

    # Slack writes a mention into the text; Feishu and Lark name it apart.
    mention? =
      String.contains?(text, "<@#{member.user_id}>") or
        member.user_id in List.wrap(message[:mentions])

    cond do
      own? ->
        [:own]

      bot? ->
        [
          {:mention, mention?},
          {:alias,
           String.length(text) >= @write_up_length and matches?(member.alias_pattern, text)},
          {:thread, MapSet.member?(member.threads, {message.channel_id, thread_of(message)})},
          {:channel, MapSet.member?(member.channels.bots, message.channel_id)}
        ]
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))

      true ->
        base =
          [
            {:mention, mention?},
            {:alias, matches?(member.alias_pattern, text)},
            {:thread, MapSet.member?(member.threads, {message.channel_id, thread_of(message)})},
            {:project, matches?(member.project_pattern, text)},
            {:channel, MapSet.member?(member.channels.humans, message.channel_id)}
          ]
          |> Enum.filter(&elem(&1, 1))
          |> Enum.map(&elem(&1, 0))

        if base == [] and jev_recall_promoted?(message) do
          [:jev_recall]
        else
          base
        end
    end
  end

  @spec tier([atom()]) :: :p0 | :p1 | nil
  def tier(reasons) do
    cond do
      Enum.any?(reasons, &(&1 in @p0)) -> :p0
      :project in reasons or :channel in reasons or :jev_recall in reasons -> :p1
      true -> nil
    end
  end

  defp jev_recall_promoted?(message) when is_map(message) do
    case message[:jev_recall_bp] || message["jev_recall_bp"] do
      prob_bp when is_integer(prob_bp) ->
        SalixStore.ProactiveKernel.gate_jev_decision(%{
          mode: :recall,
          probability_bp: prob_bp
        }) == :promote

      _ ->
        false
    end
  end

  defp thread_of(message), do: message.thread_ts || message.ts

  defp matches?(nil, _text), do: false
  defp matches?(pattern, text), do: Regex.match?(pattern, text)

  # ASCII terms match as whole words, so "XP" does not match "export".
  # Other terms (CJK names such as 鹏哥) match as substrings.
  defp pattern(terms) do
    case terms |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() do
      [] ->
        nil

      terms ->
        source =
          Enum.map_join(terms, "|", fn term ->
            escaped = Regex.escape(term)

            if ascii?(term),
              do: "(?<![A-Za-z0-9_])" <> escaped <> "(?![A-Za-z0-9_])",
              else: escaped
          end)

        Regex.compile!(source, "iu")
    end
  end

  defp ascii?(term), do: term == for(<<c <- term>>, c < 128, into: "", do: <<c>>)
end
