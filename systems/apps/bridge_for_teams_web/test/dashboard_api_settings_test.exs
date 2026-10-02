defmodule BridgeForTeamsWeb.DashboardAPISettingsTest do
  @moduledoc """
  The Settings API behind the React Settings pages (General, AI models,
  Single sign-on, Integrations): reads, every write and its audit, write-only
  secrets, the owner/admin rule with the denied-write audit, CSRF protection,
  and the fixed query counts of the CLI session list and the Integrations
  payload.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{
    Auth,
    FeishuAppBindings,
    Memberships,
    Observability,
    OrgComposioSettings,
    OrgOAuthApps,
    OrgSignalNumber,
    Orgs,
    Projects,
    Repo
  }

  @icon "data:image/png;base64,iVBORw0KGgo="

  # Salix client stand-ins. Calls the Settings payload makes but a test does
  # not care about go to the real client.
  defmodule FeishuRouteClient do
    @moduledoc false

    defdelegate list_oauth_provider_apps(tenant_id), to: BridgeForTeams.Salix.Erpc
    defdelegate get_composio_settings(tenant_id), to: BridgeForTeams.Salix.Erpc

    def reset do
      Application.put_env(:bridge_for_teams_web, :settings_feishu_connects, %{})
      Application.delete_env(:bridge_for_teams_web, :settings_feishu_disable_error)
      Application.delete_env(:bridge_for_teams_web, :settings_feishu_list_error)
      Application.delete_env(:bridge_for_teams_web, :settings_feishu_create_error)
    end

    def connects_for(group_id) do
      :bridge_for_teams_web
      |> Application.get_env(:settings_feishu_connects, %{})
      |> Map.get(group_id, [])
    end

    def put_connects(group_id, connects) do
      connects_by_group =
        Application.get_env(:bridge_for_teams_web, :settings_feishu_connects, %{})

      Application.put_env(
        :bridge_for_teams_web,
        :settings_feishu_connects,
        Map.put(connects_by_group, group_id, connects)
      )
    end

    def list_group_im_connects(group_id, provider) when provider in [nil, "feishu"] do
      send(self(), {:feishu_routes_listed, group_id})

      case Application.get_env(:bridge_for_teams_web, :settings_feishu_list_error) do
        nil -> {:ok, connects_for(group_id)}
        reason -> {:error, reason}
      end
    end

    def create_feishu_im_connect(tenant_id, group_id, attrs) do
      case Application.get_env(:bridge_for_teams_web, :settings_feishu_create_error) do
        nil -> create_connect(tenant_id, group_id, attrs)
        reason -> {:error, reason}
      end
    end

    defp create_connect(_tenant_id, group_id, attrs) do
      connect = %{
        "connect_id" => "feishu-route-created",
        "provider" => "feishu",
        "group_id" => group_id,
        "app_id" => attrs["app_id"],
        "status" => "connected",
        "updated_at" => 1_700_000_000
      }

      put_connects(group_id, [connect])
      {:ok, connect}
    end

    def disable_im_connect(_tenant_id, group_id, connect_id) do
      case Application.get_env(:bridge_for_teams_web, :settings_feishu_disable_error) do
        nil ->
          group_id
          |> connects_for()
          |> Enum.map(fn connect ->
            if connect["connect_id"] == connect_id,
              do: Map.put(connect, "disabled_at", "2026-07-14T00:00:00Z"),
              else: connect
          end)
          |> then(&put_connects(group_id, &1))

          :ok

        reason ->
          {:error, reason}
      end
    end
  end

  # A Salix client without the optional Signal callbacks.
  defmodule NoSignalClient do
    @moduledoc false

    defdelegate list_oauth_provider_apps(tenant_id), to: BridgeForTeams.Salix.Erpc
    defdelegate get_composio_settings(tenant_id), to: BridgeForTeams.Salix.Erpc
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    register_and_log_in_user(%{conn: conn})
  end

  describe "General" do
    test "shows the org profile and the CLI login commands", %{conn: conn, org: org} do
      {:ok, _org} = Orgs.update_org(org, %{icon: @icon, default_locale: "zh_Hans"})

      data = conn |> get(settings_path(org, "general")) |> json_response(200) |> data()

      assert data["organization"] == %{
               "name" => org.name,
               "slug" => org.slug,
               "icon" => @icon,
               "default_locale" => "zh_Hans"
             }

      assert %{"value" => "zh_Hans", "label" => "中文（简体）"} in data["locale_options"]

      assert data["cli"]["api_base_url"] == "http://localhost:4102"
      assert data["cli"]["config_path"] == "~/.bridge-for-teams/cli.json"

      assert data["cli"]["install_command"] ==
               ~s(curl -fsSL "http://localhost:4102/v1/cli/install.sh" | sh)

      assert data["cli"]["login_command"] ==
               ~s(bft auth login --url "http://localhost:4102" --output text\n) <>
                 "bft onboarding smoke --step cli-login"

      assert data["cli"]["sessions"] == []
      assert data["cli"]["sessions_truncated"] == false
    end

    test "lists and revokes the caller's BFT CLI sessions", %{conn: conn, org: org, user: user} do
      {:ok, %{token: cli_token, session: session}} =
        Auth.Sessions.create(user, device: "bft-cli", client_name: "agent laptop")

      body = conn |> get(settings_path(org, "general")) |> response(200)
      refute body =~ cli_token

      assert [
               %{
                 "id" => id,
                 "client_name" => "agent laptop",
                 "device" => "bft-cli",
                 "created_at" => created_at,
                 "expires_at" => expires_at
               }
             ] = body |> Jason.decode!() |> get_in(["data", "cli", "sessions"])

      assert id == session.id
      assert {:ok, _, _} = DateTime.from_iso8601(created_at)
      assert {:ok, _, _} = DateTime.from_iso8601(expires_at)

      cli =
        conn
        |> delete(~p"/dashboard/api/v1/orgs/#{org.slug}/settings/cli-sessions/#{session.id}")
        |> json_response(200)
        |> data()

      assert cli["sessions"] == []
      assert {:error, :invalid} = Auth.Sessions.fetch(cli_token)

      assert %{"error" => %{"code" => "cli_session_not_found"}} =
               conn
               |> delete(~p"/dashboard/api/v1/orgs/#{org.slug}/settings/cli-sessions/not-a-uuid")
               |> json_response(404)
    end

    test "lists at most 50 CLI sessions", %{conn: conn, org: org, user: user} do
      for _ <- 1..51, do: {:ok, _} = Auth.Sessions.create(user, device: "bft-cli")

      cli = conn |> get(settings_path(org, "general")) |> json_response(200) |> data()

      assert length(cli["cli"]["sessions"]) == 50
      assert cli["cli"]["sessions_truncated"] == true
    end

    test "reads the CLI session list in a fixed number of queries",
         %{conn: conn, org: org, user: user} do
      {:ok, _} = Auth.Sessions.create(user, device: "bft-cli")
      small = query_count(conn, settings_path(org, "general"))

      for _ <- 1..6, do: {:ok, _} = Auth.Sessions.create(user, device: "bft-cli")

      assert query_count(conn, settings_path(org, "general")) == small
    end

    test "updates the profile fields only and records the audit",
         %{conn: conn, org: org, user: user} do
      data =
        conn
        |> patch(settings_path(org, "general"), %{
          "name" => "Renamed Org",
          "icon" => @icon,
          "status" => "archived",
          "billing_account_id" => "forged",
          "allowed_template_ids" => ["forged"]
        })
        |> json_response(200)
        |> data()

      assert data["organization"]["name"] == "Renamed Org"
      assert data["organization"]["icon"] == @icon

      {:ok, reloaded} = Orgs.get_org(org.id)
      assert reloaded.name == "Renamed Org"
      assert reloaded.status == org.status
      assert reloaded.billing_account_id == org.billing_account_id
      assert reloaded.allowed_template_ids == org.allowed_template_ids

      assert [audit] = Observability.list_audit_logs(org.id, action: "org.settings.updated")
      assert audit.actor_user_id == user.id
      assert audit.redacted_diff["name"] == %{"from" => org.name, "to" => "Renamed Org"}
    end

    test "returns field errors for an invalid profile", %{conn: conn, org: org} do
      other = org_fixture()

      assert %{"error" => %{"code" => "invalid_organization", "details" => %{"fields" => fields}}} =
               conn
               |> patch(settings_path(org, "general"), %{"slug" => other.slug})
               |> json_response(422)

      assert fields["slug"]
      assert {:ok, %{slug: slug}} = Orgs.get_org(org.id)
      assert slug == org.slug
    end

    test "field errors fill in their counts, in the caller's language",
         %{conn: conn, org: org, user: user} do
      icon = "data:image/png;base64," <> String.duplicate("A", 512_000)

      assert %{"error" => %{"details" => %{"fields" => %{"icon" => [message]}}}} =
               conn
               |> patch(settings_path(org, "general"), %{"icon" => icon})
               |> json_response(422)

      assert message == "should be at most 512000 character(s)"

      {:ok, _} = BridgeForTeams.Accounts.update_user(user, %{"preferred_locale" => "zh_Hans"})

      assert %{"error" => %{"details" => %{"fields" => %{"icon" => ["最多应为 512000 个字符"]}}}} =
               conn
               |> patch(settings_path(org, "general"), %{"icon" => icon})
               |> json_response(422)
    end
  end

  describe "AI models" do
    test "saves the allowlist and defaults from the catalog", %{conn: conn, org: org, user: user} do
      {:ok, opus} = SalixAgent.Templates.create(%{"name" => "Opus", "model" => "claude-opus-4-8"})
      {:ok, _} = SalixAgent.Templates.create(%{"name" => "Haiku", "model" => "claude-haiku-4-5"})

      {:ok, alternate} =
        SalixAgent.Templates.create(%{"name" => "EU endpoint", "model" => "claude-opus-4-8"})

      data = conn |> get(settings_path(org, "models")) |> json_response(200) |> data()

      assert data["catalog_status"] == "ok"
      labels = Enum.map(data["catalog"], & &1["label"])
      assert "claude-opus-4-8 — Opus" in labels
      assert "claude-opus-4-8 — EU endpoint" in labels

      assert %{"value" => alternate["template_id"], "label" => "claude-opus-4-8 — EU endpoint"} in data[
               "default_options"
             ]["worker"]

      assert data["allowed_template_ids"] == []
      assert data["default_template_id"] == nil

      data =
        conn
        |> put(settings_path(org, "models"), %{
          "allowed_template_ids" => [opus["template_id"]],
          "default_template_id" => opus["template_id"]
        })
        |> json_response(200)
        |> data()

      assert data["allowed_template_ids"] == [opus["template_id"]]
      assert data["default_template_id"] == opus["template_id"]

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

    test "drops allowlist IDs that are no longer in the catalog", %{conn: conn, org: org} do
      {:ok, opus} = SalixAgent.Templates.create(%{"name" => "Opus", "model" => "claude-opus-4-8"})
      retired = "tpl-retired-#{System.unique_integer([:positive])}"

      assert %{"allowed_template_ids" => [opus_id]} =
               conn
               |> put(settings_path(org, "models"), %{
                 "allowed_template_ids" => [opus["template_id"], retired]
               })
               |> json_response(200)
               |> data()

      assert opus_id == opus["template_id"]

      # Only retired models left means the whole catalog.
      assert %{"allowed_template_ids" => []} =
               conn
               |> put(settings_path(org, "models"), %{"allowed_template_ids" => [retired]})
               |> json_response(200)
               |> data()

      {:ok, reloaded} = Orgs.get_org(org.id)
      assert reloaded.allowed_template_ids == []
    end

    test "rejects a default model that is not in the allowlist", %{conn: conn, org: org} do
      {:ok, opus} = SalixAgent.Templates.create(%{"name" => "Opus", "model" => "claude-opus-4-8"})

      {:ok, haiku} =
        SalixAgent.Templates.create(%{"name" => "Haiku", "model" => "claude-haiku-4-5"})

      assert %{
               "error" => %{
                 "code" => "default_model_not_allowed",
                 "message" => "The default model must be one of the allowed models.",
                 "details" => %{"fields" => ["default_template_id"]}
               }
             } =
               conn
               |> put(settings_path(org, "models"), %{
                 "allowed_template_ids" => [opus["template_id"]],
                 "default_template_id" => haiku["template_id"]
               })
               |> json_response(422)

      {:ok, reloaded} = Orgs.get_org(org.id)
      assert reloaded.default_template_id == nil

      assert [event] =
               Observability.list_events(org.id,
                 domain: "integration",
                 resource_type: "model_settings"
               )

      assert event.event_type == "model.validation.failed"
      assert event.reason_class == "default_template_not_allowed"
      assert event.evidence["settings_path"] == "settings/models"

      assert event.evidence["field_errors"]["default_template_id"] == [
               "must be one of the allowed models"
             ]
    end

    @tag :private_template
    test "offers the org's private template and not another tenant's", %{conn: conn, org: org} do
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
          %{"name" => "Foreign private model", "model" => "gpt-foreign"},
          SalixStore.Ids.new_tenant_id()
        )

      body = conn |> get(settings_path(org, "models")) |> response(200)
      assert body =~ private["model"]
      refute body =~ foreign["model"]
      refute body =~ "private-model-secret"

      assert %{"ok" => true} =
               conn
               |> put(settings_path(org, "models"), %{
                 "allowed_template_ids" => [private["template_id"]],
                 "default_template_id" => private["template_id"]
               })
               |> json_response(200)

      {:ok, updated} = Orgs.get_org(org.id)
      assert {:ok, [available]} = BridgeForTeams.Models.list_for_org(updated)
      assert available["template_id"] == private["template_id"]
    end
  end

  describe "Single sign-on" do
    test "saves a generic OIDC connection without returning the secret",
         %{conn: conn, org: org, user: user} do
      data = conn |> get(settings_path(org, "sso")) |> json_response(200) |> data()
      assert data["connection"] == nil
      assert data["feishu_app"] == nil
      assert data["providers"] == ["generic_oidc", "feishu"]
      assert data["redirect_uri"] == "http://localhost:4102/auth/callback"

      body =
        conn
        |> put(settings_path(org, "sso"), %{
          "provider" => "generic_oidc",
          "issuer" => "https://idp.example.com",
          "client_id" => "client-abc",
          "client_secret" => "s3cret",
          "allowed_domains" => "example.com, other.com",
          "default_role" => "admin"
        })
        |> response(200)

      refute body =~ "s3cret"

      assert %{
               "provider" => "generic_oidc",
               "issuer" => "https://idp.example.com",
               "client_id" => "client-abc",
               "client_secret_configured" => true,
               "allowed_domains" => ["example.com", "other.com"],
               "default_role" => "admin"
             } = body |> Jason.decode!() |> get_in(["data", "connection"])

      assert Orgs.get_sso_connection(org.id).client_secret == "s3cret"

      assert [audit] = Observability.list_audit_logs(org.id, action: "sso_connection.created")
      assert audit.actor_user_id == user.id
      assert audit.metadata["credential_changed"] == "true"
      refute inspect(audit) =~ "s3cret"
    end

    test "a blank client secret keeps the stored one", %{conn: conn, org: org} do
      {:ok, _} =
        Orgs.upsert_sso_connection(org.id, %{
          "issuer" => "https://idp.example.com",
          "client_id" => "client-abc",
          "client_secret" => "keep-me"
        })

      assert %{"ok" => true} =
               conn
               |> put(settings_path(org, "sso"), %{
                 "provider" => "generic_oidc",
                 "issuer" => "https://idp.example.com",
                 "client_id" => "client-xyz",
                 "client_secret" => "",
                 "default_role" => "member"
               })
               |> json_response(200)

      sso = Orgs.get_sso_connection(org.id)
      assert sso.client_id == "client-xyz"
      assert sso.client_secret == "keep-me"
    end

    test "returns field errors for an incomplete connection", %{conn: conn, org: org} do
      assert %{
               "error" => %{
                 "code" => "invalid_sso_connection",
                 "details" => %{"fields" => fields}
               }
             } =
               conn
               |> put(settings_path(org, "sso"), %{"provider" => "generic_oidc"})
               |> json_response(422)

      assert fields["issuer"]
      assert Orgs.get_sso_connection(org.id) == nil
    end

    test "Feishu SSO needs a Feishu app enabled for sign-in", %{conn: conn, org: org} do
      assert %{"error" => %{"code" => "feishu_app_required"}} =
               conn
               |> put(settings_path(org, "sso"), %{"provider" => "feishu"})
               |> json_response(422)

      assert Orgs.get_sso_connection(org.id) == nil
    end

    test "Feishu SSO reuses the app's ID and secret and refines scope and policy",
         %{conn: conn, org: org} do
      {:ok, _} =
        FeishuAppBindings.upsert_binding(org.id, %{
          "app_id" => "cli_app",
          "display_name" => "Acme Feishu",
          "sso_enabled" => true,
          "app_secret" => "feishu-secret"
        })

      data = conn |> get(settings_path(org, "sso")) |> json_response(200) |> data()

      assert %{
               "app_id" => "cli_app",
               "display_name" => "Acme Feishu",
               "app_secret_configured" => true
             } = data["feishu_app"]

      body =
        conn
        |> put(settings_path(org, "sso"), %{
          "provider" => "feishu",
          "client_id" => "forged",
          "provider_config" => %{
            "scope" => "contact:user.base:readonly",
            "provisioning_policy" => "existing_identity",
            "tenant_key" => "forged"
          },
          "default_role" => "member"
        })
        |> response(200)

      refute body =~ "feishu-secret"

      sso = Orgs.get_sso_connection(org.id)
      assert sso.provider == "feishu"
      assert sso.issuer == nil
      assert sso.client_id == "cli_app"
      assert sso.client_secret == "feishu-secret"

      assert sso.provider_config == %{
               "scope" => "contact:user.base:readonly",
               "provisioning_policy" => "existing_identity"
             }
    end

    test "Feishu SSO uses the latest app when legacy data enables more than one",
         %{conn: conn, org: org} do
      {:ok, old} =
        FeishuAppBindings.upsert_binding(org.id, %{
          "app_id" => "cli_old_sso",
          "display_name" => "Old Feishu",
          "sso_enabled" => true,
          "app_secret" => "old-secret"
        })

      {:ok, _new} =
        FeishuAppBindings.upsert_binding(org.id, %{
          "app_id" => "cli_new_sso",
          "display_name" => "New Feishu",
          "sso_enabled" => true,
          "app_secret" => "new-secret"
        })

      Repo.update_all(
        from(b in BridgeForTeams.Schema.FeishuAppBinding, where: b.id == ^old.id),
        set: [sso_enabled: true, updated_at: ~U[2026-01-01 00:00:00Z]]
      )

      assert %{"app_id" => "cli_new_sso"} =
               conn
               |> get(settings_path(org, "sso"))
               |> json_response(200)
               |> get_in(["data", "feishu_app"])

      assert %{"ok" => true} =
               conn
               |> put(settings_path(org, "sso"), %{
                 "provider" => "feishu",
                 "provider_config" => %{"scope" => "contact:user.base:readonly"},
                 "default_role" => "member"
               })
               |> json_response(200)

      assert Orgs.get_sso_connection(org.id).client_id == "cli_new_sso"
    end

    test "runs the SSO checks and records them in Operations", %{conn: conn, org: org, user: user} do
      {:ok, _} =
        FeishuAppBindings.upsert_binding(org.id, %{
          "app_id" => "cli_checks",
          "sso_enabled" => true,
          "app_secret" => "s3cret"
        })

      data =
        conn
        |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/settings/sso/checks")
        |> json_response(200)
        |> data()

      assert data["recorded"] == true
      assert data["warning"] == nil
      gates = Map.new(data["checks"]["gates"], &{&1["gate_id"], &1})

      assert %{"label" => "Redirect URI is generated", "status" => "ok"} =
               gates["sso.redirect_uri"]

      assert %{"label" => "Feishu credentials valid", "status" => "skipped"} =
               gates["sso.credentials"]

      refute inspect(data) =~ "s3cret"

      assert [check] = Observability.list_check_results(org.id, surface: "sso")
      assert check.ran_by_user_id == user.id
      assert [event] = Observability.list_events(org.id, domain: "check")
      assert event.check_result_id == check.id
      assert [audit] = Observability.list_audit_logs(org.id, action: "run_checks.ran")
      assert audit.actor_user_id == user.id
    end
  end

  describe "Integrations: OAuth apps" do
    test "lists the providers with setup links that carry this deployment's callbacks",
         %{conn: conn, org: org} do
      previous = Application.get_env(:salix_web, :public_base_url)
      Application.put_env(:salix_web, :public_base_url, "https://salix-staging.comma.surf/")
      on_exit(fn -> restore_env(:salix_web, :public_base_url, previous) end)

      oauth = conn |> get(settings_path(org, "integrations")) |> json_response(200) |> data()
      oauth = oauth["oauth"]

      assert oauth["status"] == "ok"
      apps = Map.new(oauth["apps"], &{&1["provider"], &1})
      assert %{"label" => "Notion", "configured" => false} = apps["notion"]
      assert apps["google"]["setup_href"] == "https://console.cloud.google.com/apis/credentials"

      linear = URI.parse(apps["linear"]["setup_href"])
      linear_params = URI.decode_query(linear.query)
      assert {linear.host, linear.path} == {"linear.app", "/settings/api/applications/new"}
      assert linear_params["distribution"] == "private"
      assert linear_params["oauth.client_name"] == "Comma Bridge for Teams"
      assert linear_params["oauth.client_uri"] == "http://localhost:4102"

      assert linear_params["oauth.redirect_uris"] ==
               "https://salix-staging.comma.surf/v1/oauth/linear/callback"

      slack = URI.parse(apps["slack"]["setup_href"])
      slack_params = URI.decode_query(slack.query)
      assert {slack.host, slack.path} == {"api.slack.com", "/apps"}
      assert slack_params["new_app"] == "1"
      manifest = Jason.decode!(slack_params["manifest_json"])

      assert manifest["oauth_config"]["redirect_urls"] == [
               "https://salix-staging.comma.surf/v1/oauth/slack/callback"
             ]

      assert manifest["oauth_config"]["scopes"]["user"] == ["users:read"]

      github = URI.parse(apps["github"]["setup_href"])
      github_params = URI.decode_query(github.query)
      assert {github.host, github.path} == {"github.com", "/settings/apps/new"}
      assert github_params["url"] == "http://localhost:4102"

      assert github_params["callback_urls[]"] ==
               "https://salix-staging.comma.surf/v1/oauth/github/callback"

      assert github_params["webhook_active"] == "false"
    end

    test "saves an OAuth app write-only and removes it", %{conn: conn, org: org, user: user} do
      body =
        conn
        |> put(oauth_path(org, "notion"), %{
          "client_id" => "notion-client",
          "client_secret" => "n0tion-secret"
        })
        |> response(200)

      refute body =~ "n0tion-secret"
      apps = body |> Jason.decode!() |> get_in(["data", "apps"]) |> Map.new(&{&1["provider"], &1})

      assert %{
               "client_id" => "notion-client",
               "client_secret_configured" => true,
               "configured" => true
             } = apps["notion"]

      assert {:ok, stored} = OrgOAuthApps.list_org_oauth_apps(org.id)
      assert Enum.find(stored, &(&1["provider"] == "notion"))["client_secret_configured"]

      assert [saved] = Observability.list_audit_logs(org.id, action: "oauth_provider_app.saved")
      assert saved.actor_user_id == user.id
      assert saved.resource_id == "notion"
      refute inspect(saved) =~ "n0tion-secret"

      apps =
        conn
        |> delete(oauth_path(org, "notion"))
        |> json_response(200)
        |> get_in(["data", "apps"])
        |> Map.new(&{&1["provider"], &1})

      assert apps["notion"]["client_secret_configured"] == false

      assert [deleted] =
               Observability.list_audit_logs(org.id, action: "oauth_provider_app.deleted")

      assert deleted.resource_id == "notion"
    end

    test "an unsupported provider returns the Salix error", %{conn: conn, org: org} do
      assert %{"error" => %{"code" => "invalid_oauth_app", "message" => message}} =
               conn
               |> put(oauth_path(org, "telegram"), %{"client_id" => "x"})
               |> json_response(422)

      assert message =~ "unsupported oauth provider"
    end
  end

  describe "Integrations: Composio and Signal" do
    test "saves Composio write-only, keeps the key on a blank save, and removes it",
         %{conn: conn, org: org, user: user} do
      composio = conn |> get(settings_path(org, "integrations")) |> json_response(200) |> data()

      assert %{"status" => "ok", "api_key_configured" => false, "enabled" => false} =
               composio["composio"]

      body =
        conn
        |> put(composio_path(org), %{"api_key" => "ck_org_secret", "enabled" => true})
        |> response(200)

      refute body =~ "ck_org_secret"

      assert %{"api_key_configured" => true, "enabled" => true} =
               body |> Jason.decode!() |> data()

      assert [_] = Observability.list_audit_logs(org.id, action: "composio_settings.saved")

      assert %{"api_key_configured" => true, "base_url" => "https://eu.example"} =
               conn
               |> put(composio_path(org), %{
                 "api_key" => "",
                 "base_url" => "https://eu.example",
                 "enabled" => true
               })
               |> json_response(200)
               |> data()

      assert %{"api_key_configured" => false} =
               conn |> delete(composio_path(org)) |> json_response(200) |> data()

      assert {:ok, %{"api_key_configured" => false}} =
               OrgComposioSettings.get_org_composio_settings(org.id)

      assert [deleted] =
               Observability.list_audit_logs(org.id, action: "composio_settings.deleted")

      assert deleted.actor_user_id == user.id
    end

    test "sets the org's Signal number and refuses an unregistered one",
         %{conn: conn, org: org, user: user} do
      number = register_signal_account(org)

      assert %{"error" => %{"code" => "signal_account_not_found"}} =
               conn |> put(signal_path(org), %{"number" => "+15559999999"}) |> json_response(422)

      assert %{"status" => "ok", "override_e164" => ^number, "effective_e164" => ^number} =
               conn
               |> put(signal_path(org), %{"number" => number})
               |> json_response(200)
               |> data()

      assert {:ok, %{"override" => %{"e164" => ^number}}} = OrgSignalNumber.get(org.id)
      assert [audit] = Observability.list_audit_logs(org.id, action: "signal_number.saved")
      assert audit.actor_user_id == user.id

      assert %{"override_e164" => nil} =
               conn |> put(signal_path(org), %{"number" => ""}) |> json_response(200) |> data()
    end

    test "a runtime without Signal marks only that section unavailable", %{conn: conn, org: org} do
      use_salix_client(NoSignalClient)

      data = conn |> get(settings_path(org, "integrations")) |> json_response(200) |> data()

      assert data["signal"]["status"] == "unavailable"
      assert data["oauth"]["status"] == "ok"
      assert data["composio"]["status"] == "ok"
    end
  end

  describe "Integrations: Feishu" do
    test "creates a Feishu app write-only and lists the scope import JSON",
         %{conn: conn, org: org, user: user} do
      body =
        conn
        |> post(feishu_apps_path(org), %{
          "app_id" => "cli_app",
          "display_name" => "Co Feishu",
          "app_secret" => "s3cret",
          "verification_token" => "vtok-secret",
          "sso_enabled" => false,
          "bot_enabled" => true
        })
        |> response(200)

      refute body =~ "s3cret"
      refute body =~ "vtok-secret"
      feishu = body |> Jason.decode!() |> data()

      assert [
               %{
                 "id" => id,
                 "app_id" => "cli_app",
                 "bot_enabled" => true,
                 "sso_enabled" => false,
                 "app_secret_configured" => true,
                 "verification_token_configured" => true,
                 "routes" => []
               }
             ] = feishu["apps"]

      # Bot-enabled and no Agent Swarm yet: the client offers "create one".
      assert feishu["routes_status"] == "ok"
      assert feishu["projects"] == []
      assert feishu["redirect_uri"] == "http://localhost:4102/auth/callback"

      cards = Map.new(feishu["scope_cards"], &{&1["id"], &1})
      assert Map.keys(cards) |> Enum.sort() == ["bot", "combined", "sso"]
      assert cards["combined"]["title"] == "SSO + group bot"

      for scope <- ~w(im:message:send_as_bot im:message.group_msg im:chat.members:read
                      contact:user.base:readonly contact:department.base:readonly) do
        assert scope in cards["combined"]["required_scopes"]
      end

      refute "im:chat.member:readonly" in cards["combined"]["required_scopes"]

      assert [%{"scope" => "im:message.group_at_msg.include_bot:readonly"}] =
               feishu["optional_scopes"]

      assert [audit] = Observability.list_audit_logs(org.id, action: "feishu_app_binding.created")
      assert audit.actor_user_id == user.id
      assert audit.resource_id == id
      refute inspect(audit) =~ "s3cret"
    end

    test "edits and deletes a Feishu app", %{conn: conn, org: org, user: user} do
      {:ok, binding} =
        FeishuAppBindings.upsert_binding(org.id, %{
          "app_id" => "cli_manage",
          "display_name" => "Comma",
          "sso_enabled" => true,
          "bot_enabled" => true,
          "app_secret" => "shared-secret",
          "verification_token" => "vtok"
        })

      assert %{"error" => %{"code" => "feishu_app_id_immutable"}} =
               conn
               |> put(feishu_app_path(org, binding.id), %{"app_id" => "cli_other"})
               |> json_response(422)

      assert [
               %{
                 "display_name" => "Comma renamed",
                 "sso_enabled" => false,
                 "bot_enabled" => false
               }
             ] =
               conn
               |> put(feishu_app_path(org, binding.id), %{
                 "display_name" => "Comma renamed",
                 "sso_enabled" => false,
                 "bot_enabled" => false
               })
               |> json_response(200)
               |> get_in(["data", "apps"])

      assert Orgs.get_sso_connection(org.id) == nil

      assert [updated] =
               Observability.list_audit_logs(org.id,
                 action: "feishu_app_binding.updated",
                 result: "ok"
               )

      assert updated.actor_user_id == user.id

      assert %{"apps" => []} =
               conn |> delete(feishu_app_path(org, binding.id)) |> json_response(200) |> data()

      refute FeishuAppBindings.get_binding_for_app(org.id, "cli_manage")

      assert [deleted] =
               Observability.list_audit_logs(org.id, action: "feishu_app_binding.deleted")

      assert deleted.resource_id == binding.id

      assert %{"error" => %{"code" => "feishu_app_not_found"}} =
               conn |> delete(feishu_app_path(org, binding.id)) |> json_response(404)

      assert %{"error" => %{"code" => "feishu_app_not_found"}} =
               conn |> put(feishu_app_path(org, "not-a-uuid"), %{}) |> json_response(404)
    end

    test "explains the bot secret and one-bot-app failures", %{conn: conn, org: org} do
      assert %{"error" => %{"code" => "feishu_bot_secret_required", "message" => message}} =
               conn
               |> post(feishu_apps_path(org), %{
                 "app_id" => "cli_no_secret",
                 "bot_enabled" => true
               })
               |> json_response(422)

      assert message =~ "Could not enable the Feishu bot"
      refute FeishuAppBindings.get_binding_for_app(org.id, "cli_no_secret")

      assert %{"ok" => true} =
               conn
               |> post(feishu_apps_path(org), %{
                 "app_id" => "cli_one",
                 "app_secret" => "secret-one",
                 "bot_enabled" => true
               })
               |> json_response(200)

      assert %{"error" => %{"code" => "feishu_bot_app_already_enabled"}} =
               conn
               |> post(feishu_apps_path(org), %{
                 "app_id" => "cli_two",
                 "app_secret" => "secret-two",
                 "bot_enabled" => true
               })
               |> json_response(409)
    end

    test "connects and disables a bot route to an Agent Swarm", %{
      conn: conn,
      org: org,
      user: user
    } do
      {:ok, project} =
        Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

      bot_binding(org)
      use_salix_client(FeishuRouteClient)

      feishu = conn |> get(settings_path(org, "integrations")) |> json_response(200) |> data()
      feishu = feishu["feishu"]
      assert feishu["routes_status"] == "ok"
      assert [%{"routes" => []}] = feishu["apps"]
      assert %{"id" => project.id, "name" => "Demo Swarm"} in feishu["projects"]

      assert %{"error" => %{"code" => "feishu_bot_app_required"}} =
               conn
               |> post(routes_path(org), %{"app_id" => "cli_unknown", "project_id" => project.id})
               |> json_response(422)

      assert %{"error" => %{"code" => "project_required"}} =
               conn
               |> post(routes_path(org), %{
                 "app_id" => "cli_app",
                 "project_id" => Ecto.UUID.generate()
               })
               |> json_response(422)

      feishu =
        conn
        |> post(routes_path(org), %{"app_id" => "cli_app", "project_id" => project.id})
        |> json_response(200)
        |> data()

      assert [%{"routes" => [route]}] = feishu["apps"]

      assert route == %{
               "project_id" => project.id,
               "project_name" => "Demo Swarm",
               "salix_group_id" => project.salix_group_id,
               "connect_id" => "feishu-route-created",
               "disabled" => false,
               "href" => "/orgs/#{org.slug}/projects/#{project.id}/integrations"
             }

      assert [created] =
               Observability.list_audit_logs(org.id, action: "integration.feishu.created")

      assert created.actor_user_id == user.id
      assert created.resource_id == "feishu-route-created"
      assert created.metadata["project_id"] == project.id
      assert created.metadata["app_id_configured"] == "true"

      assert [%{"routes" => [%{"disabled" => true}]}] =
               conn
               |> post(disable_path(org, project, "feishu-route-created"))
               |> json_response(200)
               |> get_in(["data", "apps"])

      assert [disabled] =
               Observability.list_audit_logs(org.id, action: "integration.feishu.disabled")

      assert disabled.result == "ok"
      assert disabled.resource_id == "feishu-route-created"

      assert %{"error" => %{"code" => "feishu_route_not_found"}} =
               conn
               |> post(disable_path(org, project, "feishu-route-created"))
               |> json_response(404)
    end

    test "a failed disable keeps the route active and records a failed audit",
         %{conn: conn, org: org, user: user} do
      {:ok, project} =
        Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

      bot_binding(org)
      use_salix_client(FeishuRouteClient)
      connect_route(project)
      Application.put_env(:bridge_for_teams_web, :settings_feishu_disable_error, :unavailable)

      assert %{"error" => %{"code" => "runtime_unavailable", "message" => message}} =
               conn
               |> post(disable_path(org, project, "feishu-route-created"))
               |> json_response(503)

      assert message =~ "disable the Feishu bot route"

      assert [%{"connect_id" => "feishu-route-created"} = connect] =
               FeishuRouteClient.connects_for(project.salix_group_id)

      refute connect["disabled_at"]

      assert [failed] =
               Observability.list_audit_logs(org.id,
                 action: "integration.feishu.disabled",
                 result: "failed"
               )

      assert failed.actor_user_id == user.id
      assert failed.reason_class == "unavailable"
      assert failed.metadata["connect_id"] == "feishu-route-created"

      assert [] =
               Observability.list_audit_logs(org.id,
                 action: "integration.feishu.disabled",
                 result: "ok"
               )
    end

    test "explains a connect Salix refuses because the app serves another Agent Swarm",
         %{conn: conn, org: org, user: user} do
      {:ok, project} =
        Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

      bot_binding(org)
      use_salix_client(FeishuRouteClient)

      Application.put_env(
        :bridge_for_teams_web,
        :settings_feishu_create_error,
        {:bad_request, "feishu app_id is already used by another connect"}
      )

      connect = fn ->
        conn
        |> post(routes_path(org), %{"app_id" => "cli_app", "project_id" => project.id})
        |> json_response(409)
      end

      assert %{"error" => %{"code" => "feishu_app_in_use", "message" => message}} = connect.()

      assert message ==
               "This Feishu app is already connected to another Agent Swarm. Current limitation: one Feishu app can serve one Agent Swarm; delete the existing connect or use a different app."

      {:ok, _} = BridgeForTeams.Accounts.update_user(user, %{"preferred_locale" => "zh_Hans"})

      assert %{"error" => %{"message" => "这个飞书应用已连接到另一个 Agent Swarm。" <> _}} =
               connect.()
    end

    test "the route lookup stops at the first Salix timeout", %{conn: conn, org: org} do
      bot_binding(org)
      use_salix_client(FeishuRouteClient)
      for n <- 1..3, do: bare_project_fixture(org, %{name: "Swarm #{n}"})
      Application.put_env(:bridge_for_teams_web, :settings_feishu_list_error, :timeout)

      feishu = conn |> get(settings_path(org, "integrations")) |> json_response(200) |> data()

      assert feishu["feishu"]["routes_status"] == "unavailable"
      assert_received {:feishu_routes_listed, _group_id}
      refute_received {:feishu_routes_listed, _group_id}
    end

    test "keeps a route lookup failure distinct from no routes", %{conn: conn, org: org} do
      {:ok, _project} =
        Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

      bot_binding(org)
      use_salix_client(FeishuRouteClient)
      Application.put_env(:bridge_for_teams_web, :settings_feishu_list_error, :unavailable)

      feishu = conn |> get(settings_path(org, "integrations")) |> json_response(200) |> data()

      assert feishu["feishu"]["routes_status"] == "unavailable"
      assert [%{"routes" => []}] = feishu["feishu"]["apps"]
    end

    test "skips the route lookup when no app has the bot enabled", %{conn: conn, org: org} do
      {:ok, _} =
        FeishuAppBindings.upsert_binding(org.id, %{
          "app_id" => "cli_sso_only",
          "sso_enabled" => true,
          "app_secret" => "s3cret"
        })

      _project = bare_project_fixture(org)
      use_salix_client(FeishuRouteClient)
      Application.put_env(:bridge_for_teams_web, :settings_feishu_list_error, :unavailable)

      feishu = conn |> get(settings_path(org, "integrations")) |> json_response(200) |> data()
      assert feishu["feishu"]["routes_status"] == "skipped"
    end

    test "reads the payload in a fixed number of queries and bounds the Agent Swarms",
         %{conn: conn, org: org} do
      bot_binding(org)
      use_salix_client(FeishuRouteClient)
      project = bare_project_fixture(org, %{name: "Swarm 000"})
      connect_route(project)
      add_waiting_member(org)

      path = settings_path(org, "integrations")
      _warm = query_count(conn, path)
      small = query_count(conn, path)

      for n <- 1..50 do
        project =
          bare_project_fixture(org, %{name: "Swarm #{String.pad_leading("#{n}", 3, "0")}"})

        connect_route(project, "route-#{n}")
      end

      for n <- 1..3 do
        {:ok, _} = FeishuAppBindings.upsert_binding(org.id, %{"app_id" => "cli_extra_#{n}"})
        add_waiting_member(org)
      end

      assert query_count(conn, path) == small

      feishu = conn |> get(path) |> json_response(200) |> get_in(["data", "feishu"])
      assert length(feishu["projects"]) == 50
      assert feishu["projects_truncated"] == true
      assert [%{"routes" => routes} | _] = feishu["apps"]
      assert length(routes) == 50
    end
  end

  describe "authorization" do
    test "an admin may manage settings", %{org: org} do
      admin_conn = org |> add_member("admin") |> then(&log_in_user(build_conn(), &1))

      for page <- ~w(general models sso integrations) do
        assert %{"ok" => true} = admin_conn |> get(settings_path(org, page)) |> json_response(200)
      end

      assert %{"ok" => true} =
               admin_conn
               |> patch(settings_path(org, "general"), %{"name" => "Admin Renamed"})
               |> json_response(200)
    end

    test "a member gets 403 and outsiders 404", %{org: org} do
      member_conn = org |> add_member("member") |> then(&log_in_user(build_conn(), &1))
      outsider_conn = log_in_user(build_conn(), user_fixture())

      for page <- ~w(general models sso integrations) do
        assert %{"error" => %{"code" => "forbidden", "message" => message}} =
                 member_conn |> get(settings_path(org, page)) |> json_response(403)

        assert message == "Only organization admins can manage settings."

        assert %{"error" => %{"code" => "org_not_found"}} =
                 outsider_conn |> get(settings_path(org, page)) |> json_response(404)
      end
    end

    test "a member's writes are refused and audited as denied", %{org: org} do
      {:ok, project} =
        Projects.create_project(org.id, %{"name" => "Demo Swarm", "slug" => "demo"})

      bot_binding(org)
      use_salix_client(FeishuRouteClient)
      connect_route(project)

      member = add_member(org, "member")
      member_conn = log_in_user(build_conn(), member)

      writes = [
        {"org.settings.updated",
         &patch(&1, settings_path(org, "general"), %{"name" => "Forged"})},
        {"org.model_settings.updated", &put(&1, settings_path(org, "models"), %{})},
        {"sso_connection.updated",
         &put(&1, settings_path(org, "sso"), %{"provider" => "feishu"})},
        {"run_checks.ran", &post(&1, ~p"/dashboard/api/v1/orgs/#{org.slug}/settings/sso/checks")},
        {"oauth_provider_app.saved", &put(&1, oauth_path(org, "notion"), %{"client_id" => "x"})},
        {"composio_settings.deleted", &delete(&1, composio_path(org))},
        {"signal_number.saved", &put(&1, signal_path(org), %{"number" => ""})},
        {"feishu_app_binding.created", &post(&1, feishu_apps_path(org), %{"app_id" => "cli_x"})},
        {"integration.feishu.disabled",
         &post(&1, disable_path(org, project, "feishu-route-created"))}
      ]

      for {action, write} <- writes do
        assert %{"error" => %{"code" => "forbidden"}} =
                 member_conn |> write.() |> json_response(403)

        assert [audit] = Observability.list_audit_logs(org.id, action: action, result: "denied")
        assert audit.actor_user_id == member.id
        assert audit.reason_class == "forbidden"
        assert audit.metadata["surface"] == "settings"
      end

      {:ok, reloaded} = Orgs.get_org(org.id)
      assert reloaded.name == org.name
      refute FeishuAppBindings.get_binding_for_app(org.id, "cli_x")

      assert [%{"connect_id" => "feishu-route-created"} = connect] =
               FeishuRouteClient.connects_for(project.salix_group_id)

      refute connect["disabled_at"]
    end
  end

  describe "CSRF" do
    test "writes need the page's CSRF token in the x-csrf-token header", %{conn: conn, org: org} do
      {conn, token} = csrf_session(conn, org)

      assert_error_sent(403, fn ->
        conn |> enforce_csrf() |> patch(settings_path(org, "general"), %{"name" => "No token"})
      end)

      assert_error_sent(403, fn ->
        conn
        |> enforce_csrf()
        |> put_req_header("x-csrf-token", "forged")
        |> put(composio_path(org), %{"api_key" => "ck_forged"})
      end)

      assert {:ok, %{name: name}} = Orgs.get_org(org.id)
      assert name == org.name

      assert %{"ok" => true} =
               conn
               |> enforce_csrf()
               |> put_req_header("x-csrf-token", token)
               |> patch(settings_path(org, "general"), %{"name" => "With token"})
               |> json_response(200)
    end
  end

  defp data(%{"data" => data}), do: data

  defp settings_path(org, page), do: "/dashboard/api/v1/orgs/#{org.slug}/settings/#{page}"
  defp oauth_path(org, provider), do: settings_path(org, "integrations/oauth/#{provider}")
  defp composio_path(org), do: settings_path(org, "integrations/composio")
  defp signal_path(org), do: settings_path(org, "integrations/signal")
  defp feishu_apps_path(org), do: settings_path(org, "integrations/feishu/apps")
  defp feishu_app_path(org, id), do: settings_path(org, "integrations/feishu/apps/#{id}")
  defp routes_path(org), do: settings_path(org, "integrations/feishu/routes")

  defp disable_path(org, project, connect_id),
    do:
      settings_path(
        org,
        "integrations/feishu/projects/#{project.id}/routes/#{connect_id}/disable"
      )

  defp add_member(org, role) do
    user = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, user.id, role)
    user
  end

  defp add_waiting_member(org) do
    member = add_member(org, "member")
    {:ok, _} = BridgeForTeams.Onboarding.remind_admins(org.id, member.id)
  end

  # Create the bot-enabled app before swapping the Salix client: saving it fans
  # the secret out to the real Salix tenant store.
  defp bot_binding(org) do
    {:ok, binding} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_app",
        "display_name" => "Co Feishu",
        "app_secret" => "s3cret",
        "bot_enabled" => true
      })

    binding
  end

  defp connect_route(project, connect_id \\ "feishu-route-created") do
    FeishuRouteClient.put_connects(project.salix_group_id, [
      %{"connect_id" => connect_id, "provider" => "feishu", "app_id" => "cli_app"}
    ])
  end

  defp use_salix_client(client) do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    FeishuRouteClient.reset()
    Application.put_env(:bridge_for_teams_core, :salix_client, client)

    on_exit(fn ->
      FeishuRouteClient.reset()
      restore_env(:bridge_for_teams_core, :salix_client, previous)
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp register_signal_account(org) do
    n = :rand.uniform(9_999_999)
    number = "+1555" <> String.pad_leading(Integer.to_string(n), 7, "0")

    {:ok, account_id} =
      SalixSignal.Accounts.create(%{
        aci: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0"),
        pni: nil,
        e164: number,
        device_id: 1,
        password: "device-password",
        identities: %{aci: SalixSignalProto.Keys.ec_keypair(), pni: nil},
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

    number
  end

  defp query_count(conn, path) do
    test_pid = self()
    handler = "settings-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end

  # Load the SPA page the way a browser does: it stores the CSRF secret in the
  # session cookie and hands the token to the page.
  defp csrf_session(conn, org) do
    conn = get(conn, ~p"/orgs/#{org.slug}/settings")

    [_, token] =
      Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

    {recycle(conn), token}
  end

  # `Phoenix.ConnTest` skips CSRF checks by default; the real browser does not.
  defp enforce_csrf(conn), do: put_private(conn, :plug_skip_csrf_protection, false)
end
