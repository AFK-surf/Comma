defmodule SalixStore.AgentVMM do
  @moduledoc """
  Agent VMM provider-private enrollment, gateway, and session refinement.

  Compute Environment, Allocation, Workload, Grant, command, and runtime
  authority are owned by `SalixStore.Compute`. This module only refines those
  facts with Agent VMM registration and gateway transport evidence.
  """

  import Ecto.Query
  alias SalixStore.{Compute, Repo}

  defmodule Registration do
    use Ecto.Schema
    @primary_key false
    schema "agent_vmm_registrations" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:device_id, :string)
      field(:status, :string)
      field(:revision, :integer)
      field(:policy_revision, :integer)
      field(:desired_enabled, :boolean)
      field(:next_controller_sequence, :integer)
      field(:enrollment_token_hash, :binary)
      field(:credential_hash, :binary)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule Session do
    use Ecto.Schema
    @primary_key false
    schema "agent_vmm_sessions" do
      field(:id, :string, primary_key: true)
      field(:registration_id, :string)
      field(:runtime_instance_id, :string)
      field(:allocation_id, :string)
      field(:allocation_generation, :integer)
      field(:connection_epoch, :string)
      field(:gateway_instance_id, :string)
      field(:status, :string)
      field(:expires_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
      field(:workload_generation, :integer, virtual: true)
    end
  end

  defmodule RegistrationObservation do
    use Ecto.Schema
    @primary_key false
    schema "agent_vmm_registration_observations" do
      field(:registration_id, :string, primary_key: true)
      field(:gateway_instance_id, :string)
      field(:connection_epoch, :string)
      field(:observation_sequence, :integer)
      field(:observed_at, :utc_datetime_usec)
      field(:received_at, :utc_datetime_usec)
      field(:disconnected_at, :utc_datetime_usec)
      field(:protocol_version, :string)
      field(:host_api_version, :string)
      field(:connector_release, :string)
      field(:supported_features, {:array, :string})
      field(:capacity, :map)
      field(:health_status, :string)
      field(:health_issue, :string)
      field(:health_message, :string)
      field(:health_components, :map)
      field(:usage, :map)
      field(:inventory_watermark, :integer)
      field(:inventory_observed_at, :utc_datetime_usec)
    end
  end

  defmodule AuditEvent do
    use Ecto.Schema
    @primary_key false
    schema "agent_vmm_audit_events" do
      field(:id, :integer, primary_key: true)
      field(:tenant_id, :string)
      field(:subject_type, :string)
      field(:subject_id, :string)
      field(:action, :string)
      field(:outcome, :string)
      field(:metadata, :map)
      field(:created_at, :utc_datetime_usec)
    end
  end

  def create_registration(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    limit = Application.get_env(:salix_store, :agent_vmm_registration_limit_per_tenant, 128)

    desired_enabled = Map.get(attrs, :desired_enabled, false)

    row = %{
      id: attrs.id,
      tenant_id: attrs.tenant_id,
      group_id: attrs.group_id,
      device_id: attrs.device_id,
      status: if(desired_enabled, do: "enrolling", else: "disabled"),
      revision: 1,
      policy_revision: 1,
      desired_enabled: desired_enabled,
      enrollment_token_hash: digest(attrs.enrollment_token),
      created_at: now,
      updated_at: now
    }

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "agent-vmm:" <> attrs.tenant_id
      ])

      if Repo.aggregate(
           from(r in Registration,
             where: r.tenant_id == ^attrs.tenant_id and r.status != "revoked"
           ),
           :count
         ) >=
           limit do
        Repo.rollback(:tenant_quota)
      end

      enforce_multi_scope_gate!(attrs)

      case Repo.insert_all(Registration, [row], on_conflict: :nothing) do
        {1, _} -> Repo.get!(Registration, attrs.id)
        {0, _} -> Repo.rollback(:already_exists)
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  defp enforce_multi_scope_gate!(attrs) do
    if not Application.get_env(:salix_store, :agent_vmm_multi_scope_registration_enabled, false) and
         Repo.exists?(
           from(r in Registration,
             where:
               r.tenant_id == ^attrs.tenant_id and r.device_id == ^attrs.device_id and
                 r.group_id != ^attrs.group_id and r.status != "revoked"
           )
         ) do
      Repo.rollback(:multi_scope_disabled)
    end
  end

  def enroll(registration_id, enrollment_token, credential)
      when is_binary(enrollment_token) and byte_size(enrollment_token) >= 16 and
             is_binary(credential) and byte_size(credential) >= 32 do
    case enroll_with_bundle(registration_id, enrollment_token, credential, fn _ -> {:ok, nil} end) do
      {:ok, {registration, nil}} -> {:ok, registration}
      other -> other
    end
  end

  def enroll_with_bundle(registration_id, enrollment_token, credential, issuer)
      when is_binary(enrollment_token) and byte_size(enrollment_token) >= 16 and
             is_binary(credential) and byte_size(credential) >= 32 and is_function(issuer, 1) do
    Repo.transaction(fn ->
      registration =
        Repo.one(from(r in Registration, where: r.id == ^registration_id, lock: "FOR UPDATE")) ||
          Repo.rollback(:registration_not_found)

      if registration.status == "revoked" or is_nil(registration.enrollment_token_hash) or
           not secure_equal?(registration.enrollment_token_hash, digest(enrollment_token)) do
        Repo.rollback(:invalid_enrollment)
      end

      bundle =
        case issuer.(registration) do
          {:ok, value} ->
            value

          {:error, reason}
          when reason in [
                 :device_identity_mismatch,
                 :managed_anchor_unavailable,
                 :managed_trust_signer_unavailable,
                 :managed_trust_unavailable,
                 :anchor_inactive,
                 :authority_mismatch,
                 :invalid_expiry,
                 :signer_unavailable,
                 :already_exists,
                 :unavailable
               ] ->
            Repo.rollback(reason)

          _ ->
            Repo.rollback(:managed_trust_unavailable)
        end

      {1, _} =
        Repo.update_all(from(r in Registration, where: r.id == ^registration_id),
          set: [
            credential_hash: digest(credential),
            enrollment_token_hash: nil,
            status: "ready",
            desired_enabled: true,
            updated_at: DateTime.utc_now()
          ],
          inc: [revision: 1]
        )

      audit!(registration.tenant_id, "registration", registration_id, "enroll", "succeeded", %{})
      {Repo.get!(Registration, registration_id), bundle}
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def authenticate_registration(registration_id, credential) when is_binary(credential) do
    case Repo.get(Registration, registration_id) do
      %Registration{status: status, credential_hash: hash}
      when status != "revoked" and is_binary(hash) ->
        if secure_equal?(hash, digest(credential)), do: :ok, else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def configure_registration(id, expected_revision, enabled)
      when is_binary(id) and is_integer(expected_revision) and is_boolean(enabled) do
    Repo.transaction(fn ->
      registration =
        Repo.one(from(r in Registration, where: r.id == ^id, lock: "FOR UPDATE")) ||
          Repo.rollback(:revision_conflict)

      Compute.lock_provider_bindings!(id)

      if registration.revision != expected_revision or registration.status == "revoked" do
        Repo.rollback(:revision_conflict)
      end

      now = DateTime.utc_now()

      if not enabled do
        fence_registration_bindings!(id, "disabled", now)
      end

      {1, _} =
        Repo.update_all(from(r in Registration, where: r.id == ^id),
          set: [
            desired_enabled: enabled,
            status:
              cond do
                not enabled -> "disabled"
                is_binary(registration.credential_hash) -> "ready"
                true -> "enrolling"
              end,
            updated_at: now
          ],
          inc: [revision: 1]
        )

      Repo.get!(Registration, id)
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def revoke_registration(tenant_id, id, expected_revision) do
    Repo.transaction(fn ->
      registration = Repo.one!(from(r in Registration, where: r.id == ^id, lock: "FOR UPDATE"))

      Compute.lock_provider_bindings!(id)

      if registration.tenant_id != tenant_id or registration.revision != expected_revision or
           registration.status == "revoked" do
        Repo.rollback(:revision_conflict)
      end

      now = DateTime.utc_now()

      {1, _} =
        Repo.update_all(from(r in Registration, where: r.id == ^id),
          set: [
            status: "revoked",
            desired_enabled: false,
            credential_hash: nil,
            enrollment_token_hash: nil,
            updated_at: now
          ],
          inc: [revision: 1, policy_revision: 1]
        )

      fence_registration_bindings!(id, "revoked", now)

      audit!(tenant_id, "registration", id, "revoked", "succeeded", %{})
      Repo.get!(Registration, id)
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  defp fence_registration_bindings!(registration_id, status, now)
       when status in ["disabled", "revoked"] do
    binding_ids =
      Repo.all(
        from(b in Compute.ProviderBinding,
          where: b.provider == "agent_vmm" and b.provider_ref == ^registration_id,
          select: b.id
        )
      )

    Enum.each(binding_ids, fn binding_id ->
      case Compute.mark_provider_connection_lost(binding_id) do
        {:ok, _result} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    allocation_ids =
      Repo.all(
        from(a in Compute.Allocation,
          where:
            a.provider_binding_id in ^binding_ids and
              a.status not in ["released", "failed"],
          select: a.id
        )
      )

    Compute.drain_allocations_with_release!(allocation_ids, now)

    Repo.update_all(
      from(w in Compute.Workload,
        where: w.allocation_id in ^allocation_ids and w.desired_state == "ready"
      ),
      set: [desired_state: "draining", updated_at: now],
      inc: [revision: 1]
    )

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id in ^binding_ids),
      set: [status: status, updated_at: now],
      inc: [revision: 1, generation: 1]
    )
  end

  @doc "Observe one Agent VMM host and a bounded allocation snapshot."
  def observe_registration(registration_id, gateway_instance_id, hello)
      when is_binary(registration_id) and is_binary(gateway_instance_id) and is_map(hello) do
    epoch = canonical_uint64_field(hello, "connectionEpoch")
    watermark = integer_field(hello, "inventoryWatermark")
    inventory = Map.get(hello, "inventory", [])

    if is_nil(epoch) or watermark < 0 or not is_list(inventory) or length(inventory) > 64 do
      {:error, :invalid_observation}
    else
      Repo.transaction(fn ->
        registration =
          Repo.one!(from(r in Registration, where: r.id == ^registration_id, lock: "FOR UPDATE"))

        if registration.status != "ready" or not registration.desired_enabled do
          Repo.rollback(:registration_inactive)
        end

        # The pinned connector supplies a cryptographically random non-zero
        # connection fence. It is opaque, not an ordered counter: equality is
        # a duplicate, while any different value replaces and fences the old
        # stream after its outstanding commands are settled below.
        current_observation =
          Repo.one(
            from(o in RegistrationObservation,
              where: o.registration_id == ^registration_id,
              lock: "FOR UPDATE"
            )
          )

        current_binding? =
          Repo.exists?(
            from(b in Compute.ProviderBinding,
              where:
                b.provider == "agent_vmm" and b.provider_ref == ^registration_id and
                  fragment("?->>'connection_epoch'", b.observation) == ^epoch
            )
          )

        if current_binding? or
             (current_observation && current_observation.connection_epoch == epoch) do
          Repo.rollback(:stale_connection)
        end

        inventory_by_id =
          Map.new(inventory, fn item ->
            id = Map.get(item, "allocationId")
            if not is_binary(id) or id == "", do: Repo.rollback(:invalid_observation)
            {id, item}
          end)

        if map_size(inventory_by_id) != length(inventory) do
          Repo.rollback(:invalid_observation)
        end

        observed_ids = Map.keys(inventory_by_id)

        known_allocations =
          Repo.all(
            from(a in Compute.Allocation,
              join: b in Compute.ProviderBinding,
              on: b.id == a.provider_binding_id,
              where:
                a.id in ^observed_ids and b.provider == "agent_vmm" and
                  b.provider_ref == ^registration_id and a.status != "failed",
              lock: "FOR UPDATE"
            )
          )

        if length(known_allocations) != length(observed_ids),
          do: Repo.rollback(:invalid_observation)

        observed_allocations = Enum.reject(known_allocations, &(&1.status == "released"))

        now = DateTime.utc_now()

        case Compute.mark_provider_connections_lost("agent_vmm", registration_id) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        update_registration_bindings(
          registration_id,
          gateway_instance_id,
          epoch,
          watermark,
          now
        )

        Enum.each(observed_allocations, fn allocation ->
          item = Map.fetch!(inventory_by_id, allocation.id)
          provider_revision = integer_field(item, "revision")
          provider_state = inventory_allocation_state(Map.get(item, "state"))
          status = inventory_allocation_status(provider_state)

          observed_provider_revision =
            integer_field(allocation.provider_observation || %{}, "allocation_revision")

          if provider_revision <= 0 or is_nil(status),
            do: Repo.rollback(:invalid_observation)

          cond do
            observed_provider_revision > 0 and provider_revision < observed_provider_revision ->
              # A reconnect snapshot can have been captured before a command
              # completion advanced this allocation. The bounded snapshot is
              # not authoritative over newer per-allocation facts.
              :ok

            true ->
              observation_result =
                if provider_state == "discarded" do
                  Compute.complete_discarded_release(
                    allocation.id,
                    allocation.revision,
                    allocation.generation,
                    provider_revision
                  )
                else
                  Compute.observe_allocation(
                    allocation.id,
                    allocation.revision,
                    allocation.generation,
                    status,
                    "succeeded",
                    %{
                      "allocation_revision" => provider_revision,
                      "allocation_state" => provider_state
                    },
                    authoritative_inventory: true,
                    merge_provider_observation: true
                  )
                end

              case observation_result do
                {:ok, _observed} ->
                  :ok

                {:error, :stale_generation} ->
                  :ok

                {:error, reason} ->
                  Repo.rollback(reason)
              end
          end
        end)

        # Host command ordering is scoped to one connection epoch. The
        # registration lock also serializes command creation, so resetting the
        # cursor here becomes visible atomically with the new epoch only after
        # every old-epoch settlement and inventory fence above has committed.
        Repo.update_all(from(r in Registration, where: r.id == ^registration.id),
          set: [next_controller_sequence: 1, updated_at: now]
        )

        case Map.get(hello, "observation") do
          observation when is_map(observation) ->
            case settle_observation_locked(
                   registration,
                   gateway_instance_id,
                   epoch,
                   observation,
                   now,
                   true
                 ) do
              {:ok, _changed?} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

          nil ->
            Repo.delete_all(
              from(o in RegistrationObservation, where: o.registration_id == ^registration.id)
            )

          _ ->
            Repo.rollback(:invalid_observation)
        end

        audit!(
          registration.tenant_id,
          "registration",
          registration_id,
          "connection_observed",
          "succeeded",
          %{
            "connection_epoch" => epoch
          }
        )

        {watermark, now}
      end)
      |> case do
        {:ok, {committed_watermark, observed_at}} ->
          reconcile_scoped_environments(registration_id, committed_watermark, observed_at)
          {:ok, :ok}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp update_registration_bindings(
         registration_id,
         gateway_instance_id,
         epoch,
         watermark,
         now
       ) do
    environment_scope_enabled =
      Application.get_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, false)

    scoped =
      from(b in Compute.ProviderBinding,
        where: b.provider == "agent_vmm" and b.provider_ref == ^registration_id
      )

    scoped =
      if environment_scope_enabled,
        do: from(b in scoped, where: not is_nil(b.environment_id)),
        else: from(b in scoped, where: is_nil(b.environment_id))

    available_observation = %{
      "gateway_instance_id" => gateway_instance_id,
      "connection_epoch" => epoch,
      "inventory_watermark" => watermark,
      "inventory_snapshot_bounded" => true,
      "admission" => "accepting"
    }

    if environment_scope_enabled do
      Repo.query!(
        """
        UPDATE compute_provider_bindings AS binding
        SET generation = environment.generation
        FROM compute_environments AS environment
        WHERE binding.environment_id = environment.id
          AND binding.provider = 'agent_vmm'
          AND binding.provider_ref = $1
        """,
        [registration_id]
      )
    end

    Repo.update_all(scoped,
      set: [status: "available", observation: available_observation, updated_at: now],
      inc: [revision: 1]
    )
  end

  defp reconcile_scoped_environments(registration_id, watermark, now) do
    available_environment_ids =
      from(b in Compute.ProviderBinding,
        join: e in Compute.Environment,
        on:
          e.id == b.environment_id and e.pool_id == b.pool_id and
            e.generation == b.generation,
        where:
          b.provider == "agent_vmm" and b.provider_ref == ^registration_id and
            b.status == "available" and not is_nil(b.environment_id),
        select: b.environment_id
      )

    Repo.update_all(
      from(e in Compute.Environment,
        where:
          e.id in subquery(available_environment_ids) and e.desired_state == "ready" and
            (e.observed_state != "ready" or e.inventory_watermark < ^watermark)
      ),
      set: [observed_state: "ready", inventory_watermark: watermark, updated_at: now],
      inc: [revision: 1]
    )
  end

  @doc "Settle a current Host-owned observation for one exact connection fence."
  def settle_registration_observation(
        registration_id,
        gateway_instance_id,
        connection_epoch,
        observation
      )
      when is_binary(registration_id) and is_binary(gateway_instance_id) and
             is_binary(connection_epoch) and is_map(observation) do
    Repo.transaction(fn ->
      registration =
        Repo.one!(from(r in Registration, where: r.id == ^registration_id, lock: "FOR UPDATE"))

      bindings = Compute.lock_provider_bindings!(registration_id)

      current? =
        Enum.any?(bindings, fn binding ->
          Map.get(binding.observation, "gateway_instance_id") == gateway_instance_id and
            Map.get(binding.observation, "connection_epoch") == connection_epoch
        end)

      if not current?, do: Repo.rollback(:stale_connection)

      case settle_observation_locked(
             registration,
             gateway_instance_id,
             connection_epoch,
             observation,
             DateTime.utc_now(),
             false
           ) do
        {:ok, _changed?} ->
          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def settle_registration_observation(_, _, _, _), do: {:error, :invalid_observation}

  defp settle_observation_locked(
         registration,
         gateway_instance_id,
         connection_epoch,
         observation,
         received_at,
         replace_fence?
       ) do
    with {:ok, attrs} <-
           normalize_registration_observation(
             registration.id,
             gateway_instance_id,
             connection_epoch,
             observation,
             received_at
           ) do
      current =
        Repo.one(
          from(o in RegistrationObservation,
            where: o.registration_id == ^registration.id,
            lock: "FOR UPDATE"
          )
        )

      cond do
        current == nil ->
          {1, _} = Repo.insert_all(RegistrationObservation, [attrs])
          {:ok, true}

        current.gateway_instance_id == gateway_instance_id and
          current.connection_epoch == connection_epoch and
            attrs.observation_sequence > current.observation_sequence ->
          {1, _} =
            Repo.update_all(
              from(o in RegistrationObservation, where: o.registration_id == ^registration.id),
              set: Map.to_list(Map.delete(attrs, :registration_id))
            )

          {:ok, true}

        replace_fence? and
            (current.gateway_instance_id != gateway_instance_id or
               current.connection_epoch != connection_epoch) ->
          {1, _} =
            Repo.update_all(
              from(o in RegistrationObservation, where: o.registration_id == ^registration.id),
              set: Map.to_list(Map.delete(attrs, :registration_id))
            )

          {:ok, true}

        true ->
          {:error, :stale_observation}
      end
    end
  end

  defp normalize_registration_observation(
         registration_id,
         gateway_instance_id,
         connection_epoch,
         observation,
         received_at
       ) do
    sequence = integer_field(observation, "sequence")
    watermark = integer_field(observation, "inventoryWatermark")
    protocol = Map.get(observation, "protocolVersion")
    host_api = Map.get(observation, "hostApiVersion")
    release = Map.get(observation, "connectorRelease")
    features = Map.get(observation, "supportedFeatures", [])
    health = Map.get(observation, "health", %{})
    health_status = Map.get(health, "status")
    health_issue = Map.get(health, "issue")
    health_message = Map.get(health, "message")

    with true <- sequence in 1..9_223_372_036_854_775_807,
         true <- watermark in 0..9_223_372_036_854_775_807,
         {:ok, observed_at} <- observation_time(observation, "observedUnixMillis", received_at),
         {:ok, inventory_at} <-
           observation_time(observation, "inventoryObservedUnixMillis", received_at),
         true <- bounded_text?(gateway_instance_id, 128),
         true <- bounded_text?(connection_epoch, 20),
         true <- bounded_text?(protocol, 32),
         true <- bounded_text?(host_api, 32),
         true <- is_nil(release) or bounded_text?(release, 128),
         true <- valid_features?(features),
         true <- health_status in ["healthy", "degraded", "unavailable"],
         true <-
           health_issue in [
             nil,
             "host_degraded",
             "host_unavailable",
             "observation_unavailable",
             "observation_time_invalid"
           ],
         true <- is_nil(health_message) or bounded_text?(health_message, 256),
         {:ok, components} <- normalize_health_components(Map.get(health, "components", [])),
         {:ok, capacity} <- normalize_capacity(Map.get(observation, "capacity", %{})),
         {:ok, usage} <- normalize_usage(Map.get(observation, "usage", %{})),
         {:ok, candidate} <-
           normalize_reclaim_candidate(
             Map.get(observation, "reclaimCandidate"),
             registration_id
           ) do
      {:ok,
       %{
         registration_id: registration_id,
         gateway_instance_id: gateway_instance_id,
         connection_epoch: connection_epoch,
         observation_sequence: sequence,
         observed_at: observed_at,
         received_at: received_at,
         disconnected_at: nil,
         protocol_version: protocol,
         host_api_version: host_api,
         connector_release: release,
         supported_features: features,
         capacity: capacity,
         health_status: health_status,
         health_issue: health_issue,
         health_message: canonical_health_message(health_status, health_issue),
         health_components: components,
         usage: Map.put(usage, "workload_reclaim_candidate", candidate),
         inventory_watermark: watermark,
         inventory_observed_at: inventory_at
       }}
    else
      _ -> {:error, :invalid_observation}
    end
  end

  defp normalize_reclaim_candidate(nil, _registration_id), do: {:ok, nil}

  defp normalize_reclaim_candidate(candidate, registration_id) when is_map(candidate) do
    expires = integer_field(candidate, "expiresUnixMillis")

    if candidate["registrationId"] == registration_id and expires > 0 and
         Enum.all?(
           ~w(allocationId containerId containerInstanceId),
           &bounded_text?(candidate[&1], 256)
         ) do
      {:ok,
       %{
         "registration_id" => registration_id,
         "allocation_id" => candidate["allocationId"],
         "container_id" => candidate["containerId"],
         "instance_id" => candidate["containerInstanceId"],
         "expires_at_ms" => expires
       }}
    else
      {:error, :invalid_observation}
    end
  end

  defp normalize_reclaim_candidate(_, _), do: {:error, :invalid_observation}

  defp canonical_health_message("degraded", "host_degraded"),
    do: "Host health is degraded."

  defp canonical_health_message("unavailable", "host_unavailable"),
    do: "Host health is unavailable."

  defp canonical_health_message("unavailable", "observation_unavailable"),
    do: "Host observation is unavailable."

  defp canonical_health_message("unavailable", "observation_time_invalid"),
    do: "Host observation time is invalid."

  defp canonical_health_message(_status, _issue), do: nil

  defp observation_time(map, key, received_at) do
    millis = integer_field(map, key)

    with {:ok, value} <- DateTime.from_unix(millis, :millisecond),
         true <- DateTime.compare(value, DateTime.add(received_at, -120, :second)) != :lt,
         true <- DateTime.compare(value, DateTime.add(received_at, 30, :second)) != :gt do
      {:ok, %{value | microsecond: {elem(value.microsecond, 0), 6}}}
    else
      _ -> {:error, :invalid_observation}
    end
  end

  defp bounded_text?(value, max), do: is_binary(value) and byte_size(value) in 1..max

  defp valid_features?(values) do
    is_list(values) and length(values) <= 32 and
      Enum.all?(values, &bounded_text?(&1, 64)) and Enum.uniq(values) == values
  end

  @public_health_components ~w(vmmd state-disk network egress quota containerd/runsc host-egress)
  @public_reconcile_error_codes ~w(
    aborted
    already_exists
    canceled
    deadline_exceeded
    failed_precondition
    image_import_failed
    invalid_argument
    not_found
    permission_denied
    resource_capacity_exhausted
    resource_exhausted
    unauthenticated
    unavailable
  )
  defp normalize_health_components(values) when is_list(values) and length(values) <= 16 do
    if Enum.all?(values, fn value ->
         is_map(value) and Map.get(value, "component") in @public_health_components and
           Map.get(value, "status") in ["healthy", "degraded", "unavailable"]
       end) do
      {:ok, Map.new(values, &{Map.get(&1, "component"), Map.get(&1, "status")})}
    else
      {:error, :invalid_observation}
    end
  end

  defp normalize_health_components(_), do: {:error, :invalid_observation}

  defp normalize_capacity(value) when is_map(value) do
    limits = fn item ->
      %{
        "pids" => integer_field(item, "pids"),
        "disk_bytes" => integer_field(item, "diskBytes")
      }
    end

    result = %{
      "per_environment_limits" => limits.(Map.get(value, "perEnvironmentLimits", %{})),
      "max_egress_mode" => Map.get(value, "maxEgressMode")
    }

    integers = Map.values(result["per_environment_limits"])

    if Enum.all?(integers, &(&1 in 0..9_223_372_036_854_775_807)) and
         result["max_egress_mode"] in [
           nil,
           "EGRESS_MODE_UNSPECIFIED",
           "EGRESS_MODE_DENY_ALL",
           "EGRESS_MODE_PUBLIC_INTERNET"
         ] do
      {:ok, result}
    else
      {:error, :invalid_observation}
    end
  end

  defp normalize_capacity(_), do: {:error, :invalid_observation}

  @doc false
  def project_reconcile_error(
        %{
          "code" => code,
          "stage" => stage,
          "resource" => resource,
          "message" => message
        } = error
      )
      when is_binary(code) and is_binary(stage) and is_binary(resource) and is_binary(message) do
    if code in @public_reconcile_error_codes and
         canonical_reconcile_error_shape?(code, stage, resource) and
         byte_size(message) in 1..256 do
      Enum.reduce(
        ["available_bytes", "required_bytes"],
        Map.take(error, ["code", "stage", "resource", "message"]),
        fn key, result ->
          case Map.get(error, key) do
            value when is_integer(value) and value in 0..9_223_372_036_854_775_807 ->
              Map.put(result, key, value)

            _ ->
              result
          end
        end
      )
    end
  end

  def project_reconcile_error(_), do: nil

  defp canonical_reconcile_error_shape?(
         "resource_capacity_exhausted",
         "import_admission",
         "storage_headroom"
       ),
       do: true

  defp canonical_reconcile_error_shape?(
         "resource_capacity_exhausted",
         "import_slot",
         "import_slot"
       ),
       do: true

  defp canonical_reconcile_error_shape?("image_import_failed", "image_import", "image"), do: true

  defp canonical_reconcile_error_shape?(code, "image_import", "runtime"),
    do:
      code in @public_reconcile_error_codes and
        code not in ~w(resource_capacity_exhausted image_import_failed)

  defp canonical_reconcile_error_shape?(_, _, _), do: false

  defp normalize_usage(value) when is_map(value) do
    keys =
      ~w(cpuNanos memoryBytes pids readBytes writeBytes diskBytes networkRxBytes networkTxBytes sampledUnixMillis)

    integers = Map.new(keys, &{Macro.underscore(&1), integer_field(value, &1)})
    stale = Map.get(value, "stale", false)
    issue = Map.get(value, "issue")

    if Enum.all?(Map.values(integers), &(&1 in 0..9_223_372_036_854_775_807)) and
         is_boolean(stale) and
         issue in [
           nil,
           "usage_unavailable",
           "usage_stale",
           "observation_unavailable",
           "observation_time_invalid"
         ] do
      {:ok, Map.merge(integers, %{"stale" => stale, "issue" => issue})}
    else
      {:error, :invalid_observation}
    end
  end

  defp normalize_usage(_), do: {:error, :invalid_observation}

  defp inventory_allocation_state("ALLOCATION_STATE_READY"), do: "ready"
  defp inventory_allocation_state("ALLOCATION_STATE_RETAINED"), do: "retained"
  defp inventory_allocation_state("ALLOCATION_STATE_DRAINING"), do: "draining"
  defp inventory_allocation_state("ALLOCATION_STATE_DISCARDED"), do: "discarded"
  defp inventory_allocation_state(_), do: nil

  defp inventory_allocation_status(state) when state in ["ready", "retained"],
    do: "ready"

  defp inventory_allocation_status("draining"), do: "draining"
  defp inventory_allocation_status("discarded"), do: "released"
  defp inventory_allocation_status(_), do: nil

  def claim_registration_command(registration_id, gateway_instance_id, connection_epoch)
      when is_binary(connection_epoch) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      registration =
        Repo.one!(
          from(r in Registration,
            where: r.id == ^registration_id,
            lock: "FOR UPDATE"
          )
        )

      if not is_integer(registration.next_controller_sequence) or
           registration.next_controller_sequence < 1 do
        Repo.rollback(:invalid_controller_sequence)
      end

      commands =
        Repo.all(
          from(c in Compute.Command,
            join: a in Compute.Allocation,
            on: a.id == c.allocation_id,
            left_join: w in Compute.Workload,
            on: w.id == c.workload_id and w.environment_id == a.environment_id,
            join: b in Compute.ProviderBinding,
            on: b.id == a.provider_binding_id,
            join: r in Registration,
            on: r.id == b.provider_ref,
            join: e in Compute.Environment,
            on: e.id == a.environment_id,
            where:
              b.provider == "agent_vmm" and b.provider_ref == ^registration_id and
                b.status == "available" and r.status == "ready" and r.desired_enabled == true and
                ((c.kind != "allocation.release" and not is_nil(w.id) and
                    w.allocation_id == a.id and
                    w.desired_state == "ready" and
                    fragment("(?->>'workload_generation')::bigint", c.payload) == w.generation and
                    e.desired_state == "ready" and e.generation == a.generation) or
                   (c.kind == "allocation.release" and is_nil(c.workload_id) and
                      c.release_incarnation ==
                        fragment("'allocation.release:' || ? || ':' || ?", a.id, a.generation) and
                      e.generation >= a.generation and
                      (a.status == "draining" or
                         (a.status == "ready" and
                            fragment("?->>'allocation_state'", a.provider_observation) ==
                              "retained")))) and
                fragment("?->>'gateway_instance_id'", b.observation) == ^gateway_instance_id and
                fragment("?->>'connection_epoch'", b.observation) == ^connection_epoch and
                fragment("?->>'admission'", b.observation) == "accepting" and
                a.status != "released" and
                c.status == "pending" and c.deadline_at > ^now and
                c.target_generation == a.generation and c.target_revision == a.revision,
            order_by: [asc: c.created_at, asc: c.id],
            limit: 32,
            lock: "FOR UPDATE OF c0 SKIP LOCKED"
          )
        )

      command = List.first(commands)

      if is_nil(command) do
        nil
      else
        sequence = registration.next_controller_sequence
        command_json = get_in(command.payload, ["command_json"])

        if not is_map(command_json), do: Repo.rollback(:invalid_command)

        payload =
          put_in(
            command.payload,
            ["command_json"],
            Map.merge(command_json, %{
              "connectionEpoch" => connection_epoch,
              "sequence" => sequence
            })
          )

        {1, _} =
          Repo.update_all(
            from(c in Compute.Command, where: c.id == ^command.id and c.status == "pending"),
            set: [
              status: "admitted",
              connection_epoch: connection_epoch,
              payload: payload,
              updated_at: now
            ]
          )

        {1, _} =
          Repo.update_all(
            from(r in Registration, where: r.id == ^registration.id),
            set: [next_controller_sequence: sequence + 1, updated_at: now]
          )

        Repo.get!(Compute.Command, command.id)
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def claim_registration_command(_, _, _), do: {:error, :invalid_epoch}

  def commit_registration_result(
        registration_id,
        gateway_instance_id,
        connection_epoch,
        command_id,
        status,
        evidence
      )
      when is_binary(connection_epoch) and status in ~w(succeeded failed unknown_outcome) and
             is_map(evidence) do
    result =
      Repo.transaction(fn ->
        command =
          Repo.one(
            from(c in Compute.Command,
              join: a in Compute.Allocation,
              on: a.id == c.allocation_id,
              join: b in Compute.ProviderBinding,
              on: b.id == a.provider_binding_id,
              where:
                c.id == ^command_id and b.provider == "agent_vmm" and
                  b.provider_ref == ^registration_id and
                  fragment("?->>'gateway_instance_id'", b.observation) == ^gateway_instance_id and
                  fragment("?->>'connection_epoch'", b.observation) == ^connection_epoch and
                  c.connection_epoch == ^connection_epoch and
                  c.status in ["admitted", "executing"],
              lock: "FOR UPDATE"
            )
          )

        if is_nil(command), do: Repo.rollback(:stale_command)

        settled_at = DateTime.utc_now()

        retry_at =
          if command.kind == "allocation.release" and status in ["failed", "unknown_outcome"],
            do: DateTime.add(settled_at, 5, :second)

        {1, _} =
          Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
            set: [
              status: status,
              outcome: command_outcome(status),
              evidence: evidence,
              next_attempt_at: retry_at,
              updated_at: settled_at
            ]
          )

        case apply_command_result(command, status, evidence, connection_epoch) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def commit_registration_result(_, _, _, _, _, _), do: {:error, :invalid_epoch}

  defp command_outcome("succeeded"), do: "succeeded"
  defp command_outcome("unknown_outcome"), do: "unknown"
  defp command_outcome("failed"), do: "failed"

  defp apply_command_result(command, "failed", evidence, _epoch)
       when command.kind == "allocation.ensure" do
    result = Map.get(evidence, "result", %{})

    if Map.get(result, "reason") == "ERROR_REASON_CAPACITY_EXHAUSTED" do
      Compute.park_capacity_action_required_locked(command, evidence)
    else
      :ok
    end
  end

  defp apply_command_result(_command, status, _evidence, _epoch)
       when status in ["failed", "unknown_outcome"],
       do: :ok

  defp apply_command_result(command, "succeeded", evidence, _epoch)
       when command.kind == "allocation.ensure" do
    allocation = get_in(evidence, ["result", "allocation"]) || %{}

    if Map.get(allocation, "allocationId") != command.allocation_id or
         integer_field(allocation, "revision") <= 0 do
      {:error, :invalid_host_result}
    else
      case Compute.observe_allocation(
             command.allocation_id,
             command.target_revision,
             command.target_generation,
             "ready",
             "succeeded",
             %{
               "allocation_revision" => integer_field(allocation, "revision"),
               "allocation_state" => "ready"
             },
             merge_provider_observation: true
           ) do
        {:ok, _allocation} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp apply_command_result(command, "succeeded", evidence, _epoch)
       when command.kind == "allocation.release" do
    allocation = get_in(evidence, ["result", "allocation"]) || %{}

    if Map.get(allocation, "allocationId") != command.allocation_id or
         integer_field(allocation, "revision") <= 0 do
      {:error, :invalid_host_result}
    else
      case Compute.observe_allocation(
             command.allocation_id,
             command.target_revision,
             command.target_generation,
             "released",
             "succeeded",
             %{"allocation_revision" => integer_field(allocation, "revision")},
             retired_generation_release: true
           ) do
        {:ok, _released} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp apply_command_result(command, "succeeded", evidence, epoch)
       when command.kind == "runtime.open_session" do
    session = get_in(evidence, ["result", "sessionReady"]) || %{}
    generation = get_in(command.payload, ["command_json", "openSession", "allocationGeneration"])
    expires_unix_millis = integer_field(session, "expiresUnixMillis")

    if Map.get(session, "allocationId") != command.allocation_id or
         integer_field(session, "allocationGeneration") != generation or
         expires_unix_millis <= System.system_time(:millisecond) or
         not is_binary(Map.get(session, "tunnelNonce")) or Map.get(session, "tunnelNonce") == "" do
      {:error, :invalid_host_result}
    else
      workload = Repo.get!(Compute.Workload, command.workload_id)

      case Repo.get_by(Compute.RuntimeInstance,
             workload_id: command.workload_id,
             allocation_id: command.allocation_id,
             generation: workload.generation
           ) do
        %Compute.RuntimeInstance{} ->
          :ok

        nil ->
          case Compute.prepare_runtime_bootstrap(%{
                 id: "runtime:" <> command.workload_id,
                 workload_id: command.workload_id,
                 allocation_id: command.allocation_id,
                 generation: workload.generation,
                 connection_epoch: epoch
               }) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp apply_command_result(_command, "succeeded", _evidence, _epoch),
    do: :ok

  def observe_session(registration_id, gateway_instance_id, header) when is_map(header) do
    allocation_id = Map.get(header, "allocationId")
    generation = integer_field(header, "allocationGeneration")
    epoch = canonical_uint64_field(header, "connectionEpoch")
    tunnel_nonce = Map.get(header, "tunnelNonce")
    expires_unix_millis = integer_field(header, "expiresUnixMillis")

    if generation <= 0 or is_nil(epoch) or
         not is_binary(tunnel_nonce) or tunnel_nonce == "" or expires_unix_millis <= 0 do
      {:error, :stale_session}
    else
      with {:ok, session_expires_at} <-
             DateTime.from_unix(expires_unix_millis, :millisecond),
           :gt <- DateTime.compare(session_expires_at, DateTime.utc_now()) do
        session_expires_at = DateTime.add(session_expires_at, 0, :microsecond)

        Repo.transaction(fn ->
          allocation =
            Repo.one!(
              from(a in Compute.Allocation,
                join: b in Compute.ProviderBinding,
                on: b.id == a.provider_binding_id,
                where:
                  a.id == ^allocation_id and a.generation == ^generation and
                    b.provider == "agent_vmm" and
                    b.provider_ref == ^registration_id and
                    fragment("?->>'gateway_instance_id'", b.observation) == ^gateway_instance_id and
                    fragment("?->>'connection_epoch'", b.observation) == ^epoch,
                lock: "FOR UPDATE"
              )
            )

          runtime_id = current_runtime_id!(allocation.id)

          runtime = Repo.get!(Compute.RuntimeInstance, runtime_id)
          workload = Repo.get!(Compute.Workload, runtime.workload_id)

          if runtime.allocation_id != allocation.id or
               runtime.generation != workload.generation do
            Repo.rollback(:stale_session)
          end

          if not server_issued_session_capability?(
               allocation,
               runtime.workload_id,
               generation,
               tunnel_nonce,
               expires_unix_millis
             ) do
            Repo.rollback(:stale_session)
          end

          now = DateTime.utc_now()
          id = Enum.join([registration_id, runtime_id, generation], ":")

          Repo.insert_all(
            Session,
            [
              %{
                id: id,
                registration_id: registration_id,
                runtime_instance_id: runtime_id,
                allocation_id: allocation.id,
                allocation_generation: generation,
                connection_epoch: epoch,
                gateway_instance_id: gateway_instance_id,
                status: "ready",
                expires_at: session_expires_at,
                updated_at: now
              }
            ],
            conflict_target: [:registration_id, :runtime_instance_id, :allocation_generation],
            on_conflict:
              {:replace,
               [
                 :connection_epoch,
                 :gateway_instance_id,
                 :status,
                 :expires_at,
                 :updated_at
               ]}
          )

          :ok
        end)
      else
        _ -> {:error, :stale_session}
      end
    end
  rescue
    _ -> {:error, :stale_session}
  end

  def current_session(workload_id, registration_id, allocation_id, allocation_generation) do
    current_session(
      workload_id,
      registration_id,
      allocation_id,
      allocation_generation,
      true
    )
  end

  def current_host_session(
        workload_id,
        registration_id,
        allocation_id,
        allocation_generation
      ) do
    current_session(
      workload_id,
      registration_id,
      allocation_id,
      allocation_generation,
      false
    )
  end

  defp current_session(
         workload_id,
         registration_id,
         allocation_id,
         allocation_generation,
         require_runtime_ready?
       ) do
    now = DateTime.utc_now()

    case Repo.one(
           from(s in Session,
             join: r in Compute.RuntimeInstance,
             on: r.id == s.runtime_instance_id,
             join: w in Compute.Workload,
             on: w.id == r.workload_id,
             join: a in Compute.Allocation,
             on: a.id == s.allocation_id,
             join: b in Compute.ProviderBinding,
             on: b.id == a.provider_binding_id,
             join: e in Compute.Environment,
             on: e.id == w.environment_id,
             where:
               w.id == ^workload_id and w.allocation_id == a.id and r.allocation_id == a.id and
                 s.registration_id == ^registration_id and s.allocation_id == ^allocation_id and
                 s.allocation_generation == ^allocation_generation and
                 s.status == "ready" and s.expires_at > ^now and
                 s.allocation_generation == a.generation and
                 a.status == "ready" and
                 w.desired_state == "ready" and e.desired_state == "ready" and
                 r.generation == w.generation and a.generation == e.generation and
                 b.provider == "agent_vmm" and b.status != "revoked" and
                 s.registration_id == b.provider_ref and
                 s.connection_epoch == fragment("?->>'connection_epoch'", b.observation) and
                 s.gateway_instance_id == fragment("?->>'gateway_instance_id'", b.observation)
           )
         ) do
      nil ->
        {:error, :not_found}

      session ->
        if runtime_session_ok?(session, require_runtime_ready?),
          do: {:ok, session},
          else: {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def current_session_for_workload(workload_id) when is_binary(workload_id) do
    current_session_for_workload(workload_id, true)
  end

  @doc "Resolve the current provider host session before Runtime Agent catch-up."
  def current_host_session_for_workload(workload_id) when is_binary(workload_id) do
    current_session_for_workload(workload_id, false)
  end

  @doc "Fence a vanished gateway session so reconciliation opens a fresh Host tunnel."
  # This recovery improves steady-state availability after rollout because a
  # gateway session can disappear at any time. It is not a mixed-version or
  # rollback hedge; its permanent consumer is the Workload reconciler. The
  # allocation revision bump also gives runtime.open_session a fresh durable
  # request identity instead of replaying the vanished session's evidence.
  def invalidate_host_session(workload_id, session_fence)
      when is_binary(workload_id) and is_map(session_fence) do
    Repo.transaction(fn ->
      session =
        Repo.one(
          from(s in Session,
            join: r in Compute.RuntimeInstance,
            on: r.id == s.runtime_instance_id,
            where: s.id == ^session_fence.session_id and r.workload_id == ^workload_id,
            lock: "FOR UPDATE",
            select: s
          )
        )

      if session && session.status == "ready" &&
           session.gateway_instance_id == session_fence.gateway_instance_id &&
           session.connection_epoch == session_fence.connection_epoch &&
           session.allocation_generation == session_fence.allocation_generation do
        allocation =
          Repo.one!(
            from(a in Compute.Allocation,
              where:
                a.id == ^session.allocation_id and
                  a.generation == ^session_fence.allocation_generation,
              lock: "FOR UPDATE"
            )
          )

        now = DateTime.utc_now()

        Repo.update_all(from(s in Session, where: s.id == ^session.id),
          set: [status: "stale", updated_at: now]
        )

        Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
          set: [updated_at: now],
          inc: [revision: 1]
        )
      end

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp current_session_for_workload(workload_id, require_runtime_ready?) do
    now = DateTime.utc_now()

    case Repo.one(
           from(s in Session,
             join: r in Compute.RuntimeInstance,
             on: r.id == s.runtime_instance_id,
             join: w in Compute.Workload,
             on: w.id == r.workload_id,
             join: a in Compute.Allocation,
             on: a.id == s.allocation_id,
             join: b in Compute.ProviderBinding,
             on: b.id == a.provider_binding_id,
             join: e in Compute.Environment,
             on: e.id == w.environment_id,
             where:
               w.id == ^workload_id and w.allocation_id == a.id and r.allocation_id == a.id and
                 s.status == "ready" and s.expires_at > ^now and
                 s.allocation_generation == a.generation and
                 a.status == "ready" and
                 w.desired_state == "ready" and e.desired_state == "ready" and
                 r.generation == w.generation and a.generation == e.generation and
                 b.provider == "agent_vmm" and b.status != "revoked" and
                 s.registration_id == b.provider_ref and
                 s.connection_epoch == fragment("?->>'connection_epoch'", b.observation) and
                 s.gateway_instance_id == fragment("?->>'gateway_instance_id'", b.observation),
             order_by: [desc: s.updated_at],
             select_merge: %{workload_generation: w.generation},
             limit: 1
           )
         ) do
      nil ->
        {:error, :not_found}

      session ->
        if runtime_session_ok?(session, require_runtime_ready?),
          do: {:ok, session},
          else: {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp runtime_session_ok?(session, false),
    do: not is_nil(Repo.get(Compute.RuntimeInstance, session.runtime_instance_id))

  defp runtime_session_ok?(session, true) do
    case Repo.get(Compute.RuntimeInstance, session.runtime_instance_id) do
      %Compute.RuntimeInstance{
        status: "connected",
        readiness: "ready",
        caught_up_epoch: epoch,
        connection_epoch: epoch
      } = runtime ->
        Compute.runtime_control_current?(runtime)

      _ ->
        false
    end
  end

  def mark_connection_lost(registration_id, gateway_instance_id, connection_epoch)
      when is_binary(connection_epoch) do
    Repo.transaction(fn ->
      # Registration is the observation owner. Serializing disconnect with
      # settlement prevents an accepted renewal from clearing disconnected_at
      # after the exact binding fence has been retired.
      Repo.one(
        from(r in Registration,
          where: r.id == ^registration_id,
          select: r.id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:stale_connection)

      all_bindings = Compute.lock_provider_bindings!(registration_id)

      bindings =
        Enum.filter(all_bindings, fn binding ->
          Map.get(binding.observation || %{}, "gateway_instance_id") == gateway_instance_id and
            Map.get(binding.observation || %{}, "connection_epoch") == connection_epoch
        end)

      totals =
        Enum.reduce(bindings, %{unknown_outcome: 0, pending: 0}, fn binding, acc ->
          case Compute.mark_provider_connection_lost(binding.id) do
            {:ok, result} -> Map.merge(acc, result, fn _key, left, right -> left + right end)
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      now = DateTime.utc_now()

      Repo.update_all(
        from(o in RegistrationObservation,
          where:
            o.registration_id == ^registration_id and
              o.gateway_instance_id == ^gateway_instance_id and
              o.connection_epoch == ^connection_epoch
        ),
        set: [disconnected_at: now]
      )

      Repo.update_all(
        from(s in Session,
          where:
            s.registration_id == ^registration_id and
              s.gateway_instance_id == ^gateway_instance_id and
              s.connection_epoch == ^connection_epoch
        ),
        set: [status: "disconnected", updated_at: now]
      )

      Repo.update_all(
        from(b in Compute.ProviderBinding,
          where: b.id in ^Enum.map(bindings, & &1.id) and b.status != "revoked"
        ),
        set: [status: "unavailable", observation: %{}, updated_at: now],
        inc: [revision: 1]
      )

      totals
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def mark_connection_lost(_, _, _), do: {:error, :invalid_epoch}

  @doc "Settle a bounded page of commands whose durable delivery or execution deadline elapsed."
  def settle_expired_commands(limit \\ 32, now \\ DateTime.utc_now())
      when limit in 1..32 and is_struct(now, DateTime) do
    Repo.transaction(fn ->
      commands =
        Repo.all(
          from(c in Compute.Command,
            join: a in Compute.Allocation,
            on: a.id == c.allocation_id,
            join: b in Compute.ProviderBinding,
            on: b.id == a.provider_binding_id,
            where:
              b.provider == "agent_vmm" and
                c.status in ["pending", "admitted", "executing"] and c.deadline_at <= ^now,
            order_by: [asc: c.deadline_at, asc: c.id],
            limit: ^limit,
            lock: "FOR UPDATE OF c0 SKIP LOCKED",
            select: c
          )
        )

      Enum.each(commands, fn command ->
        status =
          if command.classification == "side_effecting", do: "unknown_outcome", else: "failed"

        Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
          set: [
            status: status,
            outcome: command_outcome(status),
            evidence: %{"reason" => "execution_deadline_elapsed"},
            next_attempt_at:
              if(command.kind == "allocation.release",
                do: DateTime.add(now, 5, :second),
                else: nil
              ),
            updated_at: now
          ]
        )
      end)

      due_release_ids =
        Repo.all(
          from(c in Compute.Command,
            where:
              c.kind == "allocation.release" and
                c.status in ["failed", "unknown_outcome"] and
                not is_nil(c.next_attempt_at) and c.next_attempt_at <= ^now,
            order_by: [asc: c.status, asc: c.next_attempt_at, asc: c.id],
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED",
            select: c.id
          )
        )

      retry_results =
        Enum.map(due_release_ids, &Compute.refresh_due_release_obligation(&1, now))

      %{
        settled: length(commands),
        release_retries: Enum.count(retry_results, &match?({:ok, :reissued}, &1)),
        release_settled: Enum.count(retry_results, &match?({:ok, :settled}, &1)),
        release_blocked: Enum.count(retry_results, &match?({:error, _}, &1)),
        more?: length(commands) == limit or length(due_release_ids) == limit
      }
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def record_result(command_id, status, evidence)
      when status in ~w(succeeded failed) and is_map(evidence) do
    case Repo.get(Compute.Command, command_id) do
      %Compute.Command{kind: "allocation.release"} ->
        {:error, :release_requires_commit}

      %Compute.Command{} ->
        Compute.record_command_result(command_id, ~w(admitted executing), status, evidence)

      nil ->
        {:error, :not_found}
    end
  end

  defp current_runtime_id!(allocation_id) do
    Repo.one!(
      from(r in Compute.RuntimeInstance,
        join: w in Compute.Workload,
        on: w.id == r.workload_id,
        where: r.allocation_id == ^allocation_id and r.generation == w.generation,
        order_by: [desc: r.updated_at],
        limit: 1,
        select: r.id
      )
    )
  end

  # SessionReady is host evidence for an exact OpenSession capability that the
  # server already issued.
  defp server_issued_session_capability?(
         allocation,
         workload_id,
         allocation_generation,
         tunnel_nonce,
         expires_unix_millis
       ) do
    Repo.all(
      from(c in Compute.Command,
        where:
          c.allocation_id == ^allocation.id and c.workload_id == ^workload_id and
            c.kind == "runtime.open_session" and c.status == "succeeded" and
            c.target_generation == ^allocation.generation,
        order_by: [desc: c.updated_at],
        limit: 16,
        select: {c.payload, c.evidence}
      )
    )
    |> Enum.any?(fn {payload, evidence} ->
      issued_generation =
        integer_field(
          get_in(payload, ["command_json", "openSession"]) || %{},
          "allocationGeneration"
        )

      issued_nonce = get_in(evidence, ["result", "sessionReady", "tunnelNonce"])

      issued_expiry =
        integer_field(get_in(evidence, ["result", "sessionReady"]) || %{}, "expiresUnixMillis")

      issued_generation == allocation_generation and is_binary(issued_nonce) and
        secure_equal?(issued_nonce, tunnel_nonce) and issued_expiry == expires_unix_millis
    end)
  end

  defp integer_field(map, key) do
    case Map.get(map || %{}, key, 0) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> -1
        end

      _ ->
        -1
    end
  end

  defp canonical_uint64_field(map, key) do
    case Map.get(map || %{}, key) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed in 1..18_446_744_073_709_551_615 ->
            if Integer.to_string(parsed) == value, do: value

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp digest(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_, _), do: false

  defp audit!(tenant_id, subject_type, subject_id, action, outcome, metadata) do
    Repo.insert_all(AuditEvent, [
      %{
        tenant_id: tenant_id,
        subject_type: subject_type,
        subject_id: subject_id,
        action: action,
        outcome: outcome,
        metadata: metadata,
        created_at: DateTime.utc_now()
      }
    ])
  end
end
