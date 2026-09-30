defmodule Salix.Control.DriveBindings do
  @moduledoc """
  Per-group Drive bindings: which Synchronicity org, network and space a
  group's agents reach as `/drive`, and the org API key they reach it with
  (`docs/tools-integrations.md`).

  A binding's `source` says who owns it: `"comma"` when Comma's Workspace
  convergence minted the key and wrote the row, `"manual"` when an operator
  entered an org key in the Salix dashboard (the path a BridgeForTeams
  deployment uses). The api_key is write-only in every view.

  `handle/1` is the hot path the agent's mount takes: the binding, its
  effective control-plane origin (its own `base_url`, else the tenant's or
  the deployment's `Salix.Control.DriveSettings`), and the key, as a
  `Salix.Drive.Handle`.
  """

  alias Salix.Control.{DriveSettings, Groups, Store}
  alias Salix.Drive.Handle
  alias SalixStore.DriveBindings, as: Data

  @default_network "default"
  # The space the Comma desktop app publishes as the install's Drive.
  @default_space "comma-drive"

  @doc """
  The enabled, complete binding of `group_id` with its api_key, the one the
  agent mount may use; `{:error, :not_configured}` for a disabled or
  incomplete row as much as for a missing one. A writer deciding whether a
  row exists reads `stored/1` instead.
  """
  def get(group_id) when is_binary(group_id) do
    case Data.get(group_id) do
      {:ok, rec} -> if complete?(rec), do: {:ok, rec}, else: {:error, :not_configured}
      {:error, :not_found} -> {:error, :not_configured}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc """
  The binding of `group_id` as stored, with its api_key, whether or not it is
  enabled or complete: what an owner (Comma's convergence) consults before
  writing. `{:error, :not_found}` when there is no row.
  """
  @spec stored(String.t()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def stored(group_id) when is_binary(group_id) do
    Data.get(group_id)
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc "The redacted view of the binding of `group_id`, for dashboards and APIs."
  def view(group_id) when is_binary(group_id) do
    case Data.get(group_id) do
      {:ok, rec} -> binding_json(rec)
      {:error, :not_found} -> binding_json(nil)
    end
  rescue
    _exception -> binding_json(nil)
  end

  @doc """
  The handle the agent mount reaches the group's Drive with, or
  `{:error, :not_configured}` when the group has no enabled binding or no
  control-plane origin resolves for it.
  """
  @spec handle(String.t()) :: {:ok, Handle.t()} | {:error, :not_configured | :unavailable}
  def handle(group_id) when is_binary(group_id) do
    with {:ok, rec} <- get(group_id),
         {:ok, base_url} <- base_url(group_id, rec) do
      {:ok,
       %Handle{
         group_id: group_id,
         base_url: base_url,
         org_slug: rec["org_slug"],
         network: rec["network"],
         space: rec["space"],
         token: rec["api_key"],
         req_options: Application.get_env(:salix_web, :drive_req_options, [])
       }}
    end
  end

  @doc """
  Create/update the binding of `group_id`. `attrs` may carry `"org_slug"`,
  `"network"` (default `#{@default_network}`), `"space"` (default
  `#{@default_space}`), `"base_url"` (blank means the Drive settings apply),
  `"api_key"` (write-only; omitting it keeps the stored one), `"api_key_id"`,
  `"retired_key_ids"` (ids of earlier keys still to be revoked; omitting it
  keeps the stored list), `"source"` (`comma | manual`, default `manual`) and
  `"enabled"`.
  """
  def put(group_id, attrs) when is_binary(group_id) do
    attrs = if is_map(attrs), do: attrs, else: %{}
    current = read_record(group_id) || %{}

    api_key = text(attrs, current, "api_key")
    org_slug = text(attrs, current, "org_slug")
    network = text(attrs, current, "network", @default_network)
    space = text(attrs, current, "space", @default_space)
    base_url_input = text(attrs, current, "base_url")
    api_key_id = text(attrs, current, "api_key_id")
    retired_key_ids = retired_key_ids(attrs, current)
    source = text(attrs, current, "source", "manual")

    enabled =
      if Map.has_key?(attrs, "enabled"),
        do: attrs["enabled"] != false,
        else: current["enabled"] != false

    with :ok <- required(api_key, "api_key"),
         :ok <- required(org_slug, "org_slug"),
         :ok <- label(org_slug, "org_slug"),
         :ok <- label(network, "network"),
         :ok <- required(space, "space"),
         :ok <- source_known(source),
         {:ok, base_url} <- optional_base_url(base_url_input) do
      rec = %{
        "base_url" => base_url,
        "org_slug" => org_slug,
        "network" => network,
        "space" => space,
        "api_key" => api_key,
        "api_key_id" => api_key_id,
        "retired_key_ids" => retired_key_ids,
        "source" => source,
        "enabled" => enabled,
        "updated_at" => Store.now()
      }

      {:ok, _stored} = Data.put(group_id, rec)
      {:ok, binding_json(rec)}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def delete(group_id) when is_binary(group_id) do
    Data.delete(group_id)
  rescue
    _exception -> {:error, :unavailable}
  end

  defp base_url(group_id, rec) do
    if Store.present?(rec["base_url"]) do
      {:ok, rec["base_url"]}
    else
      tenant_id =
        case Groups.get(group_id) do
          {:ok, group} -> group["tenant_id"]
          _ -> nil
        end

      case DriveSettings.get(tenant_id) do
        {:ok, %{"base_url" => base_url}} -> {:ok, base_url}
        {:error, _} = error -> error
      end
    end
  end

  defp read_record(group_id) do
    case Data.get(group_id) do
      {:ok, rec} -> rec
      _ -> nil
    end
  rescue
    _exception -> nil
  end

  defp complete?(rec) when is_map(rec),
    do:
      rec["enabled"] != false and Store.present?(rec["api_key"]) and
        Store.present?(rec["org_slug"]) and Store.present?(rec["network"]) and
        Store.present?(rec["space"])

  defp complete?(_rec), do: false

  defp text(attrs, current, key, default \\ "") do
    value =
      if Map.has_key?(attrs, key),
        do: attrs[key],
        else: current[key]

    case String.trim(to_string(value || "")) do
      "" -> default
      trimmed -> trimmed
    end
  end

  # Non-blank strings, in order, without repeats; the stored list unless the
  # caller names one.
  defp retired_key_ids(attrs, current) do
    value =
      if Map.has_key?(attrs, "retired_key_ids"),
        do: attrs["retired_key_ids"],
        else: current["retired_key_ids"]

    value
    |> List.wrap()
    |> Enum.map(&String.trim(to_string(&1 || "")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp required("", key), do: {:error, {:bad_request, "#{key} is required"}}
  defp required(_value, _key), do: :ok

  # Org slugs and network names are DNS labels on the control plane; refusing
  # anything else here keeps a typo out of a URL.
  defp label(value, key) do
    if Regex.match?(~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/, value),
      do: :ok,
      else: {:error, {:bad_request, "#{key} must be a DNS label of 1..63 [a-z0-9-]"}}
  end

  defp source_known(source) do
    if source in Data.sources(),
      do: :ok,
      else: {:error, {:bad_request, "source must be one of #{Enum.join(Data.sources(), ", ")}"}}
  end

  defp optional_base_url(""), do: {:ok, ""}

  defp optional_base_url(value) do
    case DriveSettings.normalize_base_url(value) do
      {:ok, base_url} -> {:ok, base_url}
      {:error, message} -> {:error, {:bad_request, message}}
    end
  end

  defp binding_json(rec) do
    rec = rec || %{}

    %{
      "configured" => complete?(rec),
      "enabled" => rec["enabled"] != false and Store.present?(rec["api_key"]),
      "api_key_configured" => Store.present?(rec["api_key"]),
      "api_key_id" => rec["api_key_id"] || "",
      "retired_key_ids" => List.wrap(rec["retired_key_ids"]),
      "base_url" => rec["base_url"] || "",
      "org_slug" => rec["org_slug"] || "",
      "network" => rec["network"] || "",
      "space" => rec["space"] || "",
      "source" => rec["source"] || "",
      "updated_at" => rec["updated_at"]
    }
  end
end
