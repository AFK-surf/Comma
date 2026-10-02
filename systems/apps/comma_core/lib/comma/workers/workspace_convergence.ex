defmodule Comma.Workers.WorkspaceConvergence do
  @moduledoc """
  Converges one generation of a Comma workspace into Billing and Salix.

  The operation id is the only durable job argument. Provider identity comes
  from the workspace's stable billing and Salix ids, while the operation row
  owns retry, terminal failure, and generation fencing.

  Synchronicity's remote-present/local-missing retry boundary is modeled in
  `tla/comma_synchronicity/WorkspaceProvisioning.tla`.
  """

  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 12,
    unique: [period: :infinity, fields: [:worker, :queue, :args]]

  alias Comma.Data.{ExternalOperation, Workspace}
  alias Comma.{Operations, Repo}

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"operation_id" => operation_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case run(operation_id, final_attempt?: attempt >= max_attempts) do
      {:ok, _operation} -> :ok
      {:complete, _operation} -> :ok
      {:busy, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, "workspace_convergence:" <> classify(reason)}
    end
  end

  @doc false
  def run(operation_id, opts \\ []) when is_binary(operation_id) do
    final_attempt? = Keyword.get(opts, :final_attempt?, false)

    with %ExternalOperation{} = operation <- Repo.get(ExternalOperation, operation_id),
         %Workspace{} = workspace <- Repo.get(Workspace, operation.owner_id),
         desired_generation <- desired_generation(operation),
         {:ok, claim} <- Operations.claim(operation_id, desired_generation) do
      execute_claim(claim, workspace, final_attempt?)
    else
      nil -> {:error, :workspace_operation_not_found}
      {:error, :not_due} -> {:busy, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_claim({:complete, operation}, _workspace, _final_attempt?),
    do: {:complete, operation}

  defp execute_claim({:superseded, operation}, _workspace, _final_attempt?),
    do: {:complete, operation}

  defp execute_claim({:execute, operation}, _workspace, final_attempt?) do
    case current_workspace(operation) do
      {:ok, current} ->
        converge(operation, current, final_attempt?)

      {:superseded, operation} ->
        {:complete, operation}

      {:error, reason} ->
        record_failure(operation, reason, final_attempt?)
    end
  end

  defp current_workspace(operation) do
    case {Repo.get(Workspace, operation.owner_id), desired_generation(operation)} do
      {%Workspace{} = workspace, generation} when generation == operation.generation ->
        {:ok, workspace}

      {%Workspace{}, generation} ->
        case Operations.claim(operation.operation_id, generation) do
          {:ok, {:superseded, superseded}} -> {:superseded, superseded}
          {:ok, {:complete, complete}} -> {:superseded, complete}
          {:error, reason} -> {:error, reason}
        end

      {nil, _generation} ->
        {:error, :workspace_not_found}
    end
  end

  defp converge(operation, workspace, final_attempt?) do
    payload = workspace_payload(workspace, operation)

    result =
      try do
        with :ok <- ensure_billing(payload),
             :ok <- Comma.Billing.SignupCredits.ensure(payload),
             :ok <- ensure_selfhost_entitlement(payload),
             :ok <- Comma.Salix.Client.impl().provision_workspace_scope(payload),
             :ok <- maybe_update_vm(payload, operation),
             :ok <- ensure_synchronicity(workspace) do
          :ok
        end
      rescue
        exception -> {:error, {:provider_exception, exception.__struct__}}
      end

    case result do
      :ok ->
        acknowledge_success(operation, workspace)

      {:error, reason} ->
        record_failure(operation, reason, final_attempt?)
    end
  end

  defp acknowledge_success(operation, workspace) do
    Repo.transaction(fn ->
      current =
        Repo.one(
          from(candidate in Workspace,
            where: candidate.id == ^workspace.id,
            lock: "FOR UPDATE"
          )
        )

      case {current, desired_generation(operation)} do
        {%Workspace{} = current, generation} when generation == operation.generation ->
          if operation.generation == 1 and current.status == "provisioning" do
            current
            |> Ecto.Changeset.change(status: "active")
            |> Repo.update!()
          end

          case Operations.succeed(
                 operation.operation_id,
                 operation.generation,
                 workspace.salix_group_id,
                 %{"provider_status" => "ready"}
               ) do
            {:ok, {:updated, succeeded}} -> {:ok, succeeded}
            {:ok, {:complete, complete}} -> {:complete, complete}
            {:error, reason} -> Repo.rollback(reason)
          end

        {%Workspace{}, generation} ->
          case Operations.claim(operation.operation_id, generation) do
            {:ok, {_kind, superseded}} -> {:complete, superseded}
            {:error, reason} -> Repo.rollback(reason)
          end

        {nil, _generation} ->
          Repo.rollback(:workspace_not_found)
      end
    end)
    |> case do
      {:ok, {:ok, succeeded}} ->
        {:ok, succeeded}

      {:ok, {:complete, complete}} ->
        {:complete, complete}

      {:error, :workspace_not_found} ->
        record_failure(operation, :workspace_not_found, true)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp desired_generation(operation) do
    Repo.one(
      from(candidate in ExternalOperation,
        where:
          candidate.operation_type == ^operation.operation_type and
            candidate.owner_type == ^operation.owner_type and
            candidate.owner_id == ^operation.owner_id,
        select: max(candidate.generation)
      )
    ) || operation.generation
  end

  defp ensure_billing(workspace) do
    BillingCore.Accounts.ensure_account(%{
      billing_account_id: workspace["billing_account_id"],
      enforce_product_owner_identity: true,
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: workspace["id"]
    })
  end

  defp ensure_selfhost_entitlement(workspace) do
    if Application.get_env(:comma_core, :selfhost, false) do
      case BillingCore.Credits.issue_grant(%{
             repo: BillingCore.Repo,
             billing_account_id: workspace["billing_account_id"],
             idempotency_key: "selfhost:unlimited:v1",
             source_type: "selfhost",
             source_id: workspace["id"],
             credits: 0,
             valid_from: ~U[2020-01-01 00:00:00Z],
             expires_at: ~U[9999-12-31 23:59:59Z],
             policy_snapshot: %{"usage_credits" => %{"mode" => "unlimited_metered"}}
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp maybe_update_vm(_workspace, %{generation: 1}), do: :ok

  defp maybe_update_vm(%{"vm" => vm} = workspace, _operation) when is_map(vm),
    do: Comma.Salix.Client.impl().update_workspace_vm(workspace, vm)

  defp maybe_update_vm(_workspace, _operation), do: :ok

  defp workspace_payload(workspace, operation) do
    vm =
      if workspace.vm_recreate_generation == operation.generation and is_map(workspace.vm) do
        Map.put(workspace.vm, "recreate", true)
      else
        workspace.vm
      end

    %{
      "id" => workspace.id,
      "name" => workspace.name,
      "owner_user_id" => workspace.owner_user_id,
      "billing_account_id" => workspace.billing_owner_id,
      "salix_tenant_id" => workspace.salix_tenant_id,
      "default_group_id" => workspace.salix_group_id,
      "router_agent_id" => workspace.salix_router_agent_id,
      "default_worker_agent_id" => workspace.salix_worker_agent_id,
      "kind" => workspace.kind,
      "vm" => vm,
      "provisioning_generation" => operation.generation,
      "provisioning_idempotency_key" => operation.external_idempotency_key
    }
  end

  defp record_failure(operation, reason, final_attempt?) do
    error_class = classify(reason)

    if terminal?(reason) or final_attempt? do
      terminal_failure(
        operation,
        if(final_attempt?, do: "retry_exhausted", else: error_class)
      )
    else
      delay = retry_delay(operation.attempt)
      next_attempt_at = DateTime.add(DateTime.utc_now(), delay, :second)

      case Operations.retryable(
             operation.operation_id,
             operation.generation,
             error_class,
             next_attempt_at
           ) do
        {:ok, {_kind, _retryable}} -> {:error, error_atom(error_class)}
        {:error, transition_reason} -> {:error, transition_reason}
      end
    end
  end

  defp terminal_failure(operation, error_class) do
    Repo.transaction(fn ->
      workspace =
        Repo.one(
          from(candidate in Workspace,
            where: candidate.id == ^operation.owner_id,
            lock: "FOR UPDATE"
          )
        )

      if operation.generation == 1 and match?(%Workspace{status: "provisioning"}, workspace) do
        workspace
        |> Ecto.Changeset.change(status: "provisioning_failed")
        |> Repo.update!()
      end

      case Operations.terminal_failed(
             operation.operation_id,
             operation.generation,
             error_class,
             %{"provider_status" => "failed"}
           ) do
        {:ok, {_kind, failed}} -> failed
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, failed} -> {:error, error_atom(failed.last_error_class)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Provisions the Workspace's Synchronicity org + default network and stores
  # the returned ids on the Workspace. Off (a no-op) unless the integration is
  # configured, so convergence is unchanged where Synchronicity is not in use.
  # A guest's placeholder email never leaves Comma.
  defp ensure_synchronicity(%Workspace{kind: "guest"}), do: :ok

  defp ensure_synchronicity(workspace) do
    if Comma.Synchronicity.configured?() do
      with {:ok, _result} <-
             synchronicity_outcome(Comma.Synchronicity.provision_workspace(workspace)),
           {:ok, _key} <- synchronicity_outcome(Comma.Synchronicity.ensure_agent_key(workspace)) do
        :ok
      end
    else
      :ok
    end
  end

  # Flattens the Synchronicity client's error set into this worker's atoms;
  # only `:synchronicity_unavailable` stays retryable (`terminal?/1`).
  defp synchronicity_outcome(result) do
    case result do
      {:ok, _} = ok -> ok
      {:error, :explicit_link_required} -> {:error, :synchronicity_link_required}
      {:error, :auth} -> {:error, :synchronicity_auth}
      {:error, :owner_not_found} -> {:error, :synchronicity_owner_missing}
      {:error, :workspace_not_found} -> {:error, :workspace_not_found}
      {:error, :not_provisioned} -> {:error, :synchronicity_invalid}
      {:error, :not_configured} -> {:error, :synchronicity_invalid}
      {:error, {:invalid, _reason}} -> {:error, :synchronicity_invalid}
      {:error, {:retryable, _reason}} -> {:error, :synchronicity_unavailable}
    end
  end

  defp terminal?(reason),
    do:
      reason in [
        :billing_account_surface_mismatch,
        :invalid_workspace_configuration,
        :missing_billing_account_id,
        :workspace_not_found,
        :synchronicity_link_required,
        :synchronicity_auth,
        :synchronicity_owner_missing,
        :synchronicity_invalid
      ]

  defp classify({:provider_exception, module}) when is_atom(module),
    do: "provider_exception"

  defp classify(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.slice(0, 128)

  defp classify(_reason), do: "provider_unavailable"

  defp error_atom(error_class) do
    String.to_existing_atom(error_class)
  rescue
    ArgumentError -> :workspace_provisioning_failed
  end

  defp retry_delay(attempt), do: min(300, trunc(:math.pow(2, min(attempt, 8))))
end
