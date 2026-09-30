defmodule SalixStore.AgentVMMInstallations do
  @moduledoc """
  Durable product-authorized Agent VMM registration install operation.

  One row owns the authorization binding, current ticket generation, and the
  bounded encrypted exchange result. The helper must durably persist the
  result before acknowledging the handoff.

  Handoff is modeled in `tla/salix/VMMInstallHandoff.tla`. Admin revision
  fencing and the database-owned monotonic writer invariant are modeled in
  `tla/salix/AgentVMMAdminCommandOrchestration.tla`.
  """

  import Ecto.Query

  alias SalixStore.{AgentVMM, Compute, ComputeContract, Crypto, Repo}

  @ticket_ttl_seconds 15 * 60
  @handoff_ttl_seconds 15 * 60
  @max_ticket_generation 4
  @max_material_bytes 512_000
  @max_expiry_batch 100

  defmodule Operation do
    use Ecto.Schema
    @primary_key false

    schema "agent_vmm_install_operations" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:surface, :string)
      field(:scope_key, :string)
      field(:client_request_id, :string)
      field(:provider, :string)
      field(:environment_id, :string)
      field(:delivery_target_type, :string)
      field(:delivery_target_id, :string)
      field(:registration_id, :string)
      field(:authorization_status, :string)
      field(:revision, :integer)
      field(:ticket_generation, :integer)
      field(:ticket_secret_hash, :binary)
      field(:ticket_status, :string)
      field(:ticket_expires_at, :utc_datetime_usec)
      field(:ticket_consumed_at, :utc_datetime_usec)
      field(:host_identity_digest, :binary)
      field(:material_ciphertext, :string)
      field(:material_handoff_expires_at, :utc_datetime_usec)
      field(:material_handed_off_at, :utc_datetime_usec)
      field(:error_code, :string)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  @type descriptor :: %{
          operation: map(),
          one_time_secret: String.t(),
          expires_at: DateTime.t()
        }

  @doc "Create or rotate one idempotent install operation's current ticket."
  @spec request(map(), keyword()) :: {:ok, descriptor()} | {:error, atom() | tuple()}
  def request(attrs, opts \\ []) when is_map(attrs) do
    observe_mutation(telemetry_surface(Map.get(attrs, :surface)), fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      with :ok <- validate_request(attrs) do
        Repo.transaction(fn ->
          lock_idempotency!(attrs.surface, attrs.scope_key, attrs.client_request_id)

          case operation_by_request(attrs.surface, attrs.scope_key, attrs.client_request_id) do
            nil -> create_operation!(attrs, now)
            %Operation{} = operation -> rotate_for_request!(operation, attrs, now)
          end
        end)
        |> normalize_transaction()
      end
    end)
  end

  @doc "Return a secret-free operation projection."
  @spec get(String.t()) :: {:ok, map()} | {:error, atom()}
  def get(operation_id) when is_binary(operation_id) do
    case Repo.get(Operation, operation_id) do
      %Operation{} = operation -> {:ok, project(operation)}
      nil -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Rotate one requested ticket or reopen the same pre-handoff ticket-budget exhaustion."
  @spec retry(String.t(), keyword()) :: {:ok, descriptor()} | {:error, atom() | tuple()}
  def retry(operation_id, opts \\ []) when is_binary(operation_id) do
    observe_mutation("system", fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)

        cond do
          operation.authorization_status == "requested" ->
            rotate_for_delivery!(operation, now)

          operation.authorization_status == "action_required" and
            operation.error_code == "ticket_retry_exhausted" and
              is_nil(operation.material_handed_off_at) ->
            reopen_pre_handoff!(operation, now)

          true ->
            Repo.rollback(:operation_not_retryable)
        end
      end)
      |> normalize_transaction()
    end)
  end

  @doc "Retry one install operation only at the exact observed revision."
  def retry_at_revision(operation_id, expected_revision, opts \\ [])
      when is_binary(operation_id) and is_integer(expected_revision) do
    observe_mutation("comma_admin", fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)

        if operation.revision != expected_revision do
          Repo.rollback(:revision_conflict)
        end

        cond do
          operation.authorization_status == "requested" ->
            rotate_for_delivery!(operation, now)

          operation.authorization_status == "action_required" and
            operation.error_code == "ticket_retry_exhausted" and
              is_nil(operation.material_handed_off_at) ->
            reopen_pre_handoff!(operation, now)

          true ->
            Repo.rollback(:operation_not_retryable)
        end
      end)
      |> normalize_transaction()
    end)
  end

  @doc "Rotate and return at most one pending descriptor for one exact authenticated delivery target."
  def deliver_next(delivery_target_type, delivery_target_id, opts \\ [])

  def deliver_next(delivery_target_type, delivery_target_id, opts)
      when is_binary(delivery_target_type) and is_binary(delivery_target_id) do
    observe_mutation("system", fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      Repo.transaction(fn ->
        operation =
          Repo.one(
            from(o in Operation,
              where:
                o.delivery_target_type == ^delivery_target_type and
                  o.delivery_target_id == ^delivery_target_id and
                  o.authorization_status == "requested" and
                  o.ticket_status in ["active", "expired"],
              order_by: [asc: o.created_at, asc: o.id],
              limit: 1,
              lock: "FOR UPDATE SKIP LOCKED"
            )
          )

        case operation do
          nil -> Repo.rollback(:no_pending_operation)
          %Operation{} -> rotate_for_delivery!(operation, now)
        end
      end)
      |> normalize_transaction()
    end)
  end

  def deliver_next(_, _, _), do: {:error, :invalid_delivery_target}

  @doc "Fail one exact delivered operation after a runner reaches a terminal local install error."
  def report_delivery_failure(delivery_target_type, delivery_target_id, operation_id, error_code)
      when is_binary(delivery_target_type) and is_binary(delivery_target_id) and
             is_binary(operation_id) and is_binary(error_code) do
    if byte_size(error_code) in 1..128 and
         Regex.match?(~r/\A[a-z0-9][a-z0-9_.-]*\z/, error_code) do
      observe_mutation("system", fn ->
        now = DateTime.utc_now()

        Repo.transaction(fn ->
          operation = lock_operation!(operation_id)

          if operation.delivery_target_type != delivery_target_type or
               operation.delivery_target_id != delivery_target_id do
            Repo.rollback(:delivery_target_mismatch)
          end

          case operation.authorization_status do
            status when status in ["action_required", "revoked"] ->
              project(operation)

            status when status in ["requested", "exchange_committed"] ->
              if status == "exchange_committed" do
                revoke_bound_registration!(operation)
              end

              update_operation!(operation.id,
                authorization_status: "action_required",
                ticket_status: "revoked",
                material_ciphertext: nil,
                material_handoff_expires_at: nil,
                error_code: error_code,
                updated_at: now
              )
              |> project()

            "handed_off" ->
              revoke_bound_registration!(operation)

              update_operation!(operation.id,
                ticket_status: "revoked",
                material_ciphertext: nil,
                material_handoff_expires_at: nil,
                error_code: error_code,
                updated_at: now
              )
              |> project()
          end
        end)
        |> normalize_transaction()
      end)
    else
      {:error, :invalid_failure_code}
    end
  end

  def report_delivery_failure(_, _, _, _), do: {:error, :invalid_delivery_failure}

  @doc "Return one bounded page of secret-free desired registration controls for an exact target."
  def control_page(delivery_target_type, delivery_target_id, cursor \\ nil, limit \\ 32)

  def control_page(delivery_target_type, delivery_target_id, cursor, limit)
      when is_binary(delivery_target_type) and is_binary(delivery_target_id) and
             (is_nil(cursor) or is_binary(cursor)) and is_integer(limit) and limit in 1..32 do
    cursor = if cursor in [nil, ""], do: nil, else: cursor

    if is_binary(cursor) and byte_size(cursor) > 200 do
      {:error, :invalid_control_cursor}
    else
      query =
        from(o in Operation,
          join: r in AgentVMM.Registration,
          on:
            r.id == o.registration_id and r.tenant_id == o.tenant_id and
              r.group_id == o.group_id,
          where:
            o.delivery_target_type == ^delivery_target_type and
              o.delivery_target_id == ^delivery_target_id and
              o.authorization_status == "handed_off" and r.status != "revoked",
          order_by: [asc: o.id],
          limit: ^limit,
          select: {o.id, r.id, r.revision, r.desired_enabled, r.status}
        )

      query = if is_binary(cursor), do: from([o, _r] in query, where: o.id > ^cursor), else: query
      rows = Repo.all(query)

      controls =
        Enum.map(rows, fn {operation_id, registration_id, revision, desired_enabled, status} ->
          %{
            operation_id: operation_id,
            registration_id: registration_id,
            registration_revision: revision,
            state: if(desired_enabled and status != "revoked", do: "enabled", else: "draining")
          }
        end)

      next_cursor = if length(rows) == limit, do: rows |> List.last() |> elem(0), else: nil
      {:ok, %{controls: controls, next_cursor: next_cursor}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def control_page(_, _, _, _), do: {:error, :invalid_delivery_target}

  @doc "Exchange the operation capability or recover its fixed result for the bound Host."
  def exchange(operation_id, secret, host_identity, issuer, opts \\ [])
      when is_binary(operation_id) and is_binary(secret) and is_map(host_identity) and
             is_function(issuer, 2) do
    observe_mutation("system", fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      with {:ok, normalized_identity} <- normalize_host_identity(host_identity) do
        host_digest = identity_digest(normalized_identity)

        Repo.transaction(fn ->
          operation = lock_operation!(operation_id)

          if not secure_equal?(operation.ticket_secret_hash, digest(secret)) do
            Repo.rollback(:invalid_ticket)
          end

          case operation.ticket_status do
            "active" ->
              exchange_active!(
                operation,
                normalized_identity,
                host_digest,
                issuer,
                now
              )

            "consumed" ->
              recover_consumed!(operation, host_digest, now)

            "expired" ->
              Repo.rollback(:ticket_expired)

            "revoked" ->
              Repo.rollback(:ticket_revoked)
          end
        end)
        |> normalize_transaction()
      end
    end)
  end

  @doc "Acknowledge that the helper durably persisted the fixed exchange result."
  def acknowledge(operation_id, secret, host_digest, opts \\ [])
      when is_binary(operation_id) and is_binary(secret) and is_binary(host_digest) do
    observe_mutation("system", fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      do_acknowledge(operation_id, secret, host_digest, now)
    end)
  end

  defp do_acknowledge(operation_id, secret, host_digest, now) do
    if byte_size(host_digest) == 32 do
      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)
        verify_handoff_identity!(operation, secret, host_digest)

        case operation.authorization_status do
          "exchange_committed" -> acknowledge_committed!(operation, now)
          "handed_off" -> project(operation)
          "action_required" -> Repo.rollback(:handoff_expired)
          "revoked" -> Repo.rollback(:ticket_revoked)
          "requested" -> Repo.rollback(:exchange_not_committed)
        end
      end)
      |> normalize_transaction()
    else
      {:error, :invalid_host_identity}
    end
  end

  @doc "Close an authorization or revoke its exact handed-off registration."
  def revoke(operation_id, opts \\ []) when is_binary(operation_id) do
    observe_mutation("system", fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)

        case operation.authorization_status do
          "revoked" ->
            project(operation)

          "handed_off" ->
            # Handoff is terminal in the authorization protocol. Product
            # removal acts on the exact registration/binding lifecycle without
            # reopening or rewriting that terminal operation.
            revoke_bound_registration!(operation)
            Operation |> Repo.get!(operation.id) |> project()

          _ ->
            revoke_bound_registration!(operation)

            update_operation!(operation.id,
              authorization_status: "revoked",
              ticket_status: "revoked",
              material_ciphertext: nil,
              material_handoff_expires_at: nil,
              updated_at: now
            )
            |> project()
        end
      end)
      |> normalize_transaction()
    end)
  end

  @doc "Enable or disable one exact handed-off registration without changing authorization history."
  def configure_registration(operation_id, enabled)
      when is_binary(operation_id) and is_boolean(enabled) do
    observe_mutation("system", fn ->
      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)

        if operation.authorization_status != "handed_off" do
          Repo.rollback(:installation_not_handed_off)
        end

        registration =
          Repo.one(
            from(r in AgentVMM.Registration,
              where:
                r.id == ^operation.registration_id and
                  r.tenant_id == ^operation.tenant_id and
                  r.group_id == ^operation.group_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:registration_not_found)

        cond do
          registration.status == "revoked" ->
            Repo.rollback(:terminal_registration)

          registration.desired_enabled == enabled ->
            project(operation)

          true ->
            case AgentVMM.configure_registration(registration.id, registration.revision, enabled) do
              {:ok, _registration} -> project(operation)
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
      |> normalize_transaction()
    end)
  end

  @doc "Close a bounded batch of expired, unacknowledged material handoffs."
  def expire_handoffs(opts \\ []) do
    observe_mutation("system", fn ->
      now = Keyword.get(opts, :now, DateTime.utc_now())
      limit = opts |> Keyword.get(:limit, @max_expiry_batch) |> min(@max_expiry_batch) |> max(1)

      Repo.transaction(fn ->
        ids =
          Repo.all(
            from(o in Operation,
              where:
                o.authorization_status == "exchange_committed" and
                  o.material_handoff_expires_at <= ^now,
              order_by: [asc: o.material_handoff_expires_at, asc: o.id],
              limit: ^limit,
              select: o.id,
              lock: "FOR UPDATE SKIP LOCKED"
            )
          )

        {count, _} =
          Repo.update_all(from(o in Operation, where: o.id in ^ids),
            set: [
              authorization_status: "action_required",
              error_code: "material_handoff_expired",
              material_ciphertext: nil,
              material_handoff_expires_at: nil,
              updated_at: now
            ]
          )

        count
      end)
      |> normalize_transaction()
    end)
  end

  defp create_operation!(attrs, now) do
    secret = new_secret()
    operation_id = new_id("vmm_install")
    expires_at = DateTime.add(now, @ticket_ttl_seconds, :second)

    {1, _} =
      Repo.insert_all(Operation, [
        %{
          id: operation_id,
          tenant_id: attrs.tenant_id,
          group_id: attrs.group_id,
          surface: attrs.surface,
          scope_key: attrs.scope_key,
          client_request_id: attrs.client_request_id,
          provider: attrs.provider,
          environment_id: attrs.environment_id,
          delivery_target_type: attrs.delivery_target_type,
          delivery_target_id: attrs.delivery_target_id,
          registration_id: new_id("vmm_registration"),
          authorization_status: "requested",
          ticket_generation: 1,
          ticket_secret_hash: digest(secret),
          ticket_status: "active",
          ticket_expires_at: expires_at,
          created_at: now,
          updated_at: now
        }
      ])

    descriptor(Repo.get!(Operation, operation_id), secret)
  end

  defp rotate_for_request!(%Operation{authorization_status: "requested"} = operation, attrs, now) do
    if not binding_matches?(operation, attrs) do
      Repo.rollback(:idempotency_conflict)
    end

    rotate_ticket_or_close!(operation, now)
  end

  defp rotate_for_request!(operation, _attrs, _now),
    do: Repo.rollback({:operation_exists, operation.id})

  defp rotate_for_delivery!(operation, now) do
    rotate_ticket_or_close!(operation, now)
  end

  defp rotate_ticket_or_close!(operation, now) do
    if operation.ticket_generation >= @max_ticket_generation do
      update_operation!(operation.id,
        authorization_status: "action_required",
        ticket_status: "revoked",
        error_code: "ticket_retry_exhausted",
        updated_at: now
      )

      {:error, :ticket_retry_exhausted}
    else
      issue_rotated_ticket!(operation, now)
    end
  end

  defp issue_rotated_ticket!(operation, now) do
    secret = new_secret()
    expires_at = DateTime.add(now, @ticket_ttl_seconds, :second)

    operation
    |> then(fn current ->
      update_operation!(current.id,
        ticket_generation: current.ticket_generation + 1,
        ticket_secret_hash: digest(secret),
        ticket_status: "active",
        ticket_expires_at: expires_at,
        ticket_consumed_at: nil,
        updated_at: now
      )
    end)
    |> descriptor(secret)
  end

  defp reopen_pre_handoff!(operation, now) do
    secret = new_secret()
    expires_at = DateTime.add(now, @ticket_ttl_seconds, :second)

    operation
    |> then(fn current ->
      update_operation!(current.id,
        authorization_status: "requested",
        ticket_generation: 1,
        ticket_secret_hash: digest(secret),
        ticket_status: "active",
        ticket_expires_at: expires_at,
        ticket_consumed_at: nil,
        host_identity_digest: nil,
        material_ciphertext: nil,
        material_handoff_expires_at: nil,
        error_code: nil,
        updated_at: now
      )
    end)
    |> descriptor(secret)
  end

  defp exchange_active!(operation, identity, host_digest, issuer, now) do
    if DateTime.compare(operation.ticket_expires_at, now) != :gt do
      update_operation!(operation.id, ticket_status: "expired", updated_at: now)
      {:error, :ticket_expired}
    else
      enrollment_token = :crypto.strong_rand_bytes(32)

      case AgentVMM.create_registration(%{
             id: operation.registration_id,
             tenant_id: operation.tenant_id,
             group_id: operation.group_id,
             device_id: identity.device_id,
             enrollment_token: enrollment_token,
             desired_enabled: true
           }) do
        {:ok, _registration} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      ensure_scoped_provider_binding!(operation)

      material = issue_material!(issuer, operation, identity, enrollment_token)
      encoded = Jason.encode!(material)

      if byte_size(encoded) > @max_material_bytes do
        Repo.rollback(:install_material_too_large)
      end

      ciphertext =
        case Crypto.seal_install_material(encoded) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end

      handoff_expires_at = DateTime.add(now, @handoff_ttl_seconds, :second)

      updated =
        update_operation!(operation.id,
          authorization_status: "exchange_committed",
          ticket_status: "consumed",
          ticket_consumed_at: now,
          host_identity_digest: host_digest,
          material_ciphertext: ciphertext,
          material_handoff_expires_at: handoff_expires_at,
          updated_at: now
        )

      exchange_result(updated, material)
    end
  end

  defp recover_consumed!(operation, host_digest, now) do
    cond do
      operation.authorization_status == "handed_off" ->
        Repo.rollback(:handoff_complete)

      operation.authorization_status == "revoked" ->
        Repo.rollback(:ticket_revoked)

      operation.authorization_status == "action_required" ->
        Repo.rollback(:handoff_expired)

      not secure_equal?(operation.host_identity_digest, host_digest) ->
        Repo.rollback(:host_identity_mismatch)

      is_nil(operation.material_handoff_expires_at) or
          DateTime.compare(operation.material_handoff_expires_at, now) != :gt ->
        close_expired_handoff!(operation, now)
        {:error, :handoff_expired}

      not is_binary(operation.material_ciphertext) ->
        Repo.rollback(:recovery_material_unavailable)

      true ->
        with {:ok, encoded} <- Crypto.unseal_install_material(operation.material_ciphertext),
             {:ok, material} <- Jason.decode(encoded) do
          exchange_result(operation, material)
        else
          _ -> Repo.rollback(:recovery_material_invalid)
        end
    end
  end

  defp acknowledge_committed!(operation, now) do
    if is_nil(operation.material_handoff_expires_at) or
         DateTime.compare(operation.material_handoff_expires_at, now) != :gt do
      close_expired_handoff!(operation, now)
      {:error, :handoff_expired}
    else
      update_operation!(operation.id,
        authorization_status: "handed_off",
        material_ciphertext: nil,
        material_handoff_expires_at: nil,
        material_handed_off_at: now,
        updated_at: now
      )
      |> project()
    end
  end

  defp verify_handoff_identity!(operation, secret, host_digest) do
    cond do
      not secure_equal?(operation.ticket_secret_hash, digest(secret)) ->
        Repo.rollback(:invalid_ticket)

      operation.ticket_status != "consumed" ->
        Repo.rollback(:exchange_not_committed)

      not secure_equal?(operation.host_identity_digest, host_digest) ->
        Repo.rollback(:host_identity_mismatch)

      true ->
        :ok
    end
  end

  defp close_expired_handoff!(operation, now) do
    update_operation!(operation.id,
      authorization_status: "action_required",
      error_code: "material_handoff_expired",
      material_ciphertext: nil,
      material_handoff_expires_at: nil,
      updated_at: now
    )
  end

  defp revoke_bound_registration!(operation) do
    case Repo.get(AgentVMM.Registration, operation.registration_id) do
      nil ->
        :ok

      %AgentVMM.Registration{status: "revoked"} ->
        :ok

      registration ->
        case AgentVMM.revoke_registration(
               operation.tenant_id,
               registration.id,
               registration.revision
             ) do
          {:ok, _registration} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp issue_material!(issuer, operation, identity, enrollment_token) do
    enrollment = %{
      registration_id: operation.registration_id,
      enrollment_token: Base.encode64(enrollment_token),
      host_identity: identity
    }

    case issuer.(project(operation), enrollment) do
      {:ok, value} when is_map(value) -> value
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:invalid_install_material)
    end
  end

  # Operations written before the nullable Environment expansion remain
  # exchangeable while the rollout gate is closed. New scoped requests and
  # bindings remain fenced until every old reader has retired. After the gate
  # opens, a legacy operation fails closed instead of guessing an Environment.
  defp ensure_scoped_provider_binding!(%Operation{environment_id: environment_id} = operation)
       when is_binary(environment_id) do
    environment =
      Repo.one(
        from(e in Compute.Environment,
          where: e.id == ^environment_id,
          lock: "FOR UPDATE"
        )
      )

    case environment do
      %Compute.Environment{
        tenant_id: tenant_id,
        owner_type: "project",
        owner_id: owner_id,
        desired_state: "ready"
      }
      when tenant_id == operation.tenant_id and owner_id == operation.scope_key ->
        :ok

      _ ->
        Repo.rollback(:invalid_install_environment)
    end

    case Compute.ensure_provider_binding(%{
           id: new_id("provider"),
           pool_id: environment.pool_id,
           environment_id: environment_id,
           provider: "agent_vmm",
           provider_ref: operation.registration_id,
           generation: environment.generation
         }) do
      {:ok, _binding} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_scoped_provider_binding!(%Operation{}) do
    if Application.get_env(
         :salix_store,
         :agent_vmm_environment_scoped_bindings_enabled,
         false
       ) do
      Repo.rollback(:environment_scope_required)
    else
      :ok
    end
  end

  defp validate_request(attrs) do
    fields = [
      :tenant_id,
      :group_id,
      :surface,
      :scope_key,
      :client_request_id,
      :provider,
      :environment_id,
      :delivery_target_type,
      :delivery_target_id
    ]

    valid =
      Enum.all?(fields, fn field ->
        value = Map.get(attrs, field)
        is_binary(value) and byte_size(value) in 1..200
      end)

    scope_enabled =
      Application.get_env(
        :salix_store,
        :agent_vmm_environment_scoped_bindings_enabled,
        false
      )

    cond do
      not valid or attrs.surface not in ["comma", "bft"] or attrs.provider != "agent-vmm" ->
        {:error, :invalid_install_request}

      not scope_enabled ->
        {:error, :environment_scope_rollout_pending}

      true ->
        case Repo.get(Compute.Environment, attrs.environment_id) do
          %Compute.Environment{
            tenant_id: tenant_id,
            owner_type: "project",
            owner_id: owner_id,
            desired_state: "ready"
          }
          when tenant_id == attrs.tenant_id and owner_id == attrs.scope_key ->
            :ok

          _ ->
            {:error, :invalid_install_environment}
        end
    end
  end

  defp binding_matches?(operation, attrs) do
    Enum.all?(
      [
        :tenant_id,
        :group_id,
        :surface,
        :scope_key,
        :provider,
        :environment_id,
        :delivery_target_type,
        :delivery_target_id
      ],
      &(Map.fetch!(operation, &1) == Map.fetch!(attrs, &1))
    )
  end

  defp normalize_host_identity(identity) do
    device_id = identity["device_id"] || identity[:device_id]
    root_public_key = identity["root_public_key"] || identity[:root_public_key]
    root_key_revision = identity["root_key_revision"] || identity[:root_key_revision]

    if is_binary(device_id) and byte_size(device_id) in 1..200 and
         is_binary(root_public_key) and byte_size(root_public_key) in 32..512 and
         is_integer(root_key_revision) and root_key_revision > 0 do
      {:ok,
       %{
         device_id: device_id,
         root_public_key: root_public_key,
         root_key_revision: root_key_revision
       }}
    else
      {:error, :invalid_host_identity}
    end
  end

  defp identity_digest(identity) do
    Jason.encode!([
      identity.device_id,
      Base.encode64(identity.root_public_key),
      identity.root_key_revision
    ])
    |> digest()
  end

  defp descriptor(operation, secret) do
    %{
      operation: project(operation),
      one_time_secret: secret,
      expires_at: operation.ticket_expires_at
    }
  end

  defp exchange_result(operation, material) do
    %{
      operation: project(operation),
      material: material,
      host_identity_digest: operation.host_identity_digest
    }
  end

  defp project(operation) do
    operation
    |> Map.take([
      :id,
      :tenant_id,
      :group_id,
      :surface,
      :scope_key,
      :provider,
      :environment_id,
      :delivery_target_type,
      :delivery_target_id,
      :registration_id,
      :authorization_status,
      :revision,
      :ticket_generation,
      :ticket_status,
      :ticket_expires_at,
      :ticket_consumed_at,
      :material_handed_off_at,
      :error_code,
      :created_at,
      :updated_at
    ])
    |> Map.put(:status, product_status(operation))
  end

  defp product_status(%Operation{authorization_status: "revoked"}), do: "removed"

  defp product_status(%Operation{authorization_status: "action_required"}),
    do: "action_required"

  defp product_status(%Operation{authorization_status: "handed_off"} = operation) do
    registration = Repo.get(AgentVMM.Registration, operation.registration_id)

    binding =
      Repo.one(
        from(b in Compute.ProviderBinding,
          where:
            b.environment_id == ^operation.environment_id and b.provider == "agent_vmm" and
              b.provider_ref == ^operation.registration_id,
          limit: 1
        )
      )

    cond do
      is_binary(operation.error_code) ->
        "action_required"

      match?(%AgentVMM.Registration{status: "revoked"}, registration) ->
        "removed"

      match?(%AgentVMM.Registration{desired_enabled: false}, registration) ->
        "stopped"

      match?(%AgentVMM.Registration{status: "ready", desired_enabled: true}, registration) and
        match?(%Compute.ProviderBinding{status: "available"}, binding) and
          current_binding_observation?(binding) ->
        "ready"

      true ->
        "processing"
    end
  end

  defp product_status(%Operation{}), do: "processing"

  defp current_binding_observation?(%Compute.ProviderBinding{} = binding) do
    observation = binding.observation

    is_binary(observation["gateway_instance_id"]) and
      is_binary(observation["connection_epoch"]) and
      ComputeContract.ready?(%{
        readable: true,
        desired: "present",
        removed: false,
        artifact_verified: true,
        host_healthy: true,
        controller_current: true,
        registration_active: true,
        admission: observation["admission"]
      })
  end

  defp operation_by_request(surface, scope_key, client_request_id) do
    Repo.one(
      from(o in Operation,
        where:
          o.surface == ^surface and o.scope_key == ^scope_key and
            o.client_request_id == ^client_request_id
      )
    )
  end

  defp lock_operation!(operation_id) do
    Repo.one(from(o in Operation, where: o.id == ^operation_id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp update_operation!(operation_id, fields) do
    {1, _} =
      Repo.update_all(from(o in Operation, where: o.id == ^operation_id),
        set: fields
      )

    Repo.get!(Operation, operation_id)
  end

  defp lock_idempotency!(surface, scope_key, request_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      Enum.join(["agent-vmm-install", surface, scope_key, request_id], ":")
    ])
  end

  defp normalize_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp observe_mutation(surface, operation) do
    started = System.monotonic_time()

    result =
      try do
        operation.()
      rescue
        _ -> {:error, :unavailable}
      end

    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{
        component: "salix_store",
        operation: "compute_mutation",
        surface: surface || "system",
        outcome: mutation_outcome(result)
      }
    )

    result
  end

  defp mutation_outcome({:ok, _}), do: "ok"
  defp mutation_outcome({:error, :unavailable}), do: "unavailable"

  defp mutation_outcome({:error, :idempotency_conflict}),
    do: "conflict"

  defp mutation_outcome({:error, _}), do: "rejected"
  defp telemetry_surface(surface) when surface in ["comma", "bft"], do: surface
  defp telemetry_surface(_), do: "system"
  defp digest(value), do: :crypto.hash(:sha256, value)

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_, _), do: false

  defp new_secret,
    do: "vmmi_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))

  defp new_id(prefix),
    do: prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
end
