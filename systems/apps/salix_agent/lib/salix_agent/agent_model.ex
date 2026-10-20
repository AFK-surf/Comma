defmodule SalixAgent.AgentModel do
  @moduledoc """
  The model an Agent runs.

  An Agent with a model choice (`model`, `SalixAgent.ModelChoice`) runs it.
  An Agent without one follows the platform model of its role
  (`SalixAgent.PlatformModels`): a Router the `router` tier, a Worker the
  `worker` tier, and a meeting Agent the `summary` tier. A role whose tier is
  not configured has no model, and such an Agent cannot run until the
  platform configures it.

  This is the only place that turns an Agent record into a model. Callers do
  not read `model` and resolve it themselves, because a following Agent has
  no choice.
  """

  alias SalixAgent.{Control, ModelChoice, PlatformModels}

  @typedoc "`:pinned` for the Agent's own choice, `:platform_default` when it follows its role."
  @type source :: :pinned | :platform_default

  @role_tiers %{"router" => "router", "worker" => "worker", "meeting" => "summary"}

  @doc "The model choice of an Agent record and where it came from."
  @spec choice(map()) :: {:ok, map(), source()} | {:error, term()}
  def choice(rec) when is_map(rec) do
    if ModelChoice.value?(rec["model"]),
      do: {:ok, rec["model"], :pinned},
      else: platform_default(rec["role"])
  end

  @doc """
  The platform model a role follows, or `{:error, :platform_model_unconfigured}`
  while its tier is not configured.
  """
  @spec platform_default(term()) :: {:ok, map(), :platform_default} | {:error, term()}
  def platform_default(role) do
    case @role_tiers[role] do
      nil ->
        {:error, :agent_model_unresolved}

      tier ->
        if PlatformModels.configured?(tier),
          do: {:ok, %{"kind" => "platform", "tier" => tier}, :platform_default},
          else: {:error, :platform_model_unconfigured}
    end
  end

  @doc "The model record of an Agent record (`SalixAgent.ModelChoice.record/2`) and its source."
  @spec resolve(map()) :: {:ok, map(), source()} | {:error, term()}
  def resolve(rec) when is_map(rec) do
    with {:ok, choice, source} <- choice(rec),
         {:ok, record} <- ModelChoice.record(choice, rec["tenant_id"]) do
      {:ok, record, source}
    end
  end

  @doc "The credential-free view of an Agent record's model and its source."
  @spec resolve_public(map()) :: {:ok, map(), source()} | {:error, term()}
  def resolve_public(rec) do
    with {:ok, record, source} <- resolve(rec),
         do: {:ok, ModelChoice.public_json(record), source}
  end

  @doc "The model record of an Agent record, or `%{}` when it does not resolve."
  @spec snapshot(map()) :: map()
  def snapshot(rec) do
    case resolve(rec) do
      {:ok, record, _source} -> record
      _ -> %{}
    end
  end

  @doc "The live LLM options of an Agent record."
  @spec resolve_llm(map()) :: {:ok, term()} | {:error, term()}
  def resolve_llm(rec) when is_map(rec) do
    with {:ok, choice, _source} <- choice(rec),
         do: ModelChoice.resolve_llm(choice, rec["tenant_id"])
  end

  @doc """
  The live LLM options of an Agent. Choice and platform model edits apply on
  the next activation. A missing Agent record answers `{:ok, nil}`.
  """
  @spec resolve_llm_for_agent(String.t()) :: {:ok, term()} | {:error, term()}
  def resolve_llm_for_agent(agent_id) do
    case Control.get_record(agent_id) do
      {:ok, rec} -> resolve_llm(rec)
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The media settings of an Agent (`SalixAgent.ModelChoice.media/2`); `{:ok, nil}` without a record."
  @spec resolve_media_for_agent(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def resolve_media_for_agent(agent_id) do
    with {:ok, rec} <- Control.get_record(agent_id),
         {:ok, choice, _source} <- choice(rec) do
      ModelChoice.media(choice, rec["tenant_id"])
    else
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc "A label for following the platform model of `role`, naming that model."
  @spec default_label(term()) :: String.t()
  def default_label(role) do
    case platform_public(role) do
      {:ok, public} ->
        "Default (#{public["model_display_name"] || SalixAgent.ModelPresentation.name(public)})"

      _ ->
        "Default (unavailable)"
    end
  end

  @doc "The icon of the platform model `role` follows, or nil."
  @spec default_icon(term()) :: String.t() | nil
  def default_icon(role) do
    case platform_public(role) do
      {:ok, public} -> public["model_icon"]
      _ -> nil
    end
  end

  @doc "The credential-free view of the platform model `role` follows."
  @spec platform_public(term()) :: {:ok, map()} | {:error, term()}
  def platform_public(role) do
    with {:ok, choice, _source} <- platform_default(role),
         {:ok, record} <- ModelChoice.record(choice, nil),
         do: {:ok, ModelChoice.public_json(record)}
  end
end
