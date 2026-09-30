defmodule SalixMeet.PreparationMarkdownTest do
  use ExUnit.Case, async: true

  alias SalixMeet.{CalendarPreparation, PreparationMarkdown}
  alias SalixIM.Provider.Slack.MessageRenderer

  test "source and related-person links stay clickable without mention notifications" do
    report =
      PreparationMarkdown.normalize(
        "1. **发布准备**\n查看 <https://github.com/AFK-surf/Comma/pull/1507|PR #1507>\n" <>
          "方案提出者：[@Alex](https://example.slack.com/team/U123)"
      )

    assert {:ok, %{blocks: blocks}} = MessageRenderer.render(report)

    assert %{
             "type" => "link",
             "text" => "PR #1507",
             "url" => "https://github.com/AFK-surf/Comma/pull/1507"
           } in descendants(blocks)

    assert %{
             "type" => "link",
             "text" => "@Alex",
             "url" => "https://example.slack.com/team/U123"
           } in descendants(blocks)

    refute Enum.any?(
             descendants(blocks),
             &(&1["type"] in ["user", "usergroup", "broadcast", "channel"])
           )

    assert %{"type" => "text", "text" => "发布准备", "style" => %{"bold" => true}} in descendants(
             blocks
           )

    assert {:ok, html} = CalendarPreparation.merge("", report)
    assert html =~ ~s(<a href="https://github.com/AFK-surf/Comma/pull/1507">PR #1507</a>)
    assert html =~ ~s(<a href="https://example.slack.com/team/U123">@Alex</a>)
  end

  test "standard Markdown links, autolinks and quotes survive while provider references stay inert" do
    markdown = "[PR](<https://example.com/pr>)\n\n<https://example.com>\n\n> quote"
    assert PreparationMarkdown.normalize(markdown) == markdown

    report =
      PreparationMarkdown.normalize(
        "**Review** <@U123> <!here> <!channel> <!subteam^S123|team> <#C123|channel>"
      )

    refute report =~ "<"
    assert {:ok, %{blocks: blocks}} = MessageRenderer.render(report)

    refute Enum.any?(
             descendants(blocks),
             &(&1["type"] in ["user", "usergroup", "broadcast", "channel"])
           )

    assert report =~ "‹@U123›"
  end

  test "Slack source labels cannot break the standard Markdown link" do
    report = PreparationMarkdown.normalize("**Source** <https://example.com/pr|PR [draft]*>")
    assert {:ok, %{blocks: blocks}} = MessageRenderer.render(report)

    assert %{"type" => "link", "text" => "PR [draft]*", "url" => "https://example.com/pr"} in descendants(
             blocks
           )
  end

  defp descendants(value) when is_list(value), do: Enum.flat_map(value, &descendants/1)
  defp descendants(value) when is_map(value), do: [value | descendants(Map.values(value))]
  defp descendants(_value), do: []
end
