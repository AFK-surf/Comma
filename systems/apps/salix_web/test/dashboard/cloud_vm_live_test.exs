defmodule SalixWeb.Dashboard.CloudVMLiveTest do
  @moduledoc """
  The Cloud VM platform-defaults dashboard page renders and round-trips a save
  through `SalixWeb.CloudVM`, with secrets write-only.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixWeb.CloudVM

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    SalixStore.S3.Fake.reset()
    on_exit(fn -> CloudVM.delete_default_vm_config() end)
    :ok
  end

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => "default"})

  test "renders the page (unconfigured) without crashing" do
    {:ok, _view, html} = live(authed_conn(), "/dash/cloud-vm")

    assert html =~ "Cloud VM platform defaults"
    assert html =~ "Default provider"
    assert html =~ "no secret"
  end

  test "saving persists the default config and shows the write-only state" do
    {:ok, view, _html} = live(authed_conn(), "/dash/cloud-vm")

    html =
      view
      |> form("#cloud-vm-defaults", %{
        "default_provider" => "cloudflare",
        "cloudflare_enabled" => "true",
        "cloudflare_gateway_base_url" => "https://gateway.example.test",
        "cloudflare_gateway_secret" => "cf-dash-secret"
      })
      |> render_submit()

    assert html =~ "Platform VM defaults saved."
    # Configured badge now shows; the secret is never echoed.
    assert html =~ "secret configured"
    refute html =~ "cf-dash-secret"

    # It actually reached the default-config store (write-only on read-back).
    assert {:ok, cfg} = CloudVM.default_vm_config()
    assert cfg["default_provider"] == "cloudflare"
    assert cfg["providers"]["cloudflare"]["gateway_secret"] == "cf-dash-secret"
    refute Map.has_key?(cfg["providers"], "sprites")
  end

  test "requires admin session" do
    conn = build_conn() |> Plug.Test.init_test_session(%{})
    assert {:error, {:redirect, %{to: "/dash/login"}}} = live(conn, "/dash/cloud-vm")
  end
end
