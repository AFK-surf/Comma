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
  use ExUnit.Case, async: false

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
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    handler_id = "im-ingress-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:salix, :operation, :stop],
      fn _event, measurements, metadata, _config ->
        if metadata[:component] == "salix_im" and metadata[:operation] == "im_ingress" do
          send(parent, {:im_ingress, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      case prev_s3 do
        nil -> Application.delete_env(:salix_store, :s3_backend)
        value -> Application.put_env(:salix_store, :s3_backend, value)
      end
    end)

    :ok
  end

  describe "ingress_outcome/1" do
    test "keeps attributed local failures inside the alert numerator" do
      assert ProviderHTTP.ingress_outcome({:error, :delivery_exploded}) == "error"
      assert ProviderHTTP.ingress_outcome({:error, :crashed}) == "error"
      assert ProviderHTTP.ingress_outcome({:error, :signing_secret_missing}) == "error"
      assert ProviderHTTP.ingress_outcome({:error, :provider_app_missing}) == "error"
      assert ProviderHTTP.ingress_outcome({:error, :provider_app_mismatch}) == "error"
      assert ProviderHTTP.ingress_outcome({:error, {:provider_app_store, :boom}}) == "error"
      assert ProviderHTTP.ingress_outcome({:error, :router_not_configured}) == "unroutable"
    end

    test "keeps caller-controlled pre-auth traffic out of the ratio entirely" do
      assert ProviderHTTP.ingress_outcome({:error, :not_found}) == "unattributed"
      assert ProviderHTTP.ingress_outcome({:error, :scan_capacity_exhausted}) == "scan_error"
      assert ProviderHTTP.ingress_outcome({:error, :invalid_signature}) == "rejected"
      assert ProviderHTTP.ingress_outcome({:error, :invalid_token}) == "rejected"
      assert ProviderHTTP.ingress_outcome({:error, :team_mismatch}) == "rejected"
    end

    test "keeps ordinary traffic in the denominator only" do
      assert ProviderHTTP.ingress_outcome({:ok, :accepted}) == "ok"
      assert ProviderHTTP.ingress_outcome({:ok, :duplicate}) == "ok"
      assert ProviderHTTP.ingress_outcome({:ok, %{"challenge" => "c"}}) == "ok"
      assert ProviderHTTP.ingress_outcome({:error, :ignored}) == "ignored"
      assert ProviderHTTP.ingress_outcome({:error, {:ignored, :no_bot_mention}}) == "ignored"

      assert ProviderHTTP.ingress_outcome({:error, {:ignored, :invalid_task_card_metadata_route}}) ==
               "ignored"
    end
  end

  describe "unknown app_id ingress" do
    for {name, handler, app_prefix, payload} <- [
          {"handle_slack_request/4", :handle_slack_request, "A-no-such-app-",
           Macro.escape(%{"event" => %{}})},
          {"handle_feishu_request/4", :handle_feishu_request, "cli-no-such-app-",
           Macro.escape(%{"header" => %{}})}
        ] do
      test "#{name} counts an unknown app_id as unattributed before any handler runs" do
        app_id = unquote(app_prefix) <> Integer.to_string(System.unique_integer([:positive]))

        assert {:error, :not_found} =
                 apply(ProviderHTTP, unquote(handler), [app_id, unquote(payload), [], ""])

        assert_receive {:im_ingress, %{duration: duration}, %{outcome: "unattributed"}}
        assert duration > 0
        refute_receive {:im_ingress, _measurements, _metadata}
      end
    end
  end

  describe "feishu verified attribution (public pre-auth traffic stays out of the ratio)" do
    setup do
      prev_store = Application.get_env(:salix_im, :provider_app_store_mod)
      prev_feishu = Application.get_env(:salix_im, :feishu_api_base_url)

      start_supervised!(FakeTenantAppStore)
      Application.put_env(:salix_im, :provider_app_store_mod, FakeTenantAppStore)

      port = start_bandit_retry!(fn p -> {Bandit, plug: MockFeishuAPI, port: p} end)
      Application.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")

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

    test "a hostile token shape on a known app_id classifies as rejected, never error",
         %{tenant: tenant, group_id: group_id} do
      app_id =
        create_feishu_connect!(tenant, group_id, %{
          "app_id" => "cli_hostile_#{System.unique_integer([:positive])}",
          "app_secret" => "s",
          "verification_token" => "vtok"
        })

      assert {:error, reason} =
               ProviderHTTP.handle_feishu_request(
                 app_id,
                 %{"type" => "url_verification", "challenge" => "c", "token" => %{"a" => 1}},
                 [],
                 ""
               )

      assert reason in [:invalid_token, :invalid_envelope]
      assert_receive {:im_ingress, _measurements, %{outcome: "rejected"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end

    test "absent verification material fails closed as an attributed local error",
         %{tenant: tenant, group_id: group_id} do
      app_id =
        create_feishu_connect!(tenant, group_id, %{
          "app_id" => "cli_blank_#{System.unique_integer([:positive])}",
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

    test "a hostile request_id cannot re-attribute a correct rejection via diagnostics",
         %{tenant: tenant, group_id: group_id} do
      app_id =
        create_feishu_connect!(tenant, group_id, %{
          "app_id" => "cli_diag_#{System.unique_integer([:positive])}",
          "app_secret" => "s",
          "verification_token" => "vtok"
        })

      # Wrong token -> correctly rejected; the map-shaped request_id used to
      # crash diagnostic construction afterwards, and the wrapper re-recorded
      # the request as an attributed error. Diagnostics may never throw.
      assert {:error, :invalid_token} =
               ProviderHTTP.handle_feishu_request(
                 app_id,
                 %{"token" => "wrong", "request_id" => %{"a" => 1}},
                 [],
                 ""
               )

      assert_receive {:im_ingress, _measurements, %{outcome: "rejected"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end

    test "hostile Feishu diagnostic fields are omitted without suppressing the diagnostic",
         %{tenant: tenant, group_id: group_id} do
      app_id =
        create_feishu_connect!(tenant, group_id, %{
          "app_id" => "cli_diag_shape_#{System.unique_integer([:positive])}",
          "app_secret" => "s",
          "verification_token" => "vtok"
        })

      previous_sink = Application.get_env(:salix_im, :diagnostic_sink)
      parent = self()

      Application.put_env(:salix_im, :diagnostic_sink, fn diagnostic ->
        send(parent, {:feishu_shape_diagnostic, diagnostic})
      end)

      on_exit(fn -> restore(:salix_im, :diagnostic_sink, previous_sink) end)

      assert {:error, :invalid_token} =
               ProviderHTTP.handle_feishu_request(
                 app_id,
                 %{
                   "token" => "wrong",
                   "request_id" => %{"nested" => "value"},
                   "type" => %{"nested" => "value"},
                   "uuid" => ["not", "a", "string"],
                   "event_id" => 42,
                   "header" => %{
                     "event_type" => %{"nested" => "value"},
                     "event_id" => ["not", "a", "string"]
                   },
                   "event" => %{
                     "type" => 42,
                     "message" => ["not", "a", "map"]
                   }
                 },
                 [],
                 ""
               )

      assert_receive {:feishu_shape_diagnostic, diagnostic}
      assert diagnostic.status == "rejected"
      assert diagnostic.reason_class == "invalid_token"

      refute Map.has_key?(diagnostic, :request_id)
      refute Map.has_key?(diagnostic, :provider_event_type)
      refute Map.has_key?(diagnostic, :provider_event_id)
      refute Map.has_key?(diagnostic, :message_id)
      refute Map.has_key?(diagnostic, :chat_id)
      refute Map.has_key?(diagnostic, :chat_type)
      refute Map.has_key?(diagnostic, :thread_id)

      assert_receive {:im_ingress, _measurements, %{outcome: "rejected"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end

    test "a matched verification token still attributes and answers the challenge",
         %{tenant: tenant, group_id: group_id} do
      app_id =
        create_feishu_connect!(tenant, group_id, %{
          "app_id" => "cli_ok_#{System.unique_integer([:positive])}",
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

    test "a non-binary app_id classifies as unattributed instead of crashing" do
      assert {:error, :not_found} =
               ProviderHTTP.handle_feishu_request(%{"$gt" => ""}, %{"header" => %{}}, [], "")

      assert {:error, :not_found} =
               ProviderHTTP.handle_slack_request(42, %{"event" => %{}}, [], "")

      assert_receive {:im_ingress, _measurements, %{outcome: "unattributed"}}
      assert_receive {:im_ingress, _measurements, %{outcome: "unattributed"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end
  end

  describe "crash accounting" do
    test "a crash inside the request still emits exactly one error event and re-raises" do
      # Point storage at a module that does not exist: connect resolution
      # raises for real, and the wrapper must emit exactly one error event
      # and re-raise so the HTTP layer still fails loudly.
      Application.put_env(:salix_store, :s3_backend, __MODULE__.NoSuchBackend)

      outcome =
        try do
          {:returned, ProviderHTTP.handle_slack_request("A-crash", %{"event" => %{}}, [], "")}
        rescue
          exception -> {:raised, exception.__struct__}
        after
          Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
        end

      assert {:raised, _module} = outcome
      assert_receive {:im_ingress, _measurements, %{outcome: "error"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end

    test "a dependency exit (:noproc) still emits exactly one error event and exits" do
      # Point storage at a GenServer that is never started: connect
      # resolution's first backend call exits with :noproc, which `rescue`
      # alone would let bypass telemetry.
      Application.put_env(:salix_store, :s3_backend, NoprocBackend)

      reason =
        try do
          catch_exit(ProviderHTTP.handle_slack_request("A-noproc", %{"event" => %{}}, [], ""))
        after
          Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
        end

      assert {:noproc, {GenServer, :call, _args}} = reason
      assert_receive {:im_ingress, _measurements, %{outcome: "error"}}
      refute_receive {:im_ingress, _measurements, _metadata}
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

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
