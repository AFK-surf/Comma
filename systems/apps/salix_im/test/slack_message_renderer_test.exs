defmodule SalixIM.SlackMessageRendererTest do
  use ExUnit.Case, async: true

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

  test "bold links and percentages next to CJK punctuation use explicit styles" do
    markdown = """
    你说的是 **[Agentic Video Understanding](<https://example.test/video>)**（智能体化视频理解技术）。

    ### 核心提升

    - **Token 消耗锐减**：最高降低 **88%**；
    - **成本大幅下降**：最高降低 **66%**；
    - **精度更高**：提升约 **7%**。
    """

    assert {:ok, %{blocks: [intro, %{"type" => "header"}, improvements]}} =
             SlackMessageRenderer.render(markdown)

    assert intro["type"] == "rich_text"

    assert hd(intro["elements"])["elements"] == [
             %{"type" => "text", "text" => "你说的是 "},
             %{
               "type" => "link",
               "url" => "https://example.test/video",
               "text" => "Agentic Video Understanding",
               "style" => %{"bold" => true}
             },
             %{"type" => "text", "text" => "（智能体化视频理解技术）。"}
           ]

    assert improvements["type"] == "rich_text"

    assert [%{"type" => "rich_text_list", "style" => "bullet", "elements" => items}] =
             improvements["elements"]

    for {item, percent} <- Enum.zip(items, ["88%", "66%", "7%"]) do
      assert %{"type" => "text", "text" => percent, "style" => %{"bold" => true}} in item[
               "elements"
             ]
    end

    refute Jason.encode!([intro, improvements]) =~ "**"
  end

  test "bold prose preserves nested lists and literal inline and fenced code" do
    markdown = """
    - **Parent**
      - **Child** and `**literal**`

    ```markdown
    **not bold**
    ```
    """

    assert {:ok, %{blocks: [list, code]}} = SlackMessageRenderer.render(markdown)
    assert list["type"] == "rich_text"
    assert [parent, child] = list["elements"]
    assert parent["type"] == "rich_text_list"
    assert child["indent"] == 1

    assert %{"type" => "text", "text" => "**literal**", "style" => %{"code" => true}} in hd(
             child["elements"]
           )["elements"]

    assert code == %{"type" => "markdown", "text" => "```markdown\n**not bold**\n```"}
  end

  test "escaped strong markers and formatted headings retain native Markdown" do
    for markdown <- [~S(\**88%\**；), "`**88%**`", "### **Heading**"] do
      assert {:ok, %{blocks: [%{"type" => "markdown", "text" => ^markdown}]}} =
               SlackMessageRenderer.render(markdown)
    end
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

  test "Task and Plan rich-text fields render standard Markdown without literal markers" do
    task = %Surface{
      kind: :task_card,
      id: "task-markdown",
      fallback: "Task Markdown rendering: in progress",
      title: "Markdown rendering",
      status: :in_progress,
      details: "**Goal**: ship [docs](https://example.test/docs).\n\n- run `mix test`\n- publish",
      output: "> Ready\n\n```elixir\nIO.puts(\"ok\")\n```"
    }

    assert {:ok, %{blocks: [%{"type" => "task_card"} = block]}} =
             MessageRenderer.render_surface(SlackMessageRenderer, task)

    assert %{
             "type" => "rich_text",
             "elements" => [
               %{
                 "type" => "rich_text_section",
                 "elements" => [
                   %{"type" => "text", "text" => "Goal", "style" => %{"bold" => true}},
                   %{"type" => "text", "text" => ": ship "},
                   %{
                     "type" => "link",
                     "text" => "docs",
                     "url" => "https://example.test/docs"
                   },
                   %{"type" => "text", "text" => "."}
                 ]
               },
               %{
                 "type" => "rich_text_list",
                 "style" => "bullet",
                 "elements" => [
                   %{
                     "type" => "rich_text_section",
                     "elements" => [
                       %{"type" => "text", "text" => "run "},
                       %{"type" => "text", "text" => "mix test", "style" => %{"code" => true}}
                     ]
                   },
                   %{
                     "type" => "rich_text_section",
                     "elements" => [%{"type" => "text", "text" => "publish"}]
                   }
                 ]
               }
             ]
           } = block["details"]

    assert %{
             "type" => "rich_text",
             "elements" => [
               %{
                 "type" => "rich_text_quote",
                 "elements" => [%{"type" => "text", "text" => "Ready"}]
               },
               %{
                 "type" => "rich_text_preformatted",
                 "language" => "elixir",
                 "elements" => [%{"type" => "text", "text" => "IO.puts(\"ok\")"}]
               }
             ]
           } = block["output"]

    refute Jason.encode!(block) =~ "**"

    plan = %Surface{
      kind: :plan,
      id: "plan-markdown",
      fallback: "Plan Markdown rendering: in progress",
      title: "Markdown rendering",
      tasks: [
        %{
          id: "step-markdown",
          title: "Render result",
          status: :complete,
          output: "Published **successfully**"
        }
      ]
    }

    assert {:ok, %{blocks: [%{"type" => "plan", "tasks" => [plan_task]}]}} =
             MessageRenderer.render_surface(SlackMessageRenderer, plan)

    assert get_in(plan_task, ["output", "elements", Access.at(0), "elements"]) == [
             %{"type" => "text", "text" => "Published "},
             %{"type" => "text", "text" => "successfully", "style" => %{"bold" => true}}
           ]
  end

  test "Task rich text keeps plain titles and safely renders other common Markdown" do
    task = %Surface{
      kind: :task_card,
      id: "task-more-markdown",
      fallback: "Task Markdown rendering: complete",
      title: "**Rendered result**",
      status: :complete,
      output:
        "# C# result\n\n3. *Fast* output\n4. ~~Retired~~ output\n\nconfig_one_name and \\*literal\\* and broken **marker\n\n```elixir\nmissing close"
    }

    assert {:ok, %{blocks: [%{"type" => "task_card"} = block]}} =
             MessageRenderer.render_surface(SlackMessageRenderer, task)

    assert block["title"] == "**Rendered result**"

    assert get_in(block, ["output", "elements"]) == [
             %{
               "type" => "rich_text_section",
               "elements" => [
                 %{"type" => "text", "text" => "C# result", "style" => %{"bold" => true}}
               ]
             },
             %{
               "type" => "rich_text_list",
               "style" => "ordered",
               "offset" => 2,
               "elements" => [
                 %{
                   "type" => "rich_text_section",
                   "elements" => [
                     %{"type" => "text", "text" => "Fast", "style" => %{"italic" => true}},
                     %{"type" => "text", "text" => " output"}
                   ]
                 },
                 %{
                   "type" => "rich_text_section",
                   "elements" => [
                     %{
                       "type" => "text",
                       "text" => "Retired",
                       "style" => %{"strike" => true}
                     },
                     %{"type" => "text", "text" => " output"}
                   ]
                 }
               ]
             },
             %{
               "type" => "rich_text_section",
               "elements" => [
                 %{
                   "type" => "text",
                   "text" => "config_one_name and *literal* and broken **marker"
                 }
               ]
             },
             %{
               "type" => "rich_text_section",
               "elements" => [%{"type" => "text", "text" => "```elixir\nmissing close"}]
             }
           ]
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

  test "rendered-editor document structure stays source-faithful inside Slack markdown" do
    markdown = """
    # 发布检查

    > 先确认影响范围，再开始发布。

    1. 运行 `mix test`
       - 保留嵌套列表
       - 保留段落节奏
    2. 核对结果

    | 项目 | 状态 |
    | --- | --- |
    | Renderer | Ready |

    ---

    ```elixir
    IO.puts("ok")
    ```
    """

    assert {:ok,
            %{
              blocks: [
                %{"type" => "header", "text" => %{"text" => "发布检查"}},
                %{"type" => "markdown", "text" => introduction},
                %{"type" => "table"} = table,
                %{"type" => "divider"},
                %{"type" => "markdown", "text" => code}
              ]
            }} = SlackMessageRenderer.render(markdown)

    assert introduction ==
             "> 先确认影响范围，再开始发布。\n\n" <>
               "1. 运行 `mix test`\n" <>
               "   - 保留嵌套列表\n" <>
               "   - 保留段落节奏\n" <>
               "2. 核对结果"

    assert code == "```elixir\nIO.puts(\"ok\")\n```"

    assert get_in(table, [
             "rows",
             Access.at(0),
             Access.at(0),
             "elements",
             Access.at(0),
             "elements",
             Access.at(0)
           ]) ==
             %{"type" => "text", "text" => "项目", "style" => %{"bold" => true}}

    assert get_in(table, [
             "rows",
             Access.at(1),
             Access.at(1),
             "elements",
             Access.at(0),
             "elements",
             Access.at(0),
             "text"
           ]) ==
             "Ready"
  end

  test "heading levels, table alignment, links, and real mentions use native Slack entities" do
    markdown = """
    ## 概览

    | Owner | Link | State |
    | :--- | :---: | ---: |
    | <@U012ABCDEF> | [详情](https://example.com/item) | **Ready** |

    #### Notes
    """

    assert {:ok,
            %{
              blocks: [
                %{"type" => "header", "level" => 2, "text" => %{"text" => "概览"}},
                %{"type" => "table"} = table,
                %{"type" => "header", "level" => 4, "text" => %{"text" => "Notes"}}
              ]
            }} = SlackMessageRenderer.render(markdown)

    assert Enum.map(table["column_settings"], & &1["align"]) == ["left", "center", "right"]
    assert Enum.all?(table["column_settings"], & &1["is_wrapped"])

    assert get_in(table, [
             "rows",
             Access.at(1),
             Access.at(0),
             "elements",
             Access.at(0),
             "elements"
           ]) == [
             %{"type" => "user", "user_id" => "U012ABCDEF"}
           ]

    assert get_in(table, [
             "rows",
             Access.at(1),
             Access.at(1),
             "elements",
             Access.at(0),
             "elements"
           ]) == [
             %{"type" => "link", "text" => "详情", "url" => "https://example.com/item"}
           ]

    assert get_in(table, [
             "rows",
             Access.at(1),
             Access.at(2),
             "elements",
             Access.at(0),
             "elements"
           ]) == [
             %{"type" => "text", "text" => "Ready"}
           ]
  end

  test "tables with code-wrapped or escaped entities stay standard Markdown" do
    markdown =
      ~S"""
      | Code | Meaning |
      | --- | --- |
      | `<@U012ABCDEF>` | literal user reference |
      | `<#C012ABCDEF>` | literal channel reference |
      | `[docs](https://example.test/docs)` | literal link |

      | Escaped | Meaning |
      | --- | --- |
      | \<@U012ABCDEF> | literal user reference |
      | \<#C012ABCDEF> | literal channel reference |
      | \[docs](https://example.test/docs) | literal link |
      """
      |> String.trim()

    assert {:ok, %{text: ^markdown, blocks: [%{"type" => "markdown", "text" => ^markdown}]}} =
             SlackMessageRenderer.render(markdown)
  end

  test "native tables fail closed when their message-wide cell budget exceeds Slack's limit" do
    cell = String.duplicate("x", 5_100)
    table = "| Value |\n| --- |\n| #{cell} |"

    assert {:error, :table_too_large} =
             SlackMessageRenderer.render(table <> "\n\n" <> table)
  end

  test "native table accounting stays internal to the renderer" do
    cell = String.duplicate("x", 4_900)
    table = "| Value |\n| --- |\n| #{cell} |"

    assert {:ok, %{blocks: [%{"type" => "table"} = first, %{"type" => "table"} = second]}} =
             SlackMessageRenderer.render(table <> "\n\n" <> table)

    assert Enum.all?([first, second], fn block ->
             Enum.all?(Map.keys(block), &is_binary/1)
           end)
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

  test "escaped and multi-backtick code-span references never become notifying sections" do
    literals = [
      ~S(\<@U012ABCDEF> stays escaped),
      "``<@U012ABCDEF>`` stays code",
      "before ```<#C012ABCDEF>``` after"
    ]

    for markdown <- literals do
      assert {:ok, %{text: ^markdown, blocks: blocks}} =
               SlackMessageRenderer.render(markdown)

      refute Enum.any?(blocks, &(&1["type"] == "section"))
      assert Enum.any?(blocks, &(&1["type"] == "markdown" and &1["text"] == markdown))
    end
  end

  test "literal references remain non-notifying beside one real reference" do
    markdown =
      ~S(Keep \<@U012ABCDEF> and ``<#C012ABCDEF>`` literal; notify <@U999ABCDEF>.)

    assert {:ok, %{blocks: [%{"type" => "section", "text" => %{"text" => rendered}}]}} =
             SlackMessageRenderer.render(markdown)

    assert rendered =~ "<@U999ABCDEF>"
    refute rendered =~ "<@U012ABCDEF>"
    refute rendered =~ "<#C012ABCDEF>"
    assert rendered =~ "&lt;@U012ABCDEF&gt;"
    assert rendered =~ "&lt;#C012ABCDEF&gt;"
  end

  test "an unmatched backtick run does not hide a real reference" do
    markdown = "Unclosed `` code and <@U012ABCDEF>"

    assert {:ok, %{blocks: [%{"type" => "section", "text" => %{"text" => rendered}}]}} =
             SlackMessageRenderer.render(markdown)

    assert rendered =~ "<@U012ABCDEF>"
  end

  test "task-list lines become native checkboxes and preserve surrounding order" do
    markdown = "先处理：\n\n- [ ] 写测试\n- [x] 修复发送链路\n\n完成后汇报。"

    assert {:ok, %{blocks: [before, tasks, after_block] = blocks}} =
             SlackMessageRenderer.render(markdown)

    assert before == %{"type" => "markdown", "text" => "先处理："}
    assert after_block == %{"type" => "markdown", "text" => "完成后汇报。"}
    assert %{"type" => "actions", "block_id" => "comma_md_tasks_v1_" <> _} = tasks

    assert [%{"type" => "checkboxes", "action_id" => action_id} = checkbox] = tasks["elements"]
    assert String.starts_with?(action_id, "comma_md_tasks_v1_")

    assert Enum.map(checkbox["options"], &get_in(&1, ["text", "text"])) == [
             "写测试",
             "修复发送链路"
           ]

    assert Enum.all?(checkbox["options"], &(get_in(&1, ["text", "type"]) == "plain_text"))

    [unchecked, checked] = checkbox["options"]
    assert checkbox["initial_options"] == [checked]

    assert {:ok, updated} =
             SlackMessageRenderer.apply_checkbox_selection(blocks, action_id, [unchecked["value"]])

    updated_tasks = Enum.at(updated, 1)
    updated_checkbox = get_in(updated_tasks, ["elements", Access.at(0)])
    assert updated_checkbox["initial_options"] == [unchecked]
    refute updated_tasks["block_id"] == tasks["block_id"]

    assert {:ok, cleared} =
             SlackMessageRenderer.apply_checkbox_selection(blocks, action_id, [])

    refute get_in(cleared, [Access.at(1), "elements", Access.at(0)])["initial_options"]

    assert {:error, :invalid_checkbox_selection} =
             SlackMessageRenderer.apply_checkbox_selection(blocks, action_id, ["forged-value"])
  end

  test "checkbox groups respect Slack's ten-option limit" do
    markdown = Enum.map_join(1..11, "\n", &"- [ ] Task #{&1}")

    assert {:ok, %{blocks: [first, second]}} = SlackMessageRenderer.render(markdown)
    assert first["type"] == "actions"
    assert second["type"] == "actions"
    assert length(get_in(first, ["elements", Access.at(0), "options"])) == 10
    assert length(get_in(second, ["elements", Access.at(0), "options"])) == 1
  end

  test "task syntax inside a fenced code block remains Markdown" do
    markdown = """
    ```markdown
    - [ ] example only
    ```
    """

    assert {:ok, %{blocks: [%{"type" => "markdown", "text" => rendered}]}} =
             SlackMessageRenderer.render(markdown)

    assert rendered =~ "- [ ] example only"
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

  test "the final message fails closed above Slack's fifty-block limit" do
    fifty_headings = Enum.map_join(1..50, "\n\n", &"## Heading #{&1}")
    fifty_one_headings = fifty_headings <> "\n\n## Heading 51"

    assert {:ok, %{blocks: blocks}} = SlackMessageRenderer.render(fifty_headings)
    assert length(blocks) == 50

    assert {:error, :too_many_blocks} =
             SlackMessageRenderer.render(fifty_one_headings)
  end
end
