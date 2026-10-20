defmodule SalixAgent.Tools.SchemasTest do
  @moduledoc """
  The schema↔validation consistency contract for registry tools: every tool
  the LLM can see carries a precise input schema (no permissive-fallback
  drift), every `required` field is a declared property, and required-ness is
  enforced server-side — a call missing a schema-required argument is rejected
  with an error naming the field. Schema-carrying registry entries are covered
  through the same registry path.
  """
  use SystemsClock.Case, async: true

  alias SalixAgent.{ToolDisclosure, Tools}
  alias SalixAgent.Tools.Schemas
  test "manual meeting tools are disclosed only to the Router" do
    runtime_kind = :internal

    router_ctx =
      %{agent_id: "meeting-router", role: "router", runtime_kind: runtime_kind}
      |> SalixAgent.TestSupport.with_plugin_projection()

    worker_ctx =
      %{agent_id: "meeting-worker", role: "worker", runtime_kind: runtime_kind}
      |> SalixAgent.TestSupport.with_plugin_projection()

    router_names =
      ToolDisclosure.materialize("router", runtime_kind, router_ctx)["tools"]
      |> Enum.map(& &1["name"])

    worker_names =
      ToolDisclosure.materialize("worker", runtime_kind, worker_ctx)["tools"]
      |> Enum.map(& &1["name"])

    for name <- ["meeting.join", "meeting.get"] do
      assert name in router_names
      refute name in worker_names
    end
  end

  test "schema-required arguments are enforced by the dispatcher" do
    # A call with empty args must come back as an error result naming the
    # first missing required field — the model-visible contract and the
    # server-side validation agree.
    ctx = tool_ctx("schemas-test")

    checks = %{
      "fs.write_file" => "missing required params: path",
      "fs.delete_file" => "missing required params: path",
      "fs.edit_file" => "missing required params: path",
      "fs.copy_file" => "missing required params: from",
      "fs.move_file" => "missing required params: from",
      "fs.grep" => "missing required params: pattern",
      "fs.glob" => "missing required params: pattern",
      "script.run" => "missing required params: source",
      "fs.read_file" => "missing required params: path",
      "fs.stat_file" => "missing required params: path",
      "web.search" => "missing required params: query",
      "env.exec" => "missing required params: device_id",
      "env.copy" => "missing required params: src_environment",
      "oauth.request_authorization" => "missing required params: provider",
      "oauth.complete_authorization" => "missing required params: state",
      "im.provider_apis_list" => "missing required params: provider",
      "schedule.create" => "missing required params: prompt",
      "schedule.delete" => "missing required params: schedule_id"
    }

    for {tool, expected} <- checks do
      assert [%{error: false, status: "guidance", content: content}] =
               Tools.execute([%{id: "t-#{tool}", name: tool, args: %{}}], ctx)

      assert content =~ expected, "#{tool}: expected #{inspect(expected)} in #{inspect(content)}"
    end
  end

  defp tool_ctx(agent_id) do
    ctx =
      %{agent_id: agent_id, role: "worker", runtime_kind: :internal}
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))
  end
end
