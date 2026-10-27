defmodule SalixMeet.CalendarPreparationTest do
  use SystemsClock.Case, async: true

  alias SalixMeet.CalendarPreparation

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

  test "writeback replaces a block written under the pre-rename markers" do
    original = "Agenda\n"

    legacy =
      "<!-- cue:meeting-preparation:begin --><h3>Meeting preparation</h3>" <>
        "<p>September topics</p><!-- cue:meeting-preparation:end -->"

    assert {:ok, description} = CalendarPreparation.merge(original <> legacy, "October topics")
    assert String.starts_with?(description, original)
    assert description =~ "October topics"
    refute description =~ "September topics"
    refute description =~ "cue:meeting-preparation"
    assert {:ok, ^original} = CalendarPreparation.human_description(original <> legacy)
    assert {:ok, ^original} = CalendarPreparation.human_description(legacy <> original)

    assert {:ok, ^original} =
             CalendarPreparation.human_description(legacy <> description)
  end
end
