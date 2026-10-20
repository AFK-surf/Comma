defmodule BridgeForTeamsWeb.DashboardAPIModelAccountsTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The organization accounts section of Settings → AI models, through its API
  and the real subscription worker: importing, disabling and removing a
  subscription, write-only Provider API keys, starting an authorization, using
  a reset credit, account usage, the owner/admin rule, CSRF protection, and
  query counts that do not grow with the lists.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Memberships, Models, Observability, Subscriptions}
  alias SalixAgent.AccountPool
  alias SalixAgent.SubscriptionStore, as: Store

  defmodule ResetWorker do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:start, id, data, to}, _, parent) do
      if Jason.decode!(data)["op"] == "/quota/reset" do
        SystemsRuntime.Proc.send(parent, :reset_called)
        reply = Base.encode64(Jason.encode!(%{"code" => "reset"}))
        SystemsRuntime.Proc.send(to, {:subscription, id, %{"type" => "data", "data" => reply}})
        SystemsRuntime.Proc.send(to, {:subscription, id, %{"type" => "done"}})
      else
        SystemsRuntime.Proc.send(
          to,
          {:subscription, id,
           %{"type" => "error", "status" => 502, "code" => "quota_unavailable"}}
        )
      end

      {:reply, :ok, parent}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  # A worker whose `/prepare` (credential refresh) waits until the test lets
  # it answer, so a user's change can land between the refresh's claim and
  # its write-back. `/quota` answers at once; other operations fail.
  defmodule GatedWorker do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, %{parent: parent, held: nil}}

    def handle_call({:start, id, data, to}, _, state) do
      case Jason.decode!(data)["op"] do
        "/prepare" ->
          SystemsRuntime.Proc.send(state.parent, {:prepare_held, SystemsRuntime.Proc.self()})
          {:reply, :ok, %{state | held: {id, to}}}

        "/quota" ->
          answer(to, id, %{"body" => %{"plan_type" => "pro"}})
          {:reply, :ok, state}

        _ ->
          SystemsRuntime.Proc.send(
            to,
            {:subscription, id, %{"type" => "error", "status" => 502, "code" => "unavailable"}}
          )

          {:reply, :ok, state}
      end
    end

    def handle_cast(_, state), do: {:noreply, state}

    def handle_info({:release, answer}, %{held: {id, to}} = state) do
      case answer do
        {:error, status, code} ->
          SystemsRuntime.Proc.send(
            to,
            {:subscription, id, %{"type" => "error", "status" => status, "code" => code}}
          )

        body ->
          answer(to, id, body)
      end

      {:noreply, %{state | held: nil}}
    end

    defp answer(to, id, body) do
      data = Base.encode64(Jason.encode!(body))
      SystemsRuntime.Proc.send(to, {:subscription, id, %{"type" => "data", "data" => data}})
      SystemsRuntime.Proc.send(to, {:subscription, id, %{"type" => "done"}})
    end
  end

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bft-subscriptions-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

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
    old = SystemsRuntime.get_env(:salix_agent, :subscription_worker)
    worker = start_supervised!({SalixAgent.SubscriptionWorker, name: nil, command: {binary, []}})
    quota_worker = start_supervised!({SalixWeb.TestSubscriptionQuotaWorker, worker})
    SystemsRuntime.put_env(:salix_agent, :subscription_worker, quota_worker)

    on_exit(fn ->
      if old,
        do: SystemsRuntime.put_env(:salix_agent, :subscription_worker, old),
        else: SystemsRuntime.delete_env(:salix_agent, :subscription_worker)
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
               "compatible_runtimes" => ["claude"]
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
      worker = start_supervised!({ResetWorker, SystemsRuntime.Proc.self()})
      SystemsRuntime.put_env(:salix_agent, :subscription_worker, worker)

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
               "href" => "/orgs/#{ctx.org.slug}/projects/#{visible.id}/devices"
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

    test "the models page says which account serves each model", ctx do
      path = "/dashboard/api/v1/orgs/#{ctx.org.slug}/settings/models"
      subscription_fixture(ctx.org)
      option = fn data, key -> Enum.find(data["catalog"], &(&1["key"] == key)) end

      data = get_data(ctx.conn, path)
      assert data["servable_status"] == "ok"

      assert %{"served_by" => "subscription", "plans" => ["codex"], "key_sources" => []} =
               option.(data, "catalog:gpt-5.5")

      assert %{"served_by" => nil} = option.(data, "catalog:claude-opus-4-8")
      refute option.(data, "catalog:claude-opus-4-8+paid")

      {:ok, _key} =
        AccountPool.create(ctx.org.salix_tenant_id, %{
          "credential_kind" => "provider_api_key",
          "source" => "openrouter",
          "api_key" => "sk-or-v1-0123456789abcdef"
        })

      # Pay-per-use is a choice of its own, naming the keys that may serve it.
      data = get_data(ctx.conn, path)
      refute option.(data, "catalog:claude-opus-4-8")

      assert %{
               "served_by" => "api_key",
               "key_sources" => ["OpenRouter"],
               "choice" => %{"allow_paid" => true} = paid
             } = option.(data, "catalog:claude-opus-4-8+paid")

      assert %{"served_by" => "subscription", "key_sources" => ["OpenRouter"]} =
               option.(data, "catalog:gpt-5.5")

      assert %{"served_by" => "api_key"} = option.(data, "catalog:gpt-5.5+paid")

      # Allowing it and making it the Worker default lets a Router choose it
      # pay-per-use, the way a Worker can run it.
      data =
        ctx.conn
        |> put(path, %{"allowed_models" => [paid], "default_task_model" => paid})
        |> json_response(200)
        |> data()

      assert [%{"key" => "catalog:claude-opus-4-8+paid"}] = data["allowed_models"]
      assert %{"key" => "catalog:claude-opus-4-8+paid"} = data["default_task_model"]

      project = bare_project_fixture(ctx.org, %{name: "Paid"})
      assert {:ok, ^paid} = Models.router_choice(project.id, nil)

      assert {:ok, %{"allow_paid" => true}} = Models.router_choice(project.id, paid)

      assert {:error, :model_not_allowed} =
               Models.router_choice(project.id, %{paid | "allow_paid" => false})
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

  # The quota poll and credential refresh write an account in the background.
  # A user's change made against the version the page showed applies when only
  # such writes came in between; a change from another user in between is
  # still a conflict.
  describe "a user's change and background writes" do
    test "a second user's change against the same version is still a conflict", ctx do
      account = subscription_fixture(ctx.org)
      [listed] = get_data(ctx.conn, accounts_path(ctx.org))["accounts"]
      credentials = %{"access_token" => "replaced-secret", "email" => "replaced@example.com"}

      changes = [
        %{"disabled" => true},
        %{"name" => "Renamed account"},
        %{"credentials" => credentials}
      ]

      for first <- changes, second <- changes do
        version =
          Store.get(ctx.org.salix_tenant_id, account["id"]) |> elem(1) |> Map.get("version")

        assert ctx.conn
               |> patch(account_path(ctx.org, account["id"]), Map.put(first, "version", version))
               |> json_response(200)

        assert ctx.conn
               |> patch(account_path(ctx.org, account["id"]), Map.put(second, "version", version))
               |> json_response(409)
      end

      assert listed["version"] !=
               Store.get(ctx.org.salix_tenant_id, account["id"]) |> elem(1) |> Map.get("version")
    end

    test "replacing credentials after a background write succeeds; the background write cannot undo it",
         ctx do
      tenant = ctx.org.salix_tenant_id
      account = subscription_fixture(ctx.org)
      [listed] = get_data(ctx.conn, accounts_path(ctx.org))["accounts"]
      assert {:ok, _} = AccountPool.quota(tenant, account["id"])

      # A credential refresh that read the account before the replacement.
      {:ok, before} = Store.get(tenant, account["id"])

      assert %{"accounts" => [%{"email" => "replaced@example.com"}]} =
               ctx.conn
               |> patch(account_path(ctx.org, account["id"]), %{
                 "version" => listed["version"],
                 "credentials" => %{
                   "access_token" => "replaced-secret",
                   "email" => "replaced@example.com"
                 }
               })
               |> json_response(200)
               |> data()

      {:ok, replaced} = Store.get(tenant, account["id"])

      assert {:error, :conflict} =
               Store.update_background(
                 tenant,
                 Map.put(before, "credential_revision", "refreshed"),
                 before["version"]
               )

      assert {:ok, ^replaced} = Store.get(tenant, account["id"])
    end
  end

  describe "a user's change during a credential refresh" do
    setup ctx do
      worker = start_supervised!({GatedWorker, SystemsRuntime.Proc.self()})
      SystemsRuntime.put_env(:salix_agent, :subscription_worker, worker)
      # An unprepared account refreshes its credentials before the quota read.
      account = subscription_fixture(ctx.org, %{"prepared" => false})
      [listed] = get_data(ctx.conn, accounts_path(ctx.org))["accounts"]
      tenant = ctx.org.salix_tenant_id
      poll = SystemsRuntime.Task.async(fn -> AccountPool.quota(tenant, account["id"]) end)
      worker = SystemsRuntime.Proc.receive(do: ({:prepare_held, pid} -> pid))
      {:ok, claimed} = Store.get(tenant, account["id"])
      assert claimed["status"] == "login"
      {:ok, account: account, listed: listed, tenant: tenant, poll: poll, worker: worker}
    end

    @refreshed %{
      "credentials" => %{"access_token" => "refreshed-token", "expired" => "2099-01-01T00:00:00Z"},
      "email" => "bft@example.com"
    }

    test "a toggle between the claim and the write-back keeps both", ctx do
      assert ctx.conn
             |> patch(account_path(ctx.org, ctx.account["id"]), %{
               "version" => ctx.listed["version"],
               "disabled" => true
             })
             |> json_response(200)

      SystemsRuntime.Proc.send(ctx.worker, {:release, @refreshed})
      SystemsRuntime.Task.await(ctx.poll, :infinity)
      {:ok, saved} = Store.get(ctx.tenant, ctx.account["id"])

      assert %{"status" => "ok", "disabled" => true, "prepared" => true} = saved

      assert {:ok, %{"access_token" => "refreshed-token"}} =
               Store.open(ctx.tenant, saved["id"], saved["credentials"])
    end

    test "credentials replaced between the claim and the write-back win", ctx do
      {:ok, replaced} =
        Store.update_edition(ctx.tenant, ctx.account["id"], ctx.listed["version"], fn current ->
          {:ok, cipher} = Store.seal(ctx.tenant, current["id"], %{"access_token" => "user-token"})

          current
          |> Map.merge(%{
            "credentials" => cipher,
            "credential_revision" => Store.id(),
            "status" => "ok"
          })
          |> then(&Store.update(ctx.tenant, &1, current["version"]))
        end)

      SystemsRuntime.Proc.send(ctx.worker, {:release, @refreshed})
      assert {:error, :conflict} = SystemsRuntime.Task.await(ctx.poll, :infinity)
      assert {:ok, ^replaced} = Store.get(ctx.tenant, ctx.account["id"])

      assert {:ok, %{"access_token" => "user-token"}} =
               Store.open(ctx.tenant, replaced["id"], replaced["credentials"])
    end

    test "an account deleted between the claim and the write-back stays deleted", ctx do
      {:ok, current} = Store.get(ctx.tenant, ctx.account["id"])
      assert {:ok, nil} = Store.delete(ctx.tenant, ctx.account["id"], current["version"])
      SystemsRuntime.Proc.send(ctx.worker, {:release, @refreshed})
      assert {:error, :not_found} = SystemsRuntime.Task.await(ctx.poll, :infinity)
      assert {:error, :not_found} = Store.get(ctx.tenant, ctx.account["id"])
    end
  end

  describe "a rejected refresh lifting its claim" do
    setup ctx do
      worker = start_supervised!({GatedWorker, SystemsRuntime.Proc.self()})
      SystemsRuntime.put_env(:salix_agent, :subscription_worker, worker)
      account = subscription_fixture(ctx.org, %{"prepared" => false})
      [listed] = get_data(ctx.conn, accounts_path(ctx.org))["accounts"]
      tenant = ctx.org.salix_tenant_id
      poll = SystemsRuntime.Task.async(fn -> AccountPool.quota(tenant, account["id"]) end)
      worker = SystemsRuntime.Proc.receive(do: ({:prepare_held, pid} -> pid))
      {:ok, account: account, listed: listed, tenant: tenant, poll: poll, worker: worker}
    end
  end

  test "members, non-members and revoked admins cannot manage accounts", ctx do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(ctx.org.id, member.id, "member")
    member_conn = log_in_user(build_conn(), member)
    outsider_conn = log_in_user(build_conn(), user_fixture())

    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn |> get(accounts_path(ctx.org)) |> json_response(403)

    assert %{"error" => %{"code" => "org_not_found"}} =
             outsider_conn |> get(accounts_path(ctx.org)) |> json_response(404)

    key = %{"provider" => "openai", "credentials" => %{"api_key" => "sk-denied"}}

    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn |> post(accounts_path(ctx.org), key) |> json_response(403)

    assert [%{result: "denied"}] =
             Observability.list_audit_logs(ctx.org.id, action: "model_account.created")

    {:ok, _} = Memberships.put_org_member(ctx.org.id, ctx.user.id, "member")

    assert %{"error" => %{"code" => "forbidden"}} =
             ctx.conn |> get(accounts_path(ctx.org)) |> json_response(403)

    assert {:error, :forbidden} = Subscriptions.list(ctx.scope, "")
  end

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
            "credential" => "subscription",
            "source" => "codex",
            "status" => "ok",
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

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "model-accounts-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
end
