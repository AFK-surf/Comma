defmodule BridgeForTeamsWeb.Dashboard.SubscriptionsLiveTest do
  use BridgeForTeamsWeb.DashboardCase, async: false
  alias BridgeForTeams.{Memberships, Models, Orgs, Subscriptions}
  alias SalixAgent.{AccountPool, Templates}

  defmodule ResetWorker do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:start, id, data, to}, _, parent) do
      cmd = Jason.decode!(data)

      if cmd["op"] == "/quota/reset" do
        send(parent, :reset_called)

        send(
          to,
          {:subscription, id,
           %{"type" => "data", "data" => Base.encode64(Jason.encode!(%{"code" => "reset"}))}}
        )

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
      cmd = Jason.decode!(data)
      send(parent, {:discovery, cmd["op"]})

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

  test "organization discovers subscription models and saves their display name", ctx do
    alias SalixAgent.SubscriptionStore, as: Store
    worker = start_supervised!({ModelsWorker, self()})
    Application.put_env(:salix_agent, :subscription_worker, worker)
    id = Store.id()
    {:ok, cipher} = Store.seal(ctx.org.salix_tenant_id, id, %{"access_token" => "test"})

    {:ok, _} =
      Store.create(ctx.org.salix_tenant_id, %{
        "id" => id,
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "status" => "active",
        "prepared" => true,
        "disabled" => false,
        "credentials" => cipher
      })

    {:ok, view, _} = live(ctx.conn, "/orgs/#{ctx.org.slug}/settings/models/templates")
    settle(view)
    view |> element("button[phx-click=new]") |> render_click()
    view |> element("button[phx-click=discover]") |> render_click()
    assert settle(view) =~ "Codex Test Model"
    assert_receive {:discovery, "/models"}
    view |> element("button[phx-click=choose-model]") |> render_click()

    view
    |> form("#private-template-form", %{template: %{name: "Internal alias"}})
    |> render_submit()

    settle(view)
    assert {:ok, [template]} = Templates.list_private(ctx.org.salix_tenant_id)
    assert template["model_display_name"] == "Codex Test Model"
    assert Templates.public_json(template)["model_icon"] == "codex"
    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.user.id, "member")
    assert {:error, :forbidden} = Subscriptions.discover_models(ctx.scope, "codex")
    refute_receive {:discovery, _}
  end

  defp settle(view) do
    render_async(view, 5_000)
    render_async(view, 5_000)
  end

  setup_all do
    dir = Path.join(System.tmp_dir!(), "bft-subscriptions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    binary = Path.join(dir, "worker")

    {output, status} =
      System.cmd("go", ["build", "-o", binary, "./cmd/salix-account-proxy"],
        cd: Path.expand("../../../../account-proxy", __DIR__),
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

  test "organization reset reports success separately from quota refresh and rechecks membership",
       ctx do
    alias SalixAgent.SubscriptionStore, as: Store
    worker = start_supervised!({ResetWorker, self()})
    Application.put_env(:salix_agent, :subscription_worker, worker)
    id = Store.id()
    {:ok, cipher} = Store.seal(ctx.org.salix_tenant_id, id, %{"access_token" => "test"})

    {:ok, account} =
      Store.create(ctx.org.salix_tenant_id, %{
        "id" => id,
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "status" => "active",
        "prepared" => true,
        "disabled" => false,
        "credentials" => cipher,
        "quota" => %{"plan_type" => "free", "reset_credits" => %{"available_count" => 1}}
      })

    {:ok, view, _} = live(ctx.conn, "/orgs/#{ctx.org.slug}/settings/subscriptions")
    settle(view)
    assert has_element?(view, "#account-#{id}", "Free plan")
    view |> element("button[phx-click=reset]") |> render_click()
    refute_receive :reset_called
    view |> element("button[phx-click=confirm-reset]") |> render_click()
    html = settle(view)
    assert html =~ "One reset credit was used"
    assert html =~ "Allowance could not be refreshed"
    assert_receive :reset_called
    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.user.id, "member")

    assert {:error, :forbidden} =
             Subscriptions.reset_quota(ctx.scope, id, %{
               "version" => account["version"],
               "request_id" => Store.id()
             })

    refute_receive :reset_called
  end

  test "organization administrator imports, disables and removes an account through real worker",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/orgs/#{ctx.org.slug}/settings/subscriptions")
    assert settle(view) =~ "No organization accounts"
    view |> element("button[phx-click=open-import]") |> render_click()

    view
    |> form("form[phx-submit=import]", %{
      "provider" => "codex",
      "credential_json" => ~s({"access_token":"bft-synthetic-secret","email":"bft@example.com"})
    })
    |> render_submit()

    html = settle(view)
    assert html =~ "bft@example.com"
    refute html =~ "bft-synthetic-secret"
    view |> element("button[phx-click=toggle]") |> render_click()
    settle(view)
    assert has_element?(view, "tr[data-disabled=true]")
    assert {:ok, %{"accounts" => [account]}} = AccountPool.list(ctx.org.salix_tenant_id)
    other = org_with_owner_fixture()

    assert {:error, :conflict} =
             Subscriptions.delete(
               {other.org.id, other.user.id},
               account["id"],
               account["version"]
             )

    view |> element("button[phx-click=delete]") |> render_click()
    view |> element("button[phx-click=confirm-delete]") |> render_click()
    assert settle(view) =~ "No organization accounts"
  end

  test "organization administrator saves a write-only Provider API key", ctx do
    {:ok, view, _} = live(ctx.conn, "/orgs/#{ctx.org.slug}/settings/subscriptions")
    settle(view)
    view |> element("#add-provider-key") |> render_click()

    refute render(view) =~ ~s(phx-change="validate")

    view
    |> form("form[phx-submit=save-provider-key]", %{
      "name" => "Team gateway",
      "endpoint" => "https://models.example.test/v1",
      "protocol" => "anthropic_messages",
      "auth_scheme" => "bearer",
      "api_key" => "write-only-static-secret"
    })
    |> render_submit()

    html = settle(view)
    assert html =~ "Team gateway"
    assert html =~ "https://models.example.test/v1"
    assert html =~ "Anthropic Messages"
    assert html =~ "pi, Claude"
    refute html =~ "write-only-static-secret"

    assert {:ok, %{"accounts" => [account]}} = AccountPool.list(ctx.org.salix_tenant_id)
    assert account["credential_kind"] == "provider_api_key"
    refute Map.has_key?(account, "credentials")

    view |> element("button[phx-click=edit-name]") |> render_click()

    view
    |> form("form[phx-submit=save-provider-key]", %{"name" => "Renamed gateway"})
    |> render_submit()

    assert settle(view) =~ "Renamed gateway"
  end

  test "file import and OAuth setup work from BFT", ctx do
    {:ok, view, _} = live(ctx.conn, "/orgs/#{ctx.org.slug}/settings/subscriptions")
    settle(view)
    view |> element("button[phx-click=open-import]") |> render_click()

    upload =
      file_input(view, "form[phx-submit=import]", :credentials, [
        %{
          name: "auth.json",
          type: "application/json",
          content: ~s({"access_token":"file-secret","email":"file@example.com"})
        }
      ])

    render_upload(upload, "auth.json")
    view |> form("form[phx-submit=import]", %{"credential_json" => ""}) |> render_submit()
    assert settle(view) =~ "file@example.com"
    view |> element("button[phx-click=toggle]") |> render_click()
    settle(view)
    view |> element("button[phx-click=open-connect]") |> render_click()
    view |> form("#authorize", %{"provider" => "claude"}) |> render_submit()
    assert settle(view) =~ "Open Claude authorization"
    assert_push_event(view, "subscription-oauth-ready", %{url: url})
    assert url =~ "code_challenge"
  end

  test "private templates support editing, model governance and guarded deletion", ctx do
    {:ok, view, _} = live(ctx.conn, "/orgs/#{ctx.org.slug}/settings/models/templates")
    settle(view)
    view |> element("button[phx-click=new]") |> render_click()

    view
    |> form("#private-template-form", %{
      template: %{
        name: "Team Codex",
        subscription_provider: "codex",
        model: "gpt-5.6-sol",
        max_tokens: "8192"
      }
    })
    |> render_submit()

    assert settle(view) =~ "Team Codex"
    {:ok, [template]} = Templates.list_private(ctx.org.salix_tenant_id)
    assert template["provider_config"] == %{"account_pool" => "codex"}
    {:ok, catalog} = Models.catalog(ctx.org)
    assert Enum.any?(catalog, &(&1["template_id"] == template["template_id"]))
    view |> element("button[phx-click=edit]") |> render_click()

    view
    |> form("#private-template-form", %{template: %{name: "Updated Codex"}})
    |> render_submit()

    assert settle(view) =~ "Updated Codex"
    {:ok, models, _} = live(ctx.conn, "/orgs/#{ctx.org.slug}/settings/models")

    models
    |> form("#models-form",
      models: %{allowed: [template["template_id"]], default_template_id: template["template_id"]}
    )
    |> render_submit()

    {:ok, org} = Orgs.get_org(ctx.org.id)
    assert org.default_template_id == template["template_id"]
    view |> element("button[phx-click=delete]") |> render_click()
    view |> element("button[phx-click=confirm-delete]") |> render_click()
    assert settle(view) =~ "default and allowed models first"
    {:ok, _} = Orgs.update_org(org, %{"default_template_id" => nil, "allowed_template_ids" => []})
    view |> element("button[phx-click=confirm-delete]") |> render_click()
    settle(view)
    assert {:error, :not_found} = Templates.get(template["template_id"], ctx.org.salix_tenant_id)
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

  test "member, non-member and revoked administrator cannot manage subscriptions", ctx do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(ctx.org.id, member.id, "member")

    for user <- [member, user_fixture()], suffix <- ["subscriptions", "models/templates"] do
      assert {:error, {:redirect, _}} =
               live(log_in_user(build_conn(), user), "/orgs/#{ctx.org.slug}/settings/#{suffix}")
    end

    {:ok, view, _} = live(ctx.conn, "/orgs/#{ctx.org.slug}/settings/models/templates")
    settle(view)
    view |> element("button[phx-click=new]") |> render_click()
    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.user.id, "member")
    view |> form("#private-template-form", %{template: %{name: "Denied"}}) |> render_submit()
    assert settle(view) =~ "administrator access is required"
    assert {:error, :forbidden} = Subscriptions.list(ctx.scope, "")
    assert {:ok, []} = Templates.list_private(ctx.org.salix_tenant_id)
  end

  test "account usage exposes authorized projects and reports hidden bindings", ctx do
    alias SalixAgent.SubscriptionStore, as: Store

    visible = bare_project_fixture(ctx.org, %{name: "Visible project"})
    other = org_with_owner_fixture()
    hidden = bare_project_fixture(other.org, %{name: "Hidden project"})

    {:ok, account} =
      AccountPool.create(ctx.org.salix_tenant_id, %{
        "credential_kind" => "provider_api_key",
        "name" => "Usage account",
        "connection" => %{
          "endpoint" => "https://models.example.test",
          "protocol" => "anthropic_messages",
          "auth_scheme" => "bearer"
        },
        "credentials" => %{"api_key" => "write-only"}
      })

    for {project, workload} <- [{visible, "visible-workload"}, {hidden, "hidden-workload"}] do
      {:ok, _} =
        Store.query(
          "INSERT INTO runtime_subscription_bindings (tenant_id,project_id,workload_id,account_id) VALUES ($1,$2,$3,$4)",
          [ctx.org.salix_tenant_id, project.id, workload, account["id"]]
        )
    end

    assert {:ok,
            %{
              "bindings" => [%{"project" => project, "workload_id" => "visible-workload"}],
              "hidden_count" => 1,
              "next" => nil
            }} = Subscriptions.list_bindings(ctx.scope, account["id"])

    assert project == %{"id" => visible.id, "name" => visible.name, "slug" => visible.slug}

    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(ctx.org.id, member.id, "member")

    assert {:error, :forbidden} =
             Subscriptions.list_bindings({ctx.org.id, member.id}, account["id"])
  end

  test "private deletion sees Agent records without template-shaped fields", ctx do
    {:ok, template} =
      Subscriptions.save_template(ctx.scope, nil, %{
        "name" => "Referenced",
        "model" => "gpt-5",
        "subscription_provider" => "codex"
      })

    key =
      SalixStore.Keys.ctl_agents_prefix_for_tenant(ctx.org.salix_tenant_id) <> "reference.json"

    {:ok, _} = SalixStore.S3.put(key, Jason.encode!(%{"template_id" => template["template_id"]}))

    assert {:error, {:conflict, message}} =
             Subscriptions.delete_template(ctx.scope, template["template_id"])

    assert message =~ "assigned to an Agent"
    assert {:ok, _} = Templates.get(template["template_id"], ctx.org.salix_tenant_id)
    :ok = SalixStore.S3.delete(key)
  end

  test "private deletion fails closed when reference records cannot be decoded", ctx do
    {:ok, template} =
      Subscriptions.save_template(ctx.scope, nil, %{
        "name" => "Unreadable references",
        "model" => "gpt-5",
        "subscription_provider" => "codex"
      })

    key =
      SalixStore.Keys.ctl_agents_prefix_for_tenant(ctx.org.salix_tenant_id) <> "unreadable.json"

    {:ok, _} = SalixStore.S3.put(key, "not json")

    assert {:error, {:conflict, message}} =
             Subscriptions.delete_template(ctx.scope, template["template_id"])

    assert message =~ "Could not verify Agent references"
    assert {:ok, _} = Templates.get(template["template_id"], ctx.org.salix_tenant_id)
    :ok = SalixStore.S3.delete(key)
  end

  test "private deletion bounds its Agent reference scan", ctx do
    {:ok, template} =
      Subscriptions.save_template(ctx.scope, nil, %{
        "name" => "Bounded deletion",
        "model" => "gpt-5",
        "subscription_provider" => "codex"
      })

    prefix = SalixStore.Keys.ctl_agents_prefix_for_tenant(ctx.org.salix_tenant_id)

    keys =
      for n <- 1..101 do
        key = prefix <> "bounded-#{n}.json"
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
