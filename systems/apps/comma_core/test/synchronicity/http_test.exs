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
  end

  describe "provision_workspace/3 over the transport" do
    setup :configure_transport

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
    setup :configure_transport

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
  end

  describe "classify_revoke/2" do
    test "2xx is done" do
      assert HTTP.classify_revoke(200, %{"result" => %{"revoked" => true}}) == :ok
    end
  end

  # Each classifier owns its own status clauses, so every row is a separate
  # mapping contract rather than a replay of a shared helper.
  @classification_errors [
    {"2xx with a result missing fields is invalid", :classify, 200,
     %{"result" => %{"org_id" => "x"}}, {:error, {:invalid, :malformed_success_body}}},
    {"2xx with no result is invalid", :classify, 200, %{"ok" => true},
     {:error, {:invalid, :malformed_success_body}}},
    {"409 explicit_link_required awaits an explicit link", :classify, 409,
     %{"error" => %{"code" => "explicit_link_required", "message" => "x"}},
     {:error, :explicit_link_required}},
    {"401 is an auth failure", :classify, 401, %{}, {:error, :auth}},
    {"403 is an auth failure", :classify, 403, %{}, {:error, :auth}},
    {"429 is retryable", :classify, 429, %{}, {:error, {:retryable, {:status, 429}}}},
    {"500 is retryable", :classify, 500, %{}, {:error, {:retryable, {:status, 500}}}},
    {"503 is retryable", :classify, 503, %{}, {:error, {:retryable, {:status, 503}}}},
    {"400 carries the code", :classify, 400, %{"error" => %{"code" => "invalid_email"}},
     {:error, {:invalid, {:bad_request, "invalid_email"}}}},
    {"2xx missing device fields is invalid", :classify_device, 200,
     %{"result" => %{"device_id" => "d"}}, {:error, {:invalid, :malformed_success_body}}},
    {"404 means the workspace is not provisioned", :classify_device, 404, %{},
     {:error, :not_provisioned}},
    {"409 preserves the device ownership conflict", :classify_device, 409,
     %{"error" => %{"code" => "device_org_conflict"}},
     {:error, {:invalid, {:conflict, "device_org_conflict"}}}},
    {"401 is an auth failure", :classify_device, 401, %{}, {:error, :auth}},
    {"403 is an auth failure", :classify_device, 403, %{}, {:error, :auth}},
    {"429 is retryable", :classify_device, 429, %{}, {:error, {:retryable, {:status, 429}}}},
    {"503 is retryable", :classify_device, 503, %{}, {:error, {:retryable, {:status, 503}}}},
    {"400 carries the code", :classify_device, 400, %{"error" => %{"code" => "invalid_nk"}},
     {:error, {:invalid, {:bad_request, "invalid_nk"}}}},
    {"2xx without a token is invalid", :classify_key, 200,
     %{"result" => Map.delete(@key, "token")}, {:error, {:invalid, :malformed_success_body}}},
    {"404 is an unprovisioned Workspace", :classify_key, 404,
     %{"error" => %{"code" => "workspace_not_provisioned"}}, {:error, :not_provisioned}},
    {"401 is an auth failure", :classify_key, 401, %{}, {:error, :auth}},
    {"503 is retryable", :classify_key, 503, %{}, {:error, {:retryable, {:status, 503}}}},
    {"400 carries the code", :classify_key, 400, %{"error" => %{"code" => "bad_name"}},
     {:error, {:invalid, {:bad_request, "bad_name"}}}},
    {"404 not_found is a gone key", :classify_revoke, 404, %{"error" => %{"code" => "not_found"}},
     {:error, :not_found}},
    {"404 workspace_not_provisioned is an unprovisioned Workspace", :classify_revoke, 404,
     %{"error" => %{"code" => "workspace_not_provisioned"}}, {:error, :not_provisioned}},
    {"502 is retryable", :classify_revoke, 502, %{}, {:error, {:retryable, {:status, 502}}}}
  ]

  describe "non-success classification" do
    for {name, fun, status, body, expected} <- @classification_errors do
      test "#{fun}/2: #{name}" do
        assert apply(HTTP, unquote(fun), [unquote(status), unquote(Macro.escape(body))]) ==
                 unquote(Macro.escape(expected))
      end
    end
  end

  describe "mint_api_key/3 and revoke_api_key/2 over the transport" do
    setup :configure_transport

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

  defp configure_transport(_context) do
    Application.put_env(:comma_core, :synchronicity,
      base_url: "http://sync.test",
      provisioning_secret: @secret,
      req_options: [plug: {Req.Test, Comma.Synchronicity.HTTP}]
    )

    on_exit(fn -> Application.delete_env(:comma_core, :synchronicity) end)
    :ok
  end
end
