defmodule SalixIM.MacAppItem do
  @moduledoc """
  Pure contract for a Mac app card: one item an Agent made or found in an app on
  the user's own Mac (a Calendar event, a reminder, a note, a person, a place),
  carried as a `mac_app_item` block in an ordinary Agent Message. The Comma
  desktop app hands the Agent these blocks with the tool result; clients draw
  each as its app draws it.

  The Agent send path keeps only the known fields, at most #{5} cards, and adds
  one plain-text fallback block for clients that cannot draw the cards.
  """

  @apps ~w(calendar reminders notes contacts maps)
  @max_cards 5
  @fallback_marker "mac_app_item"
  @text_fields ~w(item_id title start end calendar location due list folder detail address category)
  @text_bytes 1..500

  @doc "The Agent's content with its Mac app cards checked and a text fallback added."
  @spec normalize_agent_content(list()) :: {:ok, list()} | {:error, {:bad_request, String.t()}}
  def normalize_agent_content(content) when is_list(content) do
    case Enum.split_with(content, &match?(%{"type" => "mac_app_item"}, &1)) do
      {[], _rest} ->
        {:ok, content}

      {cards, _rest} when length(cards) > @max_cards ->
        bad("Send at most #{@max_cards} mac_app_item blocks per Message")

      {cards, rest} ->
        with {:ok, cards} <- normalize_cards(cards) do
          rest = Enum.reject(rest, &fallback?/1)
          {:ok, rest ++ cards ++ [fallback_block(cards)]}
        end
    end
  end

  def normalize_agent_content(content), do: {:ok, content}

  @doc "Whether a text block is the plain-text fallback of Mac app cards."
  @spec fallback?(term()) :: boolean()
  def fallback?(%{"type" => "text", "fallback_for" => @fallback_marker}), do: true
  def fallback?(_block), do: false

  defp normalize_cards(cards) do
    Enum.reduce_while(cards, {:ok, []}, fn card, {:ok, acc} ->
      case normalize_card(card) do
        {:ok, card} -> {:cont, {:ok, [card | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      error -> error
    end
  end

  defp normalize_card(%{"app" => app} = card) when app in @apps do
    text =
      for key <- @text_fields,
          value = trimmed(card[key]),
          value != nil,
          into: %{},
          do: {key, value}

    cond do
      not Map.has_key?(text, "title") ->
        bad("A mac_app_item needs a title")

      Enum.any?(text, fn {_key, value} -> byte_size(value) not in @text_bytes end) ->
        bad("mac_app_item text fields are 1 to 500 bytes")

      true ->
        {:ok,
         text
         |> Map.merge(%{"type" => "mac_app_item", "app" => app})
         |> put_flag(card, "all_day")
         |> put_flag(card, "completed")
         |> put_color(card["color"])
         |> put_coordinate("latitude", card["latitude"], 90)
         |> put_coordinate("longitude", card["longitude"], 180)}
    end
  end

  defp normalize_card(_card),
    do: bad("A mac_app_item names its app: #{Enum.join(@apps, ", ")}")

  defp put_flag(map, card, key), do: if(card[key] == true, do: Map.put(map, key, true), else: map)

  defp put_color(map, color) when is_binary(color) do
    if Regex.match?(~r/^#[0-9A-Fa-f]{6}$/, color),
      do: Map.put(map, "color", String.upcase(color)),
      else: map
  end

  defp put_color(map, _color), do: map

  defp put_coordinate(map, key, value, limit) when is_number(value) and abs(value) <= limit,
    do: Map.put(map, key, value)

  defp put_coordinate(map, _key, _value, _limit), do: map

  defp fallback_block(cards) do
    lines =
      Enum.map(cards, fn card ->
        details =
          [
            card["start"] || card["due"],
            card["calendar"] || card["list"] || card["folder"],
            card["location"] || card["address"] || card["detail"]
          ]
          |> Enum.reject(&is_nil/1)

        "- " <> Enum.join([card["title"] | details], " · ")
      end)

    %{"type" => "text", "text" => Enum.join(lines, "\n"), "fallback_for" => @fallback_marker}
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  defp bad(message), do: {:error, {:bad_request, "mac_app_item: " <> message}}
end
