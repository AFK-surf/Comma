defmodule BridgeForTeamsWeb.Dashboard.SettingsLiveTest do
  @moduledoc """
  LiveView tests for the org settings page (slice members-settings). Settings is
  split into tabs (General, Models, Single sign-on, OAuth apps), each its own
  route into `SettingsLive`; these tests drive each tab directly. They render the
  sections, update the org name, manage the model allowlist/default, and save an
  SSO connection (verifying the client secret is stored and not echoed back).
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{
    Auth,
    CLI.Login,
    Memberships,
    Observability,
    OrgComposioSettings,
    OrgOAuthApps,
    OrgSignalNumber,
    Orgs,
    Projects
  }

  alias BridgeForTeams.Repo
  @icon "data:image/png;base64,iVBORw0KGgo="

  defmodule FeishuRouteSummaryClient do
    @moduledoc false

    def list_group_im_connects(group_id, "feishu") do
      {:ok,
       [
         %{
           "connect_id" => "feishu-route-1",
           "provider" => "feishu",
           "group_id" => group_id,
           "app_id" => "cli_app",
           "status" => "connected",
           "updated_at" => 1_700_000_000
         }
       ]}
    end
  end

  defmodule FeishuRouteSelectionClient do
    @moduledoc false

    def reset do
      Application.put_env(:bridge_for_teams_web, :feishu_route_selection_connects, %{})
      Application.delete_env(:bridge_for_teams_web, :feishu_route_disable_error)
    end

    def fail_disable(reason) do
      Application.put_env(:bridge_for_teams_web, :feishu_route_disable_error, reason)
    end

    def connects_for(group_id) do
      :bridge_for_teams_web
      |> Application.get_env(:feishu_route_selection_connects, %{})
      |> Map.get(group_id, [])
    end

    def list_group_im_connects(group_id, provider) when provider in [nil, "feishu"] do
      connects =
        :bridge_for_teams_web
        |> Application.get_env(:feishu_route_selection_connects, %{})
        |> Map.get(group_id, [])

      {:ok, connects}
    end

    def create_feishu_im_connect(_tenant_id, group_id, attrs) do
      connect = %{
        "connect_id" => "feishu-route-created",
        "provider" => "feishu",
        "group_id" => group_id,
        "app_id" => attrs["app_id"],
        "status" => "connected",
        "updated_at" => 1_700_000_000
      }

      connects =
        :bridge_for_teams_web
        |> Application.get_env(:feishu_route_selection_connects, %{})
        |> Map.put(group_id, [connect])

      Application.put_env(:bridge_for_teams_web, :feishu_route_selection_connects, connects)

      {:ok, connect}
    end

    def disable_im_connect(_tenant_id, group_id, connect_id) do
      case Application.get_env(:bridge_for_teams_web, :feishu_route_disable_error) do
        nil ->
          connects_by_group =
            Application.get_env(:bridge_for_teams_web, :feishu_route_selection_connects, %{})

          {connects, found?} =
            connects_by_group
            |> Map.get(group_id, [])
            |> Enum.map_reduce(false, fn connect, found? ->
              if connect["connect_id"] == connect_id do
                {Map.put(connect, "disabled_at", "2026-07-14T00:00:00Z"), true}
              else
                {connect, found?}
              end
            end)

          Application.put_env(
            :bridge_for_teams_web,
            :feishu_route_selection_connects,
            Map.put(connects_by_group, group_id, connects)
          )

          if found?, do: :ok, else: {:error, :not_found}

        reason ->
          {:error, reason}
      end
    end
  end

  defmodule FeishuRouteErrorClient do
    @moduledoc false

    def list_group_im_connects(_group_id, "feishu"), do: {:error, :unavailable}
  end

  # A Salix client without the optional Signal callbacks.
  defmodule NoSignalClient do
    @moduledoc false
  end

  defp setup_feishu_route_client do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    FeishuRouteSelectionClient.reset()
    Application.put_env(:bridge_for_teams_core, :salix_client, FeishuRouteSelectionClient)

    on_exit(fn ->
      Application.delete_env(:bridge_for_teams_web, :feishu_route_selection_connects)
      Application.delete_env(:bridge_for_teams_web, :feishu_route_disable_error)

      case previous_client do
        nil -> Application.delete_env(:bridge_for_teams_core, :salix_client)
        value -> Application.put_env(:bridge_for_teams_core, :salix_client, value)
      end
    end)
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, org: org, user: user}
  end

  test "renders the general tab with the settings tab bar", %{conn: conn, org: org} do
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings")

    assert html =~ "Settings"
    assert html =~ "Organization name"
    assert html =~ ~s(id="org-settings-icon-file")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/audit")
    # The tab bar links to the other settings sections.
    assert html =~ "Models"
    assert html =~ "Single sign-on"
    assert html =~ "OAuth apps"
    assert html =~ "BFT CLI access"
    assert html =~ "Install bft CLI"
    assert html =~ ~s(id="bft-cli-install-command")
    assert html =~ "/v1/cli/install.sh"
    refute html =~ "runner-onboarding"
    refute html =~ "create-mac-mini-runner-key"
  end

  test "renders the SSO tab", %{conn: conn, org: org} do
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/sso")

    assert html =~ "Single sign-on"
    assert html =~ "Generic OIDC"
    assert html =~ "Feishu"
    assert html =~ "Not configured"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/integrations?surface=sso")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks?surface=sso")
    refute html =~ "Runners"
    refute html =~ "OAuth provider apps"
  end

  test "shows device login command and revokes authorized BFT CLI sessions", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, %{token: cli_token, session: session}} =
      Auth.Sessions.create(user, device: "bft-cli", client_name: "agent laptop")

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings")

    assert html =~ "BFT CLI access"
    assert html =~ "API wrapper"
    assert html =~ ~s(id="bft-cli-device-login-command")
    assert html =~ "bft auth login --url &quot;http://localhost:4102&quot; --output text"
    assert html =~ "bft onboarding smoke --step cli-login"
    assert html =~ "Authorized CLI sessions"
    assert html =~ "agent laptop"
    assert html =~ session.id
    assert html =~ "Created "
    assert html =~ "Device bft-cli"
    refute html =~ "secret-cli-token"
    refute html =~ "--code"

    html =
      view
      |> element(~s(button[phx-click="revoke-cli-session"][phx-value-session-id="#{session.id}"]))
      |> render_click()

    assert html =~ "BFT CLI session revoked."
    refute html =~ session.id
    assert {:error, :invalid} = Auth.Sessions.fetch(cli_token)
  end

  test "approves and cancels CLI device login requests from the dashboard page", %{
    conn: conn,
    org: org
  } do
    {:ok, %{device_code: approve_device_code, authorization: approve_auth}} =
      Login.start_device_authorization(%{client_name: "agent laptop"})

    {:ok, view, html} = live(conn, ~p"/cli/device-login/#{approve_auth.user_code}")

    assert html =~ "BFT CLI login"
    assert html =~ approve_auth.user_code
    assert html =~ "agent laptop"
    assert html =~ "Created at"
    assert html =~ "Organization access"
    assert html =~ org.name

    html =
      view
      |> element(~s(input[phx-click="toggle_org"][value="#{org.id}"]))
      |> render_click()

    assert html =~ org.name

    html =
      view
      |> element(~s(button[phx-click="approve"]))
      |> render_click()

    assert html =~ "CLI login approved."
    assert html =~ "approved"

    assert {:ok, %{status: "approved", token: token, granted_orgs: [granted_org]}} =
             Login.poll_device_authorization(approve_device_code)

    assert granted_org.id == org.id

    assert {:ok, session} = Auth.Sessions.fetch(token)
    assert session.device == "bft-cli"

    {:ok, %{device_code: cancel_device_code, authorization: cancel_auth}} =
      Login.start_device_authorization(%{client_name: "agent laptop"})

    {:ok, view, _html} = live(conn, ~p"/cli/device-login/#{cancel_auth.user_code}")

    html =
      view
      |> element(~s(button[phx-click="cancel"]))
      |> render_click()

    assert html =~ "CLI login cancelled."
    assert html =~ "cancelled"

    assert {:ok, %{status: "cancelled"} = cancelled} =
             Login.poll_device_authorization(cancel_device_code)

    refute Map.has_key?(cancelled, :token)
  end

  test "device login generic page and direct code link render", %{conn: conn} do
    {:ok, %{authorization: authorization}} =
      Login.start_device_authorization(%{client_name: "agent laptop"})

    {:ok, _view, html} = live(conn, ~p"/cli/device-login")

    assert html =~ "BFT CLI login"
    assert html =~ "User code"
    refute html =~ "This CLI login request was not found."

    {:ok, _view, html} = live(conn, ~p"/cli/device-login/#{authorization.user_code}")
    assert html =~ authorization.user_code
    assert html =~ "agent laptop"
  end

  test "logged-out device login link redirects through login with return_to" do
    {:ok, %{authorization: authorization}} =
      Login.start_device_authorization(%{client_name: "agent laptop"})

    conn =
      build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> get(~p"/cli/device-login/#{authorization.user_code}")

    assert redirected_to(conn) =~ "/login?"

    expected_return_to = "/cli/device-login/#{authorization.user_code}"

    assert %{"return_to" => ^expected_return_to} =
             redirected_to(conn) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  test "ordinary org members cannot open CLI device login approval page", %{
    conn: conn,
    org: org
  } do
    member = user_fixture(email: "cli-device-live-member@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")

    {:ok, %{authorization: authorization}} =
      Login.start_device_authorization(%{client_name: "agent laptop"})

    assert {:error, {:redirect, %{to: "/orgs"}}} =
             conn
             |> log_in_user(member)
             |> live(~p"/cli/device-login/#{authorization.user_code}")
  end

  test "ordinary org members cannot open settings", %{conn: conn, org: org} do
    member = user_fixture(email: "settings-member@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    # Members stay inside the org and get the real reason (they already know
    # the org exists), unlike outsiders who get the vague not-found redirect.
    assert {:error, {:redirect, %{to: redirect_to, flash: flash}}} =
             conn
             |> log_in_user(member)
             |> live(~p"/orgs/#{org.slug}/settings")

    assert redirect_to == "/orgs/#{org.slug}"
    assert flash["error"] =~ "Only organization admins can manage settings"
  end

  test "ordinary org members do not see the Settings nav item", %{conn: conn, org: org} do
    member = user_fixture(email: "settings-nav-member@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    {:ok, _view, html} =
      conn
      |> log_in_user(member)
      |> live(~p"/orgs/#{org.slug}/projects")

    refute html =~ ~p"/orgs/#{org.slug}/settings"
  end

  test "outsiders cannot open settings by guessing an org slug", %{conn: conn, org: org} do
    outsider = user_fixture(email: "settings-outsider@example.com")

    assert {:error, {:redirect, %{to: "/orgs"}}} =
             conn
             |> log_in_user(outsider)
             |> live(~p"/orgs/#{org.slug}/settings")
  end

  test "allows org admins to open settings", %{conn: conn, org: org} do
    admin = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, admin.id, "admin")
    conn = log_in_user(conn, admin)

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings")

    assert html =~ "Settings"
    assert html =~ "Single sign-on"
  end

  @tag :private_template
  test "org model settings select its private template and exclude another tenant", %{
    conn: conn,
    org: org
  } do
    {:ok, private} =
      SalixAgent.Templates.create_private(
        %{
          "name" => "Org private model",
          "model" => "gpt-org-private",
          "provider_config" => %{"api_key" => "private-model-secret"}
        },
        org.salix_tenant_id
      )

    {:ok, foreign} =
      SalixAgent.Templates.create_private(
        %{
          "name" => "Foreign private model",
          "model" => "gpt-foreign"
        },
        SalixStore.Ids.new_tenant_id()
      )

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/models")
    assert html =~ private["model"]
    refute html =~ foreign["model"]
    refute html =~ "private-model-secret"

    view
    |> form("#models-form",
      models: %{allowed: [private["template_id"]], default_template_id: private["template_id"]}
    )
    |> render_submit()

    {:ok, updated} = Orgs.get_org(org.id)
    assert updated.allowed_template_ids == [private["template_id"]]
    assert updated.default_template_id == private["template_id"]
    assert {:ok, [available]} = BridgeForTeams.Models.list_for_org(updated)
    assert available["template_id"] == private["template_id"]
  end

  test "saves the model allowlist and default from the catalog", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, opus} =
      SalixAgent.Templates.create(%{"name" => "Opus", "model" => "claude-opus-4-8"})

    {:ok, _haiku} =
      SalixAgent.Templates.create(%{"name" => "Haiku", "model" => "claude-haiku-4-5"})

    {:ok, alternate} =
      SalixAgent.Templates.create(%{"name" => "EU endpoint", "model" => "claude-opus-4-8"})

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/models")
    assert html =~ "Allowed models"

    assert has_element?(
             view,
             "fieldset#models-allowed[aria-describedby='models-allowed-help'] > legend",
             "Allowed models"
           )

    assert has_element?(view, "#models-allowed input[type=checkbox][name='models[allowed][]']")

    assert has_element?(
             view,
             "#models-allowed-help",
             "Leave every box unchecked to allow every model in the catalog."
           )

    refute has_element?(view, "#models-allowed", "All models")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/integrations?surface=models")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks?surface=models")
    assert has_element?(view, "#models-allowed", "claude-opus-4-8 — Opus")
    assert has_element?(view, "#models-allowed", "claude-opus-4-8 — EU endpoint")

    assert has_element?(
             view,
             "#models-form select option[value='#{alternate["template_id"]}']",
             "claude-opus-4-8 — EU endpoint"
           )

    view
    |> form("#models-form",
      models: %{allowed: [opus["template_id"]], default_template_id: opus["template_id"]}
    )
    |> render_submit()

    {:ok, reloaded} = Orgs.get_org(org.id)
    assert reloaded.allowed_template_ids == [opus["template_id"]]
    assert reloaded.default_template_id == opus["template_id"]

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "org.model_settings.updated")

    assert audit.actor_user_id == user.id

    assert audit.redacted_diff["default_template_id"] == %{
             "from" => nil,
             "to" => opus["template_id"]
           }
  end

  test "rejects a default model that is not in the allowlist", %{conn: conn, org: org} do
    {:ok, opus} =
      SalixAgent.Templates.create(%{"name" => "Opus", "model" => "claude-opus-4-8"})

    {:ok, haiku} =
      SalixAgent.Templates.create(%{"name" => "Haiku", "model" => "claude-haiku-4-5"})

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/models")

    view
    |> form("#models-form",
      models: %{allowed: [opus["template_id"]], default_template_id: haiku["template_id"]}
    )
    |> render_submit()

    assert render(view) =~ "default model must be one of the allowed models"
    {:ok, reloaded} = Orgs.get_org(org.id)
    assert reloaded.default_template_id == nil

    assert [event] =
             Observability.list_events(org.id,
               domain: "integration",
               resource_type: "model_settings"
             )

    assert event.event_type == "model.validation.failed"
    assert event.status == "fail"
    assert event.reason_class == "default_template_not_allowed"
    assert event.evidence["settings_path"] == "settings/models"

    assert event.evidence["field_errors"]["default_template_id"] == [
             "must be one of the allowed models"
           ]
  end

  test "updates the org name", %{conn: conn, org: org, user: user} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings")

    view
    |> form("#org-form", organization: %{name: "Renamed Org"})
    |> render_submit()

    {:ok, reloaded} = Orgs.get_org(org.id)
    assert reloaded.name == "Renamed Org"

    assert [audit] = Observability.list_audit_logs(org.id, action: "org.settings.updated")
    assert audit.actor_user_id == user.id
    assert audit.redacted_diff["name"] == %{"from" => org.name, "to" => "Renamed Org"}
  end

  test "updates and renders the org icon", %{conn: conn, org: org} do
    {:ok, _updated} = Orgs.update_org(org, %{icon: @icon})

    {:ok, _show_view, show_html} = live(conn, ~p"/orgs/#{org.slug}")
    assert show_html =~ @icon
  end

  test "saves an SSO connection and stores the client secret", %{conn: conn, org: org, user: user} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/sso")

    html =
      view
      |> form("#sso-form",
        sso: %{
          issuer: "https://idp.example.com",
          client_id: "client-abc",
          client_secret: "s3cret",
          allowed_domains: "example.com, other.com",
          default_role: "admin"
        }
      )
      |> render_submit()

    assert html =~ "SSO connection saved"

    sso = Orgs.get_sso_connection(org.id)
    assert sso.issuer == "https://idp.example.com"
    assert sso.client_id == "client-abc"
    assert sso.allowed_domains == ["example.com", "other.com"]
    assert sso.default_role == "admin"
    # Secret is stored as-is (no encryption at rest) and never echoed to the form.
    assert sso.client_secret == "s3cret"
    refute html =~ "s3cret"

    assert [audit] = Observability.list_audit_logs(org.id, action: "sso_connection.created")
    assert audit.actor_user_id == user.id
    assert audit.metadata["credential_changed"] == "true"
    refute inspect(audit) =~ "s3cret"
  end

  test "Feishu SSO points to the Feishu apps tab when no app is enabled for SSO", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/sso")

    html =
      view
      |> form("#sso-form", sso: %{provider: "feishu"})
      |> render_change()

    assert html =~ "No Feishu app is enabled for sign-in yet"
    assert html =~ "Go to Feishu apps"
    # Credentials are no longer entered on the SSO card — they live in Feishu apps.
    refute html =~ "Feishu App ID"
    refute html =~ "Feishu App Secret"
  end

  test "Feishu SSO reuses the enabled binding without re-entering credentials", %{
    conn: conn,
    org: org
  } do
    {:ok, _} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_ref",
        "display_name" => "Acme Feishu",
        "sso_enabled" => true,
        "app_secret" => "s3cret"
      })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/sso")

    html =
      view
      |> form("#sso-form", sso: %{provider: "feishu"})
      |> render_change()

    assert html =~ "Acme Feishu"
    assert html =~ "cli_ref"
    assert html =~ "secret configured"
    assert html =~ "Feishu scopes"
    assert html =~ "First-login provisioning"
    assert html =~ "Redirect URI"
    refute html =~ "Feishu App Secret"
  end

  test "Feishu SSO prefers the latest active binding when legacy data has more than one", %{
    conn: conn,
    org: org
  } do
    {:ok, old_binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_old_sso_live",
        "display_name" => "Old Feishu",
        "sso_enabled" => true,
        "app_secret" => "old-secret"
      })

    {:ok, _new_binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_new_sso_live",
        "display_name" => "New Feishu",
        "sso_enabled" => true,
        "app_secret" => "new-secret"
      })

    # Simulate legacy dirty posture from earlier builds: more than one binding
    # marked SSO-active. The SSO form should prefer the most recently saved app.
    Repo.update_all(
      from(b in BridgeForTeams.Schema.FeishuAppBinding, where: b.id == ^old_binding.id),
      set: [sso_enabled: true, updated_at: ~U[2026-01-01 00:00:00Z]]
    )

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/sso")

    assert html =~ "New Feishu"
    assert html =~ "cli_new_sso_live"
    refute html =~ "Old Feishu"

    view
    |> form("#sso-form",
      sso: %{
        provider: "feishu",
        provider_config: %{"scope" => "contact:user.base:readonly"},
        default_role: "member"
      }
    )
    |> render_submit()

    assert Orgs.get_sso_connection(org.id).client_id == "cli_new_sso_live"
  end

  test "runs SSO checks and shows a real-shaped result panel for Feishu", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, _} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_checks",
        "sso_enabled" => true,
        "app_secret" => "s3cret"
      })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/sso")

    html =
      view
      |> element("button", "Run checks")
      |> render_click()

    assert html =~ "Redirect URI is generated"
    assert html =~ "Feishu credentials valid"
    # redirect URI gate is live-computed (OK); credential gate is honestly Skipped
    assert html =~ "OK"
    assert html =~ "Skipped"

    assert [check] = Observability.list_check_results(org.id, surface: "sso")
    assert check.ran_by_user_id == user.id
    assert check.status == "skipped"

    assert [event] = Observability.list_events(org.id, domain: "check")
    assert event.check_result_id == check.id
    assert event.summary =~ "Run checks completed for sso"

    assert [audit] = Observability.list_audit_logs(org.id, action: "run_checks.ran")
    assert audit.actor_user_id == user.id
    assert audit.resource_id == check.id
  end

  test "creates an org Feishu app binding from the Feishu apps tab", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/feishu")
    assert html =~ "Feishu apps"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/integrations?surface=bot")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks?surface=bot")
    assert html =~ "Add a Feishu app"
    assert html =~ "one org can have one bot-enabled Feishu app"
    assert html =~ "Feishu permission scopes"
    assert html =~ "Permissions &amp; Scopes → Batch import/export scopes → Import JSON"
    assert html =~ "SSO + group bot"
    assert html =~ "contact:user.base:readonly"
    assert html =~ "im:message:send_as_bot"
    assert html =~ "im:message.group_at_msg:readonly"
    assert html =~ "im:message.p2p_msg:readonly"
    assert html =~ "im:chat:read"
    assert html =~ "im:chat.members:read"
    assert html =~ "im:resource"
    assert html =~ "im:message.group_msg"
    assert html =~ "im:message:readonly"
    assert html =~ "im:message:update"
    assert html =~ "im:message:recall"
    assert html =~ "im:message.reactions:read"
    assert html =~ "im:message.reactions:write_only"
    assert html =~ "im:message.pins:read"
    assert html =~ "im:message.pins:write_only"
    assert html =~ "contact:contact.base:readonly"
    assert html =~ "contact:user.base:readonly"
    assert html =~ "contact:department.base:readonly"
    refute html =~ "docx:document"
    refute html =~ "contact:user.department:readonly"
    refute html =~ "im:message.group_msg:readonly"
    refute html =~ "im:chat.member:readonly"
    refute html =~ "im:resource:upload"
    refute html =~ "im:chat:readonly"
    assert has_element?(view, "#copy-feishu-scopes-sso")
    assert has_element?(view, "#copy-feishu-scopes-bot")
    assert has_element?(view, "#copy-feishu-scopes-combined")

    view
    |> form("#feishu-binding-form",
      feishu_binding: %{
        app_id: "cli_app",
        display_name: "Co Feishu",
        app_secret: "s3cret",
        sso_enabled: "false",
        bot_enabled: "true"
      }
    )
    |> render_submit()

    assert [binding] = BridgeForTeams.FeishuAppBindings.list_bindings(org.id)
    assert binding.app_id == "cli_app"
    assert binding.bot_enabled
    refute binding.sso_enabled
    assert binding.app_secret_configured
    assert render(view) =~ "Not connected to an Agent Swarm yet"
    assert render(view) =~ "Create an Agent Swarm first"
    assert render(view) =~ "Open Agent Swarms"

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "feishu_app_binding.created")

    assert audit.actor_user_id == user.id
    assert audit.resource_id == binding.id
    refute inspect(audit) =~ "s3cret"
  end

  test "Feishu apps tab connects and disables a bot-enabled Agent Swarm route", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

    {:ok, binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_app",
        "display_name" => "Co Feishu",
        "app_secret" => "s3cret",
        "bot_enabled" => true
      })

    setup_feishu_route_client()

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/feishu")

    assert html =~ "Not connected to an Agent Swarm yet"
    assert html =~ "Demo Swarm"

    html =
      view
      |> form("#feishu-route-form-#{binding.id}", feishu_route: %{"project_id" => project.id})
      |> render_submit()

    assert html =~ "Feishu bot connected to Demo Swarm"
    assert html =~ "connected"
    assert html =~ ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations"

    disable_button =
      ~s(button[phx-click="disable-feishu-route"][phx-value-connect-id="feishu-route-created"])

    assert has_element?(view, disable_button, "Disable")
    assert render(view) =~ ~s(phx-disable-with="Disabling…")

    html =
      view
      |> element(disable_button)
      |> render_click()

    assert html =~ "Connect disabled."
    assert html =~ "disabled"
    refute has_element?(view, disable_button)

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.feishu.created")

    assert audit.actor_user_id == user.id
    assert audit.result == "ok"
    assert audit.resource_type == "project_im_connect"
    assert audit.resource_id == "feishu-route-created"
    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["provider"] == "feishu"
    assert audit.metadata["connect_id"] == "feishu-route-created"
    assert audit.metadata["app_id_configured"] == "true"
    refute inspect(audit) =~ "s3cret"

    assert [disabled_audit] =
             Observability.list_audit_logs(org.id, action: "integration.feishu.disabled")

    assert disabled_audit.actor_user_id == user.id
    assert disabled_audit.result == "ok"
    assert disabled_audit.resource_type == "project_im_connect"
    assert disabled_audit.resource_id == "feishu-route-created"
    assert disabled_audit.metadata["project_id"] == project.id
    assert disabled_audit.metadata["provider"] == "feishu"
  end

  test "non-admin forged disable event cannot stop a Feishu route", %{
    conn: conn,
    org: org
  } do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

    {:ok, binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_app",
        "display_name" => "Co Feishu",
        "app_secret" => "s3cret",
        "bot_enabled" => true
      })

    member = user_fixture(email: "settings-feishu-member@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")
    setup_feishu_route_client()

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/feishu")

    view
    |> form("#feishu-route-form-#{binding.id}", feishu_route: %{"project_id" => project.id})
    |> render_submit()

    :sys.replace_state(view.pid, fn state ->
      socket =
        state.socket
        |> Phoenix.Component.assign(:current_user, member)
        |> Phoenix.Component.assign(:current_org_role, "member")

      %{state | socket: socket}
    end)

    html =
      render_click(view, "disable-feishu-route", %{
        "project-id" => project.id,
        "connect-id" => "feishu-route-created"
      })

    assert html =~ "Only organization admins can manage settings."

    assert [%{"connect_id" => "feishu-route-created"} = connect] =
             FeishuRouteSelectionClient.connects_for(project.salix_group_id)

    refute connect["disabled_at"]

    assert [] =
             Observability.list_audit_logs(org.id,
               action: "integration.feishu.disabled",
               result: "ok"
             )
  end

  test "Feishu route disable failure keeps the active state and records failed audit", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

    {:ok, binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_app",
        "display_name" => "Co Feishu",
        "app_secret" => "s3cret",
        "bot_enabled" => true
      })

    setup_feishu_route_client()
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/feishu")

    view
    |> form("#feishu-route-form-#{binding.id}", feishu_route: %{"project_id" => project.id})
    |> render_submit()

    disable_button =
      ~s(button[phx-click="disable-feishu-route"][phx-value-connect-id="feishu-route-created"])

    assert has_element?(view, disable_button, "Disable")
    FeishuRouteSelectionClient.fail_disable(:unavailable)

    html =
      view
      |> element(disable_button)
      |> render_click()

    assert html =~ "disable the Feishu bot route"
    assert html =~ "connected"
    refute html =~ "Connect disabled."
    assert has_element?(view, disable_button, "Disable")

    assert [%{"connect_id" => "feishu-route-created"} = connect] =
             FeishuRouteSelectionClient.connects_for(project.salix_group_id)

    refute connect["disabled_at"]

    assert [failed_audit] =
             Observability.list_audit_logs(org.id,
               action: "integration.feishu.disabled",
               result: "failed"
             )

    assert failed_audit.actor_user_id == user.id
    assert failed_audit.reason_class == "unavailable"
    assert failed_audit.resource_type == "project_im_connect"
    assert failed_audit.resource_id == "feishu-route-created"
    assert failed_audit.metadata["project_id"] == project.id
    assert failed_audit.metadata["provider"] == "feishu"
    assert failed_audit.metadata["connect_id"] == "feishu-route-created"

    assert [] =
             Observability.list_audit_logs(org.id,
               action: "integration.feishu.disabled",
               result: "ok"
             )
  end

  test "Feishu apps tab keeps route lookup errors distinct from empty routes", %{
    conn: conn,
    org: org
  } do
    {:ok, _project} = Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

    {:ok, binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_app",
        "display_name" => "Co Feishu",
        "app_secret" => "s3cret",
        "bot_enabled" => true
      })

    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, FeishuRouteErrorClient)

    on_exit(fn ->
      case previous_client do
        nil -> Application.delete_env(:bridge_for_teams_core, :salix_client)
        value -> Application.put_env(:bridge_for_teams_core, :salix_client, value)
      end
    end)

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/feishu")

    assert html =~ "Agent Swarm route state could not be verified"
    assert html =~ "an existing route may be hidden"
    refute html =~ "Not connected to an Agent Swarm yet"
    refute has_element?(view, "#feishu-route-form-#{binding.id}")
  end

  test "Feishu apps tab shows the Agent Swarm route for bot-enabled apps", %{
    conn: conn,
    org: org
  } do
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

    {:ok, _binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_app",
        "display_name" => "Co Feishu",
        "app_secret" => "s3cret",
        "bot_enabled" => true
      })

    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, FeishuRouteSummaryClient)

    on_exit(fn ->
      case previous_client do
        nil -> Application.delete_env(:bridge_for_teams_core, :salix_client)
        value -> Application.put_env(:bridge_for_teams_core, :salix_client, value)
      end
    end)

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/feishu")

    assert html =~ "Bot route"
    assert html =~ "Demo Swarm"
    assert html =~ project.salix_group_id
    assert html =~ ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations"
    assert html =~ "connected"
  end

  test "edits and deletes an org Feishu app binding from the Feishu apps tab", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, binding} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_manage",
        "display_name" => "Comma",
        "sso_enabled" => true,
        "bot_enabled" => true,
        "app_secret" => "shared-secret",
        "verification_token" => "vtok"
      })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/feishu")

    assert html =~ "cli_manage"
    assert html =~ "Edit"
    assert html =~ "Delete"

    html =
      view
      |> element(~s(button[phx-click="edit-feishu-binding"][phx-value-id="#{binding.id}"]))
      |> render_click()

    assert html =~ "Edit Feishu app"
    assert html =~ ~s(value="Comma")
    assert html =~ ~s(value="cli_manage")
    assert html =~ "App ID is fixed for an existing binding"

    html =
      view
      |> form("#feishu-binding-form",
        feishu_binding: %{
          id: binding.id,
          app_id: "cli_manage",
          display_name: "Comma renamed",
          sso_enabled: "false",
          bot_enabled: "false"
        }
      )
      |> render_submit()

    assert html =~ "Feishu app saved."
    assert html =~ "Comma renamed"

    {:ok, updated} = BridgeForTeams.FeishuAppBindings.get_binding(org.id, binding.id)
    assert updated.display_name == "Comma renamed"
    refute updated.sso_enabled
    refute updated.bot_enabled
    assert is_nil(Orgs.get_sso_connection(org.id))

    assert [update_audit] =
             Observability.list_audit_logs(org.id, action: "feishu_app_binding.updated")

    assert update_audit.actor_user_id == user.id
    assert update_audit.resource_id == binding.id

    html =
      view
      |> element(~s(button[phx-click="delete-feishu-binding"][phx-value-id="#{binding.id}"]))
      |> render_click()

    assert html =~ "Feishu app removed."
    refute BridgeForTeams.FeishuAppBindings.get_binding_for_app(org.id, "cli_manage")

    assert [delete_audit] =
             Observability.list_audit_logs(org.id, action: "feishu_app_binding.deleted")

    assert delete_audit.actor_user_id == user.id
    assert delete_audit.resource_id == binding.id
  end

  test "Feishu apps tab explains bot secret and one-active-bot failures", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/feishu")

    html =
      view
      |> form("#feishu-binding-form",
        feishu_binding: %{
          app_id: "cli_missing_bot_secret",
          bot_enabled: "true"
        }
      )
      |> render_submit()

    assert html =~ "Could not enable the Feishu bot"
    refute BridgeForTeams.FeishuAppBindings.get_binding_for_app(org.id, "cli_missing_bot_secret")

    view
    |> form("#feishu-binding-form",
      feishu_binding: %{
        app_id: "cli_one",
        app_secret: "secret-one",
        bot_enabled: "true"
      }
    )
    |> render_submit()

    html =
      view
      |> form("#feishu-binding-form",
        feishu_binding: %{
          app_id: "cli_two",
          app_secret: "secret-two",
          bot_enabled: "true"
        }
      )
      |> render_submit()

    assert html =~ "Only one Feishu app can be enabled for the group bot right now"
  end

  test "saving the Feishu SSO card refines the connection and reuses the binding app", %{
    conn: conn,
    org: org
  } do
    # The binding is the single place the App ID/secret are entered; enabling SSO
    # fans them out to the connection. The SSO card only refines scope/policy.
    {:ok, _} =
      BridgeForTeams.FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_app",
        "sso_enabled" => true,
        "app_secret" => "feishu-secret"
      })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/sso")

    html =
      view
      |> form("#sso-form",
        sso: %{
          provider: "feishu",
          provider_config: %{
            scope: "contact:user.base:readonly",
            provisioning_policy: "existing_identity"
          },
          default_role: "member"
        }
      )
      |> render_submit()

    assert html =~ "SSO connection saved"

    sso = Orgs.get_sso_connection(org.id)
    assert sso.provider == "feishu"
    assert sso.issuer == nil
    # App ID comes from the binding; the secret stays the one the binding fanned out.
    assert sso.client_id == "cli_app"
    assert sso.client_secret == "feishu-secret"

    assert sso.provider_config == %{
             "scope" => "contact:user.base:readonly",
             "provisioning_policy" => "existing_identity"
           }

    refute html =~ "feishu-secret"
  end

  test "blank client secret keeps the existing one", %{conn: conn, org: org} do
    {:ok, _} =
      Orgs.upsert_sso_connection(org.id, %{
        "issuer" => "https://idp.example.com",
        "client_id" => "client-abc",
        "client_secret" => "keep-me"
      })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/sso")

    view
    |> form("#sso-form",
      sso: %{
        issuer: "https://idp.example.com",
        client_id: "client-xyz",
        client_secret: "",
        default_role: "member"
      }
    )
    |> render_submit()

    sso = Orgs.get_sso_connection(org.id)
    assert sso.client_id == "client-xyz"
    assert sso.client_secret == "keep-me"
  end

  test "renders the OAuth provider apps section with supported providers", %{conn: conn, org: org} do
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/oauth")

    assert html =~ "OAuth provider apps"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/integrations?surface=oauth")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks?surface=oauth")
    assert html =~ "Notion"
    assert html =~ "Linear"
    assert html =~ ~s(id="oauth-form-notion")

    assert html =~ "Create app on GitHub"
    assert html =~ ~s(href="https://github.com/settings/apps/new?)
    assert html =~ ~s(href="https://console.cloud.google.com/apis/credentials")
    assert html =~ ~s(href="https://api.slack.com/apps?)
  end

  test "setup links pre-populate supported OAuth app creation fields", %{conn: conn, org: org} do
    previous_salix_public_base_url = Application.get_env(:salix_web, :public_base_url)

    Application.put_env(:salix_web, :public_base_url, "https://salix-staging.comma.surf/")

    on_exit(fn ->
      case previous_salix_public_base_url do
        nil -> Application.delete_env(:salix_web, :public_base_url)
        value -> Application.put_env(:salix_web, :public_base_url, value)
      end
    end)

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/oauth")

    linear_url = setup_url(html, "linear")
    linear_params = URI.decode_query(linear_url.query || "")

    assert linear_url.scheme == "https"
    assert linear_url.host == "linear.app"
    assert linear_url.path == "/settings/api/applications/new"
    assert linear_params["distribution"] == "private"
    assert linear_params["developer.name"] == "Comma"

    assert linear_params["display.description"] ==
             "Connect Linear to Comma Bridge for Teams agents."

    assert linear_params["oauth.client_name"] == "Comma Bridge for Teams"
    assert linear_params["oauth.client_uri"] == "http://localhost:4102"

    assert linear_params["oauth.redirect_uris"] ==
             "https://salix-staging.comma.surf/v1/oauth/linear/callback"

    assert linear_params["oauth.grant_types"] == "authorization_code"

    slack_url = setup_url(html, "slack")
    slack_params = URI.decode_query(slack_url.query || "")

    assert slack_url.scheme == "https"
    assert slack_url.host == "api.slack.com"
    assert slack_url.path == "/apps"
    assert slack_params["new_app"] == "1"
    assert {:ok, slack_manifest} = Jason.decode(slack_params["manifest_json"])
    assert get_in(slack_manifest, ["display_information", "name"]) == "Comma Bridge for Teams"

    assert get_in(slack_manifest, ["oauth_config", "redirect_urls"]) == [
             "https://salix-staging.comma.surf/v1/oauth/slack/callback"
           ]

    assert get_in(slack_manifest, ["oauth_config", "scopes", "user"]) == ["users:read"]
    assert get_in(slack_manifest, ["settings", "socket_mode_enabled"]) == false

    github_url = setup_url(html, "github")
    github_params = URI.decode_query(github_url.query || "")

    assert github_url.scheme == "https"
    assert github_url.host == "github.com"
    assert github_url.path == "/settings/apps/new"
    assert github_params["name"] == "Comma Bridge for Teams"
    assert github_params["url"] == "http://localhost:4102"

    assert github_params["callback_urls[]"] ==
             "https://salix-staging.comma.surf/v1/oauth/github/callback"

    assert github_params["request_oauth_on_install"] == "true"
    assert github_params["public"] == "false"
    assert github_params["webhook_active"] == "false"
  end

  test "saves an OAuth provider app and stores the secret in Salix", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/oauth")

    html =
      view
      |> form("#oauth-form-notion",
        oauth: %{provider: "notion", client_id: "notion-client", client_secret: "n0tion-secret"}
      )
      |> render_submit()

    assert html =~ "Notion OAuth app saved"
    # Secret is write-only and never echoed back into the form.
    refute html =~ "n0tion-secret"
    # Once configured, the badge stops linking to the provider console.
    refute html =~ "Create app on Notion"
    assert html =~ "Create app on GitHub"

    assert {:ok, apps} = OrgOAuthApps.list_org_oauth_apps(org.id)
    notion = Enum.find(apps, &(&1["provider"] == "notion"))
    assert notion["client_id"] == "notion-client"
    assert notion["client_secret_configured"] == true

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "oauth_provider_app.saved")

    assert audit.actor_user_id == user.id
    assert audit.resource_id == "notion"
    refute inspect(audit) =~ "n0tion-secret"
  end

  test "removes a configured OAuth provider app", %{conn: conn, org: org, user: user} do
    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "linear", %{
        "client_id" => "linear-id",
        "client_secret" => "linear-secret"
      })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/oauth")

    html =
      view
      |> element(~s(#oauth-app-linear button[phx-click="delete-oauth"]))
      |> render_click()

    assert html =~ "Linear OAuth app removed"

    assert {:ok, apps} = OrgOAuthApps.list_org_oauth_apps(org.id)
    linear = Enum.find(apps, &(&1["provider"] == "linear"))
    assert linear["client_secret_configured"] == false

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "oauth_provider_app.deleted")

    assert audit.actor_user_id == user.id
    assert audit.resource_id == "linear"
  end

  test "an unsupported provider surfaces the Salix error", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/oauth")

    # Drive the event directly: the rendered form only offers supported providers.
    html =
      render_hook(view, "save-oauth", %{
        "oauth" => %{"provider" => "telegram", "client_id" => "x"}
      })

    assert html =~ "unsupported oauth provider"
  end

  test "sets the organization's own Signal number and refuses an unregistered one", %{
    conn: conn,
    org: org,
    user: user
  } do
    n = :rand.uniform(9_999_999)
    number = "+1555" <> String.pad_leading(Integer.to_string(n), 7, "0")
    identity = SalixSignalProto.Keys.ec_keypair()

    {:ok, account_id} =
      SalixSignal.Accounts.create(%{
        aci: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0"),
        pni: nil,
        e164: number,
        device_id: 1,
        password: "device-password",
        identities: %{aci: identity, pni: nil},
        registration_ids: %{aci: 1, pni: 0},
        profile_key: :binary.copy(<<7>>, 32),
        pre_keys: %{},
        scope: {:organization, org.salix_tenant_id},
        environment: :staging
      })

    on_exit(fn ->
      SalixStore.Repo.query("DELETE FROM signal_accounts WHERE id = $1", [
        Ecto.UUID.dump!(account_id)
      ])
    end)

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/signal")
    assert html =~ ~s(id="signal-form")

    html =
      view
      |> form("#signal-form", signal: %{number: "+15559999999"})
      |> render_submit()

    assert html =~ "This number is not registered for Signal on this server."

    html = view |> form("#signal-form", signal: %{number: number}) |> render_submit()
    assert html =~ "Signal number saved."
    assert {:ok, %{"override" => %{"e164" => ^number}}} = OrgSignalNumber.get(org.id)
    assert [audit] = Observability.list_audit_logs(org.id, action: "signal_number.saved")
    assert audit.actor_user_id == user.id

    view |> form("#signal-form", signal: %{number: ""}) |> render_submit()
    assert {:ok, %{"override" => nil}} = OrgSignalNumber.get(org.id)
  end

  test "the Signal tab shows the runtime as unavailable when the Salix client lacks Signal", %{
    conn: conn,
    org: org
  } do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, NoSignalClient)

    on_exit(fn ->
      case previous_client do
        nil -> Application.delete_env(:bridge_for_teams_core, :salix_client)
        value -> Application.put_env(:bridge_for_teams_core, :salix_client, value)
      end
    end)

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/signal")

    assert html =~ "Runtime unavailable"
    refute html =~ ~s(id="signal-form")
  end

  test "renders the Composio tab unconfigured", %{conn: conn, org: org} do
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/settings/composio")

    assert html =~ "Composio"
    assert html =~ ~s(id="composio-form")
    assert html =~ "Not configured"
    assert html =~ "Write-only; never displayed back."
  end

  test "saves Composio settings write-only, keeps the key on blank update, and removes them", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/settings/composio")

    html =
      view
      |> form("#composio-form",
        composio: %{api_key: "ck_org_secret", base_url: "", enabled: "true"}
      )
      |> render_submit()

    assert html =~ "Composio settings saved"
    # The key is write-only and never echoed back into the form.
    refute html =~ "ck_org_secret"
    assert html =~ "Leave blank to keep the current key."

    assert {:ok, settings_view} = OrgComposioSettings.get_org_composio_settings(org.id)
    assert settings_view["enabled"] == true
    assert settings_view["api_key_configured"] == true

    assert [audit] = Observability.list_audit_logs(org.id, action: "composio_settings.saved")
    assert audit.actor_user_id == user.id

    # A blank key on a later save keeps the stored one.
    view
    |> form("#composio-form",
      composio: %{api_key: "", base_url: "https://eu.example", enabled: "true"}
    )
    |> render_submit()

    assert {:ok, settings_view} = OrgComposioSettings.get_org_composio_settings(org.id)
    assert settings_view["api_key_configured"] == true
    assert settings_view["base_url"] == "https://eu.example"

    html =
      view
      |> element(~s(button[phx-click="delete-composio"]))
      |> render_click()

    assert html =~ "Composio settings removed"

    assert {:ok, settings_view} = OrgComposioSettings.get_org_composio_settings(org.id)
    assert settings_view["api_key_configured"] == false

    assert [delete_audit] =
             Observability.list_audit_logs(org.id, action: "composio_settings.deleted")

    assert delete_audit.actor_user_id == user.id
  end

  defp setup_url(html, provider) do
    regex =
      Regex.compile!(
        ~s/id="oauth-app-#{provider}".*?<a href="([^"]+)".*?Create app on/,
        "s"
      )

    assert [_, href] = Regex.run(regex, html)

    href
    |> String.replace("&amp;", "&")
    |> URI.parse()
  end
end
