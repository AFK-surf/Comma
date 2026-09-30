defmodule SalixWeb.TrajectoryEvalAPI do
  @moduledoc """
  Read-only, tenant-scoped access to existing L2 trajectory facts.

  Each request returns at most 100 windows and 200 raw records per window.
  Evalens owns replay construction, redaction, identity, and persistence.
  """

  alias SalixAgent.{Control, Runtime}
  alias SalixWeb.TrajectoryEvalCursor

  @default_limit 20
  @max_limit 100
  @max_session_records 200
  @overlap_seconds 3_600

  @spec list(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def list(tenant_id, params) when is_binary(tenant_id) and is_map(params) do
    with {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, page_state} <- page_state(tenant_id, params),
         {:ok, rows} <-
           query_module().confirmed_windows(tenant_id,
             after_at: page_state.after_at,
             after_key: page_state.after_key,
             snapshot_to: page_state.snapshot_to,
             group_id: page_state.filters["group_id"],
             min_severity: page_state.filters["min_severity"],
             limit: limit + 1
           )
           |> normalize_query_error(),
         {page_rows, has_more} <- take_page(rows, limit),
         {:ok, items} <- attach_session_records(tenant_id, page_rows),
         {after_at, after_key} <- next_position(page_rows, page_state, has_more),
         {:ok, cursor} <-
           TrajectoryEvalCursor.encode(tenant_id, %{
             "after_at" => DateTime.to_iso8601(after_at),
             "after_key" => after_key,
             "snapshot_to" => DateTime.to_iso8601(page_state.snapshot_to),
             "complete" => not has_more,
             "filters" => page_state.filters
           }) do
      {:ok,
       %{
         "items" => items,
         "next_cursor" => cursor,
         "has_more" => has_more,
         "snapshot_to" => DateTime.to_iso8601(page_state.snapshot_to),
         "consistency" => %{
           "mode" => "eventual_with_overlap",
           "overlap_seconds" => @overlap_seconds
         }
       }}
    end
  end

  defp page_state(tenant_id, %{"cursor" => cursor} = params)
       when is_binary(cursor) and cursor != "" do
    if Enum.any?(~w(group_id min_severity evaluated_from bootstrap), &present?(params[&1])) do
      {:error, :cursor_filter_conflict}
    else
      with {:ok, decoded} <- TrajectoryEvalCursor.decode(cursor, tenant_id),
           {:ok, after_at} <- parse_datetime(decoded["after_at"]),
           {:ok, snapshot_to} <- parse_datetime(decoded["snapshot_to"]) do
        if decoded["complete"] do
          {:ok,
           %{
             after_at: DateTime.add(snapshot_to, -@overlap_seconds, :second),
             after_key: "",
             snapshot_to: DateTime.utc_now(),
             filters: decoded["filters"]
           }}
        else
          {:ok,
           %{
             after_at: after_at,
             after_key: decoded["after_key"],
             snapshot_to: snapshot_to,
             filters: decoded["filters"]
           }}
        end
      end
    end
  end

  defp page_state(_tenant_id, params) do
    with {:ok, filters} <- initial_filters(params),
         {:ok, after_at} <- initial_after(params) do
      {:ok,
       %{
         after_at: after_at,
         after_key: "",
         snapshot_to: DateTime.utc_now(),
         filters: filters
       }}
    end
  end

  defp initial_filters(params) do
    with {:ok, severity} <- parse_severity(params["min_severity"]) do
      {:ok,
       %{
         "group_id" => blank_to_nil(params["group_id"]),
         "min_severity" => severity
       }}
    end
  end

  defp initial_after(%{"bootstrap" => "now", "evaluated_from" => value})
       when value not in [nil, ""],
       do: {:error, :invalid_bootstrap}

  defp initial_after(%{"bootstrap" => "now"}), do: {:ok, DateTime.utc_now()}

  defp initial_after(%{"bootstrap" => value}) when value not in [nil, ""],
    do: {:error, :invalid_bootstrap}

  defp initial_after(%{"evaluated_from" => value}), do: parse_datetime(value)
  defp initial_after(_), do: {:error, :initial_cursor_required}

  defp take_page(rows, limit), do: {Enum.take(rows, limit), length(rows) > limit}

  defp next_position(_rows, page_state, false), do: {page_state.snapshot_to, ""}

  defp next_position(rows, _page_state, true) do
    row = List.last(rows)
    {:ok, evaluated_at} = parse_datetime(row["evaluated_at"])
    {evaluated_at, row["window_key"]}
  end

  defp attach_session_records(tenant_id, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case attach_session_record(tenant_id, row) do
        {:ok, item} ->
          {:cont, {:ok, [item | acc]}}

        {:error, :snapshot_unavailable} ->
          item = base_item(row) |> Map.put("session_records_status", "snapshot_unavailable")
          {:cont, {:ok, [item | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp attach_session_record(tenant_id, row) do
    agent_id = row["salix_agent_id"]
    session_id = row["session_id"]

    with {:ok, %{"tenant_id" => ^tenant_id} = agent} <- Control.get_record(agent_id),
         {:ok, agent_role} <- supported_role(agent),
         {:ok, session} <-
           Runtime.session_records(agent, session_id,
             history: {:tail, @max_session_records},
             limit: @max_session_records
           )
           |> normalize_session_error() do
      {:ok,
       base_item(row)
       |> Map.put("target", %{
         "agent_role" => agent_role,
         "runtime_kind" => "internal"
       })
       |> Map.put("session_records_status", "available")
       |> Map.put("session_records", session["records"] || session[:records] || [])}
    else
      {:ok, _other_tenant} ->
        {:error, :snapshot_unavailable}

      {:error, reason} when reason in [:not_found, :snapshot_unavailable] ->
        {:error, :snapshot_unavailable}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp base_item(row) do
    %{
      "source" => %{
        "agent_id" => row["salix_agent_id"],
        "session_id" => row["session_id"],
        "group_id" => blank_to_nil(row["group_id"]),
        "window_key" => row["window_key"]
      },
      "window" => %{
        "from_message_id" => row["window_from"],
        "to_message_id" => row["window_to"],
        "message_count" => row["window_messages"],
        "round_id" => blank_to_nil(row["round_id"])
      },
      "evaluation" => %{
        "evaluator" => "judge",
        "evaluator_version" => row["evaluator_version"],
        "outcome" => row["outcome"],
        "evaluated_at" => row["evaluated_at"],
        "max_confirmed_severity" => row["max_confirmed_severity"],
        "findings" => row["findings"] || []
      }
    }
  end

  defp supported_role(agent) do
    case {Control.runtime_kind(agent), agent["role"]} do
      {"external", _role} -> {:error, :snapshot_unavailable}
      {_runtime, "router"} -> {:ok, "router"}
      {_runtime, role} when role in ["worker", "worker_agent"] -> {:ok, "worker"}
      _ -> {:error, :snapshot_unavailable}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) do
    case Integer.parse(to_string(value)) do
      {limit, ""} when limit > 0 and limit <= @max_limit -> {:ok, limit}
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_severity(nil), do: {:ok, 0.5}

  defp parse_severity(value) do
    case Float.parse(to_string(value)) do
      {severity, ""} when severity >= 0.0 and severity <= 1.0 -> {:ok, severity}
      _ -> {:error, :invalid_severity}
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_time}

  defp normalize_query_error({:error, :not_configured}), do: {:error, :unavailable}
  defp normalize_query_error({:error, _}), do: {:error, :unavailable}
  defp normalize_query_error(result), do: result

  defp normalize_session_error({:error, :not_found}), do: {:error, :snapshot_unavailable}
  defp normalize_session_error({:error, _}), do: {:error, :unavailable}
  defp normalize_session_error(result), do: result

  defp query_module do
    Application.get_env(
      :salix_web,
      :trajectory_eval_query_module,
      SalixAnalytics.TrajectoryEvalQueries
    )
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
