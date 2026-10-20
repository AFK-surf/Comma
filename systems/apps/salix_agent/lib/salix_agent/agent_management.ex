defmodule SalixAgent.AgentManagement do
  @moduledoc "Synchronous Router commands. The caller owns retries; no command worker or desired-state copy."
  alias SalixAgent.{Control, StationBinding}
  alias SalixAgent.AgentManagement.{Error, Ports, Projection, Targets}
  alias SalixStore.{CasRecord, Ids, Keys}
  require Logger

  def run(operation, args, ctx) do
    with {:ok, args} <- SalixAgent.Tools.AgentManagement.normalize(operation, args),
         {:ok, caller} <- router(ctx),
         :ok <- admit(operation),
         {:ok, result} <- dispatch(operation, args, ctx, caller) do
      {:ok, result}
    else
      {:error, reason} ->
        issue = Error.public(reason)
        log_opaque(operation, issue, reason)
        {:error, issue}
    end
  rescue
    exception ->
      # The model sees only "outcome unknown"; operators need the real cause.
      # Log the exception type and where it was raised, never its data.
      Logger.error(
        "agent management #{operation} raised #{inspect(exception.__struct__)} at " <>
          frame(__STACKTRACE__)
      )

      {:error,
       Error.public(
         if(operation in [:get, :list], do: :read_unavailable, else: :mutation_outcome_unknown)
       )}
  end

  @opaque_codes ~w(mutation_outcome_unknown management_unavailable read_unavailable)

  defp log_opaque(operation, %{"code" => code}, reason) when code in @opaque_codes,
    do: Logger.warning("agent management #{operation} returned #{code}: #{brief(reason)}")

  defp log_opaque(_operation, _issue, _reason), do: :ok

  defp frame([{module, function, arity, location} | _]) when is_list(location) do
    arity = if is_list(arity), do: length(arity), else: arity
    "#{inspect(module)}.#{function}/#{arity}:#{location[:line]}"
  end

  defp frame(_stacktrace), do: "unknown"

  # Atoms and tuple structure only: error terms can carry records or configuration.
  defp brief(reason) when is_atom(reason), do: inspect(reason)
  defp brief({:creation_failed, _id, reason}), do: "creation_failed " <> brief(reason)

  defp brief(reason) when is_tuple(reason),
    do: "{" <> Enum.map_join(Tuple.to_list(reason), ", ", &brief/1) <> "}"

  defp brief(reason) when is_binary(reason), do: "string"
  defp brief(%{} = reason), do: "map with keys " <> inspect(Enum.take(Map.keys(reason), 8))
  defp brief(_reason), do: "term"

  @doc "Ensure a domain-owned ordinary Worker without tying identity to a Router turn."
  def ensure_owned_worker(owner_key, args, ctx) when is_binary(owner_key) do
    with true <- owner_key != "" and byte_size(owner_key) <= 128,
         {:ok, args} <- SalixAgent.Tools.AgentManagement.normalize(:create_owned, args),
         {:ok, caller} <- router(ctx),
         :ok <- admit(:create),
         scope = %{tenant_id: caller["tenant_id"], group_id: caller["group_id"]},
         invocation =
           Jason.encode!([
             scope.tenant_id,
             scope.group_id,
             caller["agent_id"],
             "domain",
             owner_key
           ]),
         {:ok, result} <-
           create_reserved(scope, args, invocation, %{
             "kind" => "domain",
             "owner_key" => owner_key,
             "router_agent_id" => caller["agent_id"]
           }),
         {:ok, record} <- Control.get_record(result["agent"]["agent_id"]),
         :ok <- writable(record) do
      {:ok, result}
    else
      false -> {:error, Error.public(:invalid_arguments)}
      {:error, reason} -> {:error, Error.public(reason)}
    end
  rescue
    _ -> {:error, Error.public(:mutation_outcome_unknown)}
  end

  defp admit(operation) when operation in [:list, :get, :models], do: :ok
  defp admit(_), do: SalixStore.AgentConfigurationRollout.ensure_open()

  defp router(%{agent_id: id}) do
    case Control.get_record(id) do
      {:ok, %{"role" => "router"} = caller} ->
        if Control.visible?(caller), do: {:ok, caller}, else: {:error, :forbidden}

      {:ok, _} ->
        {:error, :forbidden}

      {:error, :not_found} ->
        {:error, :forbidden}

      _ ->
        {:error, :read_unavailable}
    end
  end

  defp router(_), do: {:error, :forbidden}

  # The Group's Task agent (`SalixAgent.TaskAgent`) is Salix's own: a Router
  # neither lists nor manages it.
  defp dispatch(:list, args, _ctx, caller) do
    opts =
      [exclude_task_agent: true] ++ Enum.map(args, fn {key, value} -> {list_key(key), value} end)

    with {:ok, page} <- Control.page_workers(caller["tenant_id"], caller["group_id"], opts) do
      {:ok,
       %{
         "items" => Enum.map(page.items, &Projection.summary/1),
         "returned_count" => page.returned_count,
         "next_cursor" => page.next_cursor
       }}
    end
  end

  # Bounded: at most 100 Profiles and `limit` models (`AccountPool.servable_models/2`).
  defp dispatch(:models, args, _ctx, caller) do
    scope = %{tenant_id: caller["tenant_id"], group_id: caller["group_id"]}

    with {:ok, filter} <- Ports.model_filter(scope),
         {:ok, served} <-
           SalixAgent.AccountPool.servable_models(scope.tenant_id,
             limit: args["limit"] || 50,
             query: args["query"],
             filter: filter
           ),
         {:ok, user} <- Ports.user_context(scope) do
      {:ok,
       served
       |> Map.put("user", Map.take(user, ~w(locale timezone)))
       |> Map.put("platform", platform_model())}
    else
      _ -> {:error, :read_unavailable}
    end
  end

  defp dispatch(:archive, %{"user_confirmed" => false}, _ctx, _caller),
    do: {:error, :user_confirmation_required}

  defp dispatch(operation, args, ctx, caller) do
    command(%{tenant_id: caller["tenant_id"], group_id: caller["group_id"]}, operation, args, ctx)
  end

  # The platform model a Task can choose (`model` kind platform, tier worker),
  # by the name people see; nil when the platform has not set it up.
  defp platform_model do
    if SalixAgent.PlatformModels.configured?("worker"),
      do: %{"kind" => "platform", "tier" => "worker", "name" => SalixAgent.PlatformModels.name()}
  end

  defp get(scope, id) do
    with true <- Ids.valid_agent_id_for_group?(id, scope.group_id),
         {:ok, record} <- Control.get_including_archived(id, scope.tenant_id),
         true <- record["group_id"] == scope.group_id and record["role"] == "worker",
         {:ok, task_agent} <- SalixAgent.TaskAgent.get(scope.group_id),
         true <- id != task_agent do
      {:ok, record}
    else
      false -> {:error, :agent_not_found}
      {:error, :not_found} -> {:error, :agent_not_found}
      error -> error
    end
  end

  defp command(scope, :get, args, _ctx) do
    with {:ok, record} <- get(scope, args["agent_id"]),
         do: {:ok, %{"agent" => Projection.detail(record)}}
  end

  defp command(scope, :update, args, _ctx) do
    with {:ok, before} <- get(scope, args["agent_id"]),
         {:ok, %{record: record, result: result}} <-
           Control.configure_worker_metadata(
             before["agent_id"],
             scope.tenant_id,
             Map.take(args, ~w(name purpose))
           ) do
      {:ok, %{"result" => Atom.to_string(result), "agent" => Projection.detail(record)}}
    end
  end

  # A Worker bound to a station moves to another station, or another runtime
  # model; its Tasks made later run there.
  defp command(scope, :rebind, args, _ctx) do
    with {:ok, record} <- get(scope, args["agent_id"]),
         :ok <- writable(record),
         true <- StationBinding.bound?(record),
         {:ok, %{"kind" => "station", "runs_on" => runs_on}} <-
           Targets.resolve(scope, args["target"]),
         {:ok, %{record: updated, result: result}} <-
           Control.rebind_station_worker(
             record["agent_id"],
             scope.tenant_id,
             %{
               "runs_on" => runs_on,
               "model" => args["model"] || get_in(record, ["station_binding", "model"])
             },
             args["expected_binding_revision"]
           ) do
      {:ok, %{"result" => Atom.to_string(result), "agent" => Projection.detail(updated)}}
    else
      false -> {:error, :unsupported_agent_kind}
      {:ok, _internal} -> {:error, :unsupported_agent_kind}
      error -> error
    end
  end

  defp command(scope, :archive, args, _ctx) do
    with {:ok, record} <- get(scope, args["agent_id"]),
         {:ok, archived} <- Control.archive_permanently(record["agent_id"], scope.tenant_id) do
      {:ok, %{"agent" => Projection.summary(archived)}}
    end
  end

  defp command(scope, :create, input, ctx) do
    with {:ok, invocation} <- invocation(scope, ctx, "create") do
      create_reserved(scope, input, invocation, %{
        "kind" => "router_tool",
        "reason" => input["creation_reason"],
        "router_agent_id" => ctx[:agent_id],
        "session_id" => ctx[:session_id],
        "tool_call_id" => ctx[:tool_call_id]
      })
    end
  end

  defp create_reserved(scope, input, invocation, audit) do
    with {:ok, reservation} <- reserve_creation(scope, input, invocation) do
      case Control.get_record(reservation["agent_id"]) do
        {:ok, %{"hidden" => true}} ->
          {:error, :agent_not_found}

        {:ok, %{"group_id" => group, "role" => "worker"} = record} when group == scope.group_id ->
          {:ok,
           %{"result" => "unchanged", "replayed" => true, "agent" => Projection.detail(record)}}

        {:error, :not_found} ->
          create_worker(scope, input, reservation["agent_id"], audit)

        {:ok, _} ->
          {:error, :invocation_conflict}

        error ->
          error
      end
    end
  end

  # A create-only reservation reuses one identity after a lost response. It is
  # immutable input, not queued work. The digest is an existing namespace lookup
  # key, not a credential or an authority proof. No worker scans these records.
  # Model anchor: tla/salix/AgentCreationReservation.tla.
  defp reserve_creation(scope, input, invocation) do
    digest =
      :crypto.hash(:sha256, "agent.create_worker.v2:" <> invocation)
      |> Base.encode16(case: :lower)

    key = Keys.ctl_agent_worker_tool_idempotency(scope.group_id, digest)
    candidate = %{"agent_id" => Ids.new_agent_id(scope.group_id), "request" => input}

    result =
      case CasRecord.create(key, candidate) do
        {:error, :exists} -> CasRecord.get(key)
        other -> other
      end

    case result do
      {:ok, %{"request" => ^input} = receipt} -> {:ok, receipt}
      {:ok, _} -> {:error, :invocation_conflict}
      error -> error
    end
  end

  defp create_worker(scope, input, id, audit) do
    with {:ok, runtime} <- Targets.resolve(scope, input["runtime"]),
         {:ok, record} <- create_record(scope, runtime, input, id, audit) do
      {:ok, %{"result" => "applied", "replayed" => false, "agent" => Projection.detail(record)}}
    else
      {:error, reason} -> {:error, {:creation_failed, id, reason}}
    end
  end

  # The product port supplies an internal Worker's model (the chosen one, or
  # none to follow the platform model) and environment, and creates it under
  # its own lock. A catalog model applies only to a Worker inside Salix; a
  # Worker bound to a station takes a runtime model for that station instead,
  # and the product's defaults for everything else.
  defp create_record(_scope, %{"kind" => "internal"}, %{"model" => %{"kind" => "runtime"}}, _, _),
    do: {:error, :invalid_arguments}

  defp create_record(scope, %{"kind" => "internal"}, input, id, audit) do
    Ports.internal_worker(scope, input["model"], fn product ->
      create_owned(scope, input, id, audit, Map.take(product, ~w(model vm)))
    end)
  end

  defp create_record(scope, %{"kind" => "station", "runs_on" => runs_on}, input, id, audit) do
    case input["model"] do
      %{"kind" => "runtime"} = model ->
        Ports.internal_worker(scope, nil, fn product ->
          product
          |> Map.take(~w(model vm))
          |> Map.put("station_binding", %{"runs_on" => runs_on, "model" => model})
          |> then(&create_owned(scope, input, id, audit, &1))
        end)

      _catalog_or_none ->
        {:error, :station_model_required}
    end
  end

  defp create_owned(scope, input, id, audit, product) do
    %{
      "group_id" => scope.group_id,
      "role" => "worker",
      "name" => input["name"],
      "management_purpose" => input["purpose"],
      "management_creation_audit" => audit,
      "runtime_config" => %{"kind" => "internal"}
    }
    |> Map.merge(product)
    |> Control.create_owned_preallocated(scope.tenant_id, id)
  end

  defp writable(record) do
    cond do
      Control.permanently_archived?(record) -> {:error, :agent_permanently_archived}
      Control.archived?(record) -> {:error, :agent_archived}
      true -> :ok
    end
  end

  defp list_key("cursor"), do: :cursor
  defp list_key("limit"), do: :limit
  defp list_key("lifecycle"), do: :lifecycle
  defp list_key("runtime_source"), do: :runtime_source
  defp list_key("runtime_provider"), do: :runtime_provider

  # Invocation identity comes from the host tool call, never model parameters.
  defp invocation(scope, ctx, operation) do
    values = [
      scope.tenant_id,
      scope.group_id,
      ctx[:agent_id],
      ctx[:session_id],
      ctx[:tool_call_id],
      operation
    ]

    if Enum.all?(values, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 512)),
      do: {:ok, Jason.encode!(values)},
      else: {:error, :invalid_arguments}
  end
end
