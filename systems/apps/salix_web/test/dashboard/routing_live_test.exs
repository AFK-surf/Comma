defmodule SalixWeb.Dashboard.RoutingLiveTest do
  use SystemsClock.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Salix.Control.{Groups, Tenants}
  alias SalixAgent.TaskRouting.Learner
  alias SalixWeb.Dashboard.RoutingForm
  @endpoint SalixWeb.DashboardEndpoint

  setup do
    {:ok, tenant} = Tenants.create(%{"name" => "Routing file test"})
    tenant = tenant["tenant_id"]

    {:ok, profile} =
      SalixAgent.AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "api_key" => "fixture-routing-key-0000000000",
        "base_url" => "https://routing.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["local-model"]
      })

    {:ok, group} = Groups.create(%{"name" => "Model routing"}, tenant)

    policy = %{
      "mode" => "routes",
      "schema_version" => 2,
      "revision" => "original",
      "enabled" => false,
      "profile_id" => profile["id"],
      "entries" => []
    }

    {:ok, _} = Groups.update_task_model_selection(group["group_id"], tenant, nil, policy)
    %{tenant: tenant, group: group["group_id"], original: policy}
  end

  defp table(model \\ "local-model") do
    %{
      "mode" => "routes",
      "schema_version" => 2,
      "entries" => [
        %{
          "key" => "quick-edit",
          "description" => "Small, localized edits / 小修改",
          "model" => %{"kind" => "catalog", "model" => model, "reasoning_effort" => nil}
        }
      ]
    }
  end

  defp open(ctx) do
    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => ctx.tenant})

    {:ok, view, _} = live(conn, "/dash/groups/#{ctx.group}?tab=model-routing")
    render_async(view)
    view
  end

  defp saved(ctx) do
    {:ok, group} = Groups.get(ctx.group, ctx.tenant)
    group["task_model_selection"]
  end

  test "import and export operate on the draft, then normal save keeps the destination settings",
       ctx do
    view = open(ctx)
    render_hook(view, "import-routing", %{"json" => Jason.encode!(table())})
    assert saved(ctx) == ctx.original
    assert has_element?(view, "#routing-key-0[value=quick-edit]")
    render_click(view, "export-routing")
    assert_push_event(view, "download-routing", %{filename: "model-routing.json", json: json})
    assert Jason.decode!(json) == table()

    render_click(view, "reset-routing")
    render_async(view)
    refute has_element?(view, "#routing-key-0")
    render_hook(view, "import-routing", %{"json" => json})
    view |> form("#model-routing-form") |> render_submit()
    render_async(view)
    policy = saved(ctx)
    assert policy["entries"] == table()["entries"]
    assert policy["profile_id"] == ctx.original["profile_id"]
    refute policy["enabled"]
    refute policy["revision"] == ctx.original["revision"]
  end

  test "bad files preserve draft edits, and unavailable models cannot be saved", ctx do
    view = open(ctx)
    render_hook(view, "import-routing", %{"json" => Jason.encode!(table("unavailable-model"))})
    assert render_hook(view, "import-routing", %{"json" => "{"}) =~ "Invalid route table"
    assert has_element?(view, "#routing-key-0[value=quick-edit]")
    render_click(view, "export-routing")
    assert_push_event(view, "download-routing", %{json: json})
    assert {:ok, _} = RoutingForm.import_table(json)
    view |> form("#model-routing-form") |> render_submit()
    assert render_async(view) =~ "choose an available model"
    assert saved(ctx) == ctx.original
  end

  test "the editor saves an API key model without a table Profile pin", ctx do
    unpinned = Map.delete(ctx.original, "profile_id")
    {:ok, _} = Groups.update_task_model_selection(ctx.group, ctx.tenant, ctx.original, unpinned)
    view = open(ctx)
    render_click(view, "add-routing")

    paid =
      RoutingForm.model_key(%{
        "kind" => "catalog",
        "model" => "local-model",
        "allow_paid" => true
      })

    assert has_element?(view, "#routing-model-0 option", "local-model · Pay-per-use")

    view
    |> form("#model-routing-form", %{
      "routing" => %{
        "enabled" => "true",
        "rows" => %{
          "0" => %{"key" => "api", "description" => "Use the API model", "model" => paid}
        }
      }
    })
    |> render_change()

    view |> form("#model-routing-form") |> render_submit()
    render_async(view)
    assert saved(ctx)["enabled"]
    refute saved(ctx)["profile_id"]

    assert [%{"model" => %{"model" => "local-model", "allow_paid" => true}}] =
             saved(ctx)["entries"]
  end

  test "catalog models require an enabled organization account while the platform remains available",
       ctx do
    unpinned = Map.delete(ctx.original, "profile_id")

    {:ok, group} =
      Groups.update_task_model_selection(ctx.group, ctx.tenant, ctx.original, unpinned)

    {:ok, %{"models" => offered}} = SalixWeb.Dashboard.RoutingModels.load(group, ctx.tenant)
    ids = MapSet.new(offered, & &1["id"])
    assert MapSet.member?(ids, "local-model")
    refute MapSet.member?(ids, "deepseek-flash")
    platform = %{"kind" => "platform", "tier" => "worker"}
    assert Enum.any?(offered, &(&1["key"] == RoutingForm.model_key(platform)))

    {:ok, profile} =
      SalixAgent.AccountPool.create(ctx.tenant, %{
        "credential_kind" => "provider_api_key",
        "source" => "deepseek",
        "api_key" => "fixture-available-deepseek-0000000000"
      })

    {:ok, %{"models" => offered}} = SalixWeb.Dashboard.RoutingModels.load(group, ctx.tenant)

    paid_key =
      RoutingForm.model_key(%{
        "kind" => "catalog",
        "model" => "deepseek-flash",
        "allow_paid" => true
      })

    assert Enum.any?(offered, &(&1["key"] == paid_key))
    refute Enum.any?(offered, &(&1["key"] == "deepseek-flash"))

    {:ok, _} =
      SalixAgent.AccountPool.update(ctx.tenant, profile["id"], %{
        "disabled" => true,
        "version" => profile["version"]
      })

    {:ok, %{"models" => disabled}} = SalixWeb.Dashboard.RoutingModels.load(group, ctx.tenant)
    refute Enum.any?(disabled, &(&1["id"] == "deepseek-flash"))
  end

  test "saving uses current account state instead of stale page options", ctx do
    {:ok, profile} = SalixAgent.SubscriptionStore.get(ctx.tenant, ctx.original["profile_id"])

    {:ok, disabled} =
      SalixAgent.AccountPool.update(ctx.tenant, profile["id"], %{
        "disabled" => true,
        "version" => profile["version"]
      })

    view = open(ctx)
    render_hook(view, "import-routing", %{"json" => Jason.encode!(table())})

    {:ok, _} =
      SalixAgent.AccountPool.update(ctx.tenant, profile["id"], %{
        "disabled" => false,
        "version" => disabled["version"]
      })

    view |> form("#model-routing-form") |> render_submit()
    render_async(view)
    assert saved(ctx)["entries"] == table()["entries"]
  end

  test "the learning switch saves with the table and shows what each entry learned", ctx do
    view = open(ctx)
    render_hook(view, "import-routing", %{"json" => Jason.encode!(table())})

    view
    |> form("#model-routing-form", %{"routing" => %{"enabled" => "true", "learning" => "true"}})
    |> render_change()

    view |> form("#model-routing-form") |> render_submit()
    render_async(view)
    policy = saved(ctx)
    assert policy["learning"] == true
    assert policy["entries"] == table()["entries"]

    [entry] = policy["entries"]
    generation = Learner.generation(entry["key"], entry["description"])
    arm = Learner.arm_key(entry["model"])
    observation = %{"arm" => arm, "outcome" => "completed", "quality" => nil, "resources" => nil}

    {:ok, _} =
      SalixStore.TaskRoutingLearning.record(
        ctx.group,
        generation,
        "cnv_learning_live",
        observation,
        Learner.empty(),
        &Learner.update/2
      )

    view = open(ctx)
    assert has_element?(view, "#routing-learning[checked]")
    assert has_element?(view, "#routing-learned", "quick-edit: local-model · 1 results")

    view
    |> form("#model-routing-form", %{"routing" => %{"learning" => "false"}})
    |> render_change()

    view |> form("#model-routing-form") |> render_submit()
    render_async(view)
    refute Map.has_key?(saved(ctx), "learning")
    assert saved(ctx)["entries"] == table()["entries"]
  end

  test "a concurrent routing save also rejects an imported draft", ctx do
    view = open(ctx)
    render_hook(view, "import-routing", %{"json" => Jason.encode!(table())})
    winner = Map.put(ctx.original, "revision", "another-editor")
    {:ok, _} = Groups.update_task_model_selection(ctx.group, ctx.tenant, ctx.original, winner)
    view |> form("#model-routing-form") |> render_submit()
    assert render_async(view) =~ "Routing changed since this page loaded"
    assert saved(ctx) == winner
  end

  @tag skip: System.get_env("SALIX_ROUTING_BROWSER") != "1"
  @tag timeout: 120_000
  test "browser file upload and download", ctx do
    unpinned = Map.delete(ctx.original, "profile_id")
    {:ok, _} = Groups.update_task_model_selection(ctx.group, ctx.tenant, ctx.original, unpinned)

    {:ok, _} =
      SalixAgent.AccountPool.create(ctx.tenant, %{
        "credential_kind" => "provider_api_key",
        "source" => "deepseek",
        "api_key" => "fixture-browser-deepseek-key-0000000000"
      })

    server = start_supervised!({Bandit, plug: SalixWeb.DashboardEndpoint, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    script = Path.expand("../assets/routing_transfer_browser.mjs", __DIR__)

    {output, status} =
      System.cmd("node", [script],
        stderr_to_stdout: true,
        env: [
          {"ROUTING_BROWSER_URL", "http://127.0.0.1:#{port}"},
          {"ROUTING_BROWSER_TENANT", ctx.tenant},
          {"ROUTING_BROWSER_GROUP", ctx.group}
        ]
      )

    assert status == 0, output
    refute saved(ctx)["profile_id"]

    assert [
             %{
               "model" => %{
                 "model" => "deepseek-flash",
                 "allow_paid" => true,
                 "reasoning_effort" => "high"
               }
             }
           ] = saved(ctx)["entries"]
  end
end
