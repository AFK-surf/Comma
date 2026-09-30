defmodule BridgeForTeams.OrgOAuthApps do
  @moduledoc """
  Organization-level OAuth provider-app setup for BridgeForTeams.

  An org maps 1:1 to a Salix **tenant**, and Salix keys OAuth provider-app
  client credentials *per tenant* (`ctl/oauth/provider_apps`). These are the
  client id/secret an org configures once for a provider (Notion, Linear,
  GitHub, …) so the agents in its projects can run that provider's OAuth
  authorization flow and obtain per-binding tokens.

  BridgeForTeams owns org authorization and forwards the client credentials
  straight to Salix on save/delete; Salix owns the record and the secret at
  rest. This context never persists OAuth secrets in Postgres. Secrets are
  write-only — the list view reports only whether a secret is configured, never
  the value.

  Distinct from `BridgeForTeams.ProjectIMConnects`: IM connects (Slack/Feishu)
  are *project/group*-scoped inbound messaging integrations, whereas OAuth
  provider apps are *org/tenant*-scoped outbound-tool credentials shared by all
  the org's projects.
  """
  require Logger

  alias BridgeForTeams.{Observability, Orgs}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Organization

  @transient [:unavailable, :timeout]

  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  List the org's OAuth provider apps — one public-safe view per supported
  provider (`%{"provider", "client_id", "client_secret_configured"}`). Returns
  `{:error, reason}` if the org is unknown or the Salix runtime is unreachable.
  """
  @spec list_org_oauth_apps(Ecto.UUID.t()) :: {:ok, [map()]} | {:error, term()}
  def list_org_oauth_apps(org_id) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      result =
        case client().list_oauth_provider_apps(org.salix_tenant_id) do
          apps when is_list(apps) -> {:ok, apps}
          {:error, _reason} = error -> error
          other -> {:error, other}
        end

      maybe_record_oauth_provider_app_list_diagnostic(org, result)
      result
    end
  end

  @doc """
  Create or update the org's OAuth client credentials for `provider`. `attrs`
  carries `"client_id"` (required) and an optional `"client_secret"` (stored
  as-is in Salix, no encryption at rest). A blank secret is dropped so Salix's
  pointer-merge keeps the current stored secret. Salix validates the provider
  and rejects unsupported ones.
  """
  @spec upsert_org_oauth_app(Ecto.UUID.t(), String.t(), map(), keyword()) :: result()
  def upsert_org_oauth_app(org_id, provider, attrs, opts \\ []) do
    provider = trim(provider)
    attrs = attrs |> stringify() |> credential_attrs()

    Logger.info("org_oauth_app_save_requested", org_id: org_id, provider: provider)

    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      result =
        case client().put_oauth_provider_app(org.salix_tenant_id, provider, attrs) do
          {:ok, app} ->
            Logger.info("org_oauth_app_save_succeeded", org_id: org_id, provider: provider)

            with {:ok, _audit} <-
                   maybe_record_oauth_audit(
                     "oauth_provider_app.saved",
                     org,
                     provider,
                     attrs,
                     opts
                   ) do
              {:ok, app}
            end

          {:error, reason} = error ->
            # Save errors are provider-validation (`{:bad_request, msg}`) or erpc
            # transport tags — none carry the submitted secret.
            Logger.warning("org_oauth_app_save_failed reason=#{inspect(reason)}",
              org_id: org_id,
              provider: provider
            )

            error
        end

      maybe_record_oauth_validation_event(result, org, provider, attrs, opts)

      maybe_record_oauth_write_attempt(
        result,
        "oauth_provider_app.saved",
        org,
        provider,
        attrs,
        opts
      )

      result
    end
  end

  @doc """
  Remove the org's OAuth client credentials for `provider`. Idempotent: deleting
  a provider that was never configured still succeeds. Returns `{:ok, :ok}` so
  callers can pattern-match uniformly.
  """
  @spec delete_org_oauth_app(Ecto.UUID.t(), String.t(), keyword()) :: result()
  def delete_org_oauth_app(org_id, provider, opts \\ []) do
    provider = trim(provider)

    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      result =
        case normalize_delete(client().delete_oauth_provider_app(org.salix_tenant_id, provider)) do
          {:ok, value} ->
            with {:ok, _audit} <-
                   maybe_record_oauth_audit(
                     "oauth_provider_app.deleted",
                     org,
                     provider,
                     %{},
                     opts
                   ) do
              {:ok, value}
            end

          error ->
            error
        end

      maybe_record_oauth_write_attempt(
        result,
        "oauth_provider_app.deleted",
        org,
        provider,
        %{},
        opts
      )

      result
    end
  end

  defp maybe_record_oauth_audit(action, %Organization{} = org, provider, attrs, opts) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: org.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: action,
        resource_type: "oauth_provider_app",
        resource_id: provider,
        resource_label: provider,
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: %{
          "provider" => provider,
          "salix_tenant_id" => org.salix_tenant_id,
          "client_id" => attrs["client_id"],
          "credential_submitted" => Map.has_key?(attrs, "client_secret")
        },
        redacted_diff: oauth_diff(action, attrs)
      })
    else
      {:ok, nil}
    end
  end

  defp maybe_record_oauth_write_attempt(
         {:error, reason},
         action,
         %Organization{} = org,
         provider,
         attrs,
         opts
       ) do
    if audit_enabled?(opts) do
      record_write_attempt(%{
        org_id: org.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: action,
        resource_type: "oauth_provider_app",
        resource_id: provider,
        resource_label: provider,
        result: "failed",
        reason: reason,
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        surface: "oauth",
        metadata: %{
          "provider" => provider,
          "salix_tenant_id" => org.salix_tenant_id,
          "client_id_configured" => present?(attrs["client_id"]),
          "credential_submitted" => Map.has_key?(attrs, "client_secret")
        }
      })
    end
  end

  defp maybe_record_oauth_write_attempt(_result, _action, _org, _provider, _attrs, _opts),
    do: :ok

  defp maybe_record_oauth_provider_app_list_diagnostic(
         %Organization{} = org,
         {:error, reason}
       )
       when reason in @transient do
    reason_class = reason_to_class(reason)

    case Observability.create_event(%{
           org_id: org.id,
           domain: "integration",
           resource_type: "oauth_provider_app_index",
           resource_id: org.id,
           source: "salix.control",
           event_type: "oauth.provider_apps.unavailable",
           severity: "warning",
           status: "unavailable",
           reason_class: reason_class,
           summary: "OAuth provider apps could not be loaded from Salix",
           evidence: %{
             "settings_path" => "settings/oauth",
             "surface" => "oauth",
             "reason_class" => reason_class,
             "status" => "unavailable"
           },
           correlation_id: "org:#{org.id}:oauth-provider-apps",
           occurred_at: DateTime.utc_now()
         }) do
      {:ok, _event} ->
        :ok

      {:error, event_reason} ->
        Logger.warning(
          "oauth_provider_app_list_diagnostic_failed reason=#{inspect(event_reason)}"
        )

        :ok
    end
  end

  defp maybe_record_oauth_provider_app_list_diagnostic(_org, _result), do: :ok

  defp record_write_attempt(attrs) do
    case Observability.record_write_attempt(attrs) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("oauth_write_attempt_audit_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp maybe_record_oauth_validation_event(result, %Organization{} = org, provider, attrs, opts) do
    if audit_enabled?(opts) do
      record_validation_event(%{
        org_id: org.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        surface: "oauth",
        provider: provider,
        resource_type: "oauth_provider_app",
        resource_id: provider,
        resource_label: provider,
        status: validation_status(result),
        reason_class: validation_reason(result),
        evidence: %{
          "provider" => provider,
          "salix_tenant_id" => org.salix_tenant_id,
          "client_id_configured" => present?(attrs["client_id"]),
          "credential_submitted" => Map.has_key?(attrs, "client_secret"),
          "field_errors" => validation_error_evidence(result)
        }
      })
    end
  end

  defp record_validation_event(attrs) do
    case Observability.record_validation_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("oauth_validation_observability_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp validation_status({:ok, _value}), do: "ok"
  defp validation_status({:error, _reason}), do: "fail"

  defp validation_reason({:ok, _value}), do: nil
  defp validation_reason({:error, reason}), do: reason_to_class(reason)

  defp validation_error_evidence({:error, {:bad_request, message}}) when is_binary(message) do
    %{"provider_error_class" => "bad_request", "error_detail" => message}
  end

  defp validation_error_evidence({:error, reason}) do
    %{"provider_error_class" => reason_to_class(reason)}
  end

  defp validation_error_evidence(_result), do: nil

  defp reason_to_class({tag, _reason}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_to_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_class(reason) when is_binary(reason), do: reason
  defp reason_to_class(_reason), do: "unknown"

  defp oauth_diff("oauth_provider_app.deleted", _attrs) do
    %{"deleted" => %{"from" => false, "to" => true}}
  end

  defp oauth_diff(_action, attrs) do
    %{
      "client_id" => %{"from" => nil, "to" => attrs["client_id"]},
      "credential_configured" => %{"from" => nil, "to" => Map.has_key?(attrs, "client_secret")}
    }
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  # ---- internal --------------------------------------------------------------

  # Only forward the credential fields, and drop a blank client_secret so Salix's
  # pointer-merge leaves the stored secret untouched ("leave blank to keep").
  defp credential_attrs(attrs) do
    base = %{"client_id" => trim(attrs["client_id"])}

    case attrs["client_secret"] do
      secret when is_binary(secret) ->
        case String.trim(secret) do
          "" -> base
          trimmed -> Map.put(base, "client_secret", trimmed)
        end

      _ ->
        base
    end
  end

  defp normalize_delete(:ok), do: {:ok, :ok}
  defp normalize_delete({:ok, _} = ok), do: ok
  defp normalize_delete(other), do: other

  defp client, do: Client.impl()

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
