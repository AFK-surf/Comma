defmodule SalixWeb.Dashboard.RuntimeHealthLive do
  @moduledoc """
  Runtime Health: are agent rounds finishing — and if not, did it start
  with a deploy, a tool, or a model?

  One nav entry, three tab-scoped views (`live_action`):

    * Overview (`/dash/runtime`) — detect and localize in under 30 seconds;
      every anomaly is one click from a concrete session timeline.
    * Tools (`/dash/runtime/tools`) — "broke" means the tool itself failed
      (fix infra); "sent back" means the agent misused it (fix prompts).
    * Models (`/dash/runtime/models`) — is the provider failing or slow,
      and is slowness unresponsiveness (first word) or long answers plus
      retry backoff?
    * Activity (`/dash/runtime/activity`) — the newest activations (one
      input's chain of rounds) as lanes of model and tool calls at true
      offsets, with every unrecorded stretch drawn as "unknown"; which
      model calls are outliers, and how much wall clock nothing accounts
      for. Shaping lives in
      `SalixWeb.Dashboard.ActivityTimeline`; this tab can read all tenants
      (the admin dashboard is deployment-scoped) via `?tenants=all`.

  House rules carried over from the Trajectory Evals page: every stat strip
  opens with a reconciling identity (rounds ended = finished + failed),
  every rate renders next to its counts, charts are server-rendered SVG
  with hover tooltips, and a missing ClickHouse config degrades to an empty
  state instead of erroring. Pure quality verdicts (stuck, confused) stay
  on the Trajectory Evals page — this page is mechanics only.

  Filters (range / group / app revision) persist across tabs via URL query
  params, so a regression spotted in the deploy table can be carried onto
  the Tools and Models tabs. Data comes from
  `SalixAnalytics.AgentTelemetryQueries` (swappable through
  `:salix_web, :agent_telemetry_queries_mod` for tests).
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Groups
  alias SalixWeb.Dashboard.ActivityTimeline
  alias SalixWeb.Dashboard.Format
  import SalixWeb.Dashboard.LocalTime, only: [local_time: 1]

  import SalixWeb.Dashboard.AgentTelemetry,
    only: [
      queries_mod: 0,
      internal_only: 1,
      agent_infos: 1,
      rows: 1,
      over_budget?: 1,
      num: 1,
      fnum: 1,
      pct: 2,
      fmt_ms: 1,
      fmt_tokens: 1,
      ch_time_ago: 1
    ]

  # Bucket widths keep every chart between ~18 and ~72 points: fine-grained
  # enough to see when something started, coarse enough that low volume
  # doesn't read as noise.
  @ranges [
    {"3h", "Last 3 hours", 3 * 3600, 600},
    {"24h", "Last 24 hours", 24 * 3600, 3600},
    {"3d", "Last 3 days", 3 * 86_400, 3600},
    {"7d", "Last 7 days", 7 * 86_400, 86_400},
    {"30d", "Last 30 days", 30 * 86_400, 86_400}
  ]
  @default_range "24h"

  @tabs [overview: "Overview", tools: "Tools", models: "Models", activity: "Activity"]

  # A guard ended these runs on purpose to stop a loop. They read amber, not
  # red: the runtime worked as designed, but the input still got no answer.
  # The runtime owns the list; repeating it here is how a new status arrives
  # unnamed.
  @parked_statuses SalixAgent.RunTelemetry.parked_statuses()

  # Activity tab: one page is the newest activations built from at most
  # this many rows (well under the read budget for a busy day), and shows
  # this many lanes (what fits a screen with room to read labels). Older
  # pages are reached by cursor: the oldest start shown becomes `before`.
  @activity_row_limit 4000
  @activity_lanes 40

  @guidance_reasons [
    {"guidance_invalid_params", "Wrong parameters",
     "The model got the call format wrong (guidance_reason=invalid_params)"},
    {"guidance_envelope_misuse", "Wrapper misused",
     "The model misused the tool-call envelope (guidance_reason=envelope_misuse)"},
    {"guidance_not_callable", "Tool not available to this agent",
     "Configuration: the tool isn't callable here (guidance_reason=not_callable)"},
    {"guidance_not_disclosed", "Tool not shown to the model",
     "Configuration: the tool wasn't disclosed (guidance_reason=not_disclosed)"},
    {"guidance_unauthorized_target", "Historical thread-target refusals",
     "Historical refusals from the removed Slack activation source-target gate (guidance_reason=unauthorized_target); current Router sends do not use this gate"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       active_nav: :runtime,
       page_title: "Runtime Health",
       groups: Groups.list(socket.assigns.current_tenant),
       configured?: true,
       over_budget?: false,
       expanded_tool: nil,
       tool_drill: nil,
       expanded_model: nil,
       activity_detail?: false,
       activity_lane_detail: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = socket.assigns.live_action || :overview

    range =
      case List.keyfind(@ranges, params["range"] || @default_range, 0) do
        {key, _, _, _} -> key
        nil -> @default_range
      end

    {:noreply,
     socket
     |> assign(
       tab: tab,
       range: range,
       filter_group: params["group"] || "",
       filter_rev: params["rev"] || "",
       filter_provider: params["provider"] || "",
       filter_entrypoint: params["entrypoint"] || "",
       filter_tenants: if(params["tenants"] == "all", do: "all", else: ""),
       activity_before: parse_before(params["before"]),
       activity_trail: parse_trail(params["trail"]),
       breadcrumbs: breadcrumbs(tab),
       expanded_tool: nil,
       tool_drill: nil,
       expanded_model: nil,
       activity_lane_detail: %{}
     )
     |> load_when_connected()}
  end

  # LiveView renders a page twice: once over plain HTTP (the frame the
  # browser paints first) and again when the websocket connects. The
  # dashboard reads are this page's whole cost, so the first render skips
  # them and shows the frame with a loading note; the connected mount runs
  # them once. Tests read the page with `render/1` after connecting.
  defp load_when_connected(socket) do
    if connected?(socket),
      do: socket |> assign(loading?: false) |> load(),
      else: assign(socket, loading?: true, revisions: [])
  end

  # The Activity paging cursor: a unix-millisecond start, from the page's
  # own "Older" link. Anything else means the newest page.
  defp parse_before(value) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} when ms > 0 -> ms
      _ -> nil
    end
  end

  defp parse_before(_), do: nil

  # The cursors of the pages walked through to reach this one, oldest first,
  # so "Newer" can step back exactly one page. Dot-separated in the URL.
  @max_trail 200

  defp parse_trail(value) when is_binary(value) do
    value
    |> String.split(".", trim: true)
    |> Enum.map(&parse_before/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(-@max_trail)
  end

  defp parse_trail(_), do: []

  defp breadcrumbs(:overview), do: [{"Runtime Health", nil}]
  defp breadcrumbs(tab), do: [{"Runtime Health", "/dash/runtime"}, {tab_label(tab), nil}]

  defp tab_label(tab), do: Keyword.fetch!(@tabs, tab)

  @impl true
  def handle_event("filter", params, socket) do
    query =
      [
        {"range", params["range"]},
        {"group", params["group"]},
        {"rev", params["rev"]},
        {"provider", params["provider"]},
        {"entrypoint", params["entrypoint"]},
        {"tenants", params["tenants"]}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    {:noreply, push_patch(socket, to: tab_path(socket.assigns.tab, query))}
  end

  # Row expansion is in-page state, not navigation: clicking a scoreboard row
  # drills into that tool's error types and hardest-hit sessions.
  def handle_event("expand_tool", %{"tool" => tool}, socket) do
    if socket.assigns.expanded_tool == tool do
      {:noreply, assign(socket, expanded_tool: nil, tool_drill: nil)}
    else
      opts = query_opts(socket)
      mod = queries_mod()

      drill = %{
        errors: rows(mod.tool_error_types(socket.assigns.current_tenant, tool, opts)),
        sessions: rows(mod.tool_top_sessions(socket.assigns.current_tenant, tool, opts))
      }

      {:noreply, assign(socket, expanded_tool: tool, tool_drill: drill)}
    end
  end

  # The model expansion needs no extra query — the reliability rollup keeps
  # each group's outcome breakdown.
  def handle_event("expand_model", %{"key" => key}, socket) do
    expanded = if socket.assigns.expanded_model == key, do: nil, else: key
    {:noreply, assign(socket, expanded_model: expanded)}
  end

  # Folding the runtime's phases away on the Activity timeline: in-page
  # state, no query. The whole page has a default and a lane can differ
  # from it; a new default clears the per-lane choices.
  def handle_event("toggle_activity_detail", _params, socket) do
    {:noreply,
     assign(socket,
       activity_detail?: not socket.assigns.activity_detail?,
       activity_lane_detail: %{}
     )}
  end

  def handle_event("toggle_activity_lane", %{"lane" => lane_id}, socket) do
    %{activity_detail?: default, activity_lane_detail: overrides} = socket.assigns
    overrides = Map.put(overrides, lane_id, not Map.get(overrides, lane_id, default))
    {:noreply, assign(socket, activity_lane_detail: overrides)}
  end

  defp tab_path(tab, query) do
    base =
      case tab do
        :overview -> "/dash/runtime"
        :tools -> "/dash/runtime/tools"
        :models -> "/dash/runtime/models"
        :activity -> "/dash/runtime/activity"
      end

    case query do
      [] -> base
      query -> base <> "?" <> URI.encode_query(query)
    end
  end

  defp current_query(assigns) do
    [
      {"range", assigns.range != @default_range && assigns.range},
      {"group", assigns.filter_group != "" && assigns.filter_group},
      {"rev", assigns.filter_rev != "" && assigns.filter_rev},
      {"provider", assigns.filter_provider != "" && assigns.filter_provider},
      {"entrypoint", assigns.filter_entrypoint != "" && assigns.filter_entrypoint},
      {"tenants", assigns.filter_tenants != "" && assigns.filter_tenants}
    ]
    |> Enum.filter(fn {_k, v} -> v end)
  end

  # ============================== data loading ==============================

  defp query_opts(socket) do
    {_, _, seconds, bucket} = List.keyfind(@ranges, socket.assigns.range, 0)
    to = DateTime.utc_now() |> DateTime.truncate(:second)
    from = DateTime.add(to, -seconds, :second)

    [from: from, to: to, bucket_seconds: bucket]
    |> maybe_opt(:group_id, socket.assigns.filter_group)
    |> maybe_opt(:app_revision, socket.assigns.filter_rev)
  end

  defp maybe_opt(opts, _key, ""), do: opts
  defp maybe_opt(opts, key, value), do: opts ++ [{key, value}]

  defp load(socket) do
    tenant = socket.assigns.current_tenant
    opts = query_opts(socket)
    mod = queries_mod()

    # One cheap probe decides configured-vs-not for the whole page; every
    # other widget degrades to empty on its own errors.
    case mod.run_outcomes(tenant, opts) do
      {:error, :not_configured} ->
        assign(socket, configured?: false, over_budget?: false, revisions: [])

      probe ->
        # The probe is the current window/tenant's representative read; if it
        # hit the read budget, the window is too wide for this tenant's volume
        # and every widget would too. Surface one "narrow the window" banner
        # rather than a page of blank panels.
        socket
        |> assign(configured?: true, over_budget?: over_budget?(probe))
        |> assign(revisions: revisions(mod, tenant, opts))
        |> load_tab(probe, mod, tenant, opts)
    end
  end

  # The revision filter's options double as the deploy table's row set.
  defp revisions(mod, tenant, opts) do
    mod.deploy_rates(:run, tenant, Keyword.delete(opts, :app_revision))
    |> rows()
    |> Enum.map(&Map.put(&1, "revision", &1["revision"] || ""))
  end

  defp load_tab(%{assigns: %{tab: :overview}} = socket, probe, mod, tenant, opts) do
    outcomes = probe |> rows() |> List.first() || %{}
    trend_rows = rows(mod.round_trends(tenant, opts))
    unaccounted = internal_only(rows(mod.unconverged_sessions(tenant, opts)))

    {from, to, bucket} = {opts[:from], opts[:to], opts[:bucket_seconds]}

    assign(socket,
      outcomes: outcomes,
      trend: bucket_series(trend_rows, from, to, bucket),
      unknown_trend: unknown_series(rows(mod.unknown_trends(tenant, opts)), from, to, bucket),
      unaccounted: unaccounted,
      doors: %{
        tool: rows(mod.error_overview(:tool, tenant, opts)) |> List.first(),
        llm: rows(mod.error_overview(:llm, tenant, opts)) |> List.first()
      },
      deploys: deploys(mod, tenant, opts, socket.assigns.revisions),
      attention: attention(rows(mod.failed_rounds(tenant, opts)), unaccounted),
      costs:
        costs(
          rows(mod.session_costs(:llm, tenant, opts)),
          rows(mod.session_costs(:tool, tenant, opts))
        )
    )
  end

  defp load_tab(%{assigns: %{tab: :tools}} = socket, _probe, mod, tenant, opts) do
    rates = rows(mod.tool_rates(tenant, opts))

    assign(socket,
      tool_rows: rates,
      tool_totals: tool_totals(rates),
      guidance: guidance_reasons(rates),
      latency: rows(mod.tool_latency(tenant, opts)) |> Enum.take(10)
    )
  end

  defp load_tab(%{assigns: %{tab: :models}} = socket, _probe, mod, tenant, opts) do
    opts =
      opts
      |> maybe_opt(:provider, socket.assigns.filter_provider)
      |> maybe_opt(:entrypoint, socket.assigns.filter_entrypoint)

    overview = rows(mod.llm_overview(tenant, opts)) |> List.first() || %{}
    reliability_rows = rows(mod.llm_reliability(tenant, opts))
    speed = rows(mod.llm_speed(tenant, opts)) |> Enum.take(10)
    trend_rows = rows(mod.llm_trends(tenant, opts))

    {from, to, bucket} = {opts[:from], opts[:to], opts[:bucket_seconds]}

    assign(socket,
      metering?: metering_enabled?(),
      llm: overview,
      reliability: reliability(reliability_rows),
      speed: speed,
      llm_trend: llm_trend_series(trend_rows, from, to, bucket),
      providers: reliability_rows |> Enum.map(& &1["provider"]) |> Enum.uniq() |> Enum.sort(),
      entrypoints: reliability_rows |> Enum.map(& &1["entrypoint"]) |> Enum.uniq() |> Enum.sort()
    )
  end

  # The activity feed is the one read that may span every tenant: the
  # dashboard is deployment-scoped, and a cross-tenant lane view is how an
  # operator spots one slow model or one runaway session among all of them.
  # Names are resolved after shaping, once per distinct agent shown.
  defp load_tab(%{assigns: %{tab: :activity}} = socket, _probe, mod, tenant, opts) do
    scope = if socket.assigns.filter_tenants == "all", do: :all, else: tenant
    opts = opts ++ [limit: @activity_row_limit]

    opts =
      case socket.assigns.activity_before do
        ms when is_integer(ms) -> opts ++ [before: DateTime.from_unix!(ms, :millisecond)]
        _ -> opts
      end

    result = mod.activity_trace(scope, opts)

    timeline =
      result
      |> rows()
      |> ActivityTimeline.build(limit: @activity_row_limit, lanes: @activity_lanes)

    infos = agent_infos(Enum.map(timeline.lanes, & &1.agent_id))

    assign(socket,
      activity: timeline,
      activity_over_budget?: over_budget?(result),
      activity_all_tenants?: scope == :all,
      agent_names: Map.new(infos, fn {id, info} -> {id, info.name} end),
      agent_infos: infos,
      activity_roles: role_summary(timeline.lanes, infos),
      tenant_names:
        Map.new(socket.assigns.tenants, &{&1["tenant_id"], &1["name"] || &1["tenant_id"]})
    )
  end

  # Who did the work on this page: the Router's activations, the internal
  # workers' activations, and the external workers' sessions. An external
  # runtime's model calls happen off-platform and are never recorded here,
  # so for those only the proxied tool calls can be counted.
  defp role_summary(lanes, infos) do
    groups =
      Enum.group_by(lanes, fn lane ->
        info = Map.get(infos, lane.agent_id, %{role: nil, external?: false})

        cond do
          lane.kind == :session or info.external? -> :external
          info.role == "router" -> :router
          true -> :worker
        end
      end)

    for key <- [:router, :worker, :external] do
      group = Map.get(groups, key, [])
      segments = Enum.flat_map(group, & &1.segments)

      %{
        key: key,
        lanes: length(group),
        rounds: group |> Enum.map(& &1.rounds) |> Enum.sum(),
        llm_calls: Enum.count(segments, &(&1.kind == :llm)),
        tool_calls: Enum.count(segments, &(&1.kind == :tool)),
        agents: group |> Enum.map(& &1.agent_id) |> Enum.uniq() |> length()
      }
    end
  end

  defp role_label(:router), do: "Router"
  defp role_label(:worker), do: "Internal workers"
  defp role_label(:external), do: "External workers"

  defp role_value(%{key: :external, lanes: n}),
    do: "#{n} #{if n == 1, do: "session", else: "sessions"}"

  defp role_value(%{lanes: n}), do: "#{n} #{if n == 1, do: "activation", else: "activations"}"

  defp role_note(%{key: :external} = r),
    do:
      "#{r.tool_calls} tool calls across #{r.agents} agents · model calls run off-platform, not recorded"

  defp role_note(r),
    do:
      "#{r.rounds} rounds · #{r.llm_calls} model calls · #{r.tool_calls} tool calls · #{r.agents} agents"

  # LLM telemetry rides the metering pipeline: no metering module configured
  # means no rows will ever arrive, which deserves its own explanation
  # rather than an eternally empty chart.
  defp metering_enabled?, do: Application.get_env(:salix_agent, :llm_metering_mod) != nil

  # ============================== data shaping ==============================

  # Charts show the whole selected range: a bucket nothing ran in has no row,
  # and its rate is undefined rather than zero — it must read as a gap.
  defp bucket_series(rows, from, to, bucket) do
    by_key = Map.new(rows, &{&1["bucket"], &1})
    first = div(DateTime.to_unix(from), bucket) * bucket

    first
    |> Stream.iterate(&(&1 + bucket))
    |> Enum.take_while(&(&1 < DateTime.to_unix(to)))
    |> Enum.with_index()
    |> Enum.map(fn {unix, i} ->
      row = Map.get(by_key, bucket_key(unix), %{})
      rounds = num(row["rounds"])

      %{
        i: i,
        label: bucket_label(unix, bucket),
        unix_ms: unix * 1000,
        label_format: bucket_format(bucket),
        rounds: rounds,
        failed: num(row["failed"]),
        rate: pct(row["failed"], rounds),
        p50: fnum(row["p50_ms"]),
        p95: fnum(row["p95_ms"])
      }
    end)
  end

  defp llm_trend_series(rows, from, to, bucket) do
    overall =
      rows
      |> Enum.group_by(& &1["bucket"])
      |> Map.new(fn {key, bucket_rows} ->
        {key,
         %{
           "bucket" => key,
           "rounds" => Enum.sum(Enum.map(bucket_rows, &num(&1["calls"]))),
           "failed" => Enum.sum(Enum.map(bucket_rows, &num(&1["failed"])))
         }}
      end)
      |> Map.values()
      |> bucket_series(from, to, bucket)

    top_providers =
      rows
      |> Enum.group_by(& &1["provider"])
      |> Enum.map(fn {provider, provider_rows} ->
        {provider, Enum.sum(Enum.map(provider_rows, &num(&1["calls"])))}
      end)
      |> Enum.sort_by(&(-elem(&1, 1)))
      |> Enum.map(&elem(&1, 0))

    by_provider =
      rows
      |> Enum.filter(&(&1["provider"] in Enum.take(top_providers, 4)))
      |> Enum.group_by(& &1["provider"])
      |> Enum.map(fn {provider, provider_rows} ->
        by_key = Map.new(provider_rows, &{&1["bucket"], fnum(&1["p95_first_token_ms"])})
        first = div(DateTime.to_unix(from), bucket) * bucket

        points =
          first
          |> Stream.iterate(&(&1 + bucket))
          |> Enum.take_while(&(&1 < DateTime.to_unix(to)))
          |> Enum.with_index()
          |> Enum.map(fn {unix, i} -> %{i: i, value: Map.get(by_key, bucket_key(unix))} end)

        %{name: provider, points: points}
      end)
      |> Enum.sort_by(& &1.name)

    %{overall: overall, providers: by_provider, provider_overflow: length(top_providers) > 4}
  end

  # Unknown-time share per bucket, on the same epoch-aligned grid as the
  # round trends; `rounds` carries the activation count so the shared volume
  # bars and "nothing ran" gaps behave the same way.
  defp unknown_series(rows, from, to, bucket) do
    by_key = Map.new(rows, &{&1["bucket"], &1})
    first = div(DateTime.to_unix(from), bucket) * bucket

    first
    |> Stream.iterate(&(&1 + bucket))
    |> Enum.take_while(&(&1 < DateTime.to_unix(to)))
    |> Enum.with_index()
    |> Enum.map(fn {unix, i} ->
      row = Map.get(by_key, bucket_key(unix), %{})
      span = num(row["span_ms"])

      %{
        i: i,
        label: bucket_label(unix, bucket),
        unix_ms: unix * 1000,
        label_format: bucket_format(bucket),
        rounds: num(row["activations"]),
        span_ms: span,
        unknown_ms: num(row["unknown_ms"]),
        phase_ms: num(row["phase_ms"]),
        rate: pct(row["unknown_ms"], span),
        phase_rate: pct(row["phase_ms"], span)
      }
    end)
  end

  defp bucket_key(unix) do
    unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp bucket_label(unix, bucket),
    do: SalixWeb.Dashboard.LocalTime.utc_text(unix * 1000, bucket_format(bucket))

  defp bucket_format(bucket) when bucket >= 86_400, do: "month-day"
  defp bucket_format(_bucket), do: "month-day-time"

  # Merge the three per-revision aggregates; row order (and the Δ baseline)
  # comes from `revisions/3` — run terminals ordered by recency.
  defp deploys(mod, tenant, opts, revisions) do
    opts = Keyword.delete(opts, :app_revision)
    tool = rows(mod.deploy_rates(:tool, tenant, opts)) |> Map.new(&{&1["revision"], &1})
    llm = rows(mod.deploy_rates(:llm, tenant, opts)) |> Map.new(&{&1["revision"], &1})

    merged =
      Enum.map(revisions, fn row ->
        rev = row["revision"]
        tool_row = Map.get(tool, rev, %{})
        llm_row = Map.get(llm, rev, %{})
        rounds = num(row["rounds"])
        calls = num(tool_row["calls"]) + num(llm_row["calls"])

        %{
          revision: rev,
          rounds: rounds,
          rounds_failed: num(row["failed"]),
          tool_calls: num(tool_row["calls"]),
          tool_errors: num(tool_row["errors"]),
          llm_calls: num(llm_row["calls"]),
          llm_errors: num(llm_row["errors"]),
          # Too little traffic to judge: rates over a handful of calls read
          # as regressions when they're noise.
          low_volume?: rounds < 20 and calls < 50
        }
      end)

    # Δ compares each revision's round failure rate to the deploy before it
    # (the next row — rows are newest first). No verdict across grey rows.
    merged
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      prev = Enum.at(merged, idx + 1)

      delta =
        with %{low_volume?: false} <- row,
             %{low_volume?: false} = prev <- prev,
             rate when not is_nil(rate) <- pct(row.rounds_failed, row.rounds),
             prev_rate when not is_nil(prev_rate) <- pct(prev.rounds_failed, prev.rounds) do
          Float.round(rate - prev_rate, 1)
        else
          _ -> nil
        end

      Map.put(row, :delta, delta)
    end)
  end

  # Hard failures and silent stalls answer the same question — "which
  # session do I open right now?" — so they share one table.
  defp attention(failed_rounds, unaccounted) do
    failed =
      Enum.map(failed_rounds, fn row ->
        %{
          kind: :failed,
          status: row["status"],
          agent: row["salix_agent_id"],
          session: row["session_id"],
          at: row["observed_at"],
          revision: row["app_revision"],
          duration_ms: row["duration_ms"]
        }
      end)

    silent =
      Enum.map(unaccounted, fn row ->
        %{
          kind: :silent,
          status: "never_finished",
          agent: row["salix_agent_id"],
          session: row["session_id"],
          at: row["last_activity_at"],
          revision: nil,
          duration_ms: nil
        }
      end)

    (failed ++ silent)
    |> Enum.sort_by(&(&1.at || ""), :desc)
    |> Enum.take(20)
  end

  defp costs(llm_rows, tool_rows) do
    tool_by_session = Map.new(tool_rows, &{&1["session_id"], &1})

    base =
      Enum.map(llm_rows, fn row ->
        tool_row = Map.get(tool_by_session, row["session_id"], %{})

        %{
          session: row["session_id"],
          agent: row["salix_agent_id"],
          model_ms: num(row["duration_ms"]),
          tokens: num(row["tokens"]),
          rounds: num(row["rounds"]),
          tool_ms: num(tool_row["duration_ms"])
        }
      end)

    seen = MapSet.new(base, & &1.session)

    tool_only =
      tool_rows
      |> Enum.reject(&MapSet.member?(seen, &1["session_id"]))
      |> Enum.map(fn row ->
        %{
          session: row["session_id"],
          agent: row["salix_agent_id"],
          model_ms: 0,
          tokens: 0,
          rounds: nil,
          tool_ms: num(row["duration_ms"])
        }
      end)

    (base ++ tool_only)
    |> Enum.sort_by(&(-(&1.model_ms + &1.tool_ms)))
    |> Enum.take(15)
  end

  defp tool_totals(rates) do
    sum = fn key -> rates |> Enum.map(&num(&1[key])) |> Enum.sum() end
    completed = sum.("completed_calls")
    errors = sum.("error_calls")
    guidance = sum.("guidance_calls")

    %{
      calls: sum.("total_calls"),
      completed: completed,
      errors: errors,
      guidance: guidance,
      cancelled: sum.("cancelled_calls"),
      capped: sum.("capped_calls"),
      infra: completed + errors,
      sent_denom: completed + errors + guidance
    }
  end

  defp guidance_reasons(rates) do
    Enum.map(@guidance_reasons, fn {key, label, help} ->
      %{label: label, help: help, count: rates |> Enum.map(&num(&1[key])) |> Enum.sum()}
    end)
  end

  # Roll the outcome-split rows up to one row per (provider, model,
  # entrypoint), keeping the split for the expansion breakdown.
  defp reliability(rows) do
    rows
    |> Enum.group_by(&{&1["provider"], &1["model"], &1["entrypoint"]})
    |> Enum.map(fn {{provider, model, entrypoint}, group_rows} ->
      calls = Enum.sum(Enum.map(group_rows, &num(&1["calls"])))
      error_rows = Enum.filter(group_rows, &(&1["status"] == "error"))
      failed = Enum.sum(Enum.map(error_rows, &num(&1["calls"])))
      top = Enum.max_by(error_rows, &num(&1["calls"]), fn -> nil end)

      %{
        key: "#{provider}/#{model}/#{entrypoint}",
        provider: provider,
        model: model,
        entrypoint: entrypoint,
        calls: calls,
        failed: failed,
        retried: Enum.sum(Enum.map(group_rows, &num(&1["retried"]))),
        top_failure: top && {top["error_type"], top["http_status"]},
        errors: Enum.sort_by(error_rows, &(-num(&1["calls"])))
      }
    end)
    |> Enum.sort_by(&{-&1.failed, -&1.calls})
  end

  # ============================== render ==============================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-xl font-semibold">Runtime Health</h1>
        <p class="mt-1 text-sm text-neutral-500">
          Are agent rounds finishing — and if not, did it start with a deploy, a
          tool, or a model? Every anomaly here is one click from that session's
          timeline.
        </p>
        <p class="mt-1 text-xs text-neutral-400">
          Round endings are reported by internal sessions only; external sessions
          appear in tool and model numbers but never report an ending.
        </p>
      </div>

      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="inline-flex rounded-md border border-neutral-200 p-0.5" role="tablist">
          <.link
            :for={{tab, label} <- tabs()}
            patch={tab_path(tab, current_query(assigns))}
            role="tab"
            aria-selected={to_string(@tab == tab)}
            class={[
              "rounded px-3 py-1 text-sm font-medium transition-colors",
              @tab == tab && "bg-neutral-100 text-neutral-900",
              @tab != tab && "text-neutral-500 hover:text-neutral-700"
            ]}
          >
            {label}
          </.link>
        </div>

        <form id="runtime-filters" phx-change="filter" class="flex flex-wrap items-end gap-3">
          <.select
            name="range"
            label="Range"
            value={@range}
            options={Enum.map(ranges(), fn {key, label, _, _} -> {label, key} end)}
            class="w-40"
          />
          <.select
            name="group"
            label="Group"
            value={@filter_group}
            prompt="All groups"
            options={Enum.map(@groups, &{&1["name"], &1["group_id"]})}
            class="w-48"
          />
          <.select
            name="rev"
            label="App revision"
            value={@filter_rev}
            prompt="All revisions"
            options={
              @revisions
              |> Enum.map(& &1["revision"])
              |> Enum.reject(&(&1 == ""))
              |> Enum.map(&{Format.short_id(&1), &1})
            }
            class="w-44"
          />
          <%= if @tab == :activity and @configured? and not @loading? do %>
            <.select
              name="tenants"
              label="Tenants"
              value={@filter_tenants}
              options={[{"This tenant", ""}, {"All tenants", "all"}]}
              class="w-36"
            />
          <% end %>
          <%= if @tab == :models and @configured? and not @loading? do %>
            <.select
              name="provider"
              label="Provider"
              value={@filter_provider}
              prompt="All providers"
              options={Enum.map(@providers, &{&1, &1})}
              class="w-40"
            />
            <.select
              name="entrypoint"
              label="Called from"
              value={@filter_entrypoint}
              prompt="Everywhere"
              options={Enum.map(@entrypoints, &{&1, &1})}
              class="w-40"
            />
          <% end %>
        </form>
      </div>

      <.empty_state
        :if={!@configured?}
        icon="chart-bar"
        title="ClickHouse not configured"
        description="Set salix_analytics clickhouse_url to enable runtime telemetry aggregation."
      />

      <div
        :if={@over_budget?}
        class="rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-800"
      >
        This window has too much data to aggregate within the read budget.
        Narrow the time range (or filter to a group) to load these metrics.
      </div>

      <div
        :if={@loading?}
        id="runtime-loading"
        class="rounded-lg border border-neutral-200 px-4 py-6 text-sm text-neutral-500"
      >
        Loading runtime telemetry…
      </div>

      <.overview_tab :if={@configured? and not @loading? and @tab == :overview} {assigns} />
      <.tools_tab :if={@configured? and not @loading? and @tab == :tools} {assigns} />
      <.models_tab :if={@configured? and not @loading? and @tab == :models} {assigns} />
      <.activity_tab :if={@configured? and not @loading? and @tab == :activity} {assigns} />
    </div>
    """
  end

  defp tabs, do: @tabs
  defp ranges, do: @ranges

  # ============================== activity tab ==============================

  defp activity_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <style>
        .act-timeline { container-type: inline-size; min-width: 0; }
        .act-scroll { overflow-x: auto; }
        .act-table { min-width: 20rem; padding-bottom: 8rem; }
        .act-row { display: grid; grid-template-columns: minmax(0, 1fr); }
        .act-label { overflow-wrap: anywhere; }
        .act-axis > div:first-child { display: none; }
        @container (min-width: 40rem) {
          .act-row { grid-template-columns: 18rem minmax(20rem, 1fr); }
          .act-axis > div:first-child { display: block; }
        }
        .act-seg { position: absolute; top: 6px; height: 26px; line-height: 24px; border: 1px solid; border-radius: 4px; font-size: 11px; cursor: default; }
        .act-txt { display: block; padding: 0 4px; white-space: nowrap; overflow: hidden; }
        /* A collapsed lane draws every track on one row, so the order matters:
           calls over phases, phases over the unrecorded stretches. Hover keeps
           winning — one class beats none of these. */
        .act-layer-unknown { z-index: 1; }
        .act-layer-phase { z-index: 2; }
        .act-layer-tool { z-index: 3; }
        .act-layer-call { z-index: 4; }
        .act-seg:hover, .act-seg:focus { z-index: 40; filter: brightness(0.96); }
        .act-tip { display: none; position: absolute; top: 30px; left: 0; z-index: 50; width: 220px; overflow-wrap: anywhere; padding: 6px 8px; border-radius: 4px; background: #171717; color: #fafafa; font-size: 11px; line-height: 1.35; white-space: normal; box-shadow: 0 4px 12px rgba(0,0,0,.25); pointer-events: none; }
        .act-tip div:first-child { font-weight: 600; }
        .act-seg:hover .act-tip, .act-seg:focus .act-tip { display: block; }
        /* 2px clear on the right. A block ending at 100% is still at least as
           wide as its own 1px borders, so a sliver there sticks ~2px past the
           lane; the scrollport counts that and grows a horizontal scrollbar
           over nothing. */
        .act-lane { position: relative; height: 38px; margin-right: 2px; }
        .act-lane-session { background: repeating-linear-gradient(90deg, transparent 0 8px, #f5f5f4 8px 16px); border-radius: 4px; }
        /* Utility classes are no use here: the dashboard stylesheet is a
           prebuilt artifact and a class it has never seen renders as nothing. */
        .act-fold { display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; margin-top: 2px; padding: 0; border: 1px solid #e5e5e5; border-radius: 4px; background: #fff; color: #737373; cursor: pointer; }
        .act-fold:hover { color: #171717; background: #f5f5f5; border-color: #d4d4d4; }
        .act-fold svg { width: 12px; height: 12px; }
      </style>

      <div>
        <p class="text-sm text-neutral-600">
          <span :if={is_nil(@activity_before)}>The newest {@activity.summary.lanes} activations</span>
          <span :if={@activity_before}>{@activity.summary.lanes} activations that started before <.local_time ms={@activity_before} /></span>{if @activity_all_tenants?, do: " across all tenants", else: ""},
          one lane each. An activation is everything the agent did for one input: the model
          calls, the tool calls, the runtime's own recorded phases between them, and whatever
          is left over, positioned by start time. The calls and the unknown stretches between
          them take the top tracks of every lane, so they line up, and the runtime's phases sit
          underneath. Concurrent work uses separate tracks; collapse a lane to put every track
          on one row instead, with the calls drawn over the phases. Hover any block.
          <span :if={@activity.summary.session_lanes > 0}>
            Striped lanes are external worker sessions: {@activity.summary.session_lanes}
            here, drawn from their tool calls only, because an external runtime's model
            calls are never recorded on this side.
          </span>
        </p>
        <div class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-3" data-roles="1">
          <.stat
            :for={role <- @activity_roles}
            label={role_label(role.key)}
            value={role_value(role)}
            note={role_note(role)}
          />
        </div>
        <div class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.stat
            label="Unknown time"
            value={if @activity.summary.unknown_pct, do: "#{@activity.summary.unknown_pct}%", else: "—"}
            note={"#{@activity.summary.between_pct || 0}% between rounds + #{@activity.summary.gap_pct || 0}% inside rounds + #{@activity.summary.settle_pct || 0}% finishing unrecorded"}
          />
          <.stat
            label="Model calls"
            value={@activity.summary.llm_calls}
            note={"#{@activity.summary.llm_slow} slow · #{@activity.summary.llm_failed} failed · #{@activity.summary.llm_stale} stale"}
          />
          <.stat
            label="Tool calls"
            value={@activity.summary.tool_calls}
            note={"#{@activity.summary.tool_failed} broke"}
          />
          <.stat
            label="Longest unknown stretch"
            value={longest_unknown_value(@activity.summary.longest_unknown)}
            note={longest_unknown_note(@activity.summary.longest_unknown)}
          />
        </div>
        <.activity_breakdown summary={@activity.summary} />
        <p class="mt-2 text-xs text-neutral-400">
          Unknown = wall clock of the lanes shown that no record covers. The runtime records
          its own phases around each model call — activation (waking the session), preparing
          the call, storing the reply, storing tool results, closing the round, finishing,
          and settling a background tool's result (picking it up, storing it, the next
          round's config) — so
          what is left as unknown is scheduling wait between rounds, space between two records
          of one round, and rounds whose ending has no finishing record (older builds).
        </p>
      </div>

      <div
        :if={@activity_over_budget?}
        class="rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-800"
      >
        The activity feed for this window exceeded the read budget. Narrow the time range
        or filter to a group.
      </div>

      <.card>
        <:title>Activations</:title>
        <div class="space-y-3">
          <div class="flex justify-end">
            <button
              :if={@activity.lanes != []}
              type="button"
              phx-click="toggle_activity_detail"
              data-activity-detail={to_string(@activity_detail?)}
              title={
                if @activity_detail?,
                  do: "Put every lane's tracks on one row, calls on top",
                  else: "Give every record its own track again"
              }
              class="rounded border border-neutral-300 px-2 py-1 text-xs text-neutral-700 hover:bg-neutral-50"
            >
              {if @activity_detail?, do: "Collapse all lanes", else: "Expand all lanes"}
            </button>
          </div>

          <.activity_legend />

          <p :if={@activity.lanes == [] and is_nil(@activity_before)} class="text-sm text-neutral-500">
            No model or tool calls recorded in this window.
          </p>
          <p :if={@activity.lanes == [] and @activity_before} class="text-sm text-neutral-500">
            No older activations in this window.
          </p>

          <div :if={@activity.lanes != []} class="act-timeline">
            <div id="activity-scroll" phx-hook="ActivityTooltip" class="act-scroll" role="region" aria-label="Activation timeline" tabindex="0">
              <div class="act-table">
            <.activity_axis scale_ms={@activity.scale_ms} />
            <.activity_lane
              :for={lane <- @activity.lanes}
              lane={lane}
              detail?={lane_detail?(assigns, lane)}
              scale_ms={@activity.scale_ms}
              agent_names={@agent_names}
              agent_infos={@agent_infos}
              tenant_names={@tenant_names}
              show_tenant={@activity_all_tenants?}
            />
              </div>
            </div>
          </div>

          <.activity_pager
            :if={@activity_before || @activity.more?}
            before={@activity_before}
            more?={@activity.more?}
            older_path={activity_page_path(assigns, {:older, @activity.next_before_ms})}
            newer_path={activity_page_path(assigns, :newer)}
          />

          <p class="text-xs text-neutral-400">
            Lanes are sorted newest first and each starts at its own first record, so widths
            compare but positions don't. Rounds of one session are joined into one activation
            by the runtime's activation key when their phase rows carry one
            ({@activity.summary.keyed} of {@activity.summary.lanes} lanes here); rounds without
            it are joined when the earlier round recorded no ending and the next started within
            two minutes. An activation longer than {fmt_ms(@activity.cap_ms)} wraps onto more
            rows at the same scale (each marked "↳ from …"); nothing is cut.
            Cancelled background tool calls never report.
            <span :if={@activity.truncated?}>
              The feed hit its row limit; the oldest activation was dropped because it may be
              incomplete — it is the first one on the next page.
            </span>
            <span :if={@activity_before}>
              An activation straddling the page boundary shows only the rounds that started
              before it.
            </span>
            <span :if={@activity.summary.session_lanes > 0}>
              An external worker session is placed by its latest call and shows the calls on
              this page; when it says so, its earlier calls continue on the next page.
            </span>
          </p>
        </div>
      </.card>
    </div>
    """
  end

  defp activity_legend(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-x-4 gap-y-1 text-xs text-neutral-600">
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:llm, :ok)}></span>
        model call
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:llm, :warn)}></span>
        slow (over 60s; or, when the fetched sample has 5+ calls of the same model, in the slowest 10% of
        them and over twice their typical time)
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:llm, :error)}></span>
        failed
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:llm, :stale)}></span>
        stale (response discarded: newer input arrived; not counted as slow)
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:tool, :ok)}></span>
        tool call
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:compaction, :ok)}></span>
        compaction model call (not preparation or commit)
      </span>
      <span :for={phase <- ActivityTimeline.drawn_phases()} class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={phase_style_attrs(phase)}></span>
        {String.downcase(ActivityTimeline.phase_title(phase))}
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:between, :none)}></span>
        between rounds (unknown)
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:gap, :none)}></span>
        inside a round (unknown)
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-5 rounded border" style={segment_style_attrs(:settle, :none)}></span>
        finishing, unrecorded (unknown)
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="act-lane-session inline-block h-3 w-5 rounded border border-neutral-200"></span>
        external worker session (tool calls only; no rounds, no unknown)
      </span>
    </div>
    """
  end

  attr(:summary, :map, required: true)

  # Where the wall clock of the lanes shown went, as one stacked bar: the
  # calls, the recorded phases, and what is still unknown.
  defp activity_breakdown(assigns) do
    # Exclusive wall-clock shares: every moment counted once (model call
    # first, then runtime phases, then tools), so the bar never exceeds
    # the lanes even when records overlap.
    wall = assigns.summary.wall

    parts =
      [
        {"compaction model calls", wall.compaction_pct, segment_style_attrs(:compaction, :ok)},
        {"model calls", wall.llm_pct, segment_style_attrs(:llm, :ok)},
        {"tool calls", wall.tool_pct, segment_style_attrs(:tool, :ok)},
        {"waiting for activation", wall.delivery_pct, phase_style_attrs("delivery_wait")},
        {"miniskill selection", wall.miniskill_pct, phase_style_attrs("miniskill")},
        {"activation", wall.activation_pct, phase_style_attrs("activation")},
        {"preparing", wall.prepare_pct, phase_style_attrs("prepare")},
        {"storing replies and results", wall.commit_pct, phase_style_attrs("tool_commit")},
        {"finishing", wall.finalize_pct, phase_style_attrs("finalize")},
        {"settling background results", wall.async_pct, phase_style_attrs("async_commit")},
        # Solid grey here: the dashed "unknown" outline of the lanes has no
        # body to show in a bar.
        {"unknown", wall.unknown_pct, "background:#a3a3a3"}
      ]
      |> Enum.map(fn {label, pct, style} -> {label, pct || 0.0, style} end)

    assigns =
      assign(assigns,
        parts: parts,
        any?: assigns.summary.total_ms > 0,
        overlap_ms: wall.parallel_ms
      )

    ~H"""
    <div :if={@any?} class="mt-3" data-breakdown="1">
      <p class="mb-1 text-xs text-neutral-500">
        Where the time of these lanes went, as shares of their total length
        <span :if={@overlap_ms > 0} class="text-neutral-400">
          · Every second is counted once. {fmt_ms(@overlap_ms)} had two or more concurrent records (a background tool call running during a model call, for example);
          such a second counts as the model call, or the runtime phase if no model call was
          running, or else the tool.
        </span>
      </p>
      <div class="flex h-4 w-full overflow-hidden rounded border border-neutral-200">
        <div
          :for={{label, pct, style} <- @parts}
          :if={pct > 0}
          style={"width:#{pct}%;#{style};border-width:0;border-radius:0"}
          title={"#{label} #{pct}%"}
        >
        </div>
      </div>
      <p class="mt-1 text-xs text-neutral-500">
        <span :for={{label, pct, _style} <- @parts} class="mr-3">{label} {pct}%</span>
      </p>
    </div>
    """
  end

  attr(:scale_ms, :integer, required: true)

  defp activity_axis(assigns) do
    ~H"""
    <div class="act-row act-axis text-[10px] text-neutral-400 tabular-nums">
      <div></div>
      <div class="relative h-4 border-b border-neutral-200">
        <span
          :for={tick <- [0, 25, 50, 75]}
          class="absolute top-0 whitespace-nowrap"
          style={"left:#{tick}%"}
        >
          {fmt_ms(div(@scale_ms * tick, 100))}
        </span>
        <span class="absolute right-0 top-0 whitespace-nowrap">{fmt_ms(@scale_ms)}</span>
      </div>
    </div>
    """
  end

  attr(:lane, :map, required: true)
  attr(:scale_ms, :integer, required: true)
  attr(:detail?, :boolean, required: true)
  attr(:agent_names, :map, required: true)
  attr(:agent_infos, :map, required: true)
  attr(:tenant_names, :map, required: true)
  attr(:show_tenant, :boolean, required: true)

  defp activity_lane(assigns) do
    rows = ActivityTimeline.rows(assigns.lane, assigns.scale_ms)
    rows = if assigns.detail?, do: rows, else: Enum.map(rows, &collapse_row/1)
    last = rows |> List.last() |> then(&(&1 && &1.index))

    # The label is decided here, not in the template: a block too narrow to
    # hold text gets no span at all. An empty one is not free — it still
    # takes its 4px of side padding, an 8px box inside a 3px sliver.
    rows =
      Enum.map(rows, fn row ->
        segments =
          Enum.map(row.segments, &Map.put(&1, :text, segment_text(&1, assigns.scale_ms)))

        Map.merge(row, %{segments: segments, last?: row.index == last})
      end)

    assigns = assign(assigns, rows: rows)

    ~H"""
    <div
      :for={row <- @rows}
      class={["act-row", row.last? && "border-b border-neutral-100"]}
      data-lane={row.index == 0 && @lane.lane_id}
      data-lane-kind={row.index == 0 && @lane.kind}
      data-lane-row={row.index}
    >
      <div :if={row.index == 0} class="min-w-0 py-1 pr-3 text-xs leading-tight">
        <div class="act-label">
          <span :if={@show_tenant} class="text-neutral-400">
            {Map.get(@tenant_names, @lane.tenant_id, @lane.tenant_id)} ·
          </span>
          <.link navigate={"/dash/agents/#{@lane.agent_id}"} class="font-medium text-neutral-800 hover:underline">
            {Map.get(@agent_names, @lane.agent_id, @lane.agent_id)}
          </.link>
        </div>
        <div class="act-label font-mono text-[10px] text-neutral-500">
          <.link
            navigate={"/dash/agents/#{@lane.agent_id}/sessions/#{@lane.session_id}#timeline"}
            class="hover:underline"
            title={"session #{@lane.session_id}"}
          >
            <.local_time ms={@lane.start_ms} format="time-seconds" />
            · ses {tail_id(@lane.session_id)}
            <span :if={@lane.kind == :activation}>
              · {@lane.rounds} {if @lane.rounds == 1, do: "round", else: "rounds"}
            </span>
            <span :if={@lane.kind == :session}>
              · {@lane.calls} {if @lane.calls == 1, do: "call", else: "calls"}
            </span>
          </.link>
        </div>
        <div class="act-label text-[10px]">
          <span class="text-neutral-500">{fmt_ms(@lane.total_ms)} ·</span>
          <span :if={@lane.kind == :session} class="text-neutral-500">
            {session_lane_label(@lane, @agent_infos)}
          </span>
          <span :if={@lane.kind == :session and @lane.partial?} class="text-neutral-400">
            · earlier calls on the next page
          </span>
          <span :if={@lane.kind == :activation and @lane.terminal} class={terminal_class(@lane.terminal)}>
            {terminal_label(@lane.terminal)}
          </span>
          <span :if={@lane.kind == :activation and is_nil(@lane.terminal)} class="text-neutral-400">
            no ending recorded
          </span>
        </div>
        <button
          type="button"
          phx-click="toggle_activity_lane"
          phx-value-lane={@lane.lane_id}
          data-lane-detail={to_string(@detail?)}
          aria-expanded={to_string(@detail?)}
          aria-label={if @detail?, do: "Collapse this lane", else: "Expand this lane"}
          title={if @detail?, do: "Collapse", else: "Expand"}
          class="act-fold"
        >
          <svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
            <path
              d={if @detail?, do: "M4 6.5l4 4 4-4", else: "M6.5 4l4 4-4 4"}
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </button>
      </div>
      <%!-- A wrapped continuation: the same activation, the next stretch of
           the scale, like the next line of a paragraph. --%>
      <div :if={row.index > 0} class="min-w-0 py-1 pr-3 text-right text-[10px] text-neutral-400">
        ↳ from {fmt_ms(row.from_ms)}
        <span :if={row[:skipped_ms] && row.skipped_ms > 0}>
          · {fmt_ms(row.skipped_ms)} without calls folded away
        </span>
      </div>
      <div
        class={["act-lane", @lane.kind == :session && "act-lane-session"]}
        style={"height:#{row.tracks * 30 + 8}px"}
        data-tracks={row.tracks}
      >
        <%!-- Concurrent records have separate tracks at their real offsets. --%>
        <div
          :for={seg <- row.segments}
          class={["act-seg", segment_layer(seg)]}
          style={segment_style(seg, @scale_ms)}
          tabindex="0"
          aria-label={Enum.join(seg.tooltip, "; ")}
          title={Enum.join(seg.tooltip, " · ")}
          data-track={seg.track}
          data-segment={seg.kind}
          data-phase={seg.phase}
        >
          <span :if={seg.text != ""} class="act-txt">{seg.text}</span>
          <div class="act-tip">
            <div :for={line <- seg.tooltip}>{line}</div>
            <div :if={seg[:continued?]} class="text-neutral-400">(continued from the row above)</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # A collapsed lane keeps every record and puts them all on one row.
  # Nothing is dropped: what overlaps now overlaps on screen, and the
  # stylesheet's stacking order draws the calls over the phases, so a
  # lane reads as one strip of calls with the runtime's work behind it.
  defp collapse_row(row) do
    %{row | segments: Enum.map(row.segments, &Map.put(&1, :track, 0)), tracks: 1}
  end

  # The page has a default and a lane may differ from it.
  defp lane_detail?(assigns, lane) do
    Map.get(assigns.activity_lane_detail, lane.lane_id, assigns.activity_detail?)
  end

  # A session lane's calls came without a round. From an external runtime
  # that is the normal shape; from an internal agent it would mean calls
  # recorded outside any round, which is worth saying as such.
  defp session_lane_label(lane, infos) do
    case {Enum.any?(lane.segments, &(&1.kind == :compaction)), Map.get(infos, lane.agent_id)} do
      {true, _} ->
        "compaction recorded without a matching activation on this page"

      {false, %{external?: true}} ->
        "external worker: tool calls only, its model runs off-platform"

      _ ->
        "tool calls recorded outside any round"
    end
  end

  # Below this share of the lane a block can't fit even a short duration;
  # the text goes, the hover card stays.
  @min_text_pct 5.0

  defp segment_text(seg, scale_ms) do
    cond do
      seg[:continued?] -> ""
      ActivityTimeline.pct(seg.duration_ms, scale_ms) >= @min_text_pct -> seg.label
      true -> ""
    end
  end

  # Which layer a block is drawn in. It only matters once a lane is
  # collapsed and every track shares one row: the calls must stay legible
  # over the runtime's phases, and a phase over the unrecorded stretches.
  defp segment_layer(%{kind: kind}) when kind in [:llm, :compaction], do: "act-layer-call"
  defp segment_layer(%{kind: :tool}), do: "act-layer-tool"
  defp segment_layer(%{kind: :phase}), do: "act-layer-phase"
  defp segment_layer(_seg), do: "act-layer-unknown"

  defp segment_style(seg, scale_ms) do
    left = ActivityTimeline.pct(seg.offset_ms, scale_ms)
    width = max(ActivityTimeline.pct(seg.duration_ms, scale_ms), 0.4)
    # Never overflow the row: rows/2 already split at the boundary, this
    # only absorbs rounding.
    width = min(width, max(100.0 - left, 0.0))
    "left:#{left}%;width:#{width}%;top:#{6 + seg.track * 30}px;#{segment_style_attrs(seg)}"
  end

  defp segment_style_attrs(%{kind: :phase, phase: phase}), do: phase_style_attrs(phase)

  defp segment_style_attrs(%{kind: kind, severity: severity}),
    do: segment_style_attrs(kind, severity)

  # Recorded phases: cool colours, one family per phase, so they read as
  # "the runtime working" next to the warm call colours.
  defp phase_style_attrs("delivery_wait"),
    do: "background:#f1f5f9;border-color:#64748b;color:#334155"

  defp phase_style_attrs("activation"),
    do: "background:#dbeafe;border-color:#2563eb;color:#1e3a8a"

  defp phase_style_attrs("miniskill"), do: "background:#ede9fe;border-color:#7c3aed;color:#4c1d95"

  defp phase_style_attrs("prepare"), do: "background:#e0f2fe;border-color:#0284c7;color:#0c4a6e"

  defp phase_style_attrs(commit) when commit in ~w(response_commit tool_commit boundary),
    do: "background:#e0e7ff;border-color:#4f46e5;color:#312e81"

  defp phase_style_attrs("finalize"), do: "background:#ccfbf1;border-color:#0d9488;color:#134e4a"

  # Settling a background tool's result: fuchsia, the one warm-leaning
  # runtime family, because on staging it is the largest runtime stretch.
  defp phase_style_attrs(async) when async in ~w(async_pickup async_commit async_config),
    do: "background:#fae8ff;border-color:#c026d3;color:#701a75"

  defp phase_style_attrs(_other), do: "background:#f5f5f5;border-color:#a3a3a3;color:#525252"

  # Inline colours rather than utility classes: the dashboard CSS is a
  # prebuilt artifact and a class it has never seen renders as nothing.
  defp segment_style_attrs(:llm, :ok), do: "background:#bbf7d0;border-color:#16a34a;color:#14532d"

  defp segment_style_attrs(:compaction, :ok),
    do: "background:#f3e8ff;border-color:#9333ea;color:#581c87"

  defp segment_style_attrs(:tool, :ok),
    do: "background:#fef08a;border-color:#ca8a04;color:#713f12"

  # Orange, not amber: a slow call has to read differently from the yellow
  # tool blocks next to it.
  defp segment_style_attrs(_kind, :warn),
    do: "background:#fdba74;border-color:#c2410c;color:#7c2d12"

  defp segment_style_attrs(_kind, :stale),
    do: "background:#ede9fe;border-color:#7c3aed;color:#4c1d95"

  defp segment_style_attrs(_kind, :error),
    do: "background:#fecaca;border-color:#dc2626;color:#7f1d1d"

  defp segment_style_attrs(:between, _),
    do: "background:#f5f5f5;border-color:#525252;border-style:dashed;color:#404040"

  defp segment_style_attrs(:gap, _),
    do: "background:#ffffff;border-color:#737373;border-style:dashed;color:#525252"

  defp segment_style_attrs(:settle, _),
    do: "background:#e5e5e5;border-color:#a3a3a3;color:#525252"

  defp segment_style_attrs(_kind, _severity), do: "background:#f5f5f5;border-color:#a3a3a3"

  defp longest_unknown_value(nil), do: "—"
  defp longest_unknown_value(%{ms: ms}), do: fmt_ms(ms)

  defp longest_unknown_note(nil), do: "nothing unrecorded in view"

  defp longest_unknown_note(%{kind: kind, lane: lane}) do
    assigns = %{
      where: longest_unknown_where(kind),
      session: tail_id(lane.session_id),
      start_ms: lane.start_ms
    }

    ~H"""
    {@where}, in ses {@session} at <.local_time ms={@start_ms} format="time-seconds" />
    """
  end

  defp longest_unknown_where(:between), do: "between rounds"
  defp longest_unknown_where(:gap), do: "inside a round"
  defp longest_unknown_where(:settle), do: "finishing"

  defp terminal_label("completed"), do: "finished"
  defp terminal_label("llm_failed"), do: "model failed"
  defp terminal_label("actor_failed"), do: "agent failed"
  defp terminal_label("repair_failed"), do: "would not call a tool when one was required"
  defp terminal_label("runaway_guard_parked"), do: "stopped: kept going without progress"
  defp terminal_label("repeated_tool_result_parked"), do: "stopped: same tool result repeated"

  defp terminal_label("input_round_budget_parked"),
    do: "stopped: used up its round budget for one input"

  defp terminal_label(other), do: to_string(other)

  defp terminal_class("completed"), do: "text-emerald-700"
  defp terminal_class(_), do: "text-red-700"

  defp tail_id(id) when is_binary(id) and byte_size(id) > 8, do: "…" <> String.slice(id, -8, 8)
  defp tail_id(id), do: to_string(id)

  # Paging is navigation, so the cursor lives in the URL: a page can be
  # reloaded or shared, and changing any filter (a fresh query from the
  # form) drops it. The cursor is never carried onto another tab.
  # The two moves: "Older" pushes this page's cursor onto the trail and
  # cuts at the oldest lane shown; "Newer" pops the trail (an empty trail
  # means the page before this one is the newest). There is no "Newest":
  # opening the tab afresh is the newest page.
  defp activity_page_path(assigns, :newest), do: tab_path(:activity, current_query(assigns))

  defp activity_page_path(assigns, {:older, before_ms}) do
    trail = assigns.activity_trail ++ List.wrap(assigns.activity_before)
    tab_path(:activity, current_query(assigns) ++ cursor_query(before_ms, trail))
  end

  defp activity_page_path(assigns, :newer) do
    case Enum.split(assigns.activity_trail, -1) do
      {_rest, []} ->
        activity_page_path(assigns, :newest)

      {rest, [previous]} ->
        tab_path(:activity, current_query(assigns) ++ cursor_query(previous, rest))
    end
  end

  defp cursor_query(before_ms, []), do: [{"before", before_ms}]

  defp cursor_query(before_ms, trail),
    do: [{"before", before_ms}, {"trail", Enum.map_join(trail, ".", &to_string/1)}]

  attr(:before, :any, required: true)
  attr(:more?, :boolean, required: true)
  attr(:older_path, :string, required: true)
  attr(:newer_path, :string, required: true)

  defp activity_pager(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 text-xs text-neutral-500" data-pager>
      <span :if={@before}>Showing activations that started before <.local_time ms={@before} />.</span>
      <span :if={is_nil(@before)}>Older activations in this range are on the next page.</span>
      <div class="flex gap-2">
        <.link
          :if={@before}
          patch={@newer_path}
          class="rounded border border-neutral-300 px-2 py-1 text-neutral-700 hover:bg-neutral-50"
        >
          ← Newer
        </.link>
        <.link
          :if={@more?}
          patch={@older_path}
          class="rounded border border-neutral-300 px-2 py-1 text-neutral-700 hover:bg-neutral-50"
        >
          Older →
        </.link>
      </div>
    </div>
    """
  end

  # ============================== overview tab ==============================

  defp overview_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.stat label="Rounds ended" value={num(@outcomes["rounds"])} note="one row per finished round" />
          <.stat
            label="Finished cleanly"
            value={num(@outcomes["completed"])}
            note="produced a result"
          />
          <.stat
            label="Did not finish"
            value={failed_total(@outcomes)}
            note={outcome_breakdown(@outcomes)}
          />
          <.stat
            label="Sessions unaccounted for"
            value={length(@unaccounted)}
            note="active 15+ min then went silent — internal sessions only"
          />
        </div>
        <p class="mt-2 text-xs text-neutral-400">
          The math adds up: <span class="text-neutral-500 font-medium">rounds ended = finished + did not finish</span>
          ({num(@outcomes["rounds"])} = {num(@outcomes["completed"])} + {failed_total(@outcomes)}).
          Retries fold into one model-call row; guidance replies don't count as failures —
          the tool worked, the agent misused it.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <.card>
          <:title>Rounds failing, over time</:title>
          <p class="mb-3 text-xs text-neutral-500">
            Of the rounds that ended in each period, how many failed before producing
            a result? Bars show how many rounds ran — a bad hour with three rounds is
            not a bad hour with three hundred.
          </p>
          <p :if={total_rounds(@trend) == 0} class="text-sm text-neutral-500">
            No rounds ended in this range.
          </p>
          <.rate_chart :if={total_rounds(@trend) > 0} series={@trend} />
        </.card>

        <.card>
          <:title>Round duration trend</:title>
          <p class="mb-3 text-xs text-neutral-500">
            How long a full round takes — typical (p50, solid) and worst-case (p95,
            dashed). A rising worst-case with a flat typical means a few rounds are
            dragging, not all of them.
          </p>
          <p :if={total_rounds(@trend) == 0} class="text-sm text-neutral-500">
            No rounds ended in this range.
          </p>
          <.duration_chart :if={total_rounds(@trend) > 0} series={@trend} />
        </.card>

        <.card class="xl:col-span-2">
          <:title>Time nothing accounts for, over time</:title>
          <p class="mb-3 text-xs text-neutral-500">
            Of everything the agents did for each input (model calls, tool calls, the
            runtime's own recorded phases), the share of wall clock that no record covers —
            scheduling waits between rounds, space between records, endings without a
            finishing record. A rising line means the runtime is losing time somewhere
            telemetry cannot see; the Activity tab shows where. The share is a floor:
            records that overlap (a background tool under a model call) all count as
            covered, so the true unknown share is at least what is drawn.
          </p>
          <p :if={total_rounds(@unknown_trend) == 0} class="text-sm text-neutral-500">
            No activations recorded in this range.
          </p>
          <.unknown_chart :if={total_rounds(@unknown_trend) > 0} series={@unknown_trend} />
        </.card>

        <.card class="xl:col-span-2">
          <:title>Where the trouble is</:title>
          <p class="mb-3 text-xs text-neutral-500">
            The same headline numbers as the Tools and Models tabs — click through to
            see which tool or which provider.
          </p>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <.door
              label="Tool calls breaking"
              row={@doors.tool}
              href={tab_path(:tools, current_query(assigns))}
              go="Tools"
            />
            <.door
              label="Model calls failing"
              row={@doors.llm}
              href={tab_path(:models, current_query(assigns))}
              go="Models"
            />
          </div>
        </.card>

        <.card class="xl:col-span-2">
          <:title>Error rate by deploy</:title>
          <p class="mb-3 text-xs text-neutral-500">
            The same failure rates, split by which build of the app was running. If a
            rate jumps at one revision, start with that deploy's changes. Grey rows ran
            too little to judge.
          </p>
          <p :if={@deploys == []} class="text-sm text-neutral-500">
            No deploys recorded telemetry in this range.
          </p>
          <div :if={@deploys != []} class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                  <th class="py-1 pr-3 font-medium">Revision</th>
                  <th class="py-1 pr-3 text-right font-medium">Rounds failed</th>
                  <th class="py-1 pr-3 text-right font-medium">Tool errors</th>
                  <th class="py-1 pr-3 text-right font-medium">Model errors</th>
                  <th class="py-1 text-right font-medium">Δ vs previous</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @deploys}
                  class={["border-t border-neutral-100", row.low_volume? && "text-neutral-400"]}
                  title={row.low_volume? && "too few calls to judge"}
                >
                  <td class="py-1.5 pr-3">
                    <span class="font-mono text-xs">{rev_label(row.revision)}</span>
                    <.badge :if={row.revision == app_revision()} color="brand" class="ml-1">
                      current
                    </.badge>
                  </td>
                  <td class="py-1.5 pr-3 text-right tabular-nums">
                    {rate_cell(row.rounds_failed, row.rounds)}
                  </td>
                  <td class="py-1.5 pr-3 text-right tabular-nums">
                    {rate_cell(row.tool_errors, row.tool_calls)}
                  </td>
                  <td class="py-1.5 pr-3 text-right tabular-nums">
                    {rate_cell(row.llm_errors, row.llm_calls)}
                  </td>
                  <td class="py-1.5 text-right tabular-nums">
                    <span :if={row.delta && row.delta > 0} class="text-red-600">▲ +{row.delta}pt</span>
                    <span :if={row.delta && row.delta < 0} class="text-emerald-600">▼ {row.delta}pt</span>
                    <span :if={row.delta == 0} class="text-neutral-400">—</span>
                    <span :if={is_nil(row.delta)} class="text-neutral-300">—</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card class="xl:col-span-2">
          <:title>Runs needing attention</:title>
          <p class="mb-3 text-xs text-neutral-500">
            Rounds that ended in an error, plus sessions that were mid-work and then
            went silent for 15+ minutes. Internal sessions only — external sessions
            never report endings, so their absence here means nothing. Click a session
            to see its timeline.
          </p>
          <p :if={@attention == []} class="text-sm text-neutral-500">
            Nothing needs attention in this range.
          </p>
          <div :if={@attention != []} class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                  <th class="py-1 pr-3 font-medium">Agent</th>
                  <th class="py-1 pr-3 font-medium">Session</th>
                  <th class="py-1 pr-3 font-medium">What happened</th>
                  <th class="py-1 pr-3 font-medium">When</th>
                  <th class="py-1 pr-3 font-medium">Deploy</th>
                  <th class="py-1 text-right font-medium">Duration</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @attention} class="border-t border-neutral-100">
                  <td class="py-1.5 pr-3"><.agent_link agent={row.agent} /></td>
                  <td class="py-1.5 pr-3"><.session_link agent={row.agent} session={row.session} /></td>
                  <td class="py-1.5 pr-3"><.attention_badge status={row.status} /></td>
                  <td class="py-1.5 pr-3 font-mono text-xs text-neutral-500">
                    {ch_time_ago(row.at)}<span :if={row.kind == :silent}> (silent since)</span>
                  </td>
                  <td class="py-1.5 pr-3 font-mono text-xs text-neutral-500">
                    {rev_label(row.revision)}
                  </td>
                  <td class="py-1.5 text-right tabular-nums">{fmt_ms(row.duration_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card class="xl:col-span-2">
          <:title>Slowest and most expensive sessions</:title>
          <p class="mb-3 text-xs text-neutral-500">
            Where the time actually went, per session. Model time includes retry
            waits; background tool calls can overlap, so tool time can exceed the
            clock. Click through to see the timeline of any one.
          </p>
          <p :if={@costs == []} class="text-sm text-neutral-500">
            No session activity in this range.
          </p>
          <div :if={@costs != []} class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                  <th class="py-1 pr-3 font-medium">Session</th>
                  <th class="py-1 pr-3 font-medium">Agent</th>
                  <th class="py-1 pr-3 font-medium">Model time</th>
                  <th class="py-1 pr-3 font-medium">Tool time</th>
                  <th class="py-1 pr-3 text-right font-medium">Rounds</th>
                  <th class="py-1 text-right font-medium">Tokens</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @costs} class="border-t border-neutral-100">
                  <td class="py-1.5 pr-3"><.session_link agent={row.agent} session={row.session} /></td>
                  <td class="py-1.5 pr-3"><.agent_link agent={row.agent} /></td>
                  <td class="py-1.5 pr-3">
                    <.mini_bar value={row.model_ms} max={max_cost(@costs, :model_ms)} color="#6366f1" label={fmt_ms(row.model_ms)} />
                  </td>
                  <td class="py-1.5 pr-3">
                    <.mini_bar value={row.tool_ms} max={max_cost(@costs, :tool_ms)} color="#14b8a6" label={fmt_ms(row.tool_ms)} />
                  </td>
                  <td class="py-1.5 pr-3 text-right tabular-nums">{row.rounds || "—"}</td>
                  <td class="py-1.5 text-right tabular-nums text-neutral-400">
                    {fmt_tokens(row.tokens)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </div>
    """
  end

  # Everything that did not end cleanly. Subtracting keeps the identity this
  # page prints true for any status the runtime adds later. Summing named
  # failure counts instead would drop a status nobody remembered to add.
  defp failed_total(outcomes),
    do: max(num(outcomes["rounds"]) - num(outcomes["completed"]), 0)

  # Name every way a round ended other than cleanly. A guard park stops a
  # loop on purpose, so it reads apart from an actor that crashed.
  defp outcome_breakdown(outcomes) do
    named = [
      {"model failed", num(outcomes["llm_failed"])},
      {"agent failed", num(outcomes["actor_failed"])},
      {"no tool call", num(outcomes["repair_failed"])},
      {"stopped by a guard", num(outcomes["parked"])}
    ]

    # Whatever the named counts leave over still shows. A status the runtime
    # adds without updating this page lands here instead of disappearing.
    other = failed_total(outcomes) - Enum.sum(Enum.map(named, &elem(&1, 1)))

    (named ++ [{"ended another way", max(other, 0)}])
    |> Enum.filter(fn {_label, count} -> count > 0 end)
    |> case do
      [] -> "every round finished"
      parts -> Enum.map_join(parts, " · ", fn {label, count} -> "#{count} #{label}" end)
    end
  end

  defp total_rounds(trend), do: trend |> Enum.map(& &1.rounds) |> Enum.sum()

  defp max_cost(costs, key), do: costs |> Enum.map(&Map.fetch!(&1, key)) |> Enum.max(fn -> 0 end)

  defp app_revision, do: SalixAgent.AppRevision.value()

  defp rev_label(nil), do: "—"
  defp rev_label(""), do: "unknown"
  defp rev_label(rev), do: Format.short_id(rev)

  attr(:label, :string, required: true)
  attr(:row, :map, default: nil)
  attr(:href, :string, required: true)
  attr(:go, :string, required: true)

  # Amber only when the current window is genuinely worse than the previous
  # equal-length one — a rate over a handful of calls is noise, not a signal.
  defp door(assigns) do
    row = assigns.row || %{}
    rate = pct(row["errors"], row["calls"])
    prev_rate = pct(row["prev_errors"], row["prev_calls"])
    worse? = rate != nil and prev_rate != nil and rate > prev_rate

    assigns = assign(assigns, rate: rate, prev_rate: prev_rate, worse?: worse?, r: row)

    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center justify-between gap-3 rounded-lg border p-4 transition-colors",
        @worse? && "border-amber-300 bg-amber-50 hover:bg-amber-100",
        !@worse? && "border-neutral-200 bg-white hover:bg-neutral-50"
      ]}
    >
      <div>
        <p class="text-xs text-neutral-500">{@label}</p>
        <p class="mt-0.5 text-lg font-semibold tabular-nums">
          {if @rate, do: "#{@rate}%", else: "—"}
          <span class="text-xs font-normal text-neutral-500">of {num(@r["calls"])} calls</span>
        </p>
        <p class="text-xs" style={@worse? && "color:#b45309"}>
          <span :if={@worse?}>▲ was {@prev_rate}% in the previous window</span>
          <span :if={!@worse?} class="text-neutral-400">
            {if @prev_rate, do: "was #{@prev_rate}% in the previous window", else: "no previous-window data"}
          </span>
        </p>
      </div>
      <span class="text-sm font-medium text-brand-600">{@go} →</span>
    </.link>
    """
  end

  attr(:status, :string, required: true)

  defp attention_badge(assigns) do
    {label, color} =
      case assigns.status do
        "llm_failed" -> {"model failed", "red"}
        "actor_failed" -> {"agent failed", "red"}
        "repair_failed" -> {"no tool call", "red"}
        "never_finished" -> {"never finished", "amber"}
        status when status in @parked_statuses -> {terminal_label(status), "amber"}
        other -> {other, "neutral"}
      end

    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <.badge color={@color}>{@label}</.badge>
    """
  end

  # ============================== tools tab ==============================

  defp tools_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.stat label="Calls" value={@tool_totals.calls} note="every tool call that finished" />
          <.stat
            label="Broke"
            value={rate_cell(@tool_totals.errors, @tool_totals.infra)}
            note="the tool itself failed"
          />
          <.stat
            label="Sent back"
            value={rate_cell(@tool_totals.guidance, @tool_totals.sent_denom)}
            note="never ran — the agent was corrected"
          />
          <.stat
            label="Results cut short"
            value={@tool_totals.capped}
            note="a slice of Broke — output hit a size cap"
          />
        </div>
        <p class="mt-2 text-xs text-neutral-400">
          <span class="text-neutral-500 font-medium">calls = worked + broke + sent back (+ cancelled)</span>
          <span class="tabular-nums">{"(#{@tool_totals.calls} = #{@tool_totals.completed} + #{@tool_totals.errors} + #{@tool_totals.guidance} + #{@tool_totals.cancelled})"}</span>.
          Cancelled background calls never report, so cancelled counts are a floor, not a total.
        </p>
      </div>

      <.card>
        <:title>Per-tool scoreboard</:title>
        <p class="mb-3 text-xs text-neutral-500">
          One row per tool, worst first. A tool with many broke calls needs fixing; a
          tool with many sent-back calls is being called wrongly. Click a row for its
          error types and hardest-hit sessions.
        </p>
        <p :if={@tool_rows == []} class="text-sm text-neutral-500">
          No tool calls in this range.
        </p>
        <div :if={@tool_rows != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                <th class="py-1 pr-3 font-medium">Tool</th>
                <th class="py-1 pr-3 font-medium">Source</th>
                <th class="py-1 pr-3 text-right font-medium">Calls</th>
                <th class="py-1 pr-3 text-right font-medium" title="completed / (completed + broke)">
                  Worked
                </th>
                <th class="py-1 pr-3 text-right font-medium" title="the tool itself failed">Broke</th>
                <th class="py-1 text-right font-medium" title="never ran — the agent was corrected">
                  Sent back
                </th>
              </tr>
            </thead>
            <tbody>
              <%= for row <- Enum.take(@tool_rows, 20) do %>
                <tr
                  class="cursor-pointer border-t border-neutral-100 hover:bg-neutral-50"
                  phx-click="expand_tool"
                  phx-value-tool={row["tool_name"]}
                >
                  <td class="py-1.5 pr-3 font-mono text-xs">{row["tool_name"]}</td>
                  <td class="py-1.5 pr-3"><.badge>{row["tool_source"]}</.badge></td>
                  <td class="py-1.5 pr-3 text-right tabular-nums">{num(row["total_calls"])}</td>
                  <td class="py-1.5 pr-3 text-right tabular-nums">
                    {rate_cell(row["completed_calls"], infra(row))}
                  </td>
                  <td class={["py-1.5 pr-3 text-right tabular-nums", num(row["error_calls"]) > 0 && "text-red-600"]}>
                    {rate_cell(row["error_calls"], infra(row))}
                  </td>
                  <td class={["py-1.5 text-right tabular-nums", num(row["guidance_calls"]) > 0 && "text-amber-600"]}>
                    {rate_cell(row["guidance_calls"], sent_denom(row))}
                  </td>
                </tr>
                <tr :if={@expanded_tool == row["tool_name"] and @tool_drill} class="bg-neutral-50">
                  <td colspan="6" class="px-3 py-2">
                    <div class="flex flex-wrap gap-8 text-xs">
                      <div>
                        <p class="mb-1 font-medium uppercase tracking-wide text-neutral-400">
                          Error types
                        </p>
                        <p :if={@tool_drill.errors == []} class="text-neutral-400">no errors</p>
                        <p :for={err <- @tool_drill.errors} class="tabular-nums">
                          <span class="font-mono">{err["error_type"]}</span>
                          <span class="text-neutral-500">×{num(err["calls"])}</span>
                        </p>
                      </div>
                      <div>
                        <p class="mb-1 font-medium uppercase tracking-wide text-neutral-400">
                          Sessions hit hardest
                        </p>
                        <p :if={@tool_drill.sessions == []} class="text-neutral-400">none</p>
                        <p :for={sess <- @tool_drill.sessions}>
                          <.session_link agent={sess["salix_agent_id"]} session={sess["session_id"]} />
                          <span class="text-neutral-500">×{num(sess["calls"])}</span>
                        </p>
                      </div>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </.card>

      <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <.card>
          <:title>Sent-back reasons</:title>
          <p class="mb-3 text-xs text-neutral-500">
            Why calls were sent back instead of run. The first two are the model
            getting the call wrong; the last two are usually setup problems on our
            side.
          </p>
          <p :if={@tool_totals.guidance == 0} class="text-sm text-neutral-500">
            Nothing was sent back in this range.
          </p>
          <div :if={@tool_totals.guidance > 0} class="space-y-2">
            <div :for={reason <- @guidance} class="flex items-center gap-3">
              <span class="w-56 truncate text-xs cursor-help" title={reason.help}>
                {reason.label}
              </span>
              <div class="h-2 flex-1 rounded-full bg-neutral-100">
                <div
                  class="h-2 rounded-full"
                  style={"width:#{bar_width(reason.count, max_guidance(@guidance))};background:#f59e0b"}
                >
                </div>
              </div>
              <span class="w-10 text-right text-xs tabular-nums">{reason.count}</span>
            </div>
          </div>
          <p class="mt-3 text-xs text-neutral-400">
            The first two are agent behavior —
            <.link navigate="/dash/trajectory-evals" class="text-brand-600 hover:underline">
              see behavior signals →
            </.link>
          </p>
        </.card>

        <.card>
          <:title>Slowest tools</:title>
          <p class="mb-3 text-xs text-neutral-500">
            Half of calls finish under the first number; 95 in 100 under the second.
            Timed only while the tool ran. Background (async) calls are timed
            differently, so they get their own rows — and a cancelled background call
            leaves no record.
          </p>
          <p :if={@latency == []} class="text-sm text-neutral-500">
            No tool calls in this range.
          </p>
          <div :if={@latency != []} class="space-y-2">
            <div :for={row <- @latency} class="flex items-center gap-3 text-xs">
              <span class="w-44 truncate font-mono">
                {row["tool_name"]}
                <.badge :if={row["async"] in [true, 1, "true"]} color="brand" class="ml-1">
                  async
                </.badge>
              </span>
              <div class="flex-1 space-y-0.5">
                <div class="h-1.5 rounded-full bg-neutral-100">
                  <div
                    class="h-1.5 rounded-full"
                    style={"width:#{bar_width(fnum(row["p50_ms"]) || 0, max_latency(@latency))};background:#6366f1"}
                  >
                  </div>
                </div>
                <div class="h-1.5 rounded-full bg-neutral-100">
                  <div
                    class="h-1.5 rounded-full opacity-50"
                    style={"width:#{bar_width(fnum(row["p95_ms"]) || 0, max_latency(@latency))};background:#6366f1"}
                  >
                  </div>
                </div>
              </div>
              <span class="w-28 text-right tabular-nums text-neutral-600">
                {fmt_ms(row["p50_ms"])} / {fmt_ms(row["p95_ms"])}
              </span>
            </div>
            <p class="text-xs text-neutral-400">top bar: typical (p50) · bottom bar: slowest 5% (p95)</p>
          </div>
        </.card>
      </div>
    </div>
    """
  end

  defp infra(row), do: num(row["completed_calls"]) + num(row["error_calls"])
  defp sent_denom(row), do: infra(row) + num(row["guidance_calls"])

  defp max_guidance(reasons), do: reasons |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)

  defp max_latency(latency),
    do: latency |> Enum.map(&(fnum(&1["p95_ms"]) || 0)) |> Enum.max(fn -> 0 end)

  # ============================== models tab ==============================

  defp models_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <.empty_state
        :if={!@metering?}
        icon="chart-bar"
        title="LLM metering not enabled"
        description="Model-call telemetry rides the metering pipeline. Configure salix_agent llm_metering_mod to record provider latency and errors."
      />

      <div :if={@metering?} class="space-y-6">
        <div>
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <.stat label="Calls" value={num(@llm["calls"])} note="retries fold into one row" />
            <.stat
              label="Failed"
              value={rate_cell(@llm["failed"], @llm["calls"])}
              note="after all retries"
            />
            <.stat
              label="Needed retries"
              value={rate_cell(@llm["retried"], @llm["calls"])}
              note="a leading indicator — shows up before failures do"
            />
            <.stat
              label="First word (p95)"
              value={fmt_ms(@llm["p95_first_token_ms"])}
              note="streaming calls only"
            />
          </div>
          <p class="mt-2 text-xs text-neutral-400">
            Total call time includes retry waits;
            <span class="text-neutral-500 font-medium">failed means failed for good</span>.
          </p>
        </div>

        <.card>
          <:title>Reliability by provider and model</:title>
          <p class="mb-3 text-xs text-neutral-500">
            One row per provider + model + place it's called from. Rate limits mean
            we're pushing too hard; timeouts and server errors mean the provider is
            struggling. Click a row for the full failure breakdown.
          </p>
          <p :if={@reliability == []} class="text-sm text-neutral-500">
            No model calls in this range.
          </p>
          <div :if={@reliability != []} class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                  <th class="py-1 pr-3 font-medium">Provider</th>
                  <th class="py-1 pr-3 font-medium">Model</th>
                  <th class="py-1 pr-3 font-medium">Called from</th>
                  <th class="py-1 pr-3 text-right font-medium">Calls</th>
                  <th class="py-1 pr-3 text-right font-medium">Failed</th>
                  <th class="py-1 pr-3 text-right font-medium">Retried</th>
                  <th class="py-1 font-medium">Top failure</th>
                </tr>
              </thead>
              <tbody>
                <%= for row <- @reliability do %>
                  <tr
                    class="cursor-pointer border-t border-neutral-100 hover:bg-neutral-50"
                    phx-click="expand_model"
                    phx-value-key={row.key}
                  >
                    <td class="py-1.5 pr-3">{row.provider}</td>
                    <td class="py-1.5 pr-3 font-mono text-xs">{row.model}</td>
                    <td class="py-1.5 pr-3"><.badge>{row.entrypoint}</.badge></td>
                    <td class="py-1.5 pr-3 text-right tabular-nums">{row.calls}</td>
                    <td class={["py-1.5 pr-3 text-right tabular-nums", row.failed > 0 && "text-red-600"]}>
                      {rate_cell(row.failed, row.calls)}
                    </td>
                    <td class="py-1.5 pr-3 text-right tabular-nums">
                      {rate_cell(row.retried, row.calls)}
                    </td>
                    <td class="py-1.5">
                      <.badge :if={row.top_failure} color="red">{failure_label(row.top_failure)}</.badge>
                      <span :if={!row.top_failure} class="text-xs text-neutral-400">—</span>
                    </td>
                  </tr>
                  <tr :if={@expanded_model == row.key} class="bg-neutral-50">
                    <td colspan="7" class="px-3 py-2">
                      <p :if={row.errors == []} class="text-xs text-neutral-400">
                        no failures for this row
                      </p>
                      <p :for={err <- row.errors} class="text-xs tabular-nums">
                        <span class="font-mono">{err["error_type"]}</span>
                        <span :if={err["http_status"]} class="text-neutral-500">
                          (http {err["http_status"]})
                        </span>
                        <span class="text-neutral-500">×{num(err["calls"])}</span>
                      </p>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.card>

        <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
          <.card>
            <:title>Speed by provider and model</:title>
            <p class="mb-3 text-xs text-neutral-500">
              Total time includes retries and the waiting between them. First word is
              how long before the model started answering — it isolates provider
              slowness from answer length. Blank for calls that don't stream.
            </p>
            <p :if={@speed == []} class="text-sm text-neutral-500">
              No model calls in this range.
            </p>
            <div :if={@speed != []} class="space-y-3">
              <div :for={row <- @speed} class="text-xs">
                <p class="mb-0.5 font-mono">
                  {row["provider"]} · {row["model"]}
                  <.badge class="ml-1">{row["entrypoint"]}</.badge>
                </p>
                <div class="flex items-center gap-3">
                  <div class="flex-1 space-y-0.5">
                    <div class="h-1.5 rounded-full bg-neutral-100">
                      <div
                        class="h-1.5 rounded-full"
                        style={"width:#{bar_width(fnum(row["p50_ms"]) || 0, max_speed(@speed))};background:#6366f1"}
                      >
                      </div>
                    </div>
                    <div class="h-1.5 rounded-full bg-neutral-100">
                      <div
                        class="h-1.5 rounded-full opacity-50"
                        style={"width:#{bar_width(fnum(row["p95_ms"]) || 0, max_speed(@speed))};background:#6366f1"}
                      >
                      </div>
                    </div>
                    <div class="h-1.5 rounded-full bg-neutral-100">
                      <div
                        class="h-1.5 rounded-full"
                        style={"width:#{bar_width(fnum(row["p95_first_token_ms"]) || 0, max_speed(@speed))};background:#f59e0b"}
                      >
                      </div>
                    </div>
                  </div>
                  <span class="w-40 text-right tabular-nums text-neutral-600">
                    {fmt_ms(row["p50_ms"])} / {fmt_ms(row["p95_ms"])} ·
                    {if num(row["streaming_calls"]) > 0, do: fmt_ms(row["p95_first_token_ms"]), else: "—"}
                  </span>
                </div>
              </div>
              <p class="text-xs text-neutral-400">
                bars: typical (p50) · slowest 5% (p95) · first word p95 (amber)
              </p>
            </div>
          </.card>

          <.card>
            <:title>Failures and responsiveness over time</:title>
            <p class="mb-3 text-xs text-neutral-500">
              Of each period's model calls, how many failed for good — and how quickly
              each provider started answering. Bars show call volume.
            </p>
            <p :if={total_rounds(@llm_trend.overall) == 0} class="text-sm text-neutral-500">
              No model calls in this range.
            </p>
            <div :if={total_rounds(@llm_trend.overall) > 0} class="space-y-4">
              <.rate_chart series={@llm_trend.overall} />
              <div>
                <p class="mb-1 text-xs font-medium text-neutral-500">
                  First word p95, per provider
                </p>
                <.provider_chart providers={@llm_trend.providers} />
                <div class="mt-1 flex flex-wrap gap-3 text-xs text-neutral-500">
                  <span :for={{provider, idx} <- Enum.with_index(@llm_trend.providers)}>
                    <span
                      class="mr-1 inline-block h-0.5 w-4 align-middle"
                      style={"background:#{provider_color(idx)}"}
                    >
                    </span>
                    {provider.name}
                  </span>
                </div>
                <p :if={@llm_trend.provider_overflow} class="mt-1 text-xs text-neutral-400">
                  More than 4 providers in range — use the Provider filter to see the rest.
                </p>
              </div>
            </div>
          </.card>
        </div>
      </div>
    </div>
    """
  end

  defp max_speed(speed),
    do: speed |> Enum.map(&(fnum(&1["p95_ms"]) || 0)) |> Enum.max(fn -> 0 end)

  defp failure_label({error_type, nil}), do: error_type
  defp failure_label({error_type, http}), do: "#{error_type} · #{http}"

  # ============================== shared pieces ==============================

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:note, :any, default: nil)

  defp stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-neutral-200 bg-white p-4">
      <p class="text-xs text-neutral-500">{@label}</p>
      <p class="mt-1 text-2xl font-semibold tabular-nums">{@value}</p>
      <p :if={@note} class="mt-0.5 text-xs text-neutral-400">{@note}</p>
    </div>
    """
  end

  attr(:agent, :string, default: nil)

  defp agent_link(assigns) do
    ~H"""
    <.link
      :if={@agent not in [nil, ""]}
      navigate={"/dash/agents/#{@agent}"}
      class="font-mono text-xs text-brand-600 hover:underline"
    >
      {Format.short_id(@agent)}
    </.link>
    <span :if={@agent in [nil, ""]} class="font-mono text-xs text-neutral-400">—</span>
    """
  end

  attr(:agent, :string, default: nil)
  attr(:session, :string, default: nil)

  defp session_link(assigns) do
    ~H"""
    <.link
      :if={@agent not in [nil, ""] and @session not in [nil, ""]}
      navigate={"/dash/agents/#{@agent}/sessions/#{@session}#timeline"}
      class="font-mono text-xs text-brand-600 hover:underline"
    >
      {Format.short_id(@session)}
    </.link>
    <span :if={@agent in [nil, ""] or @session in [nil, ""]} class="font-mono text-xs text-neutral-400">
      {Format.short_id(@session) || "—"}
    </span>
    """
  end

  attr(:value, :any, required: true)
  attr(:max, :any, required: true)
  attr(:color, :string, required: true)
  attr(:label, :string, required: true)

  defp mini_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <div class="h-2 w-24 rounded-full bg-neutral-100">
        <div class="h-2 rounded-full" style={"width:#{bar_width(@value, @max)};background:#{@color}"}>
        </div>
      </div>
      <span class="text-xs tabular-nums text-neutral-600">{@label}</span>
    </div>
    """
  end

  defp bar_width(value, max) do
    case fnum(max) || 0 do
      m when m <= 0 -> "0%"
      m -> "#{Float.round((fnum(value) || 0) * 100 / m, 1)}%"
    end
  end

  # ============================== charts ==============================
  #
  # Same server-rendered SVG grammar as the Trajectory Evals trend chart:
  # a fixed 0..1000 × 0..100 plot space stretched freely, strokes kept
  # visually constant via non-scaling-stroke, all text as HTML around the
  # SVG, gaps (buckets nothing ran in) breaking the line instead of diving
  # to zero, and a hover column per bucket carrying the exact counts.
  # Colors are SVG presentation attributes, not Tailwind classes — the
  # prebuilt dashboard CSS doesn't regenerate on beam hot-reload, and a
  # missing utility class silently drops the whole line.

  @plot_w 1000
  @plot_h 100

  attr(:series, :list, required: true)

  defp rate_chart(assigns) do
    points = assigns.series
    n = length(points)
    defined = Enum.reject(points, &is_nil(&1.rate))
    ceiling = rate_ceiling(defined)
    segs = segments(points, & &1.rate)

    assigns =
      assign(assigns,
        n: n,
        ceiling: ceiling,
        max_volume: points |> Enum.map(& &1.rounds) |> Enum.max(fn -> 0 end),
        lines: Enum.filter(segs, &(length(&1) > 1)),
        dots: segs |> Enum.filter(&match?([_], &1)) |> List.flatten(),
        ticks: x_ticks(points)
      )

    ~H"""
    <div>
      <div class="relative pl-9">
        <div class="absolute left-0 top-0 h-24 w-8 text-right text-[10px] leading-none text-neutral-400 tabular-nums">
          <span class="absolute right-0 top-0 -translate-y-1/2">{@ceiling}%</span>
          <span class="absolute right-0 top-1/2 -translate-y-1/2">{pct_half(@ceiling)}</span>
          <span class="absolute right-0 bottom-0 translate-y-1/2">0%</span>
        </div>
        <div class="relative">
          <svg
            viewBox="0 0 1000 100"
            preserveAspectRatio="none"
            class="block h-24 w-full overflow-visible"
            role="img"
            aria-label="failure rate over time"
          >
            <line
              :for={y <- [0, 50, 100]}
              x1="0"
              x2="1000"
              y1={y}
              y2={y}
              stroke="#e5e5e5"
              stroke-width="1"
              vector-effect="non-scaling-stroke"
            />
            <polyline
              :for={seg <- @lines}
              points={poly_points(seg, @n, @ceiling, & &1.rate)}
              fill="none"
              stroke="#f59e0b"
              stroke-width="1.75"
              stroke-linecap="round"
              stroke-linejoin="round"
              vector-effect="non-scaling-stroke"
            />
            <line
              :for={p <- @dots}
              data-dot="1"
              x1={cx(p.i, @n)}
              x2={cx(p.i, @n)}
              y1={cy(p.rate, @ceiling)}
              y2={cy(p.rate, @ceiling)}
              stroke="#f59e0b"
              stroke-width="5"
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
            />
          </svg>
          <.volume_bars series={@series} n={@n} max={@max_volume} />
          <div class="absolute inset-0 flex">
            <div
              :for={p <- @series}
              class="flex-1"
              title={rate_tooltip(p)}
              data-local-time-ms={p.unix_ms}
              data-local-time-format={p.label_format}
              data-local-time-title-template={rate_tooltip(%{p | label: "%s"})}
            >
            </div>
          </div>
        </div>
        <.x_axis ticks={@ticks} />
      </div>
    </div>
    """
  end

  attr(:series, :list, required: true)

  # The rate chart's twin for unknown-time share: same grid, same volume
  # bars (activations), its own colour and hover text.
  defp unknown_chart(assigns) do
    points = assigns.series
    n = length(points)
    defined = Enum.reject(points, &is_nil(&1.rate))
    ceiling = rate_ceiling(defined)
    segs = segments(points, & &1.rate)

    assigns =
      assign(assigns,
        n: n,
        ceiling: ceiling,
        max_volume: points |> Enum.map(& &1.rounds) |> Enum.max(fn -> 0 end),
        lines: Enum.filter(segs, &(length(&1) > 1)),
        dots: segs |> Enum.filter(&match?([_], &1)) |> List.flatten(),
        ticks: x_ticks(points)
      )

    ~H"""
    <div>
      <div class="relative pl-9">
        <div class="absolute left-0 top-0 h-24 w-8 text-right text-[10px] leading-none text-neutral-400 tabular-nums">
          <span class="absolute right-0 top-0 -translate-y-1/2">{@ceiling}%</span>
          <span class="absolute right-0 top-1/2 -translate-y-1/2">{pct_half(@ceiling)}</span>
          <span class="absolute right-0 bottom-0 translate-y-1/2">0%</span>
        </div>
        <div class="relative">
          <svg
            viewBox="0 0 1000 100"
            preserveAspectRatio="none"
            class="block h-24 w-full overflow-visible"
            role="img"
            aria-label="unknown time share over time"
          >
            <line
              :for={y <- [0, 50, 100]}
              x1="0"
              x2="1000"
              y1={y}
              y2={y}
              stroke="#e5e5e5"
              stroke-width="1"
              vector-effect="non-scaling-stroke"
            />
            <polyline
              :for={seg <- @lines}
              points={poly_points(seg, @n, @ceiling, & &1.rate)}
              fill="none"
              stroke="#4f46e5"
              stroke-width="1.75"
              stroke-linecap="round"
              stroke-linejoin="round"
              vector-effect="non-scaling-stroke"
            />
            <line
              :for={p <- @dots}
              data-dot="1"
              x1={cx(p.i, @n)}
              x2={cx(p.i, @n)}
              y1={cy(p.rate, @ceiling)}
              y2={cy(p.rate, @ceiling)}
              stroke="#4f46e5"
              stroke-width="5"
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
            />
          </svg>
          <.volume_bars series={@series} n={@n} max={@max_volume} />
          <div class="absolute inset-0 flex">
            <div
              :for={p <- @series}
              class="flex-1"
              title={unknown_tooltip(p)}
              data-local-time-ms={p.unix_ms}
              data-local-time-format={p.label_format}
              data-local-time-title-template={unknown_tooltip(%{p | label: "%s"})}
            >
            </div>
          </div>
        </div>
        <.x_axis ticks={@ticks} />
      </div>
    </div>
    """
  end

  attr(:series, :list, required: true)

  defp duration_chart(assigns) do
    points = assigns.series
    n = length(points)
    defined = Enum.reject(points, &is_nil(&1.p95))
    ceiling = ms_ceiling(defined)

    p50_segs = segments(points, & &1.p50)
    p95_segs = segments(points, & &1.p95)

    assigns =
      assign(assigns,
        n: n,
        ceiling: ceiling,
        max_volume: points |> Enum.map(& &1.rounds) |> Enum.max(fn -> 0 end),
        p50_lines: Enum.filter(p50_segs, &(length(&1) > 1)),
        p95_lines: Enum.filter(p95_segs, &(length(&1) > 1)),
        # An isolated bucket has no segment to ride on — without its own
        # mark the whole chart can render empty on sparse data.
        p50_dots: p50_segs |> Enum.filter(&match?([_], &1)) |> List.flatten(),
        p95_dots: p95_segs |> Enum.filter(&match?([_], &1)) |> List.flatten(),
        ticks: x_ticks(points)
      )

    ~H"""
    <div>
      <div class="relative pl-9">
        <div class="absolute left-0 top-0 h-24 w-8 text-right text-[10px] leading-none text-neutral-400 tabular-nums">
          <span class="absolute right-0 top-0 -translate-y-1/2">{fmt_ms(@ceiling)}</span>
          <span class="absolute right-0 top-1/2 -translate-y-1/2">{fmt_ms(@ceiling / 2)}</span>
          <span class="absolute right-0 bottom-0 translate-y-1/2">0</span>
        </div>
        <div class="relative">
          <svg
            viewBox="0 0 1000 100"
            preserveAspectRatio="none"
            class="block h-24 w-full overflow-visible"
            role="img"
            aria-label="round duration over time"
          >
            <line
              :for={y <- [0, 50, 100]}
              x1="0"
              x2="1000"
              y1={y}
              y2={y}
              stroke="#e5e5e5"
              stroke-width="1"
              vector-effect="non-scaling-stroke"
            />
            <polyline
              :for={seg <- @p95_lines}
              points={poly_points(seg, @n, @ceiling, & &1.p95)}
              fill="none"
              stroke="#6366f1"
              stroke-width="1.5"
              stroke-dasharray="5 4"
              vector-effect="non-scaling-stroke"
            />
            <polyline
              :for={seg <- @p50_lines}
              points={poly_points(seg, @n, @ceiling, & &1.p50)}
              fill="none"
              stroke="#6366f1"
              stroke-width="1.75"
              stroke-linecap="round"
              stroke-linejoin="round"
              vector-effect="non-scaling-stroke"
            />
            <line
              :for={p <- @p95_dots}
              data-dot="1"
              x1={cx(p.i, @n)}
              x2={cx(p.i, @n)}
              y1={cy(p.p95, @ceiling)}
              y2={cy(p.p95, @ceiling)}
              stroke="#6366f1"
              stroke-width="4"
              stroke-linecap="round"
              opacity="0.55"
              vector-effect="non-scaling-stroke"
            />
            <line
              :for={p <- @p50_dots}
              data-dot="1"
              x1={cx(p.i, @n)}
              x2={cx(p.i, @n)}
              y1={cy(p.p50, @ceiling)}
              y2={cy(p.p50, @ceiling)}
              stroke="#6366f1"
              stroke-width="5"
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
            />
          </svg>
          <.volume_bars series={@series} n={@n} max={@max_volume} />
          <div class="absolute inset-0 flex">
            <div
              :for={p <- @series}
              class="flex-1"
              title={duration_tooltip(p)}
              data-local-time-ms={p.unix_ms}
              data-local-time-format={p.label_format}
              data-local-time-title-template={duration_tooltip(%{p | label: "%s"})}
            >
            </div>
          </div>
        </div>
        <.x_axis ticks={@ticks} />
      </div>
    </div>
    """
  end

  attr(:providers, :list, required: true)

  defp provider_chart(assigns) do
    all_points = Enum.flat_map(assigns.providers, & &1.points)
    n = assigns.providers |> Enum.map(&length(&1.points)) |> Enum.max(fn -> 0 end)
    defined = all_points |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1)
    ceiling = ms_ceiling(Enum.map(defined, &%{p95: &1}))

    assigns = assign(assigns, n: n, ceiling: ceiling)

    ~H"""
    <svg
      viewBox="0 0 1000 100"
      preserveAspectRatio="none"
      class="block h-16 w-full overflow-visible"
      role="img"
      aria-label="first-word p95 per provider"
    >
      <line
        :for={y <- [0, 100]}
        x1="0"
        x2="1000"
        y1={y}
        y2={y}
        stroke="#e5e5e5"
        stroke-width="1"
        vector-effect="non-scaling-stroke"
      />
      <%= for {provider, idx} <- Enum.with_index(@providers) do %>
        <polyline
          :for={seg <- provider.points |> segments(& &1.value) |> Enum.filter(&(length(&1) > 1))}
          points={poly_points(seg, @n, @ceiling, & &1.value)}
          fill="none"
          stroke={provider_color(idx)}
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke"
        />
        <line
          :for={
            [p] <-
              provider.points |> segments(& &1.value) |> Enum.filter(&match?([_], &1))
          }
          data-dot="1"
          x1={cx(p.i, @n)}
          x2={cx(p.i, @n)}
          y1={cy(p.value, @ceiling)}
          y2={cy(p.value, @ceiling)}
          stroke={provider_color(idx)}
          stroke-width="4"
          stroke-linecap="round"
          vector-effect="non-scaling-stroke"
        />
      <% end %>
    </svg>
    """
  end

  attr(:series, :list, required: true)
  attr(:n, :integer, required: true)
  attr(:max, :any, required: true)

  defp volume_bars(assigns) do
    ~H"""
    <svg
      viewBox="0 0 1000 26"
      preserveAspectRatio="none"
      class="mt-1.5 block h-4 w-full overflow-visible"
      aria-hidden="true"
    >
      <rect
        :for={p <- @series}
        :if={p.rounds > 0}
        x={cx(p.i, @n) - bar_w(@n) / 2}
        y={26 - vol_h(p.rounds, @max)}
        width={bar_w(@n)}
        height={vol_h(p.rounds, @max)}
        fill="#e5e5e5"
      />
      <line
        x1="0"
        x2="1000"
        y1="26"
        y2="26"
        stroke="#e5e5e5"
        stroke-width="1"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  attr(:ticks, :list, required: true)

  defp x_axis(assigns) do
    ~H"""
    <div class="relative mt-1 h-3">
      <span
        :for={tick <- @ticks}
        class="absolute whitespace-nowrap text-[10px] leading-none text-neutral-400 tabular-nums"
        style={tick_style(tick)}
      ><.local_time ms={tick.unix_ms} format={tick.label_format} fallback={tick.label} /></span>
    </div>
    """
  end

  defp provider_color(idx),
    do: Enum.at(["#6366f1", "#14b8a6", "#8b5cf6", "#fb7185"], idx, "#a3a3a3")

  defp rate_tooltip(%{rate: nil} = p), do: "#{p.label} · nothing ran"
  defp rate_tooltip(p), do: "#{p.label} · #{p.failed} of #{p.rounds} failed · #{p.rate}%"

  defp unknown_tooltip(%{rate: nil} = p), do: "#{p.label} · nothing ran"

  defp unknown_tooltip(p),
    do:
      "#{p.label} · unknown at least #{p.rate}% of #{fmt_ms(p.span_ms)} across #{p.rounds} " <>
        "#{if p.rounds == 1, do: "activation", else: "activations"} · recorded phases " <>
        "#{p.phase_rate || 0}%"

  defp duration_tooltip(%{p95: nil} = p), do: "#{p.label} · nothing ran"

  defp duration_tooltip(p),
    do: "#{p.label} · p50 #{fmt_ms(p.p50)} · p95 #{fmt_ms(p.p95)} · #{p.rounds} rounds"

  # Runs of consecutive buckets that have a value; empty buckets split the
  # series so the line breaks instead of diving to zero.
  defp segments(points, value_fn) do
    points
    |> Enum.chunk_by(&is_nil(value_fn.(&1)))
    |> Enum.reject(fn [p | _] -> is_nil(value_fn.(p)) end)
  end

  # Anchor rate axes at 0 and round up to a familiar step.
  defp rate_ceiling(defined) do
    max_rate = defined |> Enum.map(& &1.rate) |> Enum.max(fn -> 0.0 end)
    Enum.find([5, 10, 20, 25, 50, 100], 100, &(&1 >= max_rate))
  end

  # Duration axes climb in familiar time steps.
  defp ms_ceiling(defined) do
    max_ms = defined |> Enum.map(& &1.p95) |> Enum.max(fn -> 0.0 end)

    Enum.find(
      [1_000, 5_000, 10_000, 30_000, 60_000, 300_000, 900_000, 3_600_000, 14_400_000],
      14_400_000,
      &(&1 >= max_ms)
    )
  end

  defp pct_half(ceiling) do
    half = ceiling / 2
    if half == trunc(half), do: "#{trunc(half)}%", else: "#{half}%"
  end

  defp band(n), do: @plot_w / max(n, 1)
  defp cx(i, n), do: (i + 0.5) * band(n)
  defp cy(value, ceiling), do: @plot_h * (1 - value / ceiling)

  defp bar_w(n), do: min(band(n) * 0.7, 28.0)

  defp vol_h(_value, 0), do: 0.0
  defp vol_h(value, max), do: max(value / max * 26, 2.0)

  defp poly_points(segment, n, ceiling, value_fn) do
    Enum.map_join(segment, " ", &"#{fmt(cx(&1.i, n))},#{fmt(cy(value_fn.(&1), ceiling))}")
  end

  defp fmt(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)

  defp tick_style(%{pos: :first}), do: "left:0"
  defp tick_style(%{pos: :last}), do: "right:0"
  defp tick_style(%{pct: pct}), do: "left:#{fmt(pct)}%;transform:translateX(-50%)"

  defp x_ticks(points) do
    n = length(points)
    last = n - 1

    indices =
      if n <= 4,
        do: Enum.to_list(0..last//1),
        else: 0..3 |> Enum.map(&round(&1 * last / 3)) |> Enum.uniq()

    Enum.map(indices, fn i ->
      pos =
        cond do
          i == 0 -> :first
          i == last -> :last
          true -> :mid
        end

      point = Enum.at(points, i)

      %{
        pos: pos,
        pct: cx(i, n) / 10,
        label: point.label,
        unix_ms: point.unix_ms,
        label_format: point.label_format
      }
    end)
  end

  defp rate_cell(value, den), do: SalixWeb.Dashboard.AgentTelemetry.rate_cell(value, den)
end
