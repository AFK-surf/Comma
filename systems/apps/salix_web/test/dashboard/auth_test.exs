defmodule SalixWeb.Dashboard.AuthTest do
  @moduledoc """
  Dashboard admin-token login gating. The dashboard endpoint runs
  with `server: false`, so LiveViewTest drives it directly (no listener).
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixWeb.Dashboard.Auth

  @endpoint SalixWeb.DashboardEndpoint
  # config/test.exs sets :salix_web, :api_token to "test-token".
  @token "test-token"

  setup do
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_web, :api_token, @token)

    on_exit(fn ->
      if prev_api_token do
        Application.put_env(:salix_web, :api_token, prev_api_token)
      else
        Application.delete_env(:salix_web, :api_token)
      end
    end)
  end

  describe "verify_token/1" do
    test "accepts the configured admin token and rejects others" do
      assert Auth.verify_token(@token)
      refute Auth.verify_token("wrong")
      refute Auth.verify_token("")
      refute Auth.verify_token(nil)
    end
  end

  describe "authentication gate" do
    test "anonymous /dash redirects to login" do
      conn = build_conn() |> Plug.Test.init_test_session(%{})
      assert {:error, {:redirect, %{to: "/dash/login"}}} = live(conn, "/dash")
    end

    test "authenticated /dash renders the home page" do
      {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Home"})
      tenant_id = tenant["tenant_id"]

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id})

      {:ok, _view, html} = live(conn, "/dash")
      assert html =~ "Salix Admin"
    end
  end
end
