defmodule BridgeForTeamsWeb.DashboardAPIModelAccountsTest do
  @moduledoc """
  The private templates and organization accounts sections of Settings → AI
  models, through their API and the real subscription worker: importing,
  disabling and removing a subscription, write-only Provider API keys,
  starting an authorization, using a reset credit, account usage, model
  discovery, template editing with guarded deletion, the owner/admin rule,
  CSRF protection, and query counts that do not grow with the lists.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Memberships, Models, Observability, Orgs, Subscriptions}
  alias SalixAgent.{AccountPool, Templates}
  alias SalixAgent.SubscriptionStore, as: Store

  defmodule ResetWorker do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:start, id, data, to}, _, parent) do
      if Jason.decode!(data)["op"] == "/quota/reset" do
        send(parent, :reset_called)
        reply = Base.encode64(Jason.encode!(%{"code" => "reset"}))
        send(to, {:subscription, id, %{"type" => "data", "data" => reply}})
        send(to, {:subscription, id, %{"type" => "done"}})
      else
        send(
          to,
          {:subscription, id,
           %{"type" => "error", "status" => 502, "code" => "quota_unavailable"}}
        )
      end

      {:reply, :ok, parent}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  defmodule ModelsWorker do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:start, id, data, to}, _, parent) do
      send(parent, {:discovery, Jason.decode!(data)["op"]})

      result = %{
        "data" => [
          %{"id" => "gpt-test-codex", "name" => "Codex Test Model", "supports_images" => false}
        ],
        "truncated" => false
      }

      send(
        to,
        {:subscription, id, %{"type" => "data", "data" => Base.encode64(Jason.encode!(result))}}
      )

      send(to, {:subscription, id, %{"type" => "done"}})
      {:reply, :ok, parent}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  setup_all do
    dir = Path.join(System.tmp_dir!(), "bft-subscriptions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    binary = Path.join(dir, "worker")

    {output, status} =
      System.cmd("go", ["build", "-o", binary, "./cmd/salix-account-proxy"],
        cd: Path.expand("../../../account-proxy", __DIR__),
        stderr_to_stdout: true
      )

    assert status == 0, output
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, binary: binary}
  end

  setup %{binary: binary, conn: conn} do
    %{org: org, user: user} = org_with_owner_fixture()
    old = Application.get_env(:salix_agent, :subscription_worker)
    worker = start_supervised!({SalixAgent.SubscriptionWorker, name: nil, command: {binary, []}})
    quota_worker = start_supervised!({SalixWeb.TestSubscriptionQuotaWorker, worker})
    Application.put_env(:salix_agent, :subscription_worker, quota_worker)

    on_exit(fn ->
      if old,
        do: Application.put_env(:salix_agent, :subscription_worker, old),
        else: Application.delete_env(:salix_agent, :subscription_worker)
    end)

    {:ok, org: org, user: user, conn: log_in_user(conn, user), scope: {org.id, user.id}}
  end

  describe "organization accounts" do
    test "an admin imports, disables and removes a subscription without seeing its secret",
         ctx do
      assert %{"accounts" => [], "next" => nil} = get_data(ctx.conn, accounts_path(ctx.org))

      conn =
        post(ctx.conn, accounts_path(ctx.org), %{
          "kind" => "subscription",
          "provider" => "codex",
          "credentials" => %{
            "access_token" => "bft-synthetic-secret",
            "email" => "bft@example.com"
          }
        })

      refute conn.resp_body =~ "bft-synthetic-secret"
      assert %{"accounts" => [account]} = conn |> json_response(200) |> data()
      assert account["email"] == "bft@example.com"
      assert account["provider"] == "codex"

      assert %{"accounts" => [%{"disabled" => true} = disabled]} =
               ctx.conn
               |> patch(account_path(ctx.org, account["id"]), %{
                 "version" => account["version"],
                 "disabled" => true
               })
               |> json_response(200)
               |> data()

      other = org_with_owner_fixture()

      assert {:error, :conflict} =
               Subscriptions.delete(
                 {other.org.id, other.user.id},
                 disabled["id"],
                 disabled["version"]
               )

      assert %{"accounts" => []} =
               ctx.conn
               |> delete(account_path(ctx.org, disabled["id"]), %{
                 "version" => disabled["version"]
               })
               |> json_response(200)
               |> data()
    end

    test "an admin saves a write-only Provider API key and renames it", ctx do
      conn =
        post(ctx.conn, accounts_path(ctx.org), %{
          "kind" => "provider_api_key",
          "name" => "Team gateway",
          "connection" => %{
            "endpoint" => "https://models.example.test/v1",
            "protocol" => "anthropic_messages",
            "auth_scheme" => "bearer"
          },
          "credentials" => %{"api_key" => "write-only-static-secret"}
        })

      refute conn.resp_body =~ "write-only-static-secret"
      assert %{"accounts" => [account]} = conn |> json_response(200) |> data()

      assert %{
               "credential_kind" => "provider_api_key",
               "name" => "Team gateway",
               "connection" => %{
                 "endpoint" => "https://models.example.test/v1",
                 "protocol" => "anthropic_messages"
               },
               "compatible_runtimes" => ["pi", "claude"]
             } = account

      assert {:ok, %{"accounts" => [stored]}} = AccountPool.list(ctx.org.salix_tenant_id)
      refute Map.has_key?(stored, "credentials")

      assert %{"accounts" => [%{"name" => "Renamed gateway"}]} =
               ctx.conn
               |> patch(account_path(ctx.org, account["id"]), %{
                 "version" => account["version"],
                 "name" => "Renamed gateway"
               })
               |> json_response(200)
               |> data()
    end

    test "Claude authorization starts with a PKCE link", ctx do
      assert %{"mode" => "callback", "id" => id, "href" => href} =
               ctx.conn
               |> post(accounts_path(ctx.org, "/oauth"), %{"provider" => "claude"})
               |> json_response(200)
               |> data()

      assert is_binary(id)
      assert href =~ "code_challenge"

      assert %{"error" => %{"code" => "invalid_input"}} =
               ctx.conn
               |> post(accounts_path(ctx.org, "/oauth"), %{"provider" => "elsewhere"})
               |> json_response(422)
    end

    test "a reset reports its outcome apart from the quota refresh and rechecks membership",
         ctx do
      worker = start_supervised!({ResetWorker, self()})
      Application.put_env(:salix_agent, :subscription_worker, worker)

      account =
        subscription_fixture(ctx.org, %{
          "quota" => %{"plan_type" => "free", "reset_credits" => %{"available_count" => 1}}
        })

      assert %{"accounts" => [%{"quota" => %{"plan_type" => "free"}}]} =
               get_data(ctx.conn, accounts_path(ctx.org))

      refute_received :reset_called

      assert %{"outcome" => "reset", "quota_refreshed" => false, "account" => %{"id" => id}} =
               ctx.conn
               |> post(account_path(ctx.org, account["id"], "/reset"), %{
                 "version" => account["version"],
                 "request_id" => Store.id()
               })
               |> json_response(200)
               |> data()

      assert id == account["id"]
      assert_receive :reset_called
      {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.user.id, "member")

      assert %{"error" => %{"code" => "forbidden"}} =
               ctx.conn
               |> post(account_path(ctx.org, account["id"], "/reset"), %{
                 "version" => account["version"],
                 "request_id" => Store.id()
               })
               |> json_response(403)

      refute_receive :reset_called
    end

    test "usage lists bindings in the organization's projects and counts the rest", ctx do
      account = provider_key_fixture(ctx.org)
      visible = bare_project_fixture(ctx.org, %{name: "Visible project"})
      other = org_with_owner_fixture()
      hidden = bare_project_fixture(other.org, %{name: "Hidden project"})
      bind(ctx.org, account, visible, "visible-workload")
      bind(ctx.org, account, hidden, "hidden-workload")
      path = account_path(ctx.org, account["id"], "/usage")

      assert %{
               "bindings" => [binding],
               "hidden_count" => 1,
               "next" => nil
             } = get_data(ctx.conn, path)

      assert binding == %{
               "project" => %{"id" => visible.id, "name" => "Visible project"},
               "workload_id" => "visible-workload",
               "href" =>
                 "/orgs/#{ctx.org.slug}/projects/#{visible.id}/devices?runtime_auth_target=visible-workload"
             }

      small = query_count(ctx.conn, path)

      for n <- 1..4 do
        project = bare_project_fixture(ctx.org, %{name: "Project #{n}"})
        bind(ctx.org, account, project, "workload-#{n}")
      end

      assert %{"bindings" => [_, _, _, _, _]} = get_data(ctx.conn, path)
      assert query_count(ctx.conn, path) == small
    end

    test "the list costs the same queries however many accounts there are", ctx do
      small = query_count(ctx.conn, accounts_path(ctx.org))
      for _ <- 1..3, do: provider_key_fixture(ctx.org)
      assert %{"accounts" => [_, _, _]} = get_data(ctx.conn, accounts_path(ctx.org))
      assert query_count(ctx.conn, accounts_path(ctx.org)) == small
    end

    test "writes need the page's CSRF token", ctx do
      conn = get(ctx.conn, ~p"/orgs/#{ctx.org.slug}/settings/models")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)
      body = %{"kind" => "provider_api_key", "name" => "No token"}

      assert_error_sent(403, fn -> post(conn, accounts_path(ctx.org), body) end)
      assert {:ok, %{"accounts" => []}} = AccountPool.list(ctx.org.salix_tenant_id)

      assert %{"error" => %{"code" => "invalid_input"}} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> post(accounts_path(ctx.org), body)
               |> json_response(422)
    end
  end

  describe "private templates" do
    test "discovery offers the subscription's models and the template keeps the display name",
         ctx do
      worker = start_supervised!({ModelsWorker, self()})
      Application.put_env(:salix_agent, :subscription_worker, worker)
      subscription_fixture(ctx.org)

      assert %{"models" => [model], "truncated" => false} =
               ctx.conn
               |> post(templates_path(ctx.org, "/discover"), %{"subscription_provider" => "codex"})
               |> json_response(200)
               |> data()

      assert %{"id" => "gpt-test-codex", "name" => "Codex Test Model"} = model
      assert_receive {:discovery, "/models"}

      assert %{"templates" => [%{"name" => "Internal alias"}]} =
               ctx.conn
               |> post(templates_path(ctx.org), %{
                 "name" => "Internal alias",
                 "subscription_provider" => "codex",
                 "model" => "gpt-test-codex",
                 "model_display_name" => "Codex Test Model",
                 "max_tokens" => "65536"
               })
               |> json_response(200)
               |> data()

      assert {:ok, [template]} = Templates.list_private(ctx.org.salix_tenant_id)
      assert template["model_display_name"] == "Codex Test Model"
      assert Templates.public_json(template)["model_icon"] == "codex"

      {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.user.id, "member")

      assert %{"error" => %{"code" => "forbidden"}} =
               ctx.conn
               |> post(templates_path(ctx.org, "/discover"), %{"subscription_provider" => "codex"})
               |> json_response(403)

      refute_receive {:discovery, _}
    end

    test "templates are edited, offered as models and deleted only when unused", ctx do
      fields = %{
        "subscription_provider" => "codex",
        "model" => "gpt-5.6-sol",
        "max_tokens" => "8192"
      }

      assert %{"templates" => [%{"template_id" => id, "name" => "Team Codex"}]} =
               ctx.conn
               |> post(templates_path(ctx.org), Map.put(fields, "name", "Team Codex"))
               |> json_response(200)
               |> data()

      {:ok, [template]} = Templates.list_private(ctx.org.salix_tenant_id)
      assert template["provider_config"] == %{"account_pool" => "codex"}
      {:ok, catalog} = Models.catalog(ctx.org)
      assert Enum.any?(catalog, &(&1["template_id"] == id))

      assert %{"templates" => [%{"name" => "Updated Codex", "max_tokens" => 8192}]} =
               ctx.conn
               |> put(templates_path(ctx.org, "/#{id}"), Map.put(fields, "name", "Updated Codex"))
               |> json_response(200)
               |> data()

      assert %{"ok" => true} =
               ctx.conn
               |> put("/dashboard/api/v1/orgs/#{ctx.org.slug}/settings/models", %{
                 "allowed_template_ids" => [id],
                 "default_template_id" => id
               })
               |> json_response(200)

      assert %{"error" => %{"code" => "conflict", "message" => message}} =
               ctx.conn |> delete(templates_path(ctx.org, "/#{id}")) |> json_response(409)

      assert message =~ "default and allowed models first"

      {:ok, org} = Orgs.get_org(ctx.org.id)

      {:ok, _} =
        Orgs.update_org(org, %{"default_template_id" => nil, "allowed_template_ids" => []})

      assert %{"templates" => []} =
               ctx.conn
               |> delete(templates_path(ctx.org, "/#{id}"))
               |> json_response(200)
               |> data()

      assert {:error, :not_found} = Templates.get(id, ctx.org.salix_tenant_id)
    end

    test "invalid input is refused with the editor's message", ctx do
      assert %{"error" => %{"code" => "invalid", "message" => message}} =
               ctx.conn
               |> post(templates_path(ctx.org), %{
                 "name" => "",
                 "subscription_provider" => "codex"
               })
               |> json_response(422)

      assert message =~ "Enter a name"
    end

    test "forged scope and platform config cannot escape the organization editor", ctx do
      attrs = %{
        "name" => "Private",
        "model" => "gpt-5",
        "subscription_provider" => "codex",
        "tenant_id" => "foreign",
        "scope" => "global",
        "provider_config" => %{"base_url" => "http://internal", "api_key" => "secret"}
      }

      assert {:ok, template} = Subscriptions.save_template(ctx.scope, nil, attrs)
      refute Map.has_key?(template, "provider_config")
      {:ok, stored} = Templates.get(template["template_id"], ctx.org.salix_tenant_id)
      assert stored["provider_config"] == %{"account_pool" => "codex"}
      assert stored["tenant_id"] == ctx.org.salix_tenant_id
      other = org_with_owner_fixture()

      assert {:error, _} =
               Subscriptions.save_template(
                 {other.org.id, other.user.id},
                 template["template_id"],
                 attrs
               )

      {:ok, global} = Templates.create(%{"name" => "Global", "model" => "gpt-5"})
      assert {:error, _} = Subscriptions.save_template(ctx.scope, global["template_id"], attrs)
    end

    test "deletion sees Agent records without template-shaped fields", ctx do
      template = template_fixture(ctx.scope, "Referenced")
      key = agent_key(ctx.org, "reference.json")

      {:ok, _} =
        SalixStore.S3.put(key, Jason.encode!(%{"template_id" => template["template_id"]}))

      assert {:error, {:conflict, message}} =
               Subscriptions.delete_template(ctx.scope, template["template_id"])

      assert message =~ "assigned to an Agent"
      assert {:ok, _} = Templates.get(template["template_id"], ctx.org.salix_tenant_id)
      :ok = SalixStore.S3.delete(key)
    end

    test "deletion fails closed when reference records cannot be decoded", ctx do
      template = template_fixture(ctx.scope, "Unreadable references")
      key = agent_key(ctx.org, "unreadable.json")
      {:ok, _} = SalixStore.S3.put(key, "not json")

      assert {:error, {:conflict, message}} =
               Subscriptions.delete_template(ctx.scope, template["template_id"])

      assert message =~ "Could not verify Agent references"
      assert {:ok, _} = Templates.get(template["template_id"], ctx.org.salix_tenant_id)
      :ok = SalixStore.S3.delete(key)
    end

    test "deletion bounds its Agent reference scan", ctx do
      template = template_fixture(ctx.scope, "Bounded deletion")

      keys =
        for n <- 1..101 do
          key = agent_key(ctx.org, "bounded-#{n}.json")
          {:ok, _} = SalixStore.S3.put(key, "{}")
          key
        end

      assert {:error, {:conflict, message}} =
               Subscriptions.delete_template(ctx.scope, template["template_id"])

      assert message =~ "scan limit"
      assert {:ok, _} = Templates.get(template["template_id"], ctx.org.salix_tenant_id)
      Enum.each(keys, &SalixStore.S3.delete/1)
    end
  end

  test "members, non-members and revoked admins cannot manage templates or accounts", ctx do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(ctx.org.id, member.id, "member")
    member_conn = log_in_user(build_conn(), member)
    outsider_conn = log_in_user(build_conn(), user_fixture())

    for path <- [templates_path(ctx.org), accounts_path(ctx.org)] do
      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn |> get(path) |> json_response(403)

      assert %{"error" => %{"code" => "org_not_found"}} =
               outsider_conn |> get(path) |> json_response(404)
    end

    template = %{"name" => "Denied", "subscription_provider" => "codex", "model" => "gpt-5"}

    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn |> post(templates_path(ctx.org), template) |> json_response(403)

    assert [%{result: "denied"}] =
             Observability.list_audit_logs(ctx.org.id, action: "model_template.saved")

    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.user.id, "member")

    assert %{"error" => %{"code" => "forbidden"}} =
             ctx.conn |> post(templates_path(ctx.org), template) |> json_response(403)

    assert {:error, :forbidden} = Subscriptions.list(ctx.scope, "")
    assert {:ok, []} = Templates.list_private(ctx.org.salix_tenant_id)
  end

  defp templates_path(org, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/settings/models/templates#{rest}"

  defp accounts_path(org, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/settings/models/accounts#{rest}"

  defp account_path(org, id, rest \\ ""), do: accounts_path(org, "/#{id}#{rest}")

  defp data(%{"data" => data}), do: data
  defp get_data(conn, path), do: conn |> get(path) |> json_response(200) |> data()

  defp subscription_fixture(org, attrs \\ %{}) do
    id = Store.id()
    {:ok, cipher} = Store.seal(org.salix_tenant_id, id, %{"access_token" => "test"})

    {:ok, account} =
      Store.create(
        org.salix_tenant_id,
        Map.merge(
          %{
            "id" => id,
            "credential_kind" => "subscription_oauth",
            "provider" => "codex",
            "status" => "active",
            "prepared" => true,
            "disabled" => false,
            "credentials" => cipher
          },
          attrs
        )
      )

    account
  end

  defp provider_key_fixture(org) do
    {:ok, account} =
      AccountPool.create(org.salix_tenant_id, %{
        "credential_kind" => "provider_api_key",
        "name" => "Usage account",
        "connection" => %{
          "endpoint" => "https://models.example.test",
          "protocol" => "anthropic_messages",
          "auth_scheme" => "bearer"
        },
        "credentials" => %{"api_key" => "write-only"}
      })

    account
  end

  defp bind(org, account, project, workload) do
    {:ok, _} =
      Store.query(
        "INSERT INTO runtime_subscription_bindings (tenant_id,project_id,workload_id,account_id) VALUES ($1,$2,$3,$4)",
        [org.salix_tenant_id, project.id, workload, account["id"]]
      )
  end

  defp template_fixture(scope, name) do
    {:ok, template} =
      Subscriptions.save_template(scope, nil, %{
        "name" => name,
        "model" => "gpt-5",
        "subscription_provider" => "codex"
      })

    template
  end

  defp agent_key(org, name),
    do: SalixStore.Keys.ctl_agents_prefix_for_tenant(org.salix_tenant_id) <> name

  defp query_count(conn, path) do
    test_pid = self()
    handler = "model-accounts-query-count-#{System.unique_integer([:positive])}"

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
end
