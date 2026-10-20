defmodule SalixAgent.OnvifWsSecurityTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{DeviceSecrets, OnvifWsSecurity}
  alias SalixAgent.Tools.LanGateway
  alias SalixStore.S3

  @group "grp-cameras"
  @ctx %{agent_id: "agent-1", group_id: @group}
  @password "Pa55:w0rd!"
  @url "http://192.168.5.33:2020/onvif/service"
  @get_device_information ~s(<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body></s:Envelope>)

  # A gateway on the camera's network: records each request and answers 200.
  defmodule Dispatch do
    def get_device(_agent_id, _device_id), do: Process.get(:lan_device)

    def request(_agent_id, _target, method, params) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:request, method, params})
      {:ok, %{"status" => 200, "body" => "<s:Envelope/>", "truncated" => false}}
    end
  end

  setup do
    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    case SystemsRuntime.Proc.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Dispatch)
    capabilities = %{"lan_gateway" => %{"methods" => ["lan_http_request"]}}

    Process.put(
      :lan_device,
      {:ok,
       %{
         "device_id" => "dev-gw",
         "environment_id" => "env-gw",
         "status" => "connected",
         "capabilities" => capabilities,
         "environments" => [
           %{
             "environment_id" => "env-gw",
             "environment_provider" => "connector",
             "status" => "connected",
             "capabilities" => capabilities
           }
         ]
       }}
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_store)

      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :env_dispatch, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
    end)
  end

  # ONVIF Application Programmer's Guide, 6.1.1.3 (UsernameToken example).
  test "the PasswordDigest matches the ONVIF guide's example" do
    nonce = Base.decode64!("LKqI6G/AikKCQrN0zqZFlg==")

    assert OnvifWsSecurity.digest(nonce, "2010-09-16T07:50:45Z", "userpassword") ==
             "tuOSpGlFlIXsozq4HFNeeGeFLEI="
  end

  test "device.lan_request signs an ONVIF request with the saved password" do
    {:ok, _, :created} =
      DeviceSecrets.save(@group, %{
        "kind" => "onvif_password",
        "name" => "office-camera",
        "value" => @password,
        "host" => "192.168.5.33"
      })

    result =
      LanGateway.lan_request(
        %{
          "device_id" => "dev-gw",
          "method" => "POST",
          "url" => @url,
          "body" => @get_device_information,
          "auth" => %{
            "type" => "onvif_ws_security",
            "username" => "admin",
            "secret_ref" => "office-camera"
          }
        },
        @ctx
      )

    assert %{"status" => 200} = Jason.decode!(result)
    assert_received {:request, "lan_http_request", params}

    assert params["headers"] == %{"Content-Type" => "application/soap+xml; charset=utf-8"}
    refute inspect(params) =~ @password
    refute result =~ @password

    [_, nonce, created] =
      Regex.run(
        ~r{<wsse:Nonce [^>]*>([^<]+)</wsse:Nonce><wsu:Created>([^<]+)</wsu:Created>},
        params["body"]
      )

    digest = OnvifWsSecurity.digest(Base.decode64!(nonce), created, @password)
    assert params["body"] =~ ">#{digest}</wsse:Password>"

    assert {:ok, [%{"name" => "office-camera", "last_used_at" => used}]} =
             DeviceSecrets.list(@group)

    assert is_binary(used)
  end

  test "an unknown or wrong-kind secret fails before the gateway is called" do
    {:ok, _, _} =
      DeviceSecrets.save(@group, %{
        "kind" => "miio_token",
        "name" => "lamp",
        "value" => "00112233445566778899aabbccddeeff"
      })

    for {ref, code} <- [{"missing", "saved_token_not_found"}, {"lamp", "wrong_secret_kind"}] do
      assert {:tool_failure, _, ^code, "user_reportable", _, []} =
               LanGateway.lan_request(
                 %{
                   "device_id" => "dev-gw",
                   "method" => "POST",
                   "url" => @url,
                   "body" => @get_device_information,
                   "auth" => %{
                     "type" => "onvif_ws_security",
                     "username" => "admin",
                     "secret_ref" => ref
                   }
                 },
                 @ctx
               )
    end

    refute_received {:request, _, _}
  end
end
