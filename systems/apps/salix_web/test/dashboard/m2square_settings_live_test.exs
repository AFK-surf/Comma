defmodule SalixWeb.Dashboard.M2squareSettingsLiveTest do
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BridgeForTeams.M2square.Config
  alias Salix.Control.M2squareSettings
  alias SalixStore.{Keys, S3}

  @endpoint SalixWeb.DashboardEndpoint
  @path "/dash/m2square"

  setup do
    key = Keys.ctl_system_m2square_settings()
    S3.Fake.delete(key, [])
    on_exit(fn -> S3.Fake.delete(key, []) end)
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "M2square billing UI"})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        "admin_authed" => true,
        "current_tenant" => tenant["tenant_id"]
      })

    {:ok, conn: conn, key: key}
  end

  test "only an authenticated admin can open the platform billing form" do
    assert redirected_to(get(build_conn(), @path)) == "/dash/login"
  end

  test "unconfigured billing is disabled and saves only currencies with selected methods", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, @path)
    assert has_element?(view, "#m2square-settings-status", "Unconfigured (all disabled)")

    for code <- Config.country_order() do
      assert has_element?(view, "#m2square-enabled-#{code}:not([checked])")
    end

    countries = draft("EC", true, nil)
    render_submit(view, "save", form_params(countries))
    assert has_element?(view, "#m2square-enabled-EC[checked]")

    assert has_element?(
             view,
             "#m2square-error-EC[role=alert]",
             "Select at least one payment method"
           )

    assert {:ok, :unconfigured} = M2squareSettings.get()

    countries = draft("EC", true, ["CASH"])
    render_change(view, "change", form_params(countries))
    refute has_element?(view, "#m2square-error-EC")
    render_submit(view, "save", form_params(countries))

    assert has_element?(view, "#m2square-settings-status", "Configured")
    assert has_element?(view, "#m2square-method-EC-CASH[checked]")

    assert %{enabled: true, payment_types: ["CASH"], id_types: ["CI", "RUC"]} =
             Config.effective_config().countries["EC"]
  end

  test "a second administrator's stale first save reloads the authoritative settings", %{
    conn: conn
  } do
    {:ok, first, _} = live(conn, @path)
    {:ok, second, _} = live(conn, @path)

    render_submit(first, "save", form_params(draft("BR", true, ["PIX"])))
    html = render_submit(second, "save", form_params(draft("EC", true, ["CASH"])))

    assert html =~ "Someone else saved first."
    assert has_element?(second, "#m2square-enabled-BR[checked]")
    assert has_element?(second, "#m2square-enabled-EC:not([checked])")
    assert {:ok, %{etag: etag}} = M2squareSettings.get_for_admin()
    assert has_element?(second, "input[name=expected_etag][value='#{etag}']")
  end

  test "a conditional retry ambiguity is settled from the saved record", %{conn: conn, key: key} do
    {:ok, view, _} = live(conn, @path)
    S3.Fake.set_fault({:precondition_after, :put, key})

    html = render_submit(view, "save", form_params(draft("BR", true, ["PIX"])))

    assert html =~ "Current settings already match your changes."
    assert has_element?(view, "#m2square-settings-status", "Configured")

    assert {:ok, %{etag: etag, countries: %{"BR" => %{"enabled" => true}}}} =
             M2squareSettings.get_for_admin()

    assert has_element?(view, "input[name=expected_etag][value='#{etag}']")
  end

  test "an ambiguous write that did not persist leaves the draft ready for a deliberate retry",
       %{conn: conn, key: key} do
    {:ok, view, _} = live(conn, @path)
    S3.Fake.set_fault({:ambiguous_before, :put, key})

    html = render_submit(view, "save", form_params(draft("BR", true, ["PIX"])))

    assert html =~ "the record was not saved"
    assert has_element?(view, "#m2square-settings-status", "Unconfigured (all disabled)")
    assert has_element?(view, "#m2square-enabled-BR[checked]")
    assert {:ok, :unconfigured} = M2squareSettings.get()
    assert has_element?(view, "input[name=expected_etag][value='__unconfigured__']")
  end

  test "an unreadable settlement blocks editing until Retry reloads the record", %{
    conn: conn,
    key: key
  } do
    {:ok, view, _} = live(conn, @path)
    S3.Fake.set_fault({:precondition_after, :put, key})
    S3.Fake.blackhole({:fail, 503, :get, key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    render_submit(view, "save", form_params(draft("BR", true, ["PIX"])))
    assert has_element?(view, "[role=alert]", "Save status is pending confirmation")
    refute has_element?(view, "#m2square-settings-form")

    S3.Fake.clear_blackhole()
    view |> element("button", "Retry") |> render_click()
    assert has_element?(view, "#m2square-enabled-BR[checked]")
    assert has_element?(view, "#m2square-settings-status", "Configured")
  end

  defp draft(code, enabled, methods) do
    countries = M2squareSettings.default_all_disabled_countries()
    row = if methods, do: %{"payment_types" => methods}, else: %{}
    Map.put(countries, code, Map.put(row, "enabled", to_string(enabled)))
  end

  defp form_params(countries),
    do: %{"countries" => countries, "expected_etag" => M2squareSettings.unconfigured_etag()}
end
