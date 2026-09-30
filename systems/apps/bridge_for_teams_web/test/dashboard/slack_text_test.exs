defmodule BridgeForTeamsWeb.Dashboard.SlackTextTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias BridgeForTeamsWeb.Dashboard.Components.SlackText

  test "Slack mentions and labelled links render as names and links, preserving newlines" do
    html =
      render_component(&SlackText.slack_text/1,
        text: "<@U123> review <https://github.com/AFK-surf/Comma/pull/1602|PR #1602>\nnext line",
        mentions: %{"U123" => "codex-3720"}
      )

    assert html =~ "@codex-3720"
    assert html =~ ~s(href="https://github.com/AFK-surf/Comma/pull/1602")
    assert html =~ ">PR #1602</a>"
    assert html =~ "\nnext line"
    refute html =~ "U123"
  end

  test "missing profiles never display raw ids and Slack markup cannot inject HTML" do
    html =
      render_component(&SlackText.slack_text/1,
        text:
          "<@U123> <@not-a-user> literal <javascript:alert(1)|click> &lt;script&gt;alert(1)&lt;/script&gt;",
        mentions: %{}
      )

    assert html =~ "@Slack participant"
    refute html =~ "U123"
    assert html =~ "&lt;@not-a-user&gt; literal"
    refute html =~ "<script>"
    refute html =~ ~s(href="javascript:)
  end
end
