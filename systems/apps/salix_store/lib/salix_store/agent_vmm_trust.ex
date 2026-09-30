defmodule SalixStore.AgentVMMTrust do
  @moduledoc """
  Managed trust issuer persistence.

  Salix stores public anchors and signed, short-lived credentials. Signing
  private keys stay behind the injected release/HSM signer and are never
  written to Postgres. Personal mesh authorities use a different owner and
  cannot cross this module's tenant-scoped predicates.
  """

  import Ecto.Query
  alias SalixStore.Repo
  alias SalixStore.PersonalMeshProto

  @max_credential_ttl 24 * 60 * 60
  @max_route_ttl 60 * 60
  @route_audience "agent-vmm/service-tunnel/1"

  defmodule Anchor do
    use Ecto.Schema
    @primary_key false
    schema "agent_vmm_trust_anchors" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:authority_id, :string)
      field(:public_key, :binary)
      field(:key_revision, :integer)
      field(:policy_revision, :integer)
      field(:not_before, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
      field(:revoked_at, :utc_datetime_usec)
    end
  end

  defmodule Credential do
    use Ecto.Schema
    @primary_key false
    schema "agent_vmm_membership_credentials" do
      field(:id, :string, primary_key: true)
      field(:anchor_id, :string)
      field(:tenant_id, :string)
      field(:device_id, :string)
      field(:root_public_key, :binary)
      field(:root_key_revision, :integer)
      field(:opaque_claims_digest, :binary)
      field(:permissions, {:array, :string})
      field(:policy_revision, :integer)
      field(:canonical_payload, :binary)
      field(:signature, :binary)
      field(:not_before, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
      field(:revoked_at, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
    end
  end

  defmodule RouteCapability do
    use Ecto.Schema
    @primary_key false
    schema "agent_vmm_route_capabilities" do
      field(:id, :string, primary_key: true)
      field(:anchor_id, :string)
      field(:tenant_id, :string)
      field(:source_device_id, :string)
      field(:source_allocation_id, :string)
      field(:destination_device_id, :string)
      field(:destination_export_id, :string)
      field(:route_class, :string)
      field(:allowed_protocol, :string)
      field(:allowed_verbs, {:array, :string})
      field(:route_generation, :integer)
      field(:policy_revision, :integer)
      field(:connection_limit, :integer)
      field(:byte_limit, :integer)
      field(:concurrency_limit, :integer)
      field(:audience, :string)
      field(:issuer_key_id, :string)
      field(:canonical_payload, :binary)
      field(:signature, :binary)
      field(:not_before, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
      field(:revoked_at, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
    end
  end

  def create_anchor(attrs) when is_map(attrs) do
    row =
      Map.take(attrs, [
        :id,
        :tenant_id,
        :authority_id,
        :public_key,
        :key_revision,
        :policy_revision,
        :not_before,
        :expires_at
      ])

    case Repo.insert_all(Anchor, [row],
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :authority_id, :key_revision]
         ) do
      {1, _} -> {:ok, Repo.get!(Anchor, attrs.id)}
      {0, _} -> {:error, :already_exists}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Issue and persist the self-contained managed trust bundle used by enrollment."
  def issue_enrollment_bundle(registration, identity) when is_map(identity) do
    config = Application.get_env(:salix_store, :agent_vmm_managed_trust_signing)

    with %{
           authority_prefix: prefix,
           key_id: key_id,
           key_revision: key_revision,
           public_key: public_key,
           signer: signer
         } <- config,
         true <- is_binary(prefix) and prefix != "" and is_binary(key_id) and key_id != "",
         true <- is_integer(key_revision) and key_revision > 0 and byte_size(public_key) == 33,
         true <- is_function(signer, 1),
         device_id when is_binary(device_id) <- identity["deviceId"],
         true <- device_id == registration.device_id,
         {:ok, root_public_key} <- Base.decode64(identity["rootPublicKey"] || ""),
         {root_key_revision, ""} <- Integer.parse(identity["rootKeyRevision"] || "") do
      now = DateTime.utc_now()
      authority_id = prefix <> ":" <> registration.tenant_id
      trust_domain_ref = :crypto.hash(:sha256, registration.tenant_id)
      anchor_id = authority_id <> ":" <> Integer.to_string(key_revision)
      # Resource-pool revisions fence admission limits. They do not rotate the
      # managed signing authority or its membership trust policy.
      trust_policy_revision = key_revision
      anchor_expires_at = DateTime.add(now, 30 * 24 * 60 * 60, :second)

      anchor =
        Repo.one(
          from(a in Anchor,
            where:
              a.tenant_id == ^registration.tenant_id and a.authority_id == ^authority_id and
                a.key_revision == ^key_revision
          )
        ) ||
          case create_anchor(%{
                 id: anchor_id,
                 tenant_id: registration.tenant_id,
                 authority_id: authority_id,
                 public_key: public_key,
                 key_revision: key_revision,
                 policy_revision: trust_policy_revision,
                 not_before: DateTime.add(now, -60, :second),
                 expires_at: anchor_expires_at
               }) do
            {:ok, value} -> value
            _ -> nil
          end

      if anchor == nil or anchor.revoked_at != nil or
           anchor.policy_revision != trust_policy_revision do
        {:error, :managed_anchor_unavailable}
      else
        expires_at = DateTime.add(now, 60 * 60, :second)

        claims_digest =
          :crypto.hash(:sha256, registration.tenant_id <> "\0" <> registration.group_id)

        signing_attrs = %{
          authority_id: authority_id,
          key_id: key_id,
          trust_domain_ref: trust_domain_ref,
          anchor_revision: key_revision,
          device_id: device_id,
          root_public_key: root_public_key,
          root_key_revision: root_key_revision,
          claims_digest: claims_digest,
          policy_revision: trust_policy_revision,
          expires_at: expires_at
        }

        canonical_payload = PersonalMeshProto.managed_credential_signing_input(signing_attrs)

        attrs = %{
          id: "#{registration.id}:#{device_id}:#{trust_policy_revision}",
          tenant_id: registration.tenant_id,
          device_id: device_id,
          root_public_key: root_public_key,
          root_key_revision: root_key_revision,
          opaque_claims_digest: claims_digest,
          permissions: ["compute"],
          policy_revision: trust_policy_revision,
          canonical_payload: canonical_payload,
          not_before: now,
          expires_at: expires_at
        }

        with {:ok, credential} <- reuse_or_issue_enrollment_credential(anchor, attrs, signer, now) do
          authority = %{
            "authorityId" => authority_id,
            "authorityClass" => "AUTHORITY_CLASS_MANAGED_CONTROLLER",
            "keyId" => key_id,
            "trustDomainRef" => Base.encode64(trust_domain_ref),
            "revision" => Integer.to_string(key_revision)
          }

          {:ok,
           %{
             trust_anchor: %{
               "authority" => authority,
               "verificationKeys" => [
                 %{
                   "keyId" => key_id,
                   "publicKey" => Base.encode64(public_key),
                   "signatureSuite" => "SIGNATURE_SUITE_P256_SHA256"
                 }
               ],
               "allowedCapabilityKinds" => ["CAPABILITY_KIND_SERVICE_ROUTE"],
               "notBefore" => DateTime.to_iso8601(anchor.not_before),
               "notAfter" => DateTime.to_iso8601(anchor.expires_at),
               "revision" => Integer.to_string(anchor.key_revision)
             },
             membership_credential: %{
               "authority" => authority,
               "subjectDeviceId" => device_id,
               "subjectRootKeyRevision" => Integer.to_string(root_key_revision),
               "subjectRootPublicKey" => Base.encode64(root_public_key),
               "opaqueClaimsDigest" => Base.encode64(claims_digest),
               "policyRevision" => Integer.to_string(trust_policy_revision),
               "expiresAt" => DateTime.to_iso8601(credential.expires_at),
               "signature" => Base.encode64(credential.signature)
             }
           }}
        end
      end
    else
      _ -> {:error, :managed_trust_signer_unavailable}
    end
  rescue
    _ -> {:error, :managed_trust_unavailable}
  end

  defp reuse_or_issue_enrollment_credential(anchor, attrs, signer, now) do
    case Repo.transaction(fn ->
           Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
             Enum.join(
               ["agent-vmm-membership", anchor.id, attrs.tenant_id, attrs.device_id],
               ":"
             )
           ])

           credential =
             Repo.one(
               from(c in Credential,
                 where:
                   c.anchor_id == ^anchor.id and c.tenant_id == ^attrs.tenant_id and
                     c.device_id == ^attrs.device_id and
                     c.root_public_key == ^attrs.root_public_key and
                     c.root_key_revision == ^attrs.root_key_revision and
                     c.opaque_claims_digest == ^attrs.opaque_claims_digest and
                     c.permissions == ^attrs.permissions and
                     c.policy_revision == ^attrs.policy_revision and is_nil(c.revoked_at) and
                     c.not_before <= ^now and c.expires_at > ^now,
                 order_by: [desc: c.expires_at, desc: c.created_at, desc: c.id],
                 limit: 1
               )
             )

           case credential do
             %Credential{} = credential ->
               credential

             nil ->
               case issue_credential(anchor.id, attrs, signer) do
                 {:ok, credential} -> credential
                 {:error, reason} -> Repo.rollback(reason)
               end
           end
         end) do
      {:ok, credential} -> {:ok, credential}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def rotate_anchor(current_id, expected_key_revision, attrs) do
    Repo.transaction(fn ->
      current = Repo.one!(from(a in Anchor, where: a.id == ^current_id, lock: "FOR UPDATE"))

      if current.revoked_at != nil or current.key_revision != expected_key_revision or
           attrs.key_revision != expected_key_revision + 1 or
           current.tenant_id != attrs.tenant_id or current.authority_id != attrs.authority_id do
        Repo.rollback(:revision_conflict)
      end

      now = DateTime.utc_now()

      {1, _} =
        Repo.update_all(from(a in Anchor, where: a.id == ^current.id and is_nil(a.revoked_at)),
          set: [revoked_at: now]
        )

      {1, _} =
        Repo.insert_all(Anchor, [
          Map.take(attrs, [
            :id,
            :tenant_id,
            :authority_id,
            :public_key,
            :key_revision,
            :policy_revision,
            :not_before,
            :expires_at
          ])
        ])

      Repo.get!(Anchor, attrs.id)
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def issue_credential(anchor_id, attrs, signer) when is_map(attrs) and is_function(signer, 1) do
    now = DateTime.utc_now()
    anchor = Repo.get!(Anchor, anchor_id)

    cond do
      anchor.revoked_at != nil or DateTime.compare(anchor.not_before, now) == :gt or
          DateTime.compare(anchor.expires_at, now) != :gt ->
        {:error, :anchor_inactive}

      attrs.tenant_id != anchor.tenant_id or attrs.policy_revision != anchor.policy_revision ->
        {:error, :authority_mismatch}

      DateTime.compare(attrs.expires_at, now) != :gt or
          DateTime.diff(attrs.expires_at, now, :second) > @max_credential_ttl ->
        {:error, :invalid_expiry}

      true ->
        payload = attrs.canonical_payload

        with signature when is_binary(signature) <- signer.(payload),
             true <- SalixStore.P256Signature.verify(payload, signature, anchor.public_key) do
          row =
            attrs
            |> Map.take([
              :id,
              :tenant_id,
              :device_id,
              :root_public_key,
              :root_key_revision,
              :opaque_claims_digest,
              :permissions,
              :policy_revision,
              :canonical_payload,
              :not_before,
              :expires_at
            ])
            |> Map.merge(%{anchor_id: anchor.id, signature: signature, created_at: now})

          case Repo.insert_all(Credential, [row], on_conflict: :nothing, conflict_target: [:id]) do
            {1, _} -> {:ok, Repo.get!(Credential, attrs.id)}
            {0, _} -> {:error, :already_exists}
          end
        else
          _ -> {:error, :signer_unavailable}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def revoke_credential(tenant_id, id) do
    case Repo.update_all(
           from(c in Credential,
             where: c.id == ^id and c.tenant_id == ^tenant_id and is_nil(c.revoked_at)
           ),
           set: [revoked_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Issue an exact, short-lived managed service-route capability."
  def issue_route_capability(anchor_id, attrs, policy, signer)
      when is_map(attrs) and is_function(policy, 1) and is_function(signer, 1) do
    now = DateTime.utc_now()
    anchor = Repo.get!(Anchor, anchor_id)

    credential =
      Repo.one(
        from(c in Credential,
          where:
            c.tenant_id == ^attrs.tenant_id and c.device_id == ^attrs.source_device_id and
              c.policy_revision == ^attrs.policy_revision and is_nil(c.revoked_at),
          order_by: [desc: c.expires_at],
          limit: 1
        )
      )

    valid_budget =
      attrs.connection_limit in 1..1_000 and attrs.concurrency_limit in 1..256 and
        attrs.byte_limit > 0 and attrs.byte_limit <= 1_099_511_627_776

    cond do
      anchor.revoked_at != nil or DateTime.compare(anchor.not_before, now) == :gt or
          DateTime.compare(anchor.expires_at, now) != :gt ->
        {:error, :anchor_inactive}

      attrs.tenant_id != anchor.tenant_id or attrs.policy_revision != anchor.policy_revision ->
        {:error, :authority_mismatch}

      attrs.route_class not in ~w(local device compute lan public_http) or
        attrs.audience != @route_audience or attrs.allowed_protocol != "tcp" or
        attrs.allowed_verbs != ["connect"] or attrs.issuer_key_id in [nil, ""] or
        not is_binary(attrs.nonce) or byte_size(attrs.nonce) != 32 ->
        {:error, :invalid_scope}

      credential == nil or DateTime.compare(credential.expires_at, attrs.expires_at) == :lt ->
        {:error, :source_credential_unavailable}

      attrs.route_generation <= 0 or not valid_budget or
        DateTime.compare(attrs.not_before, now) == :gt or
        DateTime.compare(attrs.expires_at, attrs.not_before) != :gt or
          DateTime.diff(attrs.expires_at, now, :second) > @max_route_ttl ->
        {:error, :invalid_expiry_or_budget}

      policy.(attrs) != :ok ->
        {:error, :policy_denied}

      true ->
        trust_domain_ref = :crypto.hash(:sha256, anchor.tenant_id)

        source_credential = %{
          authority_id: anchor.authority_id,
          key_id: attrs.issuer_key_id,
          trust_domain_ref: trust_domain_ref,
          anchor_revision: anchor.key_revision,
          device_id: credential.device_id,
          root_public_key: credential.root_public_key,
          root_key_revision: credential.root_key_revision,
          claims_digest: credential.opaque_claims_digest,
          policy_revision: credential.policy_revision,
          expires_at: credential.expires_at,
          signature: credential.signature
        }

        payload =
          PersonalMeshProto.managed_route_signing_input(
            attrs
            |> Map.put(:authority_id, anchor.authority_id)
            |> Map.put(:key_id, attrs.issuer_key_id)
            |> Map.put(:trust_domain_ref, trust_domain_ref)
            |> Map.put(:anchor_revision, anchor.key_revision)
            |> Map.put(:source_credential, source_credential)
          )

        with signature when is_binary(signature) <- signer.(payload),
             true <- SalixStore.P256Signature.verify(payload, signature, anchor.public_key) do
          row =
            attrs
            |> Map.take([
              :id,
              :tenant_id,
              :source_device_id,
              :source_allocation_id,
              :destination_device_id,
              :destination_export_id,
              :route_class,
              :allowed_protocol,
              :allowed_verbs,
              :route_generation,
              :policy_revision,
              :connection_limit,
              :byte_limit,
              :concurrency_limit,
              :audience,
              :not_before,
              :expires_at
            ])
            |> Map.merge(%{
              anchor_id: anchor.id,
              issuer_key_id: attrs.issuer_key_id,
              canonical_payload: payload,
              signature: signature,
              created_at: now
            })

          case Repo.insert_all(RouteCapability, [row],
                 on_conflict: :nothing,
                 conflict_target: [:id]
               ) do
            {1, _} -> {:ok, Repo.get!(RouteCapability, attrs.id)}
            {0, _} -> {:error, :already_exists}
          end
        else
          _ -> {:error, :signer_unavailable}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def revoke_route_capability(tenant_id, id) do
    case Repo.update_all(
           from(c in RouteCapability,
             where: c.id == ^id and c.tenant_id == ^tenant_id and is_nil(c.revoked_at)
           ),
           set: [revoked_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
