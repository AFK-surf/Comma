defmodule BridgeForTeams.OrgComposioSettings do
  @moduledoc """
  Organization-level Composio settings for BridgeForTeams.

  An org maps 1:1 to a Salix **tenant**, and Salix keys Composio settings *per
  tenant* in its own SalixStore Postgres (`composio_settings`). This is the
  org's opt-in to the Composio integrations path that runs alongside OAuth
  provider apps (`BridgeForTeams.OrgOAuthApps`): one Composio project API key
  instead of per-provider client credentials, powering the `composio.*` agent
  tools in all the org's projects.

  BridgeForTeams owns org authorization and forwards the settings straight to
  Salix on save/delete; Salix owns the authoritative record and the API key at
  rest, in SalixStore Postgres. BridgeForTeams never stores the API key in its
  own (BFT) database — it only forwards. The key is write-only — the view
  reports only whether one is configured, never the value.
  """
  require Logger

  alias BridgeForTeams.{Observability, Orgs}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Organization

  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  The org's Composio settings — the public-safe view
  (`%{"enabled", "api_key_configured", "base_url", "source"}`). Returns
  `{:error, reason}` if the org is unknown or the Salix runtime is unreachable.
  """
  @spec get_org_composio_settings(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def get_org_composio_settings(org_id) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      case client().get_composio_settings(org.salix_tenant_id) do
        %{} = view -> {:ok, view}
        {:error, _reason} = error -> error
        other -> {:error, other}
      end
    end
  end

  @doc """
  Create or update the org's Composio settings. `attrs` may carry `"api_key"`
  (write-only; blank is dropped so Salix keeps the stored key), `"enabled"`,
  and `"base_url"`. Salix requires an api_key on first write.
  """
  @spec upsert_org_composio_settings(Ecto.UUID.t(), map(), keyword()) :: result()
  def upsert_org_composio_settings(org_id, attrs, opts \\ []) do
    attrs = attrs |> stringify() |> settings_attrs()

    Logger.info("org_composio_settings_save_requested", org_id: org_id)

    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      result =
        case client().put_composio_settings(org.salix_tenant_id, attrs) do
          {:ok, view} ->
            Logger.info("org_composio_settings_save_succeeded", org_id: org_id)

            with {:ok, _audit} <-
                   maybe_record_audit("composio_settings.saved", org, attrs, opts) do
              {:ok, view}
            end

          {:error, reason} = error ->
            # Save errors are validation (`{:bad_request, msg}`) or erpc
            # transport tags — none carry the submitted key.
            Logger.warning("org_composio_settings_save_failed reason=#{inspect(reason)}",
              org_id: org_id
            )

            error
        end

      maybe_record_write_attempt(result, "composio_settings.saved", org, attrs, opts)
      result
    end
  end

  @doc """
  Remove the org's Composio settings. Idempotent. Returns `{:ok, :ok}` so
  callers can pattern-match uniformly.
  """
  @spec delete_org_composio_settings(Ecto.UUID.t(), keyword()) :: result()
  def delete_org_composio_settings(org_id, opts \\ []) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      result =
        case normalize_delete(client().delete_composio_settings(org.salix_tenant_id)) do
          {:ok, value} ->
            with {:ok, _audit} <-
                   maybe_record_audit("composio_settings.deleted", org, %{}, opts) do
              {:ok, value}
            end

          error ->
            error
        end

      maybe_record_write_attempt(result, "composio_settings.deleted", org, %{}, opts)
      result
    end
  end

  defp maybe_record_audit(action, %Organization{} = org, attrs, opts) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: org.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: action,
        resource_type: "composio_settings",
        resource_id: org.salix_tenant_id,
        resource_label: "composio",
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: %{
          "salix_tenant_id" => org.salix_tenant_id,
          "enabled" => attrs["enabled"],
          "api_key_submitted" => Map.has_key?(attrs, "api_key")
        },
        redacted_diff: diff(action, attrs)
      })
    else
      {:ok, nil}
    end
  end

  defp maybe_record_write_attempt({:error, reason}, action, %Organization{} = org, attrs, opts) do
    if audit_enabled?(opts) do
      case Observability.record_write_attempt(%{
             org_id: org.id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "composio_settings",
             resource_id: org.salix_tenant_id,
             resource_label: "composio",
             result: "failed",
             reason: reason,
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             surface: "composio",
             metadata: %{
               "salix_tenant_id" => org.salix_tenant_id,
               "api_key_submitted" => Map.has_key?(attrs, "api_key")
             }
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning("composio_write_attempt_audit_failed reason=#{inspect(audit_reason)}")
          :ok
      end
    end
  end

  defp maybe_record_write_attempt(_result, _action, _org, _attrs, _opts), do: :ok

  defp diff("composio_settings.deleted", _attrs) do
    %{"deleted" => %{"from" => false, "to" => true}}
  end

  defp diff(_action, attrs) do
    %{
      "enabled" => %{"from" => nil, "to" => attrs["enabled"]},
      "api_key_configured" => %{"from" => nil, "to" => Map.has_key?(attrs, "api_key")}
    }
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  # ---- internal --------------------------------------------------------------

  # Only forward the settings fields, and drop a blank api_key so Salix's
  # pointer-merge leaves the stored key untouched ("leave blank to keep").
  defp settings_attrs(attrs) do
    base = %{
      "base_url" => trim(attrs["base_url"]),
      "enabled" => attrs["enabled"] not in [false, "false"]
    }

    case attrs["api_key"] do
      key when is_binary(key) ->
        case String.trim(key) do
          "" -> base
          trimmed -> Map.put(base, "api_key", trimmed)
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
