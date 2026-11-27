defmodule SalixWeb.Dashboard.TenantPaginationTest do
  use SystemsClock.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Salix.Control.Tenants
  alias SalixStore.{Ids, Keys, S3}
  alias SalixStore.S3.Fake
  @endpoint SalixWeb.DashboardEndpoint

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    Fake.reset()
    # The directory table is shared by every suite in this VM: the list tests
    # search for this token, which only this test's Tenants carry.
    token = "pager#{SystemsRuntime.Proc.unique_integer([:positive])}z"

    tenants =
      for index <- 1..60 do
        {:ok, tenant} = Tenants.create(%{"name" => "Tenant #{token} #{index}"})
        tenant
      end
      |> Enum.sort_by(& &1["tenant_id"])

    %{tenants: tenants, token: token}
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

  test "the tenant list pages the directory newest first without reading storage", %{
    tenants: tenants,
    token: token
  } do
    newest = Enum.sort_by(tenants, &{&1["created_at"], &1["tenant_id"]}, :desc)
    Fake.reset_read_log()
    {:ok, view, _html} = live(conn_for(List.last(tenants)), "/dash/tenants?q=#{token}")
    assert has_element?(view, "#tenants", hd(newest)["tenant_id"])
    refute has_element?(view, "#tenants", Enum.at(newest, 25)["tenant_id"])
    assert has_element?(view, "#tenant-products a[data-product=all]", "60")
    refute has_element?(view, "button[phx-click='previous-page']")
    render_click(element(view, "button[phx-click='next-page']"))
    assert has_element?(view, "#tenants", Enum.at(newest, 25)["tenant_id"])
    refute has_element?(view, "#tenants", hd(newest)["tenant_id"])
    render_click(element(view, "button[phx-click='previous-page']"))
    assert has_element?(view, "#tenants", hd(newest)["tenant_id"])
    render_click(element(view, "button[phx-click='next-page']"))
    render_click(element(view, "button[phx-click='next-page']"))
    last = List.last(newest)["tenant_id"]

    assert has_element?(
             view,
             "#tenants a[href='/dash/tenant/select?tenant_id=#{last}']",
             "Use this tenant"
           )

    refute has_element?(view, "button[phx-click='next-page']")
    refute Enum.any?(tenant_reads(), &match?({:list, _, _}, &1))
  end

  test "search and product filter live in the URL and start again on the first page", %{
    tenants: tenants,
    token: token
  } do
    comma = Ids.new_tenant_id()
    guests = Ids.new_tenant_id()
    cft = Ids.new_tenant_id()

    {:ok, _} =
      Tenants.create_preallocated(%{"name" => "Space #{token}", "product" => "comma"}, comma)

    {:ok, _} =
      Tenants.create_preallocated(%{"name" => "Guests #{token}", "product" => "comma"}, guests)

    {:ok, _} = SalixStore.TenantProfiles.put_router_only(guests, 4)
    {:ok, _} = Tenants.create_preallocated(%{"name" => "Org #{token}", "product" => "cft"}, cft)
    conn = conn_for(hd(tenants))

    {:ok, view, _html} = live(conn, "/dash/tenants?q=#{token}")
    assert has_element?(view, "#tenant-products a[data-product=all]", "63")
    assert has_element?(view, "#tenant-products a[data-product=comma]", "2")
    assert has_element?(view, "#tenant-products a[data-product=cft]", "1")
    assert has_element?(view, "#tenant-products a[data-product=other]", "60")
    render_click(element(view, "button[phx-click='next-page']"))
    assert has_element?(view, "#tenant-pager span", "Page 2")

    # A product segment keeps the search and starts again on page 1, which
    # holds every match: no pager.
    render_click(element(view, "#tenant-products a[data-product=comma]"))
    refute has_element?(view, "#tenant-pager")
    assert has_element?(view, "#tenants", comma)
    assert has_element?(view, "#tenants", "Comma · guests")
    refute has_element?(view, "#tenants", cft)

    # Refresh or a shared link opens the same view.
    {:ok, view, _html} = live(conn, "/dash/tenants?q=#{token}&product=cft")
    assert has_element?(view, "#tenants", cft)
    refute has_element?(view, "#tenants", comma)

    # A Tenant id finds its Tenant; the search box patches the URL.
    view |> form("#tenant-search", %{"q" => guests}) |> render_change()
    assert has_element?(view, "#tenant-products a[data-product=all]", "1")
    refute has_element?(view, "#tenants")
    assert has_element?(view, "h3", ~s(No tenants match "#{guests}"))

    render_click(element(view, "#tenant-products a[data-product=all]"))
    assert has_element?(view, "#tenants", guests)

    view |> form("#tenant-search", %{"q" => "nothing-#{token}"}) |> render_change()
    assert has_element?(view, "h3", ~s(No tenants match "nothing-#{token}"))
    render_click(element(view, "button[phx-click='clear-search']", "Clear search"))
    refute has_element?(view, "#tenant-search input[value]")
    assert has_element?(view, "#tenants")
  end

  test "a failed directory read keeps the page with Retry, and Retry loads the page", %{
    tenants: tenants,
    token: token
  } do
    newest = Enum.sort_by(tenants, &{&1["created_at"], &1["tenant_id"]}, :desc)
    {:ok, view, _html} = live(conn_for(hd(tenants)), "/dash/tenants?q=#{token}")

    # The directory table is out of reach for the next read.
    SalixStore.Repo.query!("ALTER TABLE tenant_directory RENAME TO tenant_directory_unavailable")

    on_exit(fn ->
      SalixStore.Repo.query!(
        "ALTER TABLE IF EXISTS tenant_directory_unavailable RENAME TO tenant_directory"
      )
    end)

    render_click(element(view, "button[phx-click='next-page']"))
    assert has_element?(view, "[role=alert]", "Tenants are unavailable")
    assert has_element?(view, "#tenants", hd(newest)["tenant_id"])

    SalixStore.Repo.query!("ALTER TABLE tenant_directory_unavailable RENAME TO tenant_directory")
    render_click(element(view, "button[phx-click='retry-page']"))
    refute has_element?(view, "[role=alert]")
    assert has_element?(view, "#tenants", Enum.at(newest, 25)["tenant_id"])
    assert has_element?(view, "#tenant-pager span", "Page 2")
  end

  test "Created shows a relative time with the full time on hover", %{
    tenants: tenants,
    token: token
  } do
    created_at = Salix.Control.Store.now() - 2 * 86_400
    id = Ids.new_tenant_id()

    {:ok, _} =
      SalixStore.TenantDirectory.upsert(%{
        "tenant_id" => id,
        "name" => "Aged #{token}",
        "created_at" => created_at
      })

    {:ok, view, _html} =
      live(conn_for(hd(tenants)), "/dash/tenants?q=#{URI.encode_www_form("Aged #{token}")}")

    full = SalixWeb.Dashboard.LocalTime.utc_text(created_at * 1_000, "full")
    assert has_element?(view, ~s(#tenants time[title="#{full}"]), "2d ago")
    refute has_element?(view, "#tenant-pager")
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
