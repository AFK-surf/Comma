defmodule BridgeForTeams.DailyBriefSlackSinkTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.DailyBrief.Sinks.Slack

  @preview "https://acme.slack.com/archives/C1/p1792720000000100"
  @open "slack://channel?team=T1&id=C1&thread_ts=1792600000.000100&message=1792720000.000100"
  @source "<#{@preview}|#sales · 10/23 09:46> · <#{@open}|打开>"

  test "a composed citation reaches Slack as preview and open links" do
    request = %{
      "items" => [%{"ref" => "m1", "in" => "#sales", "at" => "10-23 09:46", "text" => "报价"}]
    }

    text =
      BridgeForTeams.DailyBrief.Compose.finish(
        "请回复。[原消息](m1)",
        request,
        %{"m1" => {@preview, @open}},
        BridgeForTeams.DailyBrief.People.build([], [])
      )

    assert %{blocks: [_header, entry, context]} = Slack.render_personal("每日简报", text)
    assert entry["text"]["text"] == "请回复。"
    assert context["elements"] == [%{"type" => "mrkdwn", "text" => @source}]
  end

  test "preview and native-open links stay together below a plain title" do
    text = "*报价*：请回复客户。#{@source}"
    assert %{blocks: [_header, entry, context]} = Slack.render_team("团队简报", text)
    assert entry["text"]["text"] == "*报价*：请回复客户。"
    assert context["elements"] == [%{"type" => "mrkdwn", "text" => @source}]
    assert Slack.render_team("团队简报", text).text == "报价：请回复客户。"
  end

  test "multiple sources each keep their own open action in one context block" do
    other =
      "<https://acme.slack.com/archives/C2/p12|#eng · 10/23 10:00> · <slack://channel?team=T1&id=C2&message=1.2|打开>"

    text = "1. *处理 <https://github.com/acme/app/pull/42|#42>*：请 <@U1> 跟进。#{@source} #{other}"
    assert %{blocks: [_header, entry, context]} = Slack.render_personal("每日简报", text)

    assert entry["text"]["text"] ==
             "1. *处理 <https://github.com/acme/app/pull/42|#42>*：请 <@U1> 跟进。"

    assert context["elements"] == [%{"type" => "mrkdwn", "text" => @source <> "  /  " <> other}]
  end

  test "a brief without a preview still keeps its native source link" do
    source = "<#{@open}|#sales · 10/23 09:46>"
    assert %{blocks: [_header, entry, context]} = Slack.render_personal("每日简报", "请回复。#{source}")
    assert entry["text"]["text"] == "请回复。"
    assert context["elements"] == [%{"type" => "mrkdwn", "text" => source}]
  end
end
