defmodule CommaWeb.MemberGlossaryTest do
  use ExUnit.Case, async: true

  alias CommaWeb.MemberGlossary
  alias Salix.Bindings.MeetingGlossary

  @today ~D[2026-11-10]

  # The owner's replies in the 11-10 meeting Task, and a Home message.
  defp material do
    %{
      "tasks" => [%{"task" => "cnv1_meeting", "messages" => ["赫洋 是 Heyang，陶伟 是 zanwei"]}],
      "home" => ["明天和 Jiachen He 聊 Monoid"]
    }
  end

  test "a correction counts only when the owner wrote both forms in that meeting Task" do
    answer = %{
      "corrections" => [
        %{"task" => "cnv1_meeting", "heard" => "赫洋", "right" => "Heyang"},
        # Both forms exist, but not in that Task.
        %{"task" => "cnv1_other", "heard" => "陶伟", "right" => "zanwei"},
        # A nickname the owner never corrected.
        %{"task" => "cnv1_meeting", "heard" => "老板", "right" => "Jiachen He"}
      ],
      "names" => [%{"right" => "Monoid"}, %{"right" => "Invented"}]
    }

    file = MemberGlossary.split("")

    assert {:ok, %{corrections: [%{"heard" => "赫洋", "right" => "Heyang"}], names: ["Monoid"]}} =
             MemberGlossary.build(answer, material(), "", file)
  end

  test "a name stays while people.md holds it, else until 60 days after new messages last showed it" do
    file =
      MemberGlossary.split("""
      <!-- comma:glossary: x. since=1 people=2 -->
      - 赫洋 → Heyang（correction 2026-01-01）
      - → Monoid（name 2026-08-01）
      - → Hypershell（name 2026-09-10）
      - → Jiachen He（name 2026-09-12）
      - → Kimi K3（name 2026-09-01）
      <!-- /comma:glossary -->
      """)

    found = %{corrections: [], names: ["Bot Arena"]}
    corpus = "明天和 monoid 聊"

    assert [
             %{"kind" => "correction", "right" => "Heyang", "seen" => ~D[2026-01-01]},
             %{"right" => "Monoid", "seen" => @today},
             %{"right" => "Bot Arena", "seen" => @today},
             %{"right" => "Jiachen He", "seen" => ~D[2026-09-12]},
             %{"right" => "Hypershell", "seen" => ~D[2026-09-10]}
           ] = MemberGlossary.merge(file, found, corpus, "- → hypershell", @today)
  end

  test "the owner's newer correction replaces Comma's older one, and the Router's line wins" do
    file =
      MemberGlossary.split("""
      - 陶伟 → zanwei
      <!-- comma:glossary: x. since=1 people=2 -->
      - 赫洋 → Heyang（correction 2026-11-01）
      - 陶伟 → Zanwei Guo（correction 2026-11-01）
      <!-- /comma:glossary -->
      """)

    found = %{corrections: [%{"heard" => "赫洋", "right" => "Heyang Zhou"}], names: []}

    assert [%{"heard" => "赫洋", "right" => "Heyang Zhou", "seen" => @today}] =
             MemberGlossary.merge(file, found, "", "", @today)
  end

  test "the Router's lines stay wherever the Router wrote them, and Comma's entries round-trip" do
    note = """
    # Team names
    - 陶伟 → zanwei

    <!-- comma:glossary: x. since=10 people=20 -->
    - → Monoid（name 2026-11-02）
    - 金飞 → Jimmfly
    <!-- /comma:glossary -->

    Owner's note.
    """

    file = MemberGlossary.split(note)
    assert file.since == 10
    assert file.kept == ["- 金飞 → Jimmfly"]

    written = MemberGlossary.render(file, file.entries, %{since: 11, people: "21"})
    assert written =~ "Owner's note."
    assert {"金飞", "Jimmfly"} in MeetingGlossary.parse(written)
    assert {"陶伟", "zanwei"} in MeetingGlossary.parse(written)
    assert "Monoid" in MeetingGlossary.terms(written)
    assert %{since: 11, entries: [%{"right" => "Monoid"}]} = MemberGlossary.split(written)
  end

  test "a section that lost its end marker ends at its first line that is not an entry" do
    note = """
    <!-- comma:glossary: x. since=10 people=20 -->
    - → Monoid（name 2026-11-02）
    Owner's note after the section.
    - 金飞 → Jimmfly
    """

    file = MemberGlossary.split(note)
    written = MemberGlossary.render(file, file.entries, %{since: 10, people: "20"})
    assert written =~ "Owner's note after the section."
    assert {"金飞", "Jimmfly"} in MeetingGlossary.parse(written)
  end

  test "new messages are read oldest first up to the budget, and the next day starts after them" do
    # 7,500 bytes each: two fit in a refresh, the third waits.
    big = String.duplicate("字", 2_500)
    tasks = [%{"task" => "cnv1_a", "messages" => [%{"at" => 1, "text" => big}]}]
    home = [%{"at" => 2, "text" => big}, %{"at" => 3, "text" => big <> "Monoid"}]

    assert {%{"tasks" => [%{"task" => "cnv1_a"}], "home" => [^big]}, 2, true} =
             MemberGlossary.material(tasks, home, 99)

    assert {%{"tasks" => [], "home" => [_]}, 99, false} =
             MemberGlossary.material([], tl(home), 99)
  end
end
