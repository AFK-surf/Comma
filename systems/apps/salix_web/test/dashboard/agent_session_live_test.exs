defmodule SalixWeb.Dashboard.AgentSessionLiveTest do
  @moduledoc "Agent create/list/show and session listing via LiveView."
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixStore.Keys

  @endpoint SalixWeb.DashboardEndpoint

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Agent sessions"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "AgentGrp"}, tenant_id())
    SalixAgent.TestSupport.configure_platform_models!()
    %{group: group}
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "create an agent via the new form", %{group: group} do
    {:ok, view, _html} = live(authed_conn(), "/dash/agents/new")

    {:ok, _show, html} =
      view
      |> form("form[phx-submit=create]", %{
        "name" => "CI Agent",
        "group_id" => group["group_id"],
        "model" => "gpt-5.5",
        "role" => "worker"
      })
      |> render_submit()
      |> follow_redirect(authed_conn())

    assert html =~ "CI Agent"

    created =
      tenant_id()
      |> SalixAgent.Control.list(group_id: group["group_id"])
      |> Enum.find(&(&1["name"] == "CI Agent"))

    assert created["runtime_config"] == %{"kind" => "internal"}
    assert %{"kind" => "catalog", "model" => "gpt-5.5"} = created["model"]
  end

  test "agent show saves, toggles hidden sessions, and sends runtime messages", %{
    group: group
  } do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "ShowAgent",
          "group_id" => group["group_id"]
        },
        tenant_id()
      )

    aid = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    {:ok, show, _html} = live(authed_conn(), "/dash/agents/#{aid}")

    html =
      render_submit(
        form(show, "form[phx-submit=save]", %{"name" => "ShowAgent v2", "model" => "gpt-5.5"})
      )

    assert html =~ "Agent saved"

    assert {:ok, %{"model" => %{"kind" => "catalog", "model" => "gpt-5.5"}}} =
             SalixAgent.Control.get(aid, tenant_id())

    # The empty option clears the choice: the Agent follows the platform model.
    render_submit(form(show, "form[phx-submit=save]", %{"model" => ""}))
    assert {:ok, %{"model" => nil}} = SalixAgent.Control.get(aid, tenant_id())
    assert html =~ "Group conversations"
    assert html =~ "/dash/groups/#{group["group_id"]}?tab=conversations"

    assert {:ok, _} =
             SalixAgent.deliver(
               aid,
               %{
                 kind: "session_create",
                 session_id: session_id,
                 name: "Main",
                 created_at: SystemsClock.system_time(:second)
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
                 created_at: SystemsClock.system_time(:second)
               },
               source_message_id: "test:hidden-session:#{hidden_session_id}"
             )

    assert eventually(fn ->
             match?({:ok, _}, SalixAgent.InternalSessionStore.read(aid, hidden_session_id))
           end)

    {:ok, sessions, html} = live(authed_conn(), "/dash/agents/#{aid}/sessions")
    assert html =~ "Show hidden"
    refute html =~ "Hidden runtime session"

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

  test "archived agent pages render read-only with a badge", %{group: group} do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "ArchivedShowAgent",
          "group_id" => group["group_id"]
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
                 created_at: SystemsClock.system_time(:second)
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
    assert html =~ ~r/<select(?=[^>]*name="model")(?=[^>]*\bdisabled\b)/
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
    group: group
  } do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "HiddenInternalAgent",
          "group_id" => group["group_id"]
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
                 created_at: SystemsClock.system_time(:second)
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

  defp eventually(fun, retries \\ 1500) do
    case fun.() do
      true -> true
      _ when retries <= 0 -> false
      _ -> SystemsRuntime.Proc.sleep(20) && eventually(fun, retries - 1)
    end
  end
end
