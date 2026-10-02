defmodule BridgeForTeams.FeishuAppBindings do
  @moduledoc """
  Org-level Feishu app bindings.

  A binding is the single org-level record of a customer's Feishu custom app,
  reusable across the SSO and bot capabilities. The binding holds only
  non-secret posture (app_id, capability flags, and `*_configured` flags);
  verification status comes from live Run checks. Secret bytes remain in their
  owning store — the SSO secret in `org_sso_connections` (BFT), the bot secret
  in Salix.

  This module owns the binding row + the non-secret posture, and fans a
  saved/rotated secret out to the enabled capabilities' stores:
  the SSO side writes `Orgs.upsert_sso_connection/2` (org_sso_connections, BFT),
  and the bot side writes the org's Salix tenant Feishu-app store via
  `Client.put_feishu_tenant_app/2` (mirroring `OrgOAuthApps`/`ctl/oauth/provider_apps`).
  The SSO fan-out runs in the same transaction as the binding row (a Postgres
  write); the bot fan-out runs AFTER commit, because it is an `:erpc` network call
  that must not hold the Ecto checkout — see `upsert_binding/2`.
  """
  import Ecto.Query, warn: false

  require Logger

  alias BridgeForTeams.{Observability, Orgs}
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.FeishuAppBinding
  alias BridgeForTeams.Schema.Organization

  @secret_fields %{
    "app_secret" => :app_secret_configured,
    "verification_token" => :verification_token_configured,
    "encrypt_key" => :encrypt_key_configured
  }

  @audit_credential_labels %{
    "app_secret" => "app_credential",
    "verification_token" => "verification_credential",
    "encrypt_key" => "encryption_credential"
  }

  @binding_audit_fields [
    {"app_id", "app_id"},
    {"display_name", "display_name"},
    {"sso_enabled", "sso_enabled"},
    {"bot_enabled", "bot_enabled"},
    {"app_secret_configured", "app_credential_configured"},
    {"verification_token_configured", "verification_credential_configured"},
    {"encrypt_key_configured", "encryption_configured"}
  ]

  @doc "Feishu app bindings for an org, oldest first. `:limit` caps the rows."
  @spec list_bindings(Ecto.UUID.t(), keyword()) :: [FeishuAppBinding.t()]
  def list_bindings(org_id, opts \\ []) do
    query =
      from(b in FeishuAppBinding,
        where: b.org_id == ^org_id,
        order_by: [asc: b.created_at, asc: b.id]
      )

    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> query |> limit(^limit) |> Repo.all()
      _ -> Repo.all(query)
    end
  end

  @doc """
  The org's binding enabled for dashboard login, or nil. Older builds could
  leave more than one SSO-enabled binding behind, so the most recently saved
  one wins until the next binding save cleans the posture up.
  """
  @spec latest_sso_binding(Ecto.UUID.t()) :: FeishuAppBinding.t() | nil
  def latest_sso_binding(org_id) do
    Repo.one(
      from(b in FeishuAppBinding,
        where: b.org_id == ^org_id and b.sso_enabled == true,
        order_by: [desc: coalesce(b.updated_at, b.created_at), desc: b.id],
        limit: 1
      )
    )
  end

  @doc "Fetch one binding scoped to its org."
  @spec get_binding(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, FeishuAppBinding.t()} | {:error, :not_found}
  def get_binding(org_id, id) do
    case Repo.get_by(FeishuAppBinding, id: id, org_id: org_id) do
      nil -> {:error, :not_found}
      binding -> {:ok, binding}
    end
  end

  @doc "Find the org's binding for a given Feishu `app_id`, or nil."
  @spec get_binding_for_app(Ecto.UUID.t(), String.t()) :: FeishuAppBinding.t() | nil
  def get_binding_for_app(org_id, app_id),
    do: Repo.get_by(FeishuAppBinding, org_id: org_id, app_id: app_id)

  @doc """
  Create or update an org Feishu app binding (non-secret posture).

  `attrs` carries `app_id`, `display_name`, `sso_enabled`, `bot_enabled`, and the
  optional write-only `app_secret` / `verification_token` / `encrypt_key`. A
  present (non-blank) secret marks the matching `*_configured` flag; a blank
  secret keeps the existing flag (write-only "leave blank to keep"). Secrets
  themselves are NOT stored here — only the configured flags.
  """
  @spec upsert_binding(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, FeishuAppBinding.t()} | {:error, Ecto.Changeset.t() | term()}
  def upsert_binding(org_id, attrs, opts \\ []) do
    attrs = stringify(attrs)
    opts = ensure_audit_request_id(opts)

    result =
      with {:ok, existing} <- binding_for_upsert(org_id, attrs),
           attrs = keep_existing_app_id(attrs, existing),
           attrs = inherit_missing_capability_flags(attrs, existing),
           app_id = attrs["app_id"],
           :ok <- maybe_delete_bot_store_before_disable(org_id, existing, attrs),
           :ok <- ensure_single_bot_binding(org_id, app_id, existing, attrs),
           :ok <- ensure_sso_provider_available(org_id, attrs),
           :ok <- ensure_bot_secret_available(org_id, existing, attrs) do
        posture =
          attrs
          |> Map.take(["app_id", "display_name", "sso_enabled", "bot_enabled"])
          |> Map.put("org_id", org_id)
          |> Map.merge(configured_flags(org_id, attrs, existing))

        txn =
          Repo.transaction(fn ->
            binding =
              (existing || %FeishuAppBinding{})
              |> FeishuAppBinding.changeset(posture)
              |> Repo.insert_or_update()
              |> unwrap_or_rollback()

            if truthy?(attrs["sso_enabled"]) do
              disable_other_sso_bindings(binding)
            end

            if sso_disabled?(existing, attrs) do
              org_id
              |> delete_matching_sso_connection(existing.app_id, opts)
              |> unwrap_or_rollback()
            end

            # SSO fan-out (B): the SSO secret lives in org_sso_connections, so enabling
            # SSO on the binding upserts the org's Feishu SSO connection. A blank secret
            # is kept by Orgs (write-only). Enabling SSO without a secret on first
            # configuration fails the changeset and rolls the whole upsert back. This
            # stays in-transaction: it's a Postgres write on the same connection, not a
            # network call.
            if truthy?(attrs["sso_enabled"]) do
              org_id |> fan_out_sso(attrs, opts) |> unwrap_or_rollback()
            end

            binding
          end)

        # Bot fan-out (B): the bot secret belongs at the Salix tenant level — an
        # org/tenant Feishu-app store mirroring OrgOAuthApps (`ctl/oauth/provider_apps`)
        # — written via a tenant Feishu-app erpc. Done AFTER the binding row commits,
        # NOT inside the Repo.transaction above: an `:erpc` network call holds the
        # Ecto checkout for the round-trip, so a slow/unreachable Salix node would pin
        # a pooled DB connection. The binding's `*_configured` posture flags are the
        # source of truth in BFT; only the secret VALUES go to Salix. An erpc failure
        # here surfaces as `{:error, {:bot_fan_out, reason}}` — the binding row has
        # already committed, so the next save (rotate) re-attempts the fan-out idempotently.
        case txn do
          {:ok, binding} ->
            with {:ok, binding} <- fan_out_bot(org_id, binding, attrs, existing),
                 {:ok, _audit} <- maybe_record_binding_audit(existing, binding, attrs, opts) do
              {:ok, binding}
            end

          {:error, _reason} = error ->
            error
        end
      end

    maybe_record_binding_validation_event(result, org_id, attrs, opts)
    maybe_record_binding_write_attempt(result, org_id, attrs, opts)
    result
  end

  @doc "Delete one org Feishu app binding and remove the stores it owns."
  @spec delete_binding(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, FeishuAppBinding.t()} | {:error, term()}
  def delete_binding(org_id, id, opts \\ []) do
    opts = ensure_audit_request_id(opts)

    result =
      with {:ok, binding} <- get_binding(org_id, id),
           :ok <- delete_bot_store_if_needed(org_id, binding) do
        result =
          Repo.transaction(fn ->
            if binding.sso_enabled do
              org_id
              |> delete_matching_sso_connection(binding.app_id, opts)
              |> unwrap_or_rollback()
            end

            binding
            |> Repo.delete()
            |> unwrap_or_rollback()
          end)

        with {:ok, deleted} <- result,
             {:ok, _audit} <- maybe_record_binding_delete_audit(deleted, opts) do
          {:ok, deleted}
        end
      end

    maybe_record_binding_delete_write_attempt(result, org_id, id, opts)
    result
  end

  defp maybe_record_binding_audit(existing, %FeishuAppBinding{} = binding, attrs, opts) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: binding.org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action:
          if(existing, do: "feishu_app_binding.updated", else: "feishu_app_binding.created"),
        resource_type: "feishu_app_binding",
        resource_id: binding.id,
        resource_label: binding.display_name || binding.app_id,
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: binding_audit_metadata(binding, attrs),
        redacted_diff: binding_diff(existing, binding, attrs)
      })
    else
      {:ok, nil}
    end
  end

  defp maybe_record_binding_delete_audit(%FeishuAppBinding{} = binding, opts) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: binding.org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: "feishu_app_binding.deleted",
        resource_type: "feishu_app_binding",
        resource_id: binding.id,
        resource_label: binding.display_name || binding.app_id,
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: binding_audit_metadata(binding, %{}),
        redacted_diff: %{"deleted" => %{"from" => false, "to" => true}}
      })
    else
      {:ok, nil}
    end
  end

  defp maybe_record_binding_write_attempt({:error, reason}, org_id, attrs, opts) do
    if audit_enabled?(opts) do
      record_write_attempt(%{
        org_id: org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: binding_write_attempt_action(attrs),
        resource_type: "feishu_app_binding",
        resource_id: write_attempt_binding_id(org_id, {:error, reason}, attrs),
        resource_label: validation_binding_label({:error, reason}, attrs),
        result: "failed",
        reason: reason,
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        surface: "feishu",
        metadata: binding_write_attempt_metadata(attrs, reason)
      })
    end
  end

  defp maybe_record_binding_write_attempt(_result, _org_id, _attrs, _opts), do: :ok

  defp maybe_record_binding_delete_write_attempt({:error, reason}, org_id, id, opts) do
    if audit_enabled?(opts) do
      record_write_attempt(%{
        org_id: org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: "feishu_app_binding.deleted",
        resource_type: "feishu_app_binding",
        resource_id: id,
        resource_label: id,
        result: "failed",
        reason: reason,
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        surface: "feishu",
        metadata: %{"binding_id" => id}
      })
    end
  end

  defp maybe_record_binding_delete_write_attempt(_result, _org_id, _id, _opts), do: :ok

  defp record_write_attempt(attrs) do
    case Observability.record_write_attempt(attrs) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("feishu_binding_write_attempt_audit_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp binding_write_attempt_action(attrs) do
    if present?(attrs["id"] || attrs["binding_id"]) do
      "feishu_app_binding.updated"
    else
      "feishu_app_binding.created"
    end
  end

  defp write_attempt_binding_id(org_id, result, attrs) do
    case blank_to_nil(validation_binding_id(result, attrs)) do
      nil ->
        case get_binding_for_app(org_id, trim(attrs["app_id"])) do
          %FeishuAppBinding{id: id} -> id
          _ -> nil
        end

      id ->
        id
    end
  end

  defp binding_write_attempt_metadata(attrs, reason) do
    base = %{
      "app_id" => trim(attrs["app_id"]),
      "display_name_configured" => present?(attrs["display_name"]),
      "sso_enabled" => truthy?(attrs["sso_enabled"]),
      "bot_enabled" => truthy?(attrs["bot_enabled"]),
      "submitted_credential_fields" => submitted_credential_fields(attrs)
    }

    case reason do
      {:sso_provider_conflict, provider} -> Map.put(base, "existing_sso_provider", provider)
      _ -> base
    end
  end

  defp maybe_record_binding_validation_event(result, org_id, attrs, opts) do
    if audit_enabled?(opts) do
      record_validation_event(%{
        org_id: org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        surface: "feishu",
        provider: "feishu",
        resource_type: "feishu_app_binding",
        resource_id: validation_binding_id(result, attrs),
        resource_label: validation_binding_label(result, attrs),
        status: validation_status(result),
        reason_class: validation_reason(result),
        evidence: %{
          "app_id" => trim(attrs["app_id"]),
          "display_name_configured" => present?(attrs["display_name"]),
          "sso_enabled" => truthy?(attrs["sso_enabled"]),
          "bot_enabled" => truthy?(attrs["bot_enabled"]),
          "submitted_credential_fields" => submitted_credential_fields(attrs),
          "field_errors" => validation_field_errors(result)
        }
      })
    end
  end

  defp record_validation_event(attrs) do
    case Observability.record_validation_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("feishu_binding_validation_observability_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp validation_binding_id({:ok, %FeishuAppBinding{id: id}}, _attrs), do: id
  defp validation_binding_id(_result, attrs), do: trim(attrs["id"] || attrs["binding_id"])

  defp validation_binding_label({:ok, %FeishuAppBinding{} = binding}, _attrs),
    do: binding.display_name || binding.app_id

  defp validation_binding_label(_result, attrs) do
    cond do
      present?(attrs["display_name"]) -> trim(attrs["display_name"])
      present?(attrs["app_id"]) -> trim(attrs["app_id"])
      true -> "feishu"
    end
  end

  defp validation_status({:ok, _value}), do: "ok"
  defp validation_status({:error, _reason}), do: "fail"

  defp validation_reason({:ok, _value}), do: nil
  defp validation_reason({:error, %Ecto.Changeset{}}), do: "changeset_invalid"
  defp validation_reason({:error, reason}), do: reason_to_class(reason)

  defp validation_field_errors({:error, %Ecto.Changeset{} = changeset}) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp validation_field_errors(_result), do: nil

  defp reason_to_class({tag, _reason}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_to_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_class(reason) when is_binary(reason), do: reason
  defp reason_to_class(_reason), do: "unknown"

  defp binding_audit_metadata(%FeishuAppBinding{} = binding, attrs) do
    %{
      "binding_id" => binding.id,
      "app_id" => binding.app_id,
      "display_name" => binding.display_name,
      "sso_enabled" => binding.sso_enabled,
      "bot_enabled" => binding.bot_enabled,
      "app_credential_configured" => binding.app_secret_configured,
      "verification_credential_configured" => binding.verification_token_configured,
      "encryption_configured" => binding.encrypt_key_configured,
      "submitted_credential_fields" => submitted_credential_fields(attrs)
    }
  end

  defp binding_diff(existing, %FeishuAppBinding{} = binding, attrs) do
    @binding_audit_fields
    |> Enum.reduce(%{}, fn {field, audit_key}, acc ->
      old_value = binding_field(existing, field)
      new_value = binding_field(binding, field)

      if old_value != new_value do
        Map.put(acc, audit_key, %{"from" => old_value, "to" => new_value})
      else
        acc
      end
    end)
    |> maybe_put_credential_submitted_diff(attrs)
  end

  defp maybe_put_credential_submitted_diff(diff, attrs) do
    submitted = submitted_credential_fields(attrs)

    if submitted == [] do
      diff
    else
      Map.put(diff, "submitted_credential_fields", %{"from" => [], "to" => submitted})
    end
  end

  defp submitted_credential_fields(attrs) do
    attrs
    |> Map.take(Map.keys(@audit_credential_labels))
    |> Enum.filter(fn {_key, value} -> present?(value) end)
    |> Enum.map(fn {key, _value} -> Map.fetch!(@audit_credential_labels, key) end)
  end

  defp binding_field(nil, _field), do: nil
  defp binding_field(%FeishuAppBinding{} = binding, "app_id"), do: binding.app_id
  defp binding_field(%FeishuAppBinding{} = binding, "display_name"), do: binding.display_name
  defp binding_field(%FeishuAppBinding{} = binding, "sso_enabled"), do: binding.sso_enabled
  defp binding_field(%FeishuAppBinding{} = binding, "bot_enabled"), do: binding.bot_enabled

  defp binding_field(%FeishuAppBinding{} = binding, "app_secret_configured"),
    do: binding.app_secret_configured

  defp binding_field(%FeishuAppBinding{} = binding, "verification_token_configured"),
    do: binding.verification_token_configured

  defp binding_field(%FeishuAppBinding{} = binding, "encrypt_key_configured"),
    do: binding.encrypt_key_configured

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  defp ensure_audit_request_id(opts) do
    if audit_enabled?(opts) and not present?(Keyword.get(opts, :request_id)) do
      Keyword.put(opts, :request_id, Ecto.UUID.generate())
    else
      opts
    end
  end

  defp binding_for_upsert(org_id, attrs) do
    case trim(attrs["id"] || attrs["binding_id"]) do
      "" ->
        {:ok, attrs["app_id"] && get_binding_for_app(org_id, attrs["app_id"])}

      id ->
        case get_binding(org_id, id) do
          {:ok, binding} ->
            if present?(attrs["app_id"]) and trim(attrs["app_id"]) != binding.app_id do
              {:error, :app_id_immutable}
            else
              {:ok, binding}
            end

          error ->
            error
        end
    end
  end

  defp keep_existing_app_id(attrs, nil), do: attrs
  defp keep_existing_app_id(attrs, existing), do: Map.put(attrs, "app_id", existing.app_id)

  defp inherit_missing_capability_flags(attrs, nil), do: attrs

  defp inherit_missing_capability_flags(attrs, existing) do
    attrs
    |> Map.put_new("sso_enabled", existing.sso_enabled)
    |> Map.put_new("bot_enabled", existing.bot_enabled)
  end

  defp ensure_sso_provider_available(org_id, attrs) do
    if truthy?(attrs["sso_enabled"]) do
      case Orgs.get_sso_connection(org_id) do
        nil -> :ok
        %{provider: "feishu"} -> :ok
        %{provider: provider} -> {:error, {:sso_provider_conflict, provider}}
      end
    else
      :ok
    end
  end

  defp sso_disabled?(nil, _attrs), do: false

  defp sso_disabled?(existing, attrs),
    do: existing.sso_enabled == true and not truthy?(attrs["sso_enabled"])

  defp delete_matching_sso_connection(org_id, app_id, opts) do
    case Orgs.get_sso_connection(org_id) do
      %{provider: "feishu", client_id: ^app_id} -> Orgs.delete_sso_connection(org_id, opts)
      _ -> {:ok, nil}
    end
  end

  defp maybe_delete_bot_store_before_disable(_org_id, nil, _attrs), do: :ok

  defp maybe_delete_bot_store_before_disable(org_id, existing, attrs) do
    if existing.bot_enabled == true and not truthy?(attrs["bot_enabled"]) do
      delete_bot_store_if_needed(org_id, existing)
    else
      :ok
    end
  end

  defp delete_bot_store_if_needed(_org_id, %{bot_enabled: false}), do: :ok

  defp delete_bot_store_if_needed(org_id, _binding) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
         :ok <- client().delete_feishu_tenant_app(org.salix_tenant_id) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("feishu_bot_store_delete_failed reason=#{inspect(reason)}", org_id: org_id)
        {:error, {:bot_delete, reason}}
    end
  end

  defp disable_other_sso_bindings(binding) do
    now = DateTime.utc_now(:microsecond)

    Repo.update_all(
      from(b in FeishuAppBinding,
        where: b.org_id == ^binding.org_id and b.id != ^binding.id and b.sso_enabled == true
      ),
      set: [sso_enabled: false, updated_at: now]
    )
  end

  # Push bot-side secret fields to the org's Salix tenant Feishu-app store when
  # the binding has bot enabled and the admin submitted at least one secret value.
  # Salix pointer-merges absent fields, so rotating verification_token/encrypt_key
  # must not require re-entering App Secret.
  defp fan_out_bot(org_id, binding, attrs, existing) do
    with {:ok, attrs} <- bot_fan_out_attrs(org_id, binding, attrs, existing) do
      with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
           {:ok, _app} <- client().put_feishu_tenant_app(org.salix_tenant_id, attrs) do
        {:ok, binding}
      else
        {:error, reason} ->
          Logger.warning("feishu_bot_fan_out_failed reason=#{inspect(reason)}", org_id: org_id)
          {:error, {:bot_fan_out, reason}}
      end
    else
      :skip -> {:ok, binding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bot_fan_out_attrs(org_id, binding, attrs, existing) do
    cond do
      !truthy?(attrs["bot_enabled"]) ->
        :skip

      bot_secret_submitted?(attrs) ->
        {:ok, bot_attrs(attrs)}

      enabling_bot?(existing, attrs) ->
        case sso_app_secret(org_id, binding.app_id) do
          {:ok, secret} -> {:ok, Map.put(bot_attrs(attrs), "app_secret", secret)}
          :none -> {:error, {:missing_bot_secret, :app_secret}}
        end

      true ->
        :skip
    end
  end

  defp ensure_single_bot_binding(org_id, app_id, existing, attrs) do
    if truthy?(attrs["bot_enabled"]) and present?(app_id) and
         other_bot_binding?(org_id, app_id, existing) do
      {:error, :bot_app_already_enabled}
    else
      :ok
    end
  end

  defp other_bot_binding?(org_id, app_id, existing) do
    existing_id = (existing && existing.id) || Ecto.UUID.generate()

    Repo.exists?(
      from(b in FeishuAppBinding,
        where:
          b.org_id == ^org_id and b.bot_enabled == true and b.app_id != ^app_id and
            b.id != ^existing_id
      )
    )
  end

  defp ensure_bot_secret_available(org_id, existing, attrs) do
    cond do
      !truthy?(attrs["bot_enabled"]) ->
        :ok

      !present?(attrs["app_id"]) ->
        :ok

      present?(attrs["app_secret"]) ->
        :ok

      enabling_bot?(existing, attrs) and match?({:ok, _}, sso_app_secret(org_id, attrs["app_id"])) ->
        :ok

      enabling_bot?(existing, attrs) ->
        {:error, {:missing_bot_secret, :app_secret}}

      bot_secret_submitted?(attrs) and not (existing && existing.app_secret_configured) ->
        {:error, {:missing_bot_secret, :app_secret}}

      true ->
        :ok
    end
  end

  defp enabling_bot?(existing, attrs),
    do: truthy?(attrs["bot_enabled"]) and (is_nil(existing) or existing.bot_enabled != true)

  defp sso_app_secret(org_id, app_id) do
    app_id = trim(app_id)

    case Orgs.get_sso_connection(org_id) do
      %{provider: "feishu", client_id: ^app_id, client_secret: secret} when is_binary(secret) ->
        secret = String.trim(secret)
        if secret == "", do: :none, else: {:ok, secret}

      _ ->
        :none
    end
  end

  defp bot_secret_submitted?(attrs) do
    Enum.any?(["app_secret", "verification_token", "encrypt_key"], &present?(attrs[&1]))
  end

  # Only the bot secret values cross to Salix. Blank secrets are dropped so
  # Salix's pointer-merge keeps the stored value (write-only "leave blank to keep").
  defp bot_attrs(attrs) do
    %{"app_id" => attrs["app_id"]}
    |> put_present(attrs, "app_secret")
    |> put_present(attrs, "verification_token")
    |> put_present(attrs, "encrypt_key")
  end

  defp put_present(acc, attrs, key) do
    if present?(attrs[key]), do: Map.put(acc, key, attrs[key]), else: acc
  end

  defp client, do: Client.impl()

  defp fan_out_sso(org_id, attrs, opts) do
    base = %{
      "provider" => "feishu",
      "client_id" => attrs["app_id"],
      "client_secret" => attrs["app_secret"],
      "provider_config" => sso_provider_config(attrs)
    }

    base =
      if present?(attrs["default_role"]),
        do: Map.put(base, "default_role", attrs["default_role"]),
        else: base

    Orgs.upsert_sso_connection(org_id, base, opts)
  end

  # Carry only the provider_config keys the binding form actually manages. An
  # absent scope must NOT substitute the default: Orgs merges provider_config
  # onto the existing connection, so omitting scope keeps the stored scope and
  # never disturbs tenant_key / provisioning_policy set on the SSO card. Same for
  # default_role above (omit when absent so a re-save can't reset it). The SSO
  # connection's own defaults cover first-time creation. (Review B1, #1/#7.)
  defp sso_provider_config(attrs) do
    if present?(attrs["scope"]), do: %{"scope" => attrs["scope"]}, else: %{}
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # A secret present in attrs -> configured true; blank -> keep prior value
  # (create defaults to false). When enabling bot from a same-app SSO binding,
  # the SSO secret is reused for Salix fan-out, so the bot app-secret posture must
  # become configured even though the write-only input was left blank.
  defp configured_flags(org_id, attrs, existing) do
    Enum.into(@secret_fields, %{}, fn {secret_key, flag} ->
      value =
        cond do
          bot_secret_field?(secret_key) and not truthy?(attrs["bot_enabled"]) ->
            false

          secret_key == "app_secret" and
            not truthy?(attrs["sso_enabled"]) and not truthy?(attrs["bot_enabled"]) ->
            false

          present?(attrs[secret_key]) ->
            true

          secret_key == "app_secret" and sso_bot_secret_fallback?(org_id, existing, attrs) ->
            true

          existing ->
            Map.get(existing, flag, false)

          true ->
            false
        end

      {Atom.to_string(flag), value}
    end)
  end

  defp sso_bot_secret_fallback?(org_id, existing, attrs) do
    enabling_bot?(existing, attrs) and
      match?({:ok, _secret}, sso_app_secret(org_id, attrs["app_id"]))
  end

  defp bot_secret_field?(key), do: key in ["verification_token", "encrypt_key"]

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(_), do: ""

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
