defmodule SalixWeb.Dashboard.AgentSessionLiveTest do
  @moduledoc "Agent create/list/show and session listing via LiveView."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixAgent.ExternalAgentRuntime
  alias SalixEnv.Registry
  alias SalixStore.{Keys, RuntimeIds}

  @endpoint SalixWeb.DashboardEndpoint

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Agent sessions"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "AgentGrp"}, tenant_id())
    {:ok, tmpl} = SalixAgent.Templates.create(%{"name" => "AgentTmpl", "model" => "mock"})
    %{group: group, template: tmpl}
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "create an agent via the new form", %{group: group, template: tmpl} do
    {:ok, view, html} = live(authed_conn(), "/dash/agents/new")

    assert html =~
             ~r/<option[^>]*selected[^>]*value="cloudflare"|<option[^>]*value="cloudflare"[^>]*selected/

    {:ok, _show, html} =
      view
      |> form("form[phx-submit=create]", %{
        "name" => "CI Agent",
        "group_id" => group["group_id"],
        "template_id" => tmpl["template_id"],
        "role" => "worker"
      })
      |> render_submit()
      |> follow_redirect(authed_conn())

    assert html =~ "CI Agent"
    refute html =~ "Connector tokens"

    created =
      tenant_id()
      |> SalixAgent.Control.list(group_id: group["group_id"])
      |> Enum.find(&(&1["name"] == "CI Agent"))

    assert created["runtime_config"] == %{"kind" => "internal"}
  end

  test "create an external codex agent by selecting device and runtime", %{
    group: group,
    template: tmpl
  } do
    env_id = connected_codex_device!(group["group_id"])
    device_id = device_id(env_id)
    device_runtime_id = device_runtime_id(env_id)

    {:ok, other_group} = Salix.Control.Groups.create(%{"name" => "OtherGrp"}, tenant_id())
    other_env_id = connected_codex_device!(other_group["group_id"])
    {:ok, view, _html} = live(authed_conn(), "/dash/agents/new")

    view
    |> form("form[phx-submit=create]", %{
      "agent_type" => "external",
      "group_id" => group["group_id"],
      "template_id" => tmpl["template_id"]
    })
    |> render_change()

    changed =
      view
      |> form("form[phx-submit=create]", %{
        "agent_type" => "external",
        "device_id" => device_id,
        "group_id" => group["group_id"],
        "template_id" => tmpl["template_id"]
      })
      |> render_change()

    assert changed =~ "codex / #{device_runtime_id}"
    assert changed =~ device_id
    refute changed =~ other_env_id

    {:ok, _show, html} =
      view
      |> form("form[phx-submit=create]", %{
        "name" => "Codex Worker",
        "agent_type" => "external",
        "device_id" => device_id,
        "device_runtime_id" => device_runtime_id,
        "group_id" => group["group_id"],
        "template_id" => tmpl["template_id"]
      })
      |> render_submit()
      |> follow_redirect(authed_conn())

    assert html =~ "Codex Worker"

    created =
      tenant_id()
      |> SalixAgent.Control.list(group_id: group["group_id"])
      |> Enum.find(&(&1["name"] == "Codex Worker"))

    assert created["role"] == "worker"

    assert created["runtime_config"] == %{
             "kind" => "external",
             "provider" => "codex",
             "device_id" => device_id,
             "runtime_id" => "runtime-codex",
             "device_runtime_id" => device_runtime_id
           }
  end

  test "external create requires device and runtime", %{group: group, template: tmpl} do
    env_id = connected_device_without_runtime!(group["group_id"])
    {:ok, view, _html} = live(authed_conn(), "/dash/agents/new")

    html =
      view
      |> form("form[phx-submit=create]", %{
        "agent_type" => "external",
        "group_id" => group["group_id"],
        "template_id" => tmpl["template_id"]
      })
      |> render_submit()

    assert html =~ "Select a device."

    view
    |> form("form[phx-submit=create]", %{
      "agent_type" => "external",
      "group_id" => group["group_id"],
      "template_id" => tmpl["template_id"]
    })
    |> render_change()

    html =
      view
      |> form("form[phx-submit=create]", %{
        "agent_type" => "external",
        "device_id" => device_id(env_id),
        "group_id" => group["group_id"],
        "template_id" => tmpl["template_id"]
      })
      |> render_submit()

    assert html =~ "Select a runtime."
  end

  test "agent show and sessions page do not expose removed legacy controls", %{
    group: group,
    template: tmpl
  } do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "ShowAgent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"]
        },
        tenant_id()
      )

    aid = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    {:ok, show, _html} = live(authed_conn(), "/dash/agents/#{aid}")

    assert render(show) =~
             ~r/<option[^>]*selected[^>]*value="cloudflare"|<option[^>]*value="cloudflare"[^>]*selected/

    html = render_submit(form(show, "form[phx-submit=save]", %{"name" => "ShowAgent v2"}))
    assert html =~ "Agent saved"
    assert html =~ "Group conversations"
    assert html =~ "/dash/groups/#{group["group_id"]}?tab=conversations"
    refute html =~ "/dash/agents/#{aid}/conversations"

    assert {:ok, _} =
             SalixAgent.deliver(
               aid,
               %{
                 kind: "session_create",
                 session_id: session_id,
                 name: "Main",
                 created_at: System.system_time(:second)
               },
               source_message_id: "test:main-session:#{aid}"
             )

    hidden_session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _} =
             SalixAgent.deliver(
               aid,
               %{
                 kind: "session_create",
                 session_id: hidden_session_id,
                 name: "Hidden runtime session",
                 hidden: true,
                 created_at: System.system_time(:second)
               },
               source_message_id: "test:hidden-session:#{hidden_session_id}"
             )

    assert eventually(fn ->
             match?({:ok, _}, SalixAgent.InternalSessionStore.read(aid, hidden_session_id))
           end)

    {:ok, sessions, html} = live(authed_conn(), "/dash/agents/#{aid}/sessions")
    assert html =~ "Show hidden"
    refute html =~ "Hidden runtime session"
    refute html =~ "New session"
    refute html =~ "Cancel"
    refute html =~ "Delete"

    html = render_click(element(sessions, "input[name=include_hidden]"))
    assert html =~ "Hidden runtime session"

    {:ok, session_show, _html} =
      live(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}")

    html =
      session_show
      |> form("form[phx-submit=send]", %{"content" => "dashboard explicit runtime message"})
      |> render_submit()

    assert html =~ "Runtime message accepted."

    assert eventually(fn ->
             case SalixAgent.InternalSessionStore.read(aid, session_id) do
               {:ok, session} ->
                 Enum.any?(
                   SalixAgent.InternalSession.get(session, :messages),
                   &(&1.role == "user" and &1.content == "dashboard explicit runtime message")
                 )

               _ ->
                 false
             end
           end)
  end

  test "external runtime session page exposes event trace but not internal-only fork or compact",
       %{
         group: group,
         template: tmpl
       } do
    env_id = connected_codex_device!(group["group_id"])

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "External Sessions",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"],
          "runtime_config" => codex_runtime_config(env_id)
        },
        tenant_id()
      )

    aid = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, :external} =
             ExternalAgentRuntime.stage_delivery(aid, %{
               source_message_id: "external-session-live-test",
               payload: %{
                 "session_id" => session_id,
                 "content" => "external input",
                 "role" => "user",
                 "created_at" => System.system_time(:second)
               }
             })

    SalixAgent.TestSupport.stop_all_agents()
    {:ok, sessions, html} = live(authed_conn(), "/dash/agents/#{aid}/sessions")

    SalixStore.S3.Fake.reset_read_log()
    _html = render_click(element(sessions, "input[name=include_hidden]"))

    refute Enum.any?(
             SalixStore.S3.Fake.read_log(),
             &(&1 == {:get, Keys.ctl_agent(aid)})
           )

    assert html =~ session_id
    assert html =~ "Open"
    refute html =~ "Fork"
    refute html =~ "Compact"

    assert {:error, {:bad_request, message}} =
             SalixAgent.Runtime.fork_session(aid, session_id, %{})

    assert message =~ "internal runtime agents"

    assert {:error, {:bad_request, message}} =
             SalixAgent.Runtime.compact_session(aid, session_id)

    assert message =~ "internal runtime agents"

    assert {:ok, trace} = SalixAgent.Runtime.session_trace(aid, session_id)
    assert trace["runtime_kind"] == "external"
    assert trace["session_id"] == session_id
    assert trace["events"] == []

    SalixStore.S3.Fake.reset_read_log()
    trace_conn = get(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}/trace")
    assert json_response(trace_conn, 200)["runtime_kind"] == "external"

    assert Enum.count(
             SalixStore.S3.Fake.read_log(),
             &(&1 == {:get, Keys.ctl_agent(aid)})
           ) == 1

    {:ok, session_show, html} =
      live(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}")

    assert html =~ "Load trace"
    assert html =~ "Raw JSON"

    html = render_click(session_show, "trace")
    assert html =~ "&quot;runtime_kind&quot;: &quot;external&quot;"
    assert html =~ "&quot;session_id&quot;: &quot;#{session_id}&quot;"

    html =
      session_show
      |> form("form[phx-submit=search]", %{"q" => "external"})
      |> render_submit()

    refute html =~ "Search failed"
  end

  test "agents index renders", %{} do
    {:ok, _view, html} = live(authed_conn(), "/dash/agents")
    assert html =~ "Agents"
    assert html =~ "Status"
  end

  test "archived agents are hidden on the index unless the toggle is on", %{
    group: group,
    template: tmpl
  } do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "ArchivedIdxAgent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"]
        },
        tenant_id()
      )

    assert {:ok, _} = SalixAgent.Control.delete(agent["agent_id"], tenant_id())

    {:ok, view, html} = live(authed_conn(), "/dash/agents")
    assert html =~ "Show archived"
    refute html =~ "ArchivedIdxAgent"

    html = render_click(element(view, "input[name=include_archived]"))
    assert html =~ "ArchivedIdxAgent"
    assert html =~ "archived"
  end

  test "archived agent pages render read-only with a badge", %{group: group, template: tmpl} do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "ArchivedShowAgent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"]
        },
        tenant_id()
      )

    aid = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _} =
             SalixAgent.deliver(
               aid,
               %{
                 kind: "session_create",
                 session_id: session_id,
                 name: "Main",
                 created_at: System.system_time(:second)
               },
               source_message_id: "test:archived-session:#{aid}"
             )

    assert eventually(fn ->
             match?({:ok, _}, SalixAgent.InternalSessionStore.read(aid, session_id))
           end)

    assert {:ok, _} = SalixAgent.Workspace.write(aid, "/notes.txt", "archived history survives")

    assert {:ok, _} = SalixAgent.Control.delete(aid, tenant_id())

    # Agent detail stays reachable, read-only. Archival is one-way: no
    # restore action — a cleanup job will remove the resources later.
    {:ok, show, html} = live(authed_conn(), "/dash/agents/#{aid}")
    assert html =~ "ArchivedShowAgent"
    assert html =~ "archived"
    refute html =~ "Restore"
    refute html =~ "Wake"
    refute html =~ "delete-agent"
    refute html =~ ">Save<"

    # The configuration form renders disabled, not just without a Save button.
    assert html =~ ~r/<input(?=[^>]*name="name")(?=[^>]*\bdisabled\b)/
    assert html =~ ~r/<select(?=[^>]*name="template_id")(?=[^>]*\bdisabled\b)/
    assert html =~ ~r/<textarea(?=[^>]*name="system_prompt")(?=[^>]*\bdisabled\b)/
    assert html =~ ~r/<input(?=[^>]*name="tool_router_enabled")(?=[^>]*\bdisabled\b)/

    # Crafted mutating events are rejected server-side.
    html = render_click(show, "wake-agent")
    assert html =~ "archived and read-only"

    # Sessions index stays reachable without internal-only mutating ops.
    {:ok, _sessions, html} = live(authed_conn(), "/dash/agents/#{aid}/sessions")
    assert html =~ "archived"
    assert html =~ "Open"
    refute html =~ "Fork"
    refute html =~ "Compact"

    # Session detail renders the transcript read-only.
    {:ok, session_show, html} = live(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}")
    assert html =~ "archived"
    assert html =~ "read-only"
    refute html =~ "session-runtime-message-form"

    html = render_click(session_show, "send", %{"content" => "should be rejected"})
    assert html =~ "archived and read-only"

    # The read-only history endpoints linked from these pages keep working:
    # file browser, file download, and the raw session trace.
    {:ok, _files, html} = live(authed_conn(), "/dash/agents/#{aid}/files")
    assert html =~ "notes.txt"

    download_conn = get(authed_conn(), "/dash/agents/#{aid}/files/download?path=/notes.txt")
    assert response(download_conn, 200) =~ "archived history survives"

    trace_conn = get(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}/trace")
    assert %{"usage" => _} = json_response(trace_conn, 200)

    # None of the archived history leaks across tenants.
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Other tenant"})

    other_conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        "admin_authed" => true,
        "current_tenant" => other["tenant_id"]
      })

    assert {:error, {:live_redirect, %{to: "/dash/agents"}}} =
             live(other_conn, "/dash/agents/#{aid}")

    assert {:error, {:live_redirect, %{to: "/dash/agents"}}} =
             live(other_conn, "/dash/agents/#{aid}/files")

    assert get(other_conn, "/dash/agents/#{aid}/sessions/#{session_id}/trace").status == 404
    assert get(other_conn, "/dash/agents/#{aid}/files/download?path=/notes.txt").status == 404
  end

  test "hidden agents stay unreachable by direct URL, active or archived", %{
    group: group,
    template: tmpl
  } do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "HiddenInternalAgent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"]
        },
        tenant_id()
      )

    aid = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _} =
             SalixAgent.deliver(
               aid,
               %{
                 kind: "session_create",
                 session_id: session_id,
                 name: "Main",
                 created_at: System.system_time(:second)
               },
               source_message_id: "test:hidden-agent-session:#{aid}"
             )

    assert eventually(fn ->
             match?({:ok, _}, SalixAgent.InternalSessionStore.read(aid, session_id))
           end)

    # A real workspace file, downloadable while the agent is still visible, so
    # the 404s below prove authorization denial rather than a missing file.
    assert {:ok, _} = SalixAgent.Workspace.write(aid, "/secret.txt", "hidden agent file")

    pre_hidden = get(authed_conn(), "/dash/agents/#{aid}/files/download?path=/secret.txt")
    assert response(pre_hidden, 200) =~ "hidden agent file"

    mark_agent_hidden!(aid)

    # Hidden while active, and hidden while archived: every dashboard
    # entrypoint must refuse to resolve the agent by direct ID.
    assert_hidden_agent_unreachable!(aid, session_id)
    assert {:ok, _} = SalixAgent.Control.delete(aid)
    assert_hidden_agent_unreachable!(aid, session_id)

    # The "Show archived" toggle doesn't reveal it on the index either.
    {:ok, view, _html} = live(authed_conn(), "/dash/agents")
    html = render_click(element(view, "input[name=include_archived]"))
    refute html =~ "HiddenInternalAgent"
  end

  defp assert_hidden_agent_unreachable!(aid, session_id) do
    assert {:error, {:live_redirect, %{to: "/dash/agents"}}} =
             live(authed_conn(), "/dash/agents/#{aid}")

    assert {:error, {:live_redirect, %{to: "/dash/agents"}}} =
             live(authed_conn(), "/dash/agents/#{aid}/sessions")

    assert {:error, {:live_redirect, _}} =
             live(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}")

    assert {:error, {:live_redirect, %{to: "/dash/agents"}}} =
             live(authed_conn(), "/dash/agents/#{aid}/files")

    assert get(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}/trace").status == 404

    assert get(authed_conn(), "/dash/agents/#{aid}/files/download?path=/secret.txt").status ==
             404
  end

  # hidden is not settable through Control.create/update; the meeting runtime
  # writes its internal agent records directly, so the test does the same.
  defp mark_agent_hidden!(agent_id) do
    key = Keys.ctl_agent(agent_id)
    assert {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(key)
    updated = body |> Jason.decode!() |> Map.put("hidden", true)
    assert {:ok, _} = SalixStore.S3.put(key, Jason.encode!(updated), if_match: etag)
    updated
  end

  test "session page shows the models that produced assistant turns", %{
    group: group,
    template: tmpl
  } do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "ModelAgent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"]
        },
        tenant_id()
      )

    aid = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _} =
             SalixAgent.deliver(
               aid,
               %{
                 kind: "session_create",
                 session_id: session_id,
                 name: "Main",
                 created_at: System.system_time(:second)
               },
               source_message_id: "test:model-session:#{aid}"
             )

    assert eventually(fn ->
             match?({:ok, _}, SalixAgent.InternalSessionStore.read(aid, session_id))
           end)

    # The template can change mid-session, so the page reports the models that
    # actually produced assistant turns, in first-use order.
    {:ok, _} =
      SalixAgent.InternalAgentRuntime.seed_transcript(aid, session_id, %{
        "source_id" => "test:model-seed:#{aid}",
        "entries" => [
          %{"role" => "user", "content" => "hello"},
          %{"role" => "assistant", "content" => "hi", "model" => "mock-4o"},
          %{"role" => "user", "content" => "again"},
          %{"role" => "assistant", "content" => "hi again", "model" => "mock-haiku"}
        ]
      })

    {:ok, _view, html} =
      live(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}")

    assert html =~ "mock-4o → mock-haiku"
    assert html =~ "· mock-4o"
    assert html =~ "· mock-haiku"
  end

  test "session page renders trajectory eval findings with evidence", %{
    group: group,
    template: tmpl
  } do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "EvalAgent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"]
        },
        tenant_id()
      )

    aid = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _} =
             SalixAgent.deliver(
               aid,
               %{
                 kind: "session_create",
                 session_id: session_id,
                 name: "Main",
                 created_at: System.system_time(:second)
               },
               source_message_id: "test:eval-session:#{aid}"
             )

    assert eventually(fn ->
             match?({:ok, _}, SalixAgent.InternalSessionStore.read(aid, session_id))
           end)

    {:ok, view, html} = live(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}")
    assert html =~ "Trajectory eval"
    assert html =~ "No trajectory evals yet."

    entry = %{
      "evaluated_at" => "2026-07-08T12:00:00Z",
      "evaluator" => "heuristic",
      "evaluator_version" => "1",
      "outcome" => "final",
      "window" => %{
        "round_id" => "round-live",
        "message_count" => 3,
        "from_message_id" => 2,
        "to_message_id" => 4
      },
      "findings" => [
        %{
          "metric" => "confusion",
          "score" => 0.66,
          "hits" => 2,
          "evidence" => [%{"message_id" => 4, "quote" => "Wait, the table is missing."}]
        }
      ]
    }

    {:ok, _} = SalixAgent.TrajectoryEval.Store.append(aid, session_id, entry)

    html = render_click(element(view, "button[phx-click=refresh]"))

    assert html =~ "confusion"
    # severity renders as a word; the raw score stays in the hover title
    assert html =~ "moderate · 2 hit(s)"
    assert html =~ ~s(title="score 0.66")
    assert html =~ "Wait, the table is missing."
    assert html =~ "round-live"
    refute html =~ "No trajectory evals yet."
    refute html =~ "settles"

    # A same-signature re-eval merges into the newest entry and shows a
    # repeat badge instead of stacking a duplicate card entry.
    {:ok, merged} =
      SalixAgent.TrajectoryEval.Store.append(aid, session_id, %{
        entry
        | "evaluated_at" => "2026-07-08T12:01:00Z"
      })

    assert merged["repeats"] == 2

    html = render_click(element(view, "button[phx-click=refresh]"))
    assert html =~ "×2 settles"

    # LLM judge verdicts attach to the same entry and render as badges.
    :ok =
      SalixAgent.TrajectoryEval.Store.attach_judge(aid, session_id, merged, %{
        "model" => "mock-haiku",
        "prompt_version" => "1",
        "verdicts" => [
          %{
            "metric" => "confusion",
            "verdict" => "confirmed",
            "score" => 0.8,
            "reason" => "The agent restarted its plan.",
            "evidence" => "Wait, the table is missing."
          },
          %{
            "metric" => "shortcut",
            "verdict" => "confirmed",
            "score" => 0.6,
            "reason" => "Skipped a verification step.",
            "evidence" => ""
          },
          %{
            "metric" => "goal_drift",
            "verdict" => "rejected",
            "score" => 0.1,
            "reason" => "On task.",
            "evidence" => ""
          }
        ]
      })

    html = render_click(element(view, "button[phx-click=refresh]"))
    assert html =~ "LLM judge · mock-haiku"
    # The verdict word is dropped; severity (confirmed) / "cleared" (rejected)
    # plus color carry the meaning.
    assert html =~ "severe"
    assert html =~ "moderate"
    assert html =~ "cleared"
    assert html =~ "The agent restarted its plan."
    refute html =~ "confirmed"
    refute html =~ "rejected"
    # rejected verdicts carry no severity — the verdict itself is the answer
    refute html =~ ~s(title="score 0.10")

    # A confirmed problem is colored by severity: the 0.8 one is red, the 0.6
    # one is amber. A cleared false positive recedes to neutral, never green.
    assert html =~ "bg-red-100 text-red-700"
    assert html =~ "bg-amber-100 text-amber-700"
    refute html =~ "bg-emerald"
  end

  defp connected_codex_device!(group_id) do
    transport_id = "env-codex-live-#{System.unique_integer([:positive])}"
    stable_device_id = "device-" <> transport_id

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => stable_device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Mac Studio"
        },
        transport_id: transport_id
      )

    connector_run_id = record["connector_run_id"]

    {:ok, _record} =
      Registry.update_meta(connector_run_id, fn meta ->
        Map.put(meta, "agent_runtimes", [
          %{
            "kind" => "external",
            "provider" => "codex",
            "runtime_id" => "runtime-codex",
            "device_runtime_id" =>
              RuntimeIds.device_runtime_id(stable_device_id, "codex", "runtime-codex"),
            "command" => "/usr/local/bin/codex",
            "version" => "codex-test",
            "version_detected" => true,
            "auth_ready" => true,
            "native_server_startable" => true,
            "ready" => true,
            "readiness_checked_at" => System.system_time(:millisecond),
            "readiness_valid_until" => System.system_time(:millisecond) + 600_000
          }
        ])
      end)

    connector_run_id
  end

  defp codex_runtime_config(env_id) do
    %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => device_id(env_id),
      "runtime_id" => "runtime-codex",
      "device_runtime_id" => device_runtime_id(env_id)
    }
  end

  defp device_id(connector_run_id) do
    {:ok, _transport_id, device} = Registry.get_by_connector_run_id(connector_run_id)
    device["device_id"]
  end

  defp device_runtime_id(env_id),
    do: RuntimeIds.device_runtime_id(device_id(env_id), "codex", "runtime-codex")

  defp eventually(fun, retries \\ 100) do
    case fun.() do
      true -> true
      _ when retries <= 0 -> false
      _ -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp connected_device_without_runtime!(group_id) do
    transport_id = "env-empty-live-#{System.unique_integer([:positive])}"
    stable_device_id = "device-" <> transport_id

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => stable_device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Runtime Empty"
        },
        transport_id: transport_id
      )

    record["connector_run_id"]
  end
end
