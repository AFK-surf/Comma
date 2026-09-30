defmodule SalixCalendar.OccurrenceQualificationTest do
  use ExUnit.Case, async: true

  alias SalixCalendar.OccurrenceQualification

  @master_meet "https://meet.google.com/master-room"
  @exception_meet "https://meet.google.com/exception-room"

  test "master and exception conference matrix uses the occurrence-effective Google Meet URL" do
    cases = [
      {"master Meet inherited", locations(@master_meet), nil, true, @master_meet, :google_meet},
      {"master Meet removed", locations(@master_meet), %{}, false, nil, :no_supported_conference},
      {"master Meet replaced by unsupported conference", locations(@master_meet),
       locations("https://video.example.test/room"), false, nil, :unsupported_conference},
      {"master Meet replaced by another Meet", locations(@master_meet),
       locations(@exception_meet), true, @exception_meet, :google_meet},
      {"master has no room and occurrence inherits", %{}, nil, false, nil,
       :no_supported_conference},
      {"master has no room and exception adds Meet", %{}, locations(@exception_meet), true,
       @exception_meet, :google_meet}
    ]

    for {label, master_locations, effective_locations, authorized, meet_url, reason} <- cases do
      result =
        master_locations
        |> item()
        |> OccurrenceQualification.evaluate(occurrence(effective_locations))

      assert result.authorized == authorized, label
      assert result.meet_url == meet_url, label
      assert result.reason == reason, label
    end
  end

  test "independent item denials override every master and exception conference combination" do
    conference_cases = [
      {locations(@master_meet), nil},
      {locations(@master_meet), %{}},
      {locations(@master_meet), locations("https://video.example.test/room")},
      {locations(@master_meet), locations(@exception_meet)},
      {%{}, nil},
      {%{}, locations(@exception_meet)}
    ]

    for {master_locations, effective_locations} <- conference_cases do
      base = item(master_locations)
      occurrence = occurrence(effective_locations)

      assert %{authorized: false, reason: :free_busy_only} =
               base
               |> put_in(["object", "freeBusyStatus"], "free")
               |> OccurrenceQualification.evaluate(occurrence)

      assert %{authorized: false, reason: :all_day_event} =
               base
               |> put_in(["object", "showWithoutTime"], true)
               |> OccurrenceQualification.evaluate(occurrence)

      assert %{authorized: false, reason: :access_profile_restricted} =
               base
               |> put_in(["meeting_qualification"], %{
                 "item_eligible" => false,
                 "item_reason" => "access_profile_restricted",
                 "authorized" => false,
                 "reason" => "access_profile_restricted"
               })
               |> OccurrenceQualification.evaluate(occurrence)
    end
  end

  test "legacy conference-only reasons remain compatible without reviving restricted items" do
    exception = occurrence(locations(@exception_meet))

    assert %{authorized: true, meet_url: @exception_meet} =
             %{}
             |> item()
             |> put_in(["meeting_qualification"], %{
               "authorized" => false,
               "reason" => "no_supported_conference"
             })
             |> OccurrenceQualification.evaluate(exception)

    assert %{authorized: false, reason: :access_profile_restricted} =
             %{}
             |> item()
             |> put_in(["meeting_qualification"], %{
               "authorized" => false,
               "reason" => "access_profile_restricted"
             })
             |> OccurrenceQualification.evaluate(exception)
  end

  test "URI-aware Meet redaction matches the eligibility host contract" do
    explicit_port = "https://meet.google.com:443/abc-defg-hij"
    unrelated = "https://video.example.test/room"
    unrelated_first = "https://docs.example.test/brief"

    assert OccurrenceQualification.google_meet_url?(explicit_port)

    assert OccurrenceQualification.redact_google_meet_urls(
             "Join #{explicit_port}; fallback #{unrelated}"
           ) == "Join [REDACTED_GOOGLE_MEET_URL] fallback #{unrelated}"

    assert OccurrenceQualification.redact_google_meet_urls(
             "Agenda #{unrelated_first},Meet:#{explicit_port}"
           ) == "Agenda #{unrelated_first},Meet:[REDACTED_GOOGLE_MEET_URL]"

    assert OccurrenceQualification.redact_google_meet_urls(
             "Agenda #{unrelated_first};Meet:https://guest@meet.google.com/abc-defg-hij"
           ) == "Agenda #{unrelated_first};Meet:[REDACTED_GOOGLE_MEET_URL]"
  end

  defp item(master_locations) do
    %{
      "normalization_state" => "complete",
      "tombstoned_at" => nil,
      "object" => %{
        "@type" => "Event",
        "status" => "confirmed",
        "freeBusyStatus" => "busy",
        "showWithoutTime" => false,
        "virtualLocations" => master_locations
      },
      "meeting_qualification" => %{
        "item_eligible" => true,
        "item_reason" => "eligible",
        "authorized" => master_locations != %{},
        "reason" =>
          if(master_locations == %{}, do: "no_supported_conference", else: "google_meet")
      }
    }
  end

  defp occurrence(nil), do: %{"object_type" => "Event", "effective" => %{}}

  defp occurrence(effective_locations) do
    %{
      "object_type" => "Event",
      "effective" => %{"virtualLocations" => effective_locations}
    }
  end

  defp locations(url) do
    %{"conference" => %{"@type" => "VirtualLocation", "uri" => url}}
  end
end
