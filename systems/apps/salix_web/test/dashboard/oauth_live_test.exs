defmodule SalixWeb.Dashboard.OAuthLiveTest do
  @moduledoc "Tenant OAuth provider-apps dashboard, including the control-store fault state."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixStore.Repo

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "OAuth Live"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    :ok
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  test "renders the provider-apps page" do
    {:ok, _view, html} = live(authed_conn(), "/dash/oauth")
    assert html =~ "OAuth provider apps"
  end

  test "shows an error state (no crash) when the control store is unavailable" do
    # A Postgres fault must not crash the LiveView with a non-list assign; it
    # renders an error banner and empty tables instead. (The provider-apps and
    # default-apps lists are Postgres-backed; renaming that table is enough.)
    Repo.query!("ALTER TABLE oauth_provider_apps RENAME TO oauth_provider_apps_tmp")

    on_exit(fn ->
      Repo.query!("ALTER TABLE oauth_provider_apps_tmp RENAME TO oauth_provider_apps")
    end)

    {:ok, _view, html} = live(authed_conn(), "/dash/oauth")
    assert html =~ "temporarily unavailable"
  end
end
