defmodule Salix.Control.ComposioSettings do
  @moduledoc """
  Tenant Composio settings control-plane API, plus the deployment-wide default
  record — the opt-in switch for the Composio integrations path that runs
  alongside managed OAuth (`Salix.Control.OAuthApps`).

  A settings record holds the tenant's Composio project `api_key` (write-only
  in every view, like OAuth client secrets), an `enabled` flag, and an optional
  `base_url` override. Resolution (`get/1`) is tenant-first, mirroring
  `OAuthApps.get/2`: a tenant record with a non-blank api key and
  `enabled != false` wins; anything less falls back to the deployment default
  (operator-managed via the `/v1/admin/composio/default-settings` API); with
  neither, the tenant is `:not_configured` and the `composio.*` agent tools
  report that.

  The record also owns a secret ingress URL. Dedicated webhook registration
  configures Composio delivery. Ordinary settings views omit the URL credential.

  Records live in Postgres (`SalixStore.ComposioSettings`,
  docs/storage-search.md), keyed by scope: the tenant id, or
  the reserved default scope for the deployment default. Serving reads Postgres
  directly; the readiness gate keeps a pod out of service until the cutover
  marker exists (`Comma.PodLifecycle.ready(:salix)`).
  """

  alias Salix.Control.Store
  alias SalixStore.ComposioSettings, as: Data

  @doc """
  Effective Composio settings for `tenant_id`
  (`%{"api_key" => _, "base_url" => _}`), or `{:error, :not_configured}`.
  """
  def get(tenant_id) do
    case complete_record(tenant_id) do
      {:ok, settings} -> {:ok, settings}
      :incomplete -> get_default()
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @doc "The deployment default settings (complete + enabled records only)."
  def get_default do
    case complete_record(Data.default_scope()) do
      {:ok, settings} -> {:ok, settings}
      :incomplete -> {:error, :not_configured}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @doc """
  The tenant-facing redacted view: the tenant record's own fields plus the
  effective resolution `"source"` (`"tenant" | "default" | "none"`).
  """
  def view(tenant_id) do
    tenant_rec = read_record(tenant_id)
    default_rec = read_record(Data.default_scope())

    source =
      cond do
        complete?(tenant_rec) -> "tenant"
        complete?(default_rec) -> "default"
        true -> "none"
      end

    tenant_rec |> settings_json() |> Map.put("source", source)
  end

  @doc "The operator-facing redacted view of the deployment default record."
  def view_default do
    Data.default_scope() |> read_record() |> settings_json()
  end

  @doc """
  Create/update the tenant settings. `attrs` may carry `"api_key"` (write-only;
  omitting the key keeps the stored one), `"enabled"`, and `"base_url"`.
  """
  def put(tenant_id, attrs), do: upsert(tenant_id, attrs)

  @doc "Create/update the deployment default settings (same contract as `put/2`)."
  def put_default(attrs), do: upsert(Data.default_scope(), attrs)

  def delete(tenant_id) do
    delete_scope(tenant_id)
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc "Remove the deployment default settings."
  def delete_default do
    delete_scope(Data.default_scope())
  rescue
    _exception -> {:error, :unavailable}
  end

  defp delete_scope(scope) do
    case Data.locked(scope, fn -> {:ok, Data.delete(scope)} end) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Configure this scope's Composio project webhook. Explicit replacement can rotate its secret URL."
  def configure_webhook(scope, attrs) do
    Data.locked(scope, fn ->
      with {:ok, rec} <- Data.get(scope),
           true <- complete?(rec),
           secret <-
             if(attrs["rotate"] == true or is_nil(rec["webhook_secret"]),
               do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
               else: rec["webhook_secret"]
             ),
           url <-
             String.trim_trailing(SalixWeb.Application.public_base_url(), "/") <>
               "/v1/composio-webhooks/" <> secret,
           {:ok, %{"items" => subscriptions}} <- client().list_webhook_subscriptions(rec),
           {:ok, id} <- subscription_id(subscriptions, rec["webhook_secret"], attrs),
           {:ok, _} <- client().set_webhook_subscription(rec, url, id),
           {:ok, _} <- Data.put(scope, Map.put(rec, "webhook_secret", secret)) do
        {:ok, %{"status" => "configured", "webhook_url" => url}}
      else
        false -> {:error, :not_configured}
        {:error, _} = error -> error
        _ -> {:error, :invalid_composio_response}
      end
    end)
  end

  defp subscription_id([], _secret, _attrs), do: {:ok, nil}

  defp subscription_id([%{"id" => id, "webhook_url" => url}], secret, attrs) do
    expected =
      if is_binary(secret),
        do:
          String.trim_trailing(SalixWeb.Application.public_base_url(), "/") <>
            "/v1/composio-webhooks/" <> secret

    if url == expected or attrs["replace_existing"] == true,
      do: {:ok, id},
      else: {:error, :existing_project_webhook}
  end

  defp subscription_id(_, _, _), do: {:error, :invalid_composio_response}

  defp client, do: Application.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)

  defp upsert(scope, attrs), do: Data.locked(scope, fn -> do_upsert(scope, attrs) end)

  defp do_upsert(scope, attrs) do
    attrs = if is_map(attrs), do: attrs, else: %{}

    current = read_record(scope) || %{}

    api_key =
      if Map.has_key?(attrs, "api_key"),
        do: String.trim(to_string(attrs["api_key"] || "")),
        else: current["api_key"] || ""

    base_url =
      if Map.has_key?(attrs, "base_url"),
        do: String.trim(to_string(attrs["base_url"] || "")),
        else: current["base_url"] || ""

    enabled =
      if Map.has_key?(attrs, "enabled"),
        do: attrs["enabled"] != false,
        else: current["enabled"] != false

    if api_key == "" do
      {:error, {:bad_request, "api_key is required"}}
    else
      rec = %{
        "api_key" => api_key,
        "webhook_secret" =>
          if(api_key == current["api_key"] and base_url == current["base_url"],
            do: current["webhook_secret"],
            else: nil
          ),
        "base_url" => base_url,
        "enabled" => enabled,
        "updated_at" => Store.now()
      }

      {:ok, _stored} = Data.put(scope, rec)
      {:ok, settings_json(rec)}
    end
  rescue
    # A Postgres fault on the (admin-frequency) write surfaces as a structured
    # error the dashboard/API caller can show, not an unhandled crash.
    _exception -> {:error, :unavailable}
  end

  defp read_record(scope) do
    case Data.get(scope) do
      {:ok, rec} -> rec
      _ -> nil
    end
  rescue
    # A store fault must degrade the redacted view to "none" (the pre-migration
    # S3 read behaved the same way), never crash the dashboard/API render.
    _exception -> nil
  end

  defp complete_record(scope) do
    case Data.get(scope) do
      {:ok, rec} ->
        if complete?(rec) do
          {:ok,
           %{
             "api_key" => String.trim(rec["api_key"]),
             "base_url" => rec["base_url"] || "",
             "scope" => scope,
             "webhook_configured" => is_binary(rec["webhook_secret"])
           }}
        else
          :incomplete
        end

      {:error, :not_found} ->
        :incomplete
    end
  rescue
    # A Postgres/DBConnection fault on the hot resolve path surfaces as
    # unavailable (the retired S3 path propagated its faults the same way),
    # never crashing composio tools / connect / meeting flows.
    _exception -> {:error, :unavailable}
  end

  defp complete?(rec) when is_map(rec),
    do: String.trim(to_string(rec["api_key"] || "")) != "" and rec["enabled"] != false

  defp complete?(_rec), do: false

  defp settings_json(rec) do
    rec = rec || %{}

    %{
      "enabled" => rec["enabled"] != false and Store.present?(rec["api_key"]),
      "api_key_configured" => Store.present?(rec["api_key"]),
      "webhook_configured" => Store.present?(rec["webhook_secret"]),
      "base_url" => rec["base_url"] || ""
    }
  end
end
