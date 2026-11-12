defmodule SalixWeb.Dashboard.TenantPaginationTest do
  use SystemsClock.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Salix.Control.Tenants
  alias SalixStore.{Keys, S3}
  alias SalixStore.S3.Fake
  @endpoint SalixWeb.DashboardEndpoint

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    Fake.reset()

    tenants =
      for index <- 1..60 do
        {:ok, tenant} = Tenants.create(%{"name" => "Tenant #{index}"})
        tenant
      end
      |> Enum.sort_by(& &1["tenant_id"])

    %{tenants: tenants}
  end

  defp conn_for(tenant) do
    build_conn()
    |> Plug.Test.init_test_session(%{
      "admin_authed" => true,
      "current_tenant" => tenant["tenant_id"]
    })
  end

  test "home and navigation read only the selected tenant", %{tenants: tenants} do
    selected = List.last(tenants)
    Fake.reset_read_log()
    {:ok, view, html} = live(conn_for(selected), "/dash")
    refute Enum.any?(tenant_reads(), &match?({:list, _, _}, &1))
    assert html =~ selected["name"]
    assert has_element?(view, "a[href='/dash/tenants']", "Browse tenants")

    assert {:error, {:live_redirect, %{to: "/dash/platform-profiles"}}} =
             view |> element("nav a[href='/dash/platform-profiles']") |> render_click()

    {:ok, _next_view, _html} = live(conn_for(selected), "/dash/platform-profiles")
    reads = tenant_reads()
    refute Enum.any?(reads, &match?({:list, _, _}, &1))
    assert Enum.all?(reads, fn {:get, key} -> key == Keys.ctl_tenant(selected["tenant_id"]) end)
  end

  test "tenant pages support forward and backward navigation with bounded reads", %{
    tenants: tenants
  } do
    Fake.reset_read_log()
    {:ok, view, _html} = live(conn_for(List.last(tenants)), "/dash/tenants")
    assert has_element?(view, "#tenants", hd(tenants)["tenant_id"])
    refute has_element?(view, "#tenants", List.last(tenants)["tenant_id"])
    assert has_element?(view, "button[phx-click='next-page']")
    refute has_element?(view, "button[phx-click='previous-page']")
    lists = for {:list, _, opts} <- tenant_reads(), do: opts
    assert length(lists) <= 2
    assert length(for {:get, _} <- tenant_reads(), do: :read) <= 52
    assert Enum.all?(lists, &(Keyword.fetch!(&1, :max_keys) == 25))
    Fake.set_fault({:fail, 503, :list, Keys.ctl_tenants_prefix()})
    render_click(element(view, "button[phx-click='next-page']"))
    assert has_element?(view, "[role=alert]", "Tenants are unavailable")
    assert has_element?(view, "#tenants", hd(tenants)["tenant_id"])
    render_click(element(view, "button[phx-click='retry-page']"))
    assert has_element?(view, "#tenants", Enum.at(tenants, 25)["tenant_id"])
    refute has_element?(view, "#tenants", hd(tenants)["tenant_id"])
    render_click(element(view, "button[phx-click='previous-page']"))
    assert has_element?(view, "#tenants", hd(tenants)["tenant_id"])
    render_click(element(view, "button[phx-click='next-page']"))
    render_click(element(view, "button[phx-click='next-page']"))
    selected = List.last(tenants)["tenant_id"]

    assert has_element?(
             view,
             "#tenants a[href='/dash/tenant/select?tenant_id=#{selected}']",
             "Use this tenant"
           )

    refute has_element?(view, "button[phx-click='next-page']")
  end

  test "pages hold full tenant counts when every tenant has child prefixes", %{
    tenants: tenants
  } do
    for tenant <- tenants do
      {:ok, _} = S3.put(Keys.ctl_tenant_plugin_definition(tenant["tenant_id"], "test"), "{}")
    end

    Fake.reset_read_log()
    assert {:ok, %{tenants: first, next: cursor}} = Tenants.page()
    assert first == Enum.slice(tenants, 0, 25)
    assert {:ok, %{tenants: second, next: cursor}} = Tenants.page(cursor)
    assert second == Enum.slice(tenants, 25, 25)
    assert {:ok, %{tenants: last, next: nil}} = Tenants.page(cursor)
    assert last == Enum.slice(tenants, 50, 10)
    assert length(for {:get, _} <- tenant_reads(), do: :read) == 60
  end

  test "default tenant lookup reads only one storage page", %{tenants: [first | _]} do
    Fake.reset_read_log()
    assert SalixWeb.Dashboard.Auth.current_tenant(%{}) == first["tenant_id"]
    assert [{:list, _, opts}, {:get, _}] = tenant_reads()
    assert opts[:max_keys] == 1
  end

  test "storage errors do not appear as an empty tenant list" do
    Fake.set_fault({:fail, 503, :list, Keys.ctl_tenants_prefix()})
    assert {:error, _} = Tenants.page()
  end

  defp tenant_reads do
    Enum.filter(Fake.read_log(), fn
      {:list, "ctl/tenants/", _} -> true
      {:get, "ctl/tenants/" <> _} -> true
      _ -> false
    end)
  end
end
