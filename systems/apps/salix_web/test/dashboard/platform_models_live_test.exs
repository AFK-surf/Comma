defmodule SalixWeb.Dashboard.PlatformModelsLiveTest do
  @moduledoc "The operator page for the platform model and its tiers."
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SalixWeb.DashboardEndpoint

  alias SalixAgent.{AccountPool, PlatformModels}

  setup do
    platform = AccountPool.platform_tenant()

    on_exit(fn ->
      SalixStore.S3.delete(SalixStore.Keys.ctl_system_platform_models())

      SalixAgent.SubscriptionStore.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [
        platform
      ])
    end)

    {:ok, profile} =
      AccountPool.create(platform, %{
        "credential_kind" => "provider_api_key",
        "source" => "openrouter",
        "api_key" => "sk-or-v1-platform-0123456789"
      })

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Platform model UI"})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        "admin_authed" => true,
        "current_tenant" => tenant["tenant_id"]
      })

    {:ok, conn: conn, profile: profile}
  end

  test "an operator sets the Worker tier and the name members see", %{
    conn: conn,
    profile: profile
  } do
    {:ok, view, _html} = live(conn, "/dash/platform-model")

    view
    |> form("#platform-models-form", %{
      "name" => "Comma",
      "tiers" => %{
        "worker" => %{
          "profile_id" => profile["id"],
          "model" => "openai/gpt-6-sol",
          "reasoning_effort" => "high",
          "context_tokens" => "200000",
          "images" => "true"
        }
      }
    })
    |> render_submit()

    assert render(view) =~ "Platform model saved."

    assert {:ok,
            %{
              "name" => "Comma",
              "tiers" =>
                %{
                  "worker" => %{
                    "profile_id" => id,
                    "model" => "openai/gpt-6-sol",
                    "context_tokens" => 200_000,
                    "images" => true
                  }
                } = tiers
            }} = PlatformModels.get()

    assert id == profile["id"]
    refute Map.has_key?(tiers, "router")

    # A tier needs a model id.
    view
    |> form("#platform-models-form", %{
      "tiers" => %{"router" => %{"profile_id" => profile["id"], "model" => ""}}
    })
    |> render_submit()

    assert render(view) =~ "Could not save"
  end
end
