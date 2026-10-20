defmodule SalixWeb.LocalOAuthMockTest do
  use SystemsClock.Case, async: false

  test "runtime toggle installs and restores the local Composio provider boundary" do
    keys = [
      {:salix_web, :local_oauth_mock},
      {:salix_web, :local_recommendation_mock},
      {:salix_web, :public_base_url},
      {:salix_web, :composio_client_mod},
      {:salix_web, :composio_settings_mod},
      {:salix_agent, :composio_client_mod},
      {:salix_agent, :composio_store_mod},
      {:salix_store, :oauth_endpoint_overrides},
      {:salix_mcp, :remote_target_overrides},
      {:salix_mcp, :private_http_target_allowlist}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, SystemsRuntime.get_env(app, key)} end)

    SystemsRuntime.put_env(:salix_web, :local_oauth_mock, false)
    SystemsRuntime.put_env(:salix_web, :local_recommendation_mock, false)
    SystemsRuntime.put_env(:salix_web, :public_base_url, "http://127.0.0.1:4000")
    SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, %{"custom" => %{}})
    SystemsRuntime.put_env(:salix_mcp, :remote_target_overrides, %{"custom" => "https://x"})
    SystemsRuntime.put_env(:salix_mcp, :private_http_target_allowlist, ["https://x"])
    SystemsRuntime.put_env(:salix_web, :composio_client_mod, OriginalWebClient)
    SystemsRuntime.put_env(:salix_web, :composio_settings_mod, OriginalWebSettings)
    SystemsRuntime.put_env(:salix_agent, :composio_client_mod, OriginalAgentClient)
    SystemsRuntime.put_env(:salix_agent, :composio_store_mod, OriginalAgentStore)

    on_exit(fn ->
      _ = SalixWeb.LocalOAuthMock.set_enabled(false)
      Enum.each(previous, fn {{app, key}, value} -> restore_env(app, key, value) end)
    end)

    assert %{available: true, enabled: false} = SalixWeb.LocalOAuthMock.status()

    assert {:ok, %{available: true, enabled: true}} =
             SalixWeb.LocalOAuthMock.set_enabled(true)

    assert get_in(
             SystemsRuntime.fetch_env!(:salix_store, :oauth_endpoint_overrides),
             ["github", "authorize_url"]
           ) == "http://127.0.0.1:4000/v1/local-oauth/github/authorize"

    assert SystemsRuntime.fetch_env!(:salix_mcp, :remote_target_overrides)["remote:notion"] ==
             "http://127.0.0.1:4000/v1/local-oauth/mcp/resource"

    assert SystemsRuntime.fetch_env!(:salix_web, :composio_client_mod) ==
             SalixWeb.LocalComposioMock

    assert SystemsRuntime.fetch_env!(:salix_web, :composio_settings_mod) ==
             SalixWeb.LocalComposioMock

    assert SystemsRuntime.fetch_env!(:salix_agent, :composio_client_mod) ==
             SalixWeb.LocalComposioMock

    assert {:ok, accounts} =
             SalixWeb.LocalComposioMock.list_connected_accounts(%{}, "group-local")

    assert Enum.any?(accounts, &(get_in(&1, ["toolkit", "slug"]) == "linear"))

    assert {:ok, %{available: true, enabled: false}} =
             SalixWeb.LocalOAuthMock.set_enabled(false)

    assert SystemsRuntime.fetch_env!(:salix_store, :oauth_endpoint_overrides) == %{
             "custom" => %{}
           }

    assert SystemsRuntime.fetch_env!(:salix_mcp, :remote_target_overrides) == %{
             "custom" => "https://x"
           }

    assert SystemsRuntime.fetch_env!(:salix_mcp, :private_http_target_allowlist) == ["https://x"]

    assert SystemsRuntime.fetch_env!(:salix_web, :composio_client_mod) == OriginalWebClient
    assert SystemsRuntime.fetch_env!(:salix_web, :composio_settings_mod) == OriginalWebSettings
    assert SystemsRuntime.fetch_env!(:salix_agent, :composio_client_mod) == OriginalAgentClient
    assert SystemsRuntime.fetch_env!(:salix_agent, :composio_store_mod) == OriginalAgentStore
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
