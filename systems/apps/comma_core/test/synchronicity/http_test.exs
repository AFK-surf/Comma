defmodule Comma.Synchronicity.HTTPTest do
  use SystemsClock.Case, async: false
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
  end

  @device %{
    "device_id" => "dev",
    "network" => "default",
    "domain" => "default.comma-x.sync.test",
    "created" => true
  }

  describe "classify_device/2" do
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
  end

  describe "classify_key/2" do
  end

  describe "classify_revoke/2" do
  end

  describe "non-success classification" do
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
    SystemsRuntime.put_env(:comma_core, :synchronicity,
      base_url: "http://sync.test",
      provisioning_secret: @secret,
      req_options: [plug: {Req.Test, Comma.Synchronicity.HTTP}]
    )

    on_exit(fn -> SystemsRuntime.delete_env(:comma_core, :synchronicity) end)
    :ok
  end
end
