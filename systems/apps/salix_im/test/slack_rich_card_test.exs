defmodule SalixIM.SlackRichCardTest do
  use SystemsClock.Case, async: true
  alias SalixIM.Provider.Slack.RichCard

  test "map uses one localized native card without repeating the address" do
    assert {:ok, card} =
             RichCard.render("map", %{
               "location" => "Shanghai <HQ>",
               "latitude" => 31.2304,
               "longitude" => 121.4737,
               "address" => "People's Square",
               "image_url" => "https://example.com/map.png",
               "locale" => "zh-CN"
             })

    assert card.text == "地图：Shanghai &lt;HQ&gt; — 31.2304, 121.4737"
    assert [%{"type" => "card"} = block] = card.blocks
    assert block["hero_image"]["image_url"] == "https://example.com/map.png"
    assert block["title"]["text"] == "Shanghai &lt;HQ&gt;"
    assert block["subtitle"]["text"] == "People's Square"

    assert block["body"]["text"] ==
             "<https://www.google.com/maps/search/?api=1&query=31.2304%2C121.4737|在地图中查看>"

    assert block["subtext"]["text"] == "31.2304, 121.4737"
    refute_interactive(card.blocks)
  end

  @interactive_types ~w(actions input button checkboxes feedback_buttons icon_button radio_buttons workflow_button)

  defp refute_interactive(value) when is_list(value), do: Enum.each(value, &refute_interactive/1)

  defp refute_interactive(%{} = value) do
    refute value["type"] in @interactive_types
    refute Map.has_key?(value, "action_id")
    refute Map.has_key?(value, "accessory")
    Enum.each(value, fn {_key, nested} -> refute_interactive(nested) end)
  end

  defp refute_interactive(_value), do: :ok
end
