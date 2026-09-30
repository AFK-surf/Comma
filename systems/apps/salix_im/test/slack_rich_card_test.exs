defmodule SalixIM.SlackRichCardTest do
  use ExUnit.Case, async: true
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

  test "map reserves its complete destination link before truncating a long note" do
    map_url = "https://maps.example.test/place/123"

    assert {:ok, card} =
             RichCard.render("map", %{
               "location" => "Shanghai",
               "latitude" => 31.2304,
               "longitude" => 121.4737,
               "note" => String.duplicate("说明", 120),
               "map_url" => map_url
             })

    assert [%{"type" => "card", "body" => %{"text" => body}}] = card.blocks
    assert String.length(body) <= 200
    assert String.ends_with?(body, "<#{map_url}|View map>")
  end

  test "map rejects a destination that cannot fit intact in the card body" do
    map_url = "https://maps.example.test/" <> String.duplicate("x", 190)

    assert {:error, "map_url is too long for Slack card body"} =
             RichCard.render("map", %{
               "location" => "Shanghai",
               "latitude" => 31.2304,
               "longitude" => 121.4737,
               "map_url" => map_url
             })
  end

  test "stock renders one narrow container with a compact in-card trend" do
    assert {:ok, card} =
             RichCard.render("stock", %{
               "symbol" => "aapl",
               "company_name" => "Apple & Co",
               "exchange" => "NASDAQ",
               "period" => "1D",
               "price" => "231.40",
               "currency" => "usd",
               "change" => "+2.40",
               "change_percent" => "+1.05",
               "open" => 229.0,
               "high" => 233.2,
               "low" => 228.7,
               "volume" => 42_000_000,
               "price_history" => [
                 %{"label" => "09:30", "value" => 229.0},
                 %{"label" => "12:00", "value" => 230.4},
                 %{"label" => "16:00", "value" => 231.4}
               ],
               "locale" => "zh-CN"
             })

    assert card.text == "股票：AAPL US$231.40; +US$2.40 · +1.05%"

    assert [%{"type" => "container"} = stock_card] = card.blocks
    assert stock_card["width"] == "narrow"
    assert stock_card["title"]["text"] == "Apple & Co · AAPL"
    assert stock_card["subtitle"]["text"] == "NASDAQ · USD · 1D"
    assert stock_card["has_header_divider"]

    assert Enum.map(stock_card["child_blocks"], & &1["type"]) == [
             "section",
             "section",
             "section",
             "context"
           ]

    [price, trend, metrics, footer] = stock_card["child_blocks"]
    assert price["text"]["text"] == "*US$231.40*\n+US$2.40 · +1.05%"
    assert trend["text"]["text"] =~ "*价格走势*"
    assert trend["text"]["text"] =~ "09:30  `▁"
    assert Enum.any?(metrics["fields"], &(&1["text"] == "*成交量*\n42M"))
    assert get_in(footer, ["elements", Access.at(0), "text"]) == "行情数据"
    refute Enum.any?(card.blocks, &(&1["type"] == "data_visualization"))
    refute_interactive(card.blocks)
  end

  test "weather renders one container with semantic emoji and localized forecast" do
    assert {:ok, card} =
             RichCard.render("weather", %{
               "location" => "上海",
               "condition" => "小雨",
               "temperature" => 27,
               "unit" => "c",
               "feels_like" => 29,
               "high" => 30,
               "low" => 24,
               "humidity_percent" => 82,
               "precipitation_percent" => 70,
               "wind" => "东南风 3 级",
               "hourly_forecast" => [
                 %{"time" => "现在", "temperature" => 27},
                 %{"time" => "14:00", "temperature" => 28}
               ],
               "daily_forecast" => [
                 %{"day" => "今天", "condition" => "雷雨", "high" => 30, "low" => 24},
                 %{"day" => "明天", "condition" => "多云", "high" => 29, "low" => 23}
               ],
               "locale" => "zh-CN"
             })

    assert card.text == "天气：上海 27°C, 小雨"

    assert [%{"type" => "container"} = weather] = card.blocks
    assert weather["title"]["text"] == "🌧️ 上海"
    assert weather["subtitle"]["text"] == "小雨 · 今日 24°–30°C"

    assert Enum.map(weather["child_blocks"], & &1["type"]) == [
             "section",
             "section",
             "divider",
             "section",
             "context"
           ]

    [current, hourly, _divider, forecast, _footer] = weather["child_blocks"]
    assert current["text"]["text"] == "*27°C*"
    assert Enum.any?(current["fields"], &(&1["text"] == "*湿度*\n82%"))
    assert hourly["text"]["text"] =~ "*逐小时*"
    assert Enum.any?(forecast["fields"], &String.contains?(&1["text"], "⛈️ 雷雨"))
    assert Enum.any?(forecast["fields"], &String.contains?(&1["text"], "🌤️ 多云"))
    refute_interactive(card.blocks)
  end

  test "weather condition icons cover common Chinese and English conditions" do
    cases = [
      {"Thunderstorms", "⛈️"},
      {"小雪", "🌨️"},
      {"Fog", "🌫️"},
      {"Partly cloudy", "🌤️"},
      {"晴", "☀️"},
      {"Overcast", "☁️"}
    ]

    for {condition, icon} <- cases do
      assert {:ok, %{blocks: [%{"title" => %{"text" => title}}]}} =
               RichCard.render("weather", %{
                 "location" => "Test",
                 "condition" => condition,
                 "temperature" => 20,
                 "unit" => "C"
               })

      assert String.starts_with?(title, icon)
    end
  end

  test "validation fails closed for types, bounds, currency, and arrays" do
    assert {:error, "latitude must be between -90 and 90"} =
             RichCard.render("map", %{"location" => "Nowhere", "latitude" => 91, "longitude" => 0})

    assert {:error, "currency must be a 3-letter ISO code"} =
             RichCard.render("stock", %{"symbol" => "COMMA", "price" => 1, "currency" => "US"})

    assert {:error, "temperature must be a number"} =
             RichCard.render("weather", %{
               "location" => "Shanghai",
               "condition" => "Rain",
               "temperature" => "hot",
               "unit" => "C"
             })

    assert {:error, "humidity_percent must be between 0 and 100"} =
             RichCard.render("weather", %{
               "location" => "Shanghai",
               "condition" => "Rain",
               "temperature" => 27,
               "unit" => "C",
               "humidity_percent" => 140
             })

    assert {:error, "price_history must be an array"} =
             RichCard.render("stock", %{
               "symbol" => "COMMA",
               "price" => 1,
               "currency" => "USD",
               "price_history" => %{}
             })

    assert {:error, "locale must be one of en, zh-CN"} =
             RichCard.render("map", %{
               "location" => "Nowhere",
               "latitude" => 0,
               "longitude" => 0,
               "locale" => "auto"
             })
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
