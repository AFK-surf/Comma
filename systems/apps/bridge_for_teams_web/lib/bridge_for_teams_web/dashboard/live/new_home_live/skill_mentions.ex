defmodule BridgeForTeamsWeb.Dashboard.NewHomeLive.SkillMentions do
  @moduledoc """
  The user → agent skill-tagging path for the New Home composers.

  Typing `/` in a composer lets the user tag agent skills; the client submits
  the tagged skills as a JSON array in `chat[skills]`. That value is
  client-controlled, so `parse/2` only admits skills whose location exists in
  the server-loaded `@mention_skills` list and returns the server-side maps —
  client-supplied names never reach the protocol. `instructions/1` renders the
  activation block appended after the `[[bft-protocol]]` marker; the agent's
  system prompt already lists every skill with the same name and location, so
  name + location is all it needs to activate them.
  """

  @max_mentions_per_message 10

  @doc """
  Filter the client-submitted `chat[skills]` value against the server-loaded
  skill list. Malformed input degrades to `[]`; entries are deduped, capped at
  #{@max_mentions_per_message}, and returned in client order as the
  server-side skill maps.
  """
  @spec parse(term(), [map()]) :: [map()]
  def parse(value, loaded_skills) when is_binary(value) and is_list(loaded_skills) do
    case Jason.decode(value) do
      {:ok, entries} when is_list(entries) ->
        entries
        |> Enum.flat_map(fn
          %{"location" => location} when is_binary(location) -> [location]
          _ -> []
        end)
        |> Enum.uniq()
        |> Enum.take(@max_mentions_per_message)
        |> Enum.flat_map(fn location ->
          case Enum.find(loaded_skills, &(&1["location"] == location)) do
            nil -> []
            skill -> [skill]
          end
        end)

      _ ->
        []
    end
  end

  def parse(_value, _loaded_skills), do: []

  @doc """
  The protocol block asking the agent to activate the tagged skills, or `nil`
  when nothing was tagged.
  """
  @spec instructions([map()]) :: String.t() | nil
  def instructions([]), do: nil

  def instructions(skills) when is_list(skills) do
    lines = Enum.map_join(skills, "\n", &"- #{&1["name"]} — #{&1["location"]}")

    "The user tagged these skills for this task. Activate each one now: " <>
      "read the SKILL.md at the given location and follow it while doing the work:\n" <>
      lines
  end
end
