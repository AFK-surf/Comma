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

  A Router of an org whose tenant has a platform Router
  (`SalixAgent.PlatformRouter`) holds the marked catalog choice
  `"platform" => true`. Only the platform admin stores it: no org write
  offers, allows or stores a marked choice, and an org admin who gives the
  Router another model cannot give the marked one back (`platform?/1`). The
  platform admin's option decides whether the org's API keys follow its
  subscriptions in the fallback; a marked choice then also carries
  `"allow_paid" => true` (key suffix `+paid+platform`) and is still never
  offered or allowed.
  While the platform Router exists, every new Router takes it, so the default
  Router model has no effect (`platform_router/1`).

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
  (`SalixAgent.AccountPool.servable_models/2`); a cut list is an error
  (`:truncated`), since a model it leaves out is not known to be unserved.
  """
  @spec servable(Organization.t()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def servable(%Organization{salix_tenant_id: tenant}) when is_binary(tenant) do
    case Client.call_optional(:servable_models, [tenant]) do
      {:ok, %{"truncated" => true}} ->
        {:error, :truncated}

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
  The choices a swarm model picker offers: those the org admins can give to
  an Agent (`allowed?/3`) that an enabled account of the org serves now, by
  `servable/1`'s result. A catalog choice no account serves stops every round
  it runs (`model_unavailable`), so a picker does not offer it.

  With an allowed list, its choices that an account serves, as the admins
  stored them: a plain choice for a subscription, a pay-per-use choice
  (`allow_paid`) for a Provider API key. Without one, each catalog model a
  subscription serves as a plain choice and each model a key serves as a
  pay-per-use choice, then the pay-per-use choices of the models only a
  custom endpoint lists. `paid_label` labels each pay-per-use choice. When
  what serves each model is unknown, the allowed choices are returned as
  `allowed/2` gives them.
  """
  @spec offered(
          Organization.t(),
          {:ok, [option()]} | {:error, term()},
          {:ok, map()} | {:error, term()},
          (option() -> String.t())
        ) :: [option()]
  def offered(%Organization{allowed_models: [_ | _]} = org, catalog_result, served, paid_label) do
    {:ok, options} = allowed(org, catalog_result)
    catalog = with {:ok, catalog} <- catalog_result, do: catalog, else: (_error -> [])

    for option <- options, served?(option["choice"], served) do
      case option["choice"] do
        %{"allow_paid" => true} = choice ->
          plain = option(Map.put(choice, "allow_paid", false), catalog)
          %{option | "label" => paid_label.(plain), "vendor" => plain["vendor"]}

        _plain ->
          option
      end
    end
  end

  def offered(%Organization{}, {:ok, catalog}, {:ok, served}, paid_label) do
    names = MapSet.new(catalog, & &1["choice"]["model"])

    listed =
      for {id, model} <- served, not MapSet.member?(names, id) do
        choice = normalize(%{"kind" => "catalog", "model" => id})

        %{"key" => key(choice), "choice" => choice, "label" => model["label"] || id}
        |> Map.put("vendor", model["vendor"])
      end
      |> Enum.sort_by(& &1["label"])

    Enum.flat_map(catalog ++ listed, fn option ->
      model = served[option["choice"]["model"]] || %{}
      paid = Map.put(option["choice"], "allow_paid", true)

      if(model["served_by"] == "subscription", do: [option], else: []) ++
        if match?([_ | _], model["key_sources"]),
          do: [%{option | "choice" => paid, "key" => key(paid), "label" => paid_label.(option)}],
          else: []
    end)
  end

  def offered(%Organization{}, {:ok, catalog}, _unknown, _paid_label), do: catalog
  def offered(%Organization{}, {:error, _reason}, _served, _paid_label), do: []

  @doc """
  Whether an enabled account of the org serves `choice` now, by
  `servable/1`'s result: a subscription for a plain catalog choice, a
  Provider API key for a pay-per-use one. Other choices, and any choice when
  what serves each model is unknown, count as served.
  """
  @spec served?(term(), {:ok, map()} | {:error, term()}) :: boolean()
  def served?(%{"kind" => "catalog", "model" => id} = choice, {:ok, served}) do
    case {choice["allow_paid"], served[id]} do
      {true, %{"key_sources" => [_ | _]}} -> true
      {true, _model} -> false
      {_plain, %{"served_by" => "subscription"}} -> true
      {_plain, _model} -> false
    end
  end

  def served?(_choice, _servable), do: true

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
  effort allows only that effort. Without an allowed list, any catalog model
  at any effort, pay-per-use or not, and any model a custom endpoint of the
  org lists (`choose/3`); never a marked choice.
  """
  @spec allowed?(Organization.t(), choice(), {:ok, [option()]} | {:error, term()}) :: boolean()
  def allowed?(%Organization{allowed_models: allowed} = org, choice, catalog_result)
      when allowed in [nil, []] and is_map(choice) do
    case {choice, catalog_result} do
      {%{"kind" => "catalog"}, {:ok, _catalog}} ->
        bare = choice |> normalize() |> Map.delete("reasoning_effort")

        not platform?(choice) and
          (in_catalog?(bare, catalog_result) or
             match?({:ok, _}, choose(org, choice, catalog_result)))

      _other ->
        false
    end
  end

  def allowed?(%Organization{} = org, choice, catalog_result) do
    case allowed(org, catalog_result) do
      {:ok, options} -> Enum.any?(options, &allows?(&1["choice"], choice))
      {:error, _reason} -> false
    end
  end

  # A marked choice is never allowed: only the platform admin stores it.
  defp allows?(allowed, choice) do
    allowed = normalize(allowed)
    choice = normalize(choice)

    cond do
      platform?(allowed) or platform?(choice) -> false
      Map.has_key?(allowed, "reasoning_effort") -> allowed == choice
      true -> allowed == Map.delete(choice, "reasoning_effort")
    end
  end

  @doc """
  Whether `choice` carries the platform Router mark (`"platform" => true`,
  `SalixAgent.ModelChoice.platform?/1`).
  """
  @spec platform?(term()) :: boolean()
  def platform?(%{"kind" => "catalog", "platform" => true}), do: true
  def platform?(_choice), do: false

  @doc """
  The org tenant's platform Router as the org may see it:
  `%{"model" => id, "label" => name}`, or nil when it has none or Salix
  cannot say. It names no billing and no platform Profile.
  """
  @spec platform_router(Organization.t()) :: map() | nil
  def platform_router(%Organization{salix_tenant_id: tenant}) when is_binary(tenant) do
    case Client.call_optional(:platform_router, [tenant]) do
      {:ok, %{"model" => model} = router} when is_binary(model) ->
        %{"model" => model, "label" => text(router["label"]) || model}

      _none ->
        nil
    end
  end

  def platform_router(%Organization{}), do: nil

  @doc """
  Whether the platform provides `choice` now: it carries the mark and the
  org's platform Router (`platform_router/1`) names its model. A marked
  choice whose platform Router was removed is served by the org's
  subscriptions, and its API keys only when the choice allows pay-per-use.
  """
  @spec platform_provided?(term(), map() | nil) :: boolean()
  def platform_provided?(choice, %{"model" => model}),
    do: platform?(choice) and choice["model"] == model

  def platform_provided?(_choice, nil), do: false

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
  allowance. A marked choice (`platform?/1`) is never allowed.
  """
  @spec router_choice(String.t(), choice() | nil) :: {:ok, choice() | nil} | {:error, term()}
  def router_choice(project_id, choice) do
    case Repo.get(Project, project_id) |> Repo.preload(:org) do
      %Project{org: %Organization{} = org} ->
        if platform?(choice),
          do: {:error, :model_not_allowed},
          else: org_router_choice(org, default_effort(choice))

      _missing ->
        {:error, :target_not_found}
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
  `allow_paid` or an explicit Profile pin only a subscription can. The model keeps only the efforts
  those choices allow, `requires_allow_paid` says whether all of them are
  pay-per-use, and `choices` lists them, including explicit Profile pins.
  A `profile_id` option restricts pins to that Profile. The caller must
  restrict its servable-model read to that Profile.
  """
  @spec router_model_filter(String.t()) :: {:ok, ([map()] -> [map()])} | {:error, term()}
  def router_model_filter(project_id, opts \\ []) do
    pin = Keyword.get(opts, :profile_id)

    case Repo.get(Project, project_id) |> Repo.preload(:org) do
      %Project{org: %Organization{allowed_models: [_ | _] = allowed}} ->
        allowed = allowed |> Enum.map(&normalize/1) |> Enum.reject(&platform?/1)
        {:ok, fn models -> Enum.flat_map(models, &allowed_model(&1, allowed, pin)) end}

      %Project{org: %Organization{}} ->
        {:ok, &Function.identity/1}

      _missing ->
        {:error, :target_not_found}
    end
  end

  defp allowed_model(%{"id" => id} = model, allowed, pin) do
    efforts = List.wrap(model["efforts"])
    subscription? = model["served_by"] == "subscription"

    choices =
      Enum.filter(allowed, fn choice ->
        choice["kind"] == "catalog" and choice["model"] == id and
          (is_nil(pin) or choice["profile_id"] in [nil, pin]) and
          (choice["allow_paid"] == true or subscription? or is_binary(choice["profile_id"])) and
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

  defp allowed_model(_model, _allowed, _pin), do: []

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
  A plain catalog choice of a catalog model needs no Salix call; a marked
  choice is refused without one.
  """
  @spec choose(Organization.t(), term(), {:ok, [option()]} | {:error, term()}) ::
          {:ok, choice()} | {:error, term()}
  def choose(%Organization{salix_tenant_id: tenant_id}, choice, catalog_result)
      when is_map(choice) do
    choice = normalize(choice)

    cond do
      platform?(choice) -> {:error, :invalid_model_configuration}
      in_catalog?(choice, catalog_result) -> {:ok, choice}
      true -> Client.impl().choose_model(choice, tenant_id)
    end
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
  Compare choices in this form. The platform Router mark stays.
  """
  @spec normalize(choice()) :: choice()
  def normalize(%{"kind" => "catalog"} = choice), do: Map.put_new(choice, "allow_paid", false)
  def normalize(choice), do: choice

  @doc """
  The stable UI key of a choice: `catalog:<model>`, `runtime:<provider>:<model>`
  or `platform:<tier>`, then `@<effort>`, `+paid`, `+platform` (the platform
  Router mark) and `#<profile_id>` when set. A marked choice and the plain
  choice of the same model have different keys.
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
      if(choice["platform"] == true, do: "+platform", else: ""),
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
