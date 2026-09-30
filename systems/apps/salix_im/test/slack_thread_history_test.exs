defmodule SalixIM.SlackThreadHistoryTest do
  use ExUnit.Case, async: true

  alias SalixIM.Provider.Slack.{MessageReferences, ThreadHistory}

  test "native Task result survives ordinary and forwarded history in visible order" do
    alias SalixIM.MessageRenderer.Surface
    alias SalixIM.Provider.Slack.MessageRenderer

    output =
      "Approved PR #67. No blockers. No blockers.\n\n" <>
        "[Review](https://github.com/example/project/pull/67#pullrequestreview-123)\n\n" <>
        "~~Merged~~ Nothing merged or deployed."

    assert {:ok, rendered} =
             MessageRenderer.render_surface(
               %Surface{
                 kind: :task_card,
                 id: "review-67",
                 title: "Review PR #67",
                 status: :complete,
                 output: output,
                 fallback: "Review PR #67"
               },
               []
             )

    direct =
      rendered
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("ts", "6.1")

    [summary] = ThreadHistory.result(%{"messages" => [direct]})["messages"]
    assert [card] = summary["task_cards"]
    assert card["title"] == "Review PR #67"
    assert card["status"] == "complete"
    assert card["output_complete"] == true
    assert card["output"] =~ "No blockers. No blockers."

    assert card["output"] =~
             "Review (https://github.com/example/project/pull/67#pullrequestreview-123)"

    assert card["output"] =~ "~~Merged~~ Nothing merged or deployed."
    refute Map.has_key?(summary, "blocks")

    forwarded = %{
      "ts" => "7.1",
      "text" => "Why no answer?",
      "attachments" => [
        Map.merge(direct, %{
          "is_msg_unfurl" => true,
          "channel_id" => "C_SOURCE",
          "text" => "Task Review PR #67: ready for review"
        })
      ]
    }

    [summary] = ThreadHistory.result(%{"messages" => [forwarded]})["messages"]
    assert [%{"task_cards" => [^card]}] = summary["source_references"]
    assert MessageReferences.content_suffix(forwarded) =~ "Nothing merged or deployed."
  end

  test "Task output bounds and unsupported content stay explicit without raw payload" do
    task = %{
      "type" => "task_card",
      "title" => "Review",
      "status" => "complete",
      "task_id" => "PRIVATE_TASK_ID",
      "details" => %{"text" => "PRIVATE_DETAILS"},
      "output" => %{
        "type" => "rich_text",
        "elements" => [
          %{
            "type" => "rich_text_section",
            "elements" => [
              %{"type" => "text", "text" => String.duplicate("结果", 3000)}
            ]
          },
          %{"type" => "unknown", "text" => "PRIVATE_UNKNOWN"}
        ]
      }
    }

    [summary] =
      ThreadHistory.result(%{"messages" => [%{"ts" => "6.1", "blocks" => [task]}]})["messages"]

    assert [card] = summary["task_cards"]
    assert card["output_complete"] == false
    assert byte_size(card["output"]) <= 4096
    assert String.valid?(card["output"])
    refute inspect(summary) =~ "PRIVATE_"

    # A completion badge with no readable output is not a result.
    missing = Map.delete(task, "output")

    [summary] =
      ThreadHistory.result(%{"messages" => [%{"ts" => "6.2", "blocks" => [missing]}]})["messages"]

    assert [%{"output" => "", "output_complete" => false}] = summary["task_cards"]

    # Deep rich text consumes the same node budget as siblings.
    deep =
      Enum.reduce(1..150, %{"type" => "text", "text" => "unreached"}, fn _, child ->
        %{"type" => "rich_text_section", "elements" => [child]}
      end)

    [summary] =
      ThreadHistory.result(%{
        "messages" => [%{"ts" => "6.3", "blocks" => [Map.put(task, "output", deep)]}]
      })["messages"]

    assert [%{"output_complete" => false}] = summary["task_cards"]
    refute inspect(summary) =~ "unreached"
  end

  test "previous_messages includes the root in the first bounded chronological page" do
    messages = [
      %{"ts" => "1.0", "text" => "root", "user" => "U-root"},
      %{"ts" => "1.1", "text" => "reply one", "user" => "U1"},
      %{"ts" => "1.2", "text" => "reply two", "user" => "U2"},
      %{"ts" => "1.3", "text" => "trigger", "user" => "U3"}
    ]

    assert Enum.map(ThreadHistory.previous_messages(messages, "1.3", 10), & &1["ts"]) == [
             "1.0",
             "1.1",
             "1.2"
           ]
  end

  test "previous_messages keeps the first ten strict-prior messages Slack can return" do
    root = %{"ts" => "1.000000", "text" => "root", "user" => "U-root"}

    replies =
      for index <- 1..12 do
        %{
          "ts" => "1." <> String.pad_leading(Integer.to_string(index), 6, "0"),
          "text" => "reply #{index}",
          "user" => "U#{index}"
        }
      end

    trigger = %{"ts" => "1.000013", "text" => "trigger", "user" => "U-trigger"}
    newer = %{"ts" => "1.000014", "text" => "newer", "user" => "U-newer"}

    result = ThreadHistory.previous_messages([trigger, newer, root | replies], trigger["ts"], 10)

    assert Enum.map(result, & &1["ts"]) ==
             ["1.000000"] ++
               Enum.map(1..9, &("1." <> String.pad_leading(Integer.to_string(&1), 6, "0")))
  end

  test "previous_messages keeps only bounded structured forwarded-message references" do
    [message] =
      ThreadHistory.previous_messages(
        [
          %{
            "ts" => "6.1",
            "text" => "forwarded context",
            "user" => "U_FORWARDER",
            "blocks" => [
              %{
                "type" => "rich_text",
                "elements" => [
                  %{
                    "type" => "rich_text_section",
                    "elements" => [
                      %{
                        "type" => "message_mention",
                        "channel_id" => %{"unexpected" => "shape"},
                        "message_ts" => ["5.000000"],
                        "text" => %{"unexpected" => "shape"}
                      },
                      %{
                        "type" => "message_mention",
                        "author_id" => "U_AUTHOR",
                        "channel_id" => "C_SOURCE",
                        "message_ts" => "5.123456",
                        "thread_ts" => "5.000001",
                        "text" => "source excerpt",
                        "url" => "https://private.example/source?token=secret"
                      },
                      %{"type" => "link", "url" => "https://private.example/arbitrary"}
                    ]
                  }
                ]
              },
              %{
                "type" => "section",
                "text" => %{"type" => "mrkdwn", "text" => "display-only private text"}
              }
            ]
          }
        ],
        "6.2",
        10
      )

    assert message["source_references"] == [
             %{
               "type" => "message_mention",
               "author_id" => "U_AUTHOR",
               "channel_id" => "C_SOURCE",
               "message_ts" => "5.123456",
               "thread_ts" => "5.000001",
               "text" => "source excerpt"
             }
           ]

    refute inspect(message) =~ "private.example"
    refute inspect(message) =~ "display-only private text"
  end

  test "forwarded references bound timestamps before projection" do
    oversized_timestamp = String.duplicate("1", 129) <> ".1"

    message = %{
      "blocks" => [
        %{
          "type" => "rich_text",
          "elements" => [
            %{
              "type" => "rich_text_section",
              "elements" => [
                %{
                  "type" => "message_mention",
                  "channel_id" => "C_OVERSIZED_PRIMARY",
                  "message_ts" => oversized_timestamp
                },
                %{
                  "type" => "message_mention",
                  "channel_id" => "C_VALID",
                  "message_ts" => "5.123456",
                  "thread_ts" => oversized_timestamp
                }
              ]
            }
          ]
        }
      ]
    }

    assert MessageReferences.from_message(message) == [
             %{
               "type" => "message_mention",
               "channel_id" => "C_VALID",
               "message_ts" => "5.123456"
             }
           ]

    suffix = MessageReferences.content_suffix(message)
    refute suffix =~ oversized_timestamp
    assert byte_size(suffix) < 1_024
  end

  test "message unfurl attachments project only bounded source coordinates" do
    message = %{
      "blocks" => [
        %{
          "type" => "rich_text",
          "elements" => [
            %{
              "type" => "rich_text_section",
              "elements" => [
                %{
                  "type" => "message_mention",
                  "channel_id" => "C09LH8P4M0R",
                  "message_ts" => "1788145186.109259",
                  "text" => "DUPLICATE_BLOCK_SECRET",
                  "url" => "https://private.example/duplicate"
                }
              ]
            }
          ]
        }
      ],
      "attachments" => [
        %{
          "is_msg_unfurl" => true,
          "is_reply_unfurl" => true,
          "author_id" => "U0SOURCEAUTHOR",
          "channel_id" => "C09LH8P4M0R",
          "ts" => "1788145186.109259",
          "text" => String.duplicate("界", 300),
          "from_url" =>
            "https://comma-3kl2780.slack.com/archives/C09LH8P4M0R/p1788145186109259?thread_ts=1788141674.087469&cid=C09LH8P4M0R",
          "blocks" => [%{"type" => "section", "text" => "PRIVATE_NESTED_BLOCK"}],
          "files" => [%{"url_private" => "https://private.example/source"}]
        },
        %{
          "is_msg_unfurl" => true,
          "channel_id" => %{"unexpected" => "shape"},
          "ts" => "1788145186.109259",
          "text" => "INVALID_ATTACHMENT_SECRET",
          "from_url" => "https://evil.example/archives/C09LH8P4M0R/p1788145186109259"
        }
      ]
    }

    assert [reference] = MessageReferences.from_message(message)

    assert Map.drop(reference, ["text"]) == %{
             "type" => "message_unfurl",
             "author_id" => "U0SOURCEAUTHOR",
             "channel_id" => "C09LH8P4M0R",
             "message_ts" => "1788145186.109259",
             "thread_ts" => "1788141674.087469"
           }

    assert byte_size(reference["text"]) <= 512
    assert String.ends_with?(reference["text"], "… [truncated]")

    suffix = MessageReferences.content_suffix(message)
    refute suffix =~ "comma-3kl2780.slack.com"
    refute suffix =~ "PRIVATE_NESTED_BLOCK"
    refute suffix =~ "private.example"
    refute suffix =~ "DUPLICATE_BLOCK_SECRET"
    refute suffix =~ "INVALID_ATTACHMENT_SECRET"
    refute suffix =~ "evil.example"
  end

  test "message unfurl attachments reject thread coordinates from untrusted or mismatched permalinks" do
    invalid_urls = [
      "https://evil.example/archives/C_SOURCE/p1788145186109259?thread_ts=1788141674.087469&cid=C_SOURCE",
      "https://comma.slack.com/archives/C_OTHER/p1788145186109259?thread_ts=1788141674.087469&cid=C_SOURCE",
      "https://comma.slack.com/archives/C_SOURCE/p1788145186109260?thread_ts=1788141674.087469&cid=C_SOURCE",
      "https://comma.slack.com/archives/C_SOURCE/p1788145186109259?thread_ts=1788141674.087469&cid=C_OTHER"
    ]

    for from_url <- invalid_urls do
      assert MessageReferences.from_message(%{
               "attachments" => [
                 %{
                   "is_msg_unfurl" => true,
                   "channel_id" => "C_SOURCE",
                   "ts" => "1788145186.109259",
                   "from_url" => from_url
                 }
               ]
             }) == [
               %{
                 "type" => "message_unfurl",
                 "channel_id" => "C_SOURCE",
                 "message_ts" => "1788145186.109259"
               }
             ]
    end
  end

  test "duplicate forwarded references do not consume the unique-reference budget" do
    duplicate = %{
      "type" => "message_mention",
      "channel_id" => "C_DUPLICATE",
      "message_ts" => "5.123456"
    }

    distinct = %{
      "type" => "message_mention",
      "channel_id" => "C_DISTINCT",
      "message_ts" => "6.123456"
    }

    message = %{
      "blocks" => [
        %{
          "type" => "rich_text",
          "elements" => [
            %{
              "type" => "rich_text_section",
              "elements" => [duplicate, duplicate, duplicate, distinct]
            }
          ]
        }
      ]
    }

    assert Enum.map(MessageReferences.from_message(message), & &1["channel_id"]) == [
             "C_DUPLICATE",
             "C_DISTINCT"
           ]
  end

  test "previous_messages keeps historical file metadata without private URLs" do
    [message] =
      ThreadHistory.previous_messages(
        [
          %{
            "ts" => "7.1",
            "text" => "image",
            "user" => "U1",
            "files" => [
              %{
                "id" => "F1",
                "name" => "image.png",
                "mimetype" => "image/png",
                "size" => 42,
                "url_private" => "https://private.example/F1"
              }
            ]
          }
        ],
        "7.2",
        10
      )

    assert message["files"] == [
             %{"id" => "F1", "name" => "image.png", "mimetype" => "image/png", "size" => 42}
           ]

    refute inspect(message) =~ "private.example"
  end

  test "a terminal bounded page omits continuation metadata" do
    result =
      ThreadHistory.result(
        %{
          "messages" => [
            %{"ts" => "8.1", "text" => "root"},
            %{"ts" => "8.2", "text" => "reply"}
          ],
          "has_more" => false
        },
        before_ts: "8.3",
        limit: 10
      )

    assert result["has_more"] == false
    refute Map.has_key?(result, "next_before_ts")
    refute Map.has_key?(result, "next_cursor")
  end

  test "a partial bounded page preserves Slack's cursor and chronological order" do
    result =
      ThreadHistory.result(
        %{
          "messages" => [
            %{"ts" => "8.0", "text" => "root"},
            %{"ts" => "8.1", "text" => "first"},
            %{"ts" => "8.2", "text" => "second"}
          ],
          "has_more" => true,
          "response_metadata" => %{"next_cursor" => "NEXT"}
        },
        before_ts: "8.3",
        limit: 3
      )

    assert Enum.map(result["messages"], & &1["ts"]) == ["8.0", "8.1", "8.2"]
    assert result["has_more"] == true
    assert result["next_cursor"] == "NEXT"
    refute Map.has_key?(result, "next_before_ts")
  end

  test "a filtered-empty reverse page preserves Slack's usable cursor" do
    result =
      ThreadHistory.result(
        %{
          "messages" => [%{"ts" => "9.5", "text" => "boundary or newer"}],
          "has_more" => true,
          "response_metadata" => %{"next_cursor" => "NEXT"}
        },
        before_ts: "9.5",
        limit: 10
      )

    assert result == %{"messages" => [], "has_more" => true, "next_cursor" => "NEXT"}
  end

  test "valid_timestamp? accepts Slack precision without converting through floats" do
    assert ThreadHistory.valid_timestamp?("1787056149.639939")
    assert ThreadHistory.valid_timestamp?("1.2")
    refute ThreadHistory.valid_timestamp?("1787056149")
    refute ThreadHistory.valid_timestamp?("1.1234567")
    refute ThreadHistory.valid_timestamp?("not-a-timestamp")
  end
end
