defmodule SalixMeet.CalendarPreparationTest do
  use ExUnit.Case, async: true

  alias SalixMeet.CalendarPreparation

  test "renders report Markdown as HTML with working links and line breaks" do
    report =
      "## 发布准备\n\n1. **检查发布**\n查看 [PR #1507](https://github.com/AFK-surf/Comma/pull/1507)\n\n> 保留引用\n\n`status`"

    assert {:ok, description} = CalendarPreparation.merge("Human agenda\n", report)
    assert description =~ "<h2>发布准备</h2>"
    assert description =~ "<ol>"
    assert description =~ "<strong>检查发布</strong><br />"
    assert description =~ ~s(<a href="https://github.com/AFK-surf/Comma/pull/1507">PR #1507</a>)
    assert description =~ "<blockquote>"
    assert description =~ "<code>status</code>"
    refute description =~ "<pre>"
    assert {:ok, "Human agenda\n"} = CalendarPreparation.human_description(description)
  end

  test "Markdown cannot activate script URLs or raw HTML" do
    assert {:ok, description} =
             CalendarPreparation.merge(
               "",
               "[bad](javascript:alert(1))\n\n<img src=x onerror=alert(1)>"
             )

    refute description =~ ~s(href="javascript:)
    refute description =~ "<img"
  end

  test "writeback preserves the human description and replaces only its own block" do
    original = "<b>Agenda</b>\nKeep these notes exactly.\n"
    assert {:ok, first} = CalendarPreparation.merge(original, "Read the launch proposal")
    assert {:ok, second} = CalendarPreparation.merge(first <> "Human follow-up", "Review metrics")
    assert String.starts_with?(second, original)
    assert String.ends_with?(second, "Human follow-up")
    assert second =~ "Review metrics"
    refute second =~ "Read the launch proposal"
    assert {:ok, ^second} = CalendarPreparation.merge(second, "Review metrics")
    assert {:ok, human} = CalendarPreparation.human_description(second)
    assert human == original <> "Human follow-up"
  end

  test "research text cannot inject markup or close the managed block" do
    report = "<script>oops</script><!-- comma:meeting-preparation:end --> & notes"
    assert {:ok, description} = CalendarPreparation.merge(nil, report)
    refute description =~ "<script>"
    assert description =~ "&lt;script&gt;"
    assert {:ok, ""} = CalendarPreparation.human_description(description)
  end

  test "malformed or duplicate blocks leave the original untouched" do
    assert {:ok, block} = CalendarPreparation.merge("", "Preparation")

    for description <- [
          block <> block,
          "Notes<!-- comma:meeting-preparation:begin -->unfinished",
          "<!-- comma:meeting-preparation:end -->Notes"
        ] do
      assert {:error, :ambiguous_calendar_preparation_block} =
               CalendarPreparation.merge(description, "Replacement")
    end
  end

  test "rejects empty and oversized reports before any write" do
    assert {:error, :empty_meeting_preparation} = CalendarPreparation.merge("Notes", " \n")

    assert {:error, :invalid_meeting_preparation} =
             CalendarPreparation.merge("Notes", String.duplicate("a", 16_001))
  end
end
