defmodule SalixAgent.Tools.SchemasTest do
  @moduledoc """
  The schema↔validation consistency contract for registry tools: every tool
  the LLM can see carries a precise input schema (no permissive-fallback
  drift), every `required` field is a declared property, and required-ness is
  enforced server-side — a call missing a schema-required argument is rejected
  with an error naming the field. Schema-carrying registry entries are covered
  through the same registry path.
  """
  use ExUnit.Case, async: true

  alias SalixAgent.{ToolDisclosure, Tools}
  alias SalixAgent.Tools.Schemas

  @internal_session_control_schemas MapSet.new(["wait_for"])
  @task_create_name "im_api.internal.task.create"

  test "every registry tool carries a precise input schema" do
    specs = Tools.specs()

    for spec <- specs do
      assert %{"type" => "object", "properties" => props, "required" => required} =
               spec["input_schema"],
             "missing/malformed input_schema for #{spec["name"]}"

      assert is_map(props)
      assert is_integer(spec["auto_wait_timeout_seconds"])
      assert spec["auto_wait_timeout_seconds"] > 0

      for field <- required do
        assert Map.has_key?(props, field),
               "#{spec["name"]}: required #{inspect(field)} is not a declared property"
      end
    end
  end

  test "Router summary tools expose their exact structured input contract" do
    read = Schemas.schema("meeting.read_summary_materials")
    assert read["required"] == ["meeting_id", "request_id"]
    assert read["properties"]["offset"]["minimum"] == 0

    assert read["properties"]["field"]["enum"] ==
             ["transcript", "captions_transcript", "asr_transcript"]

    submit = Schemas.schema("meeting.submit_summary")
    assert submit["required"] == ["meeting_id", "request_id", "summary"]
    summary = submit["properties"]["summary"]
    assert summary["additionalProperties"] == false

    assert summary["required"] ==
             ~w(title attendees timeline key_points action_items decisions open_questions blockers)

    assert summary["properties"]["action_items"]["items"]["required"] ==
             ["description", "owner", "deadline"]
  end

  test "no orphan schemas: every schema entry maps to a registry tool" do
    visible = MapSet.new(Tools.specs(), & &1["name"])

    for name <- Schemas.names() do
      assert name in visible or name in @internal_session_control_schemas,
             "schema defined for unknown tool #{inspect(name)}"
    end
  end

  test "meeting decision validates the required baseline" do
    router_ctx =
      %{agent_id: "meeting-baseline-router", role: "router", runtime_kind: :internal}
      |> SalixAgent.TestSupport.with_plugin_projection()
      |> then(fn ctx ->
        Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("router", :internal, ctx))
      end)

    base = %{
      "meeting_plan_id" => "mtp1_schema",
      "dispatch_revision" => "dispatch-schema",
      "decision" => "required"
    }

    assert {:error, "missing required params: baseline"} =
             Tools.validate_tool_params(
               "meeting.preparation.record_decision",
               base,
               router_ctx
             )

    assert :ok =
             Tools.validate_tool_params(
               "meeting.preparation.record_decision",
               Map.put(base, "baseline", %{
                 "scope" => "Prepare the launch review.",
                 "known_facts" => ["The launch owner is assigned."],
                 "gaps" => ["The latest metric is missing."]
               }),
               router_ctx
             )
  end

  test "manual meeting tools are disclosed only to the Router in both runtimes" do
    for runtime_kind <- [:internal, :external] do
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
  end

  test "Task creation requires a Worker and validates its published examples" do
    schema = runtime_task_schema(@task_create_name)

    router_ctx = dynamic_task_ctx("task-worker-choice-router")

    assert {:error, "missing required params: agent_id"} =
             Tools.validate_tool_params(
               @task_create_name,
               %{"connect_id" => "internal", "content" => "quick task"},
               router_ctx
             )

    assert :ok =
             Tools.validate_tool_params(
               @task_create_name,
               %{
                 "connect_id" => "internal",
                 "agent_id" => "000002",
                 "content" => "quick task"
               },
               router_ctx
             )

    assert {:error, _reason} =
             Tools.validate_tool_params(
               @task_create_name,
               %{
                 "connect_id" => "internal",
                 "agent_id" => "000002",
                 "content" => "invalid task",
                 "workflow" => %{}
               },
               router_ctx
             )

    assert %{
             "tool" => @task_create_name,
             "params" =>
               %{
                 "connect_id" => "internal",
                 "agent_id" => agent_id
               } = manual_params
           } = internal_task_contract(@task_create_name)["call"]["arguments"]

    assert is_binary(agent_id) and agent_id != ""
    assert :ok = Tools.validate_tool_params(@task_create_name, manual_params, router_ctx)

    params =
      Tools.help_examples(@task_create_name, schema)
      |> get_in(["internal_llm", "arguments", "params"])

    assert :ok = Tools.validate_tool_params(@task_create_name, params, router_ctx)
  end

  test "schedule.create accepts each exclusive timing mode through runtime validation" do
    ctx = tool_ctx("schedule-validation-test")

    assert :ok =
             Tools.validate_tool_params(
               "schedule.create",
               %{"prompt" => "send an update", "interval_minutes" => 5},
               ctx
             )

    assert :ok =
             Tools.validate_tool_params(
               "schedule.create",
               %{"prompt" => "send an update", "cron" => "0 9 * * *", "timezone" => "UTC"},
               ctx
             )

    assert :ok =
             Tools.validate_tool_params(
               "schedule.create",
               %{"prompt" => "send an update", "run_at" => "2026-07-20T09:50:00+08:00"},
               ctx
             )

    assert {:error, "invalid params: must match exactly one schema alternative"} =
             Tools.validate_tool_params(
               "schedule.create",
               %{
                 "prompt" => "send an update",
                 "interval_minutes" => 5,
                 "cron" => "0 9 * * *"
               },
               ctx
             )
  end

  test "schedule.create help example chooses one valid timing mode" do
    schema = Schemas.schema("schedule.create")

    params =
      Tools.help_examples("schedule.create", schema)
      |> get_in(["internal_llm", "arguments", "params"])

    assert :ok = Tools.validate_tool_params("schedule.create", params, tool_ctx("schedule-help"))
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

  test "a blank required string is named as empty in the correction" do
    # The model sent a value. "missing" alone made it resend the same call.
    ctx = tool_ctx("schemas-blank-test")

    assert [%{error: false, status: "guidance", content: content}] =
             Tools.execute(
               [%{id: "t-blank", name: "fs.copy_file", args: %{"from" => "", "to" => "/b.txt"}}],
               ctx
             )

    assert content =~ "missing required params: from (empty string)"
  end

  defp tool_ctx(agent_id) do
    ctx =
      %{agent_id: agent_id, role: "worker", runtime_kind: :external}
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :external, ctx))
  end

  defp internal_task_contract(operation_name) do
    {:ok, %{"apis" => apis}} = SalixIM.Provider.provider_manual("internal")

    Enum.find(apis, &(&1["operation_id"] == operation_name)) ||
      flunk("internal provider manual did not expose #{operation_name}")
  end

  defp internal_task_schema(operation_name),
    do: internal_task_contract(operation_name)["input_schema"]

  defp runtime_task_schema(operation_name) do
    internal_task_schema(operation_name)
    |> Map.update!("properties", fn properties ->
      Map.put(properties, "connect_id", %{
        "type" => "string",
        "description" => "connect_id from source context, user instruction, or discovery"
      })
    end)
    |> Map.update!("required", &Enum.uniq(["connect_id" | &1]))
  end

  defp dynamic_task_ctx(agent_id, operation_name \\ @task_create_name, role \\ "router") do
    %{
      agent_id: agent_id,
      role: role,
      runtime_kind: :external,
      tool_disclosure: %{
        "tools" => [
          %{"name" => operation_name, "input_schema" => runtime_task_schema(operation_name)}
        ]
      }
    }
  end
end
