defmodule CommaWeb.RecommendationOutlookMemberSourceTest do
  use SystemsClock.Case, async: true
  alias CommaWeb.RecommendationOutlookMemberSource, as: Source

  defp read(mail, events, profile \\ {:ok, %{"id" => "user-1", "mail" => "me@example.com"}}) do
    request = fn "GET", url, opts ->
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")

      case uri.path do
        "/v1.0/me" ->
          profile

        "/v1.0/me/mailFolders/inbox/messages" ->
          # Text bodies, so the message's own text replaces the short preview.
          assert query["$select"] =~ "uniqueBody"

          assert [%{"name" => "Prefer", "value" => ~s(outlook.body-content-type="text")}] =
                   opts[:parameters]

          assert query["$top"] == "40"
          assert query["$filter"] =~ "receivedDateTime ge"
          assert query["$orderby"] == "receivedDateTime desc"
          refute query["$filter"] =~ "importance"
          mail

        "/v1.0/me/calendarView" ->
          assert query["$top"] == "40"
          events
      end
    end

    Source.read(request, ~U[2026-10-03 12:00:00Z])
  end

  test "bounded mail and calendar, deduplicated by conversation/event and tied to self" do
    mail = fn id, thread ->
      %{
        "id" => id,
        "conversationId" => thread,
        "webLink" => "https://outlook.office.com/mail/#{id}",
        "subject" => "Review",
        "receivedDateTime" => "2026-10-03T11:00:00Z",
        "from" => %{"emailAddress" => %{"address" => "person@example.com"}},
        "bodyPreview" => "Please review"
      }
    end

    event = fn id, address ->
      %{
        "id" => id,
        "webLink" => "https://outlook.office.com/calendar/#{id}",
        "subject" => "Discuss",
        "organizer" => %{"emailAddress" => %{"address" => address}}
      }
    end

    assert {:ok, data, %{"provider_user_id" => "user-1"}} =
             read(
               {:ok, %{"value" => [mail.("m1", "t1"), mail.("m2", "t1"), mail.("m3", "t2")]}},
               {:ok,
                %{
                  "value" => [
                    event.("e1", "me@example.com"),
                    event.("e1", "me@example.com"),
                    event.("e2", "other@example.com")
                  ]
                }}
             )

    assert Enum.map(data["messages"], & &1["messageId"]) == ~w(m1 m3)
    assert length(data["items"]) == 1
    assert hd(data["messages"])["context"]["text"] =~ "Please review"
    refute Map.has_key?(data, :source_warnings)
  end

  test "collected Outlook mail and events become member candidates" do
    assert {:ok, data, subject} =
             read(
               {:ok,
                %{
                  "value" => [
                    %{
                      "id" => "m1",
                      "conversationId" => "t1",
                      "webLink" => "https://outlook.office.com/mail/m1",
                      "subject" => "Review the contract",
                      "receivedDateTime" => "2026-10-03T11:00:00Z"
                    }
                  ]
                }},
               {:ok,
                %{
                  "value" => [
                    %{
                      "id" => "e1",
                      "webLink" => "https://outlook.office.com/calendar/e1",
                      "subject" => "Contract sync",
                      "organizer" => %{"emailAddress" => %{"address" => "me@example.com"}}
                    }
                  ]
                }}
             )

    fact = %{
      "sourceId" => "ca_outlook",
      "toolkit" => "outlook",
      "appName" => "Outlook",
      "memberSubject" => subject,
      "data" => data
    }

    context =
      Comma.RecommendationDraft.prepare(
        [fact],
        Comma.Recommendations.source_evidence([fact]),
        "member"
      )

    assert context
           |> Comma.RecommendationMemberSelection.candidates()
           |> Enum.map(&{&1["title"], &1["url"]})
           |> Enum.sort() == [
             {"Contract sync", "https://outlook.office.com/calendar/e1"},
             {"Review the contract", "https://outlook.office.com/mail/m1"}
           ]

    # The mail Task and Routine paths find the message identity by its URL.
    assert [%{"threadId" => "t1", "messageId" => "m1"}] = data["messages"]
  end

  test "a message's own text reaches the judgment beyond the preview" do
    mail = %{
      "id" => "m1",
      "conversationId" => "t1",
      "webLink" => "https://outlook.office.com/mail/m1",
      "subject" => "Final reminder: Your account will be deleted soon",
      "receivedDateTime" => "2026-10-03T11:00:00Z",
      "bodyPreview" => "Your account is scheduled for deletion in a few days",
      "uniqueBody" => %{
        "contentType" => "text",
        "content" =>
          "Your account is scheduled for deletion in a few days\r\n\r\n" <>
            "Sign in within the next 3 days, or your account and vault are permanently deleted."
      }
    }

    assert {:ok, %{"messages" => [message]}, _} =
             read({:ok, %{"value" => [mail]}}, {:ok, %{"value" => []}})

    assert message["context"]["text"] =~
             "Sign in within the next 3 days, or your account and vault are permanently deleted."
  end

  test "one unreadable relationship is warned; neither readable is not empty success" do
    assert {:ok, data, _} = read({:error, {:member_provider_http, 403}}, {:ok, %{"value" => []}})
    assert data[:source_warnings] == [{:member_provider_http, 403}]

    assert {:error, :member_source_context_unavailable} =
             read({:error, :denied}, {:error, :denied})
  end

  test "identity is required and unrelated URL cannot enter facts" do
    item = %{
      "id" => "m1",
      "conversationId" => "c1",
      "webLink" => "https://outlook.evil.example/mail",
      "receivedDateTime" => "2026-10-03T11:00:00Z"
    }

    assert {:ok, %{"messages" => []}, _} =
             read({:ok, %{"value" => [item]}}, {:ok, %{"value" => []}})

    assert {:error, :invalid_provider_response} =
             read(
               {:ok, %{"value" => []}},
               {:ok, %{"value" => []}},
               {:ok, %{"mail" => "me@example.com"}}
             )
  end
end
