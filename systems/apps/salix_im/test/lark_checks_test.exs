defmodule SalixIM.LarkChecksTest do
  @moduledoc """
  `SalixIM.LarkChecks` against a local request URL. The mock answers a
  callback with `SalixIM.LarkInbound`, so the envelope of the preflight is
  verified as a callback from Lark is.
  """
  use SystemsClock.Case, async: false

  alias SalixIM.LarkChecks
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.Keys

  defmodule RequestURL do
    @moduledoc """
    The Lark request URL of this deployment. It verifies a callback against
    the material it was given, which a test can make differ from the
    connect's.
    """
    use Agent
    import Plug.Conn

    def start_link(_opts \\ []),
      do: Agent.start_link(fn -> %{material: %{}, requests: []} end, name: __MODULE__)

    def verify_with(material), do: Agent.update(__MODULE__, &%{&1 | material: material})
    def last_request, do: Agent.get(__MODULE__, &List.first(&1.requests))

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      envelope = Jason.decode!(raw)
      request = %{body: envelope, headers: Map.new(conn.req_headers), query: conn.query_string}
      Agent.update(__MODULE__, &%{&1 | requests: [request | &1.requests]})

      connect =
        Map.merge(
          %{"connect_id" => "request-url", "provider" => "lark"},
          Agent.get(__MODULE__, & &1.material)
        )

      # The answers of `POST /v1/im/lark/events`.
      {status, body} =
        case SalixIM.LarkInbound.handle_event(connect, envelope, conn.req_headers, raw) do
          {:ok, body} -> {200, body}
          {:error, :invalid_token} -> {401, %{"error" => "invalid Lark token"}}
          {:error, _reason} -> {401, %{"error" => "invalid Lark signature"}}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  describe "classify_failure/3" do
    test "names the cause of a response without the challenge" do
      assert LarkChecks.classify_failure(401, %{"error" => "invalid Lark token"}, false) ==
               :token_mismatch

      assert LarkChecks.classify_failure(401, %{"error" => "invalid Lark signature"}, true) ==
               :decrypt_signature

      assert LarkChecks.classify_failure(404, %{"error" => "Lark connect not found"}, false) ==
               :callback_unreachable

      assert LarkChecks.classify_failure(503, "upstream down", true) == :callback_unreachable
      assert LarkChecks.classify_failure(200, %{"ok" => true}, false) == :unexpected_response
    end
  end

  describe "callback_preflight_for_connect/1" do
    setup [:salix_store, :request_url]

    test "an Encrypt Key gives an encrypted, signed envelope that the request URL accepts", %{
      group_id: group_id,
      url: url
    } do
      RequestURL.verify_with(%{"encrypt_key" => "lark-encrypt-key"})

      seed_connect(group_id, "lark-encrypted", %{
        "app_id" => "cli_lark",
        "webhook_url" => url <> "?app_id=cli_lark",
        "verification_token" => "lark-token",
        "encrypt_key" => "lark-encrypt-key"
      })

      assert {:ok, evidence} =
               LarkChecks.callback_preflight_for_connect(%{"connect_id" => "lark-encrypted"})

      assert evidence["ok"] == true
      assert evidence["challenge_mode"] == "encrypted"
      refute inspect(evidence) =~ "lark-encrypt-key"
      refute inspect(evidence) =~ "lark-token"

      request = RequestURL.last_request()
      assert request.query == "app_id=cli_lark"
      assert Map.keys(request.body) == ["encrypt"]
      assert is_binary(request.headers["x-lark-signature"])

      # The IV is random: the same connect never sends the same envelope twice.
      assert {:ok, _evidence} =
               LarkChecks.callback_preflight_for_connect(%{"connect_id" => "lark-encrypted"})

      refute RequestURL.last_request().body["encrypt"] == request.body["encrypt"]
    end

    test "a Verification Token alone gives a plain envelope", %{group_id: group_id, url: url} do
      RequestURL.verify_with(%{"verification_token" => "lark-token"})

      seed_connect(group_id, "lark-plain", %{
        "app_id" => "cli_plain",
        "webhook_url" => url <> "?app_id=cli_plain",
        "verification_token" => "lark-token"
      })

      assert {:ok, %{"challenge_mode" => "plain", "http_status" => 200}} =
               LarkChecks.callback_preflight_for_connect(%{"connect_id" => "lark-plain"})

      request = RequestURL.last_request()
      assert request.body["type"] == "url_verification"
      assert request.body["token"] == "lark-token"
      refute Map.has_key?(request.headers, "x-lark-signature")
    end

    test "a request URL with other material refuses the callback", %{
      group_id: group_id,
      url: url
    } do
      seed_connect(group_id, "lark-other-token", %{
        "app_id" => "cli_token",
        "webhook_url" => url,
        "verification_token" => "lark-token"
      })

      seed_connect(group_id, "lark-other-key", %{
        "app_id" => "cli_key",
        "webhook_url" => url,
        "encrypt_key" => "lark-encrypt-key"
      })

      RequestURL.verify_with(%{"verification_token" => "another-token"})

      assert {:error, :token_mismatch} =
               LarkChecks.callback_preflight_for_connect(%{"connect_id" => "lark-other-token"})

      RequestURL.verify_with(%{"encrypt_key" => "another-key"})

      assert {:error, :decrypt_signature} =
               LarkChecks.callback_preflight_for_connect(%{"connect_id" => "lark-other-key"})
    end

    test "fails closed without a usable Lark connect", %{group_id: group_id, url: url} do
      seed_connect(group_id, "lark-pending", %{"webhook_url" => url, "status" => "pending"})
      seed_connect(group_id, "lark-no-material", %{"webhook_url" => url})

      seed_connect(group_id, "feishu-connect", %{
        "provider" => "feishu",
        "webhook_url" => url,
        "verification_token" => "feishu-token"
      })

      for {connect_id, reason} <- [
            {"lark-pending", :connect_inactive},
            {"lark-no-material", :secrets_not_configured},
            {"feishu-connect", :connect_not_found},
            {"lark-unknown", :connect_not_found},
            {"", :connect_not_found}
          ] do
        assert {:error, ^reason} =
                 LarkChecks.callback_preflight_for_connect(%{"connect_id" => connect_id})
      end

      assert RequestURL.last_request() == nil
    end

    test "an address nothing answers on is unreachable", %{group_id: group_id} do
      seed_connect(group_id, "lark-unreachable", %{
        "webhook_url" => "http://127.0.0.1:1/v1/im/lark/events",
        "verification_token" => "lark-token"
      })

      assert {:error, :callback_unreachable} =
               LarkChecks.callback_preflight_for_connect(%{"connect_id" => "lark-unreachable"})
    end
  end

  describe "bot_identity/1" do
    setup [:salix_store]

    test "returns a fingerprint of the bot's open_id, never the open_id", %{group_id: group_id} do
      seed_connect(group_id, "lark-identity", %{
        "app_id" => "cli_identity",
        "bot_open_id" => "ou_secret_lark_bot"
      })

      assert {:ok, evidence} = LarkChecks.bot_identity(%{"connect_id" => "lark-identity"})
      assert evidence["identity"] == "lark_bot_open_id"
      assert evidence["app_id"] == "cli_identity"
      assert evidence["connect_id"] == "lark-identity"
      assert byte_size(evidence["open_id_fingerprint"]) == 12
      refute inspect(evidence) =~ "ou_secret_lark_bot"
    end

    test "a connect without the open_id, or one that is not connected, is not ready", %{
      group_id: group_id
    } do
      seed_connect(group_id, "lark-no-identity", %{})
      seed_connect(group_id, "lark-off", %{"status" => "error", "bot_open_id" => "ou_bot"})

      assert {:error, :bot_identity_missing} =
               LarkChecks.bot_identity(%{"connect_id" => "lark-no-identity"})

      assert {:error, :connect_inactive} = LarkChecks.bot_identity(%{"connect_id" => "lark-off"})
    end
  end

  # ---- setup ----

  defp salix_store(_context) do
    SalixAgent.TestSupport.stop_all_agents()

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_agent, :llm},
            {:salix_im, :agent_delivery_mod}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Lark checks"})

    {:ok, tenant: tenant, group_id: group_id}
  end

  defp request_url(_context) do
    start_supervised!(RequestURL)
    port = BanditServer.start!(fn port -> {Bandit, plug: RequestURL, port: port} end)
    {:ok, url: "http://127.0.0.1:#{port}/v1/im/lark/events"}
  end

  defp router(%{tenant: tenant, group_id: group_id}) do
    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", agent["agent_id"])
      end)

    {:ok, agent_id: agent["agent_id"]}
  end

  defp seed_connect(group_id, connect_id, extra) do
    now = SystemsClock.system_time(:millisecond)

    record =
      Map.merge(
        %{
          "tenant_id" => "default",
          "group_id" => group_id,
          "connect_id" => connect_id,
          "provider" => "lark",
          "status" => "connected",
          "created_at" => now,
          "updated_at" => now
        },
        extra
      )

    {:ok, _} = SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), record)
    record
  end
end
