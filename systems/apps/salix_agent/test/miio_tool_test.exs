defmodule SalixAgent.MiioToolTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  alias SalixAgent.LanCodec.Miio
  alias SalixAgent.Tools.DeviceSecrets, as: Secrets
  alias SalixAgent.Tools.Miio, as: Tool
  alias SalixStore.{Keys, S3}

  @token_hex "00112233445566778899aabbccddeeff"
  @token Base.decode16!(@token_hex, case: :lower)
  @device_id <<0x0A, 0x1B, 0x2C, 0x3D>>
  @ctx %{agent_id: "agent-1", group_id: "grp-lamps"}

  # A gateway that answers udp_request as a miIO device on 192.168.5.19
  # would: a hello reply, then each command's reply from Process :device.
  defmodule Dispatch do
    alias SalixAgent.LanCodec.Miio

    def get_device(_agent_id, _device_id), do: Process.get(:lan_device)

    def request(_agent_id, _target, "udp_request", params) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:udp, params})
      packet = Base.decode64!(params["payload_b64"])
      device = Process.get(:device)

      replies =
        cond do
          not device.online ->
            []

          packet == Miio.hello() ->
            [
              <<0x21, 0x31, 0x00, 0x20, 0::32>> <>
                device.id <> <<device.stamp::32>> <> :binary.copy(<<0xFF>>, 16)
            ]

          true ->
            reply =
              case Miio.decode(packet, device.token) do
                {:ok, request, header} ->
                  SystemsRuntime.Proc.send(
                    SystemsRuntime.Proc.self(),
                    {:command, request, header}
                  )

                  device.reply.(request)

                # Sent with another token: the device answers under its own.
                {:error, :checksum} ->
                  %{"id" => 0, "error" => %{"code" => -1, "message" => "bad request"}}
              end

            if reply,
              do: [Miio.build(Jason.encode!(reply), device.token, device.id, device.stamp + 5)],
              else: []
        end

      {:ok,
       %{
         "responses" =>
           Enum.map(
             replies,
             &%{"from" => "192.168.5.19:54321", "payload_b64" => Base.encode64(&1)}
           ),
         "timed_out" => replies == []
       }}
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
    :ets.delete_all_objects(:salix_agent_lan_codec_sessions)

    capabilities = %{"lan_gateway" => %{"methods" => ["lan_http_request", "udp_request"]}}

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

    device(%{})

    save!(@token_hex)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_store)

      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :env_dispatch, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
    end)
  end

  defp device(overrides) do
    Process.put(
      :device,
      Map.merge(
        %{
          online: true,
          id: @device_id,
          stamp: 1_000,
          token: @token,
          reply: fn request -> %{"id" => request["id"], "result" => ["on", "50"]} end
        },
        overrides
      )
    )
  end

  defp save!(value) do
    result =
      Secrets.save(
        %{
          "kind" => "miio_token",
          "name" => "bedside-lamp",
          "value" => value,
          "host" => "192.168.5.19",
          "model" => "bslamp2"
        },
        @ctx
      )

    refute result =~ value
    Jason.decode!(result)
  end

  defp call(args \\ %{}) do
    result =
      %{
        "device_id" => "dev-gw",
        "token_ref" => "bedside-lamp",
        "method" => "get_prop",
        "params" => ["power", "bright"]
      }
      |> Map.merge(args)
      |> Tool.request(@ctx)

    refute inspect(result) =~ @token_hex
    result
  end

  defp failure_code({:tool_failure, content, code, "user_reportable", _message, []}) do
    refute content =~ @token_hex
    code
  end

  test "hello then command through udp_request, and the session is reused" do
    assert %{"host" => "192.168.5.19", "result" => ["on", "50"]} = call() |> Jason.decode!()

    assert_received {:udp, %{"port" => 54_321, "max_responses" => 1} = hello}
    assert Base.decode64!(hello["payload_b64"]) == Miio.hello()
    assert_received {:udp, %{"timeout_ms" => 3_000}}

    assert_received {:command,
                     %{"id" => id, "method" => "get_prop", "params" => ["power", "bright"]},
                     %{device_id: @device_id, stamp: stamp}}

    assert stamp >= 1_001

    # The cached session skips the hello and moves the id on.
    call(%{"method" => "set_power", "params" => ["off", "smooth", 500]})
    assert_received {:udp, _command}
    refute_received {:udp, _}
    assert_received {:command, %{"id" => next, "method" => "set_power"}, %{stamp: next_stamp}}
    assert next != id
    assert next_stamp >= 1_006
  end

  test "save, list and use a token by name; delete makes later requests fail" do
    assert {:ok, %{body: stored}} = S3.get(Keys.ctl_group_device_secrets(@ctx.group_id))
    refute stored =~ @token_hex

    listed = Secrets.list(%{}, @ctx)
    refute listed =~ @token_hex

    assert %{
             "secrets" => [
               %{
                 "name" => "bedside-lamp",
                 "kind" => "miio_token",
                 "host" => "192.168.5.19",
                 "model" => "bslamp2",
                 "last_used_at" => nil
               }
             ]
           } = Jason.decode!(listed)

    # The host defaults to the one saved with the token.
    assert %{"host" => "192.168.5.19", "result" => ["on", "50"]} = call() |> Jason.decode!()
    assert_received {:command, %{"method" => "get_prop"}, _}

    assert %{"secrets" => [%{"last_used_at" => used}]} =
             Secrets.list(%{}, @ctx) |> Jason.decode!()

    assert is_binary(used)

    # Another Group sees nothing and cannot use the name.
    other = %{@ctx | group_id: "grp-other"}
    assert %{"secrets" => []} = Secrets.list(%{}, other) |> Jason.decode!()

    assert {:tool_failure, _, "saved_token_not_found", _, _, _} =
             Tool.request(
               %{"device_id" => "dev-gw", "token_ref" => "bedside-lamp", "method" => "get_prop"},
               other
             )

    assert %{"deleted" => true} =
             Secrets.delete(%{"name" => "bedside-lamp"}, @ctx) |> Jason.decode!()

    flush()
    assert "saved_token_not_found" = failure_code(call())
    refute_received {:udp, _}
  end

  test "an invalid value is refused without echoing it" do
    assert {:tool_failure, content, "invalid_value", _, message, _} =
             Secrets.save(
               %{"kind" => "miio_token", "name" => "lamp", "value" => "not-a-token-0123456789"},
               @ctx
             )

    refute content =~ "not-a-token"
    refute message =~ "not-a-token"
  end

  defp flush do
    SystemsRuntime.Proc.receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
