defmodule SalixWeb.Dashboard.ComposioLiveTest do
  @moduledoc """
  Composio dashboard surfaces: the tenant/platform-default settings page
  (write-only api_key, enabled flag, fallback badge) and the group page's
  Composio tab (not-configured hint, connect flow returning a Connect Link,
  connection listing/disconnect through a stubbed Composio client).
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Salix.Control.ComposioSettings

  @endpoint SalixWeb.DashboardEndpoint

  defmodule StubComposioClient do
    @moduledoc false
    def list_connected_accounts(_settings, user_id) do
      case SystemsRuntime.get_env(:salix_web, :composio_stub_accounts) do
        nil -> {:ok, []}
        {:error, _} = err -> err
        accounts -> {:ok, Enum.filter(accounts, &(&1["user_id"] == user_id))}
      end
    end

    def ensure_auth_config(_settings, _toolkit), do: {:ok, "ac_stub"}

    def create_connect_link(_settings, "ac_stub", _user_id, _opts \\ []),
      do: {:ok, %{"redirect_url" => "https://connect.composio.dev/link/lk_stub"}}

    def delete_connected_account(_settings, account_id) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.get_env(:salix_web, :composio_stub_pid),
        {:deleted, account_id}
      )

      :ok
    end
  end

  setup do
    # composio_settings is a node-global Postgres table shared across salix_web
    # suites; clear any leaked tenant/default rows so the not-configured
    # assertions start from a clean store.
    SalixStore.Repo.query!("TRUNCATE composio_settings")

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Composio"})
    tenant_id = tenant["tenant_id"]
    Process.put(:test_tenant_id, tenant_id)
    prev_client = SystemsRuntime.get_env(:salix_web, :composio_client_mod)
    SystemsRuntime.put_env(:salix_web, :composio_client_mod, StubComposioClient)
    SystemsRuntime.put_env(:salix_web, :composio_stub_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      if prev_client do
        SystemsRuntime.put_env(:salix_web, :composio_client_mod, prev_client)
      else
        SystemsRuntime.delete_env(:salix_web, :composio_client_mod)
      end

      SystemsRuntime.delete_env(:salix_web, :composio_stub_accounts)
      SystemsRuntime.delete_env(:salix_web, :composio_stub_pid)
      ComposioSettings.delete(tenant_id)
      ComposioSettings.delete_default()
    end)

    :ok
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  # ---- settings page ----

  test "settings page saves a tenant api key write-only and deletes it" do
    {:ok, view, html} = live(authed_conn(), "/dash/composio")
    assert html =~ "Composio"
    assert html =~ "not configured"

    html =
      view
      |> form("#composio-form", %{"api_key" => "ck_live_1", "base_url" => "", "enabled" => "true"})
      |> render_submit()

    assert html =~ "Composio settings saved."
    refute html =~ "ck_live_1"
    assert html =~ "leave blank to keep"
    assert {:ok, %{"api_key" => "ck_live_1"}} = ComposioSettings.get(tenant_id())

    # A blank api_key keeps the stored secret.
    view
    |> form("#composio-form", %{
      "api_key" => "",
      "base_url" => "https://eu.example",
      "enabled" => "true"
    })
    |> render_submit()

    assert {:ok, %{"api_key" => "ck_live_1", "base_url" => "https://eu.example"}} =
             ComposioSettings.get(tenant_id())

    html = render_click(element(view, "button[phx-click=delete]"))
    assert html =~ "Composio settings removed."
    assert {:error, :not_configured} = ComposioSettings.get(tenant_id())
  end

  # ---- group tab ----

  test "group composio tab lists connections, connects, and disconnects" do
    {:ok, _} = ComposioSettings.put(tenant_id(), %{"api_key" => "ck_live"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "ComposioGroup2"}, tenant_id())
    gid = group["group_id"]

    SystemsRuntime.put_env(:salix_web, :composio_stub_accounts, [
      %{
        "id" => "ca_mine",
        "user_id" => gid,
        "toolkit" => %{"slug" => "gmail"},
        "status" => "ACTIVE"
      },
      %{
        "id" => "ca_other",
        "user_id" => "other",
        "toolkit" => %{"slug" => "notion"},
        "status" => "ACTIVE"
      }
    ])

    {:ok, view, html} = live(authed_conn(), "/dash/groups/#{gid}?tab=composio")
    assert html =~ "ca_mine"
    assert html =~ "gmail"
    refute html =~ "ca_other"

    html =
      view
      |> form("form[phx-submit=composio-connect]", %{"toolkit" => "GMail"})
      |> render_submit()

    assert html =~ "https://connect.composio.dev/link/lk_stub"

    render_click(element(view, "button[phx-click=composio-disconnect]"))
    assert_received {:deleted, "ca_mine"}
  end
end
