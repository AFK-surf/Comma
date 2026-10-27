defmodule SalixIM.MacAppItemTest do
  use ExUnit.Case, async: true

  alias SalixIM.MacAppItem

  test "keeps known fields of each card and adds one text fallback" do
    content = [
      %{"type" => "text", "text" => "Added it."},
      %{
        "type" => "mac_app_item",
        "app" => "calendar",
        "item_id" => "E1",
        "title" => " Design review ",
        "start" => "2026-10-20T10:00:00Z",
        "end" => "2026-10-20T11:00:00Z",
        "calendar" => "Work",
        "color" => "#0088ff",
        "all_day" => false,
        "script" => "<b>not kept</b>"
      },
      %{
        "type" => "mac_app_item",
        "app" => "maps",
        "title" => "Cafe",
        "latitude" => 35.6,
        "longitude" => 139.7
      }
    ]

    assert {:ok, [text, event, place, fallback]} = MacAppItem.normalize_agent_content(content)
    assert text == %{"type" => "text", "text" => "Added it."}

    assert event == %{
             "type" => "mac_app_item",
             "app" => "calendar",
             "item_id" => "E1",
             "title" => "Design review",
             "start" => "2026-10-20T10:00:00Z",
             "end" => "2026-10-20T11:00:00Z",
             "calendar" => "Work",
             "color" => "#0088FF"
           }

    assert place["latitude"] == 35.6 and place["longitude"] == 139.7
    assert fallback["fallback_for"] == "mac_app_item"
    assert fallback["text"] =~ "Design review · 2026-10-20T10:00:00Z · Work"

    # Sending the same content again replaces the fallback instead of adding one.
    assert {:ok, again} = MacAppItem.normalize_agent_content([text, event, place, fallback])
    assert Enum.count(again, &MacAppItem.fallback?/1) == 1
  end

  test "refuses cards without an app or a title, and too many cards" do
    assert {:error, {:bad_request, _}} =
             MacAppItem.normalize_agent_content([
               %{"type" => "mac_app_item", "app" => "shell", "title" => "x"}
             ])

    assert {:error, {:bad_request, _}} =
             MacAppItem.normalize_agent_content([%{"type" => "mac_app_item", "app" => "notes"}])

    many = for i <- 1..6, do: %{"type" => "mac_app_item", "app" => "notes", "title" => "n#{i}"}
    assert {:error, {:bad_request, _}} = MacAppItem.normalize_agent_content(many)
  end

  test "content without cards is unchanged" do
    content = [%{"type" => "text", "text" => "hi"}]
    assert {:ok, ^content} = MacAppItem.normalize_agent_content(content)
  end
end
