defmodule SalixIM.SlackMessageMirrorBlockTextTest do
  @moduledoc """
  What the mirror can find in a message an app posted.

  `text` is the whole message only when a human typed it. Everything here is
  about the other case, which is most of what integrations and our own cards
  put in a channel.
  """
  use SystemsClock.Case, async: true

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
  end

  describe "the surfaces this repo actually posts" do
  end

  describe "interactive blocks" do
    # `actions` carries `elements`, `input` carries a single `element` plus its
    # own label and hint, a button says `text`, a select says `placeholder` and
    # names its choices in `options`. Reading `elements[].text` for both finds
    # the button and silently misses everything else.
    for {name, block, fragments} <- [
          {"a select in an actions block contributes its placeholder and options",
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
           }, ["Choose a severity", "Sev1 outage", "Sev2 degraded"]},
          {"an input block contributes its label, hint and element",
           %{
             "type" => "input",
             "label" => %{"type" => "plain_text", "text" => "Rollback reason"},
             "hint" => %{"type" => "plain_text", "text" => "Shown to the on-call"},
             "element" => %{
               "type" => "plain_text_input",
               "placeholder" => %{"type" => "plain_text", "text" => "why are we reverting"}
             }
           }, ["Rollback reason", "Shown to the on-call", "why are we reverting"]},
          {"grouped options and a preselected choice are reachable too",
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
           }, ["current pick", "regions", "eu-west-1"]}
        ] do
      @block block
      @fragments fragments
      test name do
        flattened = BlockText.flatten(%{"blocks" => [@block]})

        for fragment <- @fragments do
          assert flattened =~ fragment
        end
      end
    end
  end

  describe "mentions" do
  end

  describe "deduplication against text" do
  end

  describe "retained blocks" do

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
