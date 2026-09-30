defmodule SalixWeb.Dashboard.SlackCommandsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SalixIM.{SlackCommands, SlackCommandSync, ProviderConnects, SlackCommandTemplates}
  alias SalixStore.SlackCommandControl
  @endpoint SalixWeb.DashboardEndpoint

  @tag skip: System.get_env("SALIX_COMMAND_BROWSER") != "1"
  @tag timeout: 180_000
  test "browser command scopes and draft protection", ctx do
    app = connect(ctx)
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Empty organization"})

    server =
      start_supervised!({Bandit, plug: SalixWeb.DashboardEndpoint, port: 0},
        id: :browser_dashboard
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    script = Path.expand("../assets/command_scopes_browser.mjs", __DIR__)

    {output, status} =
      System.cmd("node", [script],
        stderr_to_stdout: true,
        env: [
          {"COMMAND_BROWSER_URL", "http://127.0.0.1:#{port}"},
          {"COMMAND_BROWSER_TENANT", ctx.tenant},
          {"COMMAND_BROWSER_OTHER", other["tenant_id"]},
          {"COMMAND_BROWSER_APP_PATH", path(ctx, app)},
          {"COMMAND_BROWSER_SLACK", Application.fetch_env!(:salix_im, :slack_api_base_url)}
        ]
      )

    assert status == 0, output
    assert {:ok, %{"commands" => []}} = SlackCommandTemplates.get(other["tenant_id"])
  end

  test "connections without an App binding have no command authority" do
    for connect <- [%{}, %{"app_id" => nil}, %{"app_id" => ""}] do
      connect =
        Map.put(connect, "slack_commands", %{
          "app_id" => connect["app_id"],
          "commands" => SlackCommands.task_aliases()
        })

      assert SlackCommands.list(connect) == []
      assert {:error, :command_unavailable} = SlackCommands.resolve(connect, "/newgpttask")
      assert is_binary(ProviderConnects.slack_oauth_url(connect))
    end
  end

  defmodule Slack do
    use Agent
    import Plug.Conn

    def start_link(_),
      do: Agent.start_link(fn -> %{apps: %{}, calls: [], fail: nil} end, name: __MODULE__)

    def init(opts), do: opts
    def set_app(id, manifest), do: Agent.update(__MODULE__, &put_in(&1, [:apps, id], manifest))
    def app(id), do: Agent.get(__MODULE__, & &1.apps[id])
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def fail(mode), do: Agent.update(__MODULE__, &%{&1 | fail: mode})

    def call(conn, _) do
      {:ok, body, conn} = read_body(conn)

      params =
        URI.decode_query(body)
        |> Map.put("_auth", List.first(get_req_header(conn, "authorization")))

      method = List.last(conn.path_info)

      {status, response} =
        Agent.get_and_update(__MODULE__, fn state ->
          state = %{state | calls: [{method, params} | state.calls]}

          cond do
            method == "test.fail" ->
              mode =
                case params["mode"] do
                  "rate_limit" -> :rate_limit
                  "lost_response" -> :lost_response
                  _ -> nil
                end

              {{200, %{"ok" => true}}, %{state | fail: mode}}

            method == "tooling.tokens.rotate" ->
              {{200,
                %{
                  "ok" => true,
                  "token" => "xoxe.access",
                  "refresh_token" => "xoxe-rotated",
                  "exp" => System.system_time(:second) + 43200
                }}, state}

            method == "apps.manifest.export" and state.fail == :deny_export ->
              {{200, %{"ok" => false, "error" => "access_denied"}}, state}

            method == "apps.manifest.export" ->
              {{200, %{"ok" => true, "manifest" => state.apps[params["app_id"]]}}, state}

            method == "apps.manifest.validate" ->
              {{200, %{"ok" => true}}, state}

            method == "apps.manifest.update" and state.fail == :rate_limit ->
              {{429, %{"ok" => false}}, state}

            method == "apps.manifest.update" and state.fail == :reject_update ->
              {{200, %{"ok" => false, "error" => "invalid_manifest"}}, state}

            method == "apps.manifest.update" ->
              next = Jason.decode!(params["manifest"])
              old = state.apps[params["app_id"]]

              changed =
                get_in(old, ["oauth_config", "scopes"]) !=
                  get_in(next, ["oauth_config", "scopes"])

              updated = put_in(state, [:apps, params["app_id"]], next)

              case state.fail do
                :lost_response ->
                  {{503, %{"ok" => false}}, updated}

                :internal_error ->
                  {{200, %{"ok" => false, "error" => "internal_error"}}, updated}

                :verify_denied ->
                  {{200, %{"ok" => true, "permissions_updated" => changed}},
                   %{updated | fail: :deny_export}}

                _ ->
                  {{200, %{"ok" => true, "permissions_updated" => changed}}, updated}
              end
          end
        end)

      conn
      |> put_resp_header("retry-after", "60")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  setup do
    start_supervised!(Slack)

    port =
      Enum.find_value(1..10, fn _ ->
        port = 40_000 + :erlang.phash2(make_ref(), 20_000)

        case start_supervised({Bandit, plug: Slack, port: port}, id: {:bandit, port}) do
          {:ok, _} -> port
          _ -> nil
        end
      end)

    previous =
      for key <- [:slack_api_base_url, :public_base_url],
          into: %{},
          do: {key, Application.fetch_env(:salix_im, key)}

    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    Application.put_env(:salix_im, :public_base_url, "https://salix.example")

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:salix_im, key, v)
          :error -> Application.delete_env(:salix_im, key)
        end
      end
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Slash commands"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Slash group"}, tenant_id)

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "role" => "router", "name" => "Router"},
        tenant_id
      )

    {:ok, _} =
      Salix.Control.Groups.update(group["group_id"], %{"router_agent_id" => router["agent_id"]})

    %{tenant: tenant_id, group: group["group_id"]}
  end

  defp connect(ctx) do
    id = "A#{System.unique_integer([:positive])}"

    {:ok, connect} =
      ProviderConnects.create_slack_im_connect(ctx.tenant, ctx.group, %{
        "app_id" => id,
        "app_name" => "Team Assistant #{id}",
        "client_id" => id,
        "client_secret" => "secret",
        "signing_secret" => "sign"
      })

    Slack.set_app(id, manifest())
    connect
  end

  defp manifest do
    %{
      "display_information" => %{"name" => "Keep me"},
      "settings" => %{
        "interactivity" => %{
          "is_enabled" => true,
          "request_url" => "https://other.example/interactions"
        }
      },
      "features" => %{
        "slash_commands" => [
          %{
            "command" => "/unrelated",
            "description" => "Keep",
            "url" => "https://other.example/command"
          }
        ]
      },
      "oauth_config" => %{"scopes" => %{"bot" => ["commands", "chat:write"]}}
    }
  end

  defp entry(prompt \\ "Review: ") do
    %{
      "command" => "/review",
      "description" => "Review code",
      "usage_hint" => "<link>",
      "prompt" => prompt,
      "enabled" => true
    }
  end

  defp raw(ctx, connect) do
    {:ok, record} = ProviderConnects.fetch_im_connect(ctx.group, connect["connect_id"])
    record
  end

  defp save(ctx, connect, revision, entries),
    do:
      SlackCommands.save(
        ctx.tenant,
        ctx.group,
        connect["connect_id"],
        connect["app_id"],
        revision,
        entries
      )

  defp authed(ctx),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => ctx.tenant})

  defp path(ctx, connect), do: "/dash/groups/#{ctx.group}/slack/#{connect["connect_id"]}/commands"

  defp copy_template(ctx, app, app_revision, template_revision, command \\ "/review"),
    do:
      SlackCommandTemplates.copy(
        ctx.tenant,
        ctx.group,
        app["connect_id"],
        app["app_id"],
        app_revision,
        template_revision,
        command
      )

  defp open_custom(view) do
    view |> element("button[phx-click=new]") |> render_click()
    view |> element("button[phx-click=custom]") |> render_click()
  end

  test "App enable changes are drafts until publish; template defaults remain independent", ctx do
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    {:ok, _} = save(ctx, app, 0, [entry()])
    {:ok, view, _} = live(authed(ctx), path(ctx, app))

    for enabled <- ["false", "true"] do
      view |> element("button[phx-click=edit][phx-value-command='/review']") |> render_click()
      before = Slack.calls()

      view
      |> form("#slack-command-form", %{"entry" => Map.put(entry(), "enabled", enabled)})
      |> render_change()

      assert Slack.calls() == before

      assert SlackCommands.list(raw(ctx, app)) |> hd() |> Map.fetch!("enabled") ==
               (enabled == "false")

      view
      |> form("#slack-command-form", %{"entry" => Map.put(entry(), "enabled", enabled)})
      |> render_submit()

      render_async(view)

      assert SlackCommands.list(raw(ctx, app)) |> hd() |> Map.fetch!("enabled") ==
               (enabled == "true")
    end

    selector = "button[phx-click=set-enabled][phx-value-command='/review']"
    {:ok, _} = SlackCommandTemplates.save(ctx.tenant, 0, [entry()])
    {:ok, templates, _} = live(authed(ctx), "/dash/slack-command-templates")
    calls = Slack.calls()
    templates |> element(selector) |> render_click()
    render_async(templates)
    assert has_element?(templates, selector <> "[phx-value-enabled=true]", "Enable")
    assert Slack.calls() == calls
    assert {:ok, "Review: "} = SlackCommands.resolve(raw(ctx, app), "/review")
    second = connect(ctx)
    assert {:ok, _} = copy_template(ctx, second, 0, 2)
    assert [%{"enabled" => false}] = SlackCommands.list(raw(ctx, second))
    calls = Slack.calls()
    templates |> element(selector) |> render_click()
    render_async(templates)
    assert has_element?(templates, selector <> "[phx-value-enabled=false]", "Disable")
    assert Slack.calls() == calls
    assert [%{"enabled" => false}] = SlackCommands.list(raw(ctx, second))
  end

  test "template copies are independent across Apps and tenants", ctx do
    a = connect(ctx)
    b = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    calls = Slack.calls()
    assert {:ok, _} = SlackCommandTemplates.save(ctx.tenant, 0, [entry()])
    assert Slack.calls() == calls
    assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, a), "/review")
    assert {:ok, _} = copy_template(ctx, a, 0, 1)
    assert {:ok, "Review: "} = SlackCommands.resolve(raw(ctx, a), "/review")
    calls = Slack.calls()
    assert {:ok, _} = SlackCommandTemplates.save(ctx.tenant, 1, [entry("Updated: ")])
    assert Slack.calls() == calls
    assert {:ok, "Review: "} = SlackCommands.resolve(raw(ctx, a), "/review")
    assert {:ok, _} = copy_template(ctx, b, 0, 2)
    assert {:ok, "Updated: "} = SlackCommands.resolve(raw(ctx, b), "/review")
    assert {:ok, _} = SlackCommandTemplates.save(ctx.tenant, 2, [])
    assert {:ok, %{"commands" => []}} = SlackCommandTemplates.get(ctx.tenant)
    assert {:ok, "Updated: "} = SlackCommands.resolve(raw(ctx, b), "/review")
    assert {:ok, _} = save(ctx, a, 1, [])
    assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, a), "/review")
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Other templates"})
    assert {:ok, %{"commands" => defaults}} = SlackCommandTemplates.get(other["tenant_id"])
    assert defaults == []
    assert SlackCommandTemplates.built_ins() == SlackCommands.task_aliases()

    assert {:error, :command_template_missing} =
             copy_template(%{ctx | tenant: other["tenant_id"]}, a, 2, 0, "/newgpttask")
  end

  test "template revisions, App revisions, and existing names fail closed", ctx do
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    assert {:ok, _} = SlackCommandTemplates.save(ctx.tenant, 0, [entry()])
    assert {:error, :command_templates_changed} = SlackCommandTemplates.save(ctx.tenant, 0, [])
    assert {:error, :command_templates_changed} = copy_template(ctx, app, 0, 0)
    assert {:error, :command_template_missing} = copy_template(ctx, app, 0, 1, "/missing")
    assert {:ok, _} = save(ctx, app, 0, [entry("Private: ")])
    assert {:error, :command_template_conflict} = copy_template(ctx, app, 1, 1)
    assert {:ok, "Private: "} = SlackCommands.resolve(raw(ctx, app), "/review")

    assert {:ok, _} =
             SlackCommandTemplates.save(ctx.tenant, 1, [Map.put(entry(), "command", "/proto")])

    assert {:error, :command_configuration_changed} = copy_template(ctx, app, 0, 2, "/proto")

    assert {:error, :invalid_commands} =
             SlackCommandTemplates.save(ctx.tenant, 2, [entry(), entry()])

    assert {:error, :invalid_commands} = SlackCommandTemplates.save(ctx.tenant, 2, [entry("")])
  end

  test "template admin CRUD and App copy use real LiveView and Slack sync", ctx do
    path = "/dash/slack-command-templates"
    assert {:error, {:redirect, %{to: "/dash/login"}}} = live(build_conn(), path)
    {:ok, view, html} = live(authed(ctx), path)
    assert html =~ "/newgpttask"
    calls = Slack.calls()

    view
    |> form("#slack-template-form", %{"entry" => Map.put(entry(), "enabled", "true")})
    |> render_submit()

    assert render_async(view) =~ "Template catalog saved"
    assert Slack.calls() == calls
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    {:ok, app_view, _} = live(authed(ctx), path(ctx, app))
    calls = Slack.calls()
    app_view |> element("button[phx-click=new]") |> render_click()

    app_view
    |> element("button[phx-click=copy-template][phx-value-command='/review']")
    |> render_click()

    assert Slack.calls() == calls
    assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, app), "/review")

    app_view
    |> form("#slack-command-form", %{"entry" => Map.put(entry(), "enabled", "true")})
    |> render_submit()

    assert render_async(app_view) =~ "Configured enabled"
    assert {:ok, "Review: "} = SlackCommands.resolve(raw(ctx, app), "/review")
    assert Enum.any?(Slack.calls(), &(elem(&1, 0) == "apps.manifest.update"))
    view |> element("button[phx-click=edit][phx-value-command='/review']") |> render_click()

    view
    |> form("#slack-template-form", %{
      "entry" => entry("Changed template: ") |> Map.put("enabled", "false")
    })
    |> render_submit()

    assert render_async(view) =~ "Disabled"
    view |> element("button[phx-click=edit][phx-value-command='/review']") |> render_click()
    view |> element("button[phx-click=delete][phx-value-command='/review']") |> render_click()
    render_async(view)
    assert {:ok, "Review: "} = SlackCommands.resolve(raw(ctx, app), "/review")
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Isolated templates"})
    {:ok, _, other_html} = live(authed(%{ctx | tenant: other["tenant_id"]}), path)
    refute other_html =~ "Changed template: "
  end

  test "App picker and organization switching never retain another organization's App", ctx do
    app = connect(ctx)
    {:ok, _, html} = live(authed(ctx), "/dash/slack-commands")
    assert html =~ app["app_id"]
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Command isolation"})

    {:ok, _, other_html} =
      live(authed(%{ctx | tenant: other["tenant_id"]}), "/dash/slack-commands")

    refute other_html =~ app["app_id"]
    assert other_html =~ "No Slack Apps in this organization"

    conn =
      authed(ctx)
      |> Plug.Conn.put_req_header("referer", "http://www.example.com" <> path(ctx, app))
      |> get("/dash/tenant/select", %{tenant_id: other["tenant_id"]})

    assert redirected_to(conn) == "/dash/slack-commands"
    assert Plug.Conn.get_session(conn, "current_tenant") == other["tenant_id"]
  end

  test "built-ins are separate editable drafts, not implicit organization or App commands", ctx do
    assert {:ok, %{"commands" => []}} = SlackCommandTemplates.get(ctx.tenant)
    {:ok, view, html} = live(authed(ctx), "/dash/slack-command-templates")
    assert html =~ "Built-in template library"
    refute has_element?(view, "#slack-template-list")
    calls = Slack.calls()

    view
    |> element("button[phx-click=use-builtin][phx-value-command='/newgpttask']")
    |> render_click()

    assert has_element?(view, "input[name='entry[command]'][value='/newgpttask']")
    assert {:ok, %{"commands" => []}} = SlackCommandTemplates.get(ctx.tenant)
    builtin = hd(SlackCommandTemplates.built_ins())

    view
    |> form("#slack-template-form", %{"entry" => Map.put(builtin, "enabled", "true")})
    |> render_submit()

    render_async(view)
    assert {:ok, %{"commands" => [^builtin]}} = SlackCommandTemplates.get(ctx.tenant)
    assert Slack.calls() == calls

    app = connect(ctx)
    {:ok, app_view, _} = live(authed(ctx), path(ctx, app))
    calls = Slack.calls()
    app_view |> element("button[phx-click=new]") |> render_click()

    app_view
    |> element("button[phx-click=use-builtin][phx-value-command='/newgpttask']")
    |> render_click()

    assert SlackCommands.list(raw(ctx, app)) == []
    assert has_element?(app_view, "input[name='entry[command]'][value='/newgpttask']")
    assert Slack.calls() == calls
  end

  test "multiple Apps require selection and the chooser rejects unknown connections", ctx do
    first = connect(ctx)
    second = connect(ctx)
    {:ok, chooser, _} = live(authed(ctx), "/dash/slack-commands")
    assert has_element?(chooser, "#slack-app-select option[value='']")

    chooser
    |> form("#slack-app-picker", %{"connect_id" => second["connect_id"]})
    |> render_change()

    assert_redirect(chooser, path(ctx, second))

    {:ok, editor, _} = live(authed(ctx), path(ctx, first))
    render_change(editor, "select-app", %{"connect_id" => "foreign-connect"})

    assert has_element?(
             editor,
             "#slack-app-select option[selected][value='#{first["connect_id"]}']"
           )

    open_custom(editor)
    render_change(editor, "select-app", %{"connect_id" => second["connect_id"]})

    assert has_element?(
             editor,
             "#slack-app-select option[selected][value='#{first["connect_id"]}']"
           )

    assert has_element?(editor, "#slack-command-form")
  end

  test "preview preserves exact prefix and never writes or synchronizes", ctx do
    app = connect(ctx)
    {:ok, view, _} = live(authed(ctx), path(ctx, app))
    open_custom(view)
    calls = Slack.calls()

    view
    |> form("#slack-command-form", %{
      "entry" => entry("Prefix:") |> Map.put("enabled", "true"),
      "sample" => "User text"
    })
    |> render_change()

    assert has_element?(view, "#command-request-preview", "Prefix:User text")
    assert Slack.calls() == calls
    assert SlackCommands.list(raw(ctx, app)) == []
    assert has_element?(view, "#slack-command-form button[type=submit][disabled]")
  end

  test "saved configuration does not claim Slack synchronization succeeded", ctx do
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    Slack.fail(:rate_limit)
    {:ok, view, _} = live(authed(ctx), path(ctx, app))
    open_custom(view)

    view
    |> form("#slack-command-form", %{"entry" => Map.put(entry(), "enabled", "true")})
    |> render_submit()

    html = render_async(view)
    assert html =~ "Slack rejected this update attempt"
    refute html =~ "Slack may already have received the update"
    assert html =~ "60 seconds"
    assert SlackCommands.list(raw(ctx, app)) == [entry()]
  end

  test "stale template forms retain drafts and empty catalogs stay empty after reload", ctx do
    path = "/dash/slack-command-templates"
    {:ok, view, _} = live(authed(ctx), path)
    assert {:ok, _} = SlackCommandTemplates.save(ctx.tenant, 0, [])

    view
    |> form("#slack-template-form", %{"entry" => Map.put(entry(), "enabled", "true")})
    |> render_submit()

    html = render_async(view)
    assert html =~ "Templates changed"
    assert html =~ "Review: "
    assert {:ok, %{"commands" => []}} = SlackCommandTemplates.get(ctx.tenant)
    view |> element("button[phx-click=reload]") |> render_click()
    assert render(view) =~ "No command templates"
    refute has_element?(view, "#slack-template-list")
  end

  test "save synchronizes one App, preserves unrelated manifest, and hot updates prompts", ctx do
    a = connect(ctx)
    b = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    assert {:ok, %{"status" => "synced"}} = save(ctx, a, 0, [entry()])
    assert Slack.app(b["app_id"]) == manifest()
    remote = Slack.app(a["app_id"])
    assert remote["settings"] == manifest()["settings"]
    assert remote["display_information"] == manifest()["display_information"]
    assert hd(remote["features"]["slash_commands"])["command"] == "/unrelated"
    assert {:ok, "Review: "} = SlackCommands.resolve(raw(ctx, a), "/review")
    assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, b), "/review")
    updates = Enum.count(Slack.calls(), &(elem(&1, 0) == "apps.manifest.update"))
    assert {:ok, _} = save(ctx, a, 1, [entry("Changed: ")])
    assert {:ok, "Changed: "} = SlackCommands.resolve(raw(ctx, a), "/review")
    assert updates == Enum.count(Slack.calls(), &(elem(&1, 0) == "apps.manifest.update"))
    assert {:ok, _} = save(ctx, b, 0, [entry("B: ")])
    assert {:ok, "B: "} = SlackCommands.resolve(raw(ctx, b), "/review")
    assert {:error, :command_configuration_changed} = save(ctx, a, 0, [entry("stale")])
    assert {:ok, "Changed: "} = SlackCommands.resolve(raw(ctx, a), "/review")
  end

  test "Apps can select independent credential profiles without copying refresh chains", ctx do
    a = connect(ctx)
    b = connect(ctx)
    expiry = System.system_time(:second) + 43_200

    for profile <- ["first", "second"] do
      assert :ok =
               SlackCommandControl.exclusive(fn ->
                 SlackCommandControl.put_credential(
                   ctx.tenant,
                   %{"token" => profile, "refresh_token" => "xoxe-" <> profile, "exp" => expiry},
                   profile
                 )
               end)
    end

    assert {:ok, _} =
             SlackCommands.save(
               ctx.tenant,
               ctx.group,
               a["connect_id"],
               a["app_id"],
               0,
               [entry()],
               "first"
             )

    assert {:ok, _} =
             SlackCommands.save(
               ctx.tenant,
               ctx.group,
               b["connect_id"],
               b["app_id"],
               0,
               [entry()],
               "second"
             )

    for {app, profile} <- [{a, "first"}, {b, "second"}] do
      requests =
        Enum.filter(Slack.calls(), fn {_, params} -> params["app_id"] == app["app_id"] end)

      assert requests != []
      assert Enum.all?(requests, fn {_, params} -> params["_auth"] == "Bearer " <> profile end)
    end

    snapshot = raw(ctx, a)

    assert {:ok, _} =
             SlackCommands.save(
               ctx.tenant,
               ctx.group,
               a["connect_id"],
               a["app_id"],
               1,
               [entry("New")],
               "first"
             )

    assert :ok = ProviderConnects.verify_slack_triage_connect_snapshot(snapshot)
  end

  test "lost update response retains ownership for a later deletion", ctx do
    for mode <- [:lost_response, :internal_error] do
      app = connect(ctx)
      :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
      Slack.fail(mode)

      assert {:ok,
              %{"status" => "failed", "failure_stage" => "update", "failure_outcome" => "unknown"}} =
               save(ctx, app, 0, [entry()])

      {:ok, _, html} = live(authed(ctx), path(ctx, app))
      assert html =~ "Slack may already have received the update"

      assert Enum.any?(
               Slack.app(app["app_id"])["features"]["slash_commands"],
               &(&1["command"] == "/review")
             )

      Slack.fail(nil)
      assert {:ok, %{"status" => "synced"}} = save(ctx, app, 1, [])

      assert Slack.app(app["app_id"])["features"]["slash_commands"] ==
               manifest()["features"]["slash_commands"]

      assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, app), "/review")
    end
  end

  test "scope changes require reauthorization even after an ambiguous update", ctx do
    app = connect(ctx)

    Slack.set_app(
      app["app_id"],
      put_in(manifest(), ["oauth_config", "scopes", "bot"], ["chat:write"])
    )

    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    Slack.fail(:lost_response)
    assert {:ok, %{"status" => "failed"}} = save(ctx, app, 0, [entry()])
    Slack.fail(nil)

    assert {:ok, %{"status" => "reauthorization_required"}} =
             SlackCommands.retry_sync(ctx.tenant, ctx.group, app["connect_id"], app["app_id"])
  end

  test "rate limits keep local changes and provide retry without leaking credentials", ctx do
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    Slack.fail(:rate_limit)
    assert {:ok, state} = save(ctx, app, 0, [entry()])
    assert state["status"] == "failed"
    assert state["failure_outcome"] == "rejected"
    assert state["failure_stage"] == "update"
    assert state["error"] =~ "60 seconds"
    assert {:ok, "Review: "} = SlackCommands.resolve(raw(ctx, app), "/review")
    assert {:ok, credential} = SlackCommandControl.credential(ctx.tenant)
    assert credential["refresh_token"] == "xoxe-rotated"
    {:ok, stored} = SalixStore.TenantConfigs.get(ctx.tenant, "slack_command_configuration")
    refute inspect(stored) =~ "xoxe-rotated"
    {:ok, _, html} = live(authed(ctx), path(ctx, app))
    refute html =~ "xoxe-rotated"
    refute html =~ "xoxe.access"
    assert html =~ "Slack rejected this update attempt"
    refute html =~ "Slack may already have received the update"
    Slack.fail(nil)

    assert {:ok, %{"status" => "synced", "failure_outcome" => nil, "failure_stage" => nil}} =
             SlackCommands.retry_sync(ctx.tenant, ctx.group, app["connect_id"], app["app_id"])
  end

  test "missing credentials stop before sending a manifest update", ctx do
    app = connect(ctx)

    assert {:ok,
            %{"status" => "failed", "failure_stage" => "prepare", "failure_outcome" => "not_sent"}} =
             save(ctx, app, 0, [entry()])

    assert Slack.calls() == []
    {:ok, _, html} = live(authed(ctx), path(ctx, app))
    assert html =~ "This attempt did not send an update to Slack"
    refute html =~ "Slack may already have received the update"
  end

  test "Slack rejects an update without changing its manifest", ctx do
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    Slack.fail(:reject_update)

    assert {:ok,
            %{"status" => "failed", "failure_stage" => "update", "failure_outcome" => "rejected"}} =
             save(ctx, app, 0, [entry()])

    assert Slack.app(app["app_id"]) == manifest()
    {:ok, _, html} = live(authed(ctx), path(ctx, app))
    assert html =~ "Slack rejected this update attempt"
    refute html =~ "Slack may already have received the update"
  end

  test "a rejected verification read leaves the accepted update unconfirmed", ctx do
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    Slack.fail(:verify_denied)

    assert {:ok,
            %{"status" => "failed", "failure_stage" => "verify", "failure_outcome" => "unknown"}} =
             save(ctx, app, 0, [entry()])

    assert Enum.any?(
             Slack.app(app["app_id"])["features"]["slash_commands"],
             &(&1["command"] == "/review")
           )

    {:ok, _, html} = live(authed(ctx), path(ctx, app))
    assert html =~ "Slack may already have received the update"
    Slack.fail(nil)

    assert {:ok, %{"status" => "synced", "failure_outcome" => nil}} =
             SlackCommands.retry_sync(ctx.tenant, ctx.group, app["connect_id"], app["app_id"])

    assert Enum.count(Slack.calls(), &(elem(&1, 0) == "apps.manifest.update")) == 1
  end

  test "dashboard requires admin and selected tenant, then saves through real sync", ctx do
    app = connect(ctx)
    assert {:error, {:redirect, %{to: "/dash/login"}}} = live(build_conn(), path(ctx, app))
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Other"})

    assert {:error, :not_found} =
             SlackCommands.get(other["tenant_id"], ctx.group, app["connect_id"])

    assert {:error, {:live_redirect, %{to: "/dash/im"}}} =
             live(authed(%{ctx | tenant: other["tenant_id"]}), path(ctx, app))

    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    {:ok, view, _} = live(authed(ctx), path(ctx, app))
    open_custom(view)

    view
    |> form("#slack-command-form", %{"entry" => entry() |> Map.put("enabled", "true")})
    |> render_submit()

    html = render_async(view)
    assert html =~ "Latest App configuration synchronized to Slack"
    assert {:ok, "Review: "} = SlackCommands.resolve(raw(ctx, app), "/review")
    view |> element("button[phx-click=edit][phx-value-command='/review']") |> render_click()
    view |> element("button[phx-click=delete][phx-value-command='/review']") |> render_click()
    render_async(view)
    assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, app), "/review")
  end

  test "migration preserves legacy local behavior without registering Apps or restoring deletions",
       ctx do
    legacy = connect(ctx)
    fresh = connect(ctx)
    key = SalixStore.Keys.ctl_im_connect(ctx.group, legacy["connect_id"])
    {:ok, _} = SalixStore.CasRecord.update(key, &Map.delete(&1, "slack_commands"), create: false)

    migration =
      Path.expand(
        "../../../salix_store/priv/repo/migrations/20260917113000_materialize_slack_task_aliases.exs",
        __DIR__
      )

    Code.require_file(migration)
    module = SalixStore.Repo.Migrations.MaterializeSlackTaskAliases
    assert :ok = module.up()
    assert {:ok, _} = SlackCommands.resolve(raw(ctx, legacy), "/newgpttask")
    assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, fresh), "/newgpttask")
    assert Slack.calls() == []

    {:ok, _} =
      SlackCommands.update(
        ctx.group,
        legacy["connect_id"],
        legacy["app_id"],
        &Map.put(&1, "commands", [])
      )

    assert :ok = module.up()
    assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, legacy), "/newgpttask")
  end

  test "disabling and rebinding cannot use another App's aliases", ctx do
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")
    assert {:ok, _} = save(ctx, app, 0, [entry()])
    assert {:ok, _} = save(ctx, app, 1, [%{entry() | "enabled" => false}])
    assert {:error, :command_unavailable} = SlackCommands.resolve(raw(ctx, app), "/review")

    refute Enum.any?(
             Slack.app(app["app_id"])["features"]["slash_commands"],
             &(&1["command"] == "/review")
           )

    {:ok, _} =
      ProviderConnects.update_slack_im_connect(ctx.tenant, ctx.group, app["connect_id"], %{
        "app_id" => app["app_id"] <> "NEW"
      })

    assert {:error, :command_app_changed} = save(ctx, app, 2, [entry()])
    assert SlackCommands.list(raw(ctx, app)) == []
  end

  test "one admin mutation cannot overlap another, including across Apps" do
    parent = self()

    task =
      Task.async(fn ->
        SlackCommandControl.exclusive(fn ->
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked

    assert {:error, :command_admin_busy} =
             SlackCommandControl.exclusive(fn -> flunk("must not run") end)

    send(task.pid, :release)
    assert Task.await(task) == :ok
    assert :ok = SlackCommandControl.exclusive(fn -> :ok end)
  end

  test "conflicting handlers and duplicate names fail without overwriting remote configuration",
       ctx do
    app = connect(ctx)
    :ok = SlackCommandSync.configure_credential(ctx.tenant, "xoxe-initial")

    remote =
      put_in(manifest(), ["features", "slash_commands"], [
        %{
          "command" => "/review",
          "description" => "Other handler",
          "url" => "https://other.example/review"
        }
      ])

    Slack.set_app(app["app_id"], remote)

    assert {:ok,
            %{
              "status" => "failed",
              "failure_stage" => "prepare",
              "failure_outcome" => "not_sent",
              "error" => error
            }} = save(ctx, app, 0, [entry()])

    refute Enum.any?(Slack.calls(), &(elem(&1, 0) == "apps.manifest.update"))
    {:ok, _, html} = live(authed(ctx), path(ctx, app))
    assert html =~ "This attempt did not send an update to Slack"
    refute html =~ "Slack may already have received the update"
    assert error =~ "another handler"
    assert Slack.app(app["app_id"]) == remote
    assert {:error, :invalid_commands} = save(ctx, app, 1, [entry(), entry()])
    assert {:error, :invalid_commands} = save(ctx, app, 1, [%{entry() | "prompt" => ""}])
  end
end
