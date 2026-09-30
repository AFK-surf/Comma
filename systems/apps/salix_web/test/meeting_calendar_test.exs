defmodule Salix.Bindings.MeetingCalendarTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.{GoogleCalendarSource, GoogleCalendarWatch, MeetingCalendar}
  alias SalixCluster.Schedules
  alias Salix.Control.ComposioSettings
  alias SalixCalendar.AgentAPI
  alias SalixCalendar.Server, as: Calendar
  alias SalixIM.{Conversations, ConversationServer}
  alias SalixMeet.MeetingPlan
  alias SalixStore.{Ids, Keys, S3}

  @proxy_session_path "/api/v3.1/tool_router/session"
  @proxy_execute_path "/api/v3.1/tool_router/session/trs-calendar/proxy_execute"

  defmodule MockExternalHTTP do
    use Agent
    import Plug.Conn

    def start_link(_opts \\ []),
      do: Agent.start_link(fn -> %{responses: %{}, requests: []} end, name: __MODULE__)

    def stub(method, path, body, status \\ 200),
      do:
        Agent.update(__MODULE__, fn state ->
          put_in(state, [:responses, {method, path}], {status, body})
        end)

    def stub_sequence(method, path, responses) when is_list(responses) do
      Agent.update(__MODULE__, fn state ->
        normalized =
          Enum.map(responses, fn
            {status, body} -> {status, body}
            body -> {200, body}
          end)

        put_in(state, [:responses, {method, path}], normalized)
      end)
    end

    def requests, do: Agent.get(__MODULE__, & &1.requests)

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      body =
        cond do
          raw == "" -> %{}
          String.starts_with?(raw, "{") -> Jason.decode!(raw)
          true -> URI.decode_query(raw)
        end

      Agent.update(__MODULE__, fn state ->
        %{
          state
          | requests:
              state.requests ++ [%{method: conn.method, path: conn.request_path, body: body}]
        }
      end)

      {status, response} =
        Agent.get_and_update(__MODULE__, fn state ->
          key = {conn.method, conn.request_path}

          case state.responses[key] do
            [response | rest] ->
              {response, put_in(state, [:responses, key], rest)}

            response when is_tuple(response) ->
              {response, state}

            _ ->
              {{404, %{"successful" => false, "error" => "no stub"}}, state}
          end
        end)

      response = if is_function(response, 1), do: response.(body), else: response

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  defmodule VersionedGoogleCalendarSource do
    @behaviour SalixCalendar.SourceAdapter

    alias Salix.Bindings.GoogleCalendarSource

    @impl true
    def adapter_contract_id,
      do: Application.fetch_env!(:salix_web, :test_google_calendar_contract_id)

    @impl true
    def capabilities, do: GoogleCalendarSource.capabilities()

    @impl true
    def start_sync(source, query_contract, completed_cursor),
      do:
        source
        |> GoogleCalendarSource.start_sync(query_contract, completed_cursor)
        |> emulate_legacy_page()

    @impl true
    def continue_sync(source, query_contract, continuation),
      do:
        source
        |> GoogleCalendarSource.continue_sync(query_contract, continuation)
        |> emulate_legacy_page()

    @impl true
    def exact_refresh(source, item, occurrence),
      do: GoogleCalendarSource.exact_refresh(source, item, occurrence)

    @impl true
    def normalize(record, opts) do
      with {:ok, normalized} <- GoogleCalendarSource.normalize(record, opts) do
        if adapter_contract_id() == "google_calendar.events.v1" and wkst?(record) do
          {:ok, legacy_normalized(normalized)}
        else
          {:ok, normalized}
        end
      end
    end

    defp emulate_legacy_page({:ok, %{"changes" => changes} = page})
         when is_list(changes) do
      if adapter_contract_id() == "google_calendar.events.v1" do
        {:ok, Map.put(page, "changes", Enum.map(changes, &maybe_legacy_normalized/1))}
      else
        {:ok, page}
      end
    end

    defp emulate_legacy_page(result), do: result

    defp maybe_legacy_normalized(normalized) do
      if get_in(normalized, ["object", "recurrenceRules", Access.at(0), "firstDayOfWeek"]) do
        legacy_normalized(normalized)
      else
        normalized
      end
    end

    defp legacy_normalized(normalized) do
      qualification = %{
        "item_eligible" => false,
        "item_reason" => "unsupported_timing",
        "authorized" => false,
        "reason" => "unsupported_timing"
      }

      normalized
      |> Map.put("normalization_state", "unsupported_timing")
      |> Map.put("meeting_qualification", qualification)
      |> put_in(["object", "recurrenceRules"], [])
    end

    defp wkst?(record) do
      record
      |> Map.get("recurrence", [])
      |> Enum.any?(&String.contains?(&1, "WKST="))
    end
  end

  setup do
    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      composio_url: Application.get_env(:salix_store, :composio_base_url_override),
      adapters: Application.get_env(:salix_calendar, :source_adapters),
      runtime: Application.get_env(:salix_meet, :agent_runtime_mod),
      group_context: Application.get_env(:salix_agent, :group_context_mod),
      calendar: Application.get_env(:salix_agent, :calendar_mod),
      oauth: Application.get_env(:salix_agent, :oauth_store_mod),
      public_base_url: Application.get_env(:salix_web, :public_base_url),
      slack_api_base_url: Application.get_env(:salix_im, :slack_api_base_url)
    }

    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    Application.put_env(:salix_calendar, :source_adapters, %{
      "google_calendar" => GoogleCalendarSource
    })

    Application.put_env(:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime)
    Application.put_env(:salix_agent, :calendar_mod, Salix.Bindings.AgentCalendar)
    Application.put_env(:salix_agent, :oauth_store_mod, Salix.Bindings.AgentOAuthStore)
    SalixAgent.TestSupport.configure_control_fixtures!()
    ensure_started!(S3.Fake)
    S3.Fake.reset()
    SalixAgent.TestSupport.stop_all_agents()

    ensure_started!(MockExternalHTTP)
    Agent.update(MockExternalHTTP, fn _ -> %{responses: %{}, requests: []} end)
    port = start_bandit_retry!()
    Application.put_env(:salix_store, :composio_base_url_override, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    router_id = Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(router_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "name" => "Router",
      "role" => "router"
    })

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "router_agent_id" => router_id,
      "billing_owner" => %{
        "billing_account_id" => "ba-#{group_id}",
        "surface" => "internal",
        "product_owner_type" => "group",
        "product_owner_id" => group_id,
        "salix_tenant_id" => tenant_id,
        "salix_group_id" => group_id
      }
    })

    assert {:ok, _settings} = ComposioSettings.put(tenant_id, %{"api_key" => "ck-test"})
    stub_account(group_id, "ca-cal")
    MockExternalHTTP.stub("GET", "/api/v3/connected_accounts", %{"items" => []})
    stub_proxy_session()

    assert {:ok, calendar} =
             Calendar.ensure_calendar(
               group_id,
               %{"kind" => "meeting_test"},
               %{"name" => "Meetings", "default_time_zone" => "UTC"}
             )

    assert {:ok, source} =
             Calendar.ensure_source(group_id, calendar["calendar_id"], %{
               "adapter" => "google_calendar",
               "adapter_contract_id" => GoogleCalendarSource.adapter_contract_id(),
               "source_locator" => %{
                 "connection_id" => "ca-cal",
                 "external_calendar_id" => "provider-calendar"
               },
               "access_profile" => "events_read",
               "sync_policy" => %{
                 "initial_time_min" => "2029-01-01T00:00:00Z",
                 "page_size" => 200
               }
             })

    group = %{
      "provider" => "slack",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => "calendar-test-connect",
      "workspace_id" => "workspace-test",
      "channel_id" => "channel-meetings",
      "calendar_id" => calendar["calendar_id"],
      "calendars" => [
        %{
          "account_id" => "ca-cal",
          "calendar_id" => "provider-calendar",
          "source_id" => source["source_id"]
        }
      ]
    }

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_store, :composio_base_url_override, previous.composio_url)
      restore_env(:salix_calendar, :source_adapters, previous.adapters)
      restore_env(:salix_meet, :agent_runtime_mod, previous.runtime)
      restore_env(:salix_agent, :group_context_mod, previous.group_context)
      restore_env(:salix_agent, :calendar_mod, previous.calendar)
      restore_env(:salix_agent, :oauth_store_mod, previous.oauth)
      restore_env(:salix_web, :public_base_url, previous.public_base_url)
      restore_env(:salix_im, :slack_api_base_url, previous.slack_api_base_url)
    end)

    {:ok, group: group, source: source, router_id: router_id}
  end

  test "syncs Google master and exception into one local occurrence and one MeetingPlan", %{
    group: group
  } do
    stub_list([moved_exception(), recurring_master()], "sync-1")
    :ok = S3.Fake.reset_put_log()
    assert {:ok, _} = sync_source(group)

    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert event["start_ms"] == unix_ms("2030-01-14T11:00:00Z")
    assert event["calendar_id"] == group["calendar_id"]
    assert Ids.valid_calendar_item_id?(event["calendar_item_id"])
    assert is_map(event["occurrence_ref"])
    assert Ids.valid_meeting_plan_id?(event["meeting_plan_id"])
    refute Map.has_key?(event, "calendar_connected_account_id")
    refute Map.has_key?(event, "provider_event_id")

    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert plan["occurrence_ref"] == event["occurrence_ref"]
    assert Ids.valid_conversation_id?(plan["conversation_id"])

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group["group_id"],
               plan["conversation_id"],
               limit: 100
             )

    refute Enum.any?(participants, &(&1["actor_type"] == "provider"))

    assert plan["publication_target"] == %{
             "provider" => "slack",
             "tool" => "im_api.slack.post_message",
             "params" => %{
               "connect_id" => "calendar-test-connect",
               "channel" => "channel-meetings"
             }
           }

    assert {:ok, item} =
             Calendar.get_item(group["group_id"], group["calendar_id"], event["calendar_item_id"])

    recurrence_key = get_in(event, ["occurrence_ref", "recurrence_key", "value"])

    assert get_in(item, ["object", "recurrenceOverrides", recurrence_key, "start"]) ==
             "2030-01-14T11:00:00"

    assert get_in(item, ["source_version", "recurrence_instances", recurrence_key]) ==
             "series-instance"

    item_key =
      Keys.ctl_calendar_item(
        group["group_id"],
        group["calendar_id"],
        event["calendar_item_id"]
      )

    assert S3.Fake.put_log() |> Enum.count(&(&1 == item_key)) == 1

    stub_list([], "sync-2")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [same_event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert same_event["meeting_plan_id"] == event["meeting_plan_id"]

    list_request =
      MockExternalHTTP.requests()
      |> Enum.filter(&(&1.path == @proxy_execute_path))
      |> List.last()

    assert proxy_parameter(list_request, "syncToken") == "sync-1"
    assert proxy_parameter(list_request, "singleEvents") == "false"

    bootstrap_request =
      MockExternalHTTP.requests()
      |> Enum.filter(&(&1.path == @proxy_execute_path))
      |> List.first()

    assert bootstrap_request.body["method"] == "GET"
    assert bootstrap_request.body["toolkit_slug"] == "googlecalendar"
    assert proxy_parameter(bootstrap_request, "showDeleted") == "true"
    assert proxy_parameter(bootstrap_request, "maxResults") == "200"
    assert proxy_parameter(bootstrap_request, "timeMin") == nil
    assert proxy_parameter(bootstrap_request, "timeMax") == nil
  end

  test "meeting discovery reads the local projection without polling the provider", %{
    group: group
  } do
    stub_list([standalone_event("Provider-only meeting", 1, "2030-01-01T00:00:00Z")], "sync-1")

    assert {:ok, []} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, []} = MeetingCalendar.list(group, range_start(), range_end())

    refute Enum.any?(
             MockExternalHTTP.requests(),
             &(&1.path == @proxy_execute_path)
           )
  end

  test "Google push wakes incremental sync while discovery remains local", %{
    group: group,
    source: source
  } do
    stub_watch()

    assert {:ok, watch} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"]
             )

    assert provider_watch_request_count() == 1

    assert {:ok, ^watch} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"],
               watch["expiration"] - 24 * 60 * 60 * 1_000 - 1
             )

    assert provider_watch_request_count() == 1

    stub_channel_stop()

    assert {:ok, renewed_watch} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"],
               watch["expiration"] - 24 * 60 * 60 * 1_000
             )

    assert renewed_watch["channel_id"] != watch["channel_id"]
    assert provider_watch_request_count() == 2
    assert provider_stop_request_count() == 1

    [stop_request] = provider_stop_requests()
    assert stop_request.body["body"]["id"] == watch["channel_id"]
    assert stop_request.body["body"]["resourceId"] == watch["resource_id"]

    watch_paths =
      MockExternalHTTP.requests()
      |> Enum.filter(
        &(&1.path in [
            "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH",
            @proxy_execute_path
          ])
      )
      |> Enum.map(& &1.path)

    assert watch_paths == [
             "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH",
             "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH",
             @proxy_execute_path
           ]

    stub_list([standalone_event("Initial meeting", 1, "2030-01-01T00:00:00Z")], "sync-1")
    assert {:ok, %{"sync" => settled_sync}} = repair_source(group, source, 1)
    refute settled_sync["settlement_pending"]

    assert {:ok, [%{"title" => "Initial meeting"}]} =
             MeetingCalendar.list(group, range_start(), range_end())

    assert {:ok, [%{"title" => "Initial meeting"}]} =
             MeetingCalendar.list(group, range_start(), range_end())

    assert provider_list_request_count() == 1

    stub_list([standalone_event("Changed by push", 2, "2030-01-01T00:00:00Z")], "sync-2")

    proxy_request =
      MockExternalHTTP.requests()
      |> Enum.filter(&(&1.path == "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH"))
      |> List.last()

    rejected =
      Req.post!(
        SalixWeb.Application.base_url() <>
          "/v1/calendar/google/notifications/#{group["group_id"]}/#{group["calendar_id"]}/#{source["source_id"]}",
        headers: [
          {"x-goog-channel-id", renewed_watch["channel_id"]},
          {"x-goog-channel-token", "wrong-token"},
          {"x-goog-resource-id", renewed_watch["resource_id"]},
          {"x-goog-resource-state", "exists"}
        ]
      )

    assert rejected.status == 404
    assert provider_list_request_count() == 1

    response =
      Req.post!(
        SalixWeb.Application.base_url() <>
          "/v1/calendar/google/notifications/#{group["group_id"]}/#{group["calendar_id"]}/#{source["source_id"]}",
        headers: [
          {"x-goog-channel-id", renewed_watch["channel_id"]},
          {"x-goog-channel-token", get_in(proxy_request, [:body, "arguments", "token"])},
          {"x-goog-resource-id", renewed_watch["resource_id"]},
          {"x-goog-resource-state", "exists"}
        ]
      )

    assert response.status == 204
    assert eventually(fn -> provider_list_request_count() == 2 end)

    assert {:ok, [%{"title" => "Changed by push"}]} =
             MeetingCalendar.list(group, range_start(), range_end())

    assert provider_list_request_count() == 2
  end

  test "a callback change rotates the watch and retires the prior channel", %{
    group: group,
    source: source
  } do
    stub_watch()

    assert {:ok, first_watch} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"]
             )

    stub_channel_stop()
    Application.put_env(:salix_web, :public_base_url, "https://new-callback.example")

    assert {:ok, replacement} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"],
               1
             )

    assert replacement["callback_url"] =~ "https://new-callback.example/"
    assert replacement["channel_id"] != first_watch["channel_id"]
    assert provider_stop_request_count() == 1
    assert hd(provider_stop_requests()).body["body"]["id"] == first_watch["channel_id"]
  end

  test "a failed watch renewal keeps the persisted watch", %{group: group, source: source} do
    stub_watch()

    assert {:ok, first_watch} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"]
             )

    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH",
      %{"successful" => false, "error" => "temporary watch failure"}
    )

    assert {:error, :google_calendar_provider_error} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"],
               first_watch["expiration"]
             )

    assert {:ok, persisted} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    assert persisted["watch"] == first_watch
    assert provider_stop_request_count() == 0
  end

  test "a watch tool quota envelope returns only typed allowlisted evidence", %{
    group: group,
    source: source
  } do
    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH",
      %{
        "successful" => false,
        "error" => %{
          "status" => 429,
          "errors" => [
            %{"reason" => "quotaExceeded"},
            %{"reason" => "Authorization: Bearer secret"}
          ]
        }
      }
    )

    assert {:error, {:google_calendar_rate_limited, 429, ["quotaExceeded"]}} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"]
             )
  end

  test "a watch persistence failure stops the new channel and keeps the old watch", %{
    group: group,
    source: source
  } do
    stub_watch()

    assert {:ok, first_watch} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"]
             )

    stub_channel_stop()

    source_key =
      Keys.ctl_calendar_source(group["group_id"], group["calendar_id"], source["source_id"])

    :ok = S3.Fake.set_fault({:fail, 503, :put, source_key})

    assert {:error, _reason} =
             GoogleCalendarWatch.ensure(
               group["group_id"],
               group["calendar_id"],
               source["source_id"],
               first_watch["expiration"]
             )

    assert {:ok, persisted} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    new_channel_id =
      MockExternalHTTP.requests()
      |> Enum.filter(&(&1.path == "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH"))
      |> List.last()
      |> get_in([:body, "arguments", "id"])

    assert persisted["watch"] == first_watch
    assert new_channel_id != first_watch["channel_id"]
    assert provider_stop_request_count() == 1
    assert hd(provider_stop_requests()).body["body"]["id"] == new_channel_id
  end

  test "a forged callback cannot materialize an unbounded missing-source actor" do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    calendar_id = Ids.new_calendar_id()
    source_id = Ids.new_calendar_source_id()
    actor_key = SalixCalendar.SourceActor.key(group_id, calendar_id, source_id)

    assert Registry.lookup(SalixCalendar.Registry, actor_key) == []

    response =
      Req.post!(
        SalixWeb.Application.base_url() <>
          "/v1/calendar/google/notifications/#{group_id}/#{calendar_id}/#{source_id}",
        headers: [
          {"x-goog-channel-id", "forged"},
          {"x-goog-channel-token", "forged"},
          {"x-goog-resource-id", "forged"},
          {"x-goog-resource-state", "exists"}
        ]
      )

    assert response.status == 404
    assert Registry.lookup(SalixCalendar.Registry, actor_key) == []
  end

  test "periodic repair is jittered and does not poll before it is due", %{
    group: group,
    source: source
  } do
    stub_list([standalone_event("Initial meeting", 1, "2030-01-01T00:00:00Z")], "sync-1")
    assert {:ok, _} = repair_source(group, source, 1)
    assert provider_list_request_count() == 1

    assert {:ok, persisted} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    completed_at = get_in(persisted, ["sync", "completed_at"])
    jitter = :erlang.phash2(source["source_id"], 60 * 60 * 1_000)
    due_at = completed_at + 6 * 60 * 60 * 1_000 + jitter

    assert {:ok, %{"sync_status" => "unchanged"}} =
             repair_source(group, source, due_at - 1)

    assert provider_list_request_count() == 1

    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{"status" => 503, "data" => %{"error" => %{"message" => "temporary outage"}}}
    )

    assert {:error, {:google_calendar_http, 503}} = repair_source(group, source, due_at)
    assert provider_list_request_count() == 2

    assert {:ok, attempted} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    attempted_at = get_in(attempted, ["sync", "attempted_at"])
    retry_at = attempted_at + 6 * 60 * 60 * 1_000 + jitter

    assert {:error, {:google_calendar_http, 503}} =
             repair_source(group, source, retry_at - 1)

    assert provider_list_request_count() == 2

    stub_list([standalone_event("Repair meeting", 2, "2030-01-02T00:00:00Z")], "sync-2")
    assert {:ok, _} = repair_source(group, source, retry_at)
    assert provider_list_request_count() == 3
  end

  test "not-due readiness fails closed when terminal outcome persistence is unsettled", %{
    group: group,
    source: source
  } do
    stub_list([standalone_event("Initial meeting", 1, "2030-01-01T00:00:00Z")], "sync-1")
    assert {:ok, _} = repair_source(group, source, 1)

    assert {:ok, persisted} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    completed_at = get_in(persisted, ["sync", "completed_at"])
    jitter = :erlang.phash2(source["source_id"], 60 * 60 * 1_000)
    due_at = completed_at + 6 * 60 * 60 * 1_000 + jitter

    source_key =
      Keys.ctl_calendar_source(group["group_id"], group["calendar_id"], source["source_id"])

    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      fn _request ->
        :ok = S3.Fake.set_fault({:fail, 503, :put, source_key})

        %{
          "status" => 200,
          "data" => %{
            "items" =>
              List.duplicate(
                standalone_event("Oversized repair", 2, "2030-01-02T00:00:00Z"),
                201
              ),
            "nextSyncToken" => "must-not-commit"
          }
        }
      end
    )

    assert {:error, :source_refresh_budget_exceeded} = repair_source(group, source, due_at)
    assert provider_list_request_count() == 2

    assert {:ok, unsettled} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    attempted_at = get_in(unsettled, ["sync", "attempted_at"])
    assert is_integer(attempted_at)
    assert get_in(unsettled, ["sync", "settlement_pending"]) == true
    refute get_in(unsettled, ["sync", "last_outcome"])

    assert {:error, :calendar_source_refresh_unsettled} =
             repair_source(group, source, attempted_at + 1)

    assert provider_list_request_count() == 2
  end

  test "a failed initial bootstrap retries on the bootstrap window", %{
    group: group,
    source: source
  } do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{"status" => 503, "data" => %{"error" => %{"message" => "provider unavailable"}}}
    )

    assert {:error, _reason} = repair_source(group, source, 1)
    assert provider_list_request_count() == 1

    assert {:ok, persisted} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    attempted_at = get_in(persisted, ["sync", "attempted_at"])
    assert is_integer(attempted_at)

    due_at = attempted_at + 60_000

    assert {:error, {:google_calendar_http, 503}} =
             repair_source(group, source, due_at - 1)

    assert provider_list_request_count() == 1

    stub_list([standalone_event("Bootstrap retry", 1, "2030-01-01T00:00:00Z")], "sync-1")

    assert {:ok, %{"sync_status" => "active"}} = repair_source(group, source, due_at)
    assert provider_list_request_count() == 2

    assert {:ok, %{"active_generation" => 1, "sync" => %{"status" => "active"}}} =
             Calendar.get_source(
               group["group_id"],
               group["calendar_id"],
               source["source_id"]
             )
  end

  test "calendar bootstrap persists only allowlisted Google quota reasons", %{
    group: group,
    source: source
  } do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{
        "status" => 403,
        "data" => %{
          "error" => %{
            "errors" => [
              %{"reason" => "userRateLimitExceeded"},
              %{"reason" => "Authorization: Bearer secret"}
            ]
          }
        }
      }
    )

    assert {:error, {:google_calendar_rate_limited, 403, ["userRateLimitExceeded"]}} =
             repair_source(group, source, 1)

    assert {:ok, persisted} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    assert get_in(persisted, ["sync", "last_outcome", "reason"]) == %{
             "kind" => "google_calendar_rate_limited",
             "status" => 403,
             "reasons" => ["userRateLimitExceeded"]
           }

    refute inspect(get_in(persisted, ["sync", "last_outcome"])) =~ "Bearer secret"
  end

  test "a deleted recurring series does not block preparation for other meetings", %{
    group: group,
    source: source
  } do
    deleted_master = Map.put(recurring_master(), "status", "cancelled")

    stub_list(
      [
        moved_exception(),
        deleted_master,
        standalone_event("Surviving meeting", 1, "2030-01-02T00:00:00Z")
      ],
      "sync-after-deleted-series"
    )

    assert {:ok, _} = sync_source(group)

    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert event["title"] == "Surviving meeting"
    assert Ids.valid_meeting_plan_id?(event["meeting_plan_id"])

    assert {:ok, %{"sync" => %{"status" => "active"}, "active_generation" => 1}} =
             Calendar.get_source(
               group["group_id"],
               group["calendar_id"],
               source["source_id"]
             )
  end

  test "saved series scope selects its occurrence and pause fences the actual publication receiver",
       %{group: group} do
    alias SalixStore.MeetingCalendarSettings

    configuration = %{
      "connect_id" => group["connect_id"],
      "enabled" => true,
      "mode" => "prepare",
      "series" => [
        %{"account_id" => "ca-cal", "calendar_id" => "provider-calendar", "event_id" => "series"}
      ],
      "preparation_lead_minutes" => 30,
      "research_enabled" => false,
      "personal_preparation" => false
    }

    {:ok, saved} =
      MeetingCalendarSettings.put(group["group_id"], group["tenant_id"], configuration, fn ->
        :ok
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(
        SalixStore.Repo,
        "DELETE FROM meeting_calendar_settings WHERE group_id = $1",
        [group["group_id"]]
      )
    end)

    managed = Map.merge(group, saved)

    stub_list(
      [
        moved_exception(),
        recurring_master(),
        standalone_event("Other meeting", 1, "2030-01-01T00:00:00Z")
      ],
      "managed-series"
    )

    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(managed, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert plan["preparation"]["card_at"] == event["start_ms"] - :timer.minutes(30)

    assert {:ok, _} =
             MeetingCalendarSettings.put(
               group["group_id"],
               group["tenant_id"],
               %{configuration | "enabled" => false},
               fn -> :ok end
             )

    assert {:error, :meeting_preparation_settings_changed} =
             MeetingCalendar.list(managed, range_start(), range_end())

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(
               %{
                 "group_id" => group["group_id"],
                 "meeting_plan_id" => plan["meeting_plan_id"]
               },
               :claimed,
               now: plan["preparation"]["card_at"]
             )

    assert {:ok, paused_plan} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])
    assert paused_plan["preparation"]["card_status"] == "abandoned"

    assert SalixIM.RouterConversationProjection.list_group_router_messages(group["group_id"]) ==
             {:ok, []}

    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group["group_id"])

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(
        group["group_id"],
        conversation["conversation_id"]
      )

    refute Enum.any?(participants, &(&1["actor_type"] == "provider"))
  end

  test "the base card gets its own deterministic publication schedule", %{group: group} do
    stub_list([moved_exception(), recurring_master()], "sync-card-schedule")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    card_id = get_in(plan, ["preparation", "schedule_ids", "card"])
    assert Ids.valid_schedule_id?(card_id)

    assert {:ok, schedule} = Schedules.get(card_id)
    assert schedule["receiver"] == "meeting_publication"

    assert schedule["payload"] == %{
             "group_id" => group["group_id"],
             "meeting_plan_id" => plan["meeting_plan_id"],
             "kind" => "card"
           }

    assert schedule["run_at"] == get_in(plan, ["preparation", "card_at"])
    refute schedule["agent_id"]
    refute schedule["prompt"]
  end

  test "the receiver queues exactly one card and not_required does not suppress it", %{
    group: group
  } do
    stub_list([moved_exception(), recurring_master()], "sync-card-send")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    # The research decision suppresses only the LLM briefing track.
    revision = get_in(plan, ["preparation", "dispatch_revision"])

    assert {:ok, %{"status" => "opened"}} =
             MeetingPlan.open_trigger(
               group["group_id"],
               plan["meeting_plan_id"],
               "decision",
               revision,
               now: get_in(plan, ["preparation", "decision_at"])
             )

    assert {:ok, _} =
             MeetingPlan.record_decision(
               group["group_id"],
               plan["meeting_plan_id"],
               revision,
               "not_required"
             )

    payload = %{
      "group_id" => group["group_id"],
      "meeting_plan_id" => plan["meeting_plan_id"]
    }

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(payload, :claimed,
               now: plan["preparation"]["card_at"]
             )

    assert {:ok, sent_plan} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])
    assert get_in(sent_plan, ["preparation", "card_status"]) == "sent"

    assert {:ok, [command]} =
             SalixIM.RouterConversationProjection.list_group_router_messages(group["group_id"])

    assert command["metadata"]["event_type"] == "provider.output"

    # The delivery participant sits on the Router conversation, built by the
    # factory: notification_filter messages=none is the leak gate.
    assert {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group["group_id"])

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group["group_id"],
               conversation["conversation_id"],
               limit: 100
             )

    card_participant =
      Enum.find(participants, fn participant ->
        participant["actor_type"] == "provider" and
          get_in(participant, ["payload", "channel_id"]) == "channel-meetings"
      end)

    assert card_participant
    assert get_in(card_participant, ["notification_filter", "messages"]) == "none"

    # An occurrence replay reuses the log command without a second card.
    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(payload, :exists,
               now: plan["preparation"]["card_at"]
             )

    assert {:ok, replayed} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])
    assert get_in(replayed, ["preparation", "card_status"]) == "sent"
  end

  test "a successfully read item without an event link settles instead of sending an incomplete card",
       %{group: group} do
    # The event link is absent at the provider (equivalently: removed by the
    # HTTPS safety validation). The read succeeds — this is a durable fact of
    # the item, not a transient error — and the card must settle unsent
    # rather than ship without "Open event".
    linkless =
      standalone_event("Linkless meeting", 1, "2030-01-02T00:00:00Z")
      |> Map.delete("htmlLink")
      |> Map.merge(%{"id" => "linkless-event", "iCalUID" => "linkless@example.com"})

    stub_list([linkless], "sync-card-linkless")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    start_ms = get_in(plan, ["effective_occurrence", "start_ms"])

    assert {:settle, :missing_event_link} =
             MeetingPlan.card_action(group["group_id"], plan["meeting_plan_id"],
               now: start_ms - 60_000
             )

    assert {:ok, settled} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])
    assert get_in(settled, ["preparation", "card_status"]) == "abandoned"

    # The receiver settles the occurrence without queuing anything.
    payload = %{
      "group_id" => group["group_id"],
      "meeting_plan_id" => plan["meeting_plan_id"]
    }

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(payload, :claimed,
               now: plan["preparation"]["card_at"]
             )

    assert {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group["group_id"])

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group["group_id"],
               conversation["conversation_id"],
               limit: 100
             )

    refute Enum.any?(participants, &(&1["actor_type"] == "provider"))
  end

  test "a transient calendar-item read failure retries instead of settling a degraded card", %{
    group: group
  } do
    stub_list([moved_exception(), recurring_master()], "sync-card-transient")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    start_ms = get_in(plan, ["effective_occurrence", "start_ms"])

    # One 503 on the calendar-item read: the degraded context would render a
    # placeholder title with no event link. That must be a transient error
    # (schedule claim retained, retried next sweep) — never a card, and
    # never a permanent "sent".
    :ok =
      S3.Fake.set_fault(
        {:fail, 503, :get,
         {:prefix,
          SalixStore.Keys.ctl_calendar_items_prefix(group["group_id"], group["calendar_id"])}}
      )

    assert {:error, {:calendar_item_unavailable, _reason}} =
             MeetingPlan.card_action(group["group_id"], plan["meeting_plan_id"],
               now: start_ms - 60_000
             )

    assert {:ok, unsettled} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])
    refute get_in(unsettled, ["preparation", "card_status"])

    # The fault clears; the retry renders the complete card.
    assert {:ok, action} =
             MeetingPlan.card_action(group["group_id"], plan["meeting_plan_id"],
               now: start_ms - 60_000
             )

    assert action["text"] =~ "Open event"
    refute action["text"] =~ "Calendar meeting"
  end

  test "the card window closes at meeting start and never late-posts", %{group: group} do
    stub_list([moved_exception(), recurring_master()], "sync-card-window")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    start_ms = get_in(plan, ["effective_occurrence", "start_ms"])

    # Inside the window: a complete deterministic card aimed at the trusted
    # target, keyed per occurrence with no dispatch revision.
    assert {:ok, action} =
             MeetingPlan.card_action(group["group_id"], plan["meeting_plan_id"],
               now: start_ms - 60_000
             )

    assert action["provider"] == "slack"
    assert action["params"] == get_in(plan, ["publication_target", "params"])
    assert action["idempotency_key"] == "calendar-briefing:" <> plan["meeting_plan_id"]
    assert action["text"] =~ "📅 Weekly planning"
    assert action["text"] =~ "Join Meet"
    refute action["text"] =~ "Known facts"

    # At/after start: settle abandoned, never send.
    assert {:settle, :window_passed} =
             MeetingPlan.card_action(group["group_id"], plan["meeting_plan_id"], now: start_ms)

    assert {:ok, settled} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])
    assert get_in(settled, ["preparation", "card_status"]) == "abandoned"

    assert {:settle, :already_settled} =
             MeetingPlan.card_action(group["group_id"], plan["meeting_plan_id"],
               now: start_ms - 60_000
             )
  end

  test "one failing event becomes a placeholder instead of failing the whole group scan", %{
    group: group
  } do
    poisoned =
      standalone_event("Poisoned meeting", 1, "2030-01-02T00:00:00Z")
      |> Map.merge(%{
        "id" => "poisoned-event",
        "iCalUID" => "poisoned@example.com",
        "start" => %{"dateTime" => "2030-01-14T08:00:00Z", "timeZone" => "Etc/UTC"},
        "end" => %{"dateTime" => "2030-01-14T09:00:00Z", "timeZone" => "Etc/UTC"}
      })

    healthy =
      standalone_event("Healthy meeting", 1, "2030-01-02T00:00:00Z")
      |> Map.merge(%{"id" => "healthy-event", "iCalUID" => "healthy@example.com"})

    stub_list([poisoned, healthy], "sync-placeholder")
    assert {:ok, _} = sync_source(group)

    assert {:ok, events} = MeetingCalendar.list(group, range_start(), range_end())
    assert [planned_poisoned, planned_healthy] = Enum.sort_by(events, & &1["start_ms"])
    assert planned_poisoned["title"] == "Poisoned meeting"
    assert Ids.valid_meeting_plan_id?(planned_poisoned["meeting_plan_id"])

    # One event's durable plan read fails transiently. The whole group used
    # to fail (freezing the projection); now the event stays present as an
    # unjoinable placeholder, and its neighbor is untouched. Presence in the
    # fresh set is load-bearing: absence would start the one-way recovery
    # abandon clock for a merely-transient storage error.
    :ok =
      S3.Fake.set_fault(
        {:fail, 503, :get,
         SalixStore.Keys.ctl_meeting_plan(
           group["group_id"],
           planned_poisoned["meeting_plan_id"]
         )}
      )

    assert {:ok, events} = MeetingCalendar.list(group, range_start(), range_end())
    assert [placeholder, still_healthy] = Enum.sort_by(events, & &1["start_ms"])

    assert placeholder["event_id"] == planned_poisoned["event_id"]
    assert placeholder["occurrence_ref"] == planned_poisoned["occurrence_ref"]
    assert is_binary(placeholder["prepare_error"])
    refute Map.has_key?(placeholder, "meet_url")
    refute Map.has_key?(placeholder, "meeting_plan_id")

    assert still_healthy["meeting_plan_id"] == planned_healthy["meeting_plan_id"]
    assert still_healthy["meet_url"] == planned_healthy["meet_url"]

    # The transient fault clears and the next scan restores the real event.
    assert {:ok, events} = MeetingCalendar.list(group, range_start(), range_end())
    assert [restored, _healthy] = Enum.sort_by(events, & &1["start_ms"])
    assert restored["meeting_plan_id"] == planned_poisoned["meeting_plan_id"]
    assert restored["meet_url"]
  end

  test "an unfiltered Router research message has no provider delivery target", %{
    group: group
  } do
    stub_list([moved_exception(), recurring_master()], "sync-delivery")
    assert {:ok, _} = sync_source(group)

    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group["group_id"],
               plan["conversation_id"],
               limit: 100
             )

    refute Enum.any?(participants, &(&1["actor_type"] == "provider"))

    router =
      Enum.find(
        participants,
        &(&1["actor_type"] == "agent" and
            get_in(&1, ["notification_filter", "messages"]) == "all")
      )

    assert {:ok, briefing} =
             ConversationServer.append_group_conversation_agent_message(
               group["group_id"],
               plan["conversation_id"],
               router["agent_id"],
               %{
                 "content" => "Pre-meeting briefing for all participants.",
                 "client_request_id" => "meeting-provider-briefing:#{event["meeting_plan_id"]}"
               }
             )

    assert {:ok, persisted} =
             Conversations.get_group_conversation_message(
               group["group_id"],
               plan["conversation_id"],
               briefing["message_id"]
             )

    refute Map.has_key?(persisted, "delivery_filter")

    assert {:ok, %{"deliveries" => []}} =
             Conversations.group_conversation_delivery_status(
               group["group_id"],
               plan["conversation_id"],
               message_id: briefing["message_id"],
               limit: 100
             )
  end

  test "CalendarContext writes synchronously rotate meeting preparation and fence old Router work",
       %{group: group, router_id: router_id} do
    stub_list([moved_exception(), recurring_master()], "sync-context")
    assert {:ok, _} = sync_source(group)

    worker_id = Ids.new_agent_id(group["group_id"])

    SalixAgent.TestSupport.create_control_agent!(worker_id, %{
      "tenant_id" => group["tenant_id"],
      "group_id" => group["group_id"],
      "name" => "Research Worker",
      "role" => "worker"
    })

    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, initial_plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    calendar_params = %{
      "calendar_id" => group["calendar_id"],
      "range_start_ms" => range_start(),
      "range_end_ms" => range_end(),
      "limit" => 10
    }

    item_params = %{
      "calendar_id" => group["calendar_id"],
      "calendar_item_id" => event["calendar_item_id"],
      "occurrence_ref" => event["occurrence_ref"]
    }

    assert {:ok,
            %{
              "data" => [
                %{
                  "calendar_context" => %{"revision" => 0},
                  "occurrence" => %{"occurrence_ref" => occurrence_ref}
                }
              ]
            }} = SalixAgent.Calendar.list_items(router_id, calendar_params)

    assert occurrence_ref == event["occurrence_ref"]

    assert {:ok, %{"calendar_context" => %{"revision" => 0}}} =
             SalixAgent.Calendar.get_item(worker_id, item_params)

    assert {:ok, %{"revision" => 1}} =
             SalixAgent.Calendar.update_context(worker_id, %{
               "calendar_id" => group["calendar_id"],
               "occurrence_ref" => event["occurrence_ref"],
               "expected_revision" => 0,
               "background" => "Initial Worker context"
             })

    assert {:ok, plan_at_revision_one} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    revision_one = get_in(plan_at_revision_one, ["preparation", "dispatch_revision"])
    refute revision_one == get_in(initial_plan, ["preparation", "dispatch_revision"])

    assert {:ok, %{"status" => "opened"}} =
             MeetingPlan.open_trigger(
               group["group_id"],
               event["meeting_plan_id"],
               "decision",
               revision_one,
               now: get_in(plan_at_revision_one, ["preparation", "decision_at"])
             )

    old_schedule_ids =
      plan_at_revision_one
      |> get_in(["preparation", "schedule_ids"])
      |> Map.values()
      |> Enum.sort()

    # Simulate the crash window after Calendar CAS commits but before the
    # salix_web coordinator can reconcile MeetingPlan.
    assert {:ok, %{"revision" => 2}} =
             AgentAPI.update_context(group["group_id"], %{
               "calendar_id" => group["calendar_id"],
               "occurrence_ref" => event["occurrence_ref"],
               "expected_revision" => 1,
               "background" => "Router revision two",
               "actor" => %{"actor_type" => "agent", "agent_id" => router_id}
             })

    assert {:ok, unreconciled_plan} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    assert get_in(unreconciled_plan, ["preparation", "dispatch_revision"]) == revision_one

    assert {:error, :stale_dispatch_revision} =
             MeetingPlan.record_decision(
               group["group_id"],
               event["meeting_plan_id"],
               revision_one,
               "required",
               %{"facts" => ["obsolete checkpoint"]}
             )

    assert {:error, :conflict} =
             SalixAgent.Calendar.update_context(worker_id, %{
               "calendar_id" => group["calendar_id"],
               "occurrence_ref" => event["occurrence_ref"],
               "expected_revision" => 1,
               "background" => "Stale Worker write"
             })

    assert {:ok, %{"calendar_context" => current_context}} =
             SalixAgent.Calendar.get_item(worker_id, item_params)

    assert current_context["revision"] == 2
    assert current_context["background"] == "Router revision two"

    assert {:ok, %{"revision" => 3}} =
             SalixAgent.Calendar.update_context(worker_id, %{
               "calendar_id" => group["calendar_id"],
               "occurrence_ref" => event["occurrence_ref"],
               "expected_revision" => current_context["revision"],
               "background" => "Worker revision three"
             })

    assert {:ok, current_plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    refute current_plan["revision"] == plan_at_revision_one["revision"]

    new_schedule_ids =
      current_plan
      |> get_in(["preparation", "schedule_ids"])
      |> Map.values()
      |> Enum.sort()

    assert current_plan["preparation"]["schedule_ids"] |> Map.keys() |> Enum.sort() ==
             ~w(card deadline_fence decision personal publication)

    refute new_schedule_ids == old_schedule_ids
    for id <- old_schedule_ids, do: assert({:error, :not_found} = Schedules.get(id))

    current_dispatch = get_in(current_plan, ["preparation", "dispatch_revision"])

    assert {:ok, %{"status" => "opened"}} =
             MeetingPlan.open_trigger(
               group["group_id"],
               event["meeting_plan_id"],
               "decision",
               current_dispatch,
               now: get_in(current_plan, ["preparation", "decision_at"])
             )

    assert {:ok, _decided} =
             MeetingPlan.record_decision(
               group["group_id"],
               event["meeting_plan_id"],
               current_dispatch,
               "required",
               %{"facts" => ["Persisted partial finding"]}
             )

    # A second committed-Calendar/unreconciled-MeetingPlan window must fence
    # the Router's external publication action.
    assert {:ok, %{"revision" => 4}} =
             AgentAPI.update_context(group["group_id"], %{
               "calendar_id" => group["calendar_id"],
               "occurrence_ref" => event["occurrence_ref"],
               "expected_revision" => 3,
               "background" => "Context changed after the checkpoint",
               "actor" => %{"actor_type" => "agent", "agent_id" => worker_id}
             })

    assert {:ok, %{"status" => "stale"}} =
             MeetingPlan.open_trigger(
               group["group_id"],
               event["meeting_plan_id"],
               "publication",
               current_dispatch,
               now: get_in(current_plan, ["preparation", "publish_start_at"])
             )

    assert {:ok, final_plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    refute Map.has_key?(final_plan["preparation"], "publication_message_id")

    assert {:ok, %{"data" => [%{"calendar_context" => router_context}]}} =
             SalixAgent.Calendar.list_items(router_id, calendar_params)

    assert {:ok, %{"calendar_context" => worker_context}} =
             SalixAgent.Calendar.get_item(worker_id, item_params)

    assert router_context == worker_context
    assert worker_context["revision"] == 4
  end

  test "Google sync gives Router a readable report submission action with event and effective Meet links",
       %{group: group} do
    exception =
      moved_exception()
      |> Map.put("hangoutLink", "https://meet.google.com/occurrence-room")

    stub_list([exception, recurring_master()], "sync-readable-card")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert event["meet_url"] == "https://meet.google.com/occurrence-room"

    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    revision = get_in(plan, ["preparation", "dispatch_revision"])

    assert {:ok, %{"status" => "opened"}} =
             MeetingPlan.open_trigger(
               group["group_id"],
               plan["meeting_plan_id"],
               "decision",
               revision,
               now: get_in(plan, ["preparation", "decision_at"])
             )

    assert {:ok, _} =
             MeetingPlan.record_decision(
               group["group_id"],
               plan["meeting_plan_id"],
               revision,
               "required",
               %{
                 "known_facts" => ["The agenda asks for product progress."],
                 "gaps" => ["Current metrics are still missing."]
               }
             )

    assert {:ok, publication} =
             MeetingPlan.open_trigger(
               group["group_id"],
               plan["meeting_plan_id"],
               "publication",
               revision,
               now: get_in(plan, ["preparation", "publish_start_at"])
             )

    action = publication["publication_action"]

    assert {:ok, _saved} =
             MeetingPlan.prepare_report(
               group["group_id"],
               plan["meeting_plan_id"],
               revision,
               action["draft"],
               now: plan["preparation"]["publish_start_at"]
             )

    assert {:ok, notice} =
             MeetingPlan.card_action(group["group_id"], plan["meeting_plan_id"],
               now: plan["preparation"]["card_at"]
             )

    content = notice["text"]

    assert action["tool"] == "meeting.preparation.publish_report"

    assert action["params"] == %{
             "meeting_plan_id" => plan["meeting_plan_id"],
             "dispatch_revision" => revision
           }

    assert content =~ "📅 Weekly planning"

    assert content =~
             "[Open event](<https://www.google.com/calendar/event?eid=series%40example.com>)"

    assert content =~ "[Join Meet](<https://meet.google.com/occurrence-room>)"
    assert content =~ "Known facts\n• The agenda asks for product progress."
    refute content =~ "{"

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group["group_id"],
               plan["conversation_id"],
               limit: 100
             )

    refute Enum.any?(messages, &(get_in(&1, ["metadata", "provisional"]) == true))
  end

  test "Feishu MeetingCalendar retains its exact normalized send_text action without a provider participant",
       %{group: group} do
    feishu_group =
      group
      |> Map.merge(%{
        "provider" => "feishu",
        "connect_id" => "  feishu-calendar-connect  ",
        "chat_id" => "  oc_meeting_target  ",
        "mentions" => %{
          "mode" => "users",
          "users" => [
            %{
              "user_id" => "  ou_ada  ",
              "name" => "  Ada Lovelace  ",
              "untrusted_destination" => "oc_attacker"
            },
            %{"user_id" => "ou_grace", "name" => "Grace Hopper"}
          ]
        }
      })
      |> Map.delete("channel_id")
      |> Map.delete("thread_ts")

    stub_list([moved_exception(), recurring_master()], "sync-feishu-action")
    assert {:ok, _} = sync_source(feishu_group)
    assert {:ok, [event]} = MeetingCalendar.list(feishu_group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    expected_target = %{
      "provider" => "feishu",
      "tool" => "im_api.feishu.send_text",
      "params" => %{
        "connect_id" => "feishu-calendar-connect",
        "receive_id" => "oc_meeting_target",
        "receive_id_type" => "chat_id",
        "mentions" => [
          %{"user_id" => "ou_ada", "name" => "Ada Lovelace"},
          %{"user_id" => "ou_grace", "name" => "Grace Hopper"}
        ]
      }
    }

    assert plan["publication_target"] == expected_target

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group["group_id"],
               plan["conversation_id"],
               limit: 100
             )

    refute Enum.any?(participants, &(&1["actor_type"] == "provider"))

    revision = get_in(plan, ["preparation", "dispatch_revision"])

    assert {:ok, %{"status" => "opened"}} =
             MeetingPlan.open_trigger(
               group["group_id"],
               plan["meeting_plan_id"],
               "decision",
               revision,
               now: get_in(plan, ["preparation", "decision_at"])
             )

    assert {:ok, _} =
             MeetingPlan.record_decision(
               group["group_id"],
               plan["meeting_plan_id"],
               revision,
               "required",
               %{"known_facts" => ["Agenda confirmed."], "gaps" => []}
             )

    assert {:ok, publication} =
             MeetingPlan.open_trigger(
               group["group_id"],
               plan["meeting_plan_id"],
               "publication",
               revision,
               now: get_in(plan, ["preparation", "publish_start_at"])
             )

    action = publication["publication_action"]
    assert action["tool"] == "im_api.feishu.send_text"
    assert action["params"] == expected_target["params"]
    assert action["content_param"] == "text"
    assert is_binary(action["draft"])
    assert is_binary(action["instruction"])
    assert Enum.sort(Map.keys(action)) == ~w(content_param draft instruction params tool)
    refute Jason.encode!(action["params"]) =~ "oc_attacker"
  end

  for access_profile <- ~w(free_busy redacted) do
    test "#{access_profile} Google source does not disclose provider details after sync", %{
      group: group
    } do
      access_profile = unquote(access_profile)

      assert {:ok, calendar} =
               Calendar.ensure_calendar(
                 group["group_id"],
                 %{"kind" => "meeting_privacy_test", "access_profile" => access_profile},
                 %{"name" => "Restricted meetings", "default_time_zone" => "UTC"}
               )

      assert {:ok, source} =
               Calendar.ensure_source(group["group_id"], calendar["calendar_id"], %{
                 "adapter" => "google_calendar",
                 "adapter_contract_id" => GoogleCalendarSource.adapter_contract_id(),
                 "source_locator" => %{
                   "connection_id" => "ca-cal",
                   "external_calendar_id" => "restricted-#{access_profile}"
                 },
                 "access_profile" => access_profile
               })

      restricted_group = %{
        group
        | "calendar_id" => calendar["calendar_id"],
          "calendars" => [
            %{
              "account_id" => "ca-cal",
              "calendar_id" => "restricted-#{access_profile}",
              "source_id" => source["source_id"]
            }
          ]
      }

      private_title = "Private #{access_profile} roadmap"
      private_description = "Private #{access_profile} acquisition notes"
      private_conference_uri = "https://meet.google.com/private-#{access_profile}-room"

      private_calendar_uri =
        "https://www.google.com/calendar/event?eid=private-#{access_profile}"

      event =
        recurring_master()
        |> Map.put("summary", private_title)
        |> Map.put("description", private_description)
        |> Map.put("hangoutLink", private_conference_uri)
        |> Map.put("htmlLink", private_calendar_uri)

      stub_list([event], "sync-#{access_profile}")
      assert {:ok, _} = sync_source(restricted_group)

      assert {:ok, meeting_results} =
               MeetingCalendar.list(restricted_group, range_start(), range_end())

      assert {:ok, %{"data" => calendar_items}} =
               AgentAPI.list_items(group["group_id"], %{
                 "calendar_id" => calendar["calendar_id"],
                 "range_start_ms" => range_start(),
                 "range_end_ms" => range_end(),
                 "limit" => 50
               })

      assert calendar_items != []

      assert Enum.all?(calendar_items, &(get_in(&1, ["item", "copy_role"]) == "unknown"))

      query_payload =
        Jason.encode!(%{
          "meeting_results" => meeting_results,
          "calendar_items" => calendar_items
        })

      exposed_provider_details =
        Enum.filter(
          [private_title, private_description, private_conference_uri, private_calendar_uri],
          &String.contains?(query_payload, &1)
        )

      assert exposed_provider_details == []
      assert meeting_results == []

      assert Enum.all?(
               calendar_items,
               &(get_in(&1, ["item", "meeting_qualification", "item_eligible"]) == false)
             )

      assert Enum.all?(
               calendar_items,
               &(get_in(&1, ["item", "meeting_qualification", "item_reason"]) ==
                   "access_profile_restricted")
             )
    end
  end

  test "exact revalidation applies an instance refresh and rejects a moved start", %{group: group} do
    stub_list([moved_exception(), recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    stub_get(moved_exception())
    assert :ok = MeetingCalendar.revalidate(group, event)

    changed =
      moved_exception()
      |> put_in(["start", "dateTime"], "2030-01-14T12:00:00Z")
      |> put_in(["end", "dateTime"], "2030-01-14T13:00:00Z")

    stub_get(changed)
    assert {:error, :calendar_event_changed} = MeetingCalendar.revalidate(group, event)
  end

  test "exact revalidation rebuilds one expired Composio session without cancelling the plan", %{
    group: group
  } do
    current = standalone_event("Session recovery", 1, "2030-01-01T00:00:00Z")
    stub_list([current], "session-recovery-sync")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    MockExternalHTTP.stub_sequence("POST", @proxy_execute_path, [
      {404, %{"error" => %{"message" => "proxy session expired"}}},
      %{"status" => 200, "data" => current}
    ])

    assert :ok = MeetingCalendar.revalidate(group, event)
    assert provider_proxy_session_create_count() == 3
    assert provider_proxy_session_delete_count() == 3

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
  end

  test "repeated Composio session loss is operational and preserves the meeting plan", %{
    group: group,
    source: source
  } do
    current = standalone_event("Session unavailable", 1, "2030-01-01T00:00:00Z")
    stub_list([current], "session-unavailable-sync")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    MockExternalHTTP.stub_sequence("POST", @proxy_execute_path, [
      {404, %{"error" => %{"message" => "proxy session expired"}}},
      {404, %{"error" => %{"message" => "replacement session unavailable"}}}
    ])

    assert {:error, :composio_proxy_session_unavailable} =
             MeetingCalendar.revalidate(group, event)

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    assert {:ok, %{"status" => "active"}} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])
  end

  test "Composio session creation loss is operational and preserves the meeting plan", %{
    group: group,
    source: source
  } do
    current = standalone_event("Session creation unavailable", 1, "2030-01-01T00:00:00Z")
    stub_list([current], "session-creation-unavailable-sync")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    MockExternalHTTP.stub(
      "POST",
      @proxy_session_path,
      %{"error" => %{"message" => "proxy session creation unavailable"}},
      404
    )

    assert {:error, :composio_proxy_session_unavailable} =
             MeetingCalendar.revalidate(group, event)

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    assert {:ok, %{"status" => "active"}} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])
  end

  test "Google quota and permission 403 responses preserve distinct error provenance", %{
    group: group,
    source: source
  } do
    current = standalone_event("Quota recovery", 1, "2030-01-01T00:00:00Z")
    stub_list([current], "quota-recovery-sync")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{
        "status" => 403,
        "data" => %{
          "error" => %{
            "errors" => [%{"reason" => "userRateLimitExceeded"}],
            "message" => "quota exhausted"
          }
        }
      }
    )

    assert {:error, {:google_calendar_rate_limited, 403, ["userRateLimitExceeded"]}} =
             MeetingCalendar.revalidate(group, event)

    assert {:ok, %{"status" => "active"}} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    stub_get(current)
    assert :ok = MeetingCalendar.revalidate(group, event)

    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{
        "status" => 403,
        "data" => %{
          "error" => %{
            "errors" => [%{"reason" => "forbiddenForNonOrganizer"}],
            "message" => "permission denied"
          }
        }
      }
    )

    assert {:error, {:google_calendar_http, 403}} = MeetingCalendar.revalidate(group, event)

    assert {:ok, %{"status" => "active"}} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])
  end

  test "a stale collection copy cannot overwrite a newer exact refresh", %{group: group} do
    initial = standalone_event("Initial provider fact", 1, "2030-01-01T00:00:00Z")
    stub_list([initial], "single-sync-1")
    assert {:ok, _} = sync_source(group)

    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    newest = standalone_event("Newest exact provider fact", 3, "2030-01-03T00:00:00Z")
    stub_get(newest)
    assert :ok = MeetingCalendar.revalidate(group, event)

    exact_request =
      MockExternalHTTP.requests()
      |> Enum.filter(
        &(&1.path == @proxy_execute_path and
            String.ends_with?(&1.body["endpoint"] || "", "/events/standalone-event"))
      )
      |> List.last()

    assert exact_request.body["method"] == "GET"

    refute Enum.any?(
             MockExternalHTTP.requests(),
             &(&1.path == "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_GET")
           )

    assert {:ok, exact_item} =
             Calendar.get_item(
               group["group_id"],
               group["calendar_id"],
               event["calendar_item_id"]
             )

    assert get_in(exact_item, ["object", "title"]) == "Newest exact provider fact"
    assert get_in(exact_item, ["source_version", "sequence"]) == 3

    stale = standalone_event("Stale collection provider fact", 2, "2030-01-02T00:00:00Z")
    stub_list([stale], "single-sync-2")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [_same_event]} = MeetingCalendar.list(group, range_start(), range_end())

    assert {:ok, final_item} =
             Calendar.get_item(
               group["group_id"],
               group["calendar_id"],
               event["calendar_item_id"]
             )

    assert get_in(final_item, ["object", "title"]) == "Newest exact provider fact"
    assert get_in(final_item, ["source_version", "sequence"]) == 3
  end

  test "exact revalidation keeps copy selection within the enrolled source", %{
    group: group
  } do
    assert {:ok, organizer_source} =
             Calendar.ensure_source(group["group_id"], group["calendar_id"], %{
               "adapter" => "google_calendar",
               "adapter_contract_id" => GoogleCalendarSource.adapter_contract_id(),
               "source_locator" => %{
                 "connection_id" => "ca-unselected",
                 "external_calendar_id" => "unselected-calendar"
               },
               "access_profile" => "events_read"
             })

    stub_account(group["group_id"], "ca-unselected")
    stub_list([recurring_master()], "unselected-sync")

    assert {:ok, %{"sync_status" => "active"}} =
             Calendar.refresh_source(
               group["group_id"],
               group["calendar_id"],
               organizer_source["source_id"],
               %{
                 "group_id" => group["group_id"],
                 "object_type" => "Event",
                 "page_size" => 100
               }
             )

    stub_account(group["group_id"], "ca-cal")

    attendee_master =
      put_in(recurring_master(), ["organizer"], %{
        "self" => false,
        "email" => "owner@example.com"
      })

    stub_list([attendee_master], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    assert {:ok, selected_item} =
             Calendar.get_item(
               group["group_id"],
               group["calendar_id"],
               event["calendar_item_id"]
             )

    assert selected_item["copy_role"] == "attendee"

    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert plan["calendar_source_ids"] == [hd(group["calendars"])["source_id"]]

    refute Map.has_key?(
             MeetingPlan.current_context(plan)["calendar_item"],
             "unavailable"
           )

    attendee_instance =
      put_in(ordinary_instance(), ["organizer"], %{
        "self" => false,
        "email" => "owner@example.com"
      })

    stub_instances([attendee_instance])
    assert :ok = MeetingCalendar.revalidate(group, event)

    group_without_selected_source =
      put_in(group, ["calendars"], [
        %{
          "account_id" => "ca-unselected",
          "calendar_id" => "unselected-calendar",
          "source_id" => organizer_source["source_id"]
        }
      ])

    assert {:error, :calendar_event_cancelled} =
             MeetingCalendar.revalidate(group_without_selected_source, event)

    assert {:ok, cancelled} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert cancelled["status"] == "cancelled"
  end

  test "known instance exact refresh rejects a mismatched series or original slot", %{
    group: group
  } do
    stub_list([moved_exception(), recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    wrong_series = Map.put(moved_exception(), "recurringEventId", "another-series")
    stub_get(wrong_series)

    assert {:error, :calendar_event_not_found} = MeetingCalendar.revalidate(group, event)

    wrong_slot =
      put_in(
        moved_exception(),
        ["originalStartTime", "dateTime"],
        "2030-01-15T10:00:00Z"
      )

    stub_get(wrong_slot)
    assert {:error, :calendar_event_not_found} = MeetingCalendar.revalidate(group, event)
  end

  test "exact revalidation resolves an ordinary recurrence instance instead of reading its master",
       %{group: group} do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    instance = ordinary_instance()
    stub_instances([instance])
    assert :ok = MeetingCalendar.revalidate(group, event)

    request =
      MockExternalHTTP.requests()
      |> Enum.filter(
        &(&1.path == @proxy_execute_path and
            String.ends_with?(&1.body["endpoint"] || "", "/events/series/instances"))
      )
      |> List.last()

    assert proxy_parameter(request, "originalStart") == "2030-01-14T10:00:00Z"
    assert proxy_parameter(request, "showDeleted") == "true"
    assert proxy_parameter(request, "maxResults") == "250"
    assert proxy_parameter(request, "timeMin") == "2030-01-13T10:00:00Z"
    assert proxy_parameter(request, "timeMax") == "2030-01-15T10:00:00Z"
    assert length(instance_requests()) == 1

    refute Enum.any?(
             MockExternalHTTP.requests(),
             &(&1.path == "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_GET")
           )
  end

  test "exact revalidation rejects an occurrence-specific Meet URL change", %{group: group} do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    changed_instance =
      ordinary_instance()
      |> Map.put("hangoutLink", "https://meet.google.com/replacement-room")
      |> Map.put("sequence", 5)
      |> Map.put("updated", "2030-01-13T00:00:00Z")

    stub_instances([changed_instance])

    assert {:error, :calendar_event_changed} = MeetingCalendar.revalidate(group, event)

    assert {:ok, %{"status" => "cancelled"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
  end

  test "exact revalidation rejects an occurrence-specific non-Google room", %{group: group} do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    schedule_ids =
      ~w(decision publication deadline_fence)
      |> Enum.map(&get_in(plan, ["preparation", "schedule_ids", &1]))

    unsupported_instance =
      ordinary_instance()
      |> Map.put("hangoutLink", "https://video.example.test/unsupported-room")
      |> Map.put("sequence", 5)
      |> Map.put("updated", "2030-01-13T00:00:00Z")

    stub_instances([unsupported_instance])

    assert {:error, :calendar_event_cancelled} = MeetingCalendar.revalidate(group, event)

    assert {:ok, %{"status" => "cancelled"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    for schedule_id <- schedule_ids do
      assert {:error, :not_found} = Schedules.get(schedule_id)
    end
  end

  # Google pages `instances?originalStart=` before filtering: a series with more
  # instances than one page answers the leading pages with `items: []` and a
  # `nextPageToken`. Reading only the first page turned every ordinary instance
  # of a long-running series into `calendar_event_not_found` (staging stand-up,
  # 2026-09-04), which also cancelled the meeting plan every pass.
  test "exact revalidation follows empty instance pages to the matching instance", %{
    group: group
  } do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    instance = ordinary_instance()

    # The windowed lookup finds nothing (an instance moved out of its slot),
    # so the unwindowed listing is paged instead.
    stub_instances_pages(fn request, token ->
      cond do
        proxy_parameter(request, "timeMin") -> %{"items" => []}
        token == nil -> %{"items" => [], "nextPageToken" => "page-2"}
        token == "page-2" -> %{"items" => [], "nextPageToken" => "page-3"}
        token == "page-3" -> %{"items" => [instance]}
      end
    end)

    assert :ok = MeetingCalendar.revalidate(group, event)

    assert Enum.map(
             instance_requests(),
             &{proxy_parameter(&1, "timeMin"), proxy_parameter(&1, "pageToken")}
           ) ==
             [
               {"2030-01-13T10:00:00Z", nil},
               {nil, nil},
               {nil, "page-2"},
               {nil, "page-3"}
             ]
  end

  test "exact revalidation stops after the page budget without declaring the instance gone", %{
    group: group
  } do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    stub_instances_pages(fn _request, _token -> %{"items" => [], "nextPageToken" => "again"} end)

    assert {:error, :calendar_instances_page_budget_exhausted} =
             MeetingCalendar.revalidate(group, event)

    # One page budget, spent inside the windowed listing; no unwindowed rerun.
    assert length(instance_requests()) == 20

    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    refute plan["status"] == "cancelled"
  end

  test "a failed windowed lookup is not retried without the window", %{group: group} do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn _request ->
      %{
        "status" => 429,
        "data" => %{"error" => %{"code" => 429, "message" => "rateLimitExceeded"}}
      }
    end)

    assert {:error, _} = MeetingCalendar.revalidate(group, event)
    assert length(instance_requests()) == 1
  end

  test "ordinary recurrence exact refresh fails closed when the instance is absent", %{
    group: group
  } do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    stub_instances([])
    assert {:error, :calendar_event_not_found} = MeetingCalendar.revalidate(group, event)
  end

  test "ordinary recurrence exact refresh observes a newly cancelled instance", %{
    group: group
  } do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    cancelled =
      ordinary_instance()
      |> Map.put("status", "cancelled")
      |> Map.drop(["start", "end"])

    stub_instances([cancelled])
    assert {:error, :calendar_event_cancelled} = MeetingCalendar.revalidate(group, event)
  end

  test "ordinary recurrence exact refresh uses the earlier offset for a DST overlap", %{
    group: group
  } do
    master = %{
      "id" => "dst-overlap-series",
      "iCalUID" => "dst-overlap-series@example.com",
      "summary" => "DST overlap planning",
      "status" => "confirmed",
      "sequence" => 1,
      "updated" => "2030-10-20T00:00:00Z",
      "start" => %{
        "dateTime" => "2030-10-27T01:30:00-07:00",
        "timeZone" => "America/Los_Angeles"
      },
      "end" => %{
        "dateTime" => "2030-10-27T01:45:00-07:00",
        "timeZone" => "America/Los_Angeles"
      },
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=SU"],
      "hangoutLink" => "https://meet.google.com/dst-overlap-room",
      "organizer" => %{"self" => true, "email" => "owner@example.com"}
    }

    stub_list([master], "dst-overlap-sync")
    assert {:ok, _} = sync_source(group)

    range_start = unix_ms("2030-11-03T08:00:00Z")
    range_end = unix_ms("2030-11-03T10:00:00Z")
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start, range_end)

    instance = %{
      "id" => "dst-overlap-instance",
      "recurringEventId" => "dst-overlap-series",
      "status" => "confirmed",
      "originalStartTime" => %{
        "dateTime" => "2030-11-03T01:30:00-07:00",
        "timeZone" => "America/Los_Angeles"
      },
      "start" => %{
        "dateTime" => "2030-11-03T01:30:00-07:00",
        "timeZone" => "America/Los_Angeles"
      },
      "end" => %{
        "dateTime" => "2030-11-03T01:45:00-07:00",
        "timeZone" => "America/Los_Angeles"
      },
      "hangoutLink" => "https://meet.google.com/dst-overlap-room"
    }

    stub_instances([instance])
    assert :ok = MeetingCalendar.revalidate(group, event)

    request =
      MockExternalHTTP.requests()
      |> Enum.filter(
        &(&1.path == @proxy_execute_path and
            String.ends_with?(&1.body["endpoint"] || "", "/events/dst-overlap-series/instances"))
      )
      |> List.last()

    assert proxy_parameter(request, "originalStart") == "2030-11-03T01:30:00-07:00"
  end

  test "a source tombstone cancels the existing MeetingPlan and preparation schedules", %{
    group: group
  } do
    stub_list([moved_exception(), recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    schedule_ids =
      ~w(decision publication deadline_fence)
      |> Enum.map(&get_in(plan, ["preparation", "schedule_ids", &1]))

    stub_list([%{"id" => "series", "status" => "cancelled"}], "sync-2")
    assert {:ok, _} = sync_source(group)
    assert {:ok, []} = MeetingCalendar.list(group, range_start(), range_end())

    assert {:ok, cancelled} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert cancelled["status"] == "cancelled"

    for schedule_id <- schedule_ids do
      assert {:error, :not_found} = SalixCluster.Schedules.get(schedule_id)
    end
  end

  test "a recurring exception without a Meet URL retires its existing plan and schedules", %{
    group: group
  } do
    stub_list([recurring_master()], "sync-1")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    schedule_ids =
      ~w(decision deadline_fence card personal)
      |> Enum.map(&get_in(plan, ["preparation", "schedule_ids", &1]))

    for schedule_id <- schedule_ids do
      assert {:ok, _schedule} = Schedules.get(schedule_id)
    end

    exception = Map.delete(ordinary_instance(), "hangoutLink")

    stub_list(
      [exception, standalone_event("Surviving meeting", 1, "2030-01-02T00:00:00Z")],
      "sync-2"
    )

    assert {:ok, _} = sync_source(group)
    assert {:ok, [survivor]} = MeetingCalendar.list(group, range_start(), range_end())
    assert survivor["title"] == "Surviving meeting"

    assert {:ok, cancelled} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert cancelled["status"] == "cancelled"

    for schedule_id <- schedule_ids do
      assert {:error, :not_found} = Schedules.get(schedule_id)
    end
  end

  test "a recurring exception with a non-Google room does not materialize a plan", %{
    group: group
  } do
    exception =
      ordinary_instance()
      |> Map.put("hangoutLink", "https://video.example.test/room")

    stub_list([exception, recurring_master()], "sync-invalid-room")
    assert {:ok, _} = sync_source(group)
    assert {:ok, []} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, []} = S3.list_all("ctl/meeting_plans/#{group["group_id"]}/plans/")
  end

  test "an exception can add the Google Meet room when its recurring master has none", %{
    group: group
  } do
    master_without_room = Map.delete(recurring_master(), "hangoutLink")

    exception_with_room =
      ordinary_instance()
      |> Map.put("hangoutLink", "https://meet.google.com/exception-only-room")

    assert {:ok, normalized_master} = GoogleCalendarSource.normalize(master_without_room)
    assert normalized_master["meeting_qualification"]["item_eligible"] == true
    assert normalized_master["meeting_qualification"]["item_reason"] == "eligible"
    assert normalized_master["meeting_qualification"]["authorized"] == false
    assert normalized_master["meeting_qualification"]["reason"] == "no_supported_conference"

    stub_list([exception_with_room, master_without_room], "sync-exception-only-room")
    assert {:ok, _} = sync_source(group)

    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert event["meet_url"] == "https://meet.google.com/exception-only-room"

    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert plan["status"] == "planned"

    stub_get(exception_with_room)
    assert :ok = MeetingCalendar.revalidate(group, event)
  end

  test "unsupported Google recurrence is retained but cannot fabricate occurrences" do
    unsupported =
      recurring_master()
      |> Map.put("recurrence", ["RRULE:FREQ=MONTHLY;BYDAY=1MO"])

    assert {:ok, normalized} = GoogleCalendarSource.normalize(unsupported)
    assert normalized["normalization_state"] == "unsupported_timing"
    assert normalized["meeting_qualification"]["item_eligible"] == false
    assert normalized["meeting_qualification"]["item_reason"] == "unsupported_timing"
    assert normalized["meeting_qualification"]["authorized"] == false
    assert normalized["meeting_qualification"]["reason"] == "unsupported_timing"
    assert normalized["object"]["recurrenceRules"] == []
  end

  test "Google weekly recurrence with an explicit week start creates a MeetingPlan", %{
    group: group
  } do
    recurring =
      recurring_master()
      |> Map.put("summary", "Comma Team's Stand-up Meeting")
      |> Map.put("recurrence", ["RRULE:FREQ=WEEKLY;WKST=SU;BYDAY=MO,TH,FR"])

    assert {:ok, normalized} = GoogleCalendarSource.normalize(recurring)
    assert normalized["normalization_state"] == "complete"

    assert normalized["object"]["recurrenceRules"] == [
             %{
               "@type" => "RecurrenceRule",
               "frequency" => "weekly",
               "interval" => 1,
               "firstDayOfWeek" => "su",
               "byDay" => [
                 %{"@type" => "NDay", "day" => "mo"},
                 %{"@type" => "NDay", "day" => "th"},
                 %{"@type" => "NDay", "day" => "fr"}
               ]
             }
           ]

    stub_list([recurring], "sync-week-start")
    assert {:ok, _} = sync_source(group)

    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert event["title"] == "Comma Team's Stand-up Meeting"
    assert event["start_ms"] == unix_ms("2030-01-14T10:00:00Z")
    assert Ids.valid_meeting_plan_id?(event["meeting_plan_id"])

    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert plan["status"] == "planned"
    assert plan["occurrence_ref"] == event["occurrence_ref"]
  end

  test "a normalization contract upgrade replays a persisted WKST master into a MeetingPlan", %{
    group: group
  } do
    previous_contract =
      Application.get_env(:salix_web, :test_google_calendar_contract_id)

    on_exit(fn ->
      restore_env(
        :salix_web,
        :test_google_calendar_contract_id,
        previous_contract
      )
    end)

    Application.put_env(:salix_calendar, :source_adapters, %{
      "google_calendar" => GoogleCalendarSource,
      "versioned_google_calendar" => VersionedGoogleCalendarSource
    })

    recurring =
      recurring_master()
      |> Map.put("summary", "Comma Team's Stand-up Meeting")
      |> Map.put("recurrence", ["RRULE:FREQ=WEEKLY;WKST=SU;BYDAY=MO,TH,FR"])

    source_attrs = %{
      "adapter" => "versioned_google_calendar",
      "source_locator" => %{
        "connection_id" => "ca-cal",
        "external_calendar_id" => "provider-calendar-contract-upgrade"
      },
      "access_profile" => "events_read",
      "sync_policy" => %{"page_size" => 200}
    }

    Application.put_env(
      :salix_web,
      :test_google_calendar_contract_id,
      "google_calendar.events.v1"
    )

    assert {:ok, legacy_source} =
             Calendar.ensure_source(
               group["group_id"],
               group["calendar_id"],
               Map.put(source_attrs, "adapter_contract_id", "google_calendar.events.v1")
             )

    stub_list([recurring], "sync-legacy-wkst")
    assert {:ok, _} = refresh_source(group, legacy_source["source_id"])

    legacy_group = select_source(group, legacy_source["source_id"])
    assert {:ok, []} = MeetingCalendar.list(legacy_group, range_start(), range_end())

    assert {:ok, legacy_items} = Calendar.list_items(group["group_id"], group["calendar_id"])

    assert %{"normalization_state" => "unsupported_timing"} =
             item_from_source(legacy_items["data"], legacy_source["source_id"])

    assert {:ok, []} = S3.list_all("ctl/meeting_plans/#{group["group_id"]}/plans/")

    Application.put_env(
      :salix_web,
      :test_google_calendar_contract_id,
      GoogleCalendarSource.adapter_contract_id()
    )

    assert {:ok, current_source} =
             Calendar.ensure_source(
               group["group_id"],
               group["calendar_id"],
               Map.put(
                 source_attrs,
                 "adapter_contract_id",
                 GoogleCalendarSource.adapter_contract_id()
               )
             )

    refute current_source["source_id"] == legacy_source["source_id"]

    stub_list([recurring], "sync-current-wkst")
    assert {:ok, _} = refresh_source(group, current_source["source_id"])

    assert {:ok, current_items} = Calendar.list_items(group["group_id"], group["calendar_id"])
    current_item = item_from_source(current_items["data"], current_source["source_id"])
    assert current_item["normalization_state"] == "complete"

    assert get_in(current_item, ["object", "recurrenceRules", Access.at(0), "firstDayOfWeek"]) ==
             "su"

    current_group = select_source(group, current_source["source_id"])
    assert {:ok, [event]} = MeetingCalendar.list(current_group, range_start(), range_end())
    assert event["title"] == "Comma Team's Stand-up Meeting"

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    assert {:ok, [_plan]} = S3.list_all("ctl/meeting_plans/#{group["group_id"]}/plans/")
  end

  test "Google week start supports biweekly recurrence semantics", %{group: group} do
    biweekly =
      recurring_master()
      |> Map.put("recurrence", ["RRULE:FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=MO"])

    assert {:ok, normalized} = GoogleCalendarSource.normalize(biweekly)
    assert normalized["normalization_state"] == "complete"

    assert normalized["object"]["recurrenceRules"] == [
             %{
               "@type" => "RecurrenceRule",
               "frequency" => "weekly",
               "interval" => 2,
               "firstDayOfWeek" => "su",
               "byDay" => [%{"@type" => "NDay", "day" => "mo"}]
             }
           ]

    stub_list([biweekly], "sync-biweekly-week-start")
    assert {:ok, _} = sync_source(group)

    range_start = unix_ms("2030-01-21T00:00:00Z")
    range_end = unix_ms("2030-01-22T00:00:00Z")
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start, range_end)
    assert event["start_ms"] == unix_ms("2030-01-21T10:00:00Z")

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
  end

  test "Google biweekly recurrence does not create occurrences or plans before DTSTART", %{
    group: group,
    router_id: router_id
  } do
    cross_month =
      recurring_master()
      |> put_in(["start", "dateTime"], "2030-02-05T10:00:00Z")
      |> put_in(["end", "dateTime"], "2030-02-05T11:00:00Z")
      |> Map.put("recurrence", ["RRULE:FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,SU"])

    stub_list([cross_month], "sync-biweekly-before-dtstart")
    assert {:ok, _} = sync_source(group)

    assert {:ok, []} =
             MeetingCalendar.list(
               group,
               unix_ms("2030-01-31T00:00:00Z"),
               unix_ms("2030-02-04T00:00:00Z")
             )

    assert {:ok, []} = S3.list_all("ctl/meeting_plans/#{group["group_id"]}/plans/")

    assert {:ok, [event]} =
             MeetingCalendar.list(
               group,
               unix_ms("2030-02-05T00:00:00Z"),
               unix_ms("2030-02-06T00:00:00Z")
             )

    assert event["start_ms"] == unix_ms("2030-02-05T10:00:00Z")

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    pre_start_ref =
      put_in(
        event["occurrence_ref"],
        ["recurrence_key", "value"],
        "2030-02-03T10:00:00"
      )

    assert {:error, :occurrence_not_found} =
             SalixAgent.Calendar.update_context(router_id, %{
               "calendar_id" => group["calendar_id"],
               "occurrence_ref" => pre_start_ref,
               "expected_revision" => 0,
               "background" => "must not persist"
             })
  end

  test "Google recurrence always plans DTSTART when it does not match BYDAY", %{group: group} do
    first_occurrence =
      recurring_master()
      |> put_in(["start", "dateTime"], "2030-01-07T10:00:00Z")
      |> put_in(["end", "dateTime"], "2030-01-07T11:00:00Z")
      |> Map.put("recurrence", ["RRULE:FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=SU"])

    stub_list([first_occurrence], "sync-biweekly-dtstart")
    assert {:ok, _} = sync_source(group)

    assert {:ok, [event]} =
             MeetingCalendar.list(
               group,
               unix_ms("2030-01-07T00:00:00Z"),
               unix_ms("2030-01-08T00:00:00Z")
             )

    assert event["start_ms"] == unix_ms("2030-01-07T10:00:00Z")

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
  end

  test "Google explicit pre-DTSTART exception is a real occurrence", %{
    group: group,
    router_id: router_id
  } do
    master =
      recurring_master()
      |> put_in(["start", "dateTime"], "2030-02-05T10:00:00Z")
      |> put_in(["end", "dateTime"], "2030-02-05T11:00:00Z")
      |> Map.put("recurrence", ["RRULE:FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,SU"])

    exception = %{
      "id" => "series-pre-start-instance",
      "recurringEventId" => "series",
      "status" => "confirmed",
      "originalStartTime" => %{
        "dateTime" => "2030-02-03T10:00:00Z",
        "timeZone" => "Etc/UTC"
      },
      "start" => %{"dateTime" => "2030-02-03T11:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "2030-02-03T12:00:00Z", "timeZone" => "Etc/UTC"},
      "hangoutLink" => "https://meet.google.com/abc-defg-hij"
    }

    stub_list([exception, master], "sync-explicit-pre-dtstart")
    assert {:ok, _} = sync_source(group)

    assert {:ok, [event]} =
             MeetingCalendar.list(
               group,
               unix_ms("2030-02-03T00:00:00Z"),
               unix_ms("2030-02-04T00:00:00Z")
             )

    assert event["start_ms"] == unix_ms("2030-02-03T11:00:00Z")

    assert {:ok, %{"status" => "planned"}} =
             MeetingPlan.get(group["group_id"], event["meeting_plan_id"])

    assert {:ok, %{"revision" => 1}} =
             SalixAgent.Calendar.update_context(router_id, %{
               "calendar_id" => group["calendar_id"],
               "occurrence_ref" => event["occurrence_ref"],
               "expected_revision" => 0,
               "background" => "explicit source occurrence"
             })
  end

  test "Google collection completeness uses the Calendar contract enums" do
    event =
      recurring_master()
      |> Map.put("attendeesOmitted", true)

    assert {:ok, normalized} = GoogleCalendarSource.normalize(event)
    assert normalized["participant_set_state"] == "truncated"
    assert normalized["attachment_set_state"] == "not_requested"
  end

  test "Google htmlLink becomes a safe JSCalendar event Link" do
    event =
      recurring_master()
      |> Map.put(
        "htmlLink",
        "https://www.google.com/calendar/event?eid=series%40example.com"
      )

    assert GoogleCalendarSource.adapter_contract_id() == "google_calendar.events.v3"
    assert {:ok, normalized} = GoogleCalendarSource.normalize(event)

    assert get_in(normalized, ["object", "links", "event"]) == %{
             "@type" => "Link",
             "href" => "https://www.google.com/calendar/event?eid=series%40example.com",
             "rel" => "alternate"
           }
  end

  test "Google htmlLink normalization omits unsafe or non-Google URLs" do
    unsafe_links = [
      "http://www.google.com/calendar/event?eid=insecure",
      "javascript:alert(1)",
      "https://user@www.google.com/calendar/event?eid=userinfo",
      "https://calendar.example.test/event/foreign",
      "https://www.google.com:444/calendar/event?eid=port",
      "https://www.google.com/calendar/event?eid=bad\nvalue",
      "https://www.google.com/" <> String.duplicate("x", 4_100)
    ]

    for html_link <- unsafe_links do
      event = Map.put(recurring_master(), "htmlLink", html_link)
      assert {:ok, normalized} = GoogleCalendarSource.normalize(event)
      refute get_in(normalized, ["object", "links"])
    end
  end

  test "Google collection maps the documented 410 status to cursor expiry", %{
    source: source
  } do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{
        "status" => 410,
        "data" => %{"error" => %{"code" => 410, "message" => "Sync token is no longer valid"}}
      }
    )

    assert {:error, :cursor_expired} =
             GoogleCalendarSource.start_sync(
               source,
               %{
                 "group_id" => source["group_id"],
                 "object_type" => "Event",
                 "page_size" => 200
               },
               "expired-sync-token"
             )
  end

  @tag calendar_rebuild: true
  test "Google 410 recovery imports a new meeting after an unchanged event and creates its preparation schedules",
       %{group: group, source: source} do
    existing = standalone_event("Existing meeting", 1, "2030-01-01T00:00:00Z")
    stub_list([existing], "expired-sync-token")
    assert {:ok, _initial} = sync_source(group)
    assert {:ok, [before]} = MeetingCalendar.list(group, range_start(), range_end())

    added =
      standalone_event("New meeting", 1, "2030-01-02T00:00:00Z")
      |> Map.put("id", "new-event")
      |> Map.put("iCalUID", "new-event@example.com")
      |> Map.put("hangoutLink", "https://meet.google.com/new-meeting")

    MockExternalHTTP.stub_sequence("POST", @proxy_execute_path, [
      %{"status" => 410, "data" => %{"error" => %{"code" => 410}}},
      %{
        "status" => 200,
        "data" => %{"items" => [existing, added], "nextSyncToken" => "fresh-sync-token"}
      }
    ])

    assert {:ok, rebuilt} = sync_source(group)
    assert rebuilt["sync"]["generation"] == 2
    assert rebuilt["sync"]["completed_cursor"] == "fresh-sync-token"
    assert {:ok, events} = MeetingCalendar.list(group, range_start(), range_end())
    assert Enum.sort(Enum.map(events, & &1["title"])) == ["Existing meeting", "New meeting"]
    unchanged = Enum.find(events, &(&1["title"] == "Existing meeting"))
    assert unchanged["meeting_plan_id"] == before["meeting_plan_id"]
    added_event = Enum.find(events, &(&1["title"] == "New meeting"))
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], added_event["meeting_plan_id"])
    assert plan["status"] == "planned"

    for kind <- ~w(decision deadline_fence card personal) do
      assert {:ok, _schedule} = Schedules.get(plan["preparation"]["schedule_ids"][kind])
    end

    assert {:ok, refreshed_source} =
             Calendar.get_source(group["group_id"], group["calendar_id"], source["source_id"])

    assert refreshed_source["active_generation"] == 2
    [initial_request, expired_request, full_request] = provider_list_requests()
    assert proxy_parameter(initial_request, "syncToken") == nil
    assert proxy_parameter(expired_request, "syncToken") == "expired-sync-token"
    assert proxy_parameter(full_request, "syncToken") == nil
  end

  test "Google collection keeps one proxy session across pagination and deletes it at completion",
       %{
         source: source
       } do
    MockExternalHTTP.stub_sequence("POST", @proxy_execute_path, [
      %{
        "status" => 200,
        "data" => %{
          "items" => [standalone_event("Page one", 1, "2030-01-01T00:00:00Z")],
          "nextPageToken" => "page-2"
        }
      },
      %{
        "status" => 200,
        "data" => %{
          "items" => [standalone_event("Page two", 2, "2030-01-02T00:00:00Z")],
          "nextSyncToken" => "sync-2"
        }
      }
    ])

    query = %{
      "group_id" => source["group_id"],
      "object_type" => "Event",
      "page_size" => 200
    }

    assert {:ok, first_page} = GoogleCalendarSource.start_sync(source, query, "sync-1")
    assert is_binary(first_page["next_continuation"])
    assert provider_proxy_session_delete_count() == 0

    assert {:ok, second_page} =
             GoogleCalendarSource.continue_sync(source, query, first_page["next_continuation"])

    assert second_page["next_continuation"] == nil
    assert second_page["completed_cursor"] == "sync-2"
    assert provider_proxy_session_create_count() == 1
    assert provider_proxy_session_delete_count() == 1

    [first_request, second_request] = provider_list_requests()
    assert proxy_parameter(first_request, "syncToken") == "sync-1"
    assert proxy_parameter(first_request, "pageToken") == nil
    assert proxy_parameter(second_request, "syncToken") == "sync-1"
    assert proxy_parameter(second_request, "pageToken") == "page-2"
  end

  test "a legacy continuation creates a proxy session and an expired session is rebuilt once", %{
    source: source
  } do
    MockExternalHTTP.stub_sequence("POST", @proxy_execute_path, [
      {404, %{"error" => %{"message" => "session expired"}}},
      %{"status" => 200, "data" => %{"items" => [], "nextSyncToken" => "sync-2"}}
    ])

    continuation =
      %{"page_token" => "legacy-page", "sync_token" => "sync-1"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, %{"completed_cursor" => "sync-2"}} =
             GoogleCalendarSource.continue_sync(
               source,
               %{
                 "group_id" => source["group_id"],
                 "object_type" => "Event",
                 "page_size" => 200
               },
               continuation
             )

    assert provider_proxy_session_create_count() == 2
    assert length(provider_list_requests()) == 2
    assert provider_proxy_session_delete_count() == 2
  end

  test "an unavailable proxy session is recreated only once", %{source: source} do
    MockExternalHTTP.stub_sequence("POST", @proxy_execute_path, [
      {404, %{"error" => %{"message" => "session expired"}}},
      {404, %{"error" => %{"message" => "replacement also expired"}}}
    ])

    assert {:error, :not_found} =
             GoogleCalendarSource.start_sync(
               source,
               %{
                 "group_id" => source["group_id"],
                 "object_type" => "Event",
                 "page_size" => 200
               },
               nil
             )

    assert provider_proxy_session_create_count() == 2
    assert length(provider_list_requests()) == 2
  end

  test "Google collection rejects malformed items instead of activating an empty page", %{
    source: source
  } do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{
        "status" => 200,
        "data" => %{"items" => %{}, "nextSyncToken" => "unsafe-sync-token"}
      }
    )

    assert {:error, :invalid_google_calendar_response} =
             GoogleCalendarSource.start_sync(
               source,
               %{
                 "group_id" => source["group_id"],
                 "object_type" => "Event",
                 "page_size" => 200
               },
               nil
             )
  end

  test "UTC EXDATE is converted to the recurring event wall-time key" do
    event =
      recurring_master()
      |> put_in(["start"], %{
        "dateTime" => "2030-01-07T10:00:00+08:00",
        "timeZone" => "Asia/Shanghai"
      })
      |> put_in(["end"], %{
        "dateTime" => "2030-01-07T11:00:00+08:00",
        "timeZone" => "Asia/Shanghai"
      })
      |> Map.put("recurrence", [
        "RRULE:FREQ=WEEKLY;BYDAY=MO",
        "EXDATE:20300114T020000Z"
      ])

    assert {:ok, normalized} = GoogleCalendarSource.normalize(event)

    assert get_in(normalized, [
             "object",
             "recurrenceOverrides",
             "2030-01-14T10:00:00",
             "excluded"
           ]) == true
  end

  test "all-day duration follows calendar dates across a daylight-saving transition" do
    event = %{
      "id" => "all-day-dst",
      "iCalUID" => "all-day-dst@example.com",
      "summary" => "DST boundary",
      "status" => "confirmed",
      "start" => %{"date" => "2024-03-10"},
      "end" => %{"date" => "2024-03-11"},
      "organizer" => %{"self" => true, "email" => "owner@example.com"}
    }

    assert {:ok, normalized} =
             GoogleCalendarSource.normalize(event,
               default_time_zone: "America/Los_Angeles"
             )

    assert get_in(normalized, ["object", "start"]) == "2024-03-10"
    assert get_in(normalized, ["object", "duration"]) == "P1D"
    assert get_in(normalized, ["object", "timeZone"]) == "America/Los_Angeles"
    assert normalized["meeting_qualification"]["item_eligible"] == false
    assert normalized["meeting_qualification"]["item_reason"] == "all_day_event"
    assert normalized["meeting_qualification"]["authorized"] == false
    assert normalized["meeting_qualification"]["reason"] == "all_day_event"
  end

  test "local authorization rejects provider-shaped or foreign Calendar events", %{group: group} do
    local = %{
      "calendar_id" => group["calendar_id"],
      "calendar_item_id" => Ids.new_calendar_item_id(),
      "occurrence_ref" => %{"calendar_id" => group["calendar_id"]}
    }

    assert :ok = MeetingCalendar.authorize(group, local)

    assert {:error, :calendar_event_source_mismatch} =
             MeetingCalendar.authorize(group, %{
               "calendar_id" => "provider-calendar",
               "calendar_connected_account_id" => "ca-cal"
             })
  end

  test "calendar writeback preserves human notes, uses If-Match and is idempotent after a lost reply",
       %{group: group, source: source} do
    raw =
      standalone_event("Preparation meeting", 1, "2030-01-02T00:00:00Z")
      |> Map.merge(%{"etag" => "\"version-1\"", "description" => "<p>Human agenda</p>"})

    {item, event} = writeback_fixture(group, raw)
    report = "**Read** the proposal.\n\n- [PR #1507](https://github.com/AFK-surf/Comma/pull/1507)"

    assert {:ok, expected} =
             SalixMeet.CalendarPreparation.merge(raw["description"], report)

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if request["method"] == "PATCH",
        do: %{
          "status" => 200,
          "data" => Map.put(raw, "description", request["body"]["description"])
        },
        else: %{"status" => 200, "data" => raw}
    end)

    assert {:ok, %{"status" => "written"}} =
             GoogleCalendarSource.write_preparation(
               source,
               item,
               event,
               report
             )

    assert [patch] = calendar_patch_requests()
    assert patch.body["body"] == %{"description" => expected}
    assert expected =~ "<strong>Read</strong>"
    assert expected =~ "<ul>"
    assert expected =~ ~s(<a href="https://github.com/AFK-surf/Comma/pull/1507">PR #1507</a>)
    refute expected =~ "\\n"

    assert patch.body["endpoint"] ==
             "https://www.googleapis.com/calendar/v3/calendars/provider-calendar/events/standalone-event"

    assert %{"name" => "If-Match", "value" => "\"version-1\"", "type" => "header"} in patch.body[
             "parameters"
           ]

    assert %{"name" => "sendUpdates", "value" => "none", "type" => "query"} in patch.body[
             "parameters"
           ]

    # A response can be lost after Google accepted the first write. A caller
    # retry reads the provider again and observes equality before doing PATCH.
    stub_get(Map.merge(raw, %{"description" => expected, "etag" => "\"version-2\""}))

    assert {:ok, %{"status" => "unchanged"}} =
             GoogleCalendarSource.write_preparation(
               source,
               item,
               event,
               report
             )

    assert [_one_patch] = calendar_patch_requests()
  end

  test "writeback does not retry a concurrent edit or claim permission from read access", %{
    group: group,
    source: source
  } do
    raw =
      standalone_event("Preparation meeting", 1, "2030-01-02T00:00:00Z") |> Map.put("etag", "v1")

    {item, event} = writeback_fixture(group, raw)

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if request["method"] == "PATCH",
        do: %{"status" => 412},
        else: %{"status" => 200, "data" => raw}
    end)

    assert {:error, :calendar_event_changed} =
             GoogleCalendarSource.write_preparation(source, item, event, "Report")

    assert [_one_attempt] = calendar_patch_requests()

    stub_get(put_in(raw, ["organizer", "self"], false))

    assert {:error, :calendar_organizer_access_required} =
             GoogleCalendarSource.write_preparation(source, item, event, "Report")

    assert [_one_attempt] = calendar_patch_requests()

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if request["method"] == "PATCH",
        do: %{"status" => 403},
        else: %{"status" => 200, "data" => raw}
    end)

    assert {:error, :calendar_write_permission_required} =
             GoogleCalendarSource.write_preparation(source, item, event, "Report")

    assert length(calendar_patch_requests()) == 2
  end

  test "changed live agenda or meeting time blocks a stale preparation write", %{
    group: group,
    source: source
  } do
    raw =
      standalone_event("Preparation meeting", 1, "2030-01-02T00:00:00Z") |> Map.put("etag", "v1")

    {item, event} = writeback_fixture(group, raw)

    for changed <- [
          Map.put(raw, "description", "New human instructions"),
          put_in(raw, ["start", "dateTime"], "2030-01-14T10:30:00Z"),
          Map.put(raw, "summary", "Different meeting"),
          Map.put(raw, "hangoutLink", "https://meet.google.com/new-room")
        ] do
      stub_get(changed)

      assert {:error, :calendar_event_changed} =
               GoogleCalendarSource.write_preparation(source, item, event, "Stale report")
    end

    assert calendar_patch_requests() == []
  end

  test "attendee reads reject stale titles and meeting links", %{
    group: group,
    source: source
  } do
    raw = standalone_event("Reminder meeting", 1, "2030-01-02T00:00:00Z")
    {item, event} = writeback_fixture(group, raw)

    for changed <- [
          Map.put(raw, "summary", "New title"),
          Map.put(raw, "hangoutLink", "https://meet.google.com/new-room")
        ] do
      stub_get(changed)

      assert {:error, :calendar_event_changed} =
               GoogleCalendarSource.read_attendees(source, item, event)
    end
  end

  test "recurring writeback changes the exact moved instance and never the series", %{
    group: group,
    source: source
  } do
    master = recurring_master()

    instance =
      moved_exception()
      |> Map.merge(%{
        "summary" => master["summary"],
        "organizer" => master["organizer"],
        "etag" => "instance-v1"
      })

    stub_list([master, instance], "writeback-instance")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    assert {:ok, item} =
             Calendar.get_item(group["group_id"], group["calendar_id"], event["calendar_item_id"])

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if request["method"] == "PATCH",
        do: %{"status" => 200, "data" => instance},
        else: %{"status" => 200, "data" => instance}
    end)

    assert {:ok, occurrence} = SalixCalendar.Recurrence.resolve(item, event["occurrence_ref"])

    assert {:ok, %{"status" => "written"}} =
             GoogleCalendarSource.write_preparation(
               source,
               item,
               occurrence,
               "This occurrence only"
             )

    assert [patch] = calendar_patch_requests()
    assert String.ends_with?(patch.body["endpoint"], "/events/series-instance")
  end

  test "a persisted T-1 reminder settles without attendee lookup or public delivery", %{
    group: group
  } do
    raw = standalone_event("Retired reminder meeting", 1, "2030-01-02T00:00:00Z")
    {_item, event} = writeback_fixture(group, raw)
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    now = event["start_ms"] - :timer.minutes(1)

    payload = %{
      "group_id" => group["group_id"],
      "meeting_plan_id" => plan["meeting_plan_id"],
      "kind" => "reminder"
    }

    attrs = %{"receiver" => "meeting_publication", "run_at" => now, "payload" => payload}
    assert {:error, :invalid_schedule} = Schedules.create(Ids.new_schedule_id(), attrs)
    id = Ids.new_schedule_id()

    # A definition persisted before removal bypasses new-definition validation.
    assert {:ok, schedule} =
             SalixStore.Schedules.create(
               Map.merge(attrs, %{"id" => id, "created_at" => 1, "last_run" => nil}),
               now
             )

    requests_before = MockExternalHTTP.requests()
    assert {:ok, :undeliverable} = Schedules.fire(schedule, now, now: now)
    assert {:ok, :undeliverable} = SalixStore.ScheduleRuns.disposition(id, now)
    assert {:error, :not_found} = Schedules.get(id)
    assert {:ok, due} = Schedules.due(now + 1)
    refute Enum.any?(due, &(&1["id"] == id))
    assert {:ok, :undeliverable} = Schedules.fire(schedule, now, now: now)

    for status <- [:claimed, :exists] do
      assert {:ok, :undeliverable, :invalid_meeting_publication_payload} =
               Salix.Bindings.MeetingPublicationReceiver.receive(payload, status, now: now)
    end

    assert MockExternalHTTP.requests() == requests_before
  end

  test "a description-only recurring exception does not restart this occurrence's research", %{
    group: group
  } do
    stub_list([recurring_master()], "before-description-write")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, before_plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    assert {:ok, description} = SalixMeet.CalendarPreparation.merge(nil, "Shared preparation")
    written_instance = ordinary_instance() |> Map.put("description", description)
    stub_list([written_instance], "after-description-write")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [after_event]} = MeetingCalendar.list(group, range_start(), range_end())
    assert {:ok, after_plan} = MeetingPlan.get(group["group_id"], after_event["meeting_plan_id"])

    assert after_plan["preparation"]["dispatch_revision"] ==
             before_plan["preparation"]["dispatch_revision"]

    assert after_plan["preparation"]["schedule_ids"] == before_plan["preparation"]["schedule_ids"]
  end

  test "calendar writeback requires the current enrollment opt-in, including after a plan was saved",
       %{group: group} do
    previous = Application.get_env(:salix_meet, :calendar_autojoin_channels)
    on_exit(fn -> restore_env(:salix_meet, :calendar_autojoin_channels, previous) end)
    Application.put_env(:salix_meet, :calendar_autojoin_channels, [])
    group = Map.put(group, "calendar_writeback", true)
    raw = standalone_event("Opt-in meeting", 1, "2030-01-02T00:00:00Z") |> Map.put("etag", "v1")
    {_item, event} = writeback_fixture(group, raw)
    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    revision = plan["preparation"]["dispatch_revision"]

    assert {:ok, _} =
             MeetingPlan.open_trigger(
               group["group_id"],
               plan["meeting_plan_id"],
               "publication",
               revision,
               now: plan["preparation"]["publish_start_at"]
             )

    assert {:ok, saved} =
             MeetingPlan.prepare_report(
               group["group_id"],
               plan["meeting_plan_id"],
               revision,
               "Shared report",
               now: plan["preparation"]["publish_start_at"]
             )

    assert {:error, :calendar_writeback_not_authorized} =
             Salix.Bindings.MeetingCalendarPreparation.write(saved)

    assert calendar_patch_requests() == []

    entry = %{
      "connect_id" => group["connect_id"],
      "channel" => "meetings",
      "calendars" => ["Team"],
      "calendar_writeback" => true
    }

    identity = Map.take(group, ~w(connect_id group_id tenant_id provider))

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               entry,
               identity,
               group,
               System.system_time(:millisecond)
             )

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry])
    MockExternalHTTP.stub("POST", @proxy_execute_path, %{"status" => 200, "data" => raw})

    assert {:ok, %{"status" => "written"}} =
             Salix.Bindings.MeetingCalendarPreparation.write(saved)

    assert [_one_write] = calendar_patch_requests()

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [
      Map.delete(entry, "calendar_writeback")
    ])

    assert {:error, :calendar_writeback_not_authorized} =
             Salix.Bindings.MeetingCalendarPreparation.write(saved)

    assert [_one_write] = calendar_patch_requests()
  end

  test "the public report reaches Slack with source links, inert mentions and no link previews",
       %{
         group: group
       } do
    {plan, _raw} = personal_fixture(group)
    preparation = plan["preparation"]

    assert {:ok, _} =
             MeetingPlan.open_trigger(
               group["group_id"],
               plan["meeting_plan_id"],
               "publication",
               preparation["dispatch_revision"],
               now: preparation["publish_start_at"]
             )

    assert {:ok, _} =
             MeetingPlan.prepare_report(
               group["group_id"],
               plan["meeting_plan_id"],
               preparation["dispatch_revision"],
               "1. **发布准备**\n查看 <https://github.com/AFK-surf/Comma/pull/1507|PR #1507> <@UATTACKER>",
               now: preparation["publish_start_at"]
             )

    payload = %{
      "group_id" => group["group_id"],
      "meeting_plan_id" => plan["meeting_plan_id"],
      "kind" => "card"
    }

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(payload, :claimed,
               now: preparation["card_at"]
             )

    assert eventually(fn -> length(personal_posts()) == 1 end)
    [post] = personal_posts()
    assert post.body["channel"] == group["channel_id"]
    rendered = post.body["blocks"]
    assert rendered =~ ~s("url":"https://github.com/AFK-surf/Comma/pull/1507")
    assert rendered =~ ~s("text":"PR #1507")
    assert rendered =~ ~s("bold":true)
    assert post.body["text"] =~ "[Open event](<https://"
    assert post.body["text"] =~ ">) · [Join Meet](<https://meet.google.com/"
    assert post.body["unfurl_links"] == "false"
    assert post.body["unfurl_media"] == "false"
    refute rendered =~ "<@UATTACKER>"
  end

  test "personal reading materials reach isolated DMs while Calendar keeps the shared agenda",
       %{
         group: group
       } do
    group = Map.put(group, "calendar_writeback", true)
    {plan, raw} = personal_fixture(group)
    [entry] = Application.fetch_env!(:salix_meet, :calendar_autojoin_channels)
    entry = Map.put(entry, "calendar_writeback", true)
    Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry])

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               entry,
               group,
               group,
               System.system_time(:millisecond)
             )

    assert {:ok, context} = SalixMeet.PersonalPreparation.context(plan)
    assert Enum.map(context["recipients"], & &1["user_id"]) == ["UPENG", "UJINFEI"]

    assert {:ok, _} =
             MeetingPlan.open_trigger(
               group["group_id"],
               plan["meeting_plan_id"],
               "publication",
               plan["preparation"]["dispatch_revision"],
               now: plan["preparation"]["publish_start_at"]
             )

    assert {:ok, _} =
             MeetingPlan.prepare_report(
               group["group_id"],
               plan["meeting_plan_id"],
               plan["preparation"]["dispatch_revision"],
               "## 会议议题\n- Shared calendar preparation",
               now: plan["preparation"]["publish_start_at"]
             )

    for {user, report} <- [
          {"UPENG",
           "Peng public calendar advice\n\n- **Source** <https://example.slack.com/docs/TWORKSPACE/FCANVAS|昨天的站会>：会前准备的背景。\n- <https://example.slack.com/archives/CPUBLIC/p123456|回复问题>：没有收到回复时的复现步骤。 <@UATTACKER>"},
          {"UJINFEI", "JINFEI public Shape Up advice"}
        ] do
      evidence = %{
        "sources_label" => [
          "scope|#{group["connect_id"]}|@#{user}",
          "scope|#{group["connect_id"]}|CPUBLIC"
        ],
        "declassified" => []
      }

      assert {:ok, _} =
               SalixMeet.PersonalPreparation.submit(
                 plan,
                 context["connect_id"],
                 user,
                 report,
                 evidence
               )
    end

    payload = %{
      "group_id" => group["group_id"],
      "meeting_plan_id" => plan["meeting_plan_id"],
      "kind" => "personal"
    }

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(payload, :claimed,
               now: plan["preparation"]["card_at"]
             )

    assert eventually(fn -> length(personal_posts()) == 2 end)
    by_channel = Map.new(personal_posts(), &{&1.body["channel"], Jason.encode!(&1.body)})
    assert by_channel["DPENG"] =~ "Peng public calendar advice"
    peng_post = Enum.find(personal_posts(), &(&1.body["channel"] == "DPENG"))

    assert peng_post.body["blocks"] =~
             ~s("url":"https://example.slack.com/docs/TWORKSPACE/FCANVAS")

    assert peng_post.body["blocks"] =~ ~s("text":"昨天的站会")

    assert peng_post.body["blocks"] =~
             ~s("url":"https://example.slack.com/archives/CPUBLIC/p123456")

    assert peng_post.body["text"] =~ "没有收到回复时的复现步骤"
    assert Enum.all?(personal_posts(), &(&1.body["unfurl_links"] == "false"))
    assert Enum.all?(personal_posts(), &(&1.body["unfurl_media"] == "false"))
    refute by_channel["DPENG"] =~ "<@UATTACKER>"
    refute by_channel["DPENG"] =~ "JINFEI public"
    assert by_channel["DJINFEI"] =~ "JINFEI public Shape Up advice"
    refute by_channel["DJINFEI"] =~ "Peng public"

    assert {:ok, shared} =
             MeetingPlan.card_action(group["group_id"], plan["meeting_plan_id"],
               now: plan["preparation"]["card_at"]
             )

    assert shared["text"] =~ "Shared calendar preparation"
    refute shared["text"] =~ "Peng public"
    refute shared["text"] =~ "JINFEI public"
    refute shared["text"] =~ "回复问题"

    raw = Map.put(raw, "etag", "version-1")

    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      if request["method"] == "PATCH",
        do: %{
          "status" => 200,
          "data" => Map.put(raw, "description", request["body"]["description"])
        },
        else: %{"status" => 200, "data" => raw}
    end)

    assert {:ok, current_plan} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])

    assert {:ok, %{"status" => "written"}} =
             Salix.Bindings.MeetingCalendarPreparation.write(current_plan)

    assert [patch] = calendar_patch_requests()
    description = patch.body["body"]["description"]
    assert description =~ "<h2>会议议题</h2>"
    assert description =~ "Shared calendar preparation"
    refute description =~ "Peng public"
    refute description =~ "JINFEI public"
    refute description =~ "回复问题"
    refute description =~ "FCANVAS"

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(payload, :exists,
               now: plan["preparation"]["card_at"]
             )

    assert length(personal_posts()) == 2
  end

  test "ordinary provider notices retain Slack's default link preview policy", %{group: group} do
    {plan, _raw} = personal_fixture(group)

    assert {:ok, attrs} =
             SalixIM.ProviderConversationInput.participant_attrs(%{
               "metadata" => %{
                 "provider" => "slack",
                 "connect_id" => group["connect_id"],
                 "channel_id" => group["channel_id"]
               }
             })

    assert {:ok, participant} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group["group_id"],
               plan["conversation_id"],
               attrs
             )

    assert {:ok, _} =
             ConversationServer.send_provider_participant_message(
               group["group_id"],
               plan["conversation_id"],
               participant["participant_id"],
               %{
                 "idempotency_key" => "ordinary-link-notice",
                 "content" => [%{"type" => "text", "text" => "Read https://example.com/update"}],
                 "metadata" => %{"source" => "ordinary_notice"}
               }
             )

    assert eventually(fn -> length(personal_posts()) == 1 end)
    [post] = personal_posts()
    refute Map.has_key?(post.body, "unfurl_links")
    refute Map.has_key?(post.body, "unfurl_media")
  end

  test "public-source reports reject private, cross-connect and other-recipient sources with IFC off",
       %{group: group} do
    {plan, _raw} = personal_fixture(group)
    assert {:ok, context} = SalixMeet.PersonalPreparation.context(plan)
    connect = context["connect_id"]

    for labels <- [
          ["scope|#{connect}|@UJINFEI"],
          ["scope|another-connect|CPUBLIC"],
          ["scope|#{connect}|DPRIVATE"],
          ["scope|#{connect}|CPRIVATE"]
        ] do
      assert {:error, :meeting_personal_source_not_visible} =
               SalixMeet.PersonalPreparation.submit(plan, connect, "UPENG", "Advice", %{
                 "sources_label" => labels,
                 "declassified" => []
               })
    end

    assert {:ok, []} = SalixMeet.PersonalPreparation.pending(plan)
    assert personal_posts() == []
  end

  test "public-channel revocation withholds advice while attendees still receive reminders",
       %{group: group} do
    {plan, _raw} = personal_fixture(group)
    assert {:ok, context} = SalixMeet.PersonalPreparation.context(plan)
    connect = context["connect_id"]

    assert {:ok, _} =
             SalixMeet.PersonalPreparation.submit(plan, connect, "UPENG", "Public advice", %{
               "sources_label" => ["scope|#{connect}|@UPENG", "scope|#{connect}|CPUBLIC"],
               "declassified" => []
             })

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "CPUBLIC", "is_private" => true, "is_member" => true}
    })

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(
               %{
                 "group_id" => group["group_id"],
                 "meeting_plan_id" => plan["meeting_plan_id"],
                 "kind" => "personal"
               },
               :claimed,
               now: plan["preparation"]["card_at"]
             )

    assert eventually(fn -> length(personal_posts()) == 2 end)

    assert Enum.all?(personal_posts(), fn request ->
             request.body["text"] =~ "Personal preparation meeting" and
               not String.contains?(request.body["text"], ["Public advice", "Saved public advice"])
           end)

    assert {:ok, false} = SalixMeet.PersonalPreparation.has_pending?(plan)
  end

  test "attachment sharing is checked before first save and again before queue admission",
       %{group: group} do
    {plan, _raw} = personal_fixture(group)
    assert {:ok, context} = SalixMeet.PersonalPreparation.context(plan)
    connect = context["connect_id"]

    evidence = %{
      "sources_label" => ["scope|#{connect}|@UPENG", "scope|#{connect}|CPUBLIC"],
      "source_files" => [
        %{"connect_id" => connect, "channel" => "CPUBLIC", "file_id" => "FTRANSCRIPT"}
      ],
      "declassified" => []
    }

    revoked = %{"ok" => true, "file" => %{"id" => "FTRANSCRIPT", "channels" => []}}
    MockExternalHTTP.stub("POST", "/api/files.info", revoked)

    assert {:error, :meeting_shared_source_required} =
             SalixMeet.PersonalPreparation.submit(
               plan,
               connect,
               "UPENG",
               "Unavailable draft",
               evidence
             )

    assert {:ok, []} = SalixMeet.PersonalPreparation.pending(plan)

    MockExternalHTTP.stub("POST", "/api/files.info", %{
      "ok" => true,
      "file" => %{"id" => "FTRANSCRIPT", "channels" => ["CPUBLIC"]}
    })

    assert {:ok, _} =
             SalixMeet.PersonalPreparation.submit(
               plan,
               connect,
               "UPENG",
               "Saved public advice",
               evidence
             )

    assert {:ok, [saved]} = SalixMeet.PersonalPreparation.pending(plan)
    assert saved["report"]["source_files"] == evidence["source_files"]

    MockExternalHTTP.stub("POST", "/api/files.info", revoked)

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(
               %{
                 "group_id" => group["group_id"],
                 "meeting_plan_id" => plan["meeting_plan_id"],
                 "kind" => "personal"
               },
               :claimed,
               now: plan["preparation"]["card_at"]
             )

    assert eventually(fn -> length(personal_posts()) == 2 end)

    assert Enum.all?(personal_posts(), fn request ->
             request.body["text"] =~ "Personal preparation meeting" and
               not String.contains?(request.body["text"], ["Public advice", "Saved public advice"])
           end)

    assert {:ok, false} = SalixMeet.PersonalPreparation.has_pending?(plan)
  end

  test "personal publication rechecks opt-out and a cancelled live occurrence before a DM opens",
       %{group: group} do
    {plan, raw} = personal_fixture(group)
    assert {:ok, context} = SalixMeet.PersonalPreparation.context(plan)

    for user <- ["UPENG", "UJINFEI"] do
      evidence = %{
        "sources_label" => ["scope|#{group["connect_id"]}|@#{user}"],
        "declassified" => []
      }

      assert {:ok, _} =
               SalixMeet.PersonalPreparation.submit(
                 plan,
                 context["connect_id"],
                 user,
                 "Private advice for #{user}",
                 evidence
               )
    end

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "agent_group_id" => group["group_id"],
      "provider_context" => %{"connect_id" => group["connect_id"], "user_id" => "UPENG"}
    }

    assert {:ok, _} =
             SalixMeet.PersonalPreparation.set_preference(group["group_id"], origin, false)

    assert {:ok, roster} = Salix.Bindings.MeetingPersonalPreparation.roster(plan)
    assert {:ok, recipients} = Salix.Bindings.MeetingPersonalPreparation.recipients(plan, roster)
    assert Enum.map(recipients, & &1["user_id"]) == ["UJINFEI"]
    stub_get(Map.put(raw, "status", "cancelled"))

    payload = %{
      "group_id" => group["group_id"],
      "meeting_plan_id" => plan["meeting_plan_id"],
      "kind" => "personal"
    }

    assert {:ok, :fired} =
             Salix.Bindings.MeetingPublicationReceiver.receive(payload, :claimed,
               now: plan["preparation"]["card_at"]
             )

    assert personal_posts() == []
    refute Enum.any?(MockExternalHTTP.requests(), &(&1.path == "/api/conversations.open"))
  end

  @tag :personal_pagination
  test "29 attendees receive reminders without research in bounded pages through one schedule", %{
    group: group
  } do
    names = Enum.map(1..29, &("p" <> String.pad_leading(to_string(&1), 2, "0")))
    {plan, _raw} = personal_fixture(group, names)
    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:ok, :pending} = Schedules.fire(schedule, at, now: at)
    assert {:ok, _} = Schedules.get(schedule_id)
    assert eventually(fn -> length(personal_posts()) == 20 end)
    assert {:ok, :already_fired} = finish_personal_schedule(schedule, at, 1_000)
    assert {:error, :not_found} = Schedules.get(schedule_id)
    assert eventually(fn -> length(personal_posts()) == 29 end)

    assert MapSet.new(Enum.map(personal_posts(), & &1.body["channel"])) ==
             MapSet.new(Enum.map(names, &("D" <> String.upcase(&1))))

    assert personal_lookups() == 58
    assert {:ok, false} = SalixMeet.PersonalPreparation.research_complete?(plan)

    assert Enum.all?(personal_posts(), fn request ->
             request.body["text"] =~ "Personal preparation meeting" and
               request.body["text"] =~ "https://meet.google.com/standalone-room"
           end)

    assert {:ok, false} = SalixMeet.PersonalPreparation.has_pending?(plan)
  end

  @tag :personal_pagination
  test "an empty first recipient page does not hide later eligible attendees", %{group: group} do
    names = Enum.map(1..20, &("missing" <> to_string(&1))) ++ ["peng", "jinfei"]
    {plan, _raw} = personal_fixture(group, names)
    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:ok, :pending} = Schedules.fire(schedule, at, now: at)
    assert personal_posts() == []
    assert personal_lookups() == 20
    assert {:ok, :already_fired} = finish_personal_schedule(schedule, at, 1_000)
    assert eventually(fn -> length(personal_posts()) == 2 end)
    assert personal_lookups() == 24
  end

  test "a Google group invite adds current user members across Directory pages", %{group: group} do
    {plan, raw} = personal_fixture(group, ["peng", "developer"])
    stub_group_account(group)

    stub_group_proxy(raw, fn endpoint, token ->
      cond do
        String.ends_with?(endpoint, "/groups/peng%40example.com/members") ->
          %{"status" => 404, "data" => %{}}

        String.ends_with?(endpoint, "/groups/developer%40example.com/members") and is_nil(token) ->
          %{
            "status" => 200,
            "data" => %{
              "members" => [%{"email" => "nested@example.com", "type" => "GROUP"}],
              "nextPageToken" => "second"
            }
          }

        String.ends_with?(endpoint, "/groups/developer%40example.com/members") ->
          %{
            "status" => 200,
            "data" => %{
              "members" => [%{"email" => "jinfei@example.com", "type" => "USER"}]
            }
          }

        String.ends_with?(
          endpoint,
          "/groups/developer%40example.com/hasMember/jinfei%40example.com"
        ) ->
          %{"status" => 200, "data" => %{"isMember" => true}}
      end
    end)

    MockExternalHTTP.stub("POST", "/api/users.lookupByEmail", fn request ->
      case request["email"] do
        "developer@example.com" ->
          %{"ok" => false, "error" => "users_not_found"}

        email ->
          name = email |> String.split("@") |> hd()

          %{
            "ok" => true,
            "user" => %{
              "id" => "U" <> String.upcase(name),
              "team_id" => group["workspace_id"],
              "profile" => %{"email" => email}
            }
          }
      end
    end)

    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:ok, :pending} = Schedules.fire(schedule, at, now: at)
    assert eventually(fn -> length(personal_posts()) == 1 end)
    assert {:ok, :already_fired} = Schedules.fire(schedule, at, now: at + 1_000)
    assert eventually(fn -> length(personal_posts()) == 2 end)

    assert MapSet.new(Enum.map(personal_posts(), & &1.body["channel"])) ==
             MapSet.new(~w(DPENG DJINFEI))

    directory =
      MockExternalHTTP.requests()
      |> Enum.filter(&String.contains?(&1.body["endpoint"] || "", "admin.googleapis.com"))

    assert Enum.count(directory, &String.ends_with?(&1.body["endpoint"], "/members")) == 3
    assert Enum.any?(directory, &(proxy_parameter(&1, "includeDerivedMembership") == "true"))
  end

  test "a Directory failure leaves direct reminders sent and group expansion retryable", %{
    group: group
  } do
    {plan, raw} = personal_fixture(group, ["peng", "developer"])
    stub_group_account(group)

    stub_group_proxy(raw, fn endpoint, _token ->
      if String.ends_with?(endpoint, "/groups/peng%40example.com/members"),
        do: %{"status" => 404, "data" => %{}},
        else: %{"status" => 503, "data" => %{}}
    end)

    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:ok, :pending} = Schedules.fire(schedule, at, now: at)
    assert eventually(fn -> length(personal_posts()) == 2 end)

    assert {:error, :meeting_group_directory_unavailable} =
             Schedules.fire(schedule, at, now: at + 1_000)

    assert length(personal_posts()) == 2
    assert {:ok, current} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])
    refute current["preparation"]["personal_status"] == "sent"

    stub_group_proxy(raw, fn endpoint, _token ->
      if String.ends_with?(endpoint, "/groups/peng%40example.com/members"),
        do: %{"status" => 404, "data" => %{}},
        else: %{"status" => 200, "data" => %{"members" => []}}
    end)

    assert {:ok, :already_fired} = finish_personal_schedule(schedule, at, 2_000)
    assert length(personal_posts()) == 2
  end

  test "a former group member does not receive a reminder", %{group: group} do
    {plan, raw} = personal_fixture(group, ["developer"])
    stub_group_account(group)

    stub_group_proxy(raw, fn endpoint, _token ->
      cond do
        String.ends_with?(endpoint, "/groups/developer%40example.com/members") ->
          %{
            "status" => 200,
            "data" => %{"members" => [%{"email" => "peng@example.com", "type" => "USER"}]}
          }

        String.ends_with?(endpoint, "/hasMember/peng%40example.com") ->
          %{"status" => 200, "data" => %{"isMember" => false}}
      end
    end)

    MockExternalHTTP.stub("POST", "/api/users.lookupByEmail", fn request ->
      if request["email"] == "developer@example.com" do
        %{"ok" => false, "error" => "users_not_found"}
      else
        %{
          "ok" => true,
          "user" => %{
            "id" => "UPENG",
            "team_id" => group["workspace_id"],
            "profile" => %{"email" => "peng@example.com"}
          }
        }
      end
    end)

    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:ok, :pending} = Schedules.fire(schedule, at, now: at)
    assert {:ok, :already_fired} = finish_personal_schedule(schedule, at, 1_000)
    assert personal_posts() == []
  end

  test "a cross-domain nested group member does not stall other reminders", %{group: group} do
    {plan, raw} = personal_fixture(group, ["developer"])
    stub_group_account(group)

    stub_group_proxy(raw, fn endpoint, _token ->
      cond do
        String.ends_with?(endpoint, "/groups/developer%40example.com/members") ->
          %{
            "status" => 200,
            "data" => %{
              "members" => [
                %{"email" => "nested@elsewhere.com", "type" => "USER"},
                %{"email" => "peng@example.com", "type" => "USER"}
              ]
            }
          }

        String.ends_with?(endpoint, "/hasMember/nested%40elsewhere.com") ->
          %{"status" => 400, "data" => %{"error" => "Invalid input"}}

        String.ends_with?(endpoint, "/hasMember/peng%40example.com") ->
          %{"status" => 200, "data" => %{"isMember" => true}}
      end
    end)

    MockExternalHTTP.stub("POST", "/api/users.lookupByEmail", fn request ->
      case request["email"] do
        "developer@example.com" ->
          %{"ok" => false, "error" => "users_not_found"}

        email ->
          name = email |> String.split("@") |> hd()

          %{
            "ok" => true,
            "user" => %{
              "id" => "U" <> String.upcase(name),
              "team_id" => group["workspace_id"],
              "profile" => %{"email" => email}
            }
          }
      end
    end)

    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:ok, :pending} = Schedules.fire(schedule, at, now: at)
    assert {:ok, :already_fired} = finish_personal_schedule(schedule, at, 1_000)

    assert eventually(fn -> length(personal_posts()) == 2 end)

    assert MapSet.new(Enum.map(personal_posts(), & &1.body["channel"])) ==
             MapSet.new(~w(DNESTED DPENG))
  end

  test "cross-domain fallback requires a complete current group listing", %{group: group} do
    {plan, raw} = personal_fixture(group, ["developer"])
    stub_group_account(group)

    stub_group_proxy(raw, fn endpoint, _token ->
      if String.ends_with?(endpoint, "/members"),
        do: %{"status" => 200, "data" => %{"members" => []}},
        else: %{"status" => 400, "data" => %{"error" => "Invalid input"}}
    end)

    assert {:ok, current} =
             Salix.Bindings.GoogleGroupAttendees.current_members(plan, [
               {"nested@elsewhere.com", "developer@example.com"}
             ])

    assert MapSet.size(current) == 0

    stub_group_proxy(raw, fn endpoint, _token ->
      if String.ends_with?(endpoint, "/members"),
        do: %{"status" => 503, "data" => %{}},
        else: %{"status" => 400, "data" => %{"error" => "Invalid input"}}
    end)

    assert {:error, :meeting_group_directory_unavailable} =
             Salix.Bindings.GoogleGroupAttendees.current_members(plan, [
               {"nested@elsewhere.com", "developer@example.com"}
             ])
  end

  defp stub_group_account(group) do
    MockExternalHTTP.stub("GET", "/api/v3/connected_accounts", %{
      "items" => [
        %{
          "id" => "ca-admin",
          "user_id" => group["group_id"],
          "status" => "ACTIVE",
          "toolkit" => %{"slug" => "google_admin"}
        }
      ]
    })
  end

  defp stub_group_proxy(raw, group_response) do
    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      endpoint = request["endpoint"] || ""

      if String.starts_with?(endpoint, "https://admin.googleapis.com/") do
        group_response.(endpoint, proxy_parameter(%{body: request}, "pageToken"))
      else
        %{"status" => 200, "data" => raw}
      end
    end)
  end

  test "reviewed no-advice and unresearched attendees both receive a basic reminder", %{
    group: group
  } do
    {plan, _raw} = personal_fixture(group)
    assert {:ok, context} = SalixMeet.PersonalPreparation.context(plan)
    connect = context["connect_id"]

    assert {:ok, %{"status" => "saved"}} =
             SalixMeet.PersonalPreparation.submit(plan, connect, "UPENG", nil, %{
               "sources_label" => ["scope|#{connect}|@UPENG"],
               "declassified" => []
             })

    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:ok, :fired} = Schedules.fire(schedule, at, now: at)
    assert eventually(fn -> length(personal_posts()) == 2 end)

    assert MapSet.new(Enum.map(personal_posts(), & &1.body["channel"])) ==
             MapSet.new(["DPENG", "DJINFEI"])

    assert Enum.all?(
             personal_posts(),
             &(&1.body["text"] =~ "https://meet.google.com/standalone-room")
           )

    assert {:ok, false} = SalixMeet.PersonalPreparation.research_complete?(plan)
  end

  test "basic reminders respect opt-out and removed attendees after discovery", %{group: group} do
    {plan, raw} = personal_fixture(group, ["peng", "jinfei", "remaining"])
    assert {:ok, _} = SalixMeet.PersonalPreparation.context(plan)

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "agent_group_id" => group["group_id"],
      "provider_context" => %{"connect_id" => group["connect_id"], "user_id" => "UPENG"}
    }

    assert {:ok, _} =
             SalixMeet.PersonalPreparation.set_preference(group["group_id"], origin, false)

    stub_get(
      Map.update!(
        raw,
        "attendees",
        &Enum.reject(&1, fn attendee -> attendee["email"] == "jinfei@example.com" end)
      )
    )

    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:ok, :fired} = Schedules.fire(schedule, at, now: at)
    assert eventually(fn -> length(personal_posts()) == 1 end)
    assert hd(personal_posts()).body["channel"] == "DREMAINING"
  end

  @tag :personal_pagination
  test "failed first-page lookups yield to later recipients and cutoff preserves unsent reports",
       %{group: group} do
    names = Enum.map(1..29, &("p" <> String.pad_leading(to_string(&1), 2, "0")))
    {plan, _raw} = personal_fixture(group, names)
    assert {:ok, first} = SalixMeet.PersonalPreparation.context(plan)
    assert {:ok, second} = SalixMeet.PersonalPreparation.context(plan, cursor: 20)
    save_personal_pages(plan, [first, second])

    MockExternalHTTP.stub("POST", "/api/users.lookupByEmail", fn request ->
      name = request["email"] |> String.split("@") |> hd()

      if name <= "p20" do
        %{"ok" => false, "error" => "ratelimited"}
      else
        %{
          "ok" => true,
          "user" => %{
            "id" => "U" <> String.upcase(name),
            "team_id" => group["workspace_id"],
            "profile" => %{"email" => request["email"]},
            "real_name" => name
          }
        }
      end
    end)

    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:error, :slack_attendee_lookup_failed} = Schedules.fire(schedule, at, now: at)
    assert {:ok, :pending} = Schedules.fire(schedule, at, now: at + 1_000)
    assert eventually(fn -> length(personal_posts()) == 9 end)
    assert {:ok, :already_fired} = Schedules.fire(schedule, at, now: at + :timer.minutes(10))
    assert length(personal_posts()) == 9
    assert {:ok, false} = SalixMeet.PersonalPreparation.has_pending?(plan)

    identity = [
      group["group_id"],
      plan["meeting_plan_id"],
      plan["preparation"]["dispatch_revision"]
    ]

    assert {:ok, unsent} = SalixStore.MeetingPersonalPreparation.get_recipient(identity, "UP01")
    assert unsent["report"]["status"] == "expired"
    assert unsent["report"]["text"] == "Private preparation for UP01"
  end

  @tag :discovery_failure
  test "later discovery failure preserves known reminders and recovery sends remaining attendees",
       %{group: group} do
    names = Enum.map(1..29, &("p" <> String.pad_leading(to_string(&1), 2, "0")))
    {plan, _raw} = personal_fixture(group, names)
    assert {:ok, first} = SalixMeet.PersonalPreparation.context(plan)
    assert length(first["recipients"]) == 20

    lookup = fn request ->
      name = request["email"] |> String.split("@") |> hd()

      %{
        "ok" => true,
        "user" => %{
          "id" => "U" <> String.upcase(name),
          "team_id" => group["workspace_id"],
          "profile" => %{"email" => request["email"]},
          "real_name" => name
        }
      }
    end

    MockExternalHTTP.stub("POST", "/api/users.lookupByEmail", fn request ->
      if request["email"] == "p21@example.com",
        do: %{"ok" => false, "error" => "ratelimited"},
        else: lookup.(request)
    end)

    schedule_id = plan["preparation"]["schedule_ids"]["personal"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    at = plan["preparation"]["card_at"]
    assert {:error, :slack_attendee_lookup_failed} = Schedules.fire(schedule, at, now: at)
    assert eventually(fn -> length(personal_posts()) == 20 end)
    assert {:ok, false} = SalixMeet.PersonalPreparation.research_complete?(plan)
    assert {:ok, current} = MeetingPlan.get(group["group_id"], plan["meeting_plan_id"])
    refute current["preparation"]["personal_status"] == "sent"

    assert {:error, :slack_attendee_lookup_failed} = Schedules.fire(schedule, at, now: at + 1_000)
    assert length(personal_posts()) == 20
    MockExternalHTTP.stub("POST", "/api/users.lookupByEmail", lookup)
    assert {:ok, :already_fired} = finish_personal_schedule(schedule, at, 2_000)
    assert eventually(fn -> length(personal_posts()) == 29 end)

    assert Enum.sort(Enum.map(personal_posts(), & &1.body["channel"])) ==
             Enum.map(names, &("D" <> String.upcase(&1)))

    assert {:ok, :already_fired} = Schedules.fire(schedule, at, now: at + 3_000)
    assert length(personal_posts()) == 29
    assert {:ok, false} = SalixMeet.PersonalPreparation.research_complete?(plan)
  end

  defp personal_lookups,
    do: Enum.count(MockExternalHTTP.requests(), &(&1.path == "/api/users.lookupByEmail"))

  defp finish_personal_schedule(schedule, at, offset, attempts_left \\ 6) do
    assert attempts_left > 0

    case Schedules.fire(schedule, at, now: at + offset) do
      {:ok, :pending} -> finish_personal_schedule(schedule, at, offset + 1_000, attempts_left - 1)
      result -> result
    end
  end

  defp save_personal_pages(plan, pages) do
    for page <- pages, recipient <- page["recipients"] do
      user = recipient["user_id"]

      assert {:ok, _} =
               SalixMeet.PersonalPreparation.submit(
                 plan,
                 page["connect_id"],
                 user,
                 "Private preparation for " <> user,
                 %{
                   "sources_label" => ["scope|#{page["connect_id"]}|@#{user}"],
                   "declassified" => []
                 }
               )
    end
  end

  defp personal_fixture(group, names \\ ["peng", "jinfei", "guest", "missing"]) do
    previous = Application.get_env(:salix_meet, :calendar_autojoin_channels)
    previous_port = Application.get_env(:salix_meet, :personal_preparation_mod)

    on_exit(fn ->
      restore_env(:salix_meet, :calendar_autojoin_channels, previous)
      restore_env(:salix_meet, :personal_preparation_mod, previous_port)
    end)

    Application.put_env(
      :salix_meet,
      :personal_preparation_mod,
      Salix.Bindings.MeetingPersonalPreparation
    )

    entry = %{
      "connect_id" => group["connect_id"],
      "channel" => group["channel_id"],
      "calendars" => ["Meetings"]
    }

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [entry])

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               entry,
               group,
               group,
               System.system_time(:millisecond)
             )

    assert {:ok, _} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(group["group_id"], group["connect_id"]),
               Map.merge(
                 Map.take(group, ~w(tenant_id group_id connect_id provider workspace_id)),
                 %{"bot_token" => "xoxb-personal-test", "oauth_completed_at" => 1}
               )
             )

    assert {:ok, _} =
             SalixStore.CasRecord.update(
               Keys.ctl_group(group["group_id"]),
               &Map.put(&1, "ifc", %{"mode" => "off"})
             )

    raw =
      standalone_event("Personal preparation meeting", 1, "2030-01-02T00:00:00Z")
      |> Map.put(
        "attendees",
        Enum.map(
          names,
          &%{"email" => &1 <> "@example.com", "responseStatus" => "accepted"}
        )
      )

    {_item, event} = writeback_fixture(group, raw)
    stub_get(raw)

    MockExternalHTTP.stub("POST", "/api/users.lookupByEmail", fn request ->
      name = request["email"] |> String.split("@") |> hd()

      if String.starts_with?(name, "missing") do
        %{"ok" => false, "error" => "users_not_found"}
      else
        %{
          "ok" => true,
          "user" => %{
            "id" => "U" <> String.upcase(name),
            "team_id" => group["workspace_id"],
            "profile" => %{"email" => request["email"]},
            "real_name" => name,
            "is_restricted" => String.starts_with?(name, "guest")
          }
        }
      end
    end)

    MockExternalHTTP.stub("POST", "/api/conversations.open", fn request ->
      %{"ok" => true, "channel" => %{"id" => String.replace_prefix(request["users"], "U", "D")}}
    end)

    MockExternalHTTP.stub("POST", "/api/chat.postMessage", fn request ->
      %{"ok" => true, "channel" => request["channel"], "ts" => "123.#{request["channel"]}"}
    end)

    MockExternalHTTP.stub("POST", "/api/conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "CPUBLIC", "is_private" => false, "is_member" => true}
    })

    assert {:ok, plan} = MeetingPlan.get(group["group_id"], event["meeting_plan_id"])
    {plan, raw}
  end

  defp personal_posts,
    do: Enum.filter(MockExternalHTTP.requests(), &(&1.path == "/api/chat.postMessage"))

  defp writeback_fixture(group, raw) do
    stub_list([raw], "writeback-fixture")
    assert {:ok, _} = sync_source(group)
    assert {:ok, [event]} = MeetingCalendar.list(group, range_start(), range_end())

    assert {:ok, item} =
             Calendar.get_item(group["group_id"], group["calendar_id"], event["calendar_item_id"])

    assert {:ok, occurrence} = SalixCalendar.Recurrence.resolve(item, event["occurrence_ref"])
    {item, Map.merge(event, occurrence)}
  end

  defp calendar_patch_requests do
    Enum.filter(
      MockExternalHTTP.requests(),
      &(&1.path == @proxy_execute_path and &1.body["method"] == "PATCH")
    )
  end

  defp recurring_master do
    %{
      "id" => "series",
      "iCalUID" => "series@example.com",
      "summary" => "Weekly planning",
      "status" => "confirmed",
      "sequence" => 4,
      "updated" => "2030-01-01T00:00:00Z",
      "start" => %{"dateTime" => "2030-01-07T10:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "2030-01-07T11:00:00Z", "timeZone" => "Etc/UTC"},
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO"],
      "htmlLink" => "https://www.google.com/calendar/event?eid=series%40example.com",
      "hangoutLink" => "https://meet.google.com/abc-defg-hij",
      "organizer" => %{"self" => true, "email" => "owner@example.com"}
    }
  end

  defp standalone_event(title, sequence, updated) do
    %{
      "id" => "standalone-event",
      "iCalUID" => "standalone-event@example.com",
      "summary" => title,
      "status" => "confirmed",
      "sequence" => sequence,
      "updated" => updated,
      "start" => %{"dateTime" => "2030-01-14T10:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "2030-01-14T11:00:00Z", "timeZone" => "Etc/UTC"},
      "htmlLink" => "https://www.google.com/calendar/event?eid=standalone%40example.com",
      "hangoutLink" => "https://meet.google.com/standalone-room",
      "organizer" => %{"self" => true, "email" => "owner@example.com"}
    }
  end

  defp moved_exception do
    %{
      "id" => "series-instance",
      "recurringEventId" => "series",
      "status" => "confirmed",
      "originalStartTime" => %{
        "dateTime" => "2030-01-14T10:00:00Z",
        "timeZone" => "Etc/UTC"
      },
      "start" => %{"dateTime" => "2030-01-14T11:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "2030-01-14T12:00:00Z", "timeZone" => "Etc/UTC"},
      "hangoutLink" => "https://meet.google.com/abc-defg-hij"
    }
  end

  defp ordinary_instance do
    %{
      "id" => "ordinary-series-instance",
      "recurringEventId" => "series",
      "status" => "confirmed",
      "originalStartTime" => %{
        "dateTime" => "2030-01-14T10:00:00Z",
        "timeZone" => "Etc/UTC"
      },
      "start" => %{"dateTime" => "2030-01-14T10:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "2030-01-14T11:00:00Z", "timeZone" => "Etc/UTC"},
      "hangoutLink" => "https://meet.google.com/abc-defg-hij"
    }
  end

  defp stub_list(items, sync_token) do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{"status" => 200, "data" => %{"items" => items, "nextSyncToken" => sync_token}}
    )
  end

  defp stub_watch do
    MockExternalHTTP.stub(
      "POST",
      "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH",
      fn request ->
        channel_id = get_in(request, ["arguments", "id"])

        %{
          "successful" => true,
          "data" => %{
            "id" => channel_id,
            "resourceId" => "resource-#{channel_id}",
            "expiration" => System.system_time(:millisecond) + 7 * 24 * 60 * 60 * 1_000
          }
        }
      end
    )
  end

  defp stub_channel_stop do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{"status" => 204, "data" => nil, "headers" => %{}}
    )
  end

  defp stub_proxy_session do
    MockExternalHTTP.stub(
      "POST",
      @proxy_session_path,
      %{"session_id" => "trs-calendar", "config" => %{}},
      201
    )

    MockExternalHTTP.stub(
      "DELETE",
      @proxy_session_path <> "/trs-calendar",
      %{"session_id" => "trs-calendar", "deleted" => true}
    )
  end

  defp stub_get(event) do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{"status" => 200, "data" => event}
    )
  end

  defp stub_instances(items) do
    MockExternalHTTP.stub(
      "POST",
      @proxy_execute_path,
      %{"status" => 200, "data" => %{"items" => items}}
    )
  end

  # Pages keyed by the `pageToken` the client sends (`nil` for the first page),
  # or a function of that token.
  defp stub_instances_pages(pages) do
    MockExternalHTTP.stub("POST", @proxy_execute_path, fn request ->
      request = %{body: request}
      token = proxy_parameter(request, "pageToken")
      data = if is_function(pages, 2), do: pages.(request, token), else: Map.fetch!(pages, token)
      %{"status" => 200, "data" => data}
    end)
  end

  defp instance_requests do
    MockExternalHTTP.requests()
    |> Enum.filter(
      &(&1.path == @proxy_execute_path and
          String.ends_with?(&1.body["endpoint"] || "", "/events/series/instances"))
    )
  end

  defp stub_account(group_id, account_id) do
    MockExternalHTTP.stub("GET", "/api/v3/connected_accounts/#{account_id}", %{
      "id" => account_id,
      "user_id" => group_id,
      "status" => "ACTIVE",
      "toolkit" => %{"slug" => "googlecalendar"}
    })
  end

  defp repair_source(group, source, now) do
    GoogleCalendarWatch.repair(
      group["group_id"],
      group["calendar_id"],
      source["source_id"],
      now
    )
  end

  defp sync_source(group) do
    source_id = get_in(group, ["calendars", Access.at(0), "source_id"])

    refresh_source(group, source_id)
  end

  defp refresh_source(group, source_id) do
    Calendar.refresh_source(
      group["group_id"],
      group["calendar_id"],
      source_id,
      %{
        "group_id" => group["group_id"],
        "object_type" => "Event",
        "page_size" => 200
      }
    )
  end

  defp select_source(group, source_id),
    do: put_in(group, ["calendars", Access.at(0), "source_id"], source_id)

  defp item_from_source(items, source_id) do
    Enum.find(items, fn item ->
      get_in(item, ["origin", "source_id"]) == source_id
    end)
  end

  defp provider_list_requests do
    MockExternalHTTP.requests()
    |> Enum.filter(
      &(&1.path == @proxy_execute_path and
          String.ends_with?(&1.body["endpoint"] || "", "/events"))
    )
  end

  defp provider_list_request_count, do: length(provider_list_requests())

  defp provider_proxy_session_create_count do
    MockExternalHTTP.requests()
    |> Enum.count(&(&1.method == "POST" and &1.path == @proxy_session_path))
  end

  defp provider_proxy_session_delete_count do
    MockExternalHTTP.requests()
    |> Enum.count(&(&1.method == "DELETE" and &1.path == @proxy_session_path <> "/trs-calendar"))
  end

  defp provider_watch_request_count do
    MockExternalHTTP.requests()
    |> Enum.count(&(&1.path == "/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_WATCH"))
  end

  defp provider_stop_requests do
    MockExternalHTTP.requests()
    |> Enum.filter(
      &(&1.path == @proxy_execute_path and
          &1.body["endpoint"] == "https://www.googleapis.com/calendar/v3/channels/stop")
    )
  end

  defp provider_stop_request_count, do: length(provider_stop_requests())

  defp proxy_parameter(request, name) do
    request.body["parameters"]
    |> Enum.find_value(fn parameter ->
      if parameter["name"] == name, do: parameter["value"]
    end)
  end

  defp range_start, do: unix_ms("2030-01-14T00:00:00Z")
  defp range_end, do: unix_ms("2030-01-15T00:00:00Z")

  defp unix_ms(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    DateTime.to_unix(datetime, :millisecond)
  end

  defp eventually_value(fun, retries \\ 100)
  defp eventually_value(_fun, 0), do: nil

  defp eventually_value(fun, retries) do
    case fun.() do
      value when value in [nil, false] ->
        Process.sleep(20)
        eventually_value(fun, retries - 1)

      value ->
        value
    end
  end

  defp eventually(fun), do: eventually_value(fn -> if fun.(), do: true end)

  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _ ->
      port = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(
             {Bandit, plug: MockExternalHTTP, port: port, ip: {127, 0, 0, 1}},
             id: {:meeting_calendar_bandit, port}
           ) do
        {:ok, _pid} -> port
        {:error, _reason} -> nil
      end
    end) || raise "could not bind meeting calendar test server"
  end

  defp ensure_started!(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
