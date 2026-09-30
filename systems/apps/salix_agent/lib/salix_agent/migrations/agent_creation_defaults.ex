defmodule SalixAgent.Migrations.AgentCreationDefaults do
  @moduledoc """
  Preserve inherited tenant models before platform-only runtime resolution.

  Run during a rolling release. The release migration ledger owns completion.
  Each page reads at most 100 canonical Agent records. Concurrent model choices
  may change during this pass. Conditional writes preserve unrelated edits.
  Skip records changed or deleted after the read. Retry failed passes through
  the release runner. Records created after their listing page are not revisited.
  No Agent, session, credential, or tenant configuration is deleted.
  """
  alias SalixAgent.{AgentDefaults, Templates}
  alias SalixStore.{Keys, S3}

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
         {:ok, agent} <- Jason.decode(body) do
      if agent["role"] in ["router", "worker"] and agent["template_id"] in [nil, ""] do
        with {:ok, id} <- AgentDefaults.creation_template(agent["role"], agent["tenant_id"]) do
          if id do
            with {:ok, template} <- Templates.get(id, agent["tenant_id"]),
                 updated =
                   agent
                   |> Map.put("template_id", id)
                   |> Map.put("provider", template["provider"]),
                 {:ok, _} <- S3.put(key, Jason.encode!(updated), if_match: etag) do
              {:ok, true}
            else
              {:error, :precondition_failed} -> {:ok, false}
              error -> error
            end
          else
            {:ok, false}
          end
        end
      else
        {:ok, false}
      end
    else
      {:error, :precondition_failed} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      error -> error
    end
  end
end
