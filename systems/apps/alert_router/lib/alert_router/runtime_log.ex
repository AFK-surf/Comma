defmodule AlertRouter.RuntimeLog do
  @moduledoc """
  Read-only consumer of the canonical external SessionRecord log.

  Notifications read their exact bounded segment, including old backfills.
  Producer-owned episode snapshots need no complete-prefix assumption.
  Reduction and delivery jobs commit together. No Agent calls this consumer.
  There are no LIST requests, global session scans, or timers.
  """
  alias AlertRouter.{CanonicalEvent, Repo, RuntimeEpisode, Ingest}
  alias AlertRouter.Data.Incident
  alias SalixStore.S3

  @max_bytes 1_048_576
  @max_records 512

  def parse_object(object) when is_binary(object) do
    case Regex.run(
           ~r/^agents\/([A-Za-z0-9_-]+)\/external_runtime\/sessions\/([A-Za-z0-9_-]+)\/segments\/([0-7][0-9A-HJKMNP-TV-Z]{25})\.jsonl$/,
           object
         ) do
      [_, agent, session, _] -> {:ok, agent, session}
      _ -> :ignored
    end
  end

  def parse_object(_), do: :ignored

  def consume(object, opts \\ []) do
    AlertRouter.Telemetry.observe(:runtime_log, "salix_runtime", fn ->
      do_consume(object, opts)
    end)
  end

  defp do_consume(object, opts) do
    with {:ok, agent, session} <- parse_object(object),
         {:ok, config} <- config() do
      Repo.transaction(fn ->
        scope = "#{config[:environment]}:#{agent}:#{session}"
        sql!("SELECT pg_advisory_xact_lock(hashtext($1))", [scope])

        storage = Keyword.get(opts, :storage, S3)
        metadata = read_metadata!(storage, agent, session, config)
        consume_segment!(storage, object, metadata, config, opts)
        :done
      end)
    end
  end

  def config do
    cfg = Application.get_env(:alert_router, :runtime_log, [])

    with true <- cfg[:enabled] == true,
         true <- cfg[:environment] in ["staging", "production"],
         true <- is_binary(cfg[:bucket]) and cfg[:bucket] != "",
         true <- cfg[:bucket] == SalixStore.Config.get().bucket,
         {:ok, start_at, 0} <- DateTime.from_iso8601(cfg[:start_at] || "") do
      {:ok, Keyword.put(cfg, :start_at, start_at)}
    else
      _ -> {:error, :runtime_log_not_configured}
    end
  end

  defp read_metadata!(storage, agent, session, config) do
    case storage.get("agents/#{agent}/external_runtime/sessions/#{session}.json") do
      {:ok, %{body: body}} when byte_size(body) <= @max_bytes ->
        case Jason.decode(body) do
          {:ok, %{"agent_id" => ^agent, "session_id" => ^session, "tenant_id" => tenant} = value}
          when is_binary(tenant) ->
            Map.take(value, ~w(agent_id session_id tenant_id group_id))
            |> Map.put("cluster", config[:cluster])
            |> Map.put(
              "incident_url",
              "https://console.cloud.google.com/storage/browser/#{URI.encode(config[:bucket])}/agents/#{URI.encode(agent)}/external_runtime/sessions/#{URI.encode(session)}/segments"
            )

          _ ->
            Repo.rollback(:invalid_session_metadata)
        end

      {:error, reason} ->
        Repo.rollback(reason)

      _ ->
        Repo.rollback(:session_metadata_too_large)
    end
  end

  defp consume_segment!(storage, segment, metadata, config, opts) do
    records =
      case storage.get(segment) do
        {:ok, %{body: body}} when byte_size(body) <= @max_bytes ->
          lines = String.split(body, "\n", trim: true)
          if length(lines) > @max_records, do: Repo.rollback(:segment_record_budget_exceeded)

          Enum.map(lines, fn line ->
            case Jason.decode(line) do
              {:ok, %{"id" => id, "agent_id" => agent, "session_id" => session} = record}
              when is_binary(id) ->
                if agent != metadata["agent_id"] or session != metadata["session_id"],
                  do: Repo.rollback(:segment_identity_mismatch)

                record

              _ ->
                Repo.rollback(:invalid_segment_record)
            end
          end)

        {:error, reason} ->
          Repo.rollback(reason)

        _ ->
          Repo.rollback(:segment_byte_budget_exceeded)
      end

    ids = Enum.map(records, & &1["id"])
    if ids != Enum.sort(Enum.uniq(ids)), do: Repo.rollback(:unordered_segment)

    Enum.each(records, &consume_record!(&1, metadata, config, opts))
  end

  defp consume_record!(
         %{"type" => "runtime.event", "data" => %{"event" => event}} = record,
         metadata,
         config,
         opts
       )
       when is_map(event) do
    kind =
      cond do
        event["name"] == "runtime_recovered" and event["state"] == "recovered" ->
          "runtime_recovered"

        event["work_state"] == "failed" and
            event["issue"] in ["runtime_failed", "recovery_exhausted"] ->
          event["issue"]

        true ->
          nil
      end

    if kind && is_binary(event["execution_id"]) && is_binary(event["dispatch_id"]) &&
         is_binary(event["fault_episode_id"]) do
      identity = [
        config[:environment],
        metadata["tenant_id"],
        metadata["agent_id"],
        metadata["session_id"],
        event["dispatch_id"],
        event["execution_id"]
      ]

      at = runtime_time!(event["created_at"])
      started = runtime_time!(event["fault_started_at"])

      incident_key =
        CanonicalEvent.incident_key(
          ["alert-router.v1", "salix_runtime"] ++ identity ++ [event["fault_episode_id"]]
        )

      state =
        case Repo.get(Incident, incident_key) do
          nil ->
            %{}

          incident ->
            %{"priority" => incident.priority, "recovered" => incident.state == "resolved"}
        end

      fact = %{
        "identity" => identity,
        "record_id" => record["id"],
        "episode_id" => event["fault_episode_id"],
        "started_at" => started,
        "priority" => event["fault_priority"],
        "kind" => kind,
        "observed_at" => at
      }

      case RuntimeEpisode.consume(state, fact, metadata) do
        {:ok, _next, canonical} ->
          if canonical && DateTime.compare(canonical.started_at, config[:start_at]) != :lt do
            with {:ok, _} <- Ingest.accept(canonical, opts) do
              :ok
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end
  end

  defp consume_record!(_, _, _, _), do: :ok

  defp runtime_time!(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> Repo.rollback(:invalid_runtime_time)
    end
  end

  defp runtime_time!(_), do: Repo.rollback(:invalid_runtime_time)

  defp sql!(sql, args), do: Ecto.Adapters.SQL.query!(Repo, sql, args)
end

