defmodule SalixAgent.Tools.AgentManagement do
  @moduledoc "The Agent management tool catalog; environment and task tools have their own owners."

  @archive_prompt "Permanently archive a Worker and reject new Tasks. Requires the user's explicit confirmation of this Agent and its irreversible archive after those consequences are explained. General authorization, silence, or another Worker cannot confirm it. Existing confirmation of the same target and consequence remains valid. History and environment are retained. Success confirms archive state, not completion of remote shutdown. user_confirmed declares consent; no separate approval token exists."
  @definitions [
    {"agent.list", :list,
     "List visible Workers in this Group. limit bounds candidates examined, not matches returned. Only null next_cursor means exhaustion. Results describe applied configuration, not runtime availability or Task activity. Known IDs can use agent.get directly. Incomplete or failed reads do not establish absence."},
    {"agent.get", :get,
     "Read a visible Worker, including archived Workers, by canonical agent_id. Returns configuration, purpose, creation audit, binding revision, model metadata, and archive state. Legacy creation audit can be null. Configured model metadata does not describe an existing Session. This read does not wake or diagnose the runtime."},
    {"agent.create_worker", :create,
     "Create an independent Worker on an existing runtime target. Purpose describes lasting responsibilities and suitability, not instructions or a Task title. The retained creation_reason explains why reuse is unsuitable, including an explicit request for independence. Existing Workers are compared by purpose and runtime capabilities. Internal Workers use the product default. Creates no environment or Task. Success confirms configuration, not readiness. Failures are not queued. Uncertain outcomes require an exact read or replay of the same invocation, not another create."},
    {"agent.update", :update,
     "Update a Worker name or purpose. Omitted fields are unchanged. The creation audit, model, runtime binding, permissions, Sessions, and Tasks are unchanged. Returns current configuration. A failed update requires a current-state check before retry."},
    {"agent.rebind_runtime", :rebind,
     "Change an external Worker target using its current binding revision. Conflicts require a fresh decision, not replay of an old decision with a newer revision. Only new Sessions use the new target. Existing Sessions with capability stay at their original target; those without it become read-only if the target changes. Runtime-kind conversion and Task recovery are separate operations."},
    {"agent.archive", :archive, @archive_prompt}
  ]

  # Schema is the single source for parameter shape; normalization only trims
  # descriptive strings and keeps explicit nil/empty update semantics strict.
  def normalize(operation, input) when is_map(input) do
    input =
      Map.new(input, fn {key, value} ->
        key = to_string(key)

        value =
          if key in ~w(name purpose creation_reason agent_id) and is_binary(value),
            do: String.trim(value),
            else: value

        {key, value}
      end)

    # The shared schema validator treats empty optional strings as omitted.
    # A supplied empty purpose is a destructive patch, not an omitted update.
    with true <- input["purpose"] != "",
         true <- Enum.all?(input, fn {key, value} -> key == "cursor" or not is_nil(value) end),
         :ok <- SalixAgent.Tools.validate_schema(input, schema(operation)),
         true <-
           operation != :update or Map.has_key?(input, "name") or Map.has_key?(input, "purpose") do
      {:ok, input}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  def normalize(_, _), do: {:error, :invalid_arguments}

  def defs do
    Enum.map(@definitions, fn {name, operation, description} ->
      {name, description, schema(operation), fn args, ctx -> call(operation, args, ctx) end,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: if(operation in [:list, :get], do: "read", else: "write")]}
    end)
  end

  def call(operation, args, ctx) do
    case SalixAgent.AgentManagement.run(operation, args, ctx) do
      {:ok, result} ->
        Jason.encode!(result)

      {:error, issue} ->
        {:tool_failure, Jason.encode!(issue), issue["code"], "user_reportable", issue["message"],
         []}
    end
  end

  def schema(:list),
    do:
      object(
        %{
          "cursor" => %{"type" => ["string", "null"]},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
          "lifecycle" => enum(~w(unarchived archived all)),
          "runtime_source" => enum(~w(internal connected compute)),
          "runtime_provider" => enum(~w(codex pi claude kimi))
        },
        []
      )

  def schema(:get), do: object(%{"agent_id" => string()}, ["agent_id"])

  def schema(:create),
    do:
      object(
        %{
          "name" => name(),
          "purpose" => purpose(),
          "creation_reason" => purpose(),
          "runtime" => runtime(true)
        },
        ~w(name purpose creation_reason runtime)
      )

  # Domain owners have a stable owner key rather than a model-authored reason.
  def schema(:create_owned),
    do:
      object(
        %{"name" => name(), "purpose" => purpose(), "runtime" => runtime(true)},
        ~w(name purpose runtime)
      )

  def schema(:update),
    do: object(%{"agent_id" => string(), "name" => name(), "purpose" => purpose()}, ["agent_id"])

  def schema(:rebind),
    do:
      object(
        %{
          "agent_id" => string(),
          "target" => runtime(false),
          "expected_binding_revision" => %{"type" => "integer", "minimum" => 0}
        },
        ~w(agent_id target expected_binding_revision)
      )

  def schema(:archive),
    do:
      object(
        %{
          "agent_id" => string(),
          "user_confirmed" => %{
            "type" => "boolean",
            "description" =>
              "Have you already obtained the user's explicit confirmation of this Agent's permanent, irreversible archive? Only JSON true executes."
          }
        },
        ~w(agent_id user_confirmed)
      )

  defp runtime(internal?) do
    connected =
      object(
        %{"kind" => enum(["connected"]), "device_runtime_id" => string()},
        ~w(kind device_runtime_id)
      )

    compute =
      object(
        %{
          "kind" => enum(["compute"]),
          "workload_id" => string(),
          "selection_fence" => %{
            "type" => "object",
            "description" =>
              "Copy the entire existing target's selection_fence from environment management without edits."
          }
        },
        ~w(kind workload_id selection_fence)
      )

    variants =
      if internal?,
        do: [object(%{"kind" => enum(["internal"])}, ["kind"]), connected, compute],
        else: [connected, compute]

    %{"oneOf" => variants}
  end

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp string, do: %{"type" => "string", "minLength" => 1, "maxLength" => 256}
  defp name, do: %{"type" => "string", "minLength" => 1, "maxLength" => 80}
  defp purpose, do: %{"type" => "string", "minLength" => 1, "maxLength" => 500}
  defp enum(values), do: %{"type" => "string", "enum" => values}
end
