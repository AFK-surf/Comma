defmodule SalixAgent.LanScriptToolTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.Tools.DeviceSecrets, as: Secrets
  alias SalixAgent.Tools.LanScript, as: Tool
  alias SalixStore.S3.Fake

  @token "00112233445566778899aabbccddeeff"

  # The gateway: lan_script answers with Process :lan_reply.
  defmodule Dispatch do
    def get_device(_agent_id, _device_id), do: Process.get(:lan_device)

    def request(_agent_id, target, method, params) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:request, target, method, params})
      Process.get(:lan_reply, {:ok, %{"result" => "ok", "logs" => []}})
    end
  end

  setup do
    Fake.reset()
    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    previous_skills = SystemsRuntime.get_env(:salix_agent, :builtin_skills_path)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Dispatch)

    root =
      Path.join(
        System.tmp_dir!(),
        "lan-script-skills-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "lamp"))

    File.write!(
      Path.join(root, "lamp/SKILL.md"),
      "---\nname: Lamp\ndescription: A lamp.\n---\n\nRun lamp.js.\n"
    )

    File.write!(Path.join(root, "lamp/lamp.js"), "return lan.udp(args);\n")
    SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, root)

    gateway(%{
      "methods" => ["lan_http_request", "udp_request", "lan_script"],
      "script" => %{"max_source_bytes" => 64}
    })

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    ctx =
      SalixAgent.TestSupport.with_plugin_projection(%{
        tenant_id: tenant,
        group_id: group,
        agent_id: SalixStore.Ids.new_agent_id(group),
        session_id: "lan-script-test"
      })

    on_exit(fn ->
      for {key, value} <- [env_dispatch: previous, builtin_skills_path: previous_skills] do
        if value,
          do: SystemsRuntime.put_env(:salix_agent, key, value),
          else: SystemsRuntime.delete_env(:salix_agent, key)
      end

      File.rm_rf!(root)
    end)

    %{ctx: ctx}
  end

  defp gateway(lan_gateway) do
    capabilities = %{"lan_gateway" => lan_gateway}

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
  end

  defp run(args, ctx), do: Tool.run(Map.put(args, "device_id", "dev-gw"), ctx)

  test "runs a skill's script file on the gateway with its args", %{ctx: ctx} do
    Process.put(:lan_reply, {:ok, %{"result" => %{"on" => true}, "logs" => ["sent"]}})

    result = run(%{"script" => "/.runtime/skills/lamp/lamp.js", "args" => %{"port" => 1}}, ctx)

    assert Jason.decode!(result) == %{"result" => %{"on" => true}, "logs" => ["sent"]}

    assert_received {:request, %{device_id: "dev-gw", environment_id: "env-gw"}, "lan_script",
                     %{
                       "source" => "return lan.udp(args);\n",
                       "args" => %{"port" => 1},
                       "timeout_ms" => 10_000
                     }}
  end

  test "puts saved secrets into args, with their host, and never returns their values", %{
    ctx: ctx
  } do
    Secrets.save(
      %{
        "kind" => "miio_token",
        "name" => "bedside-lamp",
        "value" => @token,
        "host" => "192.168.5.19"
      },
      ctx
    )

    Process.put(
      :lan_reply,
      {:ok, %{"result" => %{"echo" => String.upcase(@token)}, "logs" => ["token " <> @token]}}
    )

    result = run(%{"source" => "return 1;", "secrets" => %{"token" => "bedside-lamp"}}, ctx)

    refute result =~ ~r/#{@token}/i

    assert %{"result" => %{"echo" => "[saved secret]"}, "logs" => ["token [saved secret]"]} =
             Jason.decode!(result)

    assert_received {:request, _, "lan_script",
                     %{"args" => %{"token" => @token, "host" => "192.168.5.19"}}}

    # A host the model gives wins over the saved one.
    run(
      %{
        "source" => "return 1;",
        "args" => %{"host" => "192.168.5.20"},
        "secrets" => %{"token" => "bedside-lamp"}
      },
      ctx
    )

    assert_received {:request, _, "lan_script", %{"args" => %{"host" => "192.168.5.20"}}}

    assert {:tool_failure, _, "saved_token_not_found", _, _, _} =
             run(%{"source" => "return 1;", "secrets" => %{"token" => "kitchen"}}, ctx)
  end

  test "puts workspace files into args as base64 and refuses a request the gateway cannot take",
       %{ctx: ctx} do
    jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0, 255, 1, 2>>
    {:ok, write} = SalixAgent.AgentWorkspace.prepare_write(ctx.agent_id, "/out/page.jpg", jpeg)

    {:ok, :written} =
      SalixAgent.AgentWorkspace.seed_operation(ctx.agent_id, "op-jpeg", :written, [write])

    run(%{"source" => "return 1;", "files" => %{"image" => "/out/page.jpg"}}, ctx)
    encoded = Base.encode64(jpeg)
    assert_received {:request, _, "lan_script", %{"args" => %{"image" => ^encoded}}}

    gateway(%{"methods" => ["lan_script"], "script" => %{"max_request_bytes" => 300}})

    assert {:tool_failure, _, "script_request_too_large", _, _, _} =
             run(
               %{"source" => "return 1;", "args" => %{"pad" => String.duplicate("x", 100)}},
               ctx
             )

    assert_raise RuntimeError, ~r/not found/, fn ->
      run(%{"source" => "return 1;", "files" => %{"image" => "/out/none.jpg"}}, ctx)
    end
  end

  test "a script that failed returns its error and logs", %{ctx: ctx} do
    Process.put(
      :lan_reply,
      {:ok, %{"error" => "Error: device_not_answering: nothing on 7000", "logs" => ["scan"]}}
    )

    assert {:tool_failure, content, "script_failed", _,
            "Error: device_not_answering: nothing on 7000", _} =
             run(%{"source" => "return 1;"}, ctx)

    assert %{"logs" => ["scan"]} = Jason.decode!(content)
  end

  test "refuses what the gateway cannot run before it is sent", %{ctx: ctx} do
    assert {:tool_failure, _, "script_too_large", _, _, _} =
             run(%{"source" => String.duplicate("x", 65)}, ctx)

    gateway(%{"methods" => ["lan_http_request", "udp_request"]})
    assert {:tool_failure, _, "not_a_lan_gateway", _, _, _} = run(%{"source" => "return 1;"}, ctx)
    refute_received {:request, _, _, _}

    assert_raise RuntimeError, ~r/not found/, fn ->
      run(%{"script" => "/.runtime/skills/lamp/none.js"}, ctx)
    end

    assert_raise RuntimeError, ~r/script .* or source/, fn ->
      run(%{"script" => "a.js", "source" => "x"}, ctx)
    end
  end
end
