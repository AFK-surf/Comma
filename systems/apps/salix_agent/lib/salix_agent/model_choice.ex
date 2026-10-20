defmodule SalixAgent.ModelChoice do
  @moduledoc """
  A model choice stored as a value.

  An Agent record (`model`) and an internal Session (its state field `model`)
  hold the same value. A Session's choice replaces its Agent's for that Session
  only. An Agent without a choice follows the platform model of its role
  (`SalixAgent.AgentModel`).

  Three kinds exist:

    * `catalog`: a catalog or Custom Profile model id, an optional reasoning
      effort, whether pay-per-use Profiles may serve it, and an optional pinned
      Profile. It names no endpoint or credential; each request picks a Profile
      (`SalixAgent.AccountPool`).
    * `runtime`: a model and effort that a Codex or Claude Code station runs
      with its own login (`SalixAgent.StationBinding`).
    * `platform`: the platform model of a tier (`SalixAgent.PlatformModels`),
      which members see only by name. The platform decides what serves it
      and pays for it.

  `record/2` answers the model record a choice stands for: its name, model id,
  provider, `provider_config`, limits and image input. That record is never
  stored. `llm_config/1`, `media/2` and `public_json/1` read it.
  """

  alias SalixAgent.LLMProvider

  @catalog_keys ~w(kind model reasoning_effort allow_paid profile_id)
  @runtime_keys ~w(kind provider model reasoning_effort)
  @runtime_providers ~w(codex claude)

  @doc """
  Check a requested choice against the tenant and answer the value to store.

  A catalog request is `%{"kind" => "catalog", "model" => id}` with optional
  `reasoning_effort`, `allow_paid` and `profile_id`, as `agent.create_worker`
  takes it. A runtime request is `%{"kind" => "runtime", "provider" => "codex"
  | "claude", "model" => id}` with an optional `reasoning_effort`. A platform
  request is `%{"kind" => "platform", "tier" => tier}` for an Agent tier.
  """
  @spec choose(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def choose(%{"kind" => "catalog", "model" => model_id} = choice, tenant_id)
      when is_binary(model_id) do
    effort = choice["reasoning_effort"]
    profile_id = choice["profile_id"]

    with true <- Enum.all?(Map.keys(choice), &(&1 in @catalog_keys)),
         true <- model_id != "" and byte_size(model_id) <= 256,
         true <- optional_text?(effort),
         true <- optional_text?(profile_id),
         true <- Map.get(choice, "allow_paid", false) in [true, false],
         {:ok, _model, allow_paid} <-
           check_catalog(model_id, effort, choice["allow_paid"] == true, tenant_id, profile_id) do
      {:ok,
       compact(%{
         "kind" => "catalog",
         "model" => model_id,
         "reasoning_effort" => effort,
         "allow_paid" => allow_paid,
         "profile_id" => profile_id
       })}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_model_configuration}
    end
  end

  def choose(
        %{"kind" => "runtime", "provider" => provider, "model" => model_id} = choice,
        tenant_id
      )
      when provider in @runtime_providers and is_binary(model_id) do
    effort = choice["reasoning_effort"]

    with true <- Enum.all?(Map.keys(choice), &(&1 in @runtime_keys)),
         true <- optional_text?(effort),
         {:ok, _record} <- runtime_record(provider, model_id, effort, tenant_id) do
      {:ok,
       compact(%{
         "kind" => "runtime",
         "provider" => provider,
         "model" => model_id,
         "reasoning_effort" => effort
       })}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_model_configuration}
    end
  end

  def choose(%{"kind" => "platform", "tier" => tier} = choice, _tenant_id)
      when map_size(choice) == 2 do
    if tier in SalixAgent.PlatformModels.agent_tiers(),
      do: {:ok, %{"kind" => "platform", "tier" => tier}},
      else: {:error, :invalid_model_configuration}
  end

  def choose(_choice, _tenant_id), do: {:error, :invalid_model_configuration}

  @doc "Whether `value` has the shape of a stored choice."
  @spec value?(term()) :: boolean()
  def value?(%{"kind" => "catalog", "model" => model}) when is_binary(model), do: true

  def value?(%{"kind" => "runtime", "provider" => provider, "model" => model})
      when provider in @runtime_providers and is_binary(model),
      do: true

  def value?(%{"kind" => "platform", "tier" => tier}) when is_binary(tier), do: true

  def value?(_value), do: false

  @doc "The model record a stored choice stands for, owned by `tenant_id`."
  @spec record(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def record(%{"kind" => "catalog", "model" => model_id} = value, tenant_id) do
    effort = value["reasoning_effort"]

    with :ok <- validate_tenant(tenant_id),
         {:ok, model} <- catalog_or_custom(model_id, tenant_id) do
      {:ok,
       %{
         "name" => Enum.join([model["name"], effort || "default"], " · "),
         "model" => model_id,
         "model_display_name" => model["name"],
         "model_vendor" => model["vendor"],
         "provider" => model["vendor"],
         "provider_config" => %{
           "catalog_model" => model_id,
           "allow_paid" => value["allow_paid"] == true,
           "profile_id" => value["profile_id"],
           "reasoning_effort" => effort
         },
         "max_tokens" => min(model["max_tokens"] || 32_000, 128_000),
         "context_tokens" => model["context_tokens"] || 0,
         "supports_images" => model["images"] == true,
         "tenant_id" => tenant_id
       }}
    end
  end

  def record(%{"kind" => "runtime"} = value, tenant_id),
    do: runtime_record(value["provider"], value["model"], value["reasoning_effort"], tenant_id)

  def record(%{"kind" => "platform", "tier" => tier}, _tenant_id),
    do: SalixAgent.PlatformModels.record(tier)

  def record(_value, _tenant_id), do: {:error, :invalid_model_configuration}

  @doc "The LLM options of a stored choice, in the form `SalixAgent.LlmResolver` answers."
  @spec resolve_llm(map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def resolve_llm(value, tenant_id) do
    with {:ok, record} <- record(value, tenant_id),
         {:ok, llm} <- llm_config(record) do
      {:ok, llm || []}
    else
      {:error, reason} -> {:error, {:model_choice, reason}}
    end
  end

  @doc """
  The LLM options a model record resolves to: its `provider_config` with the
  model, limits and provider, and the credentials of the Profile that serves
  it (`SalixAgent.AccountPool.resolve_config/2`).
  """
  @spec llm_config(map()) :: {:ok, map() | list()} | {:error, term()}
  def llm_config(record) when is_map(record) do
    model = LLMProvider.canonical_model(record["model"])
    provider = provider(record)

    config =
      (record["provider_config"] || %{})
      |> default_openai_protocol(provider, model)

    headers = config["default_headers"] || %{}

    llm =
      config
      |> Map.put("model", model)
      |> Map.put("max_tokens", record["max_tokens"])
      |> Map.put("provider", provider)
      |> Map.put("supports_images", record["supports_images"] == true)

    llm = if headers == %{}, do: llm, else: Map.put(llm, "default_headers", headers)

    llm =
      case record["context_tokens"] do
        n when is_integer(n) and n > 0 -> Map.put(llm, "context_tokens", n)
        _ -> llm
      end

    SalixAgent.AccountPool.resolve_config(credential_scope(llm, record), record["tenant_id"])
  end

  @doc """
  The media settings of a stored choice: the platform's media settings
  (`SalixAgent.MediaSettings`), with image input following the chosen model.
  A catalog choice that the Tenant's own Codex subscription serves generates
  images with `gpt-image-2` through that subscription pool instead
  (`SalixAgent.AccountPool.codex_serves?/2`).
  """
  @spec media(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def media(value, tenant_id) do
    with {:ok, record} <- record(value, tenant_id),
         {:ok, settings} <- SalixAgent.MediaSettings.get() do
      image_config =
        if SalixAgent.AccountPool.codex_serves?(tenant_id, value),
          do: codex_image_config(tenant_id),
          else: settings["image_config"] || %{}

      {:ok,
       %{
         "image_config" => image_config,
         "video_config" => settings["video_config"] || %{},
         "supports_images" => record["supports_images"] == true,
         "vision_describer_config" => settings["vision_describer_config"] || %{},
         "analyze_config" => credential_scope(settings["analyze_config"] || %{}, %{})
       }}
    end
  end

  # The Tenant's Codex subscription pool owns this route: the pool tenant
  # comes from the Agent's Tenant, never from user-supplied fields.
  defp codex_image_config(tenant_id) do
    %{
      "provider" => "openai",
      "model" => "gpt-image-2",
      "provider_config" => %{"account_pool" => "codex"},
      "credential_scope" => "tenant",
      "account_pool_tenant" => tenant_id
    }
  end

  @doc "The credential-free view (`public_json/1`) of a stored choice."
  @spec public(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def public(value, tenant_id) do
    with {:ok, record} <- record(value, tenant_id), do: {:ok, public_json(record)}
  end

  @doc """
  The credential-free view of a model record. Members see the platform model
  only by its name: not the model that serves it, its provider or its limits.
  """
  @spec public_json(map()) :: map()
  def public_json(%{"platform_tier" => tier} = record) do
    %{
      "scope" => "platform",
      "name" => record["name"],
      "model" => record["name"],
      "provider" => "comma",
      "platform_tier" => tier,
      "model_display_name" => record["name"],
      "model_vendor" => "comma",
      "model_icon" => "comma"
    }
  end

  def public_json(record) do
    config = record["provider_config"] || %{}

    %{
      "scope" => if(record["tenant_id"], do: "tenant", else: "global"),
      "name" => record["name"],
      "model" => record["model"],
      "provider" => provider(record),
      "max_tokens" => record["max_tokens"] || 65_536,
      "context_tokens" => record["context_tokens"] || 0,
      "reasoning_effort" => config["reasoning_effort"]
    }
    |> Map.merge(SalixAgent.ModelPresentation.public(record))
    |> Map.merge(catalog_view(config))
    |> Map.merge(runtime_view(config))
  end

  defp catalog_view(%{"catalog_model" => model} = config),
    do: %{
      "catalog_model" => model,
      "allow_paid" => config["allow_paid"] == true,
      "profile_id" => config["profile_id"]
    }

  defp catalog_view(_config), do: %{}

  defp runtime_view(%{"runtime_model" => model, "runtime_provider" => provider}),
    do: %{"runtime_model" => model, "runtime_provider" => provider}

  defp runtime_view(_config), do: %{}

  # Check a catalog choice against the tenant: the model is in the catalog or
  # a Custom Profile, the effort is one of its efforts, and a pinned Profile
  # serves it. Answers the model and the effective `allow_paid`.
  defp check_catalog(model_id, effort, allow_paid, tenant_id, profile_id) do
    with :ok <- validate_tenant(tenant_id),
         {:ok, model} <- catalog_or_custom(model_id, tenant_id),
         true <- is_nil(effort) or effort in model["efforts"],
         true <-
           is_nil(profile_id) or
             SalixAgent.AccountPool.profile_serves?(tenant_id, profile_id, model_id) do
      # Pinning an API key is choosing to pay for it: such a choice is stored
      # and reported with allow_paid true, whatever the request said.
      allow_paid =
        allow_paid or
          (is_binary(profile_id) and SalixAgent.AccountPool.key_profile?(tenant_id, profile_id))

      {:ok, model, allow_paid}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_model_configuration}
    end
  end

  defp catalog_or_custom(model_id, tenant_id) do
    case SalixAgent.Models.get(model_id) do
      {:ok, model} -> {:ok, model}
      _ -> SalixAgent.AccountPool.custom_model(tenant_id, model_id)
    end
  end

  defp runtime_record(runtime_provider, model_id, effort, tenant_id)
       when runtime_provider in @runtime_providers and is_binary(model_id) do
    with :ok <- validate_tenant(tenant_id),
         {:ok, model} <- SalixAgent.Models.get(model_id),
         {:ok, request_model} <- runtime_request_model(runtime_provider, model),
         true <- is_nil(effort) or effort in (model["efforts"] || []) do
      {:ok,
       %{
         "name" => Enum.join([model["name"], effort || "default"], " · "),
         "model" => request_model,
         "model_display_name" => model["name"],
         "model_vendor" => model["vendor"],
         "provider" => model["vendor"],
         "provider_config" => %{
           "runtime_provider" => runtime_provider,
           "runtime_model" => model_id,
           "reasoning_effort" => effort
         },
         "max_tokens" => min(model["max_tokens"] || 32_000, 128_000),
         "context_tokens" => model["context_tokens"] || 0,
         "supports_images" => model["images"] == true,
         "tenant_id" => tenant_id
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_model_configuration}
    end
  end

  defp runtime_record(_provider, _model_id, _effort, _tenant_id),
    do: {:error, :invalid_model_configuration}

  # Codex and Claude Code run only models their own subscription serves; send
  # the id that source uses.
  defp runtime_request_model(source, model) do
    case model["routes"] do
      %{^source => %{"model" => request}} when is_binary(request) -> {:ok, request}
      _ -> :error
    end
  end

  defp validate_tenant(tenant_id) do
    if SalixStore.Ids.valid_tenant_id?(tenant_id),
      do: :ok,
      else: {:error, {:bad_request, "valid tenant_id is required"}}
  end

  defp provider(record) do
    config = record["provider_config"] || %{}

    LLMProvider.normalize_provider(record["provider"]) ||
      LLMProvider.provider(Map.merge(config, %{"model" => record["model"]})) ||
      ""
  end

  defp credential_scope(config, _record) when map_size(config) == 0, do: config

  defp credential_scope(config, record),
    do:
      Map.put(config, "credential_scope", if(record["tenant_id"], do: "tenant", else: "platform"))

  # GPT-5.6 supports Chat Completions, but OpenAI recommends Responses for
  # reasoning, tool-calling, and multi-turn workflows. Default only when the
  # record did not choose a protocol.
  defp default_openai_protocol(config, "openai", model)
       when model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
       do: Map.put_new(config, "protocol", "responses")

  defp default_openai_protocol(config, _provider, _model), do: config

  defp optional_text?(nil), do: true
  defp optional_text?(value), do: is_binary(value) and value != ""

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
