defmodule SalixAgent.Tools.AgentManagement do
  @moduledoc "The Agent management tool catalog; environment and task tools have their own owners."

  @archive_prompt "Permanently archive a Worker and reject new Tasks. Requires the user's explicit confirmation of this Agent and its irreversible archive after those consequences are explained.\n\nGeneral authorization, silence, or another Worker cannot confirm it. Existing confirmation of the same target and consequence remains valid. History and environment are retained. Success confirms archive state, not completion of remote shutdown. user_confirmed declares consent; no separate approval token exists."
  @definitions [
    {"agent.list", :list,
     "List visible Workers in this Group.\n\nlimit bounds candidates examined, not matches returned. Only null next_cursor means exhaustion. Results describe applied configuration, not runtime availability or Task activity. Known IDs can use agent.get directly. Incomplete or failed reads do not establish absence."},
    {"agent.get", :get,
     "Read a visible Worker, including archived Workers, by canonical agent_id.\n\nReturns configuration, purpose, creation audit, binding revision, model metadata, and archive state. Legacy creation audit can be null. Configured model metadata does not describe an existing Session. This read does not wake or diagnose the runtime."},
    {"agent.models", :models,
     "List the catalog models this Group's enabled, usable Profiles can serve, with their reasoning efforts.\n\nserved_by is subscription when a signed-in subscription plan serves the model; otherwise only a pay-per-use API key or Custom endpoint serves it and a Worker needs allow_paid true. Subscription-served models come first. When the organization limits the models a Router may choose, only those it allows are listed, efforts holds only the allowed efforts, and choices lists the exact model values it allows: pass one of them, adding a reasoning_effort from efforts when it names none. limit bounds returned models; truncated true means more exist, so narrow with query. Also returns the Group owner's locale and timezone when the product knows them, otherwise null. An empty list means no Profile serves a catalog model; create the Worker without model to use the product default. platform names the platform's own model (kind platform, tier worker) when it is set up, otherwise null: a Task may choose it, and people know it only by its name."},
    {"agent.create_worker", :create,
     "Create an independent Worker inside Salix or bound to a station.\n\nPurpose describes lasting responsibilities and suitability, not instructions or a Task title. The retained creation_reason explains why reuse is unsuitable, including an explicit request for independence. Existing Workers are compared by purpose and runtime capabilities. runtime {kind: internal} runs the Worker inside Salix: it uses the product default model unless model names a catalog model from agent.models; reasoning_effort must be one of that model's efforts, allow_paid true lets pay-per-use keys serve it, and profile_id pins one Profile that serves it. Some products reject model. runtime {kind: station, device_id} (a station from device.list) or {kind: cloud_vm} (the Group's Cloud VM) binds the Worker to that station: every Task of the Worker runs there with Codex or Claude Code, and needs no runs_on. It requires model {kind: runtime, provider: codex | claude}, with an optional model id that station runs (its task_models) and reasoning_effort; without a model id the station runs its default. The station need not be connected now. Creates no environment or Task. Success confirms configuration, not readiness. Failures are not queued. Uncertain outcomes require an exact read or replay of the same invocation, not another create."},
    {"agent.update", :update,
     "Update a Worker name or purpose. Omitted fields are unchanged. The creation audit, model, runtime binding, permissions, Sessions, and Tasks are unchanged. Returns current configuration. A failed update requires a current-state check before retry."},
    {"agent.rebind_runtime", :rebind,
     "Move a Worker bound to a station to another station, {kind: station, device_id} or {kind: cloud_vm}, using its current binding revision. model {kind: runtime, provider, model?, reasoning_effort?} changes its runtime model too; omitted, it keeps its model.\n\nConflicts require a fresh decision, not replay of an old decision with a newer revision. Only Tasks created later run on the new station; existing Tasks stay where they run. A Worker inside Salix cannot be bound by this tool. Task recovery is a separate operation."},
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
         true <- valid_model?(input["model"]),
         true <-
           operation != :update or Map.has_key?(input, "name") or Map.has_key?(input, "purpose") do
      {:ok, input}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  def normalize(_, _), do: {:error, :invalid_arguments}

  # The shared validator checks top-level fields only.
  defp valid_model?(nil), do: true

  defp valid_model?(%{"kind" => "catalog", "model" => model} = choice) when is_binary(model) do
    Enum.all?(Map.keys(choice), &(&1 in ~w(kind model reasoning_effort allow_paid profile_id))) and
      model != "" and byte_size(model) <= 256 and
      optional?(choice["reasoning_effort"], &(is_binary(&1) and &1 != "")) and
      optional?(choice["allow_paid"], &is_boolean/1) and
      optional?(choice["profile_id"], &(is_binary(&1) and &1 != ""))
  end

  defp valid_model?(%{"kind" => "runtime", "provider" => provider} = choice)
       when provider in ~w(codex claude) do
    Enum.all?(Map.keys(choice), &(&1 in ~w(kind provider model reasoning_effort))) and
      optional?(choice["model"], &(is_binary(&1) and &1 != "" and byte_size(&1) <= 256)) and
      optional?(choice["reasoning_effort"], &(is_binary(&1) and &1 != "")) and
      (Map.has_key?(choice, "model") or not Map.has_key?(choice, "reasoning_effort"))
  end

  defp valid_model?(_), do: false

  defp optional?(nil, _valid?), do: true
  defp optional?(value, valid?), do: valid?.(value)

  def defs do
    Enum.map(@definitions, fn {name, operation, description} ->
      {name, description, schema(operation), fn args, ctx -> call(operation, args, ctx) end,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [
         roles: ["router"],
         safety: if(operation in [:list, :get, :models], do: "read", else: "write")
       ]}
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
          "runtime_source" => enum(~w(internal station connected compute)),
          "runtime_provider" => enum(~w(codex pi claude kimi))
        },
        []
      )

  def schema(:get), do: object(%{"agent_id" => string()}, ["agent_id"])

  def schema(:models),
    do:
      object(
        %{
          "query" => %{"type" => "string", "minLength" => 1, "maxLength" => 80},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        },
        []
      )

  def schema(:create),
    do:
      object(
        %{
          "name" => name(),
          "purpose" => purpose(),
          "creation_reason" => purpose(),
          "runtime" => runtime(true),
          "model" => model()
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
          "model" => runtime_model(),
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
    station =
      object(
        %{
          "kind" => enum(["station"]),
          "device_id" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 256,
            "description" => "A station's device_id from device.list."
          }
        },
        ~w(kind device_id)
      )

    cloud_vm = object(%{"kind" => enum(["cloud_vm"])}, ["kind"])

    variants =
      if internal?,
        do: [object(%{"kind" => enum(["internal"])}, ["kind"]), station, cloud_vm],
        else: [station, cloud_vm]

    %{"oneOf" => variants}
  end

  # A catalog model for a Worker inside Salix; a runtime model for one bound
  # to a station.
  defp model, do: %{"oneOf" => [catalog_model(), runtime_model()]}

  defp catalog_model,
    do:
      object(
        %{
          "kind" => enum(["catalog"]),
          "model" => string(),
          "reasoning_effort" => effort(),
          "allow_paid" => %{"type" => "boolean"},
          "profile_id" => string()
        },
        ~w(kind model)
      )

  defp runtime_model,
    do:
      object(
        %{
          "kind" => enum(["runtime"]),
          "provider" => enum(~w(codex claude)),
          "model" => string(),
          "reasoning_effort" => effort()
        },
        ~w(kind provider)
      )

  defp effort, do: %{"type" => "string", "minLength" => 1, "maxLength" => 32}

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
