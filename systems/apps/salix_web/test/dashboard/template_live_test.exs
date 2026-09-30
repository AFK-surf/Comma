defmodule SalixWeb.Dashboard.TemplateLiveTest do
  @moduledoc "Template create, edit, and delete via LiveView."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  defmodule DiscoveryProvider do
    def init(opts), do: opts

    def call(conn, _) do
      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "data" =>
            [
              %{
                "id" => "anthropic/model-example",
                "display_name" => "Example Sonnet",
                "owned_by" => "anthropic"
              }
            ] ++
              for(
                number <- 2..12,
                do: %{
                  "id" => "anthropic/model-#{number}",
                  "display_name" => "Example Sonnet #{number}",
                  "owned_by" => "anthropic"
                }
              )
        })
      )
    end
  end

  test "global template discovers and saves the main model display information" do
    server =
      start_supervised!(
        {Bandit, plug: DiscoveryProvider, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, view, _} = live(authed_conn(), "/dash/templates/new")

    params = %{
      "name" => "Internal routing config",
      "base_url" => "http://127.0.0.1:#{port}/v1",
      "api_key" => "discovery-test-key"
    }

    view |> form("#template-form", params) |> render_change()
    view |> element("button[phx-click=discover]") |> render_click()
    assert render_async(view) =~ "Example Sonnet 12"
    assert has_element?(view, "button[phx-click=choose-model][phx-value-id='anthropic/model-12']")

    view
    |> element("button[phx-click=choose-model][phx-value-id='anthropic/model-12']")
    |> render_click()

    view |> form("#template-form") |> render_submit()
    {path, _} = assert_redirect(view)
    id = path |> String.split("/") |> List.last()
    assert {:ok, saved} = SalixAgent.Templates.get_public(id)
    assert saved["model"] == "anthropic/model-12"
    assert saved["model_display_name"] == "Example Sonnet 12"
    assert saved["model_icon"] == "anthropic"
    refute Jason.encode!(saved) =~ "discovery-test-key"

    assert {:error, :not_found} =
             SalixAgent.ModelDiscovery.discover(%{"template_id" => id}, tenant_id())

    {:ok, private} =
      SalixAgent.Templates.create_private(
        %{
          "name" => "Private discovery",
          "model" => saved["model"],
          "provider_config" => Map.take(params, ~w(base_url api_key))
        },
        tenant_id()
      )

    assert {:ok, discovered} =
             SalixAgent.ModelDiscovery.discover(
               %{"template_id" => private["template_id"]},
               tenant_id()
             )

    assert hd(discovered["data"])["name"] == "Example Sonnet"
    refute Jason.encode!(discovered) =~ "discovery-test-key"

    assert {:error, :not_found} =
             SalixAgent.ModelDiscovery.discover(
               %{"template_id" => private["template_id"]},
               SalixAgent.TestSupport.new_tenant_id()
             )

    {:ok, edit, html} = live(authed_conn(), path)
    refute html =~ "discovery-test-key"
    edit |> form("#template-form", %{"model" => "unknown-new-model"}) |> render_submit()
    assert_redirect(edit)
    assert {:ok, changed} = SalixAgent.Templates.get_public(id)
    assert changed["model_display_name"] == "unknown-new-model"
    assert changed["model_icon"] == nil
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Template dashboard test"})
    Process.put(:template_dashboard_tenant, tenant["tenant_id"])
    :ok
  end

  defp tenant_id, do: Process.get(:template_dashboard_tenant)

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  @tag :private_template
  test "an unavailable private catalog cannot silently switch an Agent to a global template" do
    {:ok, _} =
      SalixAgent.Templates.create(%{"name" => "Global alternative", "model" => "gpt-global"})

    {:ok, private} =
      SalixAgent.Templates.create_private(
        %{"name" => "Selected private", "model" => "gpt-private"},
        tenant_id()
      )

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Catalog failure"}, tenant_id())

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "Keep private",
          "group_id" => group["group_id"],
          "template_id" => private["template_id"]
        },
        tenant_id()
      )

    overflow =
      for number <- 1..100 do
        {:ok, template} =
          SalixAgent.Templates.create_private(
            %{"name" => "Overflow #{number}", "model" => "mock"},
            tenant_id()
          )

        template
      end

    assert {:error, :model_catalog_too_large} = SalixAgent.Templates.list_private(tenant_id())
    {:ok, view, _} = live(authed_conn(), "/dash/agents/#{agent["agent_id"]}")
    refute has_element?(view, "select[name=template_id] option")

    view
    |> form("form[phx-submit=save]", %{"name" => "Renamed private worker"})
    |> render_submit()

    assert {:ok, updated} = SalixAgent.Control.get(agent["agent_id"], tenant_id())
    assert updated["name"] == "Renamed private worker"
    assert updated["template_id"] == private["template_id"]

    {:ok, catalog, _} = live(authed_conn(), "/dash/templates")
    assert has_element?(catalog, "[role=alert]", "catalog is unavailable")
    catalog |> element("button", "Retry") |> render_click()
    assert has_element?(catalog, "[role=alert]")
    :ok = SalixAgent.Templates.delete_private(hd(overflow)["template_id"], tenant_id())
    catalog |> element("button", "Retry") |> render_click()
    refute has_element?(catalog, "[role=alert]")
    assert has_element?(catalog, "#private-templates", "Selected private")
  end

  @tag :private_template
  test "private template form creates, edits and deletes within the selected tenant" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Private dashboard"})
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Other dashboard"})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        "admin_authed" => true,
        "current_tenant" => tenant["tenant_id"]
      })

    other_conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        "admin_authed" => true,
        "current_tenant" => other["tenant_id"]
      })

    name = "Private UI #{System.unique_integer([:positive])}"
    {:ok, view, _} = live(conn, "/dash/templates/new?scope=tenant")
    assert has_element?(view, "#template-scope", "Private")
    refute has_element?(view, "input[name=private]")
    assert has_element?(view, "select[name=account_pool]")

    {:ok, edit, html} =
      view
      |> form("form[phx-submit=save]", %{
        "name" => name,
        "model" => "gpt-private",
        "api_key" => "private-ui-secret",
        "provider_config" => ~s({"timeout_ms":12345,"custom":{"keep":true}}),
        "request_headers" => ~s({"x-routing":"regional"})
      })
      |> render_submit()
      |> follow_redirect(conn)

    refute html =~ "private-ui-secret"
    assert html =~ name
    assert has_element?(edit, "#template-scope", "Private")
    {:ok, [template]} = SalixAgent.Templates.list_private(tenant["tenant_id"])
    id = template["template_id"]
    assert template["provider_config"]["api_key"] == "private-ui-secret"

    {:ok, _, html} =
      edit
      |> form("form[phx-submit=save]", %{"model" => "gpt-updated"})
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "gpt-updated"
    refute html =~ "private-ui-secret"
    {:ok, saved} = SalixAgent.Templates.get(id, tenant["tenant_id"])
    assert saved["provider_config"]["api_key"] == "private-ui-secret"
    assert saved["provider_config"]["custom"] == %{"keep" => true}
    assert saved["provider_config"]["timeout_ms"] == 12345
    assert saved["request_headers"] == %{"x-routing" => "regional"}
    {:ok, _, other_html} = live(other_conn, "/dash/templates")
    refute other_html =~ name

    assert {:error, {:live_redirect, %{to: "/dash/templates"}}} =
             live(other_conn, "/dash/templates/#{id}?scope=tenant")

    {:ok, index, html} = live(conn, "/dash/templates")
    assert html =~ name
    assert html =~ "Current tenant"
    refute render_click(index, "delete", %{"id" => id}) =~ name
    assert {:error, :not_found} = SalixAgent.Templates.get(id, tenant["tenant_id"])
  end

  @tag :private_template
  test "image credentials select Codex independently and can return to custom configuration" do
    conn = authed_conn()
    {:ok, view, _} = live(conn, "/dash/templates/new?scope=tenant")

    view
    |> form("#template-form", %{
      "name" => "Image subscription UI",
      "model" => "claude-opus-4-8",
      "image_config" => "{unfinished",
      "image_account_pool" => "codex"
    })
    |> render_change()

    assert has_element?(view, "input[type=hidden][name=image_config]")
    refute has_element?(view, "textarea[name=image_config]")
    {:ok, edit, _} = view |> form("#template-form") |> render_submit() |> follow_redirect(conn)
    {:ok, [template]} = SalixAgent.Templates.list_private(tenant_id())

    assert template["image_config"] == %{
             "provider" => "openai",
             "model" => "gpt-image-2",
             "provider_config" => %{"account_pool" => "codex"}
           }

    assert template["model"] == "claude-opus-4-8"
    refute Map.has_key?(template["provider_config"], "account_pool")
    assert has_element?(edit, "select[name=image_account_pool] option[value=codex][selected]")
    edit |> form("#template-form", %{"image_account_pool" => ""}) |> render_change()
    assert has_element?(edit, "textarea[name=image_config]")

    {:ok, _, _} =
      edit
      |> form("#template-form", %{
        "image_config" =>
          ~s({"provider":"openai","model":"gpt-image-2","base_url":"https://images.example.test/v1","api_key":"custom-key","provider_config":{"account_pool":"codex"}})
      })
      |> render_submit()
      |> follow_redirect(conn)

    {:ok, saved} = SalixAgent.Templates.get(template["template_id"], tenant_id())
    assert saved["image_config"]["base_url"] == "https://images.example.test/v1"
    assert saved["image_config"]["api_key"] == "custom-key"
    refute Map.has_key?(saved["image_config"]["provider_config"], "account_pool")
  end

  test "create a template via the new form" do
    {:ok, view, _html} = live(authed_conn(), "/dash/templates/new")

    assert has_element?(view, "#template-scope", "Global")
    refute has_element?(view, "input[name=private]")
    refute has_element?(view, "select[name=account_pool]")
    refute has_element?(view, "select[name=image_account_pool]")

    params = %{
      "name" => "CI Template",
      "model" => "claude-opus-4-8",
      "max_tokens" => "65536",
      "context_tokens" => "0",
      "provider_config" => ~s({"kind":"anthropic"}),
      "request_headers" => "{}",
      "image_config" => "{}",
      "video_config" => "{}",
      "vision_describer_config" => "{}",
      "analyze_config" => "{}"
    }

    {:ok, _edit_view, html} =
      view
      |> form("form[phx-submit=save]", params)
      |> render_submit()
      |> follow_redirect(authed_conn())

    assert html =~ "CI Template"
    assert html =~ "claude-opus-4-8"
  end

  test "rejects invalid JSON in a config field" do
    {:ok, view, _html} = live(authed_conn(), "/dash/templates/new")

    view
    |> form("form[phx-submit=save]", %{
      "name" => "Bad",
      "model" => "m",
      "image_config" => "{nope"
    })
    |> render_submit()

    assert has_element?(view, "#media-options", "Enter a valid JSON object.")
    assert has_element?(view, "textarea[name=image_config]", "{nope")
  end

  test "index deletes an unused template without reading nested tenant resources" do
    {:ok, t} = SalixAgent.Templates.create(%{"name" => "DelMe", "model" => "m"})
    nested_key = "ctl/tenants/#{tenant_id()}/devices/device-for-delete-test.json"
    {:ok, _} = SalixStore.S3.put(nested_key, Jason.encode!(%{"name" => "Device"}))
    {:ok, view, html} = live(authed_conn(), "/dash/templates")
    assert html =~ "DelMe"
    assert has_element?(view, "a[href='/dash/templates/new']", "Add model configuration")

    SalixStore.S3.Fake.set_fault(
      {:fail, 503, :get, SalixStore.Keys.ctl_tenant("device-for-delete-test")}
    )

    on_exit(fn -> SalixStore.S3.Fake.set_fault(nil) end)

    html = render_click(view, "delete", %{"id" => t["template_id"]})
    assert html =~ "Template deleted."
    refute html =~ "DelMe"
    assert {:error, :not_found} = SalixAgent.Templates.get(t["template_id"])
    assert {:ok, _} = SalixStore.S3.get(nested_key)
  end
end
