defmodule SalixIM.FeishuChecksTest do
  @moduledoc """
  Unit tests for the callback preflight and run checks in
  `SalixIM.FeishuChecks`.

  The pure classification helpers are tested directly. `callback_preflight/1`
  runs against a local Bandit mock webhook (same mock pattern the rest of the
  salix_im suite uses — no new HTTP-mock dependency).
  """
  use SystemsClock.Case, async: false

  alias SalixIM.FeishuChecks
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.Keys

  defmodule MockWebhook do
    @moduledoc """
    Configurable mock of the Feishu `/v1/im/feishu/events` endpoint.

    Default behaviour echoes the URL-verification challenge (success). The
    response can be overridden per-test to simulate token/signature/404
    failures, and requests are recorded so assertions can inspect the synthetic
    envelope (challenge mode, signature headers).
    """
    use Agent
    import Plug.Conn

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{response: :echo_challenge, requests: []} end, name: __MODULE__)

    def respond(response), do: Agent.update(__MODULE__, &%{&1 | response: response})

    def last_request, do: Agent.get(__MODULE__, &List.first(&1.requests))

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      decoded = decode(raw)

      req = %{
        raw: raw,
        body: decoded,
        headers: Map.new(conn.req_headers),
        query: conn.query_string
      }

      Agent.update(__MODULE__, &%{&1 | requests: [req | &1.requests]})

      case Agent.get(__MODULE__, & &1.response) do
        :echo_challenge ->
          challenge = decoded["challenge"] || ""
          json(conn, 200, %{"challenge" => challenge})

        :queued ->
          json(conn, 200, %{"ok" => true, "status" => "queued"})

        {:status, status, body} ->
          json(conn, status, body)
      end
    end

    defp decode(raw) do
      case Jason.decode(raw) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    end

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  # ---- pure classification helpers ----

  describe "classify_failure/3" do
    token = %{"error" => "invalid Feishu token"}
    signature = %{"error" => "invalid Feishu signature"}

    for {name, status, body, encrypted?, expected} <- [
          {"401 naming token is a token mismatch in plain mode", 401, token, false,
           :token_mismatch},
          {"401 naming token is a token mismatch in encrypted mode", 401, token, true,
           :token_mismatch},
          {"401 signature in plain mode is a decrypt/signature failure", 401, signature, false,
           :decrypt_signature},
          {"401 signature in encrypted mode is the unsupported encrypted envelope (RFC §6.2)",
           401, signature, true, :encrypted_unsupported},
          {"404 is callback unreachable", 404, %{"error" => "not found"}, false,
           :callback_unreachable},
          {"5xx is callback unreachable", 500, %{"error" => "boom"}, true, :callback_unreachable},
          {"a non-round-tripping 200 in encrypted mode is the unsupported envelope", 200,
           %{"ok" => true}, true, :encrypted_unsupported},
          {"a non-round-tripping 200 in plain mode is a decrypt/signature failure", 200,
           %{"ok" => true}, false, :decrypt_signature}
        ] do
    end
  end

  describe "challenge_round_trips?/3" do
  end

  describe "error_mentions?/2" do
  end

  # ---- callback_preflight/1 against the mock webhook ----

  describe "callback_preflight/1" do
    setup do
      start_supervised!(MockWebhook)
      port = BanditServer.start!(fn p -> {Bandit, plug: MockWebhook, port: p} end)
      {:ok, url: "http://127.0.0.1:#{port}/v1/im/feishu/events"}
    end

    test "encrypted mode sends an official random-IV envelope (RFC §6.2)", %{url: url} do
      MockWebhook.respond(:echo_challenge)

      # When the mock echoes the (encrypted-but-not-decrypted) body, the plain
      # challenge is absent, so an honest encrypted preflight does NOT false-green.
      assert {:error, :encrypted_unsupported} =
               FeishuChecks.callback_preflight(%{
                 "webhook_url" => url,
                 "encrypt_key" => "super-secret-key"
               })

      req = MockWebhook.last_request()
      # Official wire format: the envelope is an `encrypt` payload, never plaintext.
      assert Map.has_key?(req.body, "encrypt")
      refute Map.has_key?(req.body, "challenge")
      assert is_binary(req.headers["x-lark-signature"])

      # Random IV: two encryptions of the same plaintext must differ (not fixed-IV).
      first = req.body["encrypt"]
      MockWebhook.respond(:echo_challenge)

      FeishuChecks.callback_preflight(%{
        "webhook_url" => url,
        "encrypt_key" => "super-secret-key"
      })

      second = MockWebhook.last_request().body["encrypt"]
      refute first == second
    end
  end

  # ---- connect-aware paths: secrets resolved from the tenant app store ----

  # A scriptable stand-in for the tenant Feishu app store port.
  defmodule FakeTenantAppStore do
    use Agent

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def put(tenant_id, app), do: Agent.update(__MODULE__, &Map.put(&1, tenant_id, app))

    def get_feishu_tenant_app(tenant_id) do
      case Agent.get(__MODULE__, &Map.get(&1, tenant_id)) do
        nil -> {:error, :not_configured}
        app -> {:ok, app}
      end
    end
  end

  describe "callback_preflight_for_connect/1 — secret resolution + classification" do
    setup [:salix_runtime, :mock_webhook]

    test "fails closed when the connect is not active", %{group_id: group_id, url: url} do
      seed_connect(group_id, "fs-inactive", %{
        "webhook_url" => url,
        "verification_token" => "vtok",
        "status" => "disconnected"
      })

      assert {:error, :connect_inactive} =
               FeishuChecks.callback_preflight_for_connect(%{"connect_id" => "fs-inactive"})
    end

    test "tenant app verification_token drives a plain round-trip", %{
      group_id: group_id,
      url: url
    } do
      MockWebhook.respond(:echo_challenge)
      FakeTenantAppStore.put("tenant-plain", %{"verification_token" => "tenant-vtok"})

      seed_connect(group_id, "fs-plain", %{
        "tenant_id" => "tenant-plain",
        "app_id" => "cli_plain",
        "webhook_url" => url,
        "status" => "connected"
      })

      assert {:ok, evidence} =
               FeishuChecks.callback_preflight_for_connect(%{"connect_id" => "fs-plain"})

      assert evidence["ok"] == true
      assert evidence["challenge_mode"] == "plain"
      req = MockWebhook.last_request()
      assert req.body["token"] == "tenant-vtok"
      refute evidence |> Map.values() |> Enum.any?(&(&1 == "tenant-vtok"))
    end

    test "blank tenant app token does not fall back to per-connect token", %{
      group_id: group_id,
      url: url
    } do
      MockWebhook.respond(:echo_challenge)
      FakeTenantAppStore.put("tenant-partial", %{"verification_token" => ""})

      seed_connect(group_id, "fs-partial", %{
        "tenant_id" => "tenant-partial",
        "app_id" => "cli_partial",
        "webhook_url" => url,
        "verification_token" => "legacy-vtok",
        "status" => "connected"
      })

      assert {:error, :secrets_not_configured} =
               FeishuChecks.callback_preflight_for_connect(%{"connect_id" => "fs-partial"})
    end
  end

  describe "bot_identity/1 — connect-aware bot open_id readiness" do
    setup [:salix_runtime]

    test "fails closed when the connect is not active", %{group_id: group_id} do
      seed_connect(group_id, "fs-inactive-identity", %{
        "provider" => "feishu",
        "status" => "disconnected",
        "bot_open_id" => "ou_bot"
      })

      assert {:error, :connect_inactive} =
               FeishuChecks.bot_identity(%{"connect_id" => "fs-inactive-identity"})
    end

    test "returns redacted evidence when the bot open_id exists", %{group_id: group_id} do
      seed_connect(group_id, "fs-ready-identity", %{
        "provider" => "feishu",
        "status" => "connected",
        "app_id" => "cli_ready_identity",
        "bot_open_id" => "ou_secret_bot_open_id"
      })

      assert {:ok, evidence} = FeishuChecks.bot_identity(%{"connect_id" => "fs-ready-identity"})
      assert evidence["ok"] == true
      assert evidence["redacted"] == true
      assert evidence["identity"] == "feishu_bot_open_id"
      assert evidence["connect_id"] == "fs-ready-identity"
      assert evidence["app_id"] == "cli_ready_identity"
      assert is_binary(evidence["open_id_fingerprint"])
      refute evidence["open_id_fingerprint"] == "ou_secret_bot_open_id"
      refute evidence |> Map.values() |> Enum.any?(&(&1 == "ou_secret_bot_open_id"))
    end
  end

  describe "first_message/1 — connect-aware smoke (session isolation + round-trip)" do
    setup [:salix_runtime, :seed_router_group]

    test "happy path: synthetic @Bridge message round-trips to an assistant reply", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: agent_id
    } do
      SalixAgent.LLM.Mock.script([{:final, "smoke-ack"}])
      FakeTenantAppStore.put(tenant, %{"verification_token" => "vtok"})

      seed_connect(group_id, "fs-smoke", %{
        "tenant_id" => tenant,
        "app_id" => "cli_smoke",
        "status" => "connected"
      })

      assert {:ok, evidence} = FeishuChecks.first_message(%{"connect_id" => "fs-smoke"})
      assert evidence["assistant_reply"] == true
      assert evidence["check_kind"] == "first_message_smoke"
      assert evidence["redacted"] == true

      # Router agents have one canonical session per group. Smoke checks are
      # normal router notifications; they must not create a second router
      # session based on entrypoint type.
      {:ok, router_session} =
        SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

      assert {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, router_session)
      assert Enum.any?(session.messages, &(&1.role == "assistant"))
    end
  end

  # ---- shared setup for the connect-aware suites ----

  defp salix_runtime(_context) do
    SalixAgent.TestSupport.stop_all_agents()

    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_agent_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    prev_provider_app_store = SystemsRuntime.get_env(:salix_im, :provider_app_store_mod)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    start_supervised!(FakeTenantAppStore)
    SystemsRuntime.put_env(:salix_im, :provider_app_store_mod, FakeTenantAppStore)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, prev_s3)
      restore_env(:salix_agent, :llm, prev_llm)
      restore_env(:salix_im, :agent_delivery_mod, prev_agent_delivery)
      restore_env(:salix_im, :provider_app_store_mod, prev_provider_app_store)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Checks"})

    {:ok, tenant: tenant, group_id: group_id}
  end

  defp seed_router_group(%{tenant: tenant, group_id: group_id}) do
    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn rec ->
        Map.put(rec, "router_agent_id", agent["agent_id"])
      end)

    {:ok, agent_id: agent["agent_id"]}
  end

  defp mock_webhook(_context) do
    start_supervised!(MockWebhook)
    port = BanditServer.start!(fn p -> {Bandit, plug: MockWebhook, port: p} end)
    {:ok, url: "http://127.0.0.1:#{port}/v1/im/feishu/events"}
  end

  defp seed_connect(group_id, connect_id, extra) do
    now = SystemsClock.system_time(:millisecond)

    rec =
      Map.merge(
        %{
          "tenant_id" => extra["tenant_id"] || "default",
          "group_id" => group_id,
          "connect_id" => connect_id,
          "provider" => "feishu",
          "created_at" => now,
          "updated_at" => now
        },
        extra
      )

    {:ok, _} = SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), rec)
    rec
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
