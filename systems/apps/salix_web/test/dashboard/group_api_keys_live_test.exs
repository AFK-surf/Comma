defmodule SalixWeb.Dashboard.GroupApiKeysLiveTest do
  @moduledoc "The group's Inbound API tab (docs/product-features.md)."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")
    prev_public_base_url = Application.get_env(:salix_web, :public_base_url)
    Application.put_env(:salix_web, :public_base_url, "https://salix.example.test")

    on_exit(fn ->
      if prev_public_base_url == nil,
        do: Application.delete_env(:salix_web, :public_base_url),
        else: Application.put_env(:salix_web, :public_base_url, prev_public_base_url)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Inbound API"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "KeyGroup"}, tenant["tenant_id"])
    {:ok, tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  defp authed_conn(tenant_id),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id})

  test "keys are created once in plaintext, renamed, disabled, and deleted", ctx do
    path = "/dash/groups/#{ctx.group_id}?tab=api-keys"
    {:ok, view, html} = live(authed_conn(ctx.tenant_id), path)
    assert html =~ "No inbound API keys"

    html =
      view
      |> form("#group-api-key-form", %{"name" => "Zendesk"})
      |> render_submit()

    assert html =~ "shown only once"
    assert html =~ "salix_gk_"
    # The example targets the externally reachable base, not the local listener.
    assert html =~
             "https://salix.example.test/v1/agent-groups/#{ctx.group_id}/router/post-message"

    refute html =~ "127.0.0.1"
    assert [%{"key_id" => key_id, "name" => "Zendesk", "created_by" => "salix_admin"}] = keys(ctx)

    # Dismissing the banner is the last time the plaintext is on the page.
    html = render_click(element(view, "button[phx-click=dismiss-api-key]"))
    refute html =~ "shown only once"
    assert html =~ "Zendesk"

    html = render_click(view, "update-api-key", %{"key_id" => key_id, "status" => "disabled"})
    assert html =~ "updated"
    assert [%{"status" => "disabled"}] = keys(ctx)

    html = render_click(view, "update-api-key", %{"key_id" => key_id, "name" => "Jira"})
    assert html =~ "Jira"
    assert [%{"name" => "Jira", "status" => "disabled"}] = keys(ctx)

    html = render_click(view, "delete-api-key", %{"key_id" => key_id})
    assert html =~ "deleted"
    assert html =~ "No inbound API keys"
    assert keys(ctx) == []
  end

  test "a rejected create is explained, not swallowed", ctx do
    {:ok, view, _html} =
      live(authed_conn(ctx.tenant_id), "/dash/groups/#{ctx.group_id}?tab=api-keys")

    html =
      view
      |> form("#group-api-key-form", %{"name" => "Past", "expires_at" => "2000-01-01T00:00:00Z"})
      |> render_submit()

    assert html =~ "expires_at must be in the future"
    assert keys(ctx) == []
  end

  test "another tenant's group is not reachable", ctx do
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Other"})

    assert {:error, {:live_redirect, %{to: "/dash/groups"}}} =
             live(authed_conn(other["tenant_id"]), "/dash/groups/#{ctx.group_id}?tab=api-keys")
  end

  defp keys(ctx) do
    {:ok, keys} = Salix.Control.GroupApiKeys.list(ctx.group_id, ctx.tenant_id)
    keys
  end
end
