defmodule SalixAgent.Migrations.TemplatePinChoices do
  @moduledoc """
  Give every Router and Worker that still pins a template (`template_id`, no
  `model`) the model choice that template stands for (`SalixAgent.ModelChoice`),
  so no Agent reads a template any more.

    * A Tenant-private template of the subscription pool (`account_pool` codex
      or claude) becomes the catalog choice of its model and effort: the pool
      serves it as before.
    * A Tenant-private template of an own endpoint (`base_url` and its key)
      becomes a Custom Profile of the Tenant holding that endpoint, key and
      model, once per template (a second Agent pinning it, or a pass run again,
      finds it by name, endpoint and model); the Agent chooses that model of
      that Profile.
    * Any other pin (a global template, a template gone, a choice the catalog
      refuses) follows the platform model of the Agent's role.

  Run during a rolling release, like `SalixAgent.Migrations.AgentModelChoices`:
  each page reads at most 100 canonical Agent records; `template_id` stays, so
  processes of the previous release resolve the same model until they are
  replaced; conditional writes skip a record changed or deleted after the read.
  Meeting Agents (no product model) are left as they are. No Agent, template,
  session or credential is deleted.
  """

  require Logger

  alias SalixAgent.{AccountPool, ModelChoice}
  alias SalixAgent.Migrations.TemplateRecords
  alias SalixStore.{Ids, Keys, S3}

  @roles ~w(router worker)

  def run, do: page(nil, %{catalog: 0, profile: 0, platform: 0})

  defp page(cursor, counts) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix(), max_keys: 100, continuation_token: cursor),
         {:ok, counts} <-
           Enum.reduce_while(objects, {:ok, counts}, fn object, {:ok, counts} ->
             case migrate_object(object.key) do
               {:ok, nil} -> {:cont, {:ok, counts}}
               {:ok, kind} -> {:cont, {:ok, Map.update!(counts, kind, &(&1 + 1))}}
               error -> {:halt, error}
             end
           end) do
      if next, do: page(next, counts), else: {:ok, counts}
    end
  end

  defp migrate_object(key) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, agent} <- Jason.decode(body),
         {:ok, {kind, model}} <- choice(agent),
         {:ok, _} <- S3.put(key, Jason.encode!(Map.put(agent, "model", model)), if_match: etag) do
      {:ok, kind}
    else
      {:ok, nil} -> {:ok, nil}
      {:error, :precondition_failed} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  defp choice(%{"model" => model}) when is_map(model), do: {:ok, nil}

  defp choice(%{"template_id" => id, "tenant_id" => tenant, "role" => role} = agent)
       when is_binary(id) and id != "" and is_binary(tenant) and role in @roles do
    template =
      if Ids.valid_private_template_id?(id) do
        case TemplateRecords.get(id, tenant) do
          {:ok, template} -> template
          {:error, :not_found} -> nil
          error -> throw(error)
        end
      end

    case from_template(template, tenant) do
      {:ok, {kind, model}} ->
        {:ok, {kind, model}}

      _platform ->
        Logger.info(
          "template pin follows the platform model: agent=#{agent["agent_id"]} template=#{id}"
        )

        {:ok, {:platform, %{"kind" => "platform", "tier" => role}}}
    end
  catch
    {:error, _} = error -> error
  end

  defp choice(_agent), do: {:ok, nil}

  defp from_template(
         %{"model" => model, "provider_config" => %{"account_pool" => pool} = config},
         tenant
       )
       when pool in ~w(codex claude) and is_binary(model) do
    chosen(:catalog, %{"kind" => "catalog", "model" => model}, config["reasoning_effort"], tenant)
  end

  defp from_template(
         %{"model" => model, "provider_config" => %{"base_url" => url, "api_key" => key} = config} =
           template,
         tenant
       )
       when is_binary(model) and is_binary(url) and is_binary(key) and key != "" do
    with {:ok, profile} <- profile(template, config, tenant) do
      chosen(
        :profile,
        %{"kind" => "catalog", "model" => model, "profile_id" => profile},
        config["reasoning_effort"],
        tenant
      )
    end
  end

  defp from_template(_template, _tenant), do: :platform

  # The template's effort when the model takes it; else the model's default.
  defp chosen(kind, choice, effort, tenant) do
    with_effort =
      if is_binary(effort) and effort != "",
        do: Map.put(choice, "reasoning_effort", effort),
        else: choice

    case ModelChoice.choose(with_effort, tenant) do
      {:ok, model} ->
        {:ok, {kind, model}}

      {:error, _} when with_effort != choice ->
        with {:ok, model} <- ModelChoice.choose(choice, tenant), do: {:ok, {kind, model}}

      {:error, _} = error ->
        error
    end
  end

  # The Tenant's Custom Profile of this template's endpoint and model: the one
  # made before, or a new one.
  defp profile(template, config, tenant) do
    protocol = config["protocol"] || "chat_completions"

    case TemplateRecords.custom_profile(tenant, template) do
      {:ok, id} ->
        {:ok, id}

      {:error, _} = error ->
        throw(error)

      :none ->
        attrs = %{
          "credential_kind" => "provider_api_key",
          "source" => "custom",
          "name" => TemplateRecords.custom_profile_name(template),
          "api_key" => config["api_key"],
          "base_url" => config["base_url"],
          "protocol" => protocol,
          "models" => [template["model"]]
        }

        case AccountPool.create(tenant, attrs) do
          {:ok, %{"id" => id}} -> {:ok, id}
          {:error, _} = error -> error
        end
    end
  end
end
