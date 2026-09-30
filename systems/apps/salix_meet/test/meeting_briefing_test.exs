defmodule SalixMeet.MeetingBriefingTest do
  use ExUnit.Case, async: true

  alias SalixMeet.MeetingBriefing

  @start_ms DateTime.to_unix(~U[2026-08-18 02:00:00Z], :millisecond)
  @end_ms DateTime.to_unix(~U[2026-08-18 02:30:00Z], :millisecond)

  test "renders bounded attendee-facing meeting facts and research state without protocol JSON" do
    briefing =
      MeetingBriefing.render(
        context(),
        %{
          "scope" => "Prepare an evidence-backed briefing for the all-hands.",
          "known_facts" => [
            "Company-level progress is on the agenda.",
            "Product progress is on the agenda."
          ],
          "gaps" => ["Current-week metrics are not in the meeting context."]
        }
      )

    assert briefing ==
             """
             📅 AFK All-Hands Meeting
             2026-08-18 10:00–10:30 (Asia/Shanghai)
             [Open event](<https://www.google.com/calendar/event?eid=all-hands>) · [Join Meet](<https://meet.google.com/abc-defg-hij>)

             Scope: Prepare an evidence-backed briefing for the all-hands.

             Known facts
             • Company-level progress is on the agenda.
             • Product progress is on the agenda.

             Still to verify
             • Current-week metrics are not in the meeting context.

             This briefing reflects the evidence available at publication time; unverified details remain provisional.
             """
             |> String.trim()

    refute briefing =~ "{"
    refute briefing =~ ~s("known_facts")
  end

  test "uses the occurrence-effective Meet URL and omits unsafe presentation links" do
    context =
      context()
      |> put_in(
        ["calendar_item", "object", "links", "event", "href"],
        "https://user@www.google.com/calendar/event?eid=unsafe"
      )
      |> put_in(
        ["calendar_item", "object", "virtualLocations", "conference", "uri"],
        "https://meet.google.com/series-room"
      )
      |> put_in(
        [
          "effective_occurrence",
          "effective",
          "virtualLocations",
          "conference",
          "uri"
        ],
        "https://meet.google.com/occurrence-room"
      )

    briefing = MeetingBriefing.render(context, %{})

    refute briefing =~ "[Open event]"
    assert briefing =~ "[Join Meet](<https://meet.google.com/occurrence-room>)"
    refute briefing =~ "series-room"
  end

  test "omits a non-Google-Meet conference URL" do
    context =
      put_in(
        context(),
        ["effective_occurrence", "effective", "virtualLocations", "conference", "uri"],
        "https://video.example.test/occurrence-room"
      )

    briefing = MeetingBriefing.render(context, %{})

    refute briefing =~ "[Join Meet]"
    refute briefing =~ "video.example.test"
  end

  test "unknown baseline shapes degrade to readable pending text and untrusted text cannot inject mentions" do
    context =
      context()
      |> put_in(
        ["calendar_item", "object", "title"],
        "Roadmap\n<!here> <@U123>"
      )

    briefing =
      MeetingBriefing.render(context, %{
        "known_facts" => [%{"internal" => "do not dump"}],
        "gaps" => [%{"nested" => true}]
      })

    assert briefing =~ "📅 Roadmap ‹!here› ‹@U123›"
    assert briefing =~ "No verified research findings were available before this briefing."
    refute briefing =~ "<!here>"
    refute briefing =~ "<@U123>"
    refute briefing =~ "internal"
    refute briefing =~ "nested"
    refute briefing =~ "{"
  end

  defp context do
    %{
      "calendar_item" => %{
        "object" => %{
          "@type" => "Event",
          "title" => "AFK All-Hands Meeting",
          "links" => %{
            "event" => %{
              "@type" => "Link",
              "href" => "https://www.google.com/calendar/event?eid=all-hands",
              "rel" => "alternate"
            }
          },
          "virtualLocations" => %{
            "conference" => %{
              "@type" => "VirtualLocation",
              "uri" => "https://meet.google.com/abc-defg-hij"
            }
          }
        }
      },
      "effective_occurrence" => %{
        "start_ms" => @start_ms,
        "end_ms" => @end_ms,
        "effective" => %{
          "timeZone" => "Asia/Shanghai",
          "virtualLocations" => %{
            "conference" => %{
              "@type" => "VirtualLocation",
              "uri" => "https://meet.google.com/abc-defg-hij"
            }
          }
        }
      }
    }
  end
end
