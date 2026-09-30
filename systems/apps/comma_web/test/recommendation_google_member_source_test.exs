defmodule CommaWeb.RecommendationGoogleMemberSourceTest do
  use ExUnit.Case, async: true
  alias CommaWeb.RecommendationGoogleMemberSource, as: Source

  @gmail "https://gmail.googleapis.com/gmail/v1/users/me"
  @calendar "https://www.googleapis.com/calendar/v3/calendars/primary"
  @drive "https://www.googleapis.com/drive/v3"

  # Answers official API requests by URL path; the query string is passed along.
  defp request(routes) do
    fn "GET", url, _opts ->
      uri = URI.parse(url)
      base = %URI{uri | query: nil} |> URI.to_string()
      query = URI.decode_query(uri.query || "")

      case Enum.find(routes, fn {path, _} -> path == base end) do
        {_, answer} when is_function(answer, 1) -> answer.(query)
        {_, answer} -> answer
        nil -> flunk("unexpected request #{url}")
      end
    end
  end

  defp mail(id, at, labels, body) do
    %{
      "id" => id,
      "internalDate" => Integer.to_string(at),
      "labelIds" => labels,
      "snippet" => body && String.slice(body, 0, 40),
      "payload" => %{
        "mimeType" => "text/plain",
        "headers" => [
          %{"name" => "From", "value" => "Lead <lead@example.com>"},
          %{"name" => "Subject", "value" => "Please review"}
        ],
        "body" => %{"data" => Base.url_encode64(body || "", padding: false)}
      }
    }
  end

  defp thread(id, messages), do: {:ok, %{"id" => id, "messages" => messages}}

  test "Gmail keeps important mail to the member until the member replies in its thread" do
    routes = [
      {@gmail <> "/profile", {:ok, %{"emailAddress" => "member@example.com"}}},
      {@gmail <> "/threads",
       fn query ->
         assert query["q"] =~ "to:me"
         refute query["q"] =~ "is:unread"

         {:ok, %{"threads" => Enum.map(~w(open answered reopened promo), &%{"id" => &1})}}
       end},
      {@gmail <> "/threads/open",
       thread("open", [
         mail("m1", 1_000, ~w(INBOX IMPORTANT), "Your approval is needed before Friday.")
       ])},
      {@gmail <> "/threads/answered",
       thread("answered", [
         mail("m2", 1_000, ~w(INBOX IMPORTANT), "Can you confirm?"),
         mail("m3", 2_000, ~w(SENT), "Confirmed.")
       ])},
      {@gmail <> "/threads/reopened",
       thread("reopened", [
         mail("m4", 1_000, ~w(INBOX IMPORTANT), "First question"),
         mail("m5", 2_000, ~w(SENT), "Answered."),
         mail("m6", 3_000, ~w(INBOX UNREAD IMPORTANT), "One more question about the launch.")
       ])},
      {@gmail <> "/threads/promo",
       thread("promo", [mail("m7", 1_000, ~w(INBOX CATEGORY_PROMOTIONS), "Sale")])}
    ]

    assert {:ok, %{"messages" => messages, "memberRelation" => "awaiting_your_reply"},
            %{"provider_mailbox" => "member@example.com"}} =
             Source.read("gmail", request(routes), DateTime.utc_now())

    # Read but unanswered mail stays; a reply closes the thread until someone writes again.
    assert Enum.map(messages, & &1["messageId"]) == ["m1", "m6"]
    assert hd(messages)["context"]["text"] =~ "Your approval is needed before Friday."
    assert hd(messages)["sender"] == "Lead <lead@example.com>"
    assert hd(messages)["messageTimestamp"] == "1970-01-01T00:00:01.000Z"
  end

  test "Gmail distinguishes absent request context from genuinely empty mail" do
    read = fn threads ->
      routes =
        [
          {@gmail <> "/profile", {:ok, %{"emailAddress" => "member@example.com"}}},
          {@gmail <> "/threads",
           {:ok,
            if(threads == [],
              do: %{},
              else: %{"threads" => Enum.map(threads, &%{"id" => elem(&1, 0)})}
            )}}
        ] ++ Enum.map(threads, fn {id, answer} -> {@gmail <> "/threads/" <> id, answer} end)

      Source.read("gmail", request(routes), DateTime.utc_now())
    end

    blank = thread("blank", [mail("m1", 1_000, ~w(INBOX IMPORTANT), nil)])

    readable =
      thread("readable", [mail("m2", 1_000, ~w(INBOX IMPORTANT), "Please approve the release")])

    assert {:error, :member_source_context_unavailable} = read.([{"blank", blank}])

    assert {:error, :member_source_context_unavailable} =
             read.([{"broken", {:error, {:member_provider_http, 500}}}])

    assert {:ok, %{"messages" => [%{"messageId" => "m2"}]} = partial, _} =
             read.([{"readable", readable}, {"blank", blank}])

    assert partial.source_warnings == [:member_source_context_unavailable]
    assert {:ok, %{"messages" => []}, _} = read.([])

    long =
      thread("long", [
        mail("m3", 1_000, ~w(INBOX IMPORTANT), String.duplicate("Approve release. ", 1000))
      ])

    assert {:ok, %{"messages" => [item]}, _} = read.([{"long", long}])
    assert byte_size(item["context"]["text"]) <= 1200
    assert item["context"]["truncated"]
  end

  test "Calendar keeps the coming week's self attendance and excludes declined, cancelled, and unrelated events" do
    event = %{
      "id" => "e1",
      "status" => "confirmed",
      "htmlLink" => "https://calendar.google.com/event/e1",
      "attendees" => [%{"self" => true, "responseStatus" => "accepted"}]
    }

    routes = [
      {@calendar, {:ok, %{"id" => "member@example.com"}}},
      {@calendar <> "/events",
       fn query ->
         assert query["maxResults"] == "40"
         {:ok, from, _} = DateTime.from_iso8601(query["timeMin"])
         {:ok, to, _} = DateTime.from_iso8601(query["timeMax"])
         assert DateTime.diff(to, from) == 7 * 86_400

         {:ok,
          %{
            "items" => [
              event,
              Map.put(event, "status", "cancelled"),
              Map.put(event, "attendees", [%{"self" => true, "responseStatus" => "declined"}]),
              Map.put(event, "attendees", [])
            ]
          }}
       end}
    ]

    assert {:ok, %{"items" => [%{"id" => "e1"}]},
            %{"provider_calendar_id" => "member@example.com"}} =
             Source.read("googlecalendar", request(routes), DateTime.utc_now())
  end

  test "Drive requires verified ownership, not mere visibility or sharing" do
    file = %{
      "id" => "d1",
      "webViewLink" => "https://drive.google.com/open?id=d1",
      "owners" => [%{"permissionId" => "owner"}]
    }

    routes = [
      {@drive <> "/about", {:ok, %{"user" => %{"permissionId" => "owner"}}}},
      {@drive <> "/files",
       fn query ->
         if query["q"] =~ "'me' in owners" do
           assert query["fields"] ==
                    "files(id,name,webViewLink,modifiedTime,owners(permissionId),trashed,description)"

           {:ok,
            %{
              "files" => [
                file,
                Map.put(file, "owners", [%{"permissionId" => "someone-else"}]),
                Map.put(file, "trashed", true)
              ]
            }}
         else
           {:ok, %{"files" => []}}
         end
       end}
    ]

    assert {:ok, %{"files" => [%{"id" => "d1"}]}, _} =
             Source.read("googledrive", request(routes), DateTime.utc_now())

    assert {:error, :denied} =
             Source.read("googledrive", fn _, _, _ -> {:error, :denied} end, DateTime.utc_now())
  end

  test "Drive adds open comments by others that mention the member" do
    comment = fn id, content, extra ->
      Map.merge(%{"id" => id, "content" => content, "author" => %{"me" => false}}, extra)
    end

    routes = [
      {@drive <> "/about",
       {:ok, %{"user" => %{"permissionId" => "owner", "emailAddress" => "Member@Example.com"}}}},
      {@drive <> "/files",
       fn query ->
         if query["q"] =~ "'me' in owners" do
           {:ok, %{"files" => []}}
         else
           assert query["pageSize"] == "5"

           {:ok,
            %{
              "files" => [
                %{
                  "id" => "plan",
                  "name" => "Launch plan",
                  "webViewLink" => "https://docs.google.com/document/d/plan/edit?usp=drivesdk"
                },
                %{
                  "id" => "gone",
                  "name" => "Gone",
                  "webViewLink" => "https://drive.google.com/gone"
                }
              ]
            }}
         end
       end},
      {@drive <> "/files/plan/comments",
       fn query ->
         assert is_binary(query["startModifiedTime"])
         assert query["fields"] =~ "comments("

         {:ok,
          %{
            "comments" => [
              comment.("c1", "+member@example.com can you check the rollout dates?", %{}),
              comment.("c2", "+member@example.com old question", %{"resolved" => true}),
              comment.("c3", "Note to self +member@example.com", %{"author" => %{"me" => true}}),
              comment.("c4", "Unrelated comment", %{})
            ]
          }}
       end},
      {@drive <> "/files/gone/comments", {:error, {:member_provider_http, 404}}}
    ]

    assert {:ok, %{"files" => [mention]}, _} =
             Source.read("googledrive", request(routes), DateTime.utc_now())

    assert mention["memberRelation"] == "mentioned_you"
    assert mention["name"] == "Launch plan"

    assert mention["webViewLink"] ==
             "https://docs.google.com/document/d/plan/edit?usp=drivesdk&disco=c1"

    assert mention["context"]["text"] =~ "can you check the rollout dates?"
  end
end
