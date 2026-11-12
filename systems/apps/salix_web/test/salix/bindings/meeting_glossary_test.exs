defmodule Salix.Bindings.MeetingGlossaryTest do
  use SystemsClock.Case, async: true

  alias Salix.Bindings.MeetingGlossary, as: G

  @glossary """
  # Meeting spellings
  Misheard → correct, one per item.

  - Noxing / Nosing → Nothing（a customer）
  - Cloud Code -> Claude Code
  - 敬非 / 静飞 → JINFEI YANG (Slack display Jimmfly)
  - Q → Cue
  """

  test "corrects listed forms, whole Latin words only, and ignores prose and one-letter forms" do
    corrections = G.parse(@glossary)

    assert G.apply_to("敬非 说 Noxing 用 Cloud Code；Noxingly 和 Q 不变", corrections) ==
             "JINFEI YANG 说 Nothing 用 Claude Code；Noxingly 和 Q 不变"

    assert G.apply_to("Misheard → correct, one per item.", corrections) ==
             "Misheard → correct, one per item."
  end

  # The recording ASR is asked to spell these, so it writes the team's terms
  # instead of guessing (2026-10-30: "Safety" for CFT).
  test "names each correct form once for the recording ASR" do
    text = @glossary <> "- 镜非 → JINFEI YANG\n- → CFT\n"

    assert G.terms(text) == ["Nothing", "Claude Code", "JINFEI YANG", "Cue", "CFT"]
    assert G.apply_to("CFT 和 Safety", G.parse(text)) == "CFT 和 Safety"
  end
end
