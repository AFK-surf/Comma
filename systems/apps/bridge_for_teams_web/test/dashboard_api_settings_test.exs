defmodule BridgeForTeamsWeb.DashboardAPISettingsTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The Settings API behind the React Settings pages (General, AI models,
  Single sign-on, Integrations): reads, every write and its audit, write-only
  secrets, the owner/admin rule with the denied-write audit, CSRF protection,
  and the fixed query counts of the CLI session list and the Integrations
  payload.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

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
      SystemsRuntime.put_env(:bridge_for_teams_web, :settings_feishu_connects, %{})
      SystemsRuntime.delete_env(:bridge_for_teams_web, :settings_feishu_list_error)
    end

    def connects_for(group_id) do
      :bridge_for_teams_web
      |> SystemsRuntime.get_env(:settings_feishu_connects, %{})
      |> Map.get(group_id, [])
    end

    def put_connects(group_id, connects) do
      connects_by_group =
        SystemsRuntime.get_env(:bridge_for_teams_web, :settings_feishu_connects, %{})

      SystemsRuntime.put_env(
        :bridge_for_teams_web,
        :settings_feishu_connects,
        Map.put(connects_by_group, group_id, connects)
      )
    end

    def list_group_im_connects(group_id, provider) when provider in [nil, "feishu"] do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:feishu_routes_listed, group_id})

      case SystemsRuntime.get_env(:bridge_for_teams_web, :settings_feishu_list_error) do
        nil -> {:ok, connects_for(group_id)}
        reason -> {:error, reason}
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

    test "updates the profile fields only and records the audit",
         %{conn: conn, org: org, user: user} do
      data =
        conn
        |> patch(settings_path(org, "general"), %{
          "name" => "Renamed Org",
          "icon" => @icon,
          "status" => "archived",
          "billing_account_id" => "forged",
          "allowed_models" => [
            %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
          ]
        })
        |> json_response(200)
        |> data()

      assert data["organization"]["name"] == "Renamed Org"
      assert data["organization"]["icon"] == @icon

      {:ok, reloaded} = Orgs.get_org(org.id)
      assert reloaded.name == "Renamed Org"
      assert reloaded.status == org.status
      assert reloaded.billing_account_id == org.billing_account_id
      assert reloaded.allowed_models == org.allowed_models

      assert [audit] = Observability.list_audit_logs(org.id, action: "org.settings.updated")
      assert audit.actor_user_id == user.id
      assert audit.redacted_diff["name"] == %{"from" => org.name, "to" => "Renamed Org"}
    end
  end

  describe "AI models" do
    @opus %{"kind" => "catalog", "model" => "claude-opus-4-8", "allow_paid" => false}
    @haiku %{"kind" => "catalog", "model" => "claude-haiku-4-5", "allow_paid" => false}

    test "saves the allowed models and defaults as model choices", %{
      conn: conn,
      org: org,
      user: user
    } do
      data = conn |> get(settings_path(org, "models")) |> json_response(200) |> data()

      assert data["catalog_status"] == "ok"

      assert %{"key" => "catalog:claude-opus-4-8", "choice" => @opus, "label" => "Opus 4.8"} =
               Enum.find(data["catalog"], &(&1["choice"] == @opus))

      assert Enum.any?(data["default_options"]["task"], &(&1["choice"] == @haiku))
      assert data["allowed_models"] == []
      assert data["default_task_model"] == nil
      assert data["default_router_model"] == nil

      data =
        conn
        |> put(settings_path(org, "models"), %{
          "allowed_models" => [@opus, @haiku],
          "default_task_model" => @opus
        })
        |> json_response(200)
        |> data()

      assert Enum.map(data["allowed_models"], & &1["choice"]) == [@opus, @haiku]
      assert data["default_task_model"]["key"] == "catalog:claude-opus-4-8"
      assert data["default_router_model"] == nil
      assert Enum.map(data["default_options"]["router"], & &1["choice"]) == [@opus, @haiku]

      {:ok, reloaded} = Orgs.get_org(org.id)
      assert reloaded.allowed_models == [@opus, @haiku]
      assert reloaded.default_task_model == @opus
      assert reloaded.default_router_model == nil

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "org.model_settings.updated")

      assert audit.actor_user_id == user.id

      assert %{"from" => nil, "to" => %{"kind" => "catalog", "model" => "claude-opus-4-8"}} =
               audit.redacted_diff["default_task_model"]
    end
  end

  describe "Single sign-on" do
    test "saves a generic OIDC connection without returning the secret",
         %{conn: conn, org: org, user: user} do
      data = conn |> get(settings_path(org, "sso")) |> json_response(200) |> data()
      assert data["connection"] == nil
      assert data["feishu_app"] == nil
      assert data["providers"] == ["generic_oidc", "feishu", "lark"]
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

    test "Lark SSO keeps its own App ID and a write-only App Secret",
         %{conn: conn, org: org, user: user} do
      body =
        conn
        |> put(settings_path(org, "sso"), %{
          "provider" => "lark",
          "client_id" => "cli_lark_app",
          "client_secret" => "lark-secret",
          "issuer" => "https://ignored.example.com",
          "allowed_domains" => "ignored.example.com",
          "default_role" => "member",
          "provider_config" => %{
            "scope" => "contact:user.email:readonly",
            "provisioning_policy" => "existing_identity",
            "tenant_key" => "forged",
            "token_endpoint" => "https://evil.example.com/token"
          }
        })
        |> response(200)

      refute body =~ "lark-secret"

      assert %{
               "provider" => "lark",
               "issuer" => nil,
               "client_id" => "cli_lark_app",
               "client_secret_configured" => true,
               "allowed_domains" => [],
               "default_role" => "member",
               "provider_config" => %{
                 "scope" => "contact:user.email:readonly",
                 "provisioning_policy" => "existing_identity"
               }
             } = body |> Jason.decode!() |> get_in(["data", "connection"])

      sso = Orgs.get_sso_connection(org.id)
      assert sso.client_secret == "lark-secret"

      assert sso.provider_config == %{
               "scope" => "contact:user.email:readonly",
               "provisioning_policy" => "existing_identity"
             }

      # A blank secret keeps the stored one while the provider stays Lark.
      assert %{"ok" => true} =
               conn
               |> put(settings_path(org, "sso"), %{
                 "provider" => "lark",
                 "client_id" => "cli_lark_app_2",
                 "client_secret" => "",
                 "provider_config" => %{"scope" => "", "provisioning_policy" => "jit"}
               })
               |> json_response(200)

      sso = Orgs.get_sso_connection(org.id)
      assert sso.client_id == "cli_lark_app_2"
      assert sso.client_secret == "lark-secret"
      assert sso.provider_config == %{"scope" => "", "provisioning_policy" => "jit"}

      assert [audit] = Observability.list_audit_logs(org.id, action: "sso_connection.created")
      assert audit.actor_user_id == user.id
      assert audit.metadata["provider"] == "lark"
      refute inspect(audit) =~ "lark-secret"
    end

    test "changing the provider to Lark needs the Lark App Secret and drops the Feishu config",
         %{conn: conn, org: org} do
      {:ok, _} =
        Orgs.upsert_sso_connection(org.id, %{
          "provider" => "feishu",
          "client_id" => "cli_feishu",
          "client_secret" => "feishu-secret",
          "provider_config" => %{
            "scope" => "contact:user.base:readonly",
            "tenant_key" => "feishu-tenant",
            "provisioning_policy" => "existing_identity"
          }
        })

      assert %{"error" => %{"code" => "invalid_sso_connection", "details" => details}} =
               conn
               |> put(settings_path(org, "sso"), %{
                 "provider" => "lark",
                 "client_id" => "cli_lark_app"
               })
               |> json_response(422)

      assert Map.has_key?(details["fields"], "client_secret")

      kept = Orgs.get_sso_connection(org.id)
      assert kept.provider == "feishu"
      assert kept.client_secret == "feishu-secret"

      assert %{"ok" => true} =
               conn
               |> put(settings_path(org, "sso"), %{
                 "provider" => "lark",
                 "client_id" => "cli_lark_app",
                 "client_secret" => "lark-secret"
               })
               |> json_response(200)

      sso = Orgs.get_sso_connection(org.id)
      assert sso.provider == "lark"
      assert sso.client_secret == "lark-secret"
      assert sso.provider_config == %{}
    end

    test "the checks of a Lark connection name Lark and its redirect setting",
         %{conn: conn, org: org} do
      {:ok, _} =
        Orgs.upsert_sso_connection(org.id, %{
          "provider" => "lark",
          "client_id" => "cli_lark_app",
          "client_secret" => "lark-secret"
        })

      body =
        conn
        |> post(settings_path(org, "sso/checks"))
        |> response(200)

      refute body =~ "lark-secret"
      data = body |> Jason.decode!() |> data()
      assert data["recorded"] == true
      assert data["checks"]["surface"] == "sso"

      assert [
               %{
                 "gate_id" => "sso.credentials",
                 "label" => "Lark credentials valid",
                 "status" => "skipped",
                 "evidence" => %{
                   "provider" => "lark",
                   "client_id_configured" => "true",
                   "client_secret_configured" => "true"
                 }
               },
               %{
                 "gate_id" => "sso.redirect_uri",
                 "status" => "ok",
                 "next_action" => next_action,
                 "evidence" => %{"redirect_uri" => "http://localhost:4102/auth/callback"}
               }
             ] = data["checks"]["gates"]

      assert next_action =~ "Security Settings of the Lark app"
    end
  end

  describe "Integrations: OAuth apps" do
    test "saves a tenant-scoped OAuth app write-only, audits it, and removes it", %{
      conn: conn,
      org: org,
      user: user
    } do
      body =
        conn
        |> put(oauth_path(org, "x"), %{
          "client_id" => "x-client",
          "client_secret" => "x-secret"
        })
        |> response(200)

      refute body =~ "x-secret"
      apps = body |> Jason.decode!() |> get_in(["data", "apps"]) |> Map.new(&{&1["provider"], &1})

      assert %{
               "client_id" => "x-client",
               "client_secret_configured" => true,
               "configured" => true
             } = apps["x"]

      assert {:ok, stored} = OrgOAuthApps.list_org_oauth_apps(org.id)
      assert Enum.find(stored, &(&1["provider"] == "x"))["client_secret_configured"]

      assert [saved] = Observability.list_audit_logs(org.id, action: "oauth_provider_app.saved")
      assert saved.actor_user_id == user.id
      assert saved.resource_id == "x"
      refute inspect(saved) =~ "x-secret"

      assert {:ok, %{"client_id" => "x-client", "client_secret" => "x-secret"}} =
               Salix.Control.OAuthApps.get(org.salix_tenant_id, "x")

      assert {:error, :not_configured} = Salix.Control.OAuthApps.get("ten1_other-org", "x")

      apps =
        conn
        |> delete(oauth_path(org, "x"))
        |> json_response(200)
        |> get_in(["data", "apps"])
        |> Map.new(&{&1["provider"], &1})

      assert apps["x"]["client_secret_configured"] == false

      assert [deleted] =
               Observability.list_audit_logs(org.id, action: "oauth_provider_app.deleted")

      assert deleted.resource_id == "x"
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

      # Bot-enabled and no Agent Swarm yet.
      assert feishu["routes_status"] == "ok"
      assert feishu["projects_shown"] == 0
      assert feishu["redirect_uri"] == "http://localhost:4102/auth/callback"

      cards = Map.new(feishu["scope_cards"], &{&1["id"], &1})
      assert Map.keys(cards) |> Enum.sort() == ["bot", "combined", "sso"]
      assert cards["combined"]["title"] == "SSO + group bot"

      for scope <- ~w(im:message:send_as_bot im:message.group_msg im:chat.members:read
                      contact:user.base:readonly contact:department.base:readonly) do
        assert scope in cards["combined"]["required_scopes"]
      end

      assert %{"scopes" => %{"tenant" => tenant_scopes, "user" => user_scopes}} =
               Jason.decode!(cards["combined"]["json"])

      assert "im:message.group_at_msg.include_bot:readonly" in tenant_scopes
      assert "approval:task" in tenant_scopes
      assert "mail:user_mailbox.message:send" in user_scopes
      assert "minutes:minutes.transcript:export" in user_scopes

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
      assert feishu["projects_shown"] == 50
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
        {"feishu_app_binding.created", &post(&1, feishu_apps_path(org), %{"app_id" => "cli_x"})}
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
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    FeishuRouteClient.reset()
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, client)

    on_exit(fn ->
      FeishuRouteClient.reset()
      restore_env(:bridge_for_teams_core, :salix_client, previous)
    end)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp register_signal_account(org) do
    n = SystemsRuntime.Proc.uniform(9_999_999)
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
    test_pid = SystemsRuntime.Proc.self()
    handler = "settings-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if SystemsRuntime.Proc.self() == test_pid,
            do: SystemsRuntime.Proc.send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    SystemsRuntime.Proc.receive do
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
