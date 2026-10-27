defmodule SalixStore.AgentVMMInstallations do
  @moduledoc """
  Durable product-authorized Agent VMM registration install operation.

  One row owns the authorization binding, current ticket generation, and the
  bounded encrypted exchange result. The helper must durably persist the
  result before acknowledging the handoff.
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
      field(:initial_workload_id, :string)
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
      field(:authorizing_subject_id, :string)
      field(:authorizing_audience, :string)
      field(:recovery_challenge, :map)
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

  @doc """
  Create or rotate one idempotent install operation's current ticket.

  With `one_per_scope: true` the scope (a BFT Project) may have only one live
  Host: the request fails with `:scope_host_bound` while another operation of
  the scope is live (`live_for_scope/3`) or its Group has another Agent VMM
  registration that is not revoked. Automatic VMM placement requires one
  authorized Host, so this keeps the Project's Host choice unambiguous. A lock on the scope serializes the check with other requests.
  """
  @spec request(map(), keyword()) :: {:ok, descriptor()} | {:error, atom() | tuple()}
  def request(attrs, opts \\ []) when is_map(attrs) do
    observe_mutation(telemetry_surface(Map.get(attrs, :surface)), fn ->
      now = Keyword.get(opts, :now, SystemsClock.utc_now())

      Repo.transaction(fn ->
        lock_idempotency!(attrs.surface, attrs.scope_key, attrs.client_request_id)

        case Keyword.get(opts, :authorize) do
          nil -> :ok
          authorize -> if authorize.() != :ok, do: Repo.rollback(:authorization_changed)
        end

        existing = operation_by_request(attrs.surface, attrs.scope_key, attrs.client_request_id)
        attrs = request_environment!(attrs, existing, opts)

        case validate_request(attrs) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        if Keyword.get(opts, :one_per_scope, false) do
          require_unbound_scope!(attrs, existing)
        end

        case existing do
          nil -> create_operation!(attrs, now)
          %Operation{} = operation -> rotate_for_request!(operation, attrs, now)
        end
      end)
      |> normalize_transaction()
    end)
  end

  # Product environment creation shares the request's existing idempotency lock.
  # Lost responses and simultaneous retries reuse the original environment.
  defp request_environment!(attrs, existing, opts) do
    case Keyword.get(opts, :create_environment) do
      create when is_function(create, 0) ->
        case existing do
          %Operation{} ->
            Map.put(attrs, :environment_id, existing.environment_id)

          nil ->
            case create.() do
              {:ok, %Compute.Environment{id: id}} -> Map.put(attrs, :environment_id, id)
              {:error, reason} -> Repo.rollback(reason)
            end
        end

      nil ->
        attrs
    end
  end

  @doc "Read one headless delivery without consuming or rotating its existing ticket."
  def headless_handoff(operation_id, secret, opts \\ [])

  def headless_handoff(operation_id, secret, opts)
      when is_binary(operation_id) and is_binary(secret) and byte_size(secret) in 1..128 do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    case Repo.get(Operation, operation_id) do
      %Operation{delivery_target_type: "headless"} = operation ->
        cond do
          not secure_equal?(operation.ticket_secret_hash, digest(secret)) ->
            {:error, :invalid_ticket}

          operation.ticket_status == "active" and operation.authorization_status == "requested" ->
            if DateTime.compare(operation.ticket_expires_at, now) == :gt,
              do: {:ok, %{operation_id: operation.id, expires_at: operation.ticket_expires_at}},
              else: {:error, :ticket_expired}

          operation.ticket_status == "consumed" and
              operation.authorization_status in ["exchange_committed", "handed_off"] ->
            expires_at = operation.material_handoff_expires_at

            expires_at =
              if (operation.authorization_status == "exchange_committed" and expires_at) &&
                   DateTime.compare(expires_at, now) == :gt,
                 do: expires_at,
                 else: nil

            {:ok, %{operation_id: operation.id, expires_at: expires_at}}

          true ->
            {:error, :ticket_revoked}
        end

      _ ->
        {:error, :invalid_ticket}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def headless_handoff(_, _, _), do: {:error, :invalid_ticket}

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

  @doc """
  The BFT Runner (its stable id) an Agent VMM registration of `tenant_id` was
  installed on, or `nil` for a Host not delivered to a BFT Runner.
  """
  @spec bft_runner(String.t(), String.t()) :: String.t() | nil
  def bft_runner(tenant_id, registration_id)
      when is_binary(tenant_id) and is_binary(registration_id) do
    Repo.one(
      from(o in Operation,
        where:
          o.tenant_id == ^tenant_id and o.registration_id == ^registration_id and
            o.surface == "bft" and o.delivery_target_type == "bft_runner",
        order_by: [desc: o.created_at, desc: o.id],
        limit: 1,
        select: o.delivery_target_id
      )
    )
  end

  @doc """
  The live install operations of one scope, newest first, as secret-free
  projections: in flight (`requested` or `exchange_committed`), or handed off
  to a registration that is not revoked. A failed operation
  (`action_required`) does not occupy the scope: it has no live Host, and a
  retry that reopens it checks the scope again. At most `limit` are read.
  """
  @spec live_for_scope(String.t(), String.t(), pos_integer()) :: [map()]
  def live_for_scope(surface, scope_key, limit \\ 2)
      when is_binary(surface) and is_binary(scope_key) and limit in 1..16 do
    surface
    |> live_scope_query(scope_key)
    |> order_by([o], desc: o.created_at, desc: o.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&project/1)
  end

  defp live_scope_query(surface, scope_key) do
    from(o in Operation,
      left_join: r in AgentVMM.Registration,
      on: r.id == o.registration_id,
      where:
        o.surface == ^surface and o.scope_key == ^scope_key and
          o.authorization_status in ["requested", "exchange_committed", "handed_off"] and
          (is_nil(r.id) or r.status != "revoked")
    )
  end

  # `attrs` is the request, or the Operation itself when a retry reopens it.
  defp require_unbound_scope!(attrs, existing) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      Enum.join(["agent-vmm-install-scope", attrs.surface, attrs.scope_key], ":")
    ])

    own = if existing, do: existing.id
    own_registration = if existing, do: existing.registration_id

    other_operation? =
      Repo.exists?(
        attrs.surface
        |> live_scope_query(attrs.scope_key)
        |> where([o], o.id != ^(own || ""))
      )

    other_registration? =
      attrs.tenant_id
      |> AgentVMM.group_registration_ids(attrs.group_id)
      |> Enum.any?(&(&1 != own_registration))

    if other_operation? or other_registration?, do: Repo.rollback(:scope_host_bound)
  end

  @doc "Read the original subject's unexchanged request without rotating its ticket or delivery target."
  def get_by_request(surface, scope_key, client_request_id, authority, opts)
      when is_binary(client_request_id) and byte_size(client_request_id) in 1..160 do
    Repo.transaction(fn ->
      case operation_by_request(surface, scope_key, client_request_id) do
        nil ->
          Repo.rollback(:not_found)

        found ->
          operation = lock_operation!(found.id)
          require_recovery_authority!(operation, authority, opts)

          unless is_nil(operation.host_identity_digest) and is_nil(operation.ticket_consumed_at),
            do: Repo.rollback(:operation_not_abandonable)

          project(operation)
      end
    end)
    |> normalize_transaction()
  end

  def get_by_request(_surface, _scope_key, _client_request_id, _authority, _opts),
    do: {:error, :invalid_recovery_confirmation}

  @doc "Match one bounded page of exact local registration IDs to Comma recovery operations."
  def recovery_candidates(registration_ids, authority, opts) when is_list(registration_ids) do
    if length(registration_ids) > 32 or
         not Enum.all?(registration_ids, &(is_binary(&1) and byte_size(&1) in 1..200)) do
      {:error, :invalid_recovery_candidates}
    else
      ids =
        Repo.all(
          from(o in Operation,
            where:
              o.registration_id in ^registration_ids and o.surface == "comma" and
                o.tenant_id == ^authority.tenant_id and o.group_id == ^authority.group_id and
                o.scope_key == ^authority.scope_key and
                (o.authorizing_subject_id == ^authority.subject or
                   is_nil(o.authorizing_subject_id)),
            order_by: o.id,
            limit: 32,
            select: o.id
          )
        )

      candidates =
        Enum.flat_map(ids, fn id ->
          case recovery_challenge(id, authority, opts) do
            {:ok, candidate} -> [candidate]
            {:error, _} -> []
          end
        end)

      {:ok, candidates}
    end
  end

  def recovery_candidates(_, _, _), do: {:error, :invalid_recovery_candidates}

  @doc "Issue one dedicated challenge under the original installation authority."
  def recovery_challenge(operation_id, authority, opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    Repo.transaction(fn ->
      operation = lock_operation!(operation_id)
      require_recovery_authority!(operation, authority, opts)
      require_recoverable_registration!(operation)
      subject = recovery_subject!(operation, opts)

      challenge = %{
        "purpose" => SalixStore.AgentVMMRecovery.purpose(),
        "audience" => authority.audience,
        "subject" => subject,
        "session_id" => authority.session_id,
        "tenant_id" => operation.tenant_id,
        "group_id" => operation.group_id,
        "scope_key" => operation.scope_key,
        "environment_id" => operation.environment_id,
        "operation_id" => operation.id,
        "registration_id" => operation.registration_id,
        "nonce" => Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false),
        # The database trigger advances revision when it stores the challenge.
        "revision" => operation.revision + 1,
        "expires_at" => DateTime.to_unix(now) + SalixStore.AgentVMMRecovery.ttl()
      }

      saved =
        update_operation!(operation.id,
          authorizing_subject_id: subject,
          authorizing_audience: authority.audience,
          recovery_challenge: challenge,
          updated_at: now
        )

      if saved.revision != challenge["revision"], do: Repo.rollback(:revision_conflict)

      %{
        operation_id: operation.id,
        registration_id: operation.registration_id,
        challenge: challenge
      }
    end)
    |> normalize_transaction()
  end

  @doc "Verify machine possession; consume once only when explicitly recovering management."
  def recover(operation_id, authority, proof, consume, opts \\ [])

  def recover(operation_id, authority, proof, consume, opts)
      when is_boolean(consume) and is_map(proof) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    Repo.transaction(fn ->
      operation = lock_operation!(operation_id)
      require_recovery_authority!(operation, authority, opts)
      registration = require_recoverable_registration!(operation)
      challenge = operation.recovery_challenge

      unless is_map(challenge) and challenge["session_id"] == authority.session_id and
               challenge["revision"] == operation.revision and
               challenge["nonce"] == proof["nonce"] and
               challenge["expires_at"] > DateTime.to_unix(now) do
        Repo.rollback(:invalid_recovery_challenge)
      end

      with {:ok, identity} <- normalize_recovery_identity(proof),
           true <- identity_digest(identity) == operation.host_identity_digest,
           true <- identity.device_id == registration.device_id,
           {:ok, wire} <- SalixStore.AgentVMMRecovery.wire(challenge),
           {:ok, signature} <- decode_recovery_binary(proof["signature"]),
           true <- SalixStore.P256Signature.verify(wire, signature, identity.root_public_key) do
        if consume do
          update_operation!(operation.id,
            delivery_target_type: "comma_main_device",
            delivery_target_id: authority.session_id,
            recovery_challenge: nil,
            updated_at: now
          )
          |> project()
        else
          project(operation)
        end
      else
        _ -> Repo.rollback(:invalid_recovery_proof)
      end
    end)
    |> normalize_transaction()
  end

  def recover(_, _, _, _, _), do: {:error, :invalid_recovery_proof}

  @doc "Close only an unexchanged original request after the original subject explicitly abandons it."
  def abandon_unexchanged(operation_id, authority, opts \\ []) do
    Repo.transaction(fn ->
      operation = lock_operation!(operation_id)
      require_recovery_authority!(operation, authority, opts)

      unless is_nil(operation.host_identity_digest) and is_nil(operation.ticket_consumed_at) and
               operation.authorization_status in ["requested", "action_required", "revoked"] do
        Repo.rollback(:operation_not_abandonable)
      end

      update_operation!(operation.id,
        authorization_status: "revoked",
        ticket_status: "revoked",
        recovery_challenge: nil,
        updated_at: Keyword.get(opts, :now, SystemsClock.utc_now())
      )
      |> project()
    end)
    |> normalize_transaction()
  end

  defp recovery_subject!(operation, opts) do
    case operation.authorizing_subject_id do
      subject when is_binary(subject) ->
        subject

      nil ->
        resolver = Keyword.fetch!(opts, :original_subject)

        case resolver.(operation.delivery_target_type, operation.delivery_target_id) do
          {:ok, subject} when is_binary(subject) -> subject
          _ -> Repo.rollback(:original_subject_unknown)
        end
    end
  end

  defp require_recovery_authority!(operation, authority, opts) do
    unless operation.surface == "comma" and operation.delivery_target_type == "comma_main_device" and
             operation.tenant_id == authority.tenant_id and
             operation.group_id == authority.group_id and
             operation.scope_key == authority.scope_key and
             recovery_subject!(operation, opts) == authority.subject and
             (is_nil(operation.authorizing_audience) or
                operation.authorizing_audience == authority.audience) do
      Repo.rollback(:not_found)
    end

    case Keyword.fetch!(opts, :authorize).() do
      :ok -> :ok
      {:error, _} -> Repo.rollback(:not_found)
    end
  end

  defp require_recoverable_registration!(operation) do
    registration = Repo.get(AgentVMM.Registration, operation.registration_id)

    unless operation.authorization_status == "handed_off" and
             is_binary(operation.host_identity_digest) and
             not is_nil(registration) and registration.status != "revoked" and
             not AgentVMM.authorization_expired?(registration) and
             registration.tenant_id == operation.tenant_id and
             registration.group_id == operation.group_id do
      Repo.rollback(:recovery_target_unavailable)
    end

    registration
  end

  defp decode_recovery_binary(value) when is_binary(value) and byte_size(value) <= 684,
    do: Base.decode64(value)

  defp decode_recovery_binary(_), do: {:error, :invalid_recovery_proof}

  defp normalize_recovery_identity(proof) do
    with {:ok, key} <- decode_recovery_binary(proof["root_public_key"]) do
      normalize_host_identity(%{
        device_id: proof["device_id"],
        root_public_key: key,
        root_key_revision: proof["root_key_revision"]
      })
    else
      _ -> {:error, :invalid_host_identity}
    end
  end

  @doc "Rotate one requested ticket or reopen the same pre-handoff ticket-budget exhaustion."
  @spec retry(String.t(), keyword()) :: {:ok, descriptor()} | {:error, atom() | tuple()}
  def retry(operation_id, opts \\ []) when is_binary(operation_id) do
    observe_mutation("system", fn ->
      now = Keyword.get(opts, :now, SystemsClock.utc_now())

      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)
        require_expected_authorization!(operation, opts)

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
      now = Keyword.get(opts, :now, SystemsClock.utc_now())

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
      now = Keyword.get(opts, :now, SystemsClock.utc_now())

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
        now = SystemsClock.utc_now()

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
      now = Keyword.get(opts, :now, SystemsClock.utc_now())

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
      now = Keyword.get(opts, :now, SystemsClock.utc_now())

      operation_id
      |> do_acknowledge(secret, host_digest, now)
      |> tap(fn
        {:ok, operation} -> ensure_initial_workload_for_registration(operation.registration_id)
        _ -> :ok
      end)
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
      now = Keyword.get(opts, :now, SystemsClock.utc_now())

      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)
        require_expected_authorization!(operation, opts)

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
  def configure_registration(operation_id, enabled, opts \\ [])
      when is_binary(operation_id) and is_boolean(enabled) do
    observe_mutation("system", fn ->
      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)
        require_expected_authorization!(operation, opts)

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
          registration.status == "revoked" or AgentVMM.authorization_expired?(registration) ->
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

  @doc """
  Initialize the existing node Workload under its installation authorization fence.

  The operation keeps one initial Shell: `initial_workload_id` is its key, so a
  repeated call, or a call after Salix already created the Shell at readiness
  (`ensure_initial_workload_for_registration/1`), returns the same Workload,
  even after it was deleted.
  """
  def initialize_workload(operation_id, opts \\ []) do
    observe_mutation("comma", fn ->
      Repo.transaction(fn ->
        operation = lock_operation!(operation_id)
        require_expected_authorization!(operation, opts)
        if product_status(operation) != "ready", do: Repo.rollback(:compute_node_not_ready)

        workload = initial_workload!(operation)

        retry_required =
          workload.observed_state == "failed" or
            Repo.exists?(
              from(c in Compute.ReconcilerClaim,
                where:
                  c.workload_id == ^workload.id and c.generation == ^workload.generation and
                    fragment("?->>'kind'", c.last_error) == "action_required"
              )
            )

        if retry_required and is_nil(workload.deletion) do
          case SalixStore.ComputeWorkloadManagement.retry(
                 operation.tenant_id,
                 operation.scope_key,
                 workload.id,
                 workload.generation,
                 Keyword.get(opts, :authorize, fn -> :ok end)
               ) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        project(Repo.get!(Operation, operation.id))
      end)
      |> normalize_transaction()
    end)
  end

  @doc """
  Create the initial Shell of the handed-off operation of `registration_id`
  when it first reaches product status `ready`, with the same key as
  `initialize_workload/2`.

  Callers run it after the transaction that advanced readiness (Host hello,
  observation settlement, handoff) commits, never inside it: a nested
  `Repo.rollback` taints the outer transaction, so a failed placement would
  otherwise fail the hello, the acknowledgement, or the whole expiry batch.
  An operation that already has an initial Shell, even a deleted one, is
  unchanged. One indexed read when there is nothing to do.
  """
  def ensure_initial_workload_for_registration(registration_id)
      when is_binary(registration_id) do
    pending =
      Repo.one(
        from(o in Operation,
          where:
            o.registration_id == ^registration_id and o.authorization_status == "handed_off" and
              is_nil(o.initial_workload_id) and is_nil(o.error_code),
          select: o.id
        )
      )

    if pending do
      observe_mutation("system", fn ->
        Repo.transaction(fn ->
          operation = lock_operation!(pending)

          cond do
            is_binary(operation.initial_workload_id) -> :ok
            product_status(operation) != "ready" -> Repo.rollback(:compute_node_not_ready)
            true -> initial_workload!(operation)
          end

          project(Repo.get!(Operation, operation.id))
        end)
        |> normalize_transaction()
      end)
    else
      {:ok, nil}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp initial_workload!(%Operation{initial_workload_id: id} = operation) when is_binary(id) do
    Repo.one(
      from(w in Compute.Workload,
        join: a in Compute.Allocation,
        on: a.id == w.allocation_id,
        join: b in Compute.ProviderBinding,
        on: b.id == a.provider_binding_id,
        where:
          w.id == ^id and w.environment_id == ^operation.environment_id and w.kind == "shell" and
            b.provider == "agent_vmm" and b.provider_ref == ^operation.registration_id,
        select: w
      )
    ) || Repo.rollback(:initial_workload_not_found)
  end

  defp initial_workload!(%Operation{} = operation) do
    case Compute.ensure_node_workload(
           operation.tenant_id,
           operation.environment_id,
           operation.registration_id
         ) do
      {:ok, workload} ->
        Repo.update_all(from(o in Operation, where: o.id == ^operation.id),
          set: [initial_workload_id: workload.id]
        )

        workload

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @doc """
  Settle a bounded batch of material handoffs past their deadline.
  A Host that enrolled with the material received it, so its handoff completes.
  Any other handoff closes and revokes its unenrolled registration, which frees the scope.
  """
  def expire_handoffs(opts \\ []) do
    observe_mutation("system", fn ->
      now = Keyword.get(opts, :now, SystemsClock.utc_now())
      limit = opts |> Keyword.get(:limit, @max_expiry_batch) |> min(@max_expiry_batch) |> max(1)

      Repo.transaction(fn ->
        operations =
          Repo.all(
            from(o in Operation,
              where:
                o.authorization_status == "exchange_committed" and
                  o.material_handoff_expires_at <= ^now,
              order_by: [asc: o.material_handoff_expires_at, asc: o.id],
              limit: ^limit,
              lock: "FOR UPDATE SKIP LOCKED"
            )
          )

        handed_off =
          for operation <- operations,
              close_expired_handoff!(operation, now).authorization_status == "handed_off",
              do: operation.registration_id

        {%{settled: length(operations), more?: length(operations) == limit}, handed_off}
      end)
      |> case do
        {:ok, {result, handed_off}} ->
          Enum.each(handed_off, &ensure_initial_workload_for_registration/1)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
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
          authorizing_subject_id: Map.get(attrs, :authorizing_subject_id),
          authorizing_audience: Map.get(attrs, :authorizing_audience),
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
    # BFT requests hold one Host per Project (`one_per_scope: true`). A failed
    # operation released the scope, so reopening it must claim the scope again.
    if operation.surface == "bft", do: require_unbound_scope!(operation, operation)

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
      enrollment_token = SystemsRuntime.Proc.random_bytes(32)

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
          {:error, :credential_sealer_unavailable} -> Repo.rollback(:install_material_unavailable)
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
        case close_expired_handoff!(operation, now) do
          %Operation{authorization_status: "handed_off"} -> {:error, :handoff_complete}
          %Operation{} -> {:error, :handoff_expired}
        end

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
      case close_expired_handoff!(operation, now) do
        %Operation{authorization_status: "handed_off"} = settled -> project(settled)
        %Operation{} -> {:error, :handoff_expired}
      end
    else
      operation |> hand_off!(now) |> project()
    end
  end

  defp hand_off!(operation, now) do
    update_operation!(operation.id,
      authorization_status: "handed_off",
      material_ciphertext: nil,
      material_handoff_expires_at: nil,
      material_handed_off_at: now,
      updated_at: now
    )
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

  # Callers hold the Operation lock; the Registration lock follows it.
  # Enrollment consumes the token inside the material, so an enrolled
  # Registration proves the Host received it even without an acknowledgement.
  defp close_expired_handoff!(operation, now) do
    registration =
      Repo.one(
        from(r in AgentVMM.Registration,
          where: r.id == ^operation.registration_id,
          lock: "FOR UPDATE"
        )
      )

    case registration do
      %AgentVMM.Registration{status: status, credential_hash: hash}
      when status in ["ready", "disabled"] and is_binary(hash) ->
        hand_off!(operation, now)

      _ ->
        revoke_bound_registration!(operation)

        update_operation!(operation.id,
          authorization_status: "action_required",
          error_code: "material_handoff_expired",
          material_ciphertext: nil,
          material_handoff_expires_at: nil,
          updated_at: now
        )
    end
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
    if SystemsRuntime.get_env(
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
      SystemsRuntime.get_env(
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
    registration =
      operation.registration_id && Repo.get(AgentVMM.Registration, operation.registration_id)

    operation
    |> Map.take([
      :id,
      :tenant_id,
      :group_id,
      :surface,
      :scope_key,
      :provider,
      :environment_id,
      :initial_workload_id,
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
    |> Map.put(:status, product_status(operation, registration))
    |> Map.put(:registration_revocation_reason, revocation_reason(registration))
  end

  # Why the bound registration was revoked: "authorization_expired" only for
  # the 7-day deadline, so a client may reinstall automatically; any explicit
  # revocation is "revoked". A row revoked before the reason existed has none.
  defp revocation_reason(%AgentVMM.Registration{status: "revoked", revocation_reason: reason}),
    do: reason || "revoked"

  defp revocation_reason(_registration), do: nil

  defp product_status(operation),
    do: product_status(operation, Repo.get(AgentVMM.Registration, operation.registration_id))

  defp product_status(%Operation{authorization_status: "revoked"}, _registration), do: "removed"

  defp product_status(%Operation{authorization_status: "action_required"}, _registration),
    do: "action_required"

  defp product_status(%Operation{authorization_status: "handed_off"} = operation, registration) do
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

      (binding && not is_nil((binding.observation || %{})["connection_epoch"])) and
          not match?(
            {:ok, _},
            ComputeContract.connection_epoch(binding.observation["connection_epoch"])
          ) ->
        "action_required"

      match?(%AgentVMM.Registration{status: "ready", desired_enabled: true}, registration) and
        match?(%Compute.ProviderBinding{status: "available"}, binding) and
          current_binding_observation?(binding) ->
        "ready"

      true ->
        "processing"
    end
  end

  defp product_status(%Operation{}, _registration), do: "processing"

  defp current_binding_observation?(%Compute.ProviderBinding{} = binding) do
    observation = binding.observation

    is_binary(observation["gateway_instance_id"]) and
      match?({:ok, _}, ComputeContract.connection_epoch(observation["connection_epoch"])) and
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

  defp require_expected_authorization!(operation, opts) do
    case Keyword.get(opts, :authorize) do
      nil ->
        :ok

      authorize ->
        case authorize.() do
          :ok -> :ok
          _ -> Repo.rollback(:authorization_changed)
        end
    end

    case Keyword.get(opts, :expected_authorization) do
      nil ->
        :ok

      expected when is_map(expected) ->
        fields = [
          :revision,
          :tenant_id,
          :group_id,
          :surface,
          :scope_key,
          :delivery_target_type,
          :delivery_target_id
        ]

        if Enum.any?(fields, &(Map.fetch!(expected, &1) != Map.fetch!(operation, &1))) do
          Repo.rollback(:authorization_changed)
        end
    end
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
    started = SystemsClock.monotonic_time()

    result =
      try do
        operation.()
      rescue
        _ -> {:error, :unavailable}
      end

    SystemsRuntime.Telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: SystemsClock.monotonic_time() - started},
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
    do: "vmmi_" <> (SystemsRuntime.Proc.random_bytes(32) |> Base.url_encode64(padding: false))

  defp new_id(prefix),
    do:
      prefix <> "_" <> (SystemsRuntime.Proc.random_bytes(16) |> Base.url_encode64(padding: false))
end
