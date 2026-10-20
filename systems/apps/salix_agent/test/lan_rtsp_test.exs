defmodule SalixAgent.LanRtspTest do
  require SystemsRuntime.Proc

  @moduledoc """
  `device.lan_request` with an `rtsp://` url: one frame of a camera stream,
  through the gateway's `lan_tcp_dial` tunnel (`SalixAgent.SSH.DeviceRelay`)
  and the runtime's FFmpeg, stored as a workspace image the model sees.

  The connector side of the tunnel is played by the test with a T-Circle's
  limits (8 KiB frames, 16 KiB window) in front of
  `SalixAgent.TestSupport.FakeRtspCamera`.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.DeviceSecrets
  alias SalixAgent.TestSupport.FakeRtspCamera
  alias SalixAgent.Tools.LanGateway
  alias SalixStore.S3

  @moduletag :ffmpeg
  @password "Pa55:w0rd!"
  @max_frame 8_192
  @window 16_384

  defmodule TemplateMediaResolver do
    @behaviour SalixAgent.MediaResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.AgentModel.resolve_media_for_agent(agent_id)
  end

  defmodule Dispatch do
    def get_device(_agent_id, _device_id),
      do: SystemsRuntime.PersistentTerm.get({__MODULE__, :device})

    def open_tunnel(_agent_id, _target, id, params, relay) do
      test = SystemsRuntime.PersistentTerm.get({__MODULE__, :test})
      SystemsRuntime.Proc.send(test, {:open_tunnel, params})

      case SystemsRuntime.PersistentTerm.get({__MODULE__, :tunnel}) do
        {:refuse, reason} ->
          {:error, reason}

        {:camera, port} ->
          owner = SalixAgent.LanRtspTest.TunnelOwner.start(port, id, relay, test)

          {:ok,
           %{
             owner: owner,
             result: %{"status" => "connected", "window" => 16_384, "max_frame" => 8_192}
           }}
      end
    end
  end

  # The gateway's end of the tunnel: frames to and from the relay, at most one
  # window unacknowledged each way, and each relay frame's size reported.
  defmodule TunnelOwner do
    @max_frame 8_192
    @window 16_384

    def start(port, id, relay, test) do
      SystemsRuntime.Proc.spawn(fn ->
        {:ok, camera} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])

        loop(%{
          camera: camera,
          id: id,
          relay: relay,
          test: test,
          pending: "",
          sent: 0,
          acked: 0,
          received: 0
        })
      end)
    end

    defp loop(state) do
      SystemsRuntime.Proc.receive do
        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp", "data" => data}} ->
          bytes = Base.decode64!(data)
          SystemsRuntime.Proc.send(state.test, {:relay_frame, byte_size(bytes)})
          :gen_tcp.send(state.camera, bytes)
          received = state.received + byte_size(bytes)

          SystemsRuntime.Proc.send(
            state.relay,
            {:env_tunnel_frame, state.id, %{"channel" => "tcp_ack", "seq" => received}}
          )

          loop(%{state | received: received})

        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp_ack", "seq" => seq}} ->
          loop(flush(%{state | acked: seq}))

        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp", "eof" => true}} ->
          :gen_tcp.close(state.camera)

        {:tcp, _camera, data} ->
          loop(flush(%{state | pending: state.pending <> data}))

        {:tcp_closed, _camera} ->
          SystemsRuntime.Proc.send(
            state.relay,
            {:env_tunnel_frame, state.id, %{"channel" => "tcp", "eof" => true}}
          )
      end
    end

    defp flush(%{pending: pending} = state) when pending != "" do
      case min(min(@max_frame, @window - (state.sent - state.acked)), byte_size(pending)) do
        size when size > 0 ->
          <<chunk::binary-size(^size), rest::binary>> = pending
          frame = %{"channel" => "tcp", "data" => Base.encode64(chunk)}
          SystemsRuntime.Proc.send(state.relay, {:env_tunnel_frame, state.id, frame})
          flush(%{state | pending: rest, sent: state.sent + size})

        _full ->
          state
      end
    end

    defp flush(state), do: state
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      dispatch: SystemsRuntime.get_env(:salix_agent, :env_dispatch),
      resolver: SystemsRuntime.get_env(:salix_agent, :media_resolver)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Dispatch)
    SystemsRuntime.put_env(:salix_agent, :media_resolver, TemplateMediaResolver)
    SystemsRuntime.PersistentTerm.put({Dispatch, :test}, SystemsRuntime.Proc.self())

    on_exit(fn ->
      for key <- [:test, :device, :tunnel],
          do: SystemsRuntime.PersistentTerm.erase({Dispatch, key})

      for {app, key, value} <- [
            {:salix_store, :s3_backend, previous.s3},
            {:salix_agent, :env_dispatch, previous.dispatch},
            {:salix_agent, :media_resolver, previous.resolver}
          ] do
        if value,
          do: SystemsRuntime.put_env(app, key, value),
          else: SystemsRuntime.delete_env(app, key)
      end
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent, %{"supports_images" => true})
    group = SalixStore.Ids.group_id_from_agent!(agent)

    {:ok, _, :created} =
      DeviceSecrets.save(group, %{
        "kind" => "onvif_password",
        "name" => "office-camera",
        "value" => @password
      })

    gateway(["http_request", "lan_tcp_dial"])

    {:ok, port} =
      FakeRtspCamera.start(SystemsRuntime.Proc.self(),
        username: "admin",
        password: @password,
        path: "/stream2"
      )

    SystemsRuntime.PersistentTerm.put({Dispatch, :tunnel}, {:camera, port})
    {:ok, ctx: %{agent_id: agent, group_id: group}}
  end

  defp gateway(methods) do
    capabilities = %{"lan_gateway" => %{"methods" => methods}}

    environment = %{
      "environment_id" => "env-gw",
      "environment_provider" => "connector",
      "status" => "connected",
      "capabilities" => capabilities
    }

    SystemsRuntime.PersistentTerm.put(
      {Dispatch, :device},
      {:ok,
       %{
         "device_id" => "dev-gw",
         "environment_id" => "env-gw",
         "status" => "connected",
         "capabilities" => capabilities,
         "environments" => [environment]
       }}
    )
  end

  defp look(ctx, url \\ "rtsp://192.168.5.33:554/stream2") do
    LanGateway.lan_request(
      %{
        "device_id" => "dev-gw",
        "url" => url,
        "auth" => %{
          "type" => "http_digest",
          "username" => "admin",
          "secret_ref" => "office-camera"
        }
      },
      ctx
    )
  end

  defp relay_frames(sizes \\ []) do
    SystemsRuntime.Proc.receive do
      {:relay_frame, size} -> relay_frames([size | sizes])
    after
      0 -> sizes
    end
  end

  test "a frame of the camera's sub stream becomes a workspace image the model sees", %{ctx: ctx} do
    assert {content, [_event]} = look(ctx)
    refute content =~ @password

    [summary, image] = Jason.decode!(content)

    assert %{"status" => 200, "content_type" => "image/jpeg", "path" => "/artifacts/lan/" <> _} =
             Jason.decode!(summary["text"])

    assert %{"type" => "image", "mime_type" => "image/jpeg"} = image

    assert_received {:open_tunnel, %{"host" => "192.168.5.33", "port" => 554}}
    sizes = relay_frames()
    assert sizes != [] and Enum.all?(sizes, &(&1 <= @max_frame))
  end
end
