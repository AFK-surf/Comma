defmodule SalixIM.ProviderHTTPIngressTelemetryTest do
  @moduledoc """
  The `im_ingress` operation metric is the production IM ingress alert's
  source (docs/observability.md). The ratio is computed
  over ATTRIBUTED traffic only: numerator `error|unroutable|timeout|unavailable`,
  denominator additionally `ok|ignored`; the caller-controlled pre-auth
  classes (`unattributed`, `rejected`, `scan_error`) stay out of both sides.
  The classification, the verified-attribution boundary, and the emission
  boundary (exactly one event per inbound request, including
  connect-resolution failures, crashes, and BEAM exits) are load-bearing.
  """
  use SystemsClock.Case, async: false

  alias SalixIM.ProviderHTTP

  defmodule NoprocBackend do
    @moduledoc false
    # Every storage touch lands on a GenServer that is never started, so the
    # first backend call exits with {:noproc, {GenServer, :call, _}} — the
    # reviewer-reproduced dependency-exit shape that `rescue` cannot catch.
    def get(key, opts \\ []), do: GenServer.call(__MODULE__, {:get, key, opts})
    def list(prefix, opts \\ []), do: GenServer.call(__MODULE__, {:list, prefix, opts})
  end

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

  defmodule MockFeishuAPI do
    @moduledoc false
    import Plug.Conn

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
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    handler_id = "im-ingress-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Telemetry.attach(
      handler_id,
      [:salix, :operation, :stop],
      fn _event, measurements, metadata, _config ->
        if metadata[:component] == "salix_im" and metadata[:operation] == "im_ingress" do
          SystemsRuntime.Proc.send(parent, {:im_ingress, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn ->
      SystemsRuntime.Telemetry.detach(handler_id)

      case prev_s3 do
        nil -> SystemsRuntime.delete_env(:salix_store, :s3_backend)
        value -> SystemsRuntime.put_env(:salix_store, :s3_backend, value)
      end
    end)

    :ok
  end

  describe "ingress_outcome/1" do
  end

  describe "unknown app_id ingress" do
    for {name, handler, app_prefix, payload} <- [
          {"handle_slack_request/4", :handle_slack_request, "A-no-such-app-",
           Macro.escape(%{"event" => %{}})},
          {"handle_feishu_request/4", :handle_feishu_request, "cli-no-such-app-",
           Macro.escape(%{"header" => %{}})}
        ] do
    end
  end

  describe "feishu verified attribution (public pre-auth traffic stays out of the ratio)" do
    setup do
      prev_store = SystemsRuntime.get_env(:salix_im, :provider_app_store_mod)
      prev_feishu = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)

      start_supervised!(FakeTenantAppStore)
      SystemsRuntime.put_env(:salix_im, :provider_app_store_mod, FakeTenantAppStore)

      port = start_bandit_retry!(fn p -> {Bandit, plug: MockFeishuAPI, port: p} end)

      SystemsRuntime.put_env(
        :salix_im,
        :feishu_api_base_url,
        "http://127.0.0.1:#{port}/open-apis"
      )

      on_exit(fn ->
        restore(:salix_im, :provider_app_store_mod, prev_store)
        restore(:salix_im, :feishu_api_base_url, prev_feishu)
      end)

      tenant = SalixAgent.TestSupport.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant)
      SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Ingress"})

      {:ok, tenant: tenant, group_id: group_id}
    end

    defp create_feishu_connect!(tenant, group_id, app) do
      app_id = app["app_id"]
      FakeTenantAppStore.put(tenant, app)

      {:ok, _connect} =
        SalixIM.ProviderConnects.create_feishu_im_connect(tenant, group_id, %{
          "app_id" => app_id,
          "app_name" => "Ingress"
        })

      app_id
    end

    test "absent verification material fails closed as an attributed local error",
         %{tenant: tenant, group_id: group_id} do
      app_id =
        create_feishu_connect!(tenant, group_id, %{
          "app_id" => "cli_blank_#{SystemsRuntime.Proc.unique_integer([:positive])}",
          "app_secret" => "s"
        })

      assert {:error, :verification_material_missing} =
               ProviderHTTP.handle_feishu_request(
                 app_id,
                 %{"type" => "url_verification", "challenge" => "c"},
                 [],
                 ""
               )

      assert_receive {:im_ingress, _measurements, %{outcome: "error"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end

    test "a matched verification token still attributes and answers the challenge",
         %{tenant: tenant, group_id: group_id} do
      app_id =
        create_feishu_connect!(tenant, group_id, %{
          "app_id" => "cli_ok_#{SystemsRuntime.Proc.unique_integer([:positive])}",
          "app_secret" => "s",
          "verification_token" => "vtok"
        })

      assert {:ok, %{"challenge" => "c"}} =
               ProviderHTTP.handle_feishu_request(
                 app_id,
                 %{"type" => "url_verification", "challenge" => "c", "token" => "vtok"},
                 [],
                 ""
               )

      assert_receive {:im_ingress, _measurements, %{outcome: "ok"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end
  end

  describe "crash accounting" do
    test "a crash inside the request still emits exactly one error event and re-raises" do
      # Point storage at a module that does not exist: connect resolution
      # raises for real, and the wrapper must emit exactly one error event
      # and re-raise so the HTTP layer still fails loudly.
      SystemsRuntime.put_env(:salix_store, :s3_backend, __MODULE__.NoSuchBackend)

      outcome =
        try do
          {:returned, ProviderHTTP.handle_slack_request("A-crash", %{"event" => %{}}, [], "")}
        rescue
          exception -> {:raised, exception.__struct__}
        after
          SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
        end

      assert {:raised, _module} = outcome
      assert_receive {:im_ingress, _measurements, %{outcome: "error"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20_000)

      case start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end
end
