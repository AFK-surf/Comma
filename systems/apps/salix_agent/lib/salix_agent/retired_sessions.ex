defmodule SalixAgent.RetiredSessions do
  @moduledoc """
  Read-only history of the Sessions that ran on the retired External Runtime.

  External Runtime Workers were bound to stations or archived
  (`SalixAgent.Migrations.StationBoundWorkers`), and Salix no longer runs
  their Sessions. Their stored records stay where they were written: one
  `state.json` object and one `SalixStore.SegmentLog` record stream per
  Session under `agents/<agent_id>/external_runtime/sessions/`. This module
  lists and reads them for the Agent's Session history. It never writes.

  A Session id stored here stays bound to this history: deliveries to it are
  refused as read-only (`SalixAgent.AgentActor.SessionDelivery`) and no new
  Session is created with its id (`SalixAgent.InternalSessionStore`).
  """

  alias SalixAgent.ContextProviders
  alias SalixStore.{Ids, Keys, S3, SegmentLog, ULID}

  @records_limit_default 100
  @records_limit_max 500
  @summary_fields ~w(tenant_id group_id agent_id session_id name hidden platform
                     source_session_id source_schedule_id task_origin message_count
                     created_at updated_at)

  @doc "Whether `session_id` is a stored retired Session (one HEAD request)."
  @spec probe(String.t(), String.t()) :: :present | :absent | {:error, term()}
  def probe(agent_id, session_id) do
    if Ids.valid_session_id?(session_id) do
      case S3.head(state_key(agent_id, session_id)) do
        {:ok, _} -> :present
        {:error, :not_found} -> :absent
        {:error, reason} -> {:error, reason}
      end
    else
      :absent
    end
  end

  @doc "Summaries of the Agent's retired Sessions, newest first."
  def list(%{"agent_id" => agent_id}) do
    prefix = Keys.agent_external_runtime_sessions_prefix(agent_id)

    with {:ok, objects} <- S3.list_all(prefix, delimiter: "/") do
      objects
      |> Enum.flat_map(fn %{key: key} ->
        session_id = key |> String.replace_prefix(prefix, "") |> String.trim_trailing(".json")

        if String.ends_with?(key, ".json") and Ids.valid_session_id?(session_id),
          do: [session_id],
          else: []
      end)
      |> Enum.reduce_while({:ok, []}, fn session_id, {:ok, acc} ->
        case read_state(agent_id, session_id) do
          {:ok, state} -> {:cont, {:ok, [summary(state) | acc]}}
          {:error, :not_found} -> {:cont, {:ok, acc}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, summaries} ->
          {:ok, Enum.sort_by(summaries, &(&1["updated_at"] || &1["created_at"] || 0), :desc)}

        error ->
          error
      end
    end
  end

  def get_summary(%{"agent_id" => agent_id}, session_id) do
    with {:ok, state} <- read_state(agent_id, session_id), do: {:ok, summary(state)}
  end

  @doc "Every stored record of one retired Session, oldest first."
  def all_records(%{"agent_id" => agent_id}, session_id) do
    with {:ok, _state} <- read_state(agent_id, session_id),
         {:ok, log} <- SegmentLog.load(log_opts(agent_id, session_id)),
         do: SegmentLog.all(log, log_opts(agent_id, session_id))
  end

  def get_messages(agent, session_id) do
    with {:ok, records} <- all_records(agent, session_id) do
      messages =
        records
        |> Enum.flat_map(fn
          %{"type" => "message", "data" => %{} = message} -> [message]
          _ -> []
        end)
        |> ContextProviders.strip_llm_private_metadata()

      {:ok,
       %{
         "session_id" => session_id,
         "status" => "idle",
         "read_only" => true,
         "messages" => messages
       }}
    end
  end

  def records(%{"agent_id" => agent_id}, session_id, opts \\ []) do
    with {:ok, limit} <- records_limit(Keyword.get(opts, :limit)),
         {:ok, _state} <- read_state(agent_id, session_id),
         {:ok, log} <- SegmentLog.load(log_opts(agent_id, session_id)),
         {:ok, page, has_more, next_before} <-
           SegmentLog.tail(log, limit, before(opts), log_opts(agent_id, session_id)) do
      result = %{
        "runtime_kind" => "retired",
        "session_id" => session_id,
        "status" => "idle",
        "read_only" => true,
        "records" => page,
        "has_more" => has_more
      }

      {:ok, if(next_before, do: Map.put(result, "next_before", next_before), else: result)}
    end
  end

  defp summary(state) do
    binding = get_in(state, ["runtime", "binding"]) || %{}

    state
    |> Map.take(@summary_fields)
    |> Map.merge(%{
      "runtime_provider" => binding["provider"],
      "model" => binding["model"],
      "model_provider" => binding["model_provider"]
    })
    |> Map.merge(%{
      "runtime_kind" => "retired",
      "status" => "idle",
      "activity_status" => "idle",
      "read_only" => true
    })
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp read_state(agent_id, session_id) do
    if Ids.valid_session_id?(session_id) do
      with {:ok, %{body: body}} <- S3.get(state_key(agent_id, session_id)),
           {:ok, %{"agent_id" => ^agent_id, "session_id" => ^session_id} = state} <-
             Jason.decode(body) do
        {:ok, state}
      else
        {:ok, _other} -> {:error, :invalid_retired_session}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_session_id}
    end
  end

  defp records_limit(nil), do: {:ok, @records_limit_default}

  defp records_limit(raw) do
    case Integer.parse(to_string(raw)) do
      {value, ""} when value > 0 and value <= @records_limit_max ->
        {:ok, value}

      {value, ""} when value > @records_limit_max ->
        {:error, {:bad_request, "limit must be <= #{@records_limit_max}"}}

      _ ->
        {:error, {:bad_request, "limit must be a positive integer"}}
    end
  end

  defp before(opts) do
    case Keyword.get(opts, :before) do
      value when value in [nil, ""] -> nil
      value -> to_string(value)
    end
  end

  defp state_key(agent_id, session_id),
    do: Keys.agent_external_runtime_session(agent_id, session_id)

  defp log_opts(agent_id, session_id) do
    [
      prefix: Keys.agent_external_runtime_session_segments_prefix(agent_id, session_id),
      decode_id: fn name -> if ULID.valid?(name), do: {:ok, name}, else: :error end,
      record_id: & &1["id"],
      validate: fn record ->
        if record["agent_id"] == agent_id and record["session_id"] == session_id,
          do: :ok,
          else: {:error, :invalid_retired_session_record}
      end,
      same_record?: &(&1 == &2),
      parse_cursor: & &1,
      stale_error: :stale_retired_session_segment,
      conflict_error: :retired_session_record_conflict,
      decode_error: :invalid_retired_session_segment
    ]
  end
end
