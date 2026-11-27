defmodule SalixAgent.ComputeToolsTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.Tools.Compute, as: ComputeTools

  defmodule Adapter do
    def dispatch_workload("compute.exec", %{"command" => ["oom"]} = args, workload_id) do
      {:ok,
       %{
         "operation" => "compute.exec",
         "args" => args,
         "workload_id" => workload_id,
         "exit_code" => 137,
         "timed_out" => false,
         "oom_killed" => true,
         "memory_peak_bytes" => 536_870_912
       }}
    end

    def dispatch_workload("compute.exec", %{"command" => ["timeout"]} = args, workload_id) do
      {:ok,
       %{
         "operation" => "compute.exec",
         "args" => args,
         "workload_id" => workload_id,
         "exit_code" => 124,
         "timed_out" => true,
         "oom_killed" => false
       }}
    end

    def dispatch_workload("process.tail", %{"process_id" => "oom-proc"} = args, workload_id) do
      {:ok,
       %{
         "operation" => "process.tail",
         "args" => args,
         "workload_id" => workload_id,
         "state" => "exited",
         "exit_code" => 137,
         "oom_killed" => true
       }}
    end

    def dispatch_workload("process.stop", %{"process_id" => "oom-proc"} = args, workload_id) do
      {:ok,
       %{
         "operation" => "process.stop",
         "args" => args,
         "workload_id" => workload_id,
         "state" => "exited",
         "exit_code" => 137,
         "oom_killed" => true
       }}
    end

    def dispatch_workload(operation, args, workload_id) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:adapter_env, args["env"]})

      {:ok,
       %{
         "operation" => operation,
         "args" => args,
         "workload_id" => workload_id,
         "transport" => "typed"
       }}
    end

    def call_workload(:workspace_read, %{"path" => "binary.bin"} = args, workload_id) do
      {:ok,
       %{
         "operation" => "workspace_read",
         "args" => args,
         "workload_id" => workload_id,
         "content_base64" => Base.encode64(<<0xFF, 0xFE, 0x00, 0x01>>)
       }}
    end

    def call_workload(:workspace_read, %{"path" => "hello.txt"} = args, workload_id) do
      {:ok,
       %{
         "operation" => "workspace_read",
         "args" => args,
         "workload_id" => workload_id,
         "content_base64" => Base.encode64("你好, workspace!\n")
       }}
    end

    def call_workload(operation, args, workload_id) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:adapter_env, args["env"]})

      {:ok,
       %{
         "operation" => to_string(operation),
         "args" => args,
         "workload_id" => workload_id
       }}
    end
  end

  defmodule MustNotRunAdapter do
    def call_workload(_, _, _), do: raise("rejected tool call reached the workspace adapter")

    def dispatch_workload(_, _, _),
      do: raise("rejected tool call reached the runtime adapter")
  end

  defmodule ComputeAccessStub do
    def list(_ctx, _args), do: {:ok, %{"workloads" => [%{"workload_id" => "workload-tools"}]}}

    def authorize(_ctx, "workload-tools", permission)
        when permission in ["workspace", "runtime"] do
      {:ok, %{id: "workload-tools"}}
    end

    def authorize(_ctx, "workspace-only", "workspace"), do: {:ok, %{id: "workspace-only"}}
    def authorize(_ctx, "workspace-only", "runtime"), do: {:error, :workload_not_available}
    def authorize(_ctx, "mismatch-target", _permission), do: {:ok, %{id: "other-workload"}}
    def authorize(_ctx, _target, _permission), do: {:error, :workload_not_available}
  end

  defmodule OAuthStore do
    def agent_oauth_context("agent"), do: {:ok, %{tenant: "tenant", group_id: "group"}}

    def bindings_for_group("group") do
      {:ok, [%{"provider" => "github", "alias" => "github", "connection_id" => "compute-oauth"}]}
    end
  end

  setup do
    previous_access = SystemsRuntime.get_env(:salix_agent, :compute_access_mod)
    SystemsRuntime.put_env(:salix_agent, :compute_access_mod, ComputeAccessStub)

    on_exit(fn ->
      if previous_access,
        do: SystemsRuntime.put_env(:salix_agent, :compute_access_mod, previous_access),
        else: SystemsRuntime.delete_env(:salix_agent, :compute_access_mod)
    end)

    %{
      workload_id: "workload-tools",
      ctx: %{
        tenant_id: "tenant",
        agent_id: "agent",
        runtime_kind: :internal,
        compute_adapter: Adapter,
        plugin_projection: %{},
        tool_call_id: "compute-call-1"
      }
    }
  end

  defp tool(name), do: Enum.find(ComputeTools.defs(), &(elem(&1, 0) == name))

  test "registers the 11 core compute tools and dispatches authorized targets", c do
    names = Enum.map(ComputeTools.defs(), &elem(&1, 0))

    assert names == [
             "compute.workloads.list",
             "compute.workspace.stat",
             "compute.workspace.list",
             "compute.workspace.read",
             "compute.workspace.write",
             "compute.exec",
             "process.start",
             "process.list",
             "process.write",
             "process.tail",
             "process.stop"
           ]

    assert Enum.all?(names, &(SalixAgent.Tools.find_entry(&1) != nil))

    for {name, _desc, schema, _fun, _wait} <-
          Enum.reject(ComputeTools.defs(), &(elem(&1, 0) == "compute.workloads.list")) do
      assert "workload_id" in schema["required"], "expected workload_id required for #{name}"

      assert get_in(schema, ["properties", "workload_id", "description"]) ==
               "Target Workload ID from compute.workloads.list."
    end

    stat_result =
      elem(tool("compute.workspace.stat"), 3).(
        %{"workload_id" => c.workload_id, "path" => "src/main.rs"},
        c.ctx
      )
      |> Jason.decode!()

    assert stat_result["workload_id"] == c.workload_id

    exec_result =
      elem(tool("compute.exec"), 3).(
        %{"workload_id" => c.workload_id, "command" => ["printf", "ok"]},
        c.ctx
      )
      |> Jason.decode!()

    assert exec_result["operation"] == "compute.exec"
    assert exec_result["transport"] == "typed"

    process_result =
      elem(tool("process.start"), 3).(
        %{"workload_id" => c.workload_id, "command" => ["sh"]},
        %{c.ctx | tool_call_id: "process-start-1"}
      )
      |> Jason.decode!()

    assert Regex.match?(~r/\Atps_[A-Za-z0-9_-]{43}\z/, process_result["args"]["request_id"])
  end

  test "enforces ComputeAccess authorization and target validation before dispatch", c do
    ctx = %{c.ctx | compute_adapter: MustNotRunAdapter}
    list_fun = elem(tool("process.list"), 3)
    exec_fun = elem(tool("compute.exec"), 3)

    assert {:tool_failure, _, "workload_target_required", "user_reportable", _, []} =
             list_fun.(%{}, ctx)

    assert {:tool_failure, _, "compute_workspace_unavailable", "user_reportable", _, []} =
             list_fun.(%{"workload_id" => c.workload_id}, %{ctx | runtime_kind: :external})

    assert {:tool_failure, _, "workload_target_mismatch", "user_reportable", _, []} =
             list_fun.(%{"workload_id" => "mismatch-target"}, ctx)

    assert {:tool_failure, _, "workload_not_available", "user_reportable", _, []} =
             list_fun.(%{"workload_id" => "missing-workload"}, ctx)

    assert {:tool_failure, _, "workload_not_available", "user_reportable", _, []} =
             exec_fun.(
               %{"workload_id" => "workspace-only", "command" => ["printf", "blocked"]},
               ctx
             )
  end

  test "exec and process start resolve group OAuth references only for authorized workloads", c do
    previous = SystemsRuntime.get_env(:salix_agent, :oauth_store_mod)
    SystemsRuntime.put_env(:salix_agent, :oauth_store_mod, OAuthStore)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :oauth_store_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :oauth_store_mod)
    end)

    :ok =
      SalixStore.OAuth.put("compute-oauth", %{
        "access_token" => "test-oauth-token",
        "status" => "active"
      })

    ref = %{
      "env_var" => "GH_TOKEN",
      "provider" => "github",
      "alias" => "github",
      "value" => "access_token"
    }

    for name <- ["compute.exec", "process.start"] do
      fun = elem(tool(name), 3)

      args = %{
        "workload_id" => c.workload_id,
        "command" => ["gh", "api", "user"],
        "credential_env" => [ref]
      }

      result = fun.(args, c.ctx) |> Jason.decode!()
      assert result["workload_id"] == c.workload_id
      assert_received {:adapter_env, ["GH_TOKEN=test-oauth-token"]}
      assert result["args"]["env"] == ["GH_TOKEN=[redacted credential]"]
      refute Map.has_key?(result["args"], "credential_env")

      assert_raise RuntimeError, ~r/not bound to this agent group/, fn ->
        fun.(
          put_in(args, ["credential_env"], [%{ref | "alias" => "other-group"}]),
          %{c.ctx | compute_adapter: MustNotRunAdapter}
        )
      end

      next =
        fun.(%{"workload_id" => c.workload_id, "command" => ["true"]}, c.ctx) |> Jason.decode!()

      refute Map.has_key?(next["args"], "env")
    end

    assert {:tool_failure, _, "workload_not_available", "user_reportable", _, []} =
             elem(tool("compute.exec"), 3).(
               %{
                 "workload_id" => "missing-workload",
                 "command" => ["true"],
                 "credential_env" => [ref]
               },
               %{c.ctx | compute_adapter: MustNotRunAdapter}
             )
  end

  test "workspace.write and process.write support UTF-8 text or base64 with strict validation",
       c do
    write_entry = tool("compute.workspace.write")
    write_schema = elem(write_entry, 2)
    write_fun = elem(write_entry, 3)

    assert write_schema["required"] == ["path", "workload_id"]

    assert Map.keys(write_schema["properties"]) |> Enum.sort() == [
             "content",
             "content_base64",
             "mode",
             "path",
             "workload_id"
           ]

    utf8_write =
      write_fun.(
        %{
          "workload_id" => c.workload_id,
          "path" => "/src/hello.txt",
          "content" => "你好, world!\n"
        },
        c.ctx
      )
      |> Jason.decode!()

    assert utf8_write["args"]["path"] == "src/hello.txt"
    assert utf8_write["args"]["content_base64"] == Base.encode64("你好, world!\n")
    refute Map.has_key?(utf8_write["args"], "content")

    b64_write =
      write_fun.(
        %{
          "workload_id" => c.workload_id,
          "path" => "bin.dat",
          "content_base64" => Base.encode64(<<0, 1, 2, 255>>)
        },
        c.ctx
      )
      |> Jason.decode!()

    assert b64_write["args"]["content_base64"] == Base.encode64(<<0, 1, 2, 255>>)

    blocked_ctx = %{c.ctx | compute_adapter: MustNotRunAdapter}

    for bad_args <- [
          %{"workload_id" => c.workload_id, "path" => "a.txt"},
          %{
            "workload_id" => c.workload_id,
            "path" => "a.txt",
            "content" => "hi",
            "content_base64" => Base.encode64("hi")
          },
          %{"workload_id" => c.workload_id, "path" => "a.txt", "content_base64" => "!!!not-b64"},
          %{"workload_id" => c.workload_id, "path" => "a.txt", "content" => nil}
        ] do
      assert {:tool_failure, _, "invalid_argument", "user_reportable", _, []} =
               write_fun.(bad_args, blocked_ctx)
    end

    write_example_params =
      SalixAgent.Tools.help_examples("compute.workspace.write", write_schema)
      |> get_in(["internal_llm", "arguments", "params"])
      |> Map.put("workload_id", c.workload_id)

    assert is_binary(write_example_params["content"])
    refute Map.has_key?(write_example_params, "content_base64")
    assert Jason.decode!(write_fun.(write_example_params, c.ctx))["workload_id"] == c.workload_id

    proc_write_entry = tool("process.write")
    proc_write_schema = elem(proc_write_entry, 2)
    proc_write_fun = elem(proc_write_entry, 3)

    assert proc_write_schema["required"] == ["process_id", "workload_id"]

    assert Map.keys(proc_write_schema["properties"]) |> Enum.sort() == [
             "data",
             "data_base64",
             "process_id",
             "workload_id"
           ]

    proc_text =
      proc_write_fun.(
        %{"workload_id" => c.workload_id, "process_id" => "proc-1", "data" => "echo hi\n"},
        c.ctx
      )
      |> Jason.decode!()

    assert proc_text["args"]["data_base64"] == Base.encode64("echo hi\n")
    refute Map.has_key?(proc_text["args"], "data")

    proc_b64 =
      proc_write_fun.(
        %{
          "workload_id" => c.workload_id,
          "process_id" => "proc-1",
          "data_base64" => Base.encode64(<<3>>)
        },
        c.ctx
      )
      |> Jason.decode!()

    assert proc_b64["args"]["data_base64"] == Base.encode64(<<3>>)

    for bad_args <- [
          %{"workload_id" => c.workload_id, "process_id" => "proc-1"},
          %{
            "workload_id" => c.workload_id,
            "process_id" => "proc-1",
            "data" => "a",
            "data_base64" => Base.encode64("a")
          },
          %{
            "workload_id" => c.workload_id,
            "process_id" => "proc-1",
            "data_base64" => "***invalid***"
          }
        ] do
      assert {:tool_failure, _, "invalid_argument", "user_reportable", _, []} =
               proc_write_fun.(bad_args, blocked_ctx)
    end

    proc_example_params =
      SalixAgent.Tools.help_examples("process.write", proc_write_schema)
      |> get_in(["internal_llm", "arguments", "params"])
      |> Map.put("workload_id", c.workload_id)

    assert is_binary(proc_example_params["data"])
    refute Map.has_key?(proc_example_params, "data_base64")

    assert Jason.decode!(proc_write_fun.(proc_example_params, c.ctx))["workload_id"] ==
             c.workload_id
  end

  test "workspace.read attaches UTF-8 content when valid and preserves binary base64 only", c do
    read_entry = tool("compute.workspace.read")
    read_fun = elem(read_entry, 3)

    assert Map.has_key?(elem(read_entry, 2)["properties"], "offset")
    assert Map.has_key?(elem(read_entry, 2)["properties"], "max_bytes")

    utf8_res =
      read_fun.(%{"workload_id" => c.workload_id, "path" => "hello.txt"}, c.ctx)
      |> Jason.decode!()

    assert utf8_res["content"] == "你好, workspace!\n"
    assert utf8_res["content_base64"] == Base.encode64("你好, workspace!\n")

    bin_res =
      read_fun.(%{"workload_id" => c.workload_id, "path" => "binary.bin"}, c.ctx)
      |> Jason.decode!()

    refute Map.has_key?(bin_res, "content")
    assert bin_res["content_base64"] == Base.encode64(<<0xFF, 0xFE, 0x00, 0x01>>)
  end

  test "workspace path normalization, process.tail wait_ms, and tool disclosure", c do
    stat_fun = elem(tool("compute.workspace.stat"), 3)
    list_entry = tool("compute.workspace.list")
    read_fun = elem(tool("compute.workspace.read"), 3)
    tail_entry = tool("process.tail")
    stop_entry = tool("process.stop")

    assert Jason.decode!(stat_fun.(%{"workload_id" => c.workload_id, "path" => "/"}, c.ctx))[
             "args"
           ]["path"] == "."

    assert Jason.decode!(stat_fun.(%{"workload_id" => c.workload_id, "path" => "///"}, c.ctx))[
             "args"
           ]["path"] == "."

    assert Jason.decode!(
             elem(list_entry, 3).(%{"workload_id" => c.workload_id, "path" => "//"}, c.ctx)
           )["args"]["path"] == "."

    assert Jason.decode!(read_fun.(%{"workload_id" => c.workload_id, "path" => "/a/b"}, c.ctx))[
             "args"
           ]["path"] == "a/b"

    assert Jason.decode!(
             read_fun.(%{"workload_id" => c.workload_id, "path" => "../escape"}, c.ctx)
           )["args"]["path"] == "../escape"

    assert Map.has_key?(elem(list_entry, 2)["properties"], "limit")

    assert get_in(elem(stop_entry, 2), ["properties", "signal", "enum"]) == [
             "term",
             "int",
             "kill"
           ]

    tail_schema = elem(tail_entry, 2)
    assert get_in(tail_schema, ["properties", "wait_ms", "maximum"]) == 30_000
    assert SalixAgent.Tools.tool_timeout_ms("process.tail", %{"wait_ms" => 30_000}) > 30_000

    tail_res =
      elem(tail_entry, 3).(
        %{"workload_id" => c.workload_id, "process_id" => "proc-1", "wait_ms" => 2500},
        c.ctx
      )
      |> Jason.decode!()

    assert tail_res["args"]["wait_ms"] == 2500

    disclosure =
      SalixAgent.ToolDisclosure.materialize_static("worker", :internal, %{
        tenant_id: "tenant",
        agent_id: "agent",
        runtime_kind: :internal
      })

    exec_schema =
      disclosure["tools"]
      |> Enum.find(&(&1["name"] == "compute.exec"))
      |> SalixAgent.ToolDisclosure.entry_schema()

    assert "workload_id" in exec_schema["required"]
  end

  test "compute.exec timeout_ms, workspace.list cursor pagination, and OOM/timeout diagnostics",
       c do
    list_entry = tool("compute.workspace.list")
    list_schema = elem(list_entry, 2)
    assert get_in(list_schema, ["properties", "limit", "maximum"]) == 500
    assert get_in(list_schema, ["properties", "cursor", "type"]) == "string"

    list_res =
      elem(list_entry, 3).(
        %{"workload_id" => c.workload_id, "path" => ".", "limit" => 50, "cursor" => "opaque-1"},
        c.ctx
      )
      |> Jason.decode!()

    assert list_res["args"]["limit"] == 50
    assert list_res["args"]["cursor"] == "opaque-1"

    exec_entry = tool("compute.exec")
    exec_schema = elem(exec_entry, 2)
    assert get_in(exec_schema, ["properties", "timeout_ms", "minimum"]) == 1_000
    assert get_in(exec_schema, ["properties", "timeout_ms", "maximum"]) == 300_000

    # SalixAgent.Tools outer timeout must exceed 60s default and scale with timeout_ms.
    default_timeout = SalixAgent.Tools.tool_timeout_ms("compute.exec", %{})
    assert default_timeout > 60_000
    assert SalixAgent.Tools.tool_timeout_ms("compute.exec", %{"timeout_ms" => 180_000}) > 180_000
    assert SalixAgent.Tools.tool_timeout_ms("compute.exec", %{"timeout_ms" => 300_000}) > 300_000
    assert SalixAgent.Tools.tool_timeout_ms("compute.exec", %{timeout_ms: 120_000}) > 120_000

    oom_exec =
      elem(exec_entry, 3).(
        %{"workload_id" => c.workload_id, "command" => ["oom"], "timeout_ms" => 90_000},
        c.ctx
      )
      |> Jason.decode!()

    assert oom_exec["oom_killed"] == true
    assert oom_exec["diagnostic"] =~ "OOM"

    timeout_exec =
      elem(exec_entry, 3).(
        %{"workload_id" => c.workload_id, "command" => ["timeout"], "timeout_ms" => 5_000},
        c.ctx
      )
      |> Jason.decode!()

    assert timeout_exec["timed_out"] == true
    assert timeout_exec["diagnostic"] =~ "timeout_ms"
    assert timeout_exec["diagnostic"] =~ "process.start"

    oom_tail =
      elem(tool("process.tail"), 3).(
        %{"workload_id" => c.workload_id, "process_id" => "oom-proc"},
        c.ctx
      )
      |> Jason.decode!()

    assert oom_tail["diagnostic"] =~ "OOM"

    oom_stop =
      elem(tool("process.stop"), 3).(
        %{"workload_id" => c.workload_id, "process_id" => "oom-proc"},
        c.ctx
      )
      |> Jason.decode!()

    assert oom_stop["diagnostic"] =~ "OOM"
  end
end
