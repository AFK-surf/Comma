defmodule SalixWeb.VoiceCliE2ETest do
  @moduledoc """
  Drives the real `comma-voice` CLI (systems/voice/comma-voice, `nodevice` build)
  in file mode against the voice WebSocket API with a fake GPT-Live model
  (docs/messaging-voice.md). Needs a Go toolchain, so it is excluded by
  default; run it with

      mix test apps/salix_web/test/voice_cli_e2e_test.exs --include comma_voice_cli
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  @moduletag :comma_voice_cli
  @moduletag timeout: 300_000

  alias SalixIM.Provider
  alias SalixVoice.Model.Fake

  @cli_dir Path.expand("../../../voice/comma-voice", __DIR__)

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "comma-voice-e2e-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    bin = Path.join(dir, "comma-voice")

    {output, status} =
      System.cmd("go", ["build", "-tags", "nodevice", "-o", bin, "."],
        cd: @cli_dir,
        env: [{"CGO_ENABLED", "0"}],
        stderr_to_stdout: true
      )

    assert status == 0, "comma-voice build failed:\n" <> output
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, bin: bin, dir: dir}
  end

  setup ctx do
    keys = [
      {:salix_web, :api_token},
      {:salix_voice, :model_mod},
      {:salix_voice, :fake_model_observer},
      {:salix_voice, :metering_mod},
      {:salix_voice, :ingress_mod},
      {:salix_voice, :test_pid}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, SystemsRuntime.get_env(app, key)}
    SystemsRuntime.put_env(:salix_web, :api_token, "test-token")
    SystemsRuntime.put_env(:salix_voice, :model_mod, Fake)
    SystemsRuntime.put_env(:salix_voice, :fake_model_observer, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_voice, :metering_mod, nil)
    SystemsRuntime.put_env(:salix_voice, :ingress_mod, SalixVoice.TestStubs.Ingress)
    SystemsRuntime.put_env(:salix_voice, :test_pid, SystemsRuntime.Proc.self())
    SalixStore.S3.Fake.reset()
    SalixCluster.NodeLifecycle.reset()

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    {:ok, _} = SalixVoice.Settings.update(%{"enabled" => true, "openai_api_key" => "sk-test"})

    tenant_id = req(:post, "/v1/admin/tenants", json: %{name: "CLI"}).body["tenant_id"]

    tenant_key =
      req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "t"}).body["key"]

    group_id =
      req_as(tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "CLI"}).body["group_id"]

    router =
      req_as(tenant_key, :post, "/v1/runtime/agents",
        json: %{group_id: group_id, name: "Router", role: "router"}
      ).body

    req_as(tenant_key, :patch, "/v1/runtime/agent-groups/#{group_id}",
      json: %{router_agent_id: router["agent_id"]}
    )

    voice_key =
      req_as(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/voice/api-keys",
        json: %{name: "cli"}
      ).body["key"]

    inbound_key =
      req_as(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/router/api-keys",
        json: %{name: "in"}
      ).body["key"]

    env = fn key ->
      [
        {"COMMA_VOICE_SERVER", SalixWeb.Application.base_url()},
        {"COMMA_VOICE_GROUP", group_id},
        {"COMMA_VOICE_API_KEY", key}
      ]
    end

    Map.merge(ctx, %{
      group_id: group_id,
      router_id: router["agent_id"],
      env: env,
      voice_key: voice_key,
      inbound_key: inbound_key
    })
  end

  test "check and a file-mode call through the real CLI", ctx do
    assert {_out, 0} = System.cmd(ctx.bin, ["check"], env: ctx.env.(ctx.voice_key))
    assert {_out, 3} = System.cmd(ctx.bin, ["check"], env: ctx.env.(ctx.inbound_key))

    input = Path.join(ctx.dir, "in.wav")
    output = Path.join(ctx.dir, "out.wav")
    File.write!(input, wav(8_000, 1_000))

    cli =
      SystemsRuntime.Task.async(fn ->
        System.cmd(
          ctx.bin,
          [
            "call",
            "--format",
            "pcmu_8k",
            "--input",
            input,
            "--output",
            output,
            "--tail",
            "2s",
            "--json"
          ],
          env: ctx.env.(ctx.voice_key),
          stderr_to_stdout: true
        )
      end)

    settle_receive({:fake_model, model, {:started, _opts}})
    Fake.emit(model, {:started, "sess_cli"})
    settle_receive({:fake_model, ^model, {:audio, _caller}})
    Fake.emit(model, {:input_transcript, "Book a table for two.", true, 800})
    Fake.emit(model, {:delegation, "dlg_cli", 900})

    settle_receive(
      {:ingress, _group, _content, %{"event_type" => "voice.delegation"} = metadata, _source,
       _opts}
    )

    assert {:ok, _} =
             Provider.call_api(ctx.router_id, "voice", "voice.say", %{
               "connect_id" => metadata["connect_id"],
               "params" => %{
                 "text" => "Your table is booked.",
                 "call_id" => metadata["chat_id"],
                 "delegation_id" => "dlg_cli"
               }
             })

    settle_receive(
      {:fake_model, ^model, {:append, :commentary, "dlg_cli", "Your table is booked."}}
    )

    Fake.emit(model, {:output_transcript, "Your table is booked.", true})
    Fake.emit(model, {:audio, :binary.copy(<<0x55>>, 4_000)})

    {out, status} = settled_await(cli)
    assert status == 0, out
    assert out =~ ~s("type":"session.started")
    assert out =~ "Your table is booked."
    assert out =~ ~s("type":"session.ended")
    assert File.stat!(output).size > 44
  end

  # A mono 16-bit PCM WAV of a quiet 440 Hz tone.
  defp wav(rate, ms) do
    samples = div(rate * ms, 1000)

    data =
      for n <- 0..(samples - 1), into: <<>> do
        value = round(2_000 * :math.sin(2 * :math.pi() * 440 * n / rate))
        <<value::little-signed-16>>
      end

    <<"RIFF", 36 + byte_size(data)::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data",
      byte_size(data)::little-32, data::binary>>
  end

  defp req(method, path, opts), do: req_as("test-token", method, path, opts)

  defp req_as(token, method, path, opts) do
    Req.request!(
      [
        method: method,
        url: SalixWeb.Application.base_url() <> path,
        headers: [{"authorization", "Bearer " <> token}],
        retry: false
      ] ++ opts
    )
  end
end
