defmodule SalixAgent.Migrations.AgentModelChoices do
  @moduledoc """
  Store each Agent's catalog or runtime choice as its own `model` value
  (`SalixAgent.ModelChoice`) instead of a hidden private template.

  Run during a rolling release. The release migration ledger owns completion.
  Each page reads at most 100 canonical Agent records. An Agent whose
  `template_id` names a Tenant-private template holding a catalog choice or a
  compute runtime choice gets the same choice as `model`. The `template_id`
  stays, so processes of the previous release keep resolving the same model
  until they are replaced; this release reads `model` first. Conditional writes
  preserve concurrent edits: a record changed or deleted after the read is
  skipped, and a later choice already writes `model`. Retry failed passes
  through the release runner. No Agent, template, session or credential is
  deleted.

  Copy stored choices after the template identity and owner checks. A deleted
  Profile or a model removed from the catalog must not block this conversion.
  Requests still use the normal model and Profile checks.
  """
  alias SalixStore.{Ids, Keys, S3}

  def run, do: page(nil, 0)

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
      if next, do: page(next, count), else: {:ok, %{migrated: count}}
    end
  end

  defp migrate_object(key) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, agent} <- Jason.decode(body),
         {:ok, model} when is_map(model) <- choice(agent),
         {:ok, _} <- S3.put(key, Jason.encode!(Map.put(agent, "model", model)), if_match: etag) do
      {:ok, true}
    else
      {:ok, nil} -> {:ok, false}
      {:error, :precondition_failed} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      error -> error
    end
  end

  defp choice(%{"model" => model}) when is_map(model), do: {:ok, nil}

  defp choice(%{"template_id" => id, "tenant_id" => tenant_id}) when is_binary(id) do
    with true <- Ids.valid_private_template_id?(id) and Ids.valid_tenant_id?(tenant_id),
         {:ok, %{body: body}} <- S3.get(Keys.ctl_private_template(tenant_id, id)),
         {:ok, %{"template_id" => ^id, "tenant_id" => ^tenant_id} = template} <-
           Jason.decode(body) do
      {:ok, from_config(template["provider_config"] || %{})}
    else
      false -> {:ok, nil}
      {:ok, _wrong_owner} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  defp choice(_agent), do: {:ok, nil}

  defp from_config(%{"catalog_model" => model} = config) when is_binary(model),
    do:
      compact(%{
        "kind" => "catalog",
        "model" => model,
        "reasoning_effort" => config["reasoning_effort"],
        "allow_paid" => config["allow_paid"] == true,
        "profile_id" => config["profile_id"]
      })

  defp from_config(%{"runtime_model" => model, "runtime_provider" => provider} = config)
       when is_binary(model) and provider in ~w(codex claude),
       do:
         compact(%{
           "kind" => "runtime",
           "provider" => provider,
           "model" => model,
           "reasoning_effort" => config["reasoning_effort"]
         })

  defp from_config(_config), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
