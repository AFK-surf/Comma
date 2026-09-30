defmodule BridgeForTeamsWeb.MeetingPreparationFixture do
  @moduledoc false
  alias SalixStore.{Ids, Keys, S3}
  alias SalixWeb.Test.MeetingPreparationProvider, as: Provider

  def seed(org, project) do
    group_id = project.salix_group_id
    router_id = Ids.new_agent_id(group_id)
    connect_id = "slack-" <> project.id

    group = %{
      "group_id" => group_id,
      "tenant_id" => org.salix_tenant_id,
      "router_agent_id" => router_id,
      "router_conversation_id" => Ids.new_conversation_id()
    }

    {:ok, _} = S3.put(Keys.ctl_group(group_id), Jason.encode!(group))

    {:ok, _} =
      S3.put(
        Keys.ctl_agent(router_id),
        Jason.encode!(%{
          "agent_id" => router_id,
          "group_id" => group_id,
          "tenant_id" => org.salix_tenant_id,
          "role" => "router",
          "heartbeat_schedule_id" => Ids.new_schedule_id(),
          "router_session_id" => Ids.new_session_id(),
          "name" => "Local preview Router"
        })
      )

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
        "tenant_id" => org.salix_tenant_id,
        "group_id" => group_id,
        "connect_id" => connect_id,
        "provider" => "slack",
        "workspace_id" => "T-LOCAL-PREVIEW",
        "workspace_name" => "Local test workspace",
        "app_name" => "Meeting Assistant",
        "bot_username" => "meeting-assistant",
        "bot_token" => "local-test-token",
        "oauth_completed_at" => 1,
        "connect_generation" => "local-test-generation",
        "granted_bot_scopes_generation" => "local-test-generation",
        "granted_bot_scopes" => ~w(users:read.email im:write chat:write),
        "created_at" => 1,
        "updated_at" => 1
      })

    {:ok, _} =
      Salix.Control.ComposioSettings.put(org.salix_tenant_id, %{"api_key" => "local-test-key"})

    Provider.stub("GET", "/api/v3/connected_accounts", %{
      "items" =>
        Enum.map(["ca-product", "ca-engineering"], fn id ->
          %{
            "id" => id,
            "user_id" => group_id,
            "status" => "ACTIVE",
            "toolkit" => %{"slug" => "googlecalendar"}
          }
        end)
    })

    Provider.stub("POST", "/api/v3/tools/execute/GOOGLECALENDAR_LIST_CALENDARS", fn request ->
      engineering = request["connected_account_id"] == "ca-engineering"

      %{
        "successful" => true,
        "data" => %{
          "calendars" => [
            %{
              "id" =>
                if(engineering, do: "engineering@example.test", else: "product@example.test"),
              "summary" => if(engineering, do: "Engineering calendar", else: "Product calendar"),
              "primary" => true
            }
          ]
        }
      }
    end)

    channel = %{
      "id" => "C-TEAM",
      "name" => "team-meetings",
      "is_member" => true,
      "is_private" => false
    }

    Provider.stub("POST", "/api/conversations.list", %{"ok" => true, "channels" => [channel]})
    Provider.stub("POST", "/api/conversations.info", %{"ok" => true, "channel" => channel})

    for id <- ["ca-product", "ca-engineering"] do
      Provider.stub("GET", "/api/v3/connected_accounts/" <> id, %{
        "id" => id,
        "user_id" => group_id,
        "status" => "ACTIVE",
        "toolkit" => %{"slug" => "googlecalendar"}
      })
    end

    Provider.stub(
      "POST",
      "/api/v3.1/tool_router/session",
      %{"session_id" => "trs-preview", "config" => %{}},
      201
    )

    Provider.stub("DELETE", "/api/v3.1/tool_router/session/trs-preview", %{"deleted" => true})

    Provider.stub("POST", "/api/v3.1/tool_router/session/trs-preview/proxy_execute", %{
      "status" => 200,
      "data" => %{
        "items" => [
          %{
            "id" => "design-instance",
            "recurringEventId" => "design-series",
            "summary" => "Technical Design",
            "status" => "confirmed",
            "hangoutLink" => "https://meet.google.com/abc-defg-hij",
            "start" => %{"dateTime" => DateTime.to_iso8601(DateTime.utc_now())}
          },
          %{
            "id" => "without-meet",
            "summary" => "No supported meeting link",
            "status" => "confirmed"
          }
        ]
      }
    })

    %{group: group, connect_id: connect_id}
  end

  def seed_record(group, connect_id, id, attrs \\ %{}) do
    state =
      Map.merge(
        %{
          "tenant_id" => group["tenant_id"],
          "group_id" => group["group_id"],
          "connect_id" => connect_id,
          "provider" => "slack",
          "title" => "Stand-up · sample meeting",
          "status" => "done",
          "start_at" => 1_789_610_000,
          "slack_ref" => %{"channel_id" => "C-TEAM", "thread_ts" => "1789610000.000001"},
          "summary" => %{"key_points" => ["Do not expose a content preview"]},
          "artifacts" => %{"audio" => %{"storage_key" => "private-storage-key"}},
          "delivery" => %{
            "status" => "published",
            "published_at" => 1_789_611_000,
            "canvas_url" => "https://sample.slack.com/docs/TTEST/FTEST",
            "canvas_access" => %{"status" => "granted"},
            "artifacts" => %{
              "audio" => %{"permalink" => "https://sample.slack.com/files/UTEST/FRECORD"}
            }
          }
        },
        attrs
      )

    {:ok, _, _} = SalixMeet.Store.create_once(id, state: state)
    id
  end
end
