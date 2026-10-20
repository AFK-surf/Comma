defmodule SalixAgent.PlatformModels do
  @moduledoc """
  The platform model: the one model members can choose besides their own
  Profiles' (Comma shows it as "Comma"). Members see only its name. The
  platform decides what serves it, per tier, and pays for it; its calls are
  metered against the member's credits.

  A tier names one internal model: a platform Profile
  (`SalixAgent.AccountPool.platform_tenant/0`), the model id that Profile is
  asked for, the protocol when the Profile speaks several, a reasoning effort,
  and the limits and inputs the runtime needs (`context_tokens`,
  `max_tokens`, `images`). The Agent tiers are `router` and `worker`; an
  Agent that follows the platform default takes its role's tier, and a Task
  can choose `worker`. The platform's own work has tiers of its own: `summary`
  (meeting summaries) and `transcription` (meeting audio).

  Storage: `ctl/system/platform_models.json`, one platform record, written
  with a conditional put.
  """

  alias SalixAgent.AccountPool
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixStore.{Keys, S3}

  @agent_tiers ~w(router worker)
  @tiers @agent_tiers ++ ~w(summary transcription)
  @entry_fields ~w(profile_id model protocol reasoning_effort context_tokens max_tokens images)
  @default_name "Comma"

  def tiers, do: @tiers

  @doc "The tiers an Agent or a Task can run."
  def agent_tiers, do: @agent_tiers

  @doc "The LLM options of a tier, or `{:error, :platform_model_unconfigured}`."
  @spec llm(String.t()) :: {:ok, map()} | {:error, term()}
  def llm(tier) when tier in @tiers do
    if configured?(tier) do
      with {:ok, record} <- record(tier),
           {:ok, llm} when is_map(llm) or is_list(llm) <-
             SalixAgent.ModelChoice.llm_config(record),
           do: {:ok, Map.new(llm, fn {key, value} -> {to_string(key), value} end)}
    else
      {:error, :platform_model_unconfigured}
    end
  end

  @doc "The settings: `%{\"name\" => ..., \"tiers\" => %{tier => entry}}`."
  @spec get() :: {:ok, map()} | {:error, term()}
  def get do
    SalixStore.ReadScope.fetch({:platform_models}, fn ->
      case read() do
        {:ok, settings, _etag} -> {:ok, settings}
        error -> error
      end
    end)
  end

  @doc "The members' name for the platform model."
  def name do
    case get() do
      {:ok, %{"name" => name}} when is_binary(name) and name != "" -> name
      _ -> @default_name
    end
  end

  @doc "Whether a tier names an internal model."
  def configured?(tier) do
    match?({:ok, %{"tiers" => %{^tier => %{}}}}, get())
  end

  @doc """
  Replace the settings. Each tier is an entry or `nil` to clear it; an entry
  needs a platform Profile and a model id.
  """
  @spec put(map()) :: {:ok, map()} | {:error, term()}
  def put(%{} = settings) do
    with {:ok, tiers} <- validate_tiers(settings["tiers"] || %{}),
         {:ok, _current, etag} <- read() do
      next =
        %{"tiers" => tiers}
        |> then(fn s ->
          case settings["name"] do
            name when is_binary(name) and name != "" and byte_size(name) <= 100 ->
              Map.put(s, "name", name)

            _ ->
              s
          end
        end)

      body = Jason.encode!(next)

      result =
        if etag,
          do: S3.put(Keys.ctl_system_platform_models(), body, if_match: etag),
          else: S3.put(Keys.ctl_system_platform_models(), body, if_none_match: "*")

      case result do
        {:ok, _} -> {:ok, next}
        {:error, :precondition_failed} -> {:error, :conflict}
        {:error, _} = error -> error
      end
    end
  end

  def put(_settings), do: {:error, :invalid_platform_models}

  @doc """
  The model record a tier stands for, as `SalixAgent.ModelChoice.record/2`
  answers one: the internal model at its platform Profile's endpoint, with
  that Profile's key. It has no `tenant_id`, so its calls are platform-funded.
  Members never receive it; `SalixAgent.ModelChoice.public_json/1` shows only
  the platform model's name.
  """
  @spec record(String.t()) :: {:ok, map()} | {:error, term()}
  def record(tier) when tier in @tiers do
    platform = AccountPool.platform_tenant()

    with {:ok, %{"tiers" => %{^tier => entry}} = settings} <- get(),
         {:ok, record} <- Store.get(platform, entry["profile_id"]),
         false <- record["disabled"] == true,
         {:ok, protocol, endpoint} <- endpoint(record, entry["protocol"]),
         {:ok, credentials} <- Store.open(platform, record["id"], record["credentials"]) do
      name = settings["name"] || @default_name

      {:ok,
       %{
         "name" => name,
         "model" => entry["model"],
         "platform_tier" => tier,
         "provider" => if(record["source"] != "custom", do: record["source"]),
         "provider_config" =>
           %{
             "base_url" => endpoint,
             "protocol" => protocol,
             "reasoning_effort" => entry["reasoning_effort"]
           }
           |> Map.merge(auth(record, protocol, credentials["api_key"]))
           |> put_headers(SalixAgent.ProviderAdapters.headers(record["source"]))
           |> Map.reject(fn {_key, value} -> is_nil(value) end),
         "max_tokens" => entry["max_tokens"] || 32_000,
         "context_tokens" => entry["context_tokens"] || 0,
         "supports_images" => entry["images"] == true
       }}
    else
      {:ok, _settings} -> {:error, :platform_model_unconfigured}
      true -> {:error, :platform_model_unavailable}
      {:error, :not_found} -> {:error, :platform_model_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :platform_model_unavailable}
    end
  end

  def record(_tier), do: {:error, :invalid_model_configuration}

  defp put_headers(config, headers) when headers == %{}, do: config
  defp put_headers(config, headers), do: Map.put(config, "default_headers", headers)

  defp endpoint(%{"endpoints" => endpoints}, protocol) when is_map(endpoints) do
    protocol = protocol || endpoints |> Map.keys() |> Enum.sort() |> List.first()

    case endpoints[protocol] do
      url when is_binary(url) and url != "" -> {:ok, protocol, url}
      _ -> {:error, :platform_model_unavailable}
    end
  end

  defp endpoint(_record, _protocol), do: {:error, :platform_model_unavailable}

  # As a member's own key: Anthropic with a bearer scheme takes a token.
  defp auth(record, "anthropic", key) when is_binary(key) and key != "" do
    if record["auth"] == "bearer", do: %{"auth_token" => key}, else: %{"api_key" => key}
  end

  defp auth(_record, _protocol, key) when is_binary(key) and key != "", do: %{"api_key" => key}
  defp auth(_record, _protocol, _key), do: %{}

  defp validate_tiers(tiers) when is_map(tiers) do
    Enum.reduce_while(tiers, {:ok, %{}}, fn
      {tier, nil}, {:ok, acc} when tier in @tiers ->
        {:cont, {:ok, acc}}

      {tier, %{} = entry}, {:ok, acc} when tier in @tiers ->
        case validate_entry(entry) do
          {:ok, entry} -> {:cont, {:ok, Map.put(acc, tier, entry)}}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :invalid_platform_models}}
    end)
  end

  defp validate_tiers(_), do: {:error, :invalid_platform_models}

  defp validate_entry(entry) do
    entry = Map.take(entry, @entry_fields)

    valid =
      text?(entry["profile_id"]) and text?(entry["model"]) and
        optional(entry["protocol"], &(&1 in ~w(responses chat_completions anthropic))) and
        optional(entry["reasoning_effort"], &text?/1) and
        optional(entry["context_tokens"], &positive?/1) and
        optional(entry["max_tokens"], &positive?/1) and
        optional(entry["images"], &is_boolean/1)

    if valid,
      do: {:ok, Map.reject(entry, fn {_key, value} -> is_nil(value) end)},
      else: {:error, :invalid_platform_models}
  end

  defp text?(value), do: is_binary(value) and value != "" and byte_size(value) <= 200
  defp positive?(value), do: is_integer(value) and value > 0 and value <= 10_000_000
  defp optional(nil, _check), do: true
  defp optional(value, check), do: check.(value)

  defp read do
    case S3.get(Keys.ctl_system_platform_models()) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, Map.take(map, ~w(name tiers)), etag}
          _ -> {:error, :invalid_platform_models}
        end

      {:error, :not_found} ->
        {:ok, %{}, nil}

      {:error, _} = error ->
        error
    end
  end
end
