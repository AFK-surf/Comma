defmodule BridgeForTeamsWeb.Dashboard.ConversationTraceControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Projects

  defmodule TraceSalixClient do
    @moduledoc false

    @conversation %{
      "conversation_id" => "task-dashboard-1",
      "title" => "Dashboard trace task",
      "kind" => "work_session",
      "participants" => [
        %{
          "participant_id" => "delegator",
          "actor_type" => "agent",
          "agent_id" => "agent-router",
          "payload" => %{"session_id" => "router-session"}
        },
        %{
          "participant_id" => "worker",
          "actor_type" => "agent",
          "agent_id" => "agent-worker",
          "payload" => %{"session_id" => "worker-session"}
        }
      ]
    }

    @missing_runtime_conversation %{
      "conversation_id" => "trace-gone",
      "title" => "Trace gone",
      "kind" => "work_session",
      "participants" => [
        %{
          "participant_id" => "worker",
          "actor_type" => "agent",
          "agent_id" => "agent-missing",
          "payload" => %{"session_id" => "missing-session"}
        }
      ]
    }

    @single_trace_conversation %{
      "conversation_id" => "single-trace",
      "title" => "Single trace",
      "kind" => "work_session",
      "participants" => [
        %{
          "participant_id" => "agent",
          "actor_type" => "agent",
          "agent_id" => "agent-single",
          "payload" => %{"session_id" => "single-session"}
        }
      ]
    }

    @no_trace_conversation %{
      "conversation_id" => "no-trace",
      "title" => "No trace",
      "kind" => "work_session",
      "participants" => [
        %{
          "participant_id" => "worker",
          "actor_type" => "agent",
          "agent_id" => "agent-no-trace"
        }
      ]
    }

    def get_group_conversation(_group_id, "task-dashboard-1"),
      do: {:ok, Map.delete(@conversation, "participants")}

    def get_group_conversation(_group_id, "trace-gone"),
      do: {:ok, Map.delete(@missing_runtime_conversation, "participants")}

    def get_group_conversation(_group_id, "single-trace"),
      do: {:ok, Map.delete(@single_trace_conversation, "participants")}

    def get_group_conversation(_group_id, "no-trace"),
      do: {:ok, Map.delete(@no_trace_conversation, "participants")}

    def get_group_conversation(_group_id, _conversation_id), do: {:error, :not_found}

    def list_group_conversation_participants(_group_id, conversation_id, _opts) do
      conversation =
        case conversation_id do
          "task-dashboard-1" -> @conversation
          "trace-gone" -> @missing_runtime_conversation
          "single-trace" -> @single_trace_conversation
          "no-trace" -> @no_trace_conversation
        end

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => conversation["participants"]
       }}
    end

    def session_trace("agent-worker" = agent_id, "worker-session" = session_id, opts) do
      Process.put(:dashboard_trace_target, {agent_id, session_id})
      Process.put(:dashboard_trace_limit, Keyword.fetch!(opts, :limit))

      {:ok,
       %{
         "agent_id" => agent_id,
         "session_id" => session_id,
         "token" => "secret-token",
         "events" => [
           %{
             "method" => "turn/completed",
             "callback_url" => "https://example.test/callback?token=secret-token&ok=1"
           }
         ]
       }}
    end

    def session_trace("agent-single" = agent_id, "single-session" = session_id, opts) do
      Process.put(:dashboard_trace_target, {agent_id, session_id})
      Process.put(:dashboard_trace_limit, Keyword.fetch!(opts, :limit))

      {:ok,
       %{
         "agent_id" => agent_id,
         "session_id" => session_id,
         "events" => [%{"method" => "single/trace"}]
       }}
    end

    def session_trace("agent-missing", "missing-session", _opts), do: {:error, :not_found}

    def session_trace(agent_id, session_id, _opts),
      do: {:error, {:unexpected_trace_target, agent_id, session_id}}
  end

  setup %{conn: conn} do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    Application.put_env(:bridge_for_teams_core, :salix_client, TraceSalixClient)

    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "acme", name: "Acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Support", "slug" => "support"})

    %{conn: log_in_user(conn, user), org: org, project: project}
  end

  test "dashboard trace resolves the selected participant payload session and bounds limit", %{
    conn: conn,
    org: org,
    project: project
  } do
    conn =
      get(
        conn,
        "/orgs/#{org.slug}/projects/#{project.id}/tasks/task-dashboard-1/debug-trace?participant=worker&limit=1000"
      )

    assert conn.status == 200
    assert body = json_body(conn)
    assert body["agent_id"] == "agent-worker"
    assert body["session_id"] == "worker-session"
    assert body["token"] == "[REDACTED]"

    assert [%{"method" => "turn/completed", "callback_url" => callback_url}] = body["events"]
    assert String.starts_with?(callback_url, "https://example.test/callback?")
    assert callback_url =~ "ok=1"
    assert callback_url =~ "token=%5BREDACTED%5D"
    refute callback_url =~ "secret-token"

    assert Process.get(:dashboard_trace_target) == {"agent-worker", "worker-session"}
    assert Process.get(:dashboard_trace_limit) == 500
  end

  test "dashboard trace can omit participant when exactly one traceable participant exists", %{
    conn: conn,
    org: org,
    project: project
  } do
    conn =
      get(
        conn,
        "/orgs/#{org.slug}/projects/#{project.id}/tasks/single-trace/debug-trace"
      )

    assert conn.status == 200
    assert body = json_body(conn)
    assert body["agent_id"] == "agent-single"
    assert body["session_id"] == "single-session"
    assert body["events"] == [%{"method" => "single/trace"}]
    assert Process.get(:dashboard_trace_target) == {"agent-single", "single-session"}
    assert Process.get(:dashboard_trace_limit) == 100
  end

  # {label, task path suffix, status, error, runtime must stay uncalled?}
  for {label, path, status, error, runtime_untouched?} <- [
        {"rejects ambiguous agent participants without guessing", "task-dashboard-1/debug-trace",
         400, "trace_participant_required", false},
        {"validates limit before calling the runtime",
         "task-dashboard-1/debug-trace?participant=worker&limit=abc", 400, "invalid_limit", true},
        {"reports missing conversations without calling the runtime",
         "missing/debug-trace?participant=worker", 404, "conversation_not_found", true},
        {"reports missing runtime sessions as trace session not found",
         "trace-gone/debug-trace?participant=worker", 404, "trace_session_not_found", false},
        {"reports conversations without traceable participants",
         "no-trace/debug-trace?participant=worker", 404, "trace_session_not_found", false},
        {"reports unexpected runtime failures as server errors",
         "task-dashboard-1/debug-trace?participant=delegator", 500, "trace_unavailable", false}
      ] do
    @path path
    @status status
    @error error
    @runtime_untouched? runtime_untouched?

    test "dashboard trace #{label}", %{conn: conn, org: org, project: project} do
      conn = get(conn, "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{@path}")

      assert conn.status == @status
      assert json_body(conn) == %{"error" => @error}

      if @runtime_untouched? do
        refute Process.get(:dashboard_trace_target)
      end
    end
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)
end
