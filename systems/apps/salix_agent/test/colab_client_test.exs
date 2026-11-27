defmodule SalixAgent.Colab.ClientTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.Colab.Client

  defmodule FakeResolver do
    def getaddrs(host, :inet) do
      case to_string(host) do
        "colab.research.google.com" -> {:ok, [{142, 250, 190, 78}]}
        "abc.prod.colab.googleusercontent.com" -> {:ok, [{142, 250, 190, 79}]}
        "xyz.prod.colab.dev" -> {:ok, [{142, 250, 190, 80}]}
        "8080-gpu-t4-s-abc-c.europe-west4.prod.r.colab.dev" -> {:ok, [{142, 250, 190, 81}]}
        "private.prod.colab.dev" -> {:ok, [{127, 0, 0, 1}]}
        "metadata.prod.colab.dev" -> {:ok, [{169, 254, 169, 254}]}
        "127.0.0.1" -> {:ok, [{127, 0, 0, 1}]}
        _ -> {:error, :nxdomain}
      end
    end

    def getaddrs(_host, :inet6), do: {:error, :nxdomain}
  end

  setup do
    prev_oauth = SystemsRuntime.get_env(:salix_agent, :colab_oauth)
    prev_resolver = SystemsRuntime.get_env(:salix_agent, :resolver)
    prev_private = SystemsRuntime.get_env(:salix_agent, :colab_allow_private_endpoints)

    SystemsRuntime.put_env(:salix_agent, :resolver, FakeResolver)

    on_exit(fn ->
      restore_env(:colab_oauth, prev_oauth)
      restore_env(:resolver, prev_resolver)
      restore_env(:colab_allow_private_endpoints, prev_private)
    end)

    :ok
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, val), do: SystemsRuntime.put_env(:salix_agent, key, val)

  defp configure_client(plug) do
    SystemsRuntime.put_env(:salix_agent, :colab_oauth,
      colab_base_url: "https://colab.research.google.com",
      req_options: [plug: plug]
    )
  end

  test "notebook_hash/1 produces exact 44-char google-colab-cli format" do
    uuid = "12345678-1234-4abc-8def-1234567890ab"
    nbh = Client.notebook_hash(uuid)
    assert byte_size(nbh) == 44
    assert nbh == "12345678_1234_4abc_8def_1234567890ab........"
  end

  test "hardware_spec/2 maps CPU, L4, and other GPUs accurately" do
    assert {:ok, %{variant: "DEFAULT", accelerator: "NONE", shape: nil}} =
             Client.hardware_spec("CPU", false)

    assert {:ok, %{variant: "DEFAULT", accelerator: "NONE", shape: "hm"}} =
             Client.hardware_spec("CPU", true)

    # L4 is high-mem-only and always omits shape=hm
    assert {:ok, %{variant: "GPU", accelerator: "L4", shape: nil}} =
             Client.hardware_spec("L4", true)

    assert {:ok, %{variant: "GPU", accelerator: "G4", shape: "hm"}} =
             Client.hardware_spec("G4", true)

    assert {:ok, %{variant: "GPU", accelerator: "T4", shape: nil}} =
             Client.hardware_spec("T4", false)

    assert {:error, :invalid_accelerator} = Client.hardware_spec("V100", false)
  end

  test "strips XSSI prefix, sends required headers, and executes assign/unassign/refresh_proxy_info" do
    configure_client(fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-1"]
      assert Plug.Conn.get_req_header(conn, "x-colab-client-agent") == ["colab-cli"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/ccu-info"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <> Jason.encode!(%{"currentBalance" => 2491.35, "assignmentsCount" => 1})
          )

        {"GET", "/tun/m/assign"} ->
          params = URI.decode_query(conn.query_string)
          assert params["variant"] == "GPU"
          assert params["accelerator"] == "L4"
          refute Map.has_key?(params, "shape")

          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-abc"}))

        {"POST", "/tun/m/assign"} ->
          assert Plug.Conn.get_req_header(conn, "x-goog-colab-token") == ["xsrf-abc"]

          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <>
              Jason.encode!(%{
                "endpoint" => "m-s-abc123",
                "runtimeProxyInfo" => %{
                  "url" => "https://abc.prod.colab.googleusercontent.com",
                  "token" => "proxy-tok"
                }
              })
          )

        {"GET", "/tun/m/assignments"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <>
              Jason.encode!(%{
                "assignments" => [
                  %{
                    "endpoint" => "m-s-abc123",
                    "runtimeProxyInfo" => %{
                      "url" => "https://abc.prod.colab.googleusercontent.com",
                      "token" => "fresh-proxy-tok"
                    }
                  }
                ]
              })
          )

        {"GET", "/tun/m/unassign/m-s-abc123"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-unassign"}))

        {"POST", "/tun/m/unassign/m-s-abc123"} ->
          assert Plug.Conn.get_req_header(conn, "x-goog-colab-token") == ["xsrf-unassign"]
          Plug.Conn.send_resp(conn, 200, ")]}'\n{}")
      end
    end)

    assert {:ok, %{"currentBalance" => 2491.35}} = Client.ccu_info("tok-1")

    nbh = Client.notebook_hash("12345678-1234-4abc-8def-1234567890ab")
    assert {:ok, %{"endpoint" => "m-s-abc123"}} = Client.assign("tok-1", nbh, "GPU", "L4", true)

    assert {:ok, %{url: "https://abc.prod.colab.googleusercontent.com", token: "fresh-proxy-tok"}} =
             Client.refresh_proxy_info("tok-1", "m-s-abc123")

    assert {:error, :vm_terminated_externally} = Client.refresh_proxy_info("tok-1", "m-s-missing")
    assert {:ok, %{}} = Client.unassign("tok-1", "m-s-abc123")
  end

  test "validate_proxy_url/2 enforces https, port 443, empty userinfo, domain allowlist, and SSRF IP checks" do
    assert {:ok,
            %{host: "colab.research.google.com", port: 443, addresses: [{142, 250, 190, 78}]}} =
             Client.validate_proxy_url("https://colab.research.google.com/colab/ssh")

    assert {:ok, %{host: "abc.prod.colab.googleusercontent.com"}} =
             Client.validate_proxy_url("https://abc.prod.colab.googleusercontent.com")

    assert {:ok, %{host: "xyz.prod.colab.dev"}} =
             Client.validate_proxy_url("https://xyz.prod.colab.dev:443")

    assert {:ok, %{host: "8080-gpu-t4-s-abc-c.europe-west4.prod.r.colab.dev"}} =
             Client.validate_proxy_url(
               "https://8080-gpu-t4-s-abc-c.europe-west4.prod.r.colab.dev"
             )

    assert {:error, :invalid_proxy_scheme} =
             Client.validate_proxy_url("http://colab.research.google.com")

    assert {:error, :invalid_proxy_port} =
             Client.validate_proxy_url("https://colab.research.google.com:8443")

    assert {:error, :invalid_proxy_userinfo} =
             Client.validate_proxy_url("https://user:pass@colab.research.google.com")

    assert {:error, :disallowed_proxy_host} =
             Client.validate_proxy_url("https://evil-colab.research.google.com")

    assert {:error, :disallowed_proxy_host} =
             Client.validate_proxy_url("https://evil.example.com")

    assert {:error, {:blocked_proxy_destination, {:blocked_address, _, {127, 0, 0, 1}}}} =
             Client.validate_proxy_url("https://private.prod.colab.dev")

    assert {:error, {:blocked_proxy_destination, {:blocked_address, _, {169, 254, 169, 254}}}} =
             Client.validate_proxy_url("https://metadata.prod.colab.dev")

    # Test override allows private endpoints
    SystemsRuntime.put_env(:salix_agent, :colab_allow_private_endpoints, true)

    assert {:ok, %{host: "127.0.0.1", port: 8443, addresses: [{127, 0, 0, 1}]}} =
             Client.validate_proxy_url("https://127.0.0.1:8443")
  end

  test "list_assignments accepts empty {} / [] and fails closed on malformed or empty-body 2xx while unassign permits empty 200" do
    for valid_empty <- ["{}", ")]}'\n{}", "[]", ")]}'\n[]", "{\"assignments\":[]}"] do
      configure_client(fn conn ->
        Plug.Conn.send_resp(conn, 200, valid_empty)
      end)

      assert {:ok, []} = Client.list_assignments("tok-1")
    end

    for invalid_body <- [
          "",
          ")]}'\n",
          "<html>oops</html>",
          "[1, 2, 3]",
          "{\"unexpected\":1}",
          "{\"error\":\"boom\"}",
          "{\"assignments\":[{}]}",
          "{\"assignments\":[{\"endpoint\":\"\"}]}"
        ] do
      configure_client(fn conn ->
        Plug.Conn.send_resp(conn, 200, invalid_body)
      end)

      assert {:error, :invalid_response} = Client.list_assignments("tok-1")
    end

    configure_client(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/unassign/m-s-empty"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-empty"}))

        {"POST", "/tun/m/unassign/m-s-empty"} ->
          Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    assert {:ok, %{}} = Client.unassign("tok-1", "m-s-empty")
  end
end
