defmodule Salix.Control.OAuthApps do
  @moduledoc """
  Tenant OAuth app control-plane API, plus the deployment-wide default apps.

  Credential resolution (`get/2`) is tenant-first: a tenant record with a
  complete client id + secret pair wins; anything less falls back to the
  platform default app for that provider (operator-managed through the Salix
  dashboard or the `/v1/runtime/oauth/default-apps` admin API); with neither, the
  provider is `:not_configured`. In local development, the built-in OAuth mock
  provides a final in-memory fallback without persisting placeholder credentials.
  Defaults are a fallback only — they never mix with a partial tenant record (a
  tenant client id is never paired with the default secret).

  `list/1` reports the effective resolution per provider as `"source"`
  (`"tenant" | "default" | "none"`) alongside the tenant record's own fields,
  and carries the public-safe `"default_client_id"` whenever a default exists,
  so admin surfaces can show what a tenant actually runs on.

  Static provider apps + the deployment defaults moved from S3 to Postgres
  (docs/storage-search.md, PR-1): they share `oauth_provider_apps`
  keyed by a scope (tenant id or the reserved default scope), reached through the
  `SalixStore.OAuthProviderApps` data module; a Postgres fault surfaces as
  `{:error, :unavailable}`, exactly as the retired S3 path surfaced its faults.
  Remote-MCP provider apps stay in S3 for now (they migrate in a later PR), so
  the `*_remote_mcp` functions still read and write through `Salix.Control.Store`.
  """

  alias Salix.Control.Store
  alias SalixStore.{Keys, OAuthProviderApps}

  defp default_scope, do: OAuthProviderApps.default_scope()

  def list(tenant_id) do
    configured = Map.new(OAuthProviderApps.list_by_scope(tenant_id), &{&1["provider"], &1})
    defaults = default_records()
    supported = SalixStore.OAuth.Adapters.supported()

    views =
      Enum.map(supported, fn provider ->
        provider_view(provider, configured[provider], defaults[provider])
      end)

    extras =
      configured
      |> Map.drop(supported)
      |> Enum.map(fn {provider, rec} -> provider_view(provider, rec, defaults[provider]) end)
      |> Enum.sort_by(& &1["provider"])

    views ++ extras
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc """
  The deployment default apps, one public-safe view per supported provider
  (same shape as `list/1` minus tenant semantics: `"provider"`,
  `"client_id"`, `"client_secret_configured"`).
  """
  def list_defaults do
    configured = default_records()
    supported = SalixStore.OAuth.Adapters.supported()

    views =
      Enum.map(supported, fn provider ->
        default_view(provider, configured[provider])
      end)

    extras =
      configured
      |> Map.drop(supported)
      |> Enum.map(fn {provider, rec} -> default_view(provider, rec) end)
      |> Enum.sort_by(& &1["provider"])

    views ++ extras
  rescue
    _exception -> {:error, :unavailable}
  end

  def get(tenant_id, provider) do
    case OAuthProviderApps.get(tenant_id, provider) do
      {:ok, rec} ->
        case complete_credentials(rec) do
          {:ok, credentials} -> {:ok, credentials}
          :incomplete -> get_default_or_local_mock(provider)
        end

      {:error, :not_found} ->
        get_default_or_local_mock(provider)
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp get_default_or_local_mock(provider) do
    case get_default(provider) do
      {:error, :not_configured} -> SalixWeb.LocalOAuthMock.mock_credentials(provider)
      result -> result
    end
  end

  @doc "The deployment default credentials for `provider` (complete pairs only)."
  def get_default(provider) do
    case OAuthProviderApps.get(default_scope(), provider) do
      {:ok, rec} ->
        case complete_credentials(rec) do
          {:ok, credentials} ->
            {:ok,
             Map.put(
               credentials,
               "token_endpoint_auth_method",
               remote_mcp_token_auth_method(rec["token_endpoint_auth_method"])
             )}

          :incomplete ->
            {:error, :not_configured}
        end

      {:error, :not_found} ->
        {:error, :not_configured}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def put(tenant_id, provider, attrs), do: upsert_app(tenant_id, provider, attrs)

  @doc "Create/update the deployment default app for `provider` (same contract as `put/3`)."
  def put_default(provider, attrs), do: upsert_app(default_scope(), provider, attrs)

  def delete(tenant_id, provider) do
    OAuthProviderApps.delete(tenant_id, provider)
  rescue
    _exception -> {:error, :unavailable}
  end

  def list_remote_mcp(tenant_id) do
    tenant_id
    |> Keys.ctl_oauth_remote_mcp_provider_apps_prefix()
    |> Store.list_records()
    |> Enum.sort_by(&(&1["provider_key"] || ""))
    |> Enum.map(&remote_mcp_provider_app_json/1)
  end

  def get_remote_mcp(tenant_id, provider_key) do
    case Store.get_record(Keys.ctl_oauth_remote_mcp_provider_app(tenant_id, provider_key)) do
      {:ok, rec} ->
        case complete_credentials(rec) do
          {:ok, credentials} ->
            {:ok,
             Map.put(
               credentials,
               "token_endpoint_auth_method",
               remote_mcp_token_auth_method(rec["token_endpoint_auth_method"])
             )}

          :incomplete ->
            {:error, :not_configured}
        end

      {:error, :not_found} ->
        {:error, :not_configured}

      other ->
        other
    end
  end

  def put_remote_mcp(tenant_id, provider_key, attrs) do
    provider_key = normalize_remote_mcp_provider_key(provider_key)
    attrs = if is_map(attrs), do: attrs, else: %{}
    key = Keys.ctl_oauth_remote_mcp_provider_app(tenant_id, provider_key)

    current =
      case provider_key != "" and Store.get_record(key) do
        {:ok, rec} -> rec
        _ -> %{}
      end

    client_id =
      if Map.has_key?(attrs, "client_id"),
        do: optional_string(attrs["client_id"]),
        else: current["client_id"] || ""

    client_secret =
      if Map.has_key?(attrs, "client_secret") do
        case optional_string(attrs["client_secret"]) do
          "" -> current["client_secret"] || ""
          value -> value
        end
      else
        current["client_secret"] || ""
      end

    token_endpoint_auth_method =
      if Map.has_key?(attrs, "token_endpoint_auth_method"),
        do: optional_string(attrs["token_endpoint_auth_method"]),
        else: current["token_endpoint_auth_method"] || "client_secret_post"

    with :ok <- require_remote_mcp_provider_key(provider_key),
         :ok <- require_remote_mcp_client_id(client_id),
         :ok <- require_remote_mcp_client_secret(client_secret),
         {:ok, token_endpoint_auth_method} <-
           normalize_remote_mcp_token_auth_method(token_endpoint_auth_method) do
      rec = %{
        "tenant_id" => tenant_id,
        "provider" => "remote_mcp",
        "provider_kind" => "remote_mcp",
        "provider_key" => provider_key,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "token_endpoint_auth_method" => token_endpoint_auth_method,
        "updated_at" => Store.now()
      }

      Store.upsert_record(key, rec, fn _existing -> rec end)
      |> case do
        {:ok, rec} -> {:ok, remote_mcp_provider_app_json(rec)}
        other -> other
      end
    end
  end

  defp require_remote_mcp_provider_key(""),
    do: {:error, {:bad_request, "provider_key is required"}}

  defp require_remote_mcp_provider_key(_provider_key), do: :ok

  defp require_remote_mcp_client_id(""), do: {:error, {:bad_request, "client_id is required"}}
  defp require_remote_mcp_client_id(_client_id), do: :ok

  defp require_remote_mcp_client_secret(""),
    do: {:error, {:bad_request, "client_secret is required"}}

  defp require_remote_mcp_client_secret(_client_secret), do: :ok

  defp normalize_remote_mcp_token_auth_method(value) do
    case optional_string(value) do
      "" ->
        {:ok, "client_secret_post"}

      method when method in ["client_secret_post", "client_secret_basic"] ->
        {:ok, method}

      _method ->
        {:error,
         {:bad_request,
          "token_endpoint_auth_method must be client_secret_post or client_secret_basic"}}
    end
  end

  def delete_remote_mcp(tenant_id, provider_key),
    do:
      Store.delete_record(
        Keys.ctl_oauth_remote_mcp_provider_app(
          tenant_id,
          normalize_remote_mcp_provider_key(provider_key)
        )
      )

  @doc "Remove the deployment default app for `provider`."
  def delete_default(provider) do
    OAuthProviderApps.delete(default_scope(), provider)
  rescue
    _exception -> {:error, :unavailable}
  end

  defp upsert_app(scope, provider, attrs) do
    provider = provider |> to_string() |> String.trim() |> String.downcase()
    attrs = if is_map(attrs), do: attrs, else: %{}

    current =
      case provider != "" and OAuthProviderApps.get(scope, provider) do
        {:ok, rec} -> rec
        _ -> %{}
      end

    client_id =
      if Map.has_key?(attrs, "client_id"),
        do: String.trim(to_string(attrs["client_id"] || "")),
        else: current["client_id"] || ""

    client_secret =
      if Map.has_key?(attrs, "client_secret"),
        do: String.trim(to_string(attrs["client_secret"] || "")),
        else: current["client_secret"] || ""

    cond do
      provider == "" ->
        {:error, {:bad_request, "provider is required"}}

      provider not in SalixStore.OAuth.Adapters.supported() ->
        {:error, {:bad_request, "unsupported oauth provider"}}

      client_id == "" ->
        {:error, {:bad_request, "client_id is required"}}

      true ->
        rec = %{
          "provider" => provider,
          "client_id" => client_id,
          "client_secret" => client_secret,
          "updated_at" => Store.now()
        }

        {:ok, stored} = OAuthProviderApps.put(scope, rec)
        {:ok, oauth_provider_app_json(stored)}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp default_records do
    OAuthProviderApps.list_by_scope(default_scope())
    |> Map.new(&{&1["provider"], &1})
  end

  # The tenant-facing view: the tenant record's own fields (never the
  # default's, so admins see what they typed), the effective resolution
  # source, and the public-safe default client id when a default exists.
  defp provider_view(provider, tenant_rec, default_rec) do
    base =
      oauth_provider_app_json(
        tenant_rec || %{"provider" => provider, "client_id" => "", "client_secret" => ""}
      )

    source =
      cond do
        complete?(tenant_rec) -> "tenant"
        complete?(default_rec) -> "default"
        true -> "none"
      end

    base
    |> Map.put("source", source)
    |> maybe_put_default_client_id(default_rec)
  end

  defp default_view(provider, rec) do
    oauth_provider_app_json(
      rec || %{"provider" => provider, "client_id" => "", "client_secret" => ""}
    )
  end

  defp maybe_put_default_client_id(view, default_rec) do
    if complete?(default_rec) do
      Map.put(view, "default_client_id", String.trim(default_rec["client_id"] || ""))
    else
      view
    end
  end

  defp complete?(rec) when is_map(rec), do: match?({:ok, _}, complete_credentials(rec))
  defp complete?(_rec), do: false

  defp complete_credentials(rec) do
    client_id = String.trim(rec["client_id"] || "")
    client_secret = String.trim(rec["client_secret"] || "")

    if client_id == "" or client_secret == "" do
      :incomplete
    else
      {:ok, %{"client_id" => client_id, "client_secret" => client_secret}}
    end
  end

  defp oauth_provider_app_json(rec) do
    %{
      "provider" => rec["provider"],
      "client_id" => rec["client_id"] || "",
      "client_secret_configured" =>
        Store.present?(rec["client_secret"]) or rec["client_secret_configured"] == true
    }
  end

  defp remote_mcp_provider_app_json(rec) do
    %{
      "provider" => "remote_mcp",
      "provider_kind" => "remote_mcp",
      "provider_key" => rec["provider_key"],
      "client_id" => rec["client_id"] || "",
      "token_endpoint_auth_method" =>
        remote_mcp_token_auth_method(rec["token_endpoint_auth_method"]),
      "client_secret_configured" =>
        Store.present?(rec["client_secret"]) or rec["client_secret_configured"] == true
    }
  end

  defp remote_mcp_token_auth_method("client_secret_basic"), do: "client_secret_basic"
  defp remote_mcp_token_auth_method(_value), do: "client_secret_post"

  defp normalize_remote_mcp_provider_key(value) do
    value
    |> optional_string()
    |> String.replace(~r/[^A-Za-z0-9_.:-]+/, "_")
  end

  defp optional_string(nil), do: ""
  defp optional_string(value) when is_binary(value), do: String.trim(value)
  defp optional_string(value), do: value |> to_string() |> String.trim()
end
