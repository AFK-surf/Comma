defmodule SalixAgent.Migrations.RetireExternalRuntimeConfig do
  @moduledoc """
  Remove the External Runtime configuration from every Agent record.

  `SalixAgent.Migrations.StationBoundWorkers` bound each External Runtime
  Worker to a station, or archived it, and kept its `runtime_config` for the
  previous release. Salix no longer runs External Sessions, so this pass sets
  a non-internal `runtime_config` (kinds external, connected_runtime,
  compute_workload) to `%{"kind" => "internal"}` and removes a leftover
  External Session `session_admission` reservation. The station binding, the
  archive and its `archive_reason`, and every other field stay.

  Run during a rolling release: each page reads at most 100 canonical Agent
  records; a conditional write that loses to a concurrent change reads the
  record again, a deleted record is skipped, and a record already internal
  is unchanged, so a pass run again changes nothing. Processes of the
  previous release read a bound Worker as internal already. No Agent, Session or stored object is deleted.
  """

  alias SalixStore.{Keys, S3}

  def run, do: page(nil, 0)

  defp page(cursor, count) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix(), max_keys: 100, continuation_token: cursor),
         {:ok, count} <-
           Enum.reduce_while(objects, {:ok, count}, fn object, {:ok, count} ->
             case migrate_object(object.key) do
               {:ok, :changed} -> {:cont, {:ok, count + 1}}
               {:ok, :unchanged} -> {:cont, {:ok, count}}
               error -> {:halt, error}
             end
           end) do
      if next, do: page(next, count), else: {:ok, count}
    end
  end

  defp migrate_object(key) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, agent} when is_map(agent) <- Jason.decode(body) do
      case retire(agent) do
        ^agent ->
          {:ok, :unchanged}

        updated ->
          case S3.put(key, Jason.encode!(updated), if_match: etag) do
            {:ok, _} -> {:ok, :changed}
            # Changed after the read: read it again, so no record keeps an
            # External Runtime configuration.
            {:error, :precondition_failed} -> migrate_object(key)
            {:error, :not_found} -> {:ok, :unchanged}
            error -> error
          end
      end
    else
      {:ok, _not_an_object} -> {:ok, :unchanged}
      {:error, :not_found} -> {:ok, :unchanged}
      error -> error
    end
  end

  @doc false
  def retire(agent) do
    agent
    |> retire_runtime_config()
    |> retire_session_admission()
  end

  defp retire_runtime_config(%{"runtime_config" => %{"kind" => kind}} = agent)
       when kind in ~w(external connected_runtime compute_workload),
       do: Map.put(agent, "runtime_config", %{"kind" => "internal"})

  defp retire_runtime_config(agent), do: agent

  defp retire_session_admission(%{"session_admission" => _} = agent),
    do: Map.delete(agent, "session_admission")

  defp retire_session_admission(agent), do: agent
end
