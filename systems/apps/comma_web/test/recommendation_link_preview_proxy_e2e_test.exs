defmodule CommaWeb.RecommendationLinkPreviewProxyE2ETest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  alias CommaWeb.RecommendationLinkPreview

  @event_href "https://www.google.com/calendar/event?eid=ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA"

  defmodule Settings do
    def settings(_tenant_id), do: {:ok, %{"api_key" => "test"}}
  end

  # This adapter is the remote boundary of the end-to-end preview read. Its
  # ordered answers let the test exercise session replacement without exposing
  # private implementation functions from RecommendationLinkPreview.
  defmodule Client do
    def get_connected_account(_settings, id) do
      toolkit =
        cond do
          String.contains?(id, "calendar") -> "googlecalendar"
          String.contains?(id, "drive") -> "googledrive"
          String.contains?(id, "slack") -> "slack"
          true -> "github"
        end

      {:ok,
       %{
         "id" => id,
         "user_id" =>
           if(SystemsRuntime.get_env(:comma_web, :preview_e2e_rebound),
             do: "other-group",
             else: "grp-1"
           ),
         "toolkit" => %{"slug" => toolkit},
         "status" => "ACTIVE"
       }}
    end

    def create_proxy_session(_settings, group_id, account_id, toolkit, _opts) do
      SystemsRuntime.Proc.send(test_pid(), {:proxy_session, group_id, account_id, toolkit})
      pop!(:recommendation_link_preview_e2e_sessions)
    end

    def proxy_execute(_settings, session_id, request, _opts) do
      SystemsRuntime.Proc.send(test_pid(), {:proxy, session_id, request})

      if SystemsRuntime.get_env(:comma_web, :preview_e2e_rebind_on_read),
        do: SystemsRuntime.put_env(:comma_web, :preview_e2e_rebound, true)

      pop!(:recommendation_link_preview_e2e_responses)
    end

    def delete_proxy_session(_settings, session_id) do
      SystemsRuntime.Proc.send(test_pid(), {:proxy_closed, session_id})
      :ok
    end

    defp pop!(key) do
      case SystemsRuntime.fetch_env!(:comma_web, key) do
        [next | rest] ->
          SystemsRuntime.put_env(:comma_web, key, rest)
          next

        [] ->
          raise "unexpected extra proxy operation for #{key}"
      end
    end

    defp test_pid,
      do: SystemsRuntime.fetch_env!(:comma_web, :recommendation_link_preview_e2e_test_pid)
  end

  setup do
    keys = [
      :recommendation_composio_client_mod,
      :recommendation_composio_settings_mod,
      :recommendation_link_preview_e2e_responses,
      :recommendation_link_preview_e2e_sessions,
      :recommendation_link_preview_e2e_test_pid,
      :preview_e2e_rebind_on_read,
      :preview_e2e_rebound
    ]

    previous = Map.new(keys, &{&1, SystemsRuntime.get_env(:comma_web, &1)})
    SystemsRuntime.put_env(:comma_web, :recommendation_composio_client_mod, Client)
    SystemsRuntime.put_env(:comma_web, :recommendation_composio_settings_mod, Settings)

    SystemsRuntime.put_env(
      :comma_web,
      :recommendation_link_preview_e2e_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:comma_web, key)
        {key, value} -> SystemsRuntime.put_env(:comma_web, key, value)
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

  test "rejects a completed provider read if the pinned account changes owner" do
    attempts(
      ["sess-rebound"],
      [{:ok, %{"status" => 200, "data" => %{"id" => "evt123", "summary" => "Private"}}}]
    )

    SystemsRuntime.put_env(:comma_web, :preview_e2e_rebind_on_read, true)
    assert {:error, :not_found} = preview()
    assert_received {:proxy_closed, "sess-rebound"}
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

  defp attempts(sessions, responses) do
    SystemsRuntime.put_env(
      :comma_web,
      :recommendation_link_preview_e2e_sessions,
      Enum.map(sessions, &{:ok, &1})
    )

    SystemsRuntime.put_env(:comma_web, :recommendation_link_preview_e2e_responses, responses)
  end

  defp preview do
    authorized_preview(
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

  defp authorized_preview(workspace, sources, href, source_id) do
    viewer = workspace["owner_user_id"] || "test-viewer"
    workspace = Map.put(workspace, "owner_user_id", viewer)
    RecommendationLinkPreview.preview(workspace, sources, href, source_id, viewer)
  end
end
