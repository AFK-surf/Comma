defmodule Comma.Synchronicity.HTTPTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Comma.Synchronicity.HTTP

  @secret String.duplicate("x", 40)

  @result %{
    "org_id" => "org",
    "network_id" => "net",
    "sync_user_id" => "su",
    "created" => true
  }

  @owner %{subject: "usr_alice", email: "a@comma.test", name: "Alice"}

  describe "classify/2" do
    test "2xx with a wrapped full result succeeds" do
      assert HTTP.classify(200, %{"ok" => true, "soa_serial" => 3, "result" => @result}) ==
               {:ok,
                %{
                  sync_org_id: "org",
                  sync_org_slug: nil,
                  sync_network_id: "net",
                  sync_user_id: "su",
                  created: true
                }}
    end

    test "2xx with a result missing fields is invalid" do
      assert HTTP.classify(200, %{"result" => %{"org_id" => "x"}}) ==
               {:error, {:invalid, :malformed_success_body}}
    end

    test "2xx with no result is invalid" do
      assert HTTP.classify(200, %{"ok" => true}) ==
               {:error, {:invalid, :malformed_success_body}}
    end

    test "409 explicit_link_required awaits an explicit link" do
      body = %{"error" => %{"code" => "explicit_link_required", "message" => "x"}}
      assert HTTP.classify(409, body) == {:error, :explicit_link_required}
    end

    test "401 and 403 are auth failures" do
      assert HTTP.classify(401, %{}) == {:error, :auth}
      assert HTTP.classify(403, %{}) == {:error, :auth}
    end

    test "429, 5xx and 503 are retryable" do
      assert HTTP.classify(429, %{}) == {:error, {:retryable, {:status, 429}}}
      assert HTTP.classify(500, %{}) == {:error, {:retryable, {:status, 500}}}
      assert HTTP.classify(503, %{}) == {:error, {:retryable, {:status, 503}}}
    end

    test "400 carries the code" do
      body = %{"error" => %{"code" => "invalid_email"}}
      assert HTTP.classify(400, body) == {:error, {:invalid, {:bad_request, "invalid_email"}}}
    end
  end

  @device %{
    "device_id" => "dev",
    "network" => "default",
    "domain" => "default.comma-x.sync.test",
    "created" => true
  }

  describe "classify_device/2" do
    test "2xx with a wrapped device result succeeds" do
      assert HTTP.classify_device(200, %{"ok" => true, "soa_serial" => 3, "result" => @device}) ==
               {:ok,
                %{
                  device_id: "dev",
                  network: "default",
                  domain: "default.comma-x.sync.test",
                  created: true
                }}
    end

    test "2xx missing device fields is invalid" do
      assert HTTP.classify_device(200, %{"result" => %{"device_id" => "d"}}) ==
               {:error, {:invalid, :malformed_success_body}}
    end

    test "404 means the workspace is not provisioned" do
      assert HTTP.classify_device(404, %{}) == {:error, :not_provisioned}
    end

    test "409 preserves the device ownership conflict" do
      body = %{"error" => %{"code" => "device_org_conflict"}}

      assert HTTP.classify_device(409, body) ==
               {:error, {:invalid, {:conflict, "device_org_conflict"}}}
    end

    test "401 and 403 are auth failures" do
      assert HTTP.classify_device(401, %{}) == {:error, :auth}
      assert HTTP.classify_device(403, %{}) == {:error, :auth}
    end

    test "429 and 5xx are retryable" do
      assert HTTP.classify_device(429, %{}) == {:error, {:retryable, {:status, 429}}}
      assert HTTP.classify_device(503, %{}) == {:error, {:retryable, {:status, 503}}}
    end

    test "400 carries the code" do
      body = %{"error" => %{"code" => "invalid_nk"}}
      assert HTTP.classify_device(400, body) == {:error, {:invalid, {:bad_request, "invalid_nk"}}}
    end
  end

  describe "provision_workspace/3 over the transport" do
    setup do
      Application.put_env(:comma_core, :synchronicity,
        base_url: "http://sync.test",
        provisioning_secret: @secret,
        req_options: [plug: {Req.Test, Comma.Synchronicity.HTTP}]
      )

      on_exit(fn -> Application.delete_env(:comma_core, :synchronicity) end)
      :ok
    end

    test "PUTs to the workspace path with the bearer + owner, maps success" do
      Req.Test.stub(Comma.Synchronicity.HTTP, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/internal/v1/integrations/comma/workspaces/wsp_1"
        assert get_req_header(conn, "authorization") == ["Bearer " <> @secret]
        {:ok, raw, conn} = read_body(conn)

        assert Jason.decode!(raw) == %{
                 "name" => "WS One",
                 "owner" => %{
                   "subject" => "usr_alice",
                   "email" => "a@comma.test",
                   "name" => "Alice"
                 }
               }

        Req.Test.json(conn, %{"ok" => true, "soa_serial" => 1, "result" => @result})
      end)

      assert {:ok, %{sync_org_id: "org", sync_network_id: "net", created: true}} =
               HTTP.provision_workspace("wsp_1", "WS One", @owner)
    end

    test "omits owner name when nil" do
      Req.Test.stub(Comma.Synchronicity.HTTP, fn conn ->
        {:ok, raw, conn} = read_body(conn)
        assert Jason.decode!(raw)["owner"] == %{"subject" => "usr_bob", "email" => "b@comma.test"}
        Req.Test.json(conn, %{"result" => @result})
      end)

      assert {:ok, _} =
               HTTP.provision_workspace("wsp_2", "WS", %{
                 subject: "usr_bob",
                 email: "b@comma.test",
                 name: nil
               })
    end

    test "a transport error is retryable" do
      Req.Test.stub(Comma.Synchronicity.HTTP, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:retryable, _}} =
               HTTP.provision_workspace("wsp_3", "WS", @owner)
    end
  end

  describe "enroll_device/4 over the transport" do
    setup do
      Application.put_env(:comma_core, :synchronicity,
        base_url: "http://sync.test",
        provisioning_secret: @secret,
        req_options: [plug: {Req.Test, Comma.Synchronicity.HTTP}]
      )

      on_exit(fn -> Application.delete_env(:comma_core, :synchronicity) end)
      :ok
    end

    test "POSTs to the workspace devices path with the bearer + nk/label/owner" do
      Req.Test.stub(Comma.Synchronicity.HTTP, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/internal/v1/integrations/comma/workspaces/wsp_1/devices"
        assert get_req_header(conn, "authorization") == ["Bearer " <> @secret]
        {:ok, raw, conn} = read_body(conn)

        assert Jason.decode!(raw) == %{
                 "nk" => "nk-z32",
                 "label" => "laptop",
                 "owner" => %{
                   "subject" => "usr_alice",
                   "email" => "a@comma.test",
                   "name" => "Alice"
                 }
               }

        Req.Test.json(conn, %{"ok" => true, "soa_serial" => 1, "result" => @device})
      end)

      assert {:ok, %{device_id: "dev", domain: "default.comma-x.sync.test", created: true}} =
               HTTP.enroll_device("wsp_1", "nk-z32", "laptop", @owner)
    end

    test "a transport error is retryable" do
      Req.Test.stub(Comma.Synchronicity.HTTP, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:retryable, _}} =
               HTTP.enroll_device("wsp_2", "nk-z32", "laptop", @owner)
    end
  end

  @key %{
    "key_id" => "key_1",
    "name" => "comma-agent",
    "role" => "member",
    "prefix" => "synch_abcdefgh",
    "expires_at" => 0,
    "token" => "synch_abcdefgh0123456789",
    "org_id" => "org",
    "org_slug" => "comma-x",
    "network" => "default"
  }

  describe "classify/2 with an org slug" do
    test "carries the slug when the control plane answers one" do
      assert {:ok, %{sync_org_slug: "comma-x"}} =
               HTTP.classify(200, %{"result" => Map.put(@result, "org_slug", "comma-x")})
    end

    test "a control plane without a slug answers nil, not a failure" do
      assert {:ok, %{sync_org_slug: nil}} = HTTP.classify(200, %{"result" => @result})
    end
  end

  describe "classify_key/2" do
    test "2xx with a wrapped key result succeeds" do
      assert HTTP.classify_key(200, %{"result" => @key}) ==
               {:ok,
                %{
                  key_id: "key_1",
                  token: "synch_abcdefgh0123456789",
                  prefix: "synch_abcdefgh",
                  org_id: "org",
                  org_slug: "comma-x",
                  network: "default",
                  expires_at: 0
                }}
    end

    test "2xx without a token is invalid" do
      assert HTTP.classify_key(200, %{"result" => Map.delete(@key, "token")}) ==
               {:error, {:invalid, :malformed_success_body}}
    end

    test "404 is an unprovisioned Workspace" do
      assert HTTP.classify_key(404, %{"error" => %{"code" => "workspace_not_provisioned"}}) ==
               {:error, :not_provisioned}
    end

    test "401/403, 429/5xx and 400 map like provisioning" do
      assert HTTP.classify_key(401, %{}) == {:error, :auth}
      assert HTTP.classify_key(503, %{}) == {:error, {:retryable, {:status, 503}}}

      assert HTTP.classify_key(400, %{"error" => %{"code" => "bad_name"}}) ==
               {:error, {:invalid, {:bad_request, "bad_name"}}}
    end
  end

  describe "classify_revoke/2" do
    test "2xx is done" do
      assert HTTP.classify_revoke(200, %{"result" => %{"revoked" => true}}) == :ok
    end

    test "404 distinguishes a gone key from an unprovisioned Workspace" do
      assert HTTP.classify_revoke(404, %{"error" => %{"code" => "not_found"}}) ==
               {:error, :not_found}

      assert HTTP.classify_revoke(404, %{"error" => %{"code" => "workspace_not_provisioned"}}) ==
               {:error, :not_provisioned}
    end

    test "5xx is retryable" do
      assert HTTP.classify_revoke(502, %{}) == {:error, {:retryable, {:status, 502}}}
    end
  end

  describe "mint_api_key/3 and revoke_api_key/2 over the transport" do
    setup do
      Application.put_env(:comma_core, :synchronicity,
        base_url: "http://sync.test",
        provisioning_secret: @secret,
        req_options: [plug: {Req.Test, Comma.Synchronicity.HTTP}]
      )

      on_exit(fn -> Application.delete_env(:comma_core, :synchronicity) end)
      :ok
    end

    test "POSTs to the workspace api-keys path with the bearer, name and owner" do
      Req.Test.stub(Comma.Synchronicity.HTTP, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/internal/v1/integrations/comma/workspaces/wsp_1/api-keys"
        assert get_req_header(conn, "authorization") == ["Bearer " <> @secret]
        {:ok, raw, conn} = read_body(conn)

        assert Jason.decode!(raw) == %{
                 "name" => "comma-agent",
                 "owner" => %{
                   "subject" => "usr_alice",
                   "email" => "a@comma.test",
                   "name" => "Alice"
                 }
               }

        Req.Test.json(conn, %{"result" => @key})
      end)

      assert {:ok, %{key_id: "key_1", token: "synch_" <> _, org_slug: "comma-x"}} =
               HTTP.mint_api_key("wsp_1", @owner, "comma-agent")
    end

    test "DELETEs the key path with the bearer" do
      Req.Test.stub(Comma.Synchronicity.HTTP, fn conn ->
        assert conn.method == "DELETE"

        assert conn.request_path ==
                 "/internal/v1/integrations/comma/workspaces/wsp_1/api-keys/key_1"

        assert get_req_header(conn, "authorization") == ["Bearer " <> @secret]
        Req.Test.json(conn, %{"result" => %{"revoked" => true}})
      end)

      assert :ok = HTTP.revoke_api_key("wsp_1", "key_1")
    end

    test "a transport error is retryable" do
      Req.Test.stub(Comma.Synchronicity.HTTP, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:retryable, _}} = HTTP.mint_api_key("wsp_1", @owner, "comma-agent")
      assert {:error, {:retryable, _}} = HTTP.revoke_api_key("wsp_1", "key_1")
    end
  end
end
