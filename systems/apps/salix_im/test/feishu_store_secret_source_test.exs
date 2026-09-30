defmodule SalixIM.FeishuStoreSecretSourceTest do
  @moduledoc """
  `SalixIM.ProviderConnects.create_feishu_im_connect/3` secret sourcing:

    * connect create carries only app identity;
    * bot secrets are sourced from the tenant Feishu-app store keyed by tenant_id;
    * connect records do not store app_secret / verification_token / encrypt_key;
    * missing tenant app secret fails closed with a clear `{:bad_request, _}`.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias SalixStore.Keys

  # Stand-in for the tenant Feishu app store port.
  defmodule FakeTenantAppStore do
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def put(tenant_id, app), do: Agent.update(__MODULE__, &Map.put(&1, tenant_id, app))

    def get_feishu_tenant_app(tenant_id) do
      case Agent.get(__MODULE__, &Map.get(&1, tenant_id)) do
        nil -> {:error, :not_configured}
        app -> {:ok, app}
      end
    end
  end

  # Minimal Feishu open-apis stub: tenant_access_token validation succeeds for any
  # app_id/app_secret pair, so a successful create proves the secret resolved.
  defmodule MockFeishuAPI do
    @moduledoc false
    def init(opts), do: opts

    def call(%{request_path: "/open-apis/auth/v3/tenant_access_token/internal"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"code" => 0, "tenant_access_token" => "test-token"}))
    end

    def call(%{request_path: "/open-apis/bot/v3/info"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"code" => 0, "bot" => %{"open_id" => "ou_test_bot"}}))
    end
  end

  setup do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_store = Application.get_env(:salix_im, :provider_app_store_mod)
    prev_feishu = Application.get_env(:salix_im, :feishu_api_base_url)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    start_supervised!(FakeTenantAppStore)
    Application.put_env(:salix_im, :provider_app_store_mod, FakeTenantAppStore)

    port = start_bandit_retry!(fn p -> {Bandit, plug: MockFeishuAPI, port: p} end)
    Application.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")

    on_exit(fn ->
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_im, :provider_app_store_mod, prev_store)
      restore(:salix_im, :feishu_api_base_url, prev_feishu)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Secrets"})

    {:ok, tenant: tenant, group_id: group_id}
  end

  test "binding-driven create sources the bot secret from the tenant store", %{
    tenant: tenant,
    group_id: group_id
  } do
    FakeTenantAppStore.put(tenant, %{
      "app_id" => "cli_binding",
      "app_secret" => "tenant-secret",
      "verification_token" => "tenant-vtok",
      "encrypt_key" => "tenant-ekey"
    })

    # attrs carries ONLY app_id (+ a display name) — no secrets.
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_feishu_im_connect(tenant, group_id, %{
               "app_id" => "cli_binding",
               "app_name" => "Bridge"
             })

    assert connect["app_secret_configured"] == true
    assert connect["verification_token_configured"] == true
    assert connect["encrypt_key_configured"] == true

    {:ok, rec} = SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect["connect_id"]))
    refute Map.has_key?(rec, "app_secret")
    refute Map.has_key?(rec, "verification_token")
    refute Map.has_key?(rec, "encrypt_key")
  end

  test "explicit secret attrs are rejected at the connect boundary", %{
    tenant: tenant,
    group_id: group_id
  } do
    FakeTenantAppStore.put(tenant, %{
      "app_id" => "cli_explicit",
      "app_secret" => "tenant-secret",
      "verification_token" => "tenant-vtok"
    })

    assert {:error, {:bad_request, message}} =
             SalixIM.ProviderConnects.create_feishu_im_connect(tenant, group_id, %{
               "app_id" => "cli_explicit",
               "app_secret" => "explicit-secret",
               "verification_token" => "explicit-vtok"
             })

    assert message =~ "tenant Feishu app store"
  end

  test "fails closed with a clear error when neither attrs nor the tenant store has a secret", %{
    tenant: tenant,
    group_id: group_id
  } do
    # No tenant app configured for this tenant, and no secret in attrs.
    assert {:error, {:bad_request, message}} =
             SalixIM.ProviderConnects.create_feishu_im_connect(tenant, group_id, %{
               "app_id" => "cli_missing"
             })

    assert message =~ "not configured"
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # Bind Bandit on a random port, retrying on collisions across suites.
  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end
end
