defmodule SalixCalendar.OccurrenceQualificationTest do
  use SystemsClock.Case, async: true

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

  test "every recognized meeting link qualifies on any item; look-alike links do not" do
    qualified = [
      {"https://meet.google.com/abc-defg-hij", :google_meet},
      {"https://vc.feishu.cn/j/123456789", :lark_meeting},
      {"https://vc-sg.larksuite.com/j/123456789", :lark_meeting},
      {"https://VC.LarkOffice.com/j/123456789", :lark_meeting},
      {"https://us02web.zoom.us/j/81234567890?pwd=abc", :zoom_meeting},
      {"https://zoom.us/my/team", :zoom_meeting},
      {"https://acme.zoom.com/s/81234567890", :zoom_meeting},
      {"https://zoom.us/wc/join/81234567890", :zoom_meeting},
      {"https://teams.microsoft.com/meet/2345678901234?p=abc", :teams_meeting},
      {"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0", :teams_meeting},
      {"https://teams.live.com/meet/9312345678901", :teams_meeting}
    ]

    for {url, reason} <- qualified do
      item = item(locations(url))
      result = OccurrenceQualification.evaluate(item, occurrence(nil))

      assert %{authorized: true, reason: ^reason} = result, url
      assert result.meet_url == String.replace(url, "VC.LarkOffice.com", "vc.larkoffice.com")
      assert OccurrenceQualification.may_qualify?(item), url
    end

    unsupported = [
      "https://zoom.us.evil.test/j/1",
      "https://evilzoom.us/j/1",
      "https://zoom.us@evil.test/j/1",
      "https://guest@zoom.us/j/1",
      "http://zoom.us/j/1",
      "https://zoom.us:8443/j/1",
      "https://teams.microsoft.com.evil.test/l/meetup-join/1",
      "https://vc.feishu.cn.example.test/j/1",
      "https://vcx.feishu.cn/j/1",
      # A recognized host without a meeting path is no meeting.
      "https://zoom.us/download",
      "https://zoom.com/pricing",
      "https://us02web.zoom.us/j/",
      "https://teams.microsoft.com/l/channel/19%3aabc%40thread.tacv2/General",
      "https://teams.live.com/",
      "https://vc.feishu.cn/",
      "https://vc.larksuite.com/j/abc",
      "https://video.example.test/room"
    ]

    for url <- unsupported do
      assert %{authorized: false, meet_url: nil, reason: :unsupported_conference} =
               OccurrenceQualification.evaluate(item(locations(url)), occurrence(nil)),
             url

      refute OccurrenceQualification.may_qualify?(item(locations(url))), url
    end
  end

  test "a meeting link in free text is found in HTML, but a Google Meet link there is not" do
    meet = "https://meet.google.com/abc-defg-hij"

    html =
      ~s(<p>Agenda: https://docs.example.test/brief. Dial in: #{meet}</p>) <>
        ~s(<a href="https://www.google.com/url?q=https://us02web.zoom.us/j/812?pwd=a&amp;b=c&amp;sa=D">) <>
        ~s(Zoom</a> or https://teams.live.com/meet/931&nbsp;)

    assert OccurrenceQualification.text_meeting_url(html) ==
             "https://us02web.zoom.us/j/812?pwd=a&b=c&sa=D"

    assert OccurrenceQualification.text_meeting_url("Join #{meet} or call in.") == nil

    assert OccurrenceQualification.text_meeting_url("会议链接：https://vc-sg.larksuite.com/j/123。谢谢") ==
             "https://vc-sg.larksuite.com/j/123"

    assert OccurrenceQualification.text_meeting_url("Room 4 (https://zoom.us/j/99).") ==
             "https://zoom.us/j/99"

    assert OccurrenceQualification.text_meeting_url(
             "Install https://zoom.us/download first, then https://zoom.us/j/55"
           ) == "https://zoom.us/j/55"

    # Only the first 64 KiB of a description are read.
    assert OccurrenceQualification.text_meeting_url(
             String.duplicate("x", 64 * 1_024) <> " https://zoom.us/j/1"
           ) == nil
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
