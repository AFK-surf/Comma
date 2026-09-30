defmodule BridgeForTeams.Models do
  @moduledoc """
  Model catalog for BridgeForTeams agents. A "model" is a Salix LLM
  **template** (`SalixAgent.Templates` public catalog): each entry bundles a
  model id and provider config. Salix owns the catalog and resolves an agent's
  provider config live from its `template_id` (`SalixAgent.LlmResolver`); this
  context reads the tenant-visible global and private catalog view (no credentials) and applies
  per-org governance.

  Orgs govern which templates their admins may assign to agents via
  `Organization.allowed_template_ids` (empty = the whole visible catalog) and
  pick per-role org defaults (`default_router_template_id`,
  `default_template_id` for Workers). An agent without a pinned template
  follows the Salix platform default. Org defaults are copied at creation;
  changing them does not modify existing Agents.
  """
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Organization

  @type template :: %{required(String.t()) => term()}
  @type role_defaults :: %{required(String.t()) => template() | nil}

  @doc """
  The platform-layer default template per role (`"router"`, `"worker"`), each
  `nil` when unset. Empty when the Salix control plane is unreachable.
  """
  @spec platform_defaults() :: role_defaults()
  def platform_defaults do
    case Client.impl().effective_agent_defaults(nil) do
      {:ok, defaults} when is_map(defaults) -> defaults
      _ -> %{}
    end
  end

  @doc """
  Initial model per role for new org Agents. An empty org pointer selects the
  platform default. Empty when the control plane is unreachable.
  """
  @spec effective_defaults(Organization.t()) :: role_defaults()
  def effective_defaults(%Organization{salix_tenant_id: tenant_id}) do
    case Client.impl().effective_agent_defaults(tenant_id) do
      {:ok, defaults} when is_map(defaults) -> defaults
      _ -> %{}
    end
  end

  @doc """
  The org tenant's visible Salix template catalog (public view — no credentials).
  `{:error, reason}` when the Salix control plane is unreachable.
  """
  @spec catalog(Organization.t()) :: {:ok, [template()]} | {:error, term()}
  def catalog(%Organization{salix_tenant_id: tenant_id}) do
    case Client.impl().list_templates(tenant_id) do
      templates when is_list(templates) -> {:ok, templates}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  @doc """
  The templates an org's admins may assign — the catalog narrowed to the org's
  `allowed_template_ids` (an empty allowlist means the whole catalog). Returns
  `{:error, reason}` if the catalog can't be read.
  """
  @spec list_for_org(Organization.t()) :: {:ok, [template()]} | {:error, term()}
  def list_for_org(%Organization{allowed_template_ids: allowed} = org) do
    with {:ok, templates} <- catalog(org) do
      {:ok, filter_allowed(templates, allowed)}
    end
  end

  @doc "A `{label, template_id}` option list for a model `<select>`."
  def options(templates, current \\ nil) do
    Enum.flat_map(templates, fn t ->
      cond do
        t["template_id"] != "default" -> [{option_label(t), t["template_id"]}]
        current == "default" -> [[key: "#{t["model"]} (current choice)", value: "default"]]
        true -> []
      end
    end)
  end

  @doc "Main model display name, with its model or template ID as fallback."
  @spec label(template()) :: String.t()
  def label(%{"model_display_name" => name}) when is_binary(name) and name != "", do: name
  def label(%{"model" => model}) when is_binary(model) and model != "", do: model
  def label(%{"template_id" => id}) when is_binary(id), do: id
  def label(_), do: ""

  def option_label(template) do
    model = label(template)
    alias_name = template["name"]

    if is_binary(alias_name) and alias_name not in ["", model],
      do: "#{model} — #{alias_name}",
      else: model
  end

  @doc "Resolve a template's display model id from a catalog list, or `nil`."
  @spec model_for(String.t() | nil, [template()]) :: String.t() | nil
  def model_for(template_id, templates) when is_binary(template_id) do
    Enum.find_value(templates, fn
      %{"template_id" => ^template_id} = t -> t["model"]
      _ -> nil
    end)
  end

  def model_for(_template_id, _templates), do: nil

  defp filter_allowed(templates, allowed) when is_list(allowed) and allowed != [] do
    Enum.filter(templates, &(&1["template_id"] in allowed))
  end

  defp filter_allowed(templates, _allowed), do: templates
end
