defmodule SalixWeb.Dashboard.AgentTelemetry do
  @moduledoc """
  Shared helpers for dashboard surfaces reading the agent telemetry tables
  (`SalixAnalytics.AgentTelemetryQueries`): the Runtime Health pages, the
  session "What actually ran" card, and the Trajectory Evals "Sessions
  never checked" card.

  ## Internal-only labeling

  Run terminal rows (`agent_run_events`) are emitted by INTERNAL sessions
  only. Any "never finished" listing built on their absence must therefore
  drop sessions owned by external-runtime agents — an external session
  never reports an ending, so its absence means nothing. `internal_only/1`
  applies that filter using the agent registry; sessions whose agent can't
  be resolved are dropped too (fail closed: quietly mislabeling a healthy
  external session as stuck is exactly the failure mode this exists to
  prevent).
  """

  @doc "The ClickHouse query module (swappable in tests)."
  def queries_mod do
    Application.get_env(
      :salix_web,
      :agent_telemetry_queries_mod,
      SalixAnalytics.AgentTelemetryQueries
    )
  end

  @doc """
  Keep only rows (maps with `"salix_agent_id"`) whose agent is a verified
  internal-runtime agent. One registry lookup per distinct agent id.
  """
  def internal_only(rows) when is_list(rows) do
    kinds =
      rows
      |> Enum.map(& &1["salix_agent_id"])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Map.new(&{&1, internal_agent?(&1)})

    Enum.filter(rows, &Map.get(kinds, &1["salix_agent_id"], false))
  end

  defp internal_agent?(agent_id) do
    case agent_control().get_record(agent_id) do
      {:ok, agent} -> agent_control().runtime_kind(agent) != "external"
      _ -> false
    end
  end

  @doc """
  Display name, role and runtime kind for a list of agent ids — one registry
  lookup per distinct id, run concurrently (the lanes name up to 40 agents,
  and forty sequential reads are a visible part of the page's load time).
  An id whose record has no name or cannot be read (a cross-tenant row may
  name an agent this tenant view can't see) keeps the id as its name, has no
  role, and counts as internal.
  """
  @name_lookup_concurrency 8
  @name_lookup_timeout_ms 5_000

  def agent_infos(agent_ids) when is_list(agent_ids) do
    ids = agent_ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    infos =
      ids
      |> Task.async_stream(&{&1, agent_info(&1)},
        max_concurrency: @name_lookup_concurrency,
        ordered: false,
        timeout: @name_lookup_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {id, info}}, acc -> Map.put(acc, id, info)
        _exit_or_timeout, acc -> acc
      end)

    Map.new(ids, &{&1, Map.get(infos, &1, unknown_agent(&1))})
  end

  @doc "Display names alone; see `agent_infos/1`."
  def agent_names(agent_ids) when is_list(agent_ids) do
    agent_ids |> agent_infos() |> Map.new(fn {id, info} -> {id, info.name} end)
  end

  defp agent_info(id) do
    case agent_control().get_record(id) do
      {:ok, record} when is_map(record) ->
        name = record["name"]

        %{
          name: if(is_binary(name) and name != "", do: name, else: id),
          role: record["role"],
          external?: agent_control().runtime_kind(record) == "external"
        }

      _ ->
        unknown_agent(id)
    end
  end

  defp unknown_agent(id), do: %{name: id, role: nil, external?: false}

  defp agent_control do
    Application.get_env(:salix_web, :agent_control_mod, SalixAgent.Control)
  end

  @doc "Degrade a failed widget query to empty rather than crashing the page."
  def rows({:ok, rows}), do: rows
  def rows({:error, _}), do: []

  @doc """
  True when a query declined to run because it would exceed its read/memory/
  time budget (`SalixAnalytics.ClickHouseRead`'s boundedness contract). The
  page surfaces this as "narrow the time window" rather than a blank panel —
  it is the expected signal for a window too wide for the tenant's volume,
  not an error.
  """
  def over_budget?({:error, {:read_over_budget, _}}), do: true
  def over_budget?(_), do: false

  @doc """
  Coerce a ClickHouse count to a number. UInt64 aggregates can arrive as
  JSON strings depending on server settings; arithmetic must never crash
  on raw row values.
  """
  def num(n) when is_number(n), do: n

  def num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> 0
    end
  end

  def num(_), do: 0

  @doc "Like `num/1` but keeps floats and returns nil for absent values."
  def fnum(n) when is_number(n), do: n

  def fnum(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      _ -> nil
    end
  end

  def fnum(_), do: nil

  @doc "Percentage (1 decimal) or nil when the denominator is zero."
  def pct(value, den) do
    case num(den) do
      0 -> nil
      d -> Float.round(num(value) * 100 / d, 1)
    end
  end

  @doc ~S|Render "pct% (n/N)" reconciling cells; "—" when nothing ran.|
  def rate_cell(value, den) do
    case pct(value, den) do
      nil -> "—"
      p -> "#{p}% (#{num(value)}/#{num(den)})"
    end
  end

  @doc "Human duration from milliseconds."
  def fmt_ms(nil), do: "—"

  def fmt_ms(ms) do
    ms = num(ms)

    cond do
      ms < 1_000 -> "#{round(ms)}ms"
      ms < 60_000 -> "#{Float.round(ms / 1_000, 1)}s"
      ms < 3_600_000 -> "#{div(round(ms), 60_000)}m #{rem(div(round(ms), 1_000), 60)}s"
      true -> "#{div(round(ms), 3_600_000)}h #{rem(div(round(ms), 60_000), 60)}m"
    end
  end

  @doc "Compact token count: 950, 12.4k, 1.2M."
  def fmt_tokens(n) do
    n = num(n)

    cond do
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 1)}k"
      true -> "#{n}"
    end
  end

  @doc """
  Unix milliseconds for a ClickHouse DateTime string ("2026-07-10 10:05:00.123",
  UTC), or nil when the value is not one.
  """
  @spec ch_ms(term()) :: integer() | nil
  def ch_ms(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(String.replace(value, " ", "T")) do
      {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
      _ -> nil
    end
  end

  def ch_ms(_), do: nil

  @doc """
  Relative time for a ClickHouse DateTime string ("2026-07-10 10:05:00",
  UTC) via the house formatter.
  """
  def ch_time_ago(nil), do: "—"

  def ch_time_ago(value) when is_binary(value) do
    value
    |> String.replace(" ", "T")
    |> then(&(&1 <> "Z"))
    |> SalixWeb.Dashboard.Format.time_ago()
  end

  def ch_time_ago(_), do: "—"
end
