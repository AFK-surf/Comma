defmodule SalixStore.HierarchyIdMigration do
  @moduledoc """
  Durable migration protocol for tenant/group/agent canonical identities.

  Runtime paths validate canonical IDs directly. This module is only used by
  release migrations so BFT Postgres, Salix S3 and ClickHouse consume the same
  old-to-new mapping across retries and interrupted releases.
  """

  alias SalixStore.{Ids, S3}

  @key "ctl/migrations/hierarchy_identity_v1.json"
  @completion_prefix "ctl/migrations/hierarchy_identity_v1/"
  @retries 8

  def key, do: @key
  def empty, do: %{tenants: %{}, groups: %{}, agents: %{}}

  def read do
    case S3.get(@key) do
      {:ok, %{body: body}} ->
        with {:ok, value} when is_map(value) <- Jason.decode(body),
             {:ok, identity} <- normalize(value) do
          {:ok, identity}
        else
          _ -> {:error, :invalid_hierarchy_identity_map}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def normalize(identity) when is_map(identity) do
    with {:ok, tenants} <- section(identity, :tenants, &Ids.valid_tenant_id?/1),
         :ok <- unique_targets(tenants, :tenant),
         :ok <- no_mapping_chains(tenants, :tenant),
         {:ok, groups} <- section(identity, :groups, &Ids.valid_group_id?/1),
         :ok <- unique_targets(groups, :group),
         :ok <- no_mapping_chains(groups, :group),
         {:ok, agents} <- section(identity, :agents, &Ids.valid_agent_id?/1),
         :ok <- unique_targets(agents, :agent),
         :ok <- no_mapping_chains(agents, :agent) do
      {:ok, %{tenants: tenants, groups: groups, agents: agents}}
    end
  end

  def normalize(_identity), do: {:error, :invalid_hierarchy_identity_map}

  def reserve(identity) do
    with {:ok, identity} <- normalize(identity) do
      reserve(identity, @retries)
    end
  end

  def merge(left, right) do
    with {:ok, left} <- normalize(left),
         {:ok, right} <- normalize(right) do
      merge_normalized(left, right)
    end
  end

  def phase_complete?(phase, identity) when phase in [:s3, :analytics] do
    with {:ok, identity} <- normalize(identity) do
      case S3.get(completion_key(phase)) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"identity_fingerprint" => stored_fingerprint}} ->
              {:ok, stored_fingerprint == fingerprint(identity)}

            _ ->
              {:error, :invalid_hierarchy_identity_completion}
          end

        {:error, :not_found} ->
          {:ok, false}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def mark_phase_complete(phase, identity) when phase in [:s3, :analytics] do
    with {:ok, identity} <- normalize(identity) do
      body =
        Jason.encode!(%{
          "version" => 1,
          "phase" => Atom.to_string(phase),
          "identity_fingerprint" => fingerprint(identity),
          "completed_at" => System.system_time(:millisecond)
        })

      case S3.put(completion_key(phase), body, if_none_match: "*") do
        {:ok, _} -> :ok
        {:error, :precondition_failed} -> verify_phase_completion(phase, identity)
        {:error, {:ambiguous, _}} -> verify_phase_completion(phase, identity)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reserve(_identity, 0), do: {:error, :hierarchy_identity_reservation_exhausted}

  defp reserve(identity, attempts) do
    case S3.get(@key) do
      {:ok, %{body: body, etag: etag}} ->
        with {:ok, record} when is_map(record) <- Jason.decode(body),
             {:ok, existing} <- normalize(record),
             {:ok, merged} <- merge_normalized(existing, identity) do
          encoded = encode_record(merged, record["created_at"])

          case S3.put(@key, encoded, if_match: etag) do
            {:ok, _} -> {:ok, merged}
            {:error, :precondition_failed} -> reserve(identity, attempts - 1)
            {:error, {:ambiguous, _}} -> reserve(identity, attempts - 1)
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_hierarchy_identity_map}
        end

      {:error, :not_found} ->
        case S3.put(@key, encode_record(identity, nil), if_none_match: "*") do
          {:ok, _} -> {:ok, identity}
          {:error, :precondition_failed} -> reserve(identity, attempts - 1)
          {:error, {:ambiguous, _}} -> reserve(identity, attempts - 1)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_normalized(existing, incoming) do
    with {:ok, tenants} <- merge_section(existing.tenants, incoming.tenants, :tenant),
         {:ok, groups} <- merge_section(existing.groups, incoming.groups, :group),
         {:ok, agents} <- merge_section(existing.agents, incoming.agents, :agent) do
      normalize(%{tenants: tenants, groups: groups, agents: agents})
    end
  end

  defp merge_section(existing, incoming, kind) do
    Enum.reduce_while(incoming, {:ok, existing}, fn {source, target}, {:ok, acc} ->
      case Map.fetch(acc, source) do
        :error ->
          {:cont, {:ok, Map.put(acc, source, target)}}

        {:ok, ^target} ->
          {:cont, {:ok, acc}}

        {:ok, current} ->
          {:halt, {:error, {:identity_mapping_conflict, kind, source, current, target}}}
      end
    end)
  end

  defp section(identity, name, valid_target?) do
    value = Map.get(identity, name, Map.get(identity, Atom.to_string(name), :missing))

    if is_map(value) do
      Enum.reduce_while(value, {:ok, %{}}, fn {source, target}, {:ok, acc} ->
        cond do
          not is_binary(source) or String.trim(source) == "" ->
            {:halt, {:error, {:invalid_identity_source, name, source}}}

          not is_binary(target) or not valid_target?.(target) ->
            {:halt, {:error, {:invalid_identity_target, name, source, target}}}

          true ->
            {:cont, {:ok, Map.put(acc, source, target)}}
        end
      end)
    else
      {:error, {:missing_identity_section, name}}
    end
  end

  defp unique_targets(mappings, kind) do
    mappings
    |> Enum.reduce_while({:ok, %{}}, fn {source, target}, {:ok, targets} ->
      case Map.fetch(targets, target) do
        :error ->
          {:cont, {:ok, Map.put(targets, target, source)}}

        {:ok, ^source} ->
          {:cont, {:ok, targets}}

        {:ok, other} ->
          {:halt, {:error, {:duplicate_identity_target, kind, target, other, source}}}
      end
    end)
    |> case do
      {:ok, _targets} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp no_mapping_chains(mappings, kind) do
    Enum.reduce_while(mappings, :ok, fn {source, target}, :ok ->
      case Map.get(mappings, target) do
        nil -> {:cont, :ok}
        ^target -> {:cont, :ok}
        next -> {:halt, {:error, {:identity_mapping_chain, kind, source, target, next}}}
      end
    end)
  end

  defp encode_record(identity, created_at) do
    now = System.system_time(:millisecond)

    Jason.encode!(%{
      "version" => 1,
      "created_at" => created_at || now,
      "updated_at" => now,
      "tenants" => identity.tenants,
      "groups" => identity.groups,
      "agents" => identity.agents
    })
  end

  defp completion_key(phase), do: @completion_prefix <> Atom.to_string(phase) <> ".json"

  defp verify_phase_completion(phase, identity) do
    case phase_complete?(phase, identity) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:hierarchy_identity_completion_conflict, phase}}
      {:error, _} = error -> error
    end
  end

  defp fingerprint(identity) do
    canonical =
      for section <- [:tenants, :groups, :agents] do
        {section, identity |> Map.fetch!(section) |> Enum.sort()}
      end

    canonical
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
