defmodule CommaWeb.RecommendationLinkPreviewTest do
  use ExUnit.Case, async: false

  alias CommaWeb.RecommendationLinkPreview

  defmodule Settings do
    def settings(tenant_id), do: {:ok, %{"api_key" => "test", "tenant" => tenant_id}}
  end

  defmodule Client do
    def execute_tool(settings, tool_slug, group_id, arguments, opts) do
      test_pid = Application.fetch_env!(:comma_web, :recommendation_link_preview_test_pid)
      send(test_pid, {:execute, settings, tool_slug, group_id, arguments, opts})
      Application.fetch_env!(:comma_web, :recommendation_link_preview_test_response)
    end

    def create_proxy_session(_settings, group_id, account_id, toolkit, _opts) do
      send(
        Application.fetch_env!(:comma_web, :recommendation_link_preview_test_pid),
        {:proxy_session, group_id, account_id, toolkit}
      )

      Application.get_env(:comma_web, :recommendation_link_preview_test_session, {:ok, "sess-1"})
    end

    def proxy_execute(_settings, session_id, request, _opts) do
      send(
        Application.fetch_env!(:comma_web, :recommendation_link_preview_test_pid),
        {:proxy, session_id, request}
      )

      # Multi-request reads (Slack) queue ordered answers; single-request
      # reads keep the one shared response.
      case Application.get_env(:comma_web, :recommendation_link_preview_test_responses) do
        [next | rest] ->
          Application.put_env(:comma_web, :recommendation_link_preview_test_responses, rest)
          next

        _ ->
          Application.fetch_env!(:comma_web, :recommendation_link_preview_test_response)
      end
    end

    def delete_proxy_session(_settings, session_id) do
      send(
        Application.fetch_env!(:comma_web, :recommendation_link_preview_test_pid),
        {:proxy_closed, session_id}
      )

      :ok
    end
  end

  setup do
    keys = [
      :recommendation_composio_client_mod,
      :recommendation_composio_settings_mod,
      :recommendation_link_preview_test_pid,
      :recommendation_link_preview_test_response,
      :recommendation_link_preview_test_responses,
      :recommendation_link_preview_test_session
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:comma_web, &1)})
    Application.put_env(:comma_web, :recommendation_composio_client_mod, Client)
    Application.put_env(:comma_web, :recommendation_composio_settings_mod, Settings)
    Application.put_env(:comma_web, :recommendation_link_preview_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:comma_web, key)
        {key, value} -> Application.put_env(:comma_web, key, value)
      end)
    end)

    :ok
  end

  describe "GitHub pull requests" do
    test "reads a merged pull request through the link's pinned GitHub account" do
      respond(
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "number" => 845,
             "title" => "feat(chat): add inline task elements",
             "state" => "closed",
             "merged" => true,
             "html_url" => "https://github.com/AFK-surf/Comma/pull/845",
             "user" => %{"login" => "CatsJuice", "avatar_url" => "https://avatars.example/1"},
             "base" => %{"repo" => %{"full_name" => "AFK-surf/Comma"}},
             "additions" => 12_593,
             "deletions" => 829,
             "changed_files" => 147,
             "merged_at" => "2026-08-14T10:00:00Z",
             "updated_at" => "2026-08-15T10:00:00Z"
           }
         }}
      )

      assert {:ok, preview} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("linear", "ca-linear"), source("github", "ca-github")],
                 "https://github.com/AFK-surf/Comma/pull/845/",
                 "ca-github"
               )

      assert preview == %{
               "kind" => "github_pull_request",
               "href" => "https://github.com/AFK-surf/Comma/pull/845",
               "repository" => "AFK-surf/Comma",
               "number" => 845,
               "title" => "feat(chat): add inline task elements",
               "state" => "merged",
               "author" => %{"login" => "CatsJuice", "avatarUrl" => "https://avatars.example/1"},
               "additions" => 12_593,
               "deletions" => 829,
               "changedFiles" => 147,
               "updatedAt" => 1_786_701_600_000
             }

      assert_received {:execute, %{"tenant" => "ten-1"}, "GITHUB_GET_A_PULL_REQUEST", "grp-1",
                       %{"owner" => "AFK-surf", "repo" => "Comma", "pull_number" => 845}, opts}

      assert opts[:connected_account_id] == "ca-github"
      assert opts[:error_mode] == :structured
    end

    test "falls back to an enabled GitHub source when the link carries no sourceId" do
      respond(
        {:ok, %{"successful" => true, "data" => %{"title" => "Open PR", "state" => "open"}}}
      )

      assert {:ok, %{"state" => "open", "title" => "Open PR", "author" => nil}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("github", "ca-github")],
                 "https://github.com/AFK-surf/Comma/pull/12",
                 nil
               )

      assert_received {:execute, _settings, _tool, _group, _arguments, opts}
      assert opts[:connected_account_id] == "ca-github"
    end

    test "derives draft and closed states" do
      respond({:ok, %{"successful" => true, "data" => %{"state" => "open", "draft" => true}}})

      assert {:ok, %{"state" => "draft"}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("github", "ca-github")],
                 "https://github.com/AFK-surf/Comma/pull/12",
                 "ca-github"
               )

      respond({:ok, %{"successful" => true, "data" => %{"state" => "closed", "merged" => false}}})

      assert {:ok, %{"state" => "closed"}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("github", "ca-github")],
                 "https://github.com/AFK-surf/Comma/pull/12",
                 "ca-github"
               )
    end
  end

  describe "Linear issues" do
    test "reads the issue by identifier through the pinned Linear account" do
      respond(
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "issue" => %{
               "identifier" => "COMMA-143",
               "title" => "Fix onboarding crash on first launch",
               "url" => "https://linear.app/comma/issue/COMMA-143/fix-onboarding-crash",
               "priority" => 2,
               "priorityLabel" => "High",
               "updatedAt" => "2026-08-22T09:00:00.000Z",
               "state" => %{"name" => "In Progress", "type" => "started", "color" => "#f2c94c"},
               "assignee" => %{
                 "name" => "Zanwei Guo",
                 "displayName" => "zanwei",
                 "avatarUrl" => "https://avatars.example/zanwei"
               },
               "team" => %{"key" => "COMMA"},
               "project" => %{"name" => "Launch"}
             }
           }
         }}
      )

      assert {:ok, preview} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("github", "ca-github"), source("linear", "ca-linear")],
                 "https://linear.app/comma/issue/COMMA-143/fix-onboarding-crash",
                 "ca-linear"
               )

      assert preview == %{
               "kind" => "linear_issue",
               "href" => "https://linear.app/comma/issue/COMMA-143/fix-onboarding-crash",
               "identifier" => "COMMA-143",
               "title" => "Fix onboarding crash on first launch",
               "state" => %{"name" => "In Progress", "type" => "started", "color" => "#f2c94c"},
               "assignee" => %{
                 "name" => "zanwei",
                 "avatarUrl" => "https://avatars.example/zanwei"
               },
               "priority" => 2,
               "priorityLabel" => "High",
               "team" => "COMMA",
               "project" => "Launch",
               "updatedAt" => 1_787_389_200_000
             }

      assert_received {:execute, _settings, "LINEAR_RUN_QUERY_OR_MUTATION", "grp-1",
                       %{"query_or_mutation" => query, "variables" => %{"id" => "COMMA-143"}},
                       opts}

      assert query =~ "issue(id: $id)"
      assert opts[:connected_account_id] == "ca-linear"
    end

    test "accepts the GraphQL data envelope and an unknown issue" do
      respond(
        {:ok,
         %{
           "successful" => true,
           "data" => %{"data" => %{"issue" => %{"identifier" => "COMMA-1", "title" => "Nested"}}}
         }}
      )

      assert {:ok, %{"title" => "Nested", "state" => nil, "assignee" => nil}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("linear", "ca-linear")],
                 "https://linear.app/comma/issue/COMMA-1",
                 "ca-linear"
               )

      respond({:ok, %{"successful" => true, "data" => %{"issue" => nil}}})

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("linear", "ca-linear")],
                 "https://linear.app/comma/issue/COMMA-404",
                 "ca-linear"
               )
    end
  end

  describe "Notion pages" do
    test "reads the page by id and maps its title, icon and parent" do
      respond(
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "row" => %{
               "id" => "4b8e7d0d-9f1a-4ed8-9d6b-a8d11080a812",
               "url" => "https://www.notion.so/Q3-plan-4b8e7d0d9f1a4ed89d6ba8d11080a812",
               "icon" => %{"type" => "emoji", "emoji" => "🗺️"},
               "parent" => %{"type" => "database_id", "database_id" => "db-1"},
               "created_time" => "2026-08-01T08:00:00.000Z",
               "last_edited_time" => "2026-08-22T07:30:00.000Z",
               "properties" => %{
                 "Owner" => %{"type" => "people", "people" => []},
                 "Name" => %{
                   "type" => "title",
                   "title" => [
                     %{"plain_text" => "Q3 "},
                     %{"plain_text" => "plan"}
                   ]
                 }
               }
             }
           }
         }}
      )

      assert {:ok, preview} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("notion", "ca-notion")],
                 "https://www.notion.so/comma/Q3-plan-4b8e7d0d9f1a4ed89d6ba8d11080a812",
                 "ca-notion"
               )

      assert preview == %{
               "kind" => "notion_page",
               "href" => "https://www.notion.so/Q3-plan-4b8e7d0d9f1a4ed89d6ba8d11080a812",
               "title" => "Q3 plan",
               "icon" => "🗺️",
               "parent" => "database",
               "archived" => false,
               "createdAt" => 1_785_571_200_000,
               "updatedAt" => 1_787_383_800_000
             }

      assert_received {:execute, _settings, "NOTION_FETCH_ROW", "grp-1",
                       %{"page_id" => "4b8e7d0d-9f1a-4ed8-9d6b-a8d11080a812"}, opts}

      assert opts[:connected_account_id] == "ca-notion"
    end

    test "titles an untitled page and treats a bare id link as a page" do
      respond(
        {:ok,
         %{
           "successful" => true,
           "data" => %{"properties" => %{"title" => %{"type" => "title", "title" => []}}}
         }}
      )

      assert {:ok, %{"title" => "Untitled", "icon" => nil, "parent" => "workspace"}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("notion", "ca-notion")],
                 "https://notion.so/4b8e7d0d9f1a4ed89d6ba8d11080a812?pvs=4",
                 "ca-notion"
               )
    end
  end

  describe "Google Calendar events" do
    # eid = base64("evt123 zanwei@comma.local")
    @event_href "https://www.google.com/calendar/event?eid=ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA"

    test "reads the exact event by calendar id + event id, never by iCalUID" do
      # An imported event: its iCalUID has nothing to do with its id.
      respond(
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "id" => "evt123",
             "iCalUID" => "imported-7f3a@example.com",
             "status" => "confirmed",
             "visibility" => "public",
             "summary" => "Launch review",
             "location" => "Room 4",
             "htmlLink" => @event_href,
             "hangoutLink" => "https://meet.google.com/abc-defg-hij",
             "start" => %{"dateTime" => "2026-08-24T09:00:00+08:00"},
             "end" => %{"dateTime" => "2026-08-24T09:45:00+08:00"},
             "organizer" => %{"email" => "dana@comma.local", "displayName" => "Dana Wu"},
             "attendees" => [%{"email" => "a@comma.local"}, %{"email" => "b@comma.local"}],
             "updated" => "2026-08-22T01:00:00.000Z"
           }
         }}
      )

      assert {:ok, preview} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googlecalendar", "ca-calendar")],
                 @event_href,
                 "ca-calendar"
               )

      assert preview == %{
               "kind" => "google_calendar_event",
               "href" => @event_href,
               "title" => "Launch review",
               "status" => "confirmed",
               "allDay" => false,
               "startsAt" => 1_787_533_200_000,
               "endsAt" => 1_787_535_900_000,
               "location" => "Room 4",
               "organizer" => %{"name" => "Dana Wu"},
               "attendeeCount" => 2,
               "meetingUrl" => "https://meet.google.com/abc-defg-hij",
               "updatedAt" => 1_787_360_400_000
             }

      assert_received {:proxy_session, "grp-1", "ca-calendar", "googlecalendar"}
      assert_received {:proxy, "sess-1", %{"method" => "GET", "endpoint" => endpoint}}

      assert endpoint ==
               "https://www.googleapis.com/calendar/v3/calendars/zanwei%40comma.local/events/evt123"

      refute endpoint =~ "iCalUID"
      # The session is per-read: it must not outlive the hover that opened it.
      assert_received {:proxy_closed, "sess-1"}
    end

    test "never renders another event than the one the link asked for" do
      respond(
        {:ok,
         %{
           "status" => 200,
           "data" => %{"id" => "evt999", "visibility" => "public", "summary" => "Other event"}
         }}
      )

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googlecalendar", "ca-calendar")],
                 @event_href,
                 "ca-calendar"
               )
    end

    test "keeps explicitly private and confidential events link-only" do
      for visibility <- ["private", "confidential"] do
        respond(
          {:ok,
           %{
             "status" => 200,
             "data" => %{"id" => "evt123", "visibility" => visibility, "summary" => "1:1"}
           }}
        )

        assert {:error, :not_found} =
                 RecommendationLinkPreview.preview(
                   workspace(),
                   [source("googlecalendar", "ca-calendar")],
                   @event_href,
                   "ca-calendar"
                 )
      end
    end

    test "previews an event that inherits its calendar's default visibility" do
      # Google omits `visibility` for the overwhelming majority of events, and
      # the reader is the calendar's own connected account.
      respond(
        {:ok,
         %{"status" => 200, "data" => %{"id" => "evt123", "summary" => "Default visibility"}}}
      )

      assert {:ok, %{"title" => "Default visibility"}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googlecalendar", "ca-calendar")],
                 @event_href,
                 "ca-calendar"
               )
    end

    test "maps all-day events and the eventedit link shape" do
      respond(
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "id" => "evt123",
             "visibility" => "public",
             "summary" => "Offsite",
             "start" => %{"date" => "2026-09-01"},
             "end" => %{"date" => "2026-09-02"}
           }
         }}
      )

      assert {:ok,
              %{"allDay" => true, "startsAt" => 1_788_220_800_000, "endsAt" => 1_788_307_200_000}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googlecalendar", "ca-calendar")],
                 "https://calendar.google.com/calendar/u/0/r/eventedit/ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA",
                 "ca-calendar"
               )
    end
  end

  describe "Slack messages" do
    # p<digits> is the message ts with its dot removed: 1786900000.000200
    @message_href "https://comma-local.slack.com/archives/C01234567/p1786900000000200"
    @message_ts "1786900000.000200"
    @thread_ts "1786899000.000100"

    # The session's first request binds the permalink's workspace subdomain.
    @auth_ok {:ok,
              %{
                "status" => 200,
                "data" => %{"ok" => true, "url" => "https://comma-local.slack.com/"}
              }}

    test "decodes the permalink into channel id + ts and rejects near misses" do
      assert {:ok, {:slack_message, "comma-local.slack.com", "C01234567", @message_ts, nil}} =
               RecommendationLinkPreview.parse_href(@message_href)

      # A parent permalink repeats the message ts as thread_ts: a plain link.
      assert {:ok, {:slack_message, "comma-local.slack.com", "C01234567", @message_ts, nil}} =
               RecommendationLinkPreview.parse_href(
                 @message_href <> "?thread_ts=#{@message_ts}&cid=C01234567"
               )

      # A reply permalink names its parent thread alongside the reply's ts.
      assert {:ok,
              {:slack_message, "comma-local.slack.com", "C01234567", @message_ts, @thread_ts}} =
               RecommendationLinkPreview.parse_href(
                 @message_href <> "?thread_ts=#{@thread_ts}&cid=C01234567"
               )

      for href <- [
            "http://comma-local.slack.com/archives/C01234567/p1786900000000200",
            "https://slack.com/archives/C01234567/p1786900000000200",
            "https://comma-local.slack.com/archives/c01234567/p1786900000000200",
            "https://comma-local.slack.com/archives/C01234567/p123456789",
            "https://comma-local.slack.com/archives/C01234567"
          ] do
        assert {:error, :not_found} = RecommendationLinkPreview.parse_href(href)
      end
    end

    test "reads the message and its garnishes through one Tool Router session" do
      respond_queue([
        @auth_ok,
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "ok" => true,
             "messages" => [
               %{"ts" => @message_ts, "text" => "Ship the launch review", "user" => "U777"}
             ]
           }
         }},
        {:ok,
         %{
           "status" => 200,
           "data" => %{"ok" => true, "channel" => %{"id" => "C01234567", "name" => "launch"}}
         }},
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "ok" => true,
             "user" => %{
               "name" => "zanwei.guo",
               "real_name" => "Zanwei Guo",
               "profile" => %{
                 "display_name" => "zanwei",
                 "image_72" => "https://avatars.example/zanwei-72"
               }
             }
           }
         }}
      ])

      assert {:ok, preview} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googlecalendar", "ca-calendar"), source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )

      assert preview == %{
               "kind" => "slack_message",
               "href" => @message_href,
               "channel" => %{"id" => "C01234567", "name" => "launch"},
               "author" => %{
                 "name" => "zanwei",
                 "avatarUrl" => "https://avatars.example/zanwei-72"
               },
               "text" => "Ship the launch review",
               "postedAt" => 1_786_900_000_000
             }

      assert_received {:proxy_session, "grp-1", "ca-slack", "slack"}

      # The session's first request binds the permalink's workspace.
      assert_received {:proxy, "sess-1", %{"toolkit_slug" => "slack", "endpoint" => auth}}
      assert auth == "https://slack.com/api/auth.test"

      # A plain permalink still reads through conversations.history.
      assert_received {:proxy, "sess-1", %{"toolkit_slug" => "slack", "endpoint" => history}}

      assert history ==
               "https://slack.com/api/conversations.history?channel=C01234567&latest=#{@message_ts}&inclusive=true&limit=1"

      assert_received {:proxy, "sess-1",
                       %{
                         "endpoint" =>
                           "https://slack.com/api/conversations.info?channel=C01234567"
                       }}

      assert_received {:proxy, "sess-1",
                       %{"endpoint" => "https://slack.com/api/users.info?user=U777"}}

      # All four requests share the one session, closed exactly once.
      assert_received {:proxy_closed, "sess-1"}
      refute_received {:proxy_session, _, _, _}
      refute_received {:proxy_closed, _}
    end

    test "trims long text and keeps failed garnishes silent" do
      respond_queue([
        @auth_ok,
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "ok" => true,
             "messages" => [%{"ts" => @message_ts, "text" => String.duplicate("a", 300)}]
           }
         }},
        {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "missing_scope"}}}
      ])

      assert {:ok, preview} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )

      assert preview["channel"] == %{"id" => "C01234567", "name" => nil}
      # A message without a user (a bot post) never asks users.info at all.
      assert preview["author"] == nil
      assert String.length(preview["text"]) == 280
      assert String.ends_with?(preview["text"], "…")
      refute_received {:proxy, _, %{"endpoint" => "https://slack.com/api/users.info" <> _}}
    end

    test "maps Slack's ok:false answers to missing or unavailable" do
      respond_queue([
        @auth_ok,
        {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "channel_not_found"}}}
      ])

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )

      assert_received {:proxy_closed, "sess-1"}

      respond_queue([
        @auth_ok,
        {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "ratelimited"}}}
      ])

      assert {:error, {:unavailable, {:slack_api, "ratelimited"}}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )

      # The nearest earlier message is not the linked message.
      respond_queue([
        @auth_ok,
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "ok" => true,
             "messages" => [%{"ts" => "1786899999.000100", "text" => "earlier"}]
           }
         }}
      ])

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )
    end

    test "replaces one missing Tool Router session for the required read only" do
      respond_queue([
        # The stale session dies on its first request (auth.test)...
        {:error, :not_found},
        # ...and the replacement session re-runs the workspace binding.
        @auth_ok,
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "ok" => true,
             "messages" => [%{"ts" => @message_ts, "text" => "Recovered"}]
           }
         }},
        {:ok, %{"status" => 200, "data" => %{"ok" => true, "channel" => %{"name" => "launch"}}}}
      ])

      assert {:ok, %{"text" => "Recovered", "channel" => %{"name" => "launch"}}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )

      assert_received {:proxy_session, "grp-1", "ca-slack", "slack"}
      assert_received {:proxy_closed, "sess-1"}
      assert_received {:proxy_session, "grp-1", "ca-slack", "slack"}
      assert_received {:proxy_closed, "sess-1"}

      respond_queue([{:error, :not_found}, {:error, :not_found}])

      assert {:error, {:unavailable, :composio_proxy_session_unavailable}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )
    end

    test "reads a thread reply through conversations.replies pinned to the exact ts" do
      respond_queue([
        @auth_ok,
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "ok" => true,
             "messages" => [
               %{"ts" => @thread_ts, "text" => "Parent", "user" => "U111"},
               %{"ts" => @message_ts, "text" => "The reply", "user" => "U777"}
             ]
           }
         }},
        {:ok,
         %{
           "status" => 200,
           "data" => %{"ok" => true, "channel" => %{"id" => "C01234567", "name" => "launch"}}
         }},
        {:ok,
         %{
           "status" => 200,
           "data" => %{"ok" => true, "user" => %{"profile" => %{"display_name" => "zanwei"}}}
         }}
      ])

      assert {:ok, preview} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href <> "?thread_ts=#{@thread_ts}&cid=C01234567",
                 "ca-slack"
               )

      # The reply itself is previewed, not the thread parent Slack lists first.
      assert preview["text"] == "The reply"
      assert preview["postedAt"] == 1_786_900_000_000
      assert preview["author"] == %{"name" => "zanwei", "avatarUrl" => nil}

      assert_received {:proxy, "sess-1", %{"endpoint" => "https://slack.com/api/auth.test"}}
      assert_received {:proxy, "sess-1", %{"toolkit_slug" => "slack", "endpoint" => replies}}

      assert replies ==
               "https://slack.com/api/conversations.replies?channel=C01234567" <>
                 "&ts=#{@thread_ts}&latest=#{@message_ts}&inclusive=true&limit=1"

      refute_received {:proxy, _,
                       %{"endpoint" => "https://slack.com/api/conversations.history" <> _}}
    end

    test "treats a reply missing from its thread window as not found" do
      respond_queue([
        @auth_ok,
        {:ok,
         %{
           "status" => 200,
           "data" => %{"ok" => true, "messages" => [%{"ts" => @thread_ts, "text" => "Parent"}]}
         }}
      ])

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href <> "?thread_ts=#{@thread_ts}",
                 "ca-slack"
               )

      respond_queue([
        @auth_ok,
        {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "thread_not_found"}}}
      ])

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href <> "?thread_ts=#{@thread_ts}",
                 "ca-slack"
               )
    end

    test "never previews a foreign workspace's permalink over the connected account" do
      respond_queue([@auth_ok])

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 "https://evil.slack.com/archives/C01234567/p1786900000000200",
                 "ca-slack"
               )

      assert_received {:proxy, "sess-1", %{"endpoint" => "https://slack.com/api/auth.test"}}
      assert_received {:proxy_closed, "sess-1"}
      # No message, channel, or user read follows the failed binding.
      refute_received {:proxy, _, _}
    end

    test "requires a verifiable workspace before reading any message" do
      respond_queue([
        {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "invalid_auth"}}}
      ])

      assert {:error, {:unavailable, {:slack_api, "invalid_auth"}}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )

      assert_received {:proxy_closed, "sess-1"}
      refute_received {:proxy, _, %{"endpoint" => "https://slack.com/api/conversations." <> _}}

      respond_queue([{:ok, %{"status" => 500, "data" => %{}}}])

      assert {:error, {:unavailable, {:slack_http, 500}}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("slack", "ca-slack")],
                 @message_href,
                 "ca-slack"
               )
    end
  end

  describe "Google Drive files" do
    test "parses every Drive link shape into one kind" do
      for href <- [
            "https://docs.google.com/document/d/1AbC_def-123/edit?tab=t.0#heading=h",
            "https://docs.google.com/spreadsheets/d/1AbC_def-123",
            "https://docs.google.com/presentation/d/1AbC_def-123/present",
            "https://docs.google.com/forms/d/1AbC_def-123/viewform",
            "https://drive.google.com/file/d/1AbC_def-123/view?usp=sharing",
            "https://drive.google.com/open?usp=drive_link&id=1AbC_def-123"
          ] do
        assert {:ok, {:google_drive_file, "1AbC_def-123"}} =
                 RecommendationLinkPreview.parse_href(href)
      end

      for href <- [
            "http://docs.google.com/document/d/1AbC_def-123/edit",
            "https://docs.google.com/drawings/d/1AbC_def-123/edit",
            "https://drive.google.com/drive/folders/1AbC_def-123",
            "https://drive.google.com/open?usp=drive_link",
            # Published /d/e/ links: the literal "e" segment is not a file id.
            "https://docs.google.com/forms/d/e/1FAIpQLSfAbCdEf/viewform",
            "https://docs.google.com/spreadsheets/d/e/2PACX-1vRabc/pubhtml"
          ] do
        assert {:error, :not_found} = RecommendationLinkPreview.parse_href(href)
      end
    end

    test "keeps published /d/e/ links from burning a provider round trip" do
      for href <- [
            "https://docs.google.com/forms/d/e/1FAIpQLSfAbCdEf/viewform",
            "https://docs.google.com/spreadsheets/d/e/2PACX-1vRabc/pubhtml"
          ] do
        assert {:error, :not_found} =
                 RecommendationLinkPreview.preview(
                   workspace(),
                   [source("googledrive", "ca-drive")],
                   href,
                   "ca-drive"
                 )
      end

      refute_received {:proxy_session, _, _, _}
      refute_received {:proxy, _, _}
    end

    test "omits the owner when Drive reports an empty displayName" do
      respond(
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "name" => "Launch brief",
             "owners" => [%{"displayName" => "", "photoLink" => "https://avatars.example/dana"}]
           }
         }}
      )

      assert {:ok, %{"title" => "Launch brief", "owner" => nil}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googledrive", "ca-drive")],
                 "https://drive.google.com/file/d/1AbC_def-123/view",
                 "ca-drive"
               )
    end

    test "reads file metadata through the pinned Drive account" do
      respond(
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "id" => "1AbC_def-123",
             "name" => "Launch brief",
             "mimeType" => "application/vnd.google-apps.document",
             "modifiedTime" => "2026-08-20T10:00:00.000Z",
             "webViewLink" => "https://docs.google.com/document/d/1AbC_def-123/edit",
             "owners" => [
               %{"displayName" => "Dana Wu", "photoLink" => "https://avatars.example/dana"}
             ]
           }
         }}
      )

      assert {:ok, preview} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googledrive", "ca-drive")],
                 "https://docs.google.com/document/d/1AbC_def-123/edit?usp=sharing",
                 "ca-drive"
               )

      assert preview == %{
               "kind" => "google_drive_file",
               "href" => "https://docs.google.com/document/d/1AbC_def-123/edit",
               "title" => "Launch brief",
               "fileKind" => "document",
               "owner" => %{"name" => "Dana Wu", "avatarUrl" => "https://avatars.example/dana"},
               "modifiedAt" => 1_787_220_000_000,
               "size" => nil
             }

      assert_received {:proxy_session, "grp-1", "ca-drive", "googledrive"}
      assert_received {:proxy, "sess-1", %{"method" => "GET", "endpoint" => endpoint}}

      assert endpoint ==
               "https://www.googleapis.com/drive/v3/files/1AbC_def-123" <>
                 "?fields=id,name,mimeType,modifiedTime,webViewLink,owners(displayName,photoLink),size" <>
                 "&supportsAllDrives=true"

      assert_received {:proxy_closed, "sess-1"}
    end

    test "maps mime types to file kinds and parses Drive's string size" do
      for {mime, kind} <- [
            {"application/vnd.google-apps.document", "document"},
            {"application/vnd.google-apps.spreadsheet", "spreadsheet"},
            {"application/vnd.google-apps.presentation", "presentation"},
            {"application/vnd.google-apps.form", "form"},
            {"application/vnd.google-apps.folder", "folder"},
            {"application/pdf", "pdf"},
            {"video/mp4", "file"}
          ] do
        respond({:ok, %{"status" => 200, "data" => %{"mimeType" => mime, "size" => "482133"}}})

        assert {:ok, %{"fileKind" => ^kind, "size" => 482_133}} =
                 RecommendationLinkPreview.preview(
                   workspace(),
                   [source("googledrive", "ca-drive")],
                   "https://drive.google.com/file/d/1AbC_def-123/view",
                   "ca-drive"
                 )
      end

      # An unnamed answer still previews; an unparsable size is no size.
      respond({:ok, %{"status" => 200, "data" => %{"size" => "unknown"}}})

      assert {:ok,
              %{
                "title" => "Untitled",
                "fileKind" => "file",
                "owner" => nil,
                "size" => nil,
                "href" => "https://drive.google.com/open?id=1AbC_def-123"
              }} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googledrive", "ca-drive")],
                 "https://drive.google.com/open?id=1AbC_def-123",
                 "ca-drive"
               )
    end

    test "maps a missing file to not found and other statuses to unavailable" do
      respond({:ok, %{"status" => 404, "data" => %{}}})

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googledrive", "ca-drive")],
                 "https://drive.google.com/file/d/1AbC_def-123/view",
                 "ca-drive"
               )

      assert_received {:proxy_closed, "sess-1"}

      respond({:ok, %{"status" => 403, "data" => %{}}})

      assert {:error, {:unavailable, {:google_drive_http, 403}}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googledrive", "ca-drive")],
                 "https://drive.google.com/file/d/1AbC_def-123/view",
                 "ca-drive"
               )
    end

    test "replaces one missing Tool Router session and recovers the file" do
      respond_queue([
        {:error, :not_found},
        {:ok, %{"status" => 200, "data" => %{"name" => "Recovered brief"}}}
      ])

      assert {:ok, %{"title" => "Recovered brief"}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("googledrive", "ca-drive")],
                 "https://drive.google.com/file/d/1AbC_def-123/view",
                 "ca-drive"
               )

      assert_received {:proxy_session, "grp-1", "ca-drive", "googledrive"}
      assert_received {:proxy_closed, "sess-1"}
      assert_received {:proxy_session, "grp-1", "ca-drive", "googledrive"}
      assert_received {:proxy_closed, "sess-1"}
      refute_received {:proxy_session, _, _, _}
    end
  end

  describe "link shapes" do
    test "only previews supported links and never Gmail" do
      for href <- [
            "https://github.com/AFK-surf/Comma/issues/12",
            "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
            "https://drive.google.com/drive/folders/1AbC_def-123",
            "https://app.slack.com/client/T012345/C01234567",
            "https://www.google.com/calendar/event?eid=%%%"
          ] do
        assert {:error, :not_found} =
                 RecommendationLinkPreview.preview(
                   workspace(),
                   [
                     source("github", "ca-github"),
                     source("gmail", "ca-gmail"),
                     source("googlecalendar", "ca-calendar")
                   ],
                   href,
                   nil
                 )
      end

      assert {:error, {:bad_request, _}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("github", "ca-github")],
                 nil,
                 nil
               )

      refute_received {:execute, _, _, _, _, _}
      refute_received {:proxy_session, _, _, _}
    end

    test "never reads through a non-matching or disabled account" do
      disabled = Map.put(source("github", "ca-github"), "enabled", false)

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("linear", "ca-linear"), disabled],
                 "https://github.com/AFK-surf/Comma/pull/845",
                 "ca-linear"
               )

      assert {:error, :not_found} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("github", "ca-github")],
                 "https://linear.app/comma/issue/COMMA-143",
                 "ca-github"
               )

      refute_received {:execute, _, _, _, _, _}
    end

    test "maps provider failures to an unavailable error" do
      respond({:ok, %{"successful" => false, "error" => "rate limited"}})

      assert {:error, {:unavailable, {:provider_failed, "rate limited"}}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("github", "ca-github")],
                 "https://github.com/AFK-surf/Comma/pull/845",
                 "ca-github"
               )

      respond({:error, :timeout})

      assert {:error, {:unavailable, :timeout}} =
               RecommendationLinkPreview.preview(
                 workspace(),
                 [source("notion", "ca-notion")],
                 "https://www.notion.so/4b8e7d0d9f1a4ed89d6ba8d11080a812",
                 "ca-notion"
               )
    end
  end

  defp respond(response),
    do: Application.put_env(:comma_web, :recommendation_link_preview_test_response, response)

  defp respond_queue(responses),
    do: Application.put_env(:comma_web, :recommendation_link_preview_test_responses, responses)

  defp workspace,
    do: %{"id" => "wsp-1", "default_group_id" => "grp-1", "salix_tenant_id" => "ten-1"}

  defp source(toolkit, connection_id) do
    %{
      "appId" => toolkit,
      "appName" => String.capitalize(toolkit),
      "connectionId" => connection_id,
      "enabled" => true,
      "kind" => "composio",
      "toolkit" => toolkit
    }
  end
end
