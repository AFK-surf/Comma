defmodule SalixStore.PersonalMeshRegistry do
  @moduledoc """
  Provider-neutral personal mesh registry authority.

  Modeled in `tla/agent_vmm/PersonalMeshTrust.tla`. The registry verifies
  device-root signatures, applies expected-revision CAS, retains remove-wins
  tombstones until mesh deletion, and returns bounded full snapshots. It owns
  no mesh/device private key and cannot issue service route capabilities.
  """

  import Ecto.Query
  alias SalixStore.{P256Signature, PersonalMeshProto, Repo}

  @max_members 32
  @max_endpoint_ttl 15 * 60
  @manager_permission "manage_members"

  defmodule Mesh do
    use Ecto.Schema
    @primary_key false
    schema "personal_meshes" do
      field(:id, :string, primary_key: true)
      field(:descriptor, :binary)
      field(:registry_audience, :string)
      field(:revision, :integer)
      field(:policy_epoch, :integer)
      field(:member_limit, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule Member do
    use Ecto.Schema
    @primary_key false
    schema "personal_mesh_members" do
      field(:mesh_id, :string, primary_key: true)
      field(:device_id, :string, primary_key: true)
      field(:root_public_key, :binary)
      field(:root_key_revision, :integer)
      field(:permissions, {:array, :string})
      field(:joined_revision, :integer)
      field(:expires_at, :utc_datetime_usec)
    end
  end

  defmodule Tombstone do
    use Ecto.Schema
    @primary_key false
    schema "personal_mesh_tombstones" do
      field(:mesh_id, :string, primary_key: true)
      field(:device_id, :string, primary_key: true)
      field(:root_key_revision, :integer)
      field(:revoked_revision, :integer)
      field(:policy_epoch, :integer)
      field(:operation_digest, :binary)
      field(:created_at, :utc_datetime_usec)
    end
  end

  defmodule Invite do
    use Ecto.Schema
    @primary_key false
    schema "personal_mesh_invites" do
      field(:id, :string, primary_key: true)
      field(:mesh_id, :string)
      field(:invite_digest, :binary)
      field(:expires_at, :utc_datetime_usec)
      field(:consumed_at, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
    end
  end

  defmodule Operation do
    use Ecto.Schema
    @primary_key false
    schema "personal_mesh_operations" do
      field(:id, :string, primary_key: true)
      field(:mesh_id, :string)
      field(:kind, :string)
      field(:issuer_device_id, :string)
      field(:expected_revision, :integer)
      field(:canonical_payload, :binary)
      field(:signature, :binary)
      field(:result_revision, :integer)
      field(:created_at, :utc_datetime_usec)
    end
  end

  defmodule Endpoint do
    use Ecto.Schema
    @primary_key false
    schema "personal_mesh_endpoints" do
      field(:mesh_id, :string, primary_key: true)
      field(:device_id, :string, primary_key: true)
      field(:root_key_revision, :integer)
      field(:generation, :integer)
      field(:observation, :binary)
      field(:expires_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  def genesis(attrs) when is_map(attrs) do
    with :ok <- rate_limit("mutation", attrs.mesh_id, rate_limit_value("mutation", 120)),
         :ok <- validate_operation(attrs, 0),
         true <- canonical_operation_matches?(attrs),
         true <- attrs.issuer_device_id == attrs.device_id,
         true <- valid_genesis_descriptor?(attrs),
         true <- verify_signature(attrs.canonical_payload, attrs.signature, attrs.root_public_key) do
      Repo.transaction(fn ->
        case Repo.get(Operation, attrs.operation_id) do
          %Operation{result_revision: 1} -> snapshot!(attrs.mesh_id)
          nil -> create_genesis!(attrs)
          _ -> Repo.rollback(:operation_conflict)
        end
      end)
    else
      _ -> {:error, :invalid_operation}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def create_invite(mesh_id, issuer_device_id, id, invite_digest, expires_at)
      when is_binary(invite_digest) do
    with :ok <- rate_limit("mutation", mesh_id, rate_limit_value("mutation", 120)) do
      Repo.transaction(fn ->
        mesh = lock_mesh!(mesh_id)
        issuer = active_member!(mesh_id, issuer_device_id)
        ensure_manager!(issuer)

        if DateTime.compare(expires_at, DateTime.utc_now()) != :gt do
          Repo.rollback(:expired)
        end

        {1, _} =
          Repo.insert_all(
            Invite,
            [
              %{
                id: id,
                mesh_id: mesh.id,
                invite_digest: invite_digest,
                expires_at: expires_at,
                created_at: DateTime.utc_now()
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:id]
          )

        audit!(mesh.id, issuer_device_id, "invite_created", "succeeded", invite_digest)
        :ok
      end)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def join(attrs) when is_map(attrs) do
    with :ok <- rate_limit("mutation", attrs.mesh_id, rate_limit_value("mutation", 120)),
         :ok <- validate_operation(attrs, attrs.expected_revision),
         true <- canonical_operation_matches?(attrs) do
      Repo.transaction(fn ->
        mesh = lock_mesh!(attrs.mesh_id)
        issuer = active_member!(mesh.id, attrs.issuer_device_id)

        if not verify_signature(attrs.canonical_payload, attrs.signature, issuer.root_public_key),
          do: Repo.rollback(:invalid_signature)

        idempotent_or_apply!(attrs, mesh, fn -> apply_join!(mesh, attrs) end)
      end)
    else
      _ -> {:error, :invalid_operation}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def revoke(attrs) when is_map(attrs) do
    with :ok <- rate_limit("mutation", attrs.mesh_id, rate_limit_value("mutation", 120)),
         :ok <- validate_operation(attrs, attrs.expected_revision),
         true <- canonical_operation_matches?(attrs) do
      Repo.transaction(fn ->
        mesh = lock_mesh!(attrs.mesh_id)
        issuer = active_member!(mesh.id, attrs.issuer_device_id)

        if not verify_signature(attrs.canonical_payload, attrs.signature, issuer.root_public_key),
          do: Repo.rollback(:invalid_signature)

        idempotent_or_apply!(attrs, mesh, fn -> apply_revoke!(mesh, attrs) end)
      end)
    else
      _ -> {:error, :invalid_operation}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def publish_endpoint(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    with :ok <- rate_limit("endpoint", attrs.mesh_id, rate_limit_value("endpoint", 120)),
         true <- DateTime.compare(attrs.expires_at, now) == :gt,
         true <- DateTime.diff(attrs.expires_at, now, :second) <= @max_endpoint_ttl,
         true <- canonical_endpoint_matches?(attrs),
         true <- verify_signature(attrs.canonical_payload, attrs.signature, attrs.root_public_key) do
      row = %{
        mesh_id: attrs.mesh_id,
        device_id: attrs.device_id,
        root_key_revision: attrs.root_key_revision,
        generation: attrs.generation,
        observation: attrs.observation,
        expires_at: attrs.expires_at,
        updated_at: now
      }

      case Repo.transaction(fn ->
             mesh = lock_mesh!(attrs.mesh_id)

             if Map.get(attrs, :canonical_format) == :protobuf_v1 and
                  mesh.revision != attrs.expected_revision,
                do: Repo.rollback(:revision_conflict)

             member = active_member!(attrs.mesh_id, attrs.device_id)

             if member.root_key_revision != attrs.root_key_revision or
                  member.root_public_key != attrs.root_public_key,
                do: Repo.rollback(:stale_root)

             current =
               Repo.one(
                 from(e in Endpoint,
                   where: e.mesh_id == ^attrs.mesh_id and e.device_id == ^attrs.device_id,
                   lock: "FOR UPDATE"
                 )
               )

             if current != nil and not endpoint_advances?(current, attrs) do
               Repo.rollback(:stale_generation)
             end

             Repo.insert_all(Endpoint, [row],
               conflict_target: [:mesh_id, :device_id],
               on_conflict:
                 {:replace,
                  [:root_key_revision, :generation, :observation, :expires_at, :updated_at]}
             )

             :ok
           end) do
        {:ok, :ok} ->
          audit!(
            attrs.mesh_id,
            attrs.device_id,
            "endpoint_published",
            "succeeded",
            :crypto.hash(:sha256, attrs.canonical_payload)
          )

          :ok

        {:error, reason} when reason in [:revision_conflict, :stale_generation, :stale_root] ->
          {:error, reason}

        {:error, _} ->
          {:error, :unavailable}
      end
    else
      _ -> {:error, :invalid_endpoint}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp endpoint_advances?(current, attrs) do
    cond do
      attrs.root_key_revision < current.root_key_revision ->
        false

      attrs.generation > current.generation ->
        true

      attrs.generation < current.generation or
          attrs.root_key_revision != current.root_key_revision ->
        false

      DateTime.compare(attrs.expires_at, current.expires_at) != :gt ->
        false

      true ->
        with {:ok, previous} when is_map(previous) <- Jason.decode(current.observation),
             {:ok, next} when is_map(next) <- Jason.decode(attrs.observation) do
          Map.take(previous, [
            "deviceId",
            "rootKeyRevision",
            "endpointNodeId",
            "endpointGeneration",
            "supportedAlpns",
            "featureSet",
            "observedAddressesDigest"
          ]) ==
            Map.take(next, [
              "deviceId",
              "rootKeyRevision",
              "endpointNodeId",
              "endpointGeneration",
              "supportedAlpns",
              "featureSet",
              "observedAddressesDigest"
            ])
        else
          _ -> false
        end
    end
  end

  def snapshot(mesh_id) do
    with :ok <- rate_limit("snapshot", mesh_id, rate_limit_value("snapshot", 240)) do
      case Repo.get(Mesh, mesh_id) do
        nil -> {:error, :not_found}
        _ -> {:ok, snapshot!(mesh_id)}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp create_genesis!(attrs) do
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Mesh, [
        %{
          id: attrs.mesh_id,
          descriptor: attrs.descriptor,
          registry_audience: attrs.registry_audience,
          revision: 1,
          policy_epoch: 1,
          member_limit: @max_members,
          created_at: now,
          updated_at: now
        }
      ])

    {1, _} =
      Repo.insert_all(Member, [
        %{
          mesh_id: attrs.mesh_id,
          device_id: attrs.device_id,
          root_public_key: attrs.root_public_key,
          root_key_revision: attrs.root_key_revision,
          permissions: [@manager_permission, "request_routes"],
          joined_revision: 1,
          expires_at: attrs.expires_at
        }
      ])

    insert_operation!(attrs, 1, now)
    snapshot!(attrs.mesh_id)
  end

  defp apply_join!(mesh, attrs) do
    ensure_revision!(mesh, attrs.expected_revision)
    issuer = active_member!(mesh.id, attrs.issuer_device_id)
    ensure_manager!(issuer)
    verify_pairing_proof!(attrs)

    if Map.get(attrs, :canonical_format) == :protobuf_v1 do
      Repo.insert_all(
        Invite,
        [
          %{
            id: attrs.invite_id,
            mesh_id: mesh.id,
            invite_digest: attrs.invite_digest,
            expires_at: attrs.expires_at,
            created_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:id]
      )
    end

    invite =
      Repo.one!(
        from(i in Invite,
          where: i.id == ^attrs.invite_id and i.mesh_id == ^mesh.id,
          lock: "FOR UPDATE"
        )
      )

    if invite.consumed_at != nil or DateTime.compare(invite.expires_at, DateTime.utc_now()) != :gt or
         invite.invite_digest != attrs.invite_digest,
       do: Repo.rollback(:invalid_invite)

    if Repo.exists?(
         from(t in Tombstone, where: t.mesh_id == ^mesh.id and t.device_id == ^attrs.device_id)
       ),
       do: Repo.rollback(:remove_wins)

    if Repo.aggregate(from(m in Member, where: m.mesh_id == ^mesh.id), :count) >=
         mesh.member_limit,
       do: Repo.rollback(:member_limit)

    revision = mesh.revision + 1
    now = DateTime.utc_now()

    {1, _} =
      Repo.update_all(from(i in Invite, where: i.id == ^invite.id and is_nil(i.consumed_at)),
        set: [consumed_at: now]
      )

    {1, _} =
      Repo.insert_all(Member, [
        %{
          mesh_id: mesh.id,
          device_id: attrs.device_id,
          root_public_key: attrs.root_public_key,
          root_key_revision: attrs.root_key_revision,
          permissions: attrs.permissions,
          joined_revision: revision,
          expires_at: attrs.expires_at
        }
      ])

    advance_mesh!(mesh, revision, mesh.policy_epoch)
    insert_operation!(attrs, revision, now)
    snapshot!(mesh.id)
  end

  defp apply_revoke!(mesh, attrs) do
    ensure_revision!(mesh, attrs.expected_revision)
    issuer = active_member!(mesh.id, attrs.issuer_device_id)
    ensure_manager!(issuer)
    target = active_member!(mesh.id, attrs.device_id)
    revision = mesh.revision + 1
    epoch = mesh.policy_epoch + 1
    now = DateTime.utc_now()
    digest = :crypto.hash(:sha256, attrs.canonical_payload)

    Repo.delete_all(
      from(m in Member, where: m.mesh_id == ^mesh.id and m.device_id == ^target.device_id)
    )

    Repo.delete_all(
      from(e in Endpoint, where: e.mesh_id == ^mesh.id and e.device_id == ^target.device_id)
    )

    {1, _} =
      Repo.insert_all(
        Tombstone,
        [
          %{
            mesh_id: mesh.id,
            device_id: target.device_id,
            root_key_revision: target.root_key_revision,
            revoked_revision: revision,
            policy_epoch: epoch,
            operation_digest: digest,
            created_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:mesh_id, :device_id]
      )

    advance_mesh!(mesh, revision, epoch)
    insert_operation!(attrs, revision, now)
    snapshot!(mesh.id)
  end

  defp idempotent_or_apply!(attrs, mesh, fun) do
    case Repo.get(Operation, attrs.operation_id) do
      %Operation{
        mesh_id: id,
        canonical_payload: payload,
        signature: signature,
        result_revision: revision
      }
      when id == attrs.mesh_id and payload == attrs.canonical_payload and
             signature == attrs.signature and not is_nil(revision) ->
        snapshot!(mesh.id)

      nil ->
        fun.()

      _ ->
        Repo.rollback(:operation_conflict)
    end
  end

  defp snapshot!(mesh_id) do
    mesh = Repo.get!(Mesh, mesh_id)

    members =
      Repo.all(
        from(m in Member,
          where: m.mesh_id == ^mesh_id,
          order_by: m.device_id,
          limit: @max_members
        )
      )

    tombstones =
      Repo.all(
        from(t in Tombstone,
          where: t.mesh_id == ^mesh_id,
          order_by: t.device_id,
          limit: @max_members
        )
      )

    now = DateTime.utc_now()

    endpoints =
      Repo.all(
        from(e in Endpoint,
          join: m in Member,
          on: m.mesh_id == e.mesh_id and m.device_id == e.device_id,
          where:
            e.mesh_id == ^mesh_id and e.expires_at > ^now and
              e.root_key_revision == m.root_key_revision and m.expires_at > ^now,
          order_by: e.device_id,
          limit: @max_members
        )
      )

    snapshot = %{
      mesh: mesh,
      members: members,
      tombstones: tombstones,
      endpoints: endpoints,
      freshness_expires_at: DateTime.add(now, @max_endpoint_ttl, :second)
    }

    Map.put(snapshot, :freshness_receipt, sign_freshness_receipt!(snapshot))
  end

  defp lock_mesh!(id), do: Repo.one!(from(m in Mesh, where: m.id == ^id, lock: "FOR UPDATE"))

  defp active_member!(mesh_id, device_id),
    do:
      Repo.one!(
        from(m in Member,
          where:
            m.mesh_id == ^mesh_id and m.device_id == ^device_id and
              m.expires_at > ^DateTime.utc_now()
        )
      )

  defp ensure_manager!(%Member{permissions: permissions}),
    do: if(@manager_permission in permissions, do: :ok, else: Repo.rollback(:permission_denied))

  defp ensure_revision!(mesh, expected),
    do: if(mesh.revision == expected, do: :ok, else: Repo.rollback(:revision_conflict))

  defp advance_mesh!(mesh, revision, epoch),
    do:
      Repo.update_all(from(m in Mesh, where: m.id == ^mesh.id and m.revision == ^mesh.revision),
        set: [revision: revision, policy_epoch: epoch, updated_at: DateTime.utc_now()]
      )

  defp insert_operation!(attrs, revision, now) do
    {1, _} =
      Repo.insert_all(Operation, [
        %{
          id: attrs.operation_id,
          mesh_id: attrs.mesh_id,
          kind: attrs.kind,
          issuer_device_id: attrs.issuer_device_id,
          expected_revision: attrs.expected_revision,
          canonical_payload: attrs.canonical_payload,
          signature: attrs.signature,
          result_revision: revision,
          created_at: now
        }
      ])

    audit!(
      attrs.mesh_id,
      attrs.issuer_device_id,
      attrs.kind,
      "succeeded",
      :crypto.hash(:sha256, attrs.canonical_payload)
    )
  end

  @doc "Bounded retention worker for expired projections, rate buckets, and old audit rows."
  def prune_retention(limit \\ 500) when limit > 0 and limit <= 1_000 do
    now = DateTime.utc_now()
    audit_before = DateTime.add(now, -90, :day)
    old_window = div(DateTime.to_unix(now), 60) - 24 * 60

    Repo.transaction(fn ->
      expired_endpoints =
        bounded_delete("personal_mesh_endpoints", "expires_at < $1", [now], limit)

      expired_invites = bounded_delete("personal_mesh_invites", "expires_at < $1", [now], limit)

      old_audit =
        bounded_delete("personal_mesh_registry_audit", "created_at < $1", [audit_before], limit)

      old_rates =
        bounded_delete("personal_mesh_rate_buckets", "window_start < $1", [old_window], limit)

      %{
        endpoints: expired_endpoints,
        invites: expired_invites,
        audit: old_audit,
        rate_buckets: old_rates
      }
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  defp rate_limit(scope, subject_id, limit) when is_binary(subject_id) and subject_id != "" do
    window = div(System.system_time(:second), 60)

    case Repo.query!(
           "INSERT INTO personal_mesh_rate_buckets (scope, subject_id, window_start, count) VALUES ($1, $2, $3, 1) ON CONFLICT (scope, subject_id, window_start) DO UPDATE SET count = personal_mesh_rate_buckets.count + 1 RETURNING count",
           [scope, subject_id, window]
         ).rows do
      [[count]] when count <= limit -> :ok
      _ -> {:error, :rate_limited}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp rate_limit(_, _, _), do: {:error, :invalid_subject}

  defp rate_limit_value(scope, fallback),
    do:
      Application.get_env(:salix_store, :personal_mesh_registry_rate_limits, %{})
      |> Map.get(scope, fallback)

  defp audit!(mesh_id, actor, action, outcome, digest) do
    Repo.insert_all("personal_mesh_registry_audit", [
      %{
        mesh_id: mesh_id,
        actor_device_id: actor,
        action: action,
        outcome: outcome,
        operation_digest: digest,
        created_at: DateTime.utc_now()
      }
    ])
  end

  defp bounded_delete(table, predicate, params, limit) do
    sql =
      "DELETE FROM #{table} WHERE ctid IN (SELECT ctid FROM #{table} WHERE #{predicate} LIMIT #{limit})"

    %{num_rows: count} = Repo.query!(sql, params)
    count
  end

  defp validate_operation(attrs, expected_revision) do
    required = [:operation_id, :mesh_id, :kind, :issuer_device_id, :canonical_payload, :signature]

    if Enum.all?(required, &(is_binary(Map.get(attrs, &1)) and byte_size(Map.get(attrs, &1)) > 0)) and
         attrs.expected_revision == expected_revision, do: :ok, else: {:error, :invalid_operation}
  end

  defp valid_genesis_descriptor?(attrs) do
    is_binary(Map.get(attrs, :descriptor)) and byte_size(attrs.descriptor) > 0 and
      is_binary(Map.get(attrs, :registry_audience)) and byte_size(attrs.registry_audience) > 0
  end

  @doc "Canonical signed operation payload; verifier-only key hints are excluded."
  def canonical_operation(attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:policy_epoch, 1)
    |> Map.put_new(:issuer_root_key_revision, 1)
    |> Map.put_new(:invite_id, nil)
    |> Map.put_new(:nonce, <<>>)
    |> Map.put_new(:pairing_proof, <<>>)
    |> Map.put_new(:canonical_membership, %{
      mesh_id: attrs.mesh_id,
      device_id: attrs.device_id,
      root_public_key: Map.get(attrs, :root_public_key, <<>>),
      root_key_revision: Map.get(attrs, :root_key_revision, 0),
      permissions: Enum.map(attrs[:permissions] || [], &permission_number/1),
      state: 2,
      joined_at_revision: 0,
      revoked_at_revision: nil,
      operation_digest: <<>>,
      signatures: []
    })
    |> PersonalMeshProto.registry_operation_signing_input()
  end

  defp canonical_operation_matches?(attrs),
    do: canonical_operation(attrs) == attrs.canonical_payload

  defp verify_pairing_proof!(attrs) do
    raw = Map.get(attrs, :pairing_proof, <<>>)

    proof =
      try do
        Agentvmm.Trust.V1.PairingProof.decode(raw)
      rescue
        _ -> Repo.rollback(:invalid_pairing_proof)
      end

    permissions = Enum.map(attrs.permissions || [], &permission_number/1) |> Enum.sort()
    proof_permissions = Enum.map(proof.permissions, &permission_number/1) |> Enum.sort()
    expires_at = timestamp_datetime(proof.expires_at)

    signing_attrs = %{
      session_id: proof.session_id,
      mesh_id: proof.mesh_id,
      invite_revision: proof.invite_revision,
      role: "joiner",
      device_id: proof.device_id,
      root_key_revision: proof.root_key_revision,
      root_public_key: proof.root_public_key,
      permissions: proof.permissions,
      context_digest: proof.context_digest,
      expires_at: expires_at
    }

    valid =
      raw != <<>> and Protobuf.encode(proof) == raw and byte_size(proof.session_id) == 16 and
        proof.mesh_id == attrs.mesh_id and proof.invite_revision == attrs.expected_revision and
        proof.role == :PAIRING_ROLE_JOINER and proof.device_id == attrs.device_id and
        proof.root_key_revision == attrs.root_key_revision and
        proof.root_public_key == attrs.root_public_key and proof_permissions == permissions and
        byte_size(proof.context_digest) == 32 and not is_nil(expires_at) and
        DateTime.compare(expires_at, DateTime.utc_now()) == :gt and
        DateTime.compare(expires_at, attrs.expires_at) != :gt and
        P256Signature.verify(
          PersonalMeshProto.pairing_proof_signing_input(signing_attrs),
          proof.signature,
          proof.root_public_key
        )

    if not valid, do: Repo.rollback(:invalid_pairing_proof)
  end

  defp timestamp_datetime(%Google.Protobuf.Timestamp{seconds: seconds, nanos: nanos}) do
    with {:ok, datetime} <- DateTime.from_unix(seconds, :second) do
      DateTime.add(datetime, div(nanos, 1_000), :microsecond)
    else
      _ -> nil
    end
  end

  defp timestamp_datetime(_), do: nil

  @doc "Canonical endpoint observation payload, binding identity, generation, bytes, and expiry."
  def canonical_endpoint(attrs) when is_map(attrs) do
    attrs =
      case attrs[:observation] && Jason.decode(attrs.observation) do
        {:ok, observation} ->
          Map.merge(attrs, %{
            endpoint_node_id: decode_proto_bytes(observation["endpointNodeId"]),
            supported_alpns: observation["supportedAlpns"] || [],
            feature_set: observation["featureSet"] || [],
            observed_addresses_digest: decode_proto_bytes(observation["observedAddressesDigest"])
          })

        _ ->
          attrs
      end

    PersonalMeshProto.endpoint_observation_signing_input(attrs)
  end

  defp canonical_endpoint_matches?(attrs),
    do: canonical_endpoint(attrs) == attrs.canonical_payload

  defp permission_number("use_services"), do: 1
  defp permission_number("request_routes"), do: 1
  defp permission_number("manage_members"), do: 2
  defp permission_number(:MESH_PERMISSION_USE_SERVICES), do: 1
  defp permission_number(:MESH_PERMISSION_MANAGE_MEMBERS), do: 2
  defp permission_number(value) when is_integer(value), do: value

  defp decode_proto_bytes(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> decoded
      :error -> <<>>
    end
  end

  defp decode_proto_bytes(_), do: <<>>

  defp sign_freshness_receipt!(snapshot) do
    expires_at = snapshot.freshness_expires_at

    digest_input = %{
      mesh_id: snapshot.mesh.id,
      revision: snapshot.mesh.revision,
      policy_epoch: snapshot.mesh.policy_epoch,
      members: Enum.map(snapshot.members, &{&1.device_id, &1.root_key_revision, &1.permissions}),
      tombstones:
        Enum.map(snapshot.tombstones, &{&1.device_id, &1.revoked_revision, &1.policy_epoch}),
      endpoints:
        Enum.map(
          snapshot.endpoints,
          &{&1.device_id, &1.root_key_revision, &1.generation, &1.expires_at}
        )
    }

    payload =
      :erlang.term_to_binary(
        %{
          mesh_id: snapshot.mesh.id,
          revision: snapshot.mesh.revision,
          policy_epoch: snapshot.mesh.policy_epoch,
          snapshot_digest:
            :crypto.hash(:sha256, :erlang.term_to_binary(digest_input, [:deterministic])),
          expires_at: expires_at
        },
        [:deterministic]
      )

    signer = Application.get_env(:salix_store, :personal_mesh_registry_receipt_signer)

    case signer && signer.(payload) do
      {key_id, signature}
      when is_binary(key_id) and key_id != "" and is_binary(signature) and
             byte_size(signature) > 0 ->
        %{key_id: key_id, payload: payload, signature: signature, expires_at: expires_at}

      _ ->
        Repo.rollback(:receipt_signer_unavailable)
    end
  end

  defp verify_signature(payload, signature, public_key),
    do: SalixStore.P256Signature.verify(payload, signature, public_key)

  def verify_p256_signature(payload, signature, public_key),
    do: verify_signature(payload, signature, public_key)
end
