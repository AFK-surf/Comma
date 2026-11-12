defmodule SalixStore.AgentVMMRegistrations do
  @moduledoc "Product-authorized Registration requests, claim and credential replacement."
  import Ecto.Query
  alias SalixStore.{AgentVMM, Compute, Repo}
  alias AgentVMM.Registration

  @ticket_ttl 900

  def request(attrs, opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    Repo.transaction(fn ->
      owner_id = attrs.owner_id
      lock_owner!(attrs.surface, owner_id)
      authorize!(opts)
      existing = by_request(attrs.surface, owner_id, attrs.client_request_id)

      attrs = request_environment!(attrs, existing, opts)

      environment = validate_request!(attrs)

      if is_nil(existing) and environment.desired_state != "ready",
        do: Repo.rollback(:invalid_registration_environment)

      if attrs.surface == "bft" and is_nil(existing),
        do: require_unbound_owner!(attrs.environment_id, nil, now)

      case existing do
        nil ->
          secret = new_secret()

          row = %Registration{
            id: new_id("registration"),
            tenant_id: attrs.tenant_id,
            group_id: attrs.group_id,
            surface: attrs.surface,
            client_request_id: attrs.client_request_id,
            environment_id: attrs.environment_id,
            delivery_target_type: attrs.delivery_target_type,
            delivery_target_id: attrs.delivery_target_id,
            authorizing_subject_id: attrs[:authorizing_subject_id],
            authorizing_audience: attrs[:authorizing_audience],
            status: "enrolling",
            revision: 1,
            policy_revision: 1,
            desired_enabled: true,
            ticket_secret_hash: digest(secret),
            ticket_expires_at: DateTime.add(now, @ticket_ttl, :second),
            authorization_expires_at: DateTime.add(now, 7 * 86_400, :second),
            created_at: now,
            updated_at: now
          }

          descriptor(Repo.insert!(row), secret)

        r ->
          unless binding_matches?(r, attrs), do: Repo.rollback(:idempotency_conflict)
          descriptor(r, nil)
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def cancel_request(attrs, opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    Repo.transaction(fn ->
      lock_owner!(attrs.surface, attrs.owner_id)
      authorize!(opts)
      existing = by_request(attrs.surface, attrs.owner_id, attrs.client_request_id)
      attrs = request_environment!(attrs, existing, opts)
      validate_request!(attrs)

      case existing do
        nil ->
          Repo.insert!(%Registration{
            id: new_id("registration"),
            tenant_id: attrs.tenant_id,
            group_id: attrs.group_id,
            surface: attrs.surface,
            client_request_id: attrs.client_request_id,
            environment_id: attrs.environment_id,
            delivery_target_type: attrs.delivery_target_type,
            delivery_target_id: attrs.delivery_target_id,
            authorizing_subject_id: attrs[:authorizing_subject_id],
            authorizing_audience: attrs[:authorizing_audience],
            status: "revoked",
            revocation_reason: "revoked",
            revision: 1,
            policy_revision: 1,
            desired_enabled: false,
            authorization_expires_at: DateTime.add(now, 7 * 86_400, :second),
            created_at: now,
            updated_at: now
          })
          |> project()

        found ->
          r = lock_registration!(found.id)

          require_authority!(
            r,
            %{
              tenant_id: attrs.tenant_id,
              owner_id: attrs.owner_id,
              subject: attrs[:authorizing_subject_id],
              audience: attrs[:authorizing_audience]
            },
            opts
          )

          if r.status == "revoked" do
            project(r)
          else
            case AgentVMM.revoke_registration(r.tenant_id, r.id, r.revision) do
              {:ok, r} -> project(r)
              {:error, reason} -> Repo.rollback(reason)
            end
          end
      end
    end)
  end

  def get(id) do
    case Repo.get(Registration, id) do
      nil -> {:error, :not_found}
      r -> {:ok, project(r)}
    end
  end

  def get_by_request(surface, owner_id, request_id, authority, opts) do
    Repo.transaction(fn ->
      lock_owner!(surface, owner_id)
      found = by_request(surface, owner_id, request_id) || Repo.rollback(:not_found)
      r = lock_registration!(found.id)
      require_authority!(r, authority, opts)
      project(r)
    end)
  end

  def retry(id, opts \\ []) do
    Repo.transaction(fn ->
      r = lock_owned_registration!(id)
      require_expected!(r, opts)
      unless pending?(r) and r.status != "revoked", do: Repo.rollback(:registration_not_retryable)

      if r.surface == "bft",
        do: require_unbound_owner!(r.environment_id, r.id, SystemsClock.utc_now())

      rotate_ticket!(r, Keyword.get(opts, :now, SystemsClock.utc_now()))
    end)
  end

  def retry_at_revision(id, revision, opts \\ []),
    do: retry(id, Keyword.put(opts, :expected_revision, revision))

  def claim(id, ticket, identity, credential, opts \\ [])

  def claim(id, ticket, identity, credential, opts)
      when is_binary(credential) and byte_size(credential) == 43 do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    with {:ok, identity} <- normalize_identity(identity) do
      Repo.transaction(fn ->
        r = lock_owned_registration!(id)
        if r.status == "revoked", do: Repo.rollback(:registration_revoked)

        unless Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, credential),
          do: Repo.rollback(:invalid_candidate_credential)

        commitment = identity_digest(identity)

        cond do
          is_binary(r.credential_hash) ->
            unless secure_equal?(r.host_identity_digest, commitment) and
                     r.device_id == identity.device_id and
                     secure_equal?(r.credential_hash, digest(credential)),
                   do: Repo.rollback(:host_identity_mismatch)

            if AgentVMM.authorization_expired?(r, now), do: Repo.rollback(:authorization_expired)

          not pending?(r) ->
            Repo.rollback(:credential_reauthorization_required)

          true ->
            unless is_binary(ticket) and secure_equal?(r.ticket_secret_hash, digest(ticket)),
              do: Repo.rollback(:invalid_ticket)

            unless r.ticket_expires_at && DateTime.compare(r.ticket_expires_at, now) == :gt,
              do: Repo.rollback(:ticket_expired)

            current_owner!(r, opts)
            if r.surface == "bft", do: require_unbound_owner!(r.environment_id, r.id, now)
            ensure_binding!(r)

            update!(r.id,
              device_id: identity.device_id,
              host_identity_digest: commitment,
              credential_hash: digest(credential),
              ticket_secret_hash: nil,
              status: if(r.desired_enabled, do: "ready", else: "disabled"),
              error_code: nil,
              authorization_expires_at: DateTime.add(now, 7 * 86_400, :second),
              updated_at: now
            )
        end

        case SalixStore.AgentVMMConnectionConfig.issue(Repo.get!(Registration, id)) do
          {:ok, config} -> config
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def claim(_, _, _, _, _), do: {:error, :invalid_request}

  def revoke(id, opts \\ []) do
    Repo.transaction(fn ->
      r = lock_owned_registration!(id)
      require_expected!(r, opts)

      if r.status != "revoked" do
        case AgentVMM.revoke_registration(r.tenant_id, id, r.revision) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      project(Repo.get!(Registration, id))
    end)
  end

  def configure_registration(id, enabled, opts \\ []) do
    Repo.transaction(fn ->
      r = lock_owned_registration!(id)
      require_expected!(r, opts)

      case AgentVMM.configure_registration(id, r.revision, enabled) do
        {:ok, r} -> project(r)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A bounded exact-ID lookup returns no challenge: the Host must first persist
  # its replacement credential, whose hash is part of the signed challenge.
  def recovery_candidates(ids, authority, opts) when is_list(ids) and length(ids) <= 32 do
    candidates =
      Enum.flat_map(ids, fn id ->
        case Repo.transaction(fn ->
               r = lock_owned_registration!(id)
               require_authority!(r, authority, opts)
               require_recoverable!(r)
               project(r)
             end) do
          {:ok, r} -> [r]
          _ -> []
        end
      end)

    {:ok, candidates}
  end

  def recovery_candidates(_, _, _), do: {:error, :invalid_recovery_candidates}

  def recovery_challenge(id, authority, opts \\ []) do
    candidate_hash = Keyword.get(opts, :candidate_credential_hash)

    with {:ok, hash} <- decode_candidate_hash(candidate_hash) do
      now = Keyword.get(opts, :now, SystemsClock.utc_now())

      Repo.transaction(fn ->
        r = lock_owned_registration!(id)
        require_authority!(r, authority, opts)
        require_recoverable!(r)
        environment = Repo.get!(Compute.Environment, r.environment_id)

        challenge = %{
          "purpose" => SalixStore.AgentVMMRecovery.purpose(),
          "audience" => authority.audience,
          "subject" => authority.subject,
          "session_id" => authority.session_id,
          "controller_binding" => Jason.encode!([r.tenant_id, r.group_id, environment.owner_id]),
          "environment_id" => r.environment_id,
          "registration_id" => r.id,
          "candidate_credential_hash" => Base.encode64(hash),
          "nonce" => new_secret(),
          "revision" => r.revision + 1,
          "expires_at" => DateTime.to_unix(now) + SalixStore.AgentVMMRecovery.ttl()
        }

        saved =
          update!(id,
            recovery_challenge: challenge,
            authorizing_subject_id:
              if(r.surface == "comma", do: authority.subject, else: r.authorizing_subject_id),
            authorizing_audience: r.authorizing_audience || authority.audience,
            updated_at: now
          )

        if saved.revision != challenge["revision"], do: Repo.rollback(:revision_conflict)
        %{registration_id: id, challenge: challenge}
      end)
    end
  end

  def replace_credential(id, authority, proof, candidate, opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    with {:ok, candidate} <- decode_credential(candidate),
         true <- is_map(proof),
         {:ok, key} <- Base.decode64(proof["root_public_key"] || ""),
         {:ok, identity} <-
           normalize_identity(%{
             device_id: proof["device_id"],
             root_public_key: key,
             root_key_revision: proof["root_key_revision"]
           }) do
      Repo.transaction(fn ->
        r = lock_owned_registration!(id)
        require_authority!(r, authority, opts)
        require_recoverable!(r)

        unless secure_equal?(identity_digest(identity), r.host_identity_digest) and
                 identity.device_id == r.device_id,
               do: Repo.rollback(:invalid_recovery_proof)

        if secure_equal?(r.credential_hash, digest(candidate)) do
          # The accepted candidate authenticates a lost-response replay. It must
          # still pass the same expiry and explicit revocation checks as connect.
          if AgentVMM.authorization_expired?(r, now), do: Repo.rollback(:authorization_expired)
          project(r)
        else
          c = r.recovery_challenge

          unless is_map(c) and c["session_id"] == authority.session_id and
                   c["revision"] == r.revision and
                   c["nonce"] == proof["nonce"] and c["expires_at"] > DateTime.to_unix(now) and
                   c["candidate_credential_hash"] == Base.encode64(digest(candidate)),
                 do: Repo.rollback(:invalid_recovery_challenge)

          with {:ok, wire} <- SalixStore.AgentVMMRecovery.wire(c),
               {:ok, signature} <- Base.decode64(proof["signature"] || ""),
               true <- SalixStore.P256Signature.verify(wire, signature, key) do
            # Keep enablement and all workload facts. Fence only the old control
            # connection, whose credential has just been replaced.
            update!(id,
              credential_hash: digest(candidate),
              recovery_challenge: nil,
              connected: false,
              current_gateway_instance_id: nil,
              current_connection_epoch: nil,
              authorization_expires_at: DateTime.add(now, 7 * 86_400, :second),
              updated_at: now
            )
            |> project()
          else
            _ -> Repo.rollback(:invalid_recovery_proof)
          end
        end
      end)
    else
      _ -> {:error, :invalid_recovery_proof}
    end
  rescue
    _ -> {:error, :invalid_recovery_proof}
  end

  def headless_handoff(id, secret, opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    case Repo.get(Registration, id) do
      %Registration{delivery_target_type: "headless"} = r ->
        cond do
          r.status == "revoked" ->
            {:error, :registration_revoked}

          not pending?(r) ->
            # This is public installer/configuration delivery. The supplied
            # ticket cannot authorize another claim; only the already-persisted
            # candidate can replay the bound Registration.
            {:ok,
             %{
               registration_id: id,
               request_id: r.client_request_id,
               expires_at: r.ticket_expires_at
             }}

          not secure_equal?(r.ticket_secret_hash, digest(secret)) ->
            {:error, :invalid_ticket}

          DateTime.compare(r.ticket_expires_at, now) != :gt ->
            {:error, :ticket_expired}

          true ->
            {:ok,
             %{
               registration_id: id,
               request_id: r.client_request_id,
               expires_at: r.ticket_expires_at
             }}
        end

      _ ->
        {:error, :invalid_ticket}
    end
  end

  def deliver_next(type, target, opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())
    # Select one ID before acquiring owner then registration locks in the same
    # order as claim/retry/GC. The locked row is checked again.
    id =
      Repo.one(
        from(r in Registration,
          where:
            r.delivery_target_type == ^type and
              r.delivery_target_id == ^target and r.status != "revoked" and r.desired_enabled and
              is_nil(r.error_code) and is_nil(r.host_identity_digest) and
              not is_nil(r.ticket_secret_hash) and
              r.ticket_expires_at > ^now,
          order_by: [asc: r.created_at, asc: r.id],
          limit: 1,
          select: r.id
        )
      )

    if id do
      Repo.transaction(fn ->
        r = lock_owned_registration!(id)

        unless (pending?(r) and r.status != "revoked" and r.desired_enabled and
                  is_nil(r.error_code) and r.ticket_expires_at) &&
                 DateTime.compare(r.ticket_expires_at, now) == :gt,
               do: Repo.rollback(:no_pending_registration)

        current_owner!(r, opts)
        rotate_ticket!(r, now)
      end)
    else
      {:error, :no_pending_registration}
    end
  end

  def report_delivery_failure(type, target, id, code)
      when is_binary(code) and byte_size(code) in 1..128 do
    Repo.transaction(fn ->
      r = lock_owned_registration!(id)

      unless r.delivery_target_type == type and r.delivery_target_id == target,
        do: Repo.rollback(:delivery_target_mismatch)

      # A local install result is not revocation authority over independent work.
      update!(id, error_code: code, updated_at: SystemsClock.utc_now()) |> project()
    end)
  end

  def report_delivery_failure(_, _, _, _), do: {:error, :invalid_delivery_failure}

  def control_page(type, target, cursor \\ nil, limit \\ 32) when limit in 1..32 do
    query =
      from(r in Registration,
        where:
          r.delivery_target_type == ^type and
            r.delivery_target_id == ^target and not is_nil(r.host_identity_digest),
        order_by: r.id,
        limit: ^limit
      )

    query =
      if is_binary(cursor) and cursor != "",
        do: from(r in query, where: r.id > ^cursor),
        else: query

    rows = Repo.all(query)

    {:ok,
     %{
       controls:
         Enum.map(rows, fn r ->
           %{
             registration_id: r.id,
             registration_revision: r.revision,
             state:
               cond do
                 r.status == "revoked" -> "revoked"
                 r.desired_enabled -> "enabled"
                 true -> "draining"
               end
           }
         end),
       next_cursor: if(length(rows) == limit, do: List.last(rows).id)
     }}
  rescue
    _ -> {:error, :unavailable}
  end

  def bft_runner(tenant, id),
    do:
      Repo.one(
        from(r in Registration,
          where:
            r.id == ^id and
              r.tenant_id == ^tenant and r.surface == "bft" and
              r.delivery_target_type == "bft_runner",
          select: r.delivery_target_id
        )
      )

  def live_for_owner(surface, owner_id, limit \\ 2) when limit in 1..16 do
    now = SystemsClock.utc_now()

    Repo.all(
      from(r in Registration,
        join: e in Compute.Environment,
        on: e.id == r.environment_id,
        where:
          r.surface == ^surface and e.owner_id == ^owner_id and r.status != "revoked" and
            (not is_nil(r.host_identity_digest) or
               (not is_nil(r.ticket_secret_hash) and r.ticket_expires_at > ^now)),
        order_by: [desc: r.created_at, desc: r.id],
        limit: ^limit
      )
    )
    |> Enum.map(&project/1)
  end

  def expire_tickets(opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())
    limit = min(Keyword.get(opts, :limit, 32), 100)

    ids =
      Repo.all(
        from(r in Registration,
          where:
            is_nil(r.host_identity_digest) and
              is_nil(r.credential_hash) and is_nil(r.device_id) and
              not is_nil(r.ticket_secret_hash) and r.ticket_expires_at <= ^now,
          order_by: [asc: r.ticket_expires_at, asc: r.id],
          limit: ^limit,
          select: r.id
        )
      )

    Enum.each(ids, fn id ->
      Repo.transaction(fn ->
        r = lock_owned_registration!(id)

        if ((pending?(r) and r.ticket_expires_at) &&
              DateTime.compare(r.ticket_expires_at, now) != :gt) and
             not Repo.exists?(
               from(b in Compute.ProviderBinding,
                 where: b.provider == "agent_vmm" and b.provider_ref == ^id
               )
             ) do
          update!(id, ticket_secret_hash: nil, updated_at: now)
        end
      end)
    end)

    {:ok, %{expired: length(ids), more?: length(ids) == limit}}
  end

  def initialize_workload(id, opts \\ []) do
    Repo.transaction(fn ->
      r = lock_owned_registration!(id)
      require_expected!(r, opts)
      unless request_status(r) == "ready", do: Repo.rollback(:compute_node_not_ready)
      w = initial_workload!(r)

      if (w.observed_state == "failed" or
            Repo.exists?(
              from(c in Compute.ReconcilerClaim,
                where:
                  c.workload_id == ^w.id and c.generation == ^w.generation and
                    fragment("?->>'kind'", c.last_error) == "action_required"
              )
            )) and is_nil(w.deletion) do
        environment = Repo.get!(Compute.Environment, r.environment_id)

        case SalixStore.ComputeWorkloadManagement.retry(
               r.tenant_id,
               environment.owner_id,
               w.id,
               w.generation,
               Keyword.get(opts, :authorize, fn -> :ok end)
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      project(Repo.get!(Registration, id))
    end)
  end

  def ensure_initial_workload_for_registration(id) do
    case Repo.get(Registration, id) do
      %Registration{environment_id: env, initial_workload_id: nil} when is_binary(env) ->
        Repo.transaction(fn ->
          r = lock_owned_registration!(id)

          if is_nil(r.initial_workload_id) and request_status(r) == "ready",
            do: initial_workload!(r)

          project(Repo.get!(Registration, id))
        end)

      _ ->
        {:ok, nil}
    end
  end

  defp initial_workload!(%Registration{initial_workload_id: id, environment_id: env})
       when is_binary(id) do
    Repo.one(
      from(w in Compute.Workload,
        where: w.id == ^id and w.environment_id == ^env and w.kind == "shell"
      )
    ) ||
      Repo.rollback(:initial_workload_not_found)
  end

  defp initial_workload!(r) do
    case Compute.ensure_node_workload(r.tenant_id, r.environment_id, r.id) do
      {:ok, w} ->
        update!(r.id, initial_workload_id: w.id)
        w

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  def project(r) do
    env = r.environment_id && Repo.get(Compute.Environment, r.environment_id)

    r
    |> Map.take([
      :id,
      :client_request_id,
      :tenant_id,
      :group_id,
      :surface,
      :environment_id,
      :initial_workload_id,
      :delivery_target_type,
      :delivery_target_id,
      :authorizing_subject_id,
      :authorizing_audience,
      :revision,
      :ticket_expires_at,
      :error_code,
      :created_at,
      :updated_at
    ])
    |> Map.put(:host_bound, not pending?(r))
    |> Map.put(:error_code, projected_error(r))
    |> Map.put(:owner_id, env && env.owner_id)
    |> Map.put(:status, request_status(r))
  end

  defp projected_error(r) do
    cond do
      r.status == "revoked" ->
        r.error_code

      pending?(r) ->
        if(
          r.ticket_expires_at &&
            DateTime.compare(r.ticket_expires_at, SystemsClock.utc_now()) != :gt,
          do: "ticket_expired",
          else: r.error_code
        )

      is_nil(r.credential_hash) ->
        "credential_missing"

      AgentVMM.authorization_expired?(r) ->
        "authorization_expired"

      true ->
        r.error_code
    end
  end

  def request_status(r) do
    cond do
      r.status == "revoked" ->
        "removed"

      is_binary(r.error_code) ->
        "action_required"

      pending?(r) and not r.desired_enabled ->
        "stopped"

      pending?(r) ->
        if(
          r.ticket_expires_at &&
            DateTime.compare(r.ticket_expires_at, SystemsClock.utc_now()) == :gt,
          do: "processing",
          else: "action_required"
        )

      not r.desired_enabled ->
        "stopped"

      AgentVMM.authorization_expired?(r) ->
        "action_required"

      r.status == "ready" and r.connected ->
        "ready"

      true ->
        "processing"
    end
  end

  defp require_recoverable!(r) do
    unless is_binary(r.host_identity_digest) and r.status != "revoked",
      do: Repo.rollback(:recovery_target_unavailable)
  end

  defp require_authority!(r, authority, opts) do
    e = Repo.get(Compute.Environment, r.environment_id)

    unless (e && e.owner_id == authority.owner_id) and r.tenant_id == authority.tenant_id and
             (is_nil(r.authorizing_audience) or r.authorizing_audience == authority.audience) and
             (r.surface != "comma" or original_subject!(r, opts) == authority.subject),
           do: Repo.rollback(:not_found)

    authorize!(opts)
  end

  defp original_subject!(r, opts) do
    case r.authorizing_subject_id do
      subject when is_binary(subject) ->
        subject

      nil ->
        resolver = Keyword.get(opts, :original_subject, fn _, _ -> {:error, :not_found} end)

        case resolver.(r.delivery_target_type, r.delivery_target_id) do
          {:ok, subject} ->
            subject

          _ ->
            Repo.rollback(:original_subject_unknown)
        end
    end
  end

  defp current_owner!(r, opts) do
    result =
      case Keyword.get(opts, :authorize) do
        f when is_function(f, 0) ->
          f.()

        _ ->
          case r.surface do
            "comma" -> apply(Comma.Compute, :registration_claim_authority, [r])
            "bft" -> apply(BridgeForTeams.Compute, :registration_claim_authority, [r])
            _ -> {:error, :not_found}
          end
      end

    unless result == :ok, do: Repo.rollback(:authorization_changed)
  end

  defp authorize!(opts) do
    case Keyword.get(opts, :authorize) do
      nil -> :ok
      f -> unless f.() == :ok, do: Repo.rollback(:authorization_changed)
    end
  end

  defp require_expected!(r, opts) do
    authorize!(opts)
    expected = Keyword.get(opts, :expected_authorization)
    revision = Keyword.get(opts, :expected_revision, expected && expected.revision)
    if revision && revision != r.revision, do: Repo.rollback(:revision_conflict)

    if expected &&
         Enum.any?(
           [
             :tenant_id,
             :group_id,
             :surface,
             :environment_id,
             :delivery_target_type,
             :delivery_target_id
           ],
           &(Map.get(expected, &1) != Map.get(r, &1))
         ),
       do: Repo.rollback(:authorization_changed)
  end

  defp ensure_binding!(r) do
    e =
      Repo.one(
        from(e in Compute.Environment, where: e.id == ^r.environment_id, lock: "FOR UPDATE")
      )

    unless (e && e.tenant_id == r.tenant_id) and e.desired_state == "ready",
      do: Repo.rollback(:invalid_registration_environment)

    case Compute.ensure_provider_binding(%{
           id: new_id("provider"),
           pool_id: e.pool_id,
           environment_id: e.id,
           provider: "agent_vmm",
           provider_ref: r.id,
           generation: e.generation
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp require_unbound_owner!(env, own, now) do
    # An expired, never-bound ticket owns no work and releases occupancy once.
    Repo.update_all(
      from(r in Registration,
        where:
          r.environment_id == ^env and r.surface == "bft" and
            is_nil(r.host_identity_digest) and is_nil(r.credential_hash) and is_nil(r.device_id) and
            not is_nil(r.ticket_secret_hash) and r.ticket_expires_at <= ^now
      ),
      set: [ticket_secret_hash: nil]
    )

    if Repo.exists?(
         from(r in Registration,
           where:
             r.environment_id == ^env and r.surface == "bft" and
               r.id != ^(own || "") and r.status != "revoked" and
               (not is_nil(r.host_identity_digest) or not is_nil(r.ticket_secret_hash))
         )
       ),
       do: Repo.rollback(:scope_host_bound)
  end

  defp request_environment!(attrs, existing, opts) do
    case {existing, Keyword.get(opts, :create_environment)} do
      {%Registration{} = r, _} ->
        Map.put(attrs, :environment_id, r.environment_id)

      {nil, create} when is_function(create, 0) ->
        case create.() do
          {:ok, %Compute.Environment{id: id}} -> Map.put(attrs, :environment_id, id)
          {:error, reason} -> Repo.rollback(reason)
        end

      _ ->
        attrs
    end
  end

  defp validate_request!(attrs) do
    unless Enum.all?(
             [
               :tenant_id,
               :group_id,
               :surface,
               :owner_id,
               :client_request_id,
               :environment_id,
               :delivery_target_type,
               :delivery_target_id
             ],
             fn k -> is_binary(attrs[k]) and byte_size(attrs[k]) in 1..200 end
           ) and
             attrs.surface in ["comma", "bft"],
           do: Repo.rollback(:invalid_registration_request)

    case Repo.get(Compute.Environment, attrs.environment_id) do
      %Compute.Environment{
        tenant_id: tenant,
        owner_type: "project",
        owner_id: owner
      } = environment
      when tenant == attrs.tenant_id and owner == attrs.owner_id ->
        environment

      _ ->
        Repo.rollback(:invalid_registration_environment)
    end
  end

  defp binding_matches?(r, attrs) do
    fields = [
      :tenant_id,
      :group_id,
      :surface,
      :environment_id,
      :delivery_target_type,
      :authorizing_subject_id,
      :authorizing_audience
    ]

    fields = if r.surface == "comma", do: fields, else: [:delivery_target_id | fields]
    Enum.all?(fields, &(Map.get(r, &1) == Map.get(attrs, &1)))
  end

  defp by_request(surface, owner, request),
    do:
      Repo.one(
        from(r in Registration,
          join: e in Compute.Environment,
          on: e.id == r.environment_id,
          where:
            r.surface == ^surface and e.owner_id == ^owner and r.client_request_id == ^request
        )
      )

  defp lock_owned_registration!(id) do
    found = Repo.get(Registration, id) || Repo.rollback(:not_found)
    e = found.environment_id && Repo.get(Compute.Environment, found.environment_id)
    if e, do: lock_owner!(found.surface, e.owner_id)
    lock_registration!(id)
  end

  defp lock_registration!(id),
    do:
      Repo.one(from(r in Registration, where: r.id == ^id, lock: "FOR UPDATE")) ||
        Repo.rollback(:not_found)

  defp lock_owner!(surface, owner),
    do:
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "agent-vmm-registration:#{surface}:#{owner}"
      ])

  defp update!(id, fields) do
    {1, _} =
      Repo.update_all(from(r in Registration, where: r.id == ^id),
        set: fields,
        inc: [revision: 1]
      )

    Repo.get!(Registration, id)
  end

  defp rotate_ticket!(r, now) do
    secret = new_secret()

    update!(r.id,
      ticket_secret_hash: digest(secret),
      ticket_expires_at: DateTime.add(now, @ticket_ttl, :second),
      error_code: nil,
      updated_at: now
    )
    |> descriptor(secret)
  end

  defp descriptor(r, secret),
    do: %{registration: project(r), ticket: secret, expires_at: r.ticket_expires_at}

  defp pending?(r),
    do: is_nil(r.host_identity_digest) and is_nil(r.credential_hash) and is_nil(r.device_id)

  defp normalize_identity(i) when is_map(i) do
    d = i[:device_id] || i["device_id"]
    k = i[:root_public_key] || i["root_public_key"]
    v = i[:root_key_revision] || i["root_key_revision"]

    if is_binary(d) and byte_size(d) in 1..200 and is_binary(k) and byte_size(k) == 33 and
         :binary.first(k) in [2, 3] and
         is_integer(v) and v > 0,
       do: {:ok, %{device_id: d, root_public_key: k, root_key_revision: v}},
       else: {:error, :invalid_host_identity}
  end

  defp normalize_identity(_), do: {:error, :invalid_host_identity}

  defp identity_digest(i),
    do:
      digest(Jason.encode!([i.device_id, Base.encode64(i.root_public_key), i.root_key_revision]))

  defp decode_credential(value) when is_binary(value) and byte_size(value) == 60 do
    with {:ok, credential} <- Base.decode64(value),
         true <-
           byte_size(credential) == 43 and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, credential) do
      {:ok, credential}
    else
      _ -> {:error, :invalid_candidate_credential}
    end
  end

  defp decode_credential(_), do: {:error, :invalid_candidate_credential}

  defp decode_candidate_hash(v) when is_binary(v) and byte_size(v) <= 44 do
    case Base.decode64(v) do
      {:ok, b} when byte_size(b) == 32 -> {:ok, b}
      _ -> {:error, :invalid_candidate_credential}
    end
  end

  defp decode_candidate_hash(_), do: {:error, :invalid_candidate_credential}
  defp digest(v), do: :crypto.hash(:sha256, v)

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: Plug.Crypto.secure_compare(a, b)

  defp secure_equal?(_, _), do: false
  defp new_secret, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

  defp new_id(prefix),
    do: prefix <> "_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)
end
