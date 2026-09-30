defmodule SalixWeb.Dashboard.BrowserLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SalixStore.{BrowserSettings, Repo}
  @endpoint SalixWeb.DashboardEndpoint

  test "dashboard saves a tenant override, masks its token, and can disable it" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Browser settings"})
    scope = tenant["tenant_id"]
    old = Application.get_env(:salix_store, :compute_workload_credential_secret)

    Application.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("dashboard-test", 4)
    )

    on_exit(fn ->
      if row = Repo.get(BrowserSettings.Row, scope), do: Repo.delete!(row, log: false)

      if old,
        do: Application.put_env(:salix_store, :compute_workload_credential_secret, old),
        else: Application.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => scope})

    {:ok, view, _} = live(conn, "/dash/browser")

    html =
      view
      |> form("#browser-tenant", %{
        "scope" => "tenant",
        "mode" => "override",
        "account_id" => String.duplicate("a", 32),
        "api_token" => "private-dashboard-token"
      })
      |> render_submit()

    assert html =~ "Browser settings saved"
    refute html =~ "private-dashboard-token"
    assert {:ok, settings} = BrowserSettings.resolve(scope)
    assert settings.scope == scope

    assert {:ok, "private-dashboard-token"} =
             BrowserSettings.unseal(settings.token_ciphertext, scope)

    view
    |> form("#browser-tenant", %{"scope" => "tenant", "mode" => "disabled"})
    |> render_submit()

    assert {:error, :browser_disabled} = BrowserSettings.resolve(scope)
  end
end
