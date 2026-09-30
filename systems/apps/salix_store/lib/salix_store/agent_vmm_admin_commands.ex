defmodule SalixStore.AgentVMMAdminCommands do
  @moduledoc """
  Exact, tenant-scoped Comma Admin commands for Agent VMM owners.

  The immutable receipt proves that one audited command committed. Business
  state remains owned by the existing installation, registration, and
  environment writers.

  Modeled in `tla/salix/AgentVMMAdminCommandReceipt.tla` and the cross-Repo
  `tla/salix/AgentVMMAdminCommandOrchestration.tla`.
  """

  import Ecto.Query

  alias SalixStore.{AgentVMM, AgentVMMInstallations, Compute, Repo}

  @actions ~w(
    retry_agent_vmm_install
    enable_agent_vmm_registration
    disable_agent_vmm_registration
    revoke_agent_vmm_registration
    drain_compute_environment
    revoke_compute_environment
    create_shell_workload
  )

  def actions, do: @actions

  defmodule Receipt do
    use Ecto.Schema
    @primary_key false

    schema "agent_vmm_admin_command_receipts" do
      field(:command_id, Ecto.UUID, primary_key: true)
      field(:action, :string)
      field(:tenant_id, :string)
      field(:target, :string)
      field(:fingerprint, :binary)
      field(:result_revision, :integer)
    end
  end

  @type command :: %{
          action: String.t(),
          tenant_id: String.t(),
          target_id: String.t(),
          expected_revision: non_neg_integer()
        }

  @spec execute(Ecto.UUID.t(), command()) ::
          {:ok, map()} | {:already_applied, map()} | {:error, atom() | tuple()}
  def execute(command_id, %{action: action} = command)
      when is_binary(command_id) and action in @actions do
    with {:ok, _} <- Ecto.UUID.cast(command_id),
         :ok <- validate_command(command) do
      Repo.transaction(fn ->
        lock_command!(command_id)
        fingerprint = fingerprint(command)
        target = target_key(action, command.target_id)

        case Repo.get(Receipt, command_id) do
          %Receipt{} = receipt ->
            if receipt.action == action and receipt.tenant_id == command.tenant_id and
                 receipt.target == target and receipt.fingerprint == fingerprint do
              {:already_applied, public_result(receipt)}
            else
              Repo.rollback(:idempotency_conflict)
            end

          nil ->
            result_revision = apply_command!(Map.put(command, :command_id, command_id))

            %Receipt{
              command_id: command_id,
              action: action,
              tenant_id: command.tenant_id,
              target: target,
              fingerprint: fingerprint,
              result_revision: result_revision
            }
            |> Repo.insert!()
            |> public_result()
        end
      end)
      |> normalize_result()
    end
  end

  def execute(_command_id, _command), do: {:error, :invalid_command}

  @spec replay_receipt(Ecto.UUID.t(), command()) ::
          {:already_applied, map()} | {:error, atom()}
  def replay_receipt(command_id, %{action: action} = command)
      when is_binary(command_id) and action in @actions do
    with {:ok, _} <- Ecto.UUID.cast(command_id),
         :ok <- validate_command(command) do
      fingerprint = fingerprint(command)
      target = target_key(action, command.target_id)

      case Repo.get(Receipt, command_id) do
        %Receipt{} = receipt
        when receipt.action == action and receipt.tenant_id == command.tenant_id and
               receipt.target == target and receipt.fingerprint == fingerprint ->
          {:already_applied, public_result(receipt)}

        %Receipt{} ->
          {:error, :idempotency_conflict}

        nil ->
          {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def replay_receipt(_command_id, _command), do: {:error, :invalid_command}

  defp apply_command!(%{action: "create_shell_workload"} = command) do
    environment =
      Repo.one(
        from(e in Compute.Environment, where: e.id == ^command.target_id, lock: "FOR UPDATE")
      )

    with %Compute.Environment{tenant_id: tenant, revision: revision} <- environment,
         true <- tenant == command.tenant_id || {:error, :not_found},
         true <- revision == command.expected_revision || {:error, :revision_conflict},
         {:ok, _placed} <-
           Compute.place_workload(%{
             tenant_id: command.tenant_id,
             environment_id: command.target_id,
             allocation_id: "allocation_" <> command.command_id,
             workload_id: "workload_" <> command.command_id,
             kind: "shell",
             template_key: "shell.default",
             capability_requirements: ["runtime_exec"]
           }) do
      revision
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_command!(%{
         action: "retry_agent_vmm_install",
         tenant_id: tenant_id,
         target_id: operation_id,
         expected_revision: revision
       }) do
    operation =
      Repo.one(
        from(o in AgentVMMInstallations.Operation,
          where: o.id == ^operation_id and o.tenant_id == ^tenant_id,
          select: %{
            id: o.id,
            delivery_target_type: o.delivery_target_type,
            authorization_status: o.authorization_status,
            error_code: o.error_code,
            material_handed_off_at: o.material_handed_off_at
          }
        )
      ) || Repo.rollback(:not_found)

    unless admin_retryable_install?(operation),
      do: Repo.rollback(:install_retry_not_available)

    case AgentVMMInstallations.retry_at_revision(operation.id, revision) do
      {:ok, %{operation: %{revision: result_revision}}} -> result_revision
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_command!(%{action: action} = command)
       when action in ~w(enable_agent_vmm_registration disable_agent_vmm_registration) do
    enabled = action == "enable_agent_vmm_registration"

    case AgentVMM.configure_registration(
           command.target_id,
           command.expected_revision,
           enabled
         ) do
      {:ok, %{tenant_id: tenant_id, revision: revision}} when tenant_id == command.tenant_id ->
        revision

      {:ok, _wrong_tenant} ->
        Repo.rollback(:not_found)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp apply_command!(%{action: "revoke_agent_vmm_registration"} = command) do
    case AgentVMM.revoke_registration(
           command.tenant_id,
           command.target_id,
           command.expected_revision
         ) do
      {:ok, %{revision: revision}} -> revision
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_command!(%{action: action} = command)
       when action in ~w(drain_compute_environment revoke_compute_environment) do
    desired_state = if action == "drain_compute_environment", do: "draining", else: "revoked"

    case Compute.update_environment_intent(command.target_id, command.expected_revision, %{
           desired_state: desired_state
         }) do
      {:ok, %{tenant_id: tenant_id, revision: revision}} when tenant_id == command.tenant_id ->
        revision

      {:ok, _wrong_tenant} ->
        Repo.rollback(:not_found)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp validate_command(%{
         action: action,
         tenant_id: tenant_id,
         target_id: target_id,
         expected_revision: revision
       })
       when action in @actions and is_binary(tenant_id) and tenant_id != "" and
              is_binary(target_id) and target_id != "" and is_integer(revision) and revision >= 0,
       do: :ok

  defp validate_command(_command), do: {:error, :invalid_command}

  defp admin_retryable_install?(operation) do
    operation.delivery_target_type == "bft_runner" and
      operation.authorization_status == "action_required" and
      operation.error_code == "ticket_retry_exhausted" and
      is_nil(operation.material_handed_off_at)
  end

  defp fingerprint(command) do
    :crypto.hash(
      :sha256,
      Jason.encode!([
        command.action,
        command.tenant_id,
        command.target_id,
        command.expected_revision
      ])
    )
  end

  defp target_key(action, target_id), do: action_target_type(action) <> ":" <> target_id
  defp action_target_type("retry_agent_vmm_install"), do: "installation"

  defp action_target_type(action)
       when action in ~w(drain_compute_environment revoke_compute_environment create_shell_workload),
       do: "environment"

  defp action_target_type(_action), do: "registration"

  defp lock_command!(command_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["agent-vmm-admin:" <> command_id])
  end

  defp public_result(receipt) do
    %{
      action: receipt.action,
      target: receipt.target,
      result_revision: receipt.result_revision,
      accepted: true
    }
  end

  defp normalize_result({:ok, {:already_applied, result}}),
    do: {:already_applied, result}

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
end
