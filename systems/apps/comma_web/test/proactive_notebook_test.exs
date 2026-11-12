defmodule CommaWeb.ProactiveNotebookTest do
  use SystemsClock.Case, async: true
  alias Comma.Data.{MemberSourceItem, MemberSourceState}
  alias CommaWeb.ProactiveNotebook

  @now 1_790_750_000_000
  @hour 60 * 60 * 1000

  defp facts(overrides) do
    Map.merge(
      %{
        now: @now,
        locale: nil,
        timezone: "Asia/Shanghai",
        automatic: true,
        notifications: {:open, 5},
        urgent: {:open, 5},
        matters: [],
        monitors: [],
        sources: [],
        judged: [],
        briefing: nil
      },
      overrides
    )
  end

  defp matter(subject, attrs),
    do:
      Map.merge(
        %{
          "subject" => subject,
          "source_url" => "https://example.com/" <> subject,
          "state" => "active",
          "changed_at" => @now - @hour
        },
        attrs
      )

  defp section(notebook, heading) do
    notebook
    |> String.split("\n## ")
    |> Enum.find_value("", fn part ->
      if String.starts_with?(part, heading), do: part
    end)
  end

  test "each matter lands where the owner looks for it, with Comma's reason" do
    notebook =
      ProactiveNotebook.render(
        facts(%{
          matters: [
            # A reminder the owner asked for came due.
            matter("due", %{"last_command" => %{"action" => "present"}}),
            # An automatic handoff the Router has not decided on yet.
            matter("undecided", %{
              "automatic" => true,
              "urgency" => "high",
              "last_command" => %{"action" => "present"}
            }),
            matter("later", %{
              "state" => "snoozed",
              "run_at" => @now + 2 * @hour,
              "followup_reason" => "before the\nreview"
            }),
            matter("task", %{"task_id" => "conv_1"}),
            matter("quiet", %{
              "state" => "quiet",
              "decision" => %{"decision" => "quiet", "reason" => "Milo owns it"}
            }),
            matter("done", %{"state" => "handled"}),
            matter("old", %{"state" => "handled", "changed_at" => @now - 8 * 24 * @hour})
          ],
          judged: [
            %MemberSourceItem{
              title: "newsletter",
              url: "https://example.com/n",
              attention: %{"outcome" => "quiet", "urgency" => "low", "at" => @now}
            },
            %MemberSourceItem{
              title: "routed",
              url: "https://example.com/r",
              attention: %{"outcome" => "routed", "urgency" => "high", "at" => @now}
            },
            %MemberSourceItem{
              title: "slides",
              url: "https://example.com/s",
              attention: %{
                "outcome" => "deferred",
                "role" => "act",
                "urgency" => "high",
                "reason" => "notification_budget",
                "next_at" => @now + @hour,
                "at" => @now
              }
            },
            %MemberSourceItem{
              title: "notes",
              url: "https://example.com/notes",
              attention: %{
                "outcome" => "quiet",
                "role" => "act",
                "urgency" => "normal",
                "at" => @now
              }
            },
            %MemberSourceItem{
              title: "own pr",
              url: "https://example.com/pr",
              attention: %{
                "outcome" => "waiting",
                "role" => "waiting",
                "urgency" => "normal",
                "at" => @now
              }
            },
            %MemberSourceItem{
              title: "unanswerable",
              url: "https://example.com/u",
              attention: %{
                "outcome" => "retry",
                "failures" => 3,
                "isolated" => true,
                "at" => @now
              }
            },
            %MemberSourceItem{
              title: "teammate pr",
              url: "https://example.com/tpr",
              attention: %{
                "outcome" => "quiet",
                "role" => "reference",
                "urgency" => "low",
                "at" => @now
              }
            }
          ],
          sources: [
            %MemberSourceState{
              app: "Gmail",
              toolkit: "gmail",
              failure: nil,
              collected_at: ~U[2026-09-30 06:47:00Z],
              attempted_at: ~U[2026-09-30 06:47:00Z]
            },
            %MemberSourceState{
              app: "Slack",
              toolkit: "slack",
              failure: %{"reason" => "unauthorized"},
              collected_at: ~U[2026-09-30 05:00:00Z],
              attempted_at: ~U[2026-09-30 06:47:00Z]
            }
          ],
          monitors: [%{"name" => "PR #12 merges", "status" => "active"}]
        })
      )

    assert section(notebook, "Needs you") =~ "[due](https://example.com/due)"
    refute section(notebook, "Needs you") =~ "undecided"

    assert section(notebook, "Coming up") =~
             "[later](https://example.com/later) — checking again 09-30 16:33; before the review"

    # What is the owner's move but did not interrupt them comes up next.
    coming = section(notebook, "Coming up")

    assert coming =~
             "[slides](https://example.com/s) — important; no automatic messages left for now, checking again "

    assert coming =~ "[notes](https://example.com/notes)\n"

    waiting = section(notebook, "Waiting and in progress")
    assert waiting =~ "[own pr](https://example.com/pr) — waiting on someone else"
    assert waiting =~ "[task](https://example.com/task) — in a Task"
    assert waiting =~ "[undecided](https://example.com/undecided) — important"

    quiet = section(notebook, "Did not interrupt you")
    assert quiet =~ "[quiet](https://example.com/quiet) — stayed quiet: Milo owns it"
    assert quiet =~ "[newsletter](https://example.com/n) — rated low, left for the daily briefing"
    refute quiet =~ "routed"
    refute quiet =~ "notes"
    assert quiet =~ "[teammate pr](https://example.com/tpr) — information or someone else's work"

    assert quiet =~
             "[unanswerable](https://example.com/u) — the model could not judge this one yet"

    assert section(notebook, "Recently done") =~ "[done]"
    refute notebook =~ "[old]"

    watching = section(notebook, "Watching")
    assert watching =~ "Watch: PR #12 merges — active"
    # Read times show the owner's hour, so each collection does not rewrite the file.
    assert watching =~ "Source: Gmail — last read around 09-30 14:00"
    assert watching =~ "Source: Slack — the last read failed"
  end

  test "open threads show five by priority and count the rest" do
    at = fn days -> DateTime.from_unix!(@now - days * 24 * @hour, :millisecond) end

    thread = fn summary, attrs ->
      struct(
        Comma.Data.OpenThread,
        Map.merge(
          %{
            summary: summary,
            url: "https://team.slack.com/archives/C1/p" <> summary,
            kind: "asked",
            status: "open",
            evidence_at: at.(1)
          },
          attrs
        )
      )
    end

    asked = for n <- 1..4, do: thread.("asked#{n}", %{evidence_at: at.(n)})

    notebook =
      ProactiveNotebook.render(
        facts(%{
          open_threads:
            asked ++
              [
                thread.("promise", %{kind: "promised", counterpart: "Lena", evidence_at: at.(9)}),
                thread.("dated", %{due_on: ~D[2026-10-02], evidence_at: at.(20)}),
                thread.("dismissed", %{status: "dismissed"})
              ]
        })
      )

    open = section(notebook, "What you may have left open")
    # A due date first, then a promise, then the newest questions.
    assert open =~
             ~r/dated.*by 10-02\n.*promise.*you promised; with Lena\n.*asked1.*\n.*asked2.*\n.*asked3/s

    refute open =~ "asked4"
    assert open =~ "1 more not listed"
    refute notebook =~ "dismissed"
  end

  test "proactive.state lists every open thread the notebook counts, then the latest resolved" do
    threads =
      for n <- 1..20,
          do: %Comma.Data.OpenThread{
            id: "o#{n}",
            kind: "asked",
            status: "open",
            summary: "o#{n}",
            url: "u"
          }

    resolved =
      for n <- 1..15,
          do: %Comma.Data.OpenThread{
            id: "r#{n}",
            kind: "asked",
            status: "resolved",
            summary: "r#{n}",
            url: "u"
          }

    dismissed = [
      %Comma.Data.OpenThread{id: "d", kind: "asked", status: "dismissed", summary: "d", url: "u"}
    ]

    rows = ProactiveNotebook.open_thread_rows(resolved ++ threads ++ dismissed)

    assert Enum.count(rows, &(&1["status"] == "open")) == 20
    assert Enum.count(rows, &(&1["status"] == "resolved")) == 12
    refute Enum.any?(rows, &(&1["id"] == "d"))
  end
end
