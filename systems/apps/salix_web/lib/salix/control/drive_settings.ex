defmodule Salix.Control.DriveSettings do
  @moduledoc """
  Drive settings control-plane API: the Synchronicity control plane the
  agents' `/drive` mount reaches (`docs/tools-integrations.md`).

  A record holds the control plane's `base_url` and an `enabled` flag.
  Resolution (`get/1`) is tenant-first, as `Salix.Control.ComposioSettings`
  resolves: a tenant record with a non-blank origin and `enabled != false`
  wins, else the deployment default, else `:not_configured`. A group's
  binding may name its own `base_url` (`Salix.Control.DriveBindings`), in
  which case this record is not consulted for that group.

  Records live in Postgres (`SalixStore.DriveSettings`), keyed by scope: the
  tenant id, or the reserved default scope.
  """

  alias Salix.Control.Store
  alias SalixStore.DriveSettings, as: Data

  @doc "Effective settings for `tenant_id` (`%{\"base_url\" => _}`), or `{:error, :not_configured}`."
  def get(tenant_id) when is_binary(tenant_id) do
    case complete_record(tenant_id) do
      {:ok, settings} -> {:ok, settings}
      :incomplete -> get_default()
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  def get(_tenant_id), do: get_default()

  @doc "The deployment default settings (complete + enabled records only)."
  def get_default do
    case complete_record(Data.default_scope()) do
      {:ok, settings} -> {:ok, settings}
      :incomplete -> {:error, :not_configured}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @doc "The tenant-facing view, with the effective `\"source\"` (`tenant | default | none`)."
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

  @doc "The operator-facing view of the deployment default record."
  def view_default, do: Data.default_scope() |> read_record() |> settings_json()

  @doc "Create/update the tenant settings: `\"base_url\"` and `\"enabled\"`."
  def put(tenant_id, attrs), do: upsert(tenant_id, attrs)

  @doc "Create/update the deployment default settings (same contract as `put/2`)."
  def put_default(attrs), do: upsert(Data.default_scope(), attrs)

  def delete(tenant_id) do
    Data.delete(tenant_id)
  rescue
    _exception -> {:error, :unavailable}
  end

  def delete_default do
    Data.delete(Data.default_scope())
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc """
  Validates a control-plane origin the way the file client needs it: one
  HTTPS origin (loopback HTTP for development), no path, query, fragment or
  userinfo, trailing slash dropped.
  """
  @spec normalize_base_url(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_base_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.new(value) do
      {:ok, uri} ->
        loopback_http? = uri.scheme == "http" and uri.host in ["127.0.0.1", "::1", "localhost"]

        if (uri.scheme == "https" or loopback_http?) and is_binary(uri.host) and uri.host != "" and
             uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
             uri.path in [nil, "", "/"] do
          {:ok, String.trim_trailing(value, "/")}
        else
          {:error, "base_url must be one HTTPS origin, for example https://sync.example.com"}
        end

      {:error, _reason} ->
        {:error, "base_url must be one HTTPS origin, for example https://sync.example.com"}
    end
  end

  def normalize_base_url(_value), do: {:error, "base_url is required"}

  defp upsert(scope, attrs) do
    attrs = if is_map(attrs), do: attrs, else: %{}
    current = read_record(scope) || %{}

    base_url_input =
      if Map.has_key?(attrs, "base_url"),
        do: to_string(attrs["base_url"] || ""),
        else: current["base_url"] || ""

    enabled =
      if Map.has_key?(attrs, "enabled"),
        do: attrs["enabled"] != false,
        else: current["enabled"] != false

    case normalize_base_url(base_url_input) do
      {:error, message} ->
        {:error, {:bad_request, message}}

      {:ok, base_url} ->
        rec = %{"base_url" => base_url, "enabled" => enabled, "updated_at" => Store.now()}
        {:ok, _stored} = Data.put(scope, rec)
        {:ok, settings_json(rec)}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp read_record(scope) do
    case Data.get(scope) do
      {:ok, rec} -> rec
      _ -> nil
    end
  rescue
    _exception -> nil
  end

  defp complete_record(scope) do
    case Data.get(scope) do
      {:ok, rec} ->
        if complete?(rec), do: {:ok, %{"base_url" => rec["base_url"]}}, else: :incomplete

      {:error, :not_found} ->
        :incomplete
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp complete?(rec) when is_map(rec),
    do: Store.present?(rec["base_url"]) and rec["enabled"] != false

  defp complete?(_rec), do: false

  defp settings_json(rec) do
    rec = rec || %{}

    %{
      "enabled" => rec["enabled"] != false and Store.present?(rec["base_url"]),
      "base_url" => rec["base_url"] || ""
    }
  end
end
