defmodule BridgeForTeams.Models do
  @moduledoc """
  Model governance for BridgeForTeams Agents.

  An Agent's model is a Salix model choice (`SalixAgent.ModelChoice`), stored
  as a value in the Agent's Salix record (`model`). A catalog choice is
  `%{"kind" => "catalog", "model" => id}`, with optional `reasoning_effort`,
  `allow_paid` and `profile_id`. An Agent without a choice follows the
  platform model of its role (`SalixAgent.AgentModel`). Salix owns the
  catalog and checks every choice; this context reads the catalog (no
  credentials) and applies per-org governance:

    * `Organization.allowed_models` lists the choices that org admins can give
      to Agents. An empty list allows every model.
    * `Organization.default_router_model` is the choice that a new Router
      gets: a copy, so a later change does not change existing Routers. nil =
      the platform model of the role.
    * `Organization.default_task_model` is the org default Task model: the
      model a Task runs when it names none and its swarm has no default Task
      model of its own (`SalixAgent.TaskModel`); Salix reads it when it makes
      the Task (`default_task_model/1`). nil = the platform model.

  Each choice has a stable string `key/1` for UI state. The API exchanges the
  choice maps.
  """
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Organization, Project}

  @type choice :: %{required(String.t()) => term()}

  @typedoc "A choice with its key and label (`option/2`)."
  @type option :: %{required(String.t()) => term()}

  @roles ~w(router worker)
  @router_effort "medium"
  @vendors %{
    "ant-ling" => "Ant Ling",
    "anthropic" => "Anthropic",
    "deepseek" => "DeepSeek",
    "glm" => "GLM",
    "google" => "Google",
    "kimi" => "Kimi",
    "meta" => "Meta",
    "minimax" => "MiniMax",
    "mistral" => "Mistral",
    "nvidia" => "NVIDIA",
    "openai" => "OpenAI",
    "qwen" => "Qwen",
    "xai" => "xAI",
    "xiaomi" => "Xiaomi"
  }

  @doc "The catalog choices, one plain catalog choice per catalog model."
  @spec catalog() :: {:ok, [option()]} | {:error, term()}
  def catalog do
    with {:ok, models} <- Client.impl().model_catalog() do
      {:ok,
       for %{"id" => id} = model <- models, is_binary(id) do
         choice = normalize(%{"kind" => "catalog", "model" => id})

         %{
           "key" => key(choice),
           "choice" => choice,
           "label" => text(model["name"]) || id,
           "vendor" => text(model["vendor"])
         }
       end}
    end
  end

  @doc """
  What the org's own enabled accounts can serve now, by model id: a map with
  `served_by` (`"subscription"` or `"api_key"`), `plans` (the subscription
  sources, such as `"codex"`) and `key_sources` (the names of the Provider API
  key sources that serve it pay-per-use, such as `"OpenRouter"`). Custom
  endpoints add the model ids they list. Reads at most 100 accounts
  (`SalixAgent.AccountPool.servable_models/2`).
  """
  @spec servable(Organization.t()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def servable(%Organization{salix_tenant_id: tenant}) when is_binary(tenant) do
    case Client.call_optional(:servable_models, [tenant]) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok,
         for %{"id" => id} = model <- models, is_binary(id), into: %{} do
           {id,
            %{
              "served_by" => model["served_by"],
              "plans" => List.wrap(model["subscription_plans"]),
              "key_sources" =>
                for(%{"name" => name} <- List.wrap(model["api_key_sources"]), do: name),
              "label" => text(model["name"]) || id,
              "vendor" => text(model["vendor"])
            }}
         end}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected, other}}
    end
  end

  def servable(%Organization{}), do: {:ok, %{}}

  @doc """
  The choices that org admins can give to Agents: the allowed list, or the
  whole catalog when the list is empty.
  """
  @spec allowed(Organization.t(), {:ok, [option()]} | {:error, term()}) ::
          {:ok, [option()]} | {:error, term()}
  def allowed(%Organization{allowed_models: allowed}, catalog_result) do
    case {allowed || [], catalog_result} do
      {[], result} -> result
      {allowed, {:ok, catalog}} -> {:ok, Enum.map(allowed, &option(&1, catalog))}
      {allowed, {:error, _reason}} -> {:ok, Enum.map(allowed, &option(&1, []))}
    end
  end

  @doc """
  Whether the org admins can give `choice` to an Agent. An allowed choice
  without `reasoning_effort` allows the model at any effort; one with an
  effort allows only that effort.
  """
  @spec allowed?(Organization.t(), choice(), {:ok, [option()]} | {:error, term()}) :: boolean()
  def allowed?(%Organization{} = org, choice, catalog_result) do
    case allowed(org, catalog_result) do
      {:ok, options} -> Enum.any?(options, &allows?(&1["choice"], choice))
      {:error, _reason} -> false
    end
  end

  defp allows?(allowed, choice) do
    allowed = normalize(allowed)
    choice = normalize(choice)

    if Map.has_key?(allowed, "reasoning_effort"),
      do: allowed == choice,
      else: allowed == Map.delete(choice, "reasoning_effort")
  end

  @doc "The org default choice for a new Router, or nil (the platform model)."
  @spec default_for(Organization.t(), String.t()) :: choice() | nil
  def default_for(%Organization{default_router_model: choice}, "router"), do: choice
  def default_for(%Organization{}, _role), do: nil

  @doc """
  The org default Task model of a project's org, for a swarm without its own
  (`Salix.Bindings.AgentManagement.default_task_model/1`): a catalog choice,
  or nil (the platform model).
  """
  @spec default_task_model(String.t()) :: {:ok, choice() | nil} | {:error, term()}
  def default_task_model(project_id) do
    case Repo.get(Project, project_id) |> Repo.preload(:org) do
      %Project{org: %Organization{default_task_model: %{"kind" => "catalog"} = choice}} ->
        {:ok, normalize(choice)}

      %Project{org: %Organization{}} ->
        {:ok, nil}

      _missing ->
        {:error, :target_not_found}
    end
  end

  @doc """
  The model a project's Router may give to a new Worker or to one Task's
  Worker Session (`Salix.Bindings.AgentManagement`). nil answers the org
  default Task model for a new Worker. A catalog choice without `reasoning_effort` takes
  `#{@router_effort}` when the catalog model offers it, and stays without an
  effort otherwise. It must be in the org's allowed list unless the list is
  empty (matched as in `allowed?/3`); Salix then checks it against the
  catalog. The platform model and a station's runtime models need no
  allowance.
  """
  @spec router_choice(String.t(), choice() | nil) :: {:ok, choice() | nil} | {:error, term()}
  def router_choice(project_id, choice) do
    case Repo.get(Project, project_id) |> Repo.preload(:org) do
      %Project{org: %Organization{} = org} -> org_router_choice(org, default_effort(choice))
      _missing -> {:error, :target_not_found}
    end
  end

  defp default_effort(%{"kind" => "catalog", "model" => model} = choice) do
    if choice["reasoning_effort"] in [nil, ""] and @router_effort in efforts(model),
      do: Map.put(choice, "reasoning_effort", @router_effort),
      else: choice
  end

  defp default_effort(choice), do: choice

  # The reasoning efforts of a catalog model; none when the catalog does not
  # name it or cannot be read.
  defp efforts(model) do
    with {:ok, models} <- Client.impl().model_catalog(),
         %{"efforts" => efforts} when is_list(efforts) <-
           Enum.find(models, &(&1["id"] == model)) do
      efforts
    else
      _unknown -> []
    end
  end

  defp org_router_choice(%Organization{default_task_model: choice}, nil), do: {:ok, choice}

  defp org_router_choice(
         %Organization{allowed_models: [_ | _] = allowed},
         %{"kind" => "catalog"} = choice
       ) do
    choice = normalize(choice)

    if Enum.any?(allowed, &allows?(&1, choice)),
      do: {:ok, choice},
      else: {:error, :model_not_allowed}
  end

  defp org_router_choice(_org, choice), do: {:ok, choice}

  @doc """
  The filter a project's Router applies to the models it may choose
  (`agent.models`, `SalixAgent.AccountPool.servable_models/2`). It keeps what
  `router_choice/2` accepts: every model when the allowed list is empty.
  Otherwise a model stays when an allowed choice names it, with an effort the
  model offers or none, and the org's Profiles can serve that choice: without
  `allow_paid` only a subscription can. The model then keeps only the efforts
  those choices allow, `requires_allow_paid` says whether all of them are
  pay-per-use, and `choices` lists them.
  """
  @spec router_model_filter(String.t()) :: {:ok, ([map()] -> [map()])} | {:error, term()}
  def router_model_filter(project_id) do
    case Repo.get(Project, project_id) |> Repo.preload(:org) do
      %Project{org: %Organization{allowed_models: [_ | _] = allowed}} ->
        allowed = Enum.map(allowed, &normalize/1)
        {:ok, fn models -> Enum.flat_map(models, &allowed_model(&1, allowed)) end}

      %Project{org: %Organization{}} ->
        {:ok, &Function.identity/1}

      _missing ->
        {:error, :target_not_found}
    end
  end

  defp allowed_model(%{"id" => id} = model, allowed) do
    efforts = List.wrap(model["efforts"])
    subscription? = model["served_by"] == "subscription"

    choices =
      Enum.filter(allowed, fn choice ->
        choice["kind"] == "catalog" and choice["model"] == id and
          (choice["allow_paid"] == true or subscription?) and
          (choice["reasoning_effort"] in [nil, ""] or choice["reasoning_effort"] in efforts)
      end)

    allowed_efforts =
      if Enum.any?(choices, &(&1["reasoning_effort"] in [nil, ""])),
        do: efforts,
        else:
          Enum.filter(efforts, fn effort ->
            Enum.any?(choices, &(&1["reasoning_effort"] == effort))
          end)

    if choices == [],
      do: [],
      else: [
        Map.merge(model, %{
          "efforts" => allowed_efforts,
          "requires_allow_paid" => Enum.all?(choices, &(&1["allow_paid"] == true)),
          "choices" => choices
        })
      ]
  end

  defp allowed_model(_model, _allowed), do: []

  @doc """
  The platform model that each role follows, as `%{"label", "model_icon"}`,
  or nil when it is not configured or Salix is unavailable.
  """
  @spec platform_defaults() :: %{required(String.t()) => map() | nil}
  def platform_defaults, do: Map.new(@roles, &{&1, platform_default(&1)})

  @doc "The platform model that `role` follows (see `platform_defaults/0`)."
  @spec platform_default(String.t()) :: map() | nil
  def platform_default(role) do
    case Client.impl().platform_model(role) do
      {:ok, public} when is_map(public) ->
        %{"label" => public_label(public), "model_icon" => public["model_icon"]}

      _unavailable ->
        nil
    end
  end

  @doc """
  Check `choice` against the org tenant (`SalixAgent.ModelChoice.choose/2`).
  A plain catalog choice of a catalog model needs no Salix call.
  """
  @spec choose(Organization.t(), term(), {:ok, [option()]} | {:error, term()}) ::
          {:ok, choice()} | {:error, term()}
  def choose(%Organization{salix_tenant_id: tenant_id}, choice, catalog_result)
      when is_map(choice) do
    choice = normalize(choice)

    if in_catalog?(choice, catalog_result),
      do: {:ok, choice},
      else: Client.impl().choose_model(choice, tenant_id)
  end

  def choose(_org, _choice, _catalog_result), do: {:error, :invalid_model_configuration}

  @doc """
  Whether `choice` is a plain catalog choice of the catalog, pay-per-use
  allowed or not.
  """
  @spec in_catalog?(choice(), {:ok, [option()]} | {:error, term()}) :: boolean()
  def in_catalog?(choice, {:ok, catalog}) do
    choice = choice |> normalize() |> Map.put("allow_paid", false)
    Enum.any?(catalog, &(&1["choice"] == choice))
  end

  def in_catalog?(_choice, _catalog_result), do: false

  @doc """
  The option of `choice`: its catalog entry, or a key and a label made from
  the choice when the catalog does not offer it.
  """
  @spec option(choice(), [option()]) :: option()
  def option(choice, catalog) do
    choice = normalize(choice)

    Enum.find(catalog, &(&1["choice"] == choice)) ||
      %{"key" => key(choice), "choice" => choice, "label" => label(choice), "vendor" => nil}
  end

  @doc """
  A choice in the form that Salix stores it: a catalog choice always says
  whether pay-per-use Profiles may serve it (`allow_paid`, default false).
  Compare choices in this form.
  """
  @spec normalize(choice()) :: choice()
  def normalize(%{"kind" => "catalog"} = choice), do: Map.put_new(choice, "allow_paid", false)
  def normalize(choice), do: choice

  @doc """
  The stable UI key of a choice: `catalog:<model>`, `runtime:<provider>:<model>`
  or `platform:<tier>`, then `@<effort>`, `+paid` and `#<profile_id>` when set.
  """
  @spec key(choice()) :: String.t()
  def key(%{"kind" => "catalog", "model" => model} = choice),
    do: "catalog:#{model}" <> suffix(choice)

  def key(%{"kind" => "runtime", "provider" => provider, "model" => model} = choice),
    do: "runtime:#{provider}:#{model}" <> suffix(choice)

  def key(%{"kind" => "platform", "tier" => tier}), do: "platform:#{tier}"
  def key(choice), do: "other:" <> Jason.encode!(choice)

  defp suffix(choice) do
    Enum.join([
      if(effort = text(choice["reasoning_effort"]), do: "@" <> effort, else: ""),
      if(choice["allow_paid"] == true, do: "+paid", else: ""),
      if(profile = text(choice["profile_id"]), do: "#" <> profile, else: "")
    ])
  end

  @doc "A label for a choice that the catalog does not name."
  @spec label(choice()) :: String.t()
  def label(%{"kind" => "runtime", "provider" => provider, "model" => model} = choice),
    do: with_effort("#{String.capitalize(provider)}: #{model}", choice)

  def label(%{"kind" => "platform", "tier" => tier}), do: "Platform model (#{tier})"
  def label(%{"model" => model} = choice) when is_binary(model), do: with_effort(model, choice)
  def label(_choice), do: "Unknown model"

  defp with_effort(label, choice) do
    case text(choice["reasoning_effort"]) do
      nil -> label
      effort -> "#{label} · #{effort}"
    end
  end

  @doc "The display name of a catalog vendor id, or nil for an unknown vendor."
  @spec vendor_label(term()) :: String.t() | nil
  def vendor_label(vendor), do: @vendors[vendor]

  @doc "The display name of a credential-free model view (`public_model/2`)."
  @spec public_label(map()) :: String.t()
  def public_label(public) do
    text(public["model_display_name"]) || text(public["name"]) || text(public["model"]) || ""
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil
end
