defmodule BridgeForTeams.DailyBrief.Classifier do
  @moduledoc """
  Deterministic relevance of one message to one member, before any model reads it.

  P0 reasons: the message mentions the member, names one of the member's
  aliases, replies in a thread the member wrote in, or is the member's own.
  P1 reason: it names one of the member's project terms. A bot message counts
  only when it mentions the member.
  """

  @p0 [:mention, :alias, :thread, :own]

  @type member :: %{
          slack_user_id: String.t(),
          alias_pattern: Regex.t() | nil,
          project_pattern: Regex.t() | nil,
          threads: MapSet.t({String.t(), String.t()})
        }

  @doc "Builds the per-member matcher once per run."
  @spec member(String.t(), [%{term: String.t(), kind: String.t()}], [map()]) :: member()
  def member(slack_user_id, aliases, threads) do
    %{
      slack_user_id: slack_user_id,
      alias_pattern:
        pattern(for %{kind: kind, term: term} <- aliases, kind != "project", do: term),
      project_pattern: pattern(for %{kind: "project", term: term} <- aliases, do: term),
      threads: MapSet.new(threads, &{&1.channel_id, &1.thread_ts})
    }
  end

  @spec reasons(map(), member()) :: [atom()]
  def reasons(message, member) do
    text = message.text || ""
    own? = message.actor_id == member.slack_user_id
    bot? = message.actor_kind in ["bot", "app"]
    mention? = String.contains?(text, "<@#{member.slack_user_id}>")

    cond do
      own? ->
        [:own]

      bot? ->
        if mention?, do: [:mention], else: []

      true ->
        [
          {:mention, mention?},
          {:alias, matches?(member.alias_pattern, text)},
          {:thread, MapSet.member?(member.threads, {message.channel_id, thread_of(message)})},
          {:project, matches?(member.project_pattern, text)}
        ]
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))
    end
  end

  @spec tier([atom()]) :: :p0 | :p1 | nil
  def tier(reasons) do
    cond do
      Enum.any?(reasons, &(&1 in @p0)) -> :p0
      :project in reasons -> :p1
      true -> nil
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
