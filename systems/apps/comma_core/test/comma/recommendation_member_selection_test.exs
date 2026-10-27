defmodule Comma.RecommendationMemberSelectionTest do
  use ExUnit.Case, async: true

  alias Comma.RecommendationMemberSelection

  defp md(text), do: %{"kind" => "markdown", "text" => text}

  defp link(id),
    do: %{
      "kind" => "inline-link",
      "link" => %{
        "href" => "https://linear.app/team/issue/#{id}",
        "label" => id,
        "promptId" => id,
        "sourceId" => "linear"
      }
    }

  defp prompts(objectives),
    do: Map.new(objectives, fn {id, objective} -> {id, %{"objective" => objective}} end)

  defp hiding(ids), do: &(&1["promptId"] in ids)

  test "a member summary loses only the clauses of the hidden items" do
    summary = [
      md("Your briefing\n\nHere is what I suggest you focus on: Review PR 1 "),
      link("p1"),
      md("; Reply to Ada "),
      link("p2"),
      md("; Ship v2\\.4 "),
      link("p3"),
      md(".")
    ]

    prompts = prompts(%{"p1" => "Review PR 1.", "p2" => "Reply to Ada", "p3" => "Ship v2.4"})

    assert {:ok,
            [
              md("Your briefing\n\nHere is what I suggest you focus on: Review PR 1 "),
              link("p1"),
              md("; Ship v2\\.4 "),
              link("p3"),
              md(".")
            ]} ==
             RecommendationMemberSelection.without_summary_items(summary, prompts, hiding(["p2"]))

    assert {:ok, ^summary} =
             RecommendationMemberSelection.without_summary_items(summary, prompts, hiding([]))
  end

  test "a Chinese member summary keeps its own separators" do
    summary = [
      md("你的事项简报\n\n建议你先关注这几件事：回复 Ada "),
      link("p1"),
      md("；合并 PR "),
      link("p2"),
      md("。")
    ]

    prompts = prompts(%{"p1" => "回复 Ada", "p2" => "合并 PR。"})

    assert {:ok, [md("你的事项简报\n\n建议你先关注这几件事：合并 PR "), link("p2"), md("。")]} ==
             RecommendationMemberSelection.without_summary_items(summary, prompts, hiding(["p1"]))
  end

  test "model prose, or a summary with no cited item left, is not rebuilt" do
    prose = [md("Your briefing\n\nAda is waiting on "), link("p1"), md(" before the release.")]
    prompts = prompts(%{"p1" => "Reply to Ada"})

    assert :error =
             RecommendationMemberSelection.without_summary_items(prose, prompts, hiding([]))

    member = [
      md("Your briefing\n\nHere is what I suggest you focus on: Reply to Ada "),
      link("p1"),
      md(".")
    ]

    assert :error =
             RecommendationMemberSelection.without_summary_items(member, prompts, hiding(["p1"]))

    assert :error = RecommendationMemberSelection.without_summary_items(member, %{}, hiding([]))
  end
end
