defmodule SalixIM.SlackMessageMirrorBlockTextTest do
  @moduledoc """
  What the mirror can find in a message an app posted.

  `text` is the whole message only when a human typed it. Everything here is
  about the other case, which is most of what integrations and our own cards
  put in a channel.
  """
  use ExUnit.Case, async: true

  alias SalixIM.MessageRenderer.Surface
  alias SalixIM.Provider.Slack.MessageRenderer
  alias SalixIM.SlackMessageMirror.{BlockText, Row}

  describe "app messages whose content is not in text" do
    test "a block-only card is searchable instead of looking like an empty message" do
      assert {:ok, row} = Row.from_event(connect(), envelope(card()))

      assert row["text"] == ""
      assert row["body_text"] =~ "Deploy failed"
      assert row["body_text"] =~ "api-gateway"
      assert row["body_text"] =~ "Retry"
    end

    test "legacy attachments are flattened too" do
      message =
        message(%{
          "attachments" => [
            %{
              "pretext" => "New issue",
              "title" => "COMMA-42 payments time out",
              "text" => "Reported by three customers",
              "fields" => [%{"title" => "Priority", "value" => "P1"}]
            }
          ]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))

      for fragment <- ["New issue", "COMMA-42 payments time out", "Reported by three", "P1"] do
        assert row["body_text"] =~ fragment
      end
    end

    # An `attachment` fallback almost always repeats its text, and a card often
    # repeats its header in a section. Indexing both buys nothing.
    test "repeated fragments are indexed once" do
      message =
        message(%{
          "attachments" => [%{"text" => "the same line", "fallback" => "the same line"}]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))
      assert row["body_text"] == "the same line"
    end
  end

  describe "the surfaces this repo actually posts" do
    # Built by the real renderer rather than a hand-written stand-in. The
    # previous test assembled a "card" out of header/section/actions, which is
    # not what `MessageRenderer` emits, and that is what let a catch-all drop
    # `card`, `plan`, `task_card`, `markdown` and `table` unnoticed — leaving
    # our own Task cards holding nothing but their one-line fallback.
    test "a Task card's details, output and sources are searchable" do
      surface = %Surface{
        kind: :task_card,
        id: "task-42",
        fallback: "Task update",
        title: "Rotate the signing key",
        status: :in_progress,
        details: "Blocked on the HSM maintenance window",
        output: "Rehearsal completed on staging"
      }

      assert {:ok, %{blocks: blocks}} = MessageRenderer.render_surface(surface, [])
      flattened = BlockText.flatten(%{"blocks" => blocks})

      assert flattened =~ "Rotate the signing key"
      assert flattened =~ "Blocked on the HSM maintenance window"
      assert flattened =~ "Rehearsal completed on staging"
      assert flattened =~ "in_progress"
    end

    test "a Workflow plan's tasks are searchable" do
      surface = %Surface{
        kind: :plan,
        id: "plan-7",
        fallback: "Plan update",
        title: "Incident remediation",
        tasks: [
          %{
            id: "t1",
            title: "Drain the affected region",
            status: :complete,
            details: "eu-west-1 removed from rotation"
          },
          %{id: "t2", title: "Re-run the failover rehearsal", status: :pending}
        ]
      }

      assert {:ok, %{blocks: blocks}} = MessageRenderer.render_surface(surface, [])
      flattened = BlockText.flatten(%{"blocks" => blocks})

      assert flattened =~ "Incident remediation"
      assert flattened =~ "Drain the affected region"
      assert flattened =~ "eu-west-1 removed from rotation"
      assert flattened =~ "Re-run the failover rehearsal"
    end

    test "a card's title, body and action labels are searchable" do
      surface = %Surface{
        kind: :card,
        id: "card-1",
        fallback: "Deploy summary",
        title: "Deploy failed",
        subtitle: "api-gateway v42",
        body: "The canary never reported healthy",
        subtext: "Owner: platform",
        actions: [%{id: "retry", text: "Retry the deploy"}]
      }

      assert {:ok, %{blocks: blocks}} = MessageRenderer.render_surface(surface, [])
      flattened = BlockText.flatten(%{"blocks" => blocks})

      for fragment <- [
            "Deploy failed",
            "api-gateway v42",
            "The canary never reported healthy",
            "Owner: platform",
            "Retry the deploy"
          ] do
        assert flattened =~ fragment
      end
    end

    test "markdown and table surfaces are searchable" do
      assert {:ok, %{blocks: blocks}} =
               MessageRenderer.render("""
               ## Rollout status

               | Region | State |
               | --- | --- |
               | eu-west-1 | drained |
               """)

      flattened = BlockText.flatten(%{"blocks" => blocks})

      assert flattened =~ "Rollout status"
      assert flattened =~ "eu-west-1"
      assert flattened =~ "drained"
    end
  end

  describe "interactive blocks" do
    # `actions` carries `elements`, `input` carries a single `element` plus its
    # own label and hint, a button says `text`, a select says `placeholder` and
    # names its choices in `options`. Reading `elements[].text` for both finds
    # the button and silently misses everything else.
    test "a select in an actions block contributes its placeholder and options" do
      flattened =
        BlockText.flatten(%{
          "blocks" => [
            %{
              "type" => "actions",
              "elements" => [
                %{
                  "type" => "static_select",
                  "placeholder" => %{"type" => "plain_text", "text" => "Choose a severity"},
                  "options" => [
                    %{"text" => %{"type" => "plain_text", "text" => "Sev1 outage"}},
                    %{"text" => %{"type" => "plain_text", "text" => "Sev2 degraded"}}
                  ]
                }
              ]
            }
          ]
        })

      assert flattened =~ "Choose a severity"
      assert flattened =~ "Sev1 outage"
      assert flattened =~ "Sev2 degraded"
    end

    test "an input block contributes its label, hint and element" do
      flattened =
        BlockText.flatten(%{
          "blocks" => [
            %{
              "type" => "input",
              "label" => %{"type" => "plain_text", "text" => "Rollback reason"},
              "hint" => %{"type" => "plain_text", "text" => "Shown to the on-call"},
              "element" => %{
                "type" => "plain_text_input",
                "placeholder" => %{"type" => "plain_text", "text" => "why are we reverting"}
              }
            }
          ]
        })

      assert flattened =~ "Rollback reason"
      assert flattened =~ "Shown to the on-call"
      assert flattened =~ "why are we reverting"
    end

    test "grouped options and a preselected choice are reachable too" do
      flattened =
        BlockText.flatten(%{
          "blocks" => [
            %{
              "type" => "actions",
              "elements" => [
                %{
                  "type" => "static_select",
                  "initial_option" => %{"text" => %{"text" => "current pick"}},
                  "option_groups" => [
                    %{
                      "label" => %{"text" => "regions"},
                      "options" => [%{"text" => %{"text" => "eu-west-1"}}]
                    }
                  ]
                }
              ]
            }
          ]
        })

      assert flattened =~ "current pick"
      assert flattened =~ "regions"
      assert flattened =~ "eu-west-1"
    end
  end

  describe "mentions" do
    # The point of rendering `<@U...>` rather than a display name: one query
    # matches a mention whether it arrived through `text` or through a block.
    # Rendering a name would make mention search depend on the message's shape.
    test "a block mention is written the way text writes it" do
      message =
        message(%{
          "blocks" => [
            %{
              "type" => "rich_text",
              "elements" => [
                %{
                  "type" => "rich_text_section",
                  "elements" => [
                    %{"type" => "text", "text" => "ping "},
                    %{"type" => "user", "user_id" => "U_ONCALL"},
                    %{"type" => "text", "text" => " in "},
                    %{"type" => "channel", "channel_id" => "C_INCIDENT"}
                  ]
                }
              ]
            }
          ]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))
      assert row["body_text"] =~ "<@U_ONCALL>"
      assert row["body_text"] =~ "<#C_INCIDENT>"
    end

    test "broadcasts and emoji survive the flattening" do
      flattened =
        BlockText.flatten(%{
          "blocks" => [
            %{
              "type" => "rich_text",
              "elements" => [
                %{
                  "type" => "rich_text_section",
                  "elements" => [
                    %{"type" => "broadcast", "range" => "here"},
                    %{"type" => "emoji", "name" => "rocket"}
                  ]
                }
              ]
            }
          ]
        })

      assert flattened =~ "<!here>"
      assert flattened =~ ":rocket:"
    end
  end

  describe "deduplication against text" do
    # The case the skip-on-non-empty-text rule got backwards. An app posting a
    # one-line notification fallback with the real body in a `rich_text` block
    # is exactly the shape this column exists for, and trusting the fallback
    # dropped that body entirely.
    test "a short fallback does not suppress a different rich_text body" do
      message =
        message(%{
          "text" => "Incident update",
          "subtype" => "bot_message",
          "bot_id" => "B_PAGER",
          "blocks" => [
            %{
              "type" => "rich_text",
              "elements" => [
                %{
                  "type" => "rich_text_section",
                  "elements" => [
                    %{"type" => "text", "text" => "Database failover is blocked"}
                  ]
                }
              ]
            }
          ]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))
      assert row["text"] == "Incident update"
      assert row["body_text"] =~ "Database failover is blocked"
    end

    # Dropping only what `text` already contains verbatim is lossless, and it
    # still removes the duplication: a client-composed message's fragments are
    # each present in its mrkdwn.
    test "fragments already present in text are not indexed twice" do
      message =
        message(%{
          "text" => "hello <@U_HUMAN>",
          "blocks" => [
            %{
              "type" => "rich_text",
              "elements" => [
                %{
                  "type" => "rich_text_section",
                  "elements" => [
                    %{"type" => "text", "text" => "hello "},
                    %{"type" => "user", "user_id" => "U_HUMAN"}
                  ]
                }
              ]
            }
          ]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))
      assert row["text"] == "hello <@U_HUMAN>"
      assert row["body_text"] == ""
    end

    test "a section beside a rich_text is still flattened" do
      message =
        message(%{
          "text" => "hello",
          "blocks" => [
            %{"type" => "rich_text", "elements" => []},
            %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => "extra context"}}
          ]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))
      assert row["body_text"] == "extra context"
    end
  end

  describe "retained blocks" do
    test "the payload is kept so a later derivation need not re-walk Slack" do
      assert {:ok, row} = Row.from_event(connect(), envelope(card()))

      assert {:ok, decoded} = Jason.decode(row["blocks"])
      assert [%{"type" => "header"} | _rest] = decoded
    end

    # Truncated JSON is not JSON. Emptying the payload would make a later
    # Slack-substituting read impossible, so an over-size object is stored
    # whole. Search still uses the clamped `body_text` projection.
    test "an over-large payload is stored whole rather than emptied" do
      giant = String.duplicate("x", 300_000)

      message =
        message(%{
          "blocks" => [
            %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => giant}}
          ]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))
      assert {:ok, decoded} = Jason.decode(row["payload"])
      assert get_in(decoded, ["blocks", Access.at(0), "text", "text"]) == giant
      assert row["blocks"] =~ giant
      assert String.length(row["body_text"]) == BlockText.max_chars()
    end

    # `files/1` refuses to store signed attachment links; a block carrying the
    # same reference is not a different rule. Retaining the payload verbatim
    # would have put them back under a different column.
    test "a private file reference never reaches the retained payload" do
      private = "https://files.slack.com/files-pri/T1-F1/secret.png?t=xoxe-signed"

      message =
        message(%{
          "blocks" => [
            %{
              "type" => "image",
              "alt_text" => "the failing dashboard",
              "image_url" => private,
              "slack_file" => %{"id" => "F_DASH", "url" => private}
            },
            %{
              "type" => "actions",
              "elements" => [
                %{
                  "type" => "button",
                  "text" => %{"type" => "plain_text", "text" => "Open"},
                  "value" => "opaque-app-state"
                }
              ]
            }
          ]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))

      # Signed URLs on the file handle are dropped; semantic `value` stays.
      refute row["blocks"] =~ "xoxe-signed"
      refute row["payload"] =~ "xoxe-signed"
      assert row["blocks"] =~ "opaque-app-state"
      assert row["payload"] =~ "opaque-app-state"
      assert row["blocks"] =~ "F_DASH"
      assert row["blocks"] =~ "the failing dashboard"
      assert row["body_text"] =~ "the failing dashboard"
      assert row["body_text"] =~ "Open"
    end

    test "a URL-only slack_file keeps its handle and thumbnail dimensions stay" do
      private = "https://files.slack.com/files-pri/T1-F1/secret.png?t=xoxe-signed"

      message =
        message(%{
          "files" => [
            %{
              "id" => "F_IMG",
              "permalink_public" => "https://slack-files.com/T1-F_IMG-public",
              "thumb_360" => private,
              "thumb_360_w" => 360,
              "thumb_360_h" => 240
            }
          ],
          "blocks" => [
            %{
              "type" => "image",
              "alt_text" => "screenshot",
              "slack_file" => %{"url" => private}
            }
          ]
        })

      assert {:ok, row} = Row.from_event(connect(), envelope(message))
      assert {:ok, payload} = Jason.decode(row["payload"])

      assert get_in(payload, ["blocks", Access.at(0), "slack_file", "url"]) == private

      assert get_in(payload, ["files", Access.at(0), "permalink_public"]) ==
               "https://slack-files.com/T1-F_IMG-public"

      assert get_in(payload, ["files", Access.at(0), "thumb_360_w"]) == 360
      assert get_in(payload, ["files", Access.at(0), "thumb_360_h"]) == 240
      refute payload |> get_in(["files", Access.at(0)]) |> Map.has_key?("thumb_360")
    end

    test "a deleted message keeps neither" do
      assert {:ok, tombstone} =
               Row.from_event(connect(), %{
                 "event" => %{
                   "type" => "message",
                   "subtype" => "message_deleted",
                   "channel" => "C_MIRROR",
                   "deleted_ts" => "1787019001.000000",
                   "event_ts" => "1787019009.000000",
                   "previous_message" => card()
                 }
               })

      assert tombstone["deleted"] == true
      assert tombstone["body_text"] == ""
      assert tombstone["blocks"] == ""
    end
  end

  defp card do
    message(%{
      "text" => "",
      "subtype" => "bot_message",
      "bot_id" => "B_DEPLOY",
      "blocks" => [
        %{"type" => "header", "text" => %{"type" => "plain_text", "text" => "Deploy failed"}},
        %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => "*api-gateway* v42"}},
        %{
          "type" => "actions",
          "elements" => [
            %{"type" => "button", "text" => %{"type" => "plain_text", "text" => "Retry"}}
          ]
        }
      ]
    })
  end

  defp message(extra) do
    Map.merge(
      %{"type" => "message", "ts" => "1787019001.000000", "user" => "U_HUMAN", "text" => ""},
      extra
    )
  end

  defp envelope(message), do: %{"event" => Map.put(message, "channel", "C_MIRROR")}

  defp connect do
    %{"tenant_id" => "TEN_MIRROR", "workspace_id" => "T_WORKSPACE"}
  end
end
