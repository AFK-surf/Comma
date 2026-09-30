defmodule CommaWeb.RecommendationMailTasksTest do
  use ExUnit.Case, async: false
  alias CommaWeb.RecommendationMailTasks

  test "mail without a confirmed Task keeps the member's pre-task prompt" do
    collection = %{
      facts: [
        %{
          "sourceId" => "account",
          "toolkit" => "gmail",
          "data" => %{
            "_comma" => %{"truncated" => true},
            "value" => %{
              "messages" => [
                %{
                  "threadId" => "thread",
                  "messageId" => "message",
                  "webUrl" => "https://mail.google.com/mail/#inbox/message"
                }
              ]
            }
          }
        }
      ]
    }

    prepared =
      RecommendationMailTasks.prepare(collection, %{
        "default_group_id" => "unavailable",
        "router_agent_id" => "router"
      })

    result =
      snapshot()
      |> CommaWeb.ProactiveRoutine.attach(prepared.facts)
      |> RecommendationMailTasks.project(prepared.facts)

    # Projection lag and a bounded source envelope leave the Task unknown. The
    # row stays a pre-task that the member confirms before anything is sent.
    [item] = hd(result["cards"])["items"]

    assert %{"type" => "send_to_comma", "promptId" => "p", "requiresConfirmation" => true} =
             item["action"]

    assert hd(item["parts"])["link"]["promptId"] == "p"
    assert Map.keys(result["prompts"]) == ["p"]

    assert [%{"source_ref" => "thread", "observation_id" => "message", "body" => "Mail"}] =
             CommaWeb.ProactiveRoutine.items(result)

    assert :ok = Comma.RecommendationContract.validate(result)
  end

  test "confirmed Task uses its existing identity and never a creation prompt" do
    facts = [
      %{
        "toolkit" => "gmail",
        "sourceId" => "account",
        "data" => %{
          "messages" => [
            %{
              "threadId" => "thread",
              "messageId" => "message",
              "webUrl" => "https://mail.google.com/mail/#inbox/message"
            }
          ]
        },
        "mailTasks" => %{
          "https://mail.google.com/mail/#inbox/message" => %{
            "conversation_id" => "task",
            "title" => "Follow up",
            "status" => "active"
          }
        }
      }
    ]

    result =
      snapshot()
      |> CommaWeb.ProactiveRoutine.attach(facts)
      |> RecommendationMailTasks.project(facts)

    assert [%{"kind" => "inline-task", "task" => %{"conversationId" => "task"}}] =
             hd(hd(result["cards"])["items"])["parts"]

    assert result["prompts"] == %{}

    assert [%{"source_ref" => "thread", "task_id" => "task", "body" => "Mail"}] =
             CommaWeb.ProactiveRoutine.items(result)

    assert :ok = Comma.RecommendationContract.validate(result)
  end

  test "a long selected URL keeps an executable recipe and a bounded Home key" do
    url = "https://example.test/" <> String.duplicate("a", 600)
    snapshot = snapshot()
    [card] = snapshot["cards"]
    [item] = card["items"]
    item = put_in(item, ["parts", Access.at(0), "link", "href"], url)

    result =
      snapshot
      |> Map.put("cards", [Map.put(card, "items", [item])])
      |> CommaWeb.ProactiveRoutine.attach([])

    assert :ok = Comma.RecommendationContract.validate(result)
    [matter] = CommaWeb.ProactiveRoutine.items(result)
    assert CommaWeb.ProactiveRoutine.valid_args?(matter["read"]["arguments"])
    assert byte_size(SalixIM.MailInteraction.key(matter["source_id"], matter["source_ref"])) < 600
  end

  defp snapshot do
    %{
      "protocolVersion" => 1,
      "templateCatalogVersion" => 1,
      "generatedAt" => 1,
      "generation" => 1,
      "sourceRevision" => 1,
      "summary" => [%{"kind" => "markdown", "text" => "Hello"}],
      "warnings" => [],
      "prompts" => %{
        "p" => %{
          "sourceId" => "account",
          "objective" => "Review",
          "context" => "Mail",
          "contextLabel" => "Mail"
        }
      },
      "cards" => [
        %{
          "id" => "c",
          "template" => "text-list@1",
          "title" => "Mail",
          "fallbackText" => "Mail",
          "sourceIds" => ["account"],
          "items" => [
            %{
              "id" => "i",
              "parts" => [
                %{
                  "kind" => "inline-link",
                  "link" => %{
                    "sourceId" => "account",
                    "href" => "https://mail.google.com/mail/#inbox/message",
                    "label" => String.duplicate("x", 90),
                    "promptId" => "p"
                  }
                }
              ],
              "action" => %{
                "type" => "send_to_comma",
                "label" => "Use prompt",
                "promptId" => "p",
                "requiresConfirmation" => true
              }
            }
          ]
        }
      ]
    }
  end
end
