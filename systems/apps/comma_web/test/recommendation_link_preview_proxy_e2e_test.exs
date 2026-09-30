defmodule CommaWeb.RecommendationLinkPreviewProxyE2ETest do
  use ExUnit.Case, async: false

  alias CommaWeb.RecommendationLinkPreview

  @event_href "https://www.google.com/calendar/event?eid=ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA"

  # p<digits> is the message ts with its dot removed: 1786900000.000200
  @message_href "https://comma-local.slack.com/archives/C01234567/p1786900000000200"
  @message_ts "1786900000.000200"
  @thread_ts "1786899000.000100"

  # Every Slack session opens by binding the permalink's workspace subdomain.
  @auth_ok {:ok,
            %{
              "status" => 200,
              "data" => %{"ok" => true, "url" => "https://comma-local.slack.com/"}
            }}

  defmodule Settings do
    def settings(_tenant_id), do: {:ok, %{"api_key" => "test"}}
  end

  # This adapter is the remote boundary of the end-to-end preview read. Its
  # ordered answers let the test exercise session replacement without exposing
  # private implementation functions from RecommendationLinkPreview.
  defmodule Client do
    def create_proxy_session(_settings, group_id, account_id, toolkit, _opts) do
      send(test_pid(), {:proxy_session, group_id, account_id, toolkit})
      pop!(:recommendation_link_preview_e2e_sessions)
    end

    def proxy_execute(_settings, session_id, request, _opts) do
      send(test_pid(), {:proxy, session_id, request})
      pop!(:recommendation_link_preview_e2e_responses)
    end

    def delete_proxy_session(_settings, session_id) do
      send(test_pid(), {:proxy_closed, session_id})
      :ok
    end

    defp pop!(key) do
      case Application.fetch_env!(:comma_web, key) do
        [next | rest] ->
          Application.put_env(:comma_web, key, rest)
          next

        [] ->
          raise "unexpected extra proxy operation for #{key}"
      end
    end

    defp test_pid,
      do: Application.fetch_env!(:comma_web, :recommendation_link_preview_e2e_test_pid)
  end

  setup do
    keys = [
      :recommendation_composio_client_mod,
      :recommendation_composio_settings_mod,
      :recommendation_link_preview_e2e_responses,
      :recommendation_link_preview_e2e_sessions,
      :recommendation_link_preview_e2e_test_pid
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:comma_web, &1)})
    Application.put_env(:comma_web, :recommendation_composio_client_mod, Client)
    Application.put_env(:comma_web, :recommendation_composio_settings_mod, Settings)
    Application.put_env(:comma_web, :recommendation_link_preview_e2e_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:comma_web, key)
        {key, value} -> Application.put_env(:comma_web, key, value)
      end)
    end)

    :ok
  end

  test "keeps provider rate limiting distinct from a missing event" do
    attempts(
      ["sess-rate-limit"],
      [
        {:ok,
         %{
           "status" => 403,
           "data" => %{
             "error" => %{
               "code" => 403,
               "errors" => [%{"reason" => "userRateLimitExceeded"}]
             }
           }
         }}
      ]
    )

    assert {:error,
            {:unavailable, {:google_calendar_rate_limited, 403, ["userRateLimitExceeded"]}}} =
             preview()

    assert_received {:proxy_closed, "sess-rate-limit"}
  end

  test "maps only provider-envelope missing responses to a missing event" do
    for status <- [404, 410] do
      session_id = "sess-provider-#{status}"
      attempts([session_id], [{:ok, %{"status" => status, "data" => %{}}}])

      assert {:error, :not_found} = preview()
      assert_received {:proxy_closed, ^session_id}
    end
  end

  test "replaces one missing Tool Router session and recovers the exact event" do
    attempts(
      ["sess-stale", "sess-replacement"],
      [
        {:error, :not_found},
        {:ok,
         %{
           "status" => 200,
           "data" => %{"id" => "evt123", "summary" => "Recovered review"}
         }}
      ]
    )

    assert {:ok, %{"kind" => "google_calendar_event", "title" => "Recovered review"}} =
             preview()

    assert_received {:proxy_closed, "sess-stale"}
    assert_received {:proxy_closed, "sess-replacement"}
    assert_received {:proxy, "sess-stale", _request}
    assert_received {:proxy, "sess-replacement", _request}
  end

  test "returns unavailable after the replacement Tool Router session is also missing" do
    attempts(
      ["sess-stale", "sess-stale-again"],
      [{:error, :not_found}, {:error, :not_found}]
    )

    assert {:error, {:unavailable, :composio_proxy_session_unavailable}} = preview()

    assert_received {:proxy_session, "grp-1", "ca-calendar", "googlecalendar"}
    assert_received {:proxy_session, "grp-1", "ca-calendar", "googlecalendar"}
    assert_received {:proxy_closed, "sess-stale"}
    assert_received {:proxy_closed, "sess-stale-again"}
    refute_received {:proxy_session, _, _, _}
  end

  test "replaces one missing session before the required Slack read only" do
    attempts(
      ["sess-stale", "sess-replacement"],
      [
        {:error, :not_found},
        @auth_ok,
        {:ok,
         %{
           "status" => 200,
           "data" => %{
             "ok" => true,
             "messages" => [%{"ts" => @message_ts, "text" => "Recovered"}]
           }
         }},
        {:ok, %{"status" => 200, "data" => %{"ok" => false, "error" => "missing_scope"}}}
      ]
    )

    assert {:ok, %{"kind" => "slack_message", "text" => "Recovered", "author" => nil}} =
             slack_preview()

    assert_received {:proxy_session, "grp-1", "ca-slack", "slack"}
    assert_received {:proxy_session, "grp-1", "ca-slack", "slack"}
    assert_received {:proxy, "sess-stale", _request}
    assert_received {:proxy_closed, "sess-stale"}

    # The replacement session re-runs the workspace binding first.
    assert_received {:proxy, "sess-replacement",
                     %{"endpoint" => "https://slack.com/api/auth.test"}}

    assert_received {:proxy, "sess-replacement",
                     %{"endpoint" => "https://slack.com/api/conversations.history" <> _}}

    assert_received {:proxy, "sess-replacement",
                     %{"endpoint" => "https://slack.com/api/conversations.info" <> _}}

    assert_received {:proxy_closed, "sess-replacement"}
    refute_received {:proxy_session, _, _, _}
  end

  test "reads a Slack thread reply through conversations.replies" do
    attempts(
      ["sess-slack"],
      [
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
        {:ok, %{"status" => 200, "data" => %{"ok" => true, "channel" => %{"name" => "release"}}}},
        {:ok, %{"status" => 200, "data" => %{"ok" => true, "user" => %{"name" => "dana"}}}}
      ]
    )

    assert {:ok,
            %{"kind" => "slack_message", "text" => "The reply", "author" => %{"name" => "dana"}}} =
             slack_preview(@message_href <> "?thread_ts=#{@thread_ts}&cid=C01234567")

    assert_received {:proxy, "sess-slack", %{"endpoint" => "https://slack.com/api/auth.test"}}

    assert_received {:proxy, "sess-slack",
                     %{"endpoint" => "https://slack.com/api/conversations.replies" <> _}}

    refute_received {:proxy, _,
                     %{"endpoint" => "https://slack.com/api/conversations.history" <> _}}

    assert_received {:proxy_closed, "sess-slack"}
  end

  defp attempts(sessions, responses) do
    Application.put_env(
      :comma_web,
      :recommendation_link_preview_e2e_sessions,
      Enum.map(sessions, &{:ok, &1})
    )

    Application.put_env(:comma_web, :recommendation_link_preview_e2e_responses, responses)
  end

  defp preview do
    RecommendationLinkPreview.preview(
      %{"default_group_id" => "grp-1", "salix_tenant_id" => "ten-1"},
      [
        %{
          "appId" => "googlecalendar",
          "appName" => "Google Calendar",
          "connectionId" => "ca-calendar",
          "enabled" => true,
          "kind" => "composio",
          "toolkit" => "googlecalendar"
        }
      ],
      @event_href,
      "ca-calendar"
    )
  end

  defp slack_preview(href \\ @message_href) do
    RecommendationLinkPreview.preview(
      %{"default_group_id" => "grp-1", "salix_tenant_id" => "ten-1"},
      [
        %{
          "appId" => "slack",
          "appName" => "Slack",
          "connectionId" => "ca-slack",
          "enabled" => true,
          "kind" => "composio",
          "toolkit" => "slack"
        }
      ],
      href,
      "ca-slack"
    )
  end
end
