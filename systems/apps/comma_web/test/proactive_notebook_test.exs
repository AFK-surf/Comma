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

    waiting = section(notebook, "Waiting and in progress")
    assert waiting =~ "[task](https://example.com/task) — in a Task"
    assert waiting =~ "[undecided](https://example.com/undecided) — important"

    quiet = section(notebook, "Did not interrupt you")
    assert quiet =~ "[quiet](https://example.com/quiet) — stayed quiet: Milo owns it"
    assert quiet =~ "[newsletter](https://example.com/n) — rated low, left for the daily briefing"
    refute quiet =~ "routed"

    assert section(notebook, "Recently done") =~ "[done]"
    refute notebook =~ "[old]"

    watching = section(notebook, "Watching")
    assert watching =~ "Watch: PR #12 merges — active"
    # Read times show the owner's hour, so each collection does not rewrite the file.
    assert watching =~ "Source: Gmail — last read around 09-30 14:00"
    assert watching =~ "Source: Slack — the last read failed"
  end
end
