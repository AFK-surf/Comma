defmodule SalixIM.SlackMessageRendererTest do
  use SystemsClock.Case, async: true

  alias SalixIM.MessageRenderer
  alias SalixIM.MessageRenderer.Input
  alias SalixIM.MessageRenderer.Surface
  alias SalixIM.Provider.Slack.MessageRenderer, as: SlackMessageRenderer

  test "provider-neutral input is rendered by the selected platform adapter" do
    input = %Input{markdown: "Hello **team**"}

    assert {:ok, %{blocks: [%{"type" => "rich_text"} = block]}} =
             MessageRenderer.render(SlackMessageRenderer, input)

    assert hd(block["elements"])["elements"] == [
             %{"type" => "text", "text" => "Hello "},
             %{"type" => "text", "text" => "team", "style" => %{"bold" => true}}
           ]
  end

  test "provider-neutral product surfaces map to Slack card, plan, and task_card blocks" do
    card = %Surface{
      kind: :card,
      id: "conversation-link-1",
      fallback: "Task Launch report: https://teams.example.test/tasks/1",
      title: "Launch report",
      subtitle: "Bridge for Teams",
      body: "This Slack thread is connected to the Task.",
      actions: [
        %{id: "open_task", text: "Open Task", url: "https://teams.example.test/tasks/1"}
      ]
    }

    assert {:ok, %{text: card_fallback, blocks: [%{"type" => "card"} = card_block]}} =
             MessageRenderer.render_surface(SlackMessageRenderer, card)

    assert card_fallback == card.fallback
    assert get_in(card_block, ["title", "text"]) == "Launch report"
    assert get_in(card_block, ["subtitle", "text"]) == "Bridge for Teams"

    assert [%{"type" => "button", "url" => "https://teams.example.test/tasks/1"}] =
             card_block["actions"]

    plan = %Surface{
      kind: :plan,
      id: "release-plan-1",
      fallback: "Release plan: in progress",
      title: "Release plan",
      tasks: [
        %{id: "build", title: "Build image", status: :complete, output: "sha-1234567"},
        %{id: "deploy", title: "Deploy staging", status: :in_progress}
      ]
    }

    assert {:ok, %{text: "Release plan: in progress", blocks: [plan_block]}} =
             MessageRenderer.render_surface(SlackMessageRenderer, plan)

    assert plan_block["type"] == "plan"
    assert plan_block["title"] == "Release plan"

    assert [
             %{"task_id" => "build", "status" => "complete", "output" => output},
             %{"task_id" => "deploy", "status" => "in_progress"}
           ] = plan_block["tasks"]

    assert get_in(output, ["elements", Access.at(0), "elements", Access.at(0), "text"]) ==
             "sha-1234567"

    task = %Surface{
      kind: :task_card,
      id: "task-1",
      render_id: "task-render-1",
      fallback: "Task Verify staging: pending",
      title: "Verify staging",
      status: :pending,
      details: "Check readiness and health.",
      sources: [
        %{url: "https://teams-staging.bridge.surf/ready", text: "Bridge readiness"}
      ]
    }

    assert {:ok, %{blocks: [task_block]}} =
             MessageRenderer.render_surface(SlackMessageRenderer, task)

    assert task_block["type"] == "task_card"
    assert task_block["task_id"] == "task-1"
    assert task_block["block_id"] == "task-render-1"
    assert task_block["status"] == "pending"

    assert task_block["sources"] == [
             %{
               "type" => "url",
               "url" => "https://teams-staging.bridge.surf/ready",
               "text" => "Bridge readiness"
             }
           ]

    assert {:error, :card_content_required} =
             MessageRenderer.render_surface(
               SlackMessageRenderer,
               %Surface{kind: :card, id: "empty", fallback: "Empty card"}
             )
  end

  test "provider-neutral semantic data surfaces map to Slack map, stock, and weather cards" do
    surfaces = [
      {%Surface{
         kind: :map,
         id: "map:shanghai",
         fallback: "",
         data: %{
           "location" => "Shanghai",
           "latitude" => 31.2304,
           "longitude" => 121.4737
         }
       }, "Map:", ["card"]},
      {%Surface{
         kind: :stock,
         id: "stock:aapl",
         fallback: "",
         data: %{
           "symbol" => "AAPL",
           "price" => 231.4,
           "currency" => "USD",
           "price_history" => [
             %{"label" => "09:30", "value" => 229.0},
             %{"label" => "16:00", "value" => 231.4}
           ]
         }
       }, "Stock:", ["container"]},
      {%Surface{
         kind: :weather,
         id: "weather:shanghai",
         fallback: "",
         data: %{
           "location" => "Shanghai",
           "condition" => "Light rain",
           "temperature" => 27,
           "unit" => "C",
           "hourly_forecast" => [
             %{"time" => "Now", "temperature" => 27},
             %{"time" => "14:00", "temperature" => 28}
           ]
         }
       }, "Weather:", ["container"]}
    ]

    for {surface, fallback_prefix, block_types} <- surfaces do
      refute Map.has_key?(surface.data, "blocks")

      assert {:ok, %{text: fallback, blocks: blocks}} =
               MessageRenderer.render_surface(SlackMessageRenderer, surface)

      assert String.starts_with?(fallback, fallback_prefix)
      assert Enum.map(blocks, & &1["type"]) == block_types
    end
  end

  test "ordinary model prose keeps Markdown while title and table use native blocks" do
    markdown = """
    # Decision

    Use **native Markdown** and keep the table.

    | Item | State |
    | --- | --- |
    | Renderer | Ready |

    ```elixir
    IO.puts("ok")
    ```
    """

    assert {:ok,
            %{
              text: fallback,
              blocks: [
                %{
                  "type" => "header",
                  "text" => %{"type" => "plain_text", "text" => "Decision"}
                },
                %{"type" => "rich_text"} = prose,
                %{"type" => "table"} = table,
                %{"type" => "markdown", "text" => code}
              ]
            }} =
             SlackMessageRenderer.render(markdown)

    assert fallback == String.trim(markdown)

    assert hd(prose["elements"])["elements"] == [
             %{"type" => "text", "text" => "Use "},
             %{"type" => "text", "text" => "native Markdown", "style" => %{"bold" => true}},
             %{"type" => "text", "text" => " and keep the table."}
           ]

    assert code =~ "```elixir"
    assert length(table["rows"]) == 2
    assert length(hd(table["rows"])) == 2
  end

  test "native Slack user and channel references render without parallel metadata" do
    markdown = "请 <@U012ABCDEF> 看一下，完整版在 <#C012ABCDEF>。\n\n@Alice 只是普通名字。"

    assert {:ok, %{text: fallback, blocks: [references, names]}} =
             SlackMessageRenderer.render(markdown)

    assert fallback == markdown

    assert references == %{
             "type" => "section",
             "text" => %{
               "type" => "mrkdwn",
               "text" => "请 <@U012ABCDEF> 看一下，完整版在 <#C012ABCDEF>。"
             }
           }

    assert names == %{
             "type" => "markdown",
             "text" => "@Alice 只是普通名字。"
           }
  end

  test "mention syntax inside fenced code never becomes a notifying section" do
    markdown = """
    ```text
    <@U012ABCDEF>
    ```
    """

    assert {:ok, %{blocks: [%{"type" => "markdown", "text" => rendered}]}} =
             SlackMessageRenderer.render(markdown)

    assert rendered =~ "<@U012ABCDEF>"
  end

  test "a message above Slack's cumulative markdown limit fails instead of truncating" do
    assert {:error, :markdown_too_long} =
             SlackMessageRenderer.render(String.duplicate("a", 12_001))
  end
end
