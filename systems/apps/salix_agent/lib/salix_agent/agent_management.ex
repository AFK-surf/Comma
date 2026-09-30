defmodule SalixAgent.AgentManagement do
  @moduledoc "Synchronous Router commands. The caller owns retries; no command worker or desired-state copy."
  alias SalixAgent.Control
  alias SalixAgent.AgentManagement.{Error, Ports, Projection, Targets}
  alias SalixStore.{CasRecord, Ids, Keys}

  def run(operation, args, ctx) do
    with {:ok, args} <- SalixAgent.Tools.AgentManagement.normalize(operation, args),
         {:ok, caller} <- router(ctx),
         :ok <- admit(operation),
         {:ok, result} <- dispatch(operation, args, ctx, caller) do
      {:ok, result}
    else
      {:error, reason} -> {:error, Error.public(reason)}
    end
  rescue
    _ ->
      {:error,
       Error.public(
         if(operation in [:get, :list], do: :read_unavailable, else: :mutation_outcome_unknown)
       )}
  end

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

  defp admit(operation) when operation in [:list, :get], do: :ok
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

  defp dispatch(:list, args, _ctx, caller) do
    opts = Enum.map(args, fn {key, value} -> {list_key(key), value} end)

    with {:ok, page} <- Control.page_workers(caller["tenant_id"], caller["group_id"], opts) do
      {:ok,
       %{
         "items" => Enum.map(page.items, &Projection.summary/1),
         "returned_count" => page.returned_count,
         "next_cursor" => page.next_cursor
       }}
    end
  end

  defp dispatch(:archive, %{"user_confirmed" => false}, _ctx, _caller),
    do: {:error, :user_confirmation_required}

  defp dispatch(operation, args, ctx, caller) do
    command(%{tenant_id: caller["tenant_id"], group_id: caller["group_id"]}, operation, args, ctx)
  end

  defp get(scope, id) do
    with true <- Ids.valid_agent_id_for_group?(id, scope.group_id),
         {:ok, record} <- Control.get_including_archived(id, scope.tenant_id),
         true <- record["group_id"] == scope.group_id and record["role"] == "worker" do
      {:ok, record}
    else
      false -> {:error, :agent_not_found}
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

  defp command(scope, :rebind, args, ctx) do
    with {:ok, record} <- get(scope, args["agent_id"]),
         :ok <- writable(record),
         true <- Control.external_runtime?(record),
         {:ok, target} <- Targets.resolve(scope, args["target"]),
         true <- target["kind"] != "internal",
         {:ok, invocation} <- invocation(scope, ctx, "rebind"),
         {:ok, %{record: updated, result: result}} <-
           Control.rebind_external_worker(
             record["agent_id"],
             scope.tenant_id,
             target,
             args["expected_binding_revision"],
             invocation
           ) do
      {:ok, %{"result" => Atom.to_string(result), "agent" => Projection.detail(updated)}}
    else
      false -> {:error, :unsupported_agent_kind}
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
         {:ok, template} <- worker_template(runtime, scope),
         {:ok, record} <-
           Control.create_owned_preallocated(
             %{
               "group_id" => scope.group_id,
               "role" => "worker",
               "name" => input["name"],
               "management_purpose" => input["purpose"],
               "management_creation_audit" => audit,
               "template_id" => template,
               "runtime_config" => Targets.with_revision(runtime, 1)
             },
             scope.tenant_id,
             id
           ) do
      {:ok, %{"result" => "applied", "replayed" => false, "agent" => Projection.detail(record)}}
    else
      {:error, reason} -> {:error, {:creation_failed, id, reason}}
    end
  end

  defp writable(record) do
    cond do
      Control.permanently_archived?(record) -> {:error, :agent_permanently_archived}
      Control.archived?(record) -> {:error, :agent_archived}
      true -> :ok
    end
  end

  defp worker_template(%{"kind" => "internal"}, scope), do: Ports.worker_template(scope)
  defp worker_template(_, _), do: {:ok, nil}
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
