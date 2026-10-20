defmodule SalixAgent.Migrations.PlatformModels do
  @moduledoc """
  Move the platform's models off global templates (decided by 左子健,
  2026-10-08): members choose a model their own Profiles serve or the one
  platform model (`SalixAgent.PlatformModels`).

  Run during a rolling release; the release migration ledger owns
  completion. One pass:

    1. For each tier (`router`, `worker`) that is not configured yet, the
       role's platform default template becomes a platform Profile and the
       tier's internal model. The Profile is an API-key Profile under the
       platform Tenant at the template's endpoint with its key: the LMHub
       source for an LMHub endpoint, else Custom. A Profile already there for
       the same endpoint and key is reused.
    2. When no media settings are stored, the Router default template's media
       configurations become them (`SalixAgent.MediaSettings`).
    3. Each Router or Worker that pins a global template and holds no model
       choice gets the platform model of its role as its choice. Its
       `template_id` stays, so processes of the previous release resolve the
       same template until they are replaced. Conditional writes preserve
       concurrent edits; each page reads at most 100 Agent records.

  A template that cannot become a platform Profile (no endpoint, an unset key
  environment variable) leaves its tier unconfigured: that role keeps the
  template pointer, and the pass reports it. No template, Agent, Session or
  credential is deleted. Retry failed passes through the release runner.
  """

  require Logger

  alias SalixAgent.{AccountPool, MediaSettings, ModelChoice, PlatformModels}
  alias SalixAgent.Migrations.TemplateRecords
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixStore.{Ids, Keys, S3}

  def run do
    with {:ok, tiers} <- convert_tiers(),
         {:ok, _named} <- convert_named_tiers(),
         :ok <- copy_media(),
         {:ok, agents} <- page(nil, 0) do
      {:ok, %{tiers: tiers, agents: agents}}
    end
  end

  defp convert_tiers do
    with {:ok, settings} <- PlatformModels.get() do
      configured = settings["tiers"] || %{}

      Enum.reduce_while(PlatformModels.agent_tiers(), {:ok, configured}, fn tier, {:ok, tiers} ->
        if Map.has_key?(tiers, tier) do
          {:cont, {:ok, tiers}}
        else
          case tier_from_template(tier) do
            {:ok, entry} ->
              {:cont, {:ok, Map.put(tiers, tier, entry)}}

            {:skip, reason} ->
              Logger.warning(
                "platform model tier #{tier} left on its template: #{inspect(reason)}"
              )

              {:cont, {:ok, tiers}}

            {:error, _} = error ->
              {:halt, error}
          end
        end
      end)
      |> case do
        {:ok, ^configured} ->
          {:ok, Map.keys(configured)}

        {:ok, tiers} ->
          with {:ok, _} <- PlatformModels.put(Map.put(settings, "tiers", tiers)),
               do: {:ok, Map.keys(tiers)}

        error ->
          error
      end
    end
  end

  # The meeting summary and transcription templates a deployment named
  # (`meetings.summary_template`, `meetings.asr_template`) become the
  # `summary` and `transcription` tiers.
  @named_tiers [
    {"summary", :meeting_summary_template},
    {"transcription", :meeting_asr_template}
  ]

  defp convert_named_tiers do
    with {:ok, settings} <- PlatformModels.get() do
      configured = settings["tiers"] || %{}

      tiers =
        Enum.reduce(@named_tiers, configured, fn {tier, key}, tiers ->
          with false <- Map.has_key?(tiers, tier),
               ref when is_binary(ref) and ref != "" <- SystemsRuntime.get_env(:salix_web, key),
               {:ok, template} <- named_template(String.trim(ref)),
               {:ok, entry} <- entry_from_template(template) do
            Map.put(tiers, tier, entry)
          else
            {:skip, reason} ->
              Logger.warning(
                "platform model tier #{tier} not set from its template: #{inspect(reason)}"
              )

              tiers

            _ ->
              tiers
          end
        end)

      if tiers == configured,
        do: {:ok, Map.keys(configured)},
        else:
          with(
            {:ok, _} <- PlatformModels.put(Map.put(settings, "tiers", tiers)),
            do: {:ok, Map.keys(tiers)}
          )
    end
  end

  defp named_template(ref) do
    case TemplateRecords.get(ref) do
      {:ok, template} ->
        {:ok, template}

      {:error, :not_found} ->
        case TemplateRecords.named(ref) do
          {:ok, %{} = template} -> {:ok, template}
          {:ok, nil} -> {:skip, {:template_not_found, ref}}
          error -> error
        end

      error ->
        error
    end
  end

  @doc """
  Configure each tier that is not configured yet from `template`, a template
  record that is not stored (a deployment's `llm.default_template`): the way
  a local or self-hosted installation names its one model. Configured tiers
  are kept. The tiers configured afterwards.
  """
  def seed(template) when is_map(template) do
    with {:ok, settings} <- PlatformModels.get() do
      configured = settings["tiers"] || %{}
      missing = PlatformModels.agent_tiers() -- Map.keys(configured)

      if missing == [] do
        {:ok, Map.keys(configured)}
      else
        with {:ok, entry} <- entry_from_template(template),
             tiers = Map.merge(Map.new(missing, &{&1, entry}), configured),
             {:ok, _} <- PlatformModels.put(Map.put(settings, "tiers", tiers)) do
          {:ok, Map.keys(tiers)}
        else
          {:skip, reason} -> {:error, {:platform_model_not_seeded, reason}}
          error -> error
        end
      end
    end
  end

  defp tier_from_template(role) do
    with {:ok, template} <- default_template(role), do: entry_from_template(template)
  end

  defp entry_from_template(template) do
    with {:ok, llm} <- template_llm(template),
         {:ok, profile} <- platform_profile(llm) do
      {:ok,
       compact(%{
         "profile_id" => profile["id"],
         "model" => llm["model"],
         "protocol" => llm["protocol"],
         "reasoning_effort" => get_in(template, ["provider_config", "reasoning_effort"]),
         "context_tokens" => positive(template["context_tokens"]),
         "max_tokens" => positive(template["max_tokens"]),
         "images" => template["supports_images"] == true
       })}
    end
  end

  # The template the role followed before: the platform pointer, else the
  # built-in fallback.
  defp default_template(role) do
    with {:ok, id} <- TemplateRecords.platform_default(role) do
      id = id || "default"

      case TemplateRecords.get(id) do
        {:ok, template} -> {:ok, template}
        {:error, :not_found} -> {:skip, {:template_not_found, id}}
        error -> error
      end
    end
  end

  defp template_llm(template) do
    case ModelChoice.llm_config(template) do
      {:ok, llm} when is_list(llm) or is_map(llm) ->
        llm = Map.new(llm, fn {key, value} -> {to_string(key), value} end)
        # An unset protocol is Chat Completions, as `SalixLlm.ProviderConfig` sends it.
        llm =
          if llm["protocol"] in [nil, ""],
            do: Map.put(llm, "protocol", "chat_completions"),
            else: llm

        key = llm["api_key"] || llm["auth_token"] || env_key(llm)

        cond do
          not is_binary(llm["base_url"]) or not String.starts_with?(llm["base_url"], "http") ->
            {:skip, :no_endpoint}

          llm["protocol"] not in ~w(responses chat_completions anthropic) ->
            {:skip, {:unknown_protocol, llm["protocol"]}}

          not is_binary(key) or key == "" ->
            {:skip, :no_key}

          true ->
            {:ok, Map.put(llm, "key", key)}
        end

      {:ok, _} ->
        {:skip, :no_llm_config}

      error ->
        error
    end
  end

  defp env_key(llm) do
    case llm["api_key_env"] || llm["auth_token_env"] do
      name when is_binary(name) and name != "" -> System.get_env(name)
      _ -> nil
    end
  end

  # An existing platform Profile at the same endpoint with the same key, or a
  # new one.
  defp platform_profile(llm) do
    platform = AccountPool.platform_tenant()
    source = if lmhub?(llm["base_url"]), do: "lmhub", else: "custom"

    with {:ok, existing} <- existing_profile(platform, source, llm) do
      if existing do
        {:ok, existing}
      else
        attrs =
          %{
            "credential_kind" => "provider_api_key",
            "source" => source,
            "name" => URI.parse(llm["base_url"]).host,
            "api_key" => llm["key"],
            "base_url" => llm["base_url"],
            "protocol" => llm["protocol"]
          }
          |> then(fn attrs ->
            if source == "custom", do: Map.put(attrs, "models", [llm["model"]]), else: attrs
          end)

        case AccountPool.create(platform, attrs) do
          {:ok, profile} -> {:ok, profile}
          {:error, :invalid_input} -> {:skip, :endpoint_not_accepted}
          error -> error
        end
      end
    end
  end

  defp existing_profile(platform, source, llm) do
    endpoint = SalixAgent.ModelDiscovery.normalize_url(llm["base_url"], llm["protocol"])

    with {:ok, %{"accounts" => accounts}} <- AccountPool.list(platform) do
      Enum.find_value(accounts, {:ok, nil}, fn account ->
        with %{"source" => ^source} <- account,
             %{"endpoint" => ^endpoint} <- account["connection"],
             {:ok, record} <- Store.get(platform, account["id"]),
             {:ok, %{"api_key" => key}} <-
               Store.open(platform, record["id"], record["credentials"]),
             true <- key == llm["key"] do
          {:ok, add_model(platform, account, source, llm["model"])}
        else
          _ -> nil
        end
      end)
    end
  end

  # A reused Custom Profile lists the tier's model as well.
  defp add_model(_platform, account, "lmhub", _model), do: account

  defp add_model(platform, account, "custom", model) do
    models = account["models"] || []

    if model in models do
      account
    else
      case Store.update_locked(platform, account["id"], account["version"], fn record ->
             Store.update(
               platform,
               Map.put(record, "models", models ++ [model]),
               record["version"]
             )
           end) do
        {:ok, _} -> account
        _ -> account
      end
    end
  end

  defp lmhub?(url), do: String.contains?(URI.parse(url).host || "", "lmhub")

  defp copy_media do
    with {:ok, settings} <- MediaSettings.get() do
      if settings == %{} do
        case default_template("router") do
          {:ok, template} ->
            media =
              template
              |> Map.take(MediaSettings.purposes())
              |> Map.reject(fn {_purpose, config} -> config in [nil, %{}] end)

            if media == %{} do
              :ok
            else
              case MediaSettings.put(media) do
                {:ok, _} -> :ok
                {:error, :conflict} -> :ok
                error -> error
              end
            end

          {:skip, _} ->
            :ok

          error ->
            error
        end
      else
        :ok
      end
    end
  end

  defp page(cursor, count) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix(), max_keys: 100, continuation_token: cursor),
         {:ok, count} <-
           Enum.reduce_while(objects, {:ok, count}, fn object, {:ok, count} ->
             case migrate_object(object.key) do
               {:ok, changed} -> {:cont, {:ok, count + if(changed, do: 1, else: 0)}}
               error -> {:halt, error}
             end
           end) do
      if next, do: page(next, count), else: {:ok, count}
    end
  end

  defp migrate_object(key) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, agent} <- Jason.decode(body),
         {:ok, tier} when is_binary(tier) <- tier_for(agent),
         {:ok, _} <-
           S3.put(
             key,
             Jason.encode!(Map.put(agent, "model", %{"kind" => "platform", "tier" => tier})),
             if_match: etag
           ) do
      {:ok, true}
    else
      {:ok, nil} -> {:ok, false}
      {:error, :precondition_failed} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      error -> error
    end
  end

  # A Router or Worker pinned to a global template, with no model choice, whose
  # role's tier is configured.
  defp tier_for(%{"model" => model}) when is_map(model), do: {:ok, nil}

  defp tier_for(%{"template_id" => id, "role" => role})
       when is_binary(id) and id != "" and role in ["router", "worker"] do
    if Ids.valid_private_template_id?(id) or not PlatformModels.configured?(role),
      do: {:ok, nil},
      else: {:ok, role}
  end

  defp tier_for(_agent), do: {:ok, nil}

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
