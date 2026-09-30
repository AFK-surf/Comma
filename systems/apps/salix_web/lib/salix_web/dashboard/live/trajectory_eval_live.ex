defmodule SalixWeb.Dashboard.TrajectoryEvalLive do
  @moduledoc """
  Tenant-scoped trajectory-eval trend page.

  One vocabulary everywhere: a **check** is one automated review of a slice
  of a session's conversation; a check can find zero or more **issues**; the
  LLM judge reviews some issues and either confirms them or **dismisses**
  them as false alarms. All headline numbers are net (found − dismissed);
  dismissed counts stay visible in muted text so numbers reconcile instead
  of silently shrinking. The summary strip on top states the identity the
  cards share: issues = found − dismissed.

  Data comes from ClickHouse via `SalixAnalytics.TrajectoryEvalQueries`
  (swappable through `:salix_web, :trajectory_eval_queries_mod` for tests).
  When ClickHouse isn't configured the page renders an empty state instead
  of erroring.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.{Groups, Tenants}
  alias SalixAgent.TrajectoryEval.JudgeProviders
  alias SalixWeb.Dashboard.{AgentTelemetry, Format}

  @tenant_eval_section "trajectory_eval"

  @day_options ["7", "14", "30", "90"]

  @never_checked_shown 10

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :trajectory_evals,
       page_title: "Trajectory Evals",
       breadcrumbs: [{"Trajectory Evals", nil}],
       day_options: @day_options,
       days: "14",
       groups: Groups.list(socket.assigns.current_tenant),
       filter_group: "",
       trend_view: :chart
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"days" => days, "group_id" => group}, socket) do
    days = if days in @day_options, do: days, else: "14"
    {:noreply, socket |> assign(days: days, filter_group: group) |> load()}
  end

  # The chart shows the shape, the table the exact per-day counts. The choice is
  # view-only — it never reloads, and it survives a range or group change.
  def handle_event("trend_view", %{"view" => "chart"}, socket),
    do: {:noreply, assign(socket, trend_view: :chart)}

  def handle_event("trend_view", %{"view" => "table"}, socket),
    do: {:noreply, assign(socket, trend_view: :table)}

  def handle_event("trend_view", _params, socket), do: {:noreply, socket}

  # The judge spends this tenant's LLM credit, so it's a per-tenant switch:
  # write the tenant's trajectory_eval override, merging so a future setting in
  # the same section is not clobbered.
  def handle_event("toggle_judge", _params, socket) do
    tenant = socket.assigns.current_tenant
    new_value = !socket.assigns.judge_enabled
    override = Map.put(tenant_eval_override(tenant), "judge_enabled", new_value)

    case Tenants.update_config(tenant, @tenant_eval_section, override) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(judge_enabled: new_value, judge_overridden: true)
         |> put_flash(
           :info,
           "LLM judge #{if new_value, do: "enabled", else: "disabled"} for this tenant."
         )}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not update the judge setting. Please try again.")}
    end
  end

  # The judge model is picked by name from the server-side allowlist
  # (JudgeProviders); the endpoint + credential resolve server-side, so only the
  # opaque provider key is stored. "" means "use the deployment default", which
  # clears the per-tenant key. An unknown value is ignored (defensive: the
  # runtime skips it rather than substituting a model).
  def handle_event("select_judge_provider", %{"judge_provider" => value}, socket) do
    tenant = socket.assigns.current_tenant

    cond do
      value == "" ->
        save_judge_provider(
          socket,
          tenant,
          Map.delete(tenant_eval_override(tenant), "judge_provider")
        )

      JudgeProviders.known?(value) ->
        save_judge_provider(
          socket,
          tenant,
          Map.put(tenant_eval_override(tenant), "judge_provider", value)
        )

      true ->
        {:noreply, socket}
    end
  end

  # Clears a revoked selection. Distinct from picking "" in the dropdown only
  # because the dropdown may not render at all (empty allowlist) while a stale
  # override still exists — this stays reachable in exactly that state.
  def handle_event("reset_judge_provider", _params, socket) do
    tenant = socket.assigns.current_tenant

    save_judge_provider(
      socket,
      tenant,
      Map.delete(tenant_eval_override(tenant), "judge_provider")
    )
  end

  defp save_judge_provider(socket, tenant, override) do
    case Tenants.update_config(tenant, @tenant_eval_section, override) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_judge_provider(tenant)
         |> put_flash(:info, "Judge model updated for this tenant.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not update the judge model. Please try again.")}
    end
  end

  defp load(socket) do
    tenant = socket.assigns.current_tenant
    socket = socket |> assign_judge_setting(tenant) |> assign_judge_provider(tenant)
    to = Date.utc_today()
    from = Date.add(to, -(String.to_integer(socket.assigns.days) - 1))
    opts = [from: from, to: to, group_id: nilify(socket.assigns.filter_group)]
    mod = queries_mod()

    trend = mod.flag_rate_trend(tenant, opts)

    if trend == {:error, :not_configured} do
      assign(socket,
        configured?: false,
        trend: [],
        metrics: [],
        judge: [],
        top: [],
        stats: %{checks: 0, found: 0, dismissed: 0, issues: 0, reviewed: 0},
        never_checked: nil
      )
    else
      trend_rows = rows(trend)
      metric_rows = mod.metric_breakdown(tenant, opts) |> rows()

      assign(socket,
        configured?: true,
        trend: trend_series(trend_rows, from, to),
        metrics: metric_totals(metric_rows),
        judge: mod.judge_confirm_rate(tenant, opts) |> rows(),
        top: mod.top_flagged_sessions(tenant, opts) |> rows(),
        stats: stats(trend_rows, metric_rows),
        never_checked: never_checked(tenant, from, socket.assigns.filter_group)
      )
    end
  end

  # The page's denominator blind spot: checks run when a round finishes, so
  # a session that went quiet without ever finishing a round was never
  # looked at — the issue counts above cannot include it. Fed by the runtime
  # telemetry tables, internal sessions only (external sessions never report
  # endings, so their absence means nothing). `nil` — telemetry tables not
  # readable — hides the card entirely; the rest of the page is untouched.
  defp never_checked(tenant, from, filter_group) do
    opts =
      [
        from: DateTime.new!(from, ~T[00:00:00], "Etc/UTC"),
        to: DateTime.utc_now() |> DateTime.truncate(:second),
        limit: @never_checked_shown
      ] ++
        case nilify(filter_group) do
          nil -> []
          group_id -> [group_id: group_id]
        end

    case AgentTelemetry.queries_mod().unconverged_sessions(tenant, opts) do
      {:ok, telemetry_rows} -> AgentTelemetry.internal_only(telemetry_rows)
      {:error, _} -> nil
    end
  end

  defp queries_mod do
    Application.get_env(
      :salix_web,
      :trajectory_eval_queries_mod,
      SalixAnalytics.TrajectoryEvalQueries
    )
  end

  # Effective judge state for this tenant = its explicit override if set, else
  # the deployment default. `judge_overridden?` distinguishes the two so the UI
  # can say whether the switch reflects a tenant choice or the fallback. Only a
  # real boolean counts as an override — a malformed stored value falls back to
  # the default, matching how the runner gates on it (so the switch can't read
  # "on" while the runtime is actually using the global default).
  defp assign_judge_setting(socket, tenant) do
    default = judge_default()

    {enabled, overridden} =
      case tenant_eval_override(tenant) do
        %{"judge_enabled" => value} when is_boolean(value) -> {value, true}
        _ -> {default, false}
      end

    assign(socket, judge_enabled: enabled, judge_overridden: overridden, judge_default: default)
  end

  # The judge-model picker renders whatever `JudgeProviders.resolve_selection/2`
  # says — the SAME pure contract the Runner gates paid calls on, fed the same
  # inputs (the tenant's stored value, the deployment default), so the page can
  # never claim a state the runtime doesn't have. Four render states:
  #
  #   :default        — nothing selected anywhere; the dropdown shows the
  #                     "Deployment default" prompt (inherit the template
  #                     analyze model). Also how a VALID global default renders:
  #                     the tenant hasn't overridden anything.
  #   :set            — the tenant's stored pick is a known allowlist key.
  #   :revoked        — the tenant's pick no longer resolves (removed or
  #                     malformed). The judge is skipping; show the banner +
  #                     reset, even when the allowlist is empty — otherwise the
  #                     stale override is invisible and impossible to clear.
  #   :global_invalid — no tenant pick, but the deployment default itself no
  #                     longer resolves. Also skipping, but reset can't repair
  #                     it (there's no tenant key to clear) — that's an ops
  #                     config fix; a tenant may still pick a valid model to
  #                     shadow the broken default.
  defp assign_judge_provider(socket, tenant) do
    tenant_value = tenant_eval_override(tenant)["judge_provider"]

    {state, selected, stale} =
      case JudgeProviders.resolve_selection(tenant_value, global_judge_provider()) do
        nil -> {:default, "", nil}
        {:ok, key, :tenant} -> {:set, key, nil}
        {:ok, _key, :global} -> {:default, "", nil}
        {:invalid, :tenant, value} -> {:revoked, "", stale_label(value)}
        {:invalid, :global, value} -> {:global_invalid, "", stale_label(value)}
      end

    assign(socket,
      judge_provider_state: state,
      judge_provider: selected,
      judge_provider_stale: stale,
      judge_provider_options: JudgeProviders.options()
    )
  end

  defp global_judge_provider do
    :salix_agent
    |> Application.get_env(:trajectory_eval, [])
    |> Keyword.get(:judge_provider)
  end

  # Only a name-like stale value is echoed back; a malformed one (a map, a
  # list…) is described, not rendered.
  defp stale_label(key) when is_binary(key) and key != "", do: key
  defp stale_label(_key), do: "an invalid value"

  defp tenant_eval_override(tenant) do
    case Tenants.get_config(tenant, @tenant_eval_section, %{}) do
      {:ok, %{} = override} -> override
      _ -> %{}
    end
  end

  # The runtime gate lives in salix_agent's app env; salix_web shares the BEAM,
  # so read the same default the runner falls back to when a tenant is unset.
  defp judge_default do
    :salix_agent
    |> Application.get_env(:trajectory_eval, [])
    |> Keyword.get(:judge_enabled, false)
  end

  defp nilify(""), do: nil
  defp nilify(v), do: v

  # Degrade a failed widget to empty rather than crashing the page.
  defp rows({:ok, rows}), do: rows
  defp rows({:error, _}), do: []

  # The identity the whole page hangs on: issues = found − dismissed.
  defp stats(trend_rows, metric_rows) do
    found = sum(metric_rows, "found")
    dismissed = sum(metric_rows, "dismissed")

    %{
      checks: sum(trend_rows, "checks"),
      found: found,
      dismissed: dismissed,
      issues: found - dismissed,
      reviewed: sum(metric_rows, "reviewed")
    }
  end

  # Trend rows arrive per (event_date, group_id); a check belongs to exactly
  # one group, so summing the per-group uniqExact counts per date is safe.
  defp trend_by_date(rows) do
    rows
    |> Enum.group_by(& &1["event_date"])
    |> Enum.map(fn {date, group_rows} ->
      %{
        date: date,
        checks: sum(group_rows, "checks"),
        with_issues: sum(group_rows, "with_issues")
      }
    end)
    |> Enum.sort_by(& &1.date)
  end

  # The chart's x-axis is the selected range, not just the days ClickHouse had
  # rows for. A day nothing ran on has no row at all, and its issue rate is
  # undefined rather than zero — it must read as a gap in the line, so the
  # range is walked and filled with `rate: nil` where there were no checks.
  defp trend_series(rows, from, to) do
    by_date = rows |> trend_by_date() |> Map.new(&{&1.date, &1})

    from
    |> Date.range(to)
    |> Enum.with_index()
    |> Enum.map(fn {date, i} ->
      iso = Date.to_iso8601(date)
      row = Map.get(by_date, iso, %{checks: 0, with_issues: 0})

      %{
        i: i,
        date: iso,
        checks: row.checks,
        with_issues: row.with_issues,
        rate: pct(row.with_issues, row.checks)
      }
    end)
  end

  defp metric_totals(rows) do
    rows
    |> Enum.group_by(& &1["metric"])
    |> Enum.map(fn {metric, metric_rows} ->
      found = sum(metric_rows, "found")
      dismissed = sum(metric_rows, "dismissed")
      %{metric: metric, net: found - dismissed, dismissed: dismissed}
    end)
    |> Enum.sort_by(&{-&1.net, -&1.dismissed})
  end

  defp sum(rows, key), do: rows |> Enum.map(&num(&1[key])) |> Enum.sum()

  # ClickHouse can return UInt64 counts as JSON strings depending on server
  # settings; coerce so arithmetic never crashes the page on raw row values.
  defp num(n) when is_number(n), do: n

  defp num(n) when is_binary(n),
    do:
      (case Integer.parse(n) do
         {i, _} -> i
         _ -> 0
       end)

  defp num(_), do: 0

  defp pct(value, den) do
    case num(den) do
      0 -> nil
      d -> Float.round(num(value) * 100 / d, 1)
    end
  end

  defp bar_width(value, max) do
    case num(max) do
      0 -> "0%"
      m -> "#{Float.round(num(value) * 100 / m, 1)}%"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-xl font-semibold">Trajectory Evals</h1>
          <p class="mt-1 max-w-2xl text-sm text-neutral-500">
            Automated quality checks over agent sessions. Numbers below count issues
            that stand — anything the LLM judge ruled a false alarm is subtracted
            and shown in grey.
          </p>
        </div>

        <form id="eval-filters" phx-change="filter" class="flex flex-wrap items-end gap-3">
          <.select
            name="days"
            label="Range"
            value={@days}
            options={Enum.map(@day_options, &{"Last #{&1} days", &1})}
            class="w-40"
          />
          <.select
            name="group_id"
            label="Group"
            value={@filter_group}
            prompt="All groups"
            options={Enum.map(@groups, &{&1["name"], &1["group_id"]})}
            class="w-56"
          />
        </form>
      </div>

      <.card>
        <:title>LLM judge</:title>
        <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
          <p class="text-sm text-neutral-500">
            A small model reviews each flagged check, on this tenant's LLM credit.
          </p>

          <div class="flex items-center gap-4">
            <div
              :if={@judge_provider_options != [] and @judge_provider_state in [:default, :set]}
              class="flex items-center gap-2"
            >
              <span class="text-sm text-neutral-500">Judge model</span>
              <form id="judge-provider" phx-change="select_judge_provider">
                <.select
                  name="judge_provider"
                  value={@judge_provider}
                  prompt="Deployment default"
                  options={@judge_provider_options}
                  class="w-44"
                />
              </form>
            </div>

            <button
              type="button"
              phx-click="toggle_judge"
              role="switch"
              aria-checked={to_string(@judge_enabled)}
              aria-label="LLM judge for this tenant"
              class={[
                "relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors",
                "focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 focus-visible:ring-offset-2",
                @judge_enabled && "bg-emerald-500",
                !@judge_enabled && "bg-neutral-300"
              ]}
            >
              <span class={[
                "inline-block h-5 w-5 transform rounded-full bg-white shadow transition-transform",
                @judge_enabled && "translate-x-5",
                !@judge_enabled && "translate-x-1"
              ]}>
              </span>
            </button>
          </div>
        </div>

        <%!-- An invalid selection means the runtime is SKIPPING the paid judge
              for this tenant — showing "Deployment default" would claim a
              fallback that isn't happening. Rendered regardless of the
              allowlist (an empty one is exactly how a pick gets orphaned).
              The ways out differ by whose selection broke: a tenant pick can
              be reset or replaced here; a broken deployment default is an ops
              config fix — reset has nothing to clear, so it isn't offered —
              though a tenant pick can still shadow it when models exist. --%>
        <div
          :if={@judge_provider_state in [:revoked, :global_invalid]}
          class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-2"
        >
          <p :if={@judge_provider_state == :revoked} class="text-xs text-amber-700">
            The selected judge model ({@judge_provider_stale}) is no longer available,
            so the judge is paused for this tenant.
          </p>
          <p :if={@judge_provider_state == :global_invalid} class="text-xs text-amber-700">
            The deployment default judge model ({@judge_provider_stale}) is not in the
            allowlist, so the judge is paused for this tenant. Fixing the default needs
            an ops config change.
          </p>
          <button
            :if={@judge_provider_state == :revoked}
            type="button"
            phx-click="reset_judge_provider"
            class="rounded-md border border-neutral-300 px-2 py-0.5 text-xs font-medium text-neutral-700 hover:bg-neutral-50"
          >
            Reset to deployment default
          </button>
          <form
            :if={@judge_provider_options != []}
            id="judge-provider"
            phx-change="select_judge_provider"
          >
            <.select
              name="judge_provider"
              value=""
              prompt="Pick a replacement…"
              options={@judge_provider_options}
              class="w-44"
            />
          </form>
        </div>

        <%!-- Whether this tenant is on its own setting or inheriting the
              deployment default decides who pays for the judge, so it stays on
              screen: a hover tooltip is unreachable by touch and keyboard. --%>
        <p class="mt-2 text-xs text-neutral-500">
          <span :if={@judge_provider_state in [:revoked, :global_invalid]}>
            The on/off switch above still applies once a model is available again.
          </span>
          <span :if={@judge_provider_state in [:default, :set] and @judge_overridden}>
            Set for this tenant.
          </span>
          <span :if={@judge_provider_state in [:default, :set] and !@judge_overridden}>
            Using the deployment default.
          </span>
          <span :if={@judge_provider_options != []}>
            Models are pre-provisioned by ops; API keys never pass through this page.
          </span>
        </p>
      </.card>

      <.empty_state
        :if={!@configured?}
        icon="chart-bar"
        title="ClickHouse not configured"
        description="Set salix_analytics clickhouse_url to enable trajectory eval aggregation."
      />

      <div :if={@configured?} class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <.stat
          label="Checks run"
          value={@stats.checks}
          note={
            if @never_checked != nil,
              do: "covers finished rounds only — see “Sessions never checked” below",
              else: "one per settled round"
          }
        />
        <.stat
          label="Issues"
          value={@stats.issues}
          note={"#{@stats.found} found − #{@stats.dismissed} false alarms"}
        />
        <.stat label="False alarms" value={@stats.dismissed} note="judge ruled not a real problem" />
        <.stat
          label="Judge reviewed"
          value={"#{@stats.reviewed} of #{@stats.found}"}
          note="unreviewed issues still count"
        />
      </div>

      <div :if={@configured?} class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <.card>
          <:title>Issue rate by day</:title>
          <:actions>
            <.view_toggle :if={@stats.checks > 0} current={@trend_view} />
          </:actions>
          <p class="mb-3 text-xs text-neutral-500">
            Of the checks run each day, how many found at least one issue that stood?
          </p>
          <p :if={@stats.checks == 0} class="text-sm text-neutral-500">
            No checks ran in this range.
          </p>
          <.trend_chart :if={@stats.checks > 0 and @trend_view == :chart} series={@trend} />

          <table :if={@stats.checks > 0 and @trend_view == :table} class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                <th class="py-1 pr-3 font-medium">Date</th>
                <th class="py-1 pr-3 text-right font-medium">Checks</th>
                <th class="py-1 pr-3 text-right font-medium">With issues</th>
                <th class="w-1/2 py-1 pl-3 font-medium">Issue rate</th>
              </tr>
            </thead>
            <tbody>
              <%!-- A day nothing ran on is the table's version of the chart's gap:
                    it has no issue rate to report, so it gets no row. --%>
              <tr :for={row <- @trend} :if={row.checks > 0} class="border-t border-neutral-100">
                <td class="whitespace-nowrap py-1.5 pr-3 font-mono text-xs">{row.date}</td>
                <td class="py-1.5 pr-3 text-right tabular-nums">{row.checks}</td>
                <td class="py-1.5 pr-3 text-right tabular-nums">{row.with_issues}</td>
                <td class="py-1.5 pl-3">
                  <div class="flex items-center gap-2">
                    <div class="h-2 flex-1 rounded-full bg-neutral-100">
                      <div
                        class="h-2 rounded-full bg-amber-400"
                        style={"width: #{bar_width(row.with_issues, row.checks)}"}
                      >
                      </div>
                    </div>
                    <span class="w-12 text-right text-xs tabular-nums text-neutral-500">
                      {pct(row.with_issues, row.checks) || "—"}<span :if={pct(row.with_issues, row.checks)}>%</span>
                    </span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </.card>

        <.card>
          <:title>Issues by type</:title>
          <p class="mb-3 text-xs text-neutral-500">
            What kind of problems stood, per detection rule. Grey = judge ruled it a
            false alarm. Hover a name to see what it means.
          </p>
          <p :if={@metrics == []} class="text-sm text-neutral-500">No issues found in this range.</p>
          <div :if={@metrics != []} class="space-y-2">
            <div :for={row <- @metrics} class="flex items-center gap-3">
              <span
                class="w-40 truncate font-mono text-xs cursor-help"
                title={metric_help(row.metric)}
              >
                {row.metric}
              </span>
              <div class="h-2 flex-1 rounded-full bg-neutral-100">
                <div
                  class="h-2 rounded-full bg-brand-500"
                  style={"width: #{bar_width(row.net, max_net(@metrics))}"}
                >
                </div>
              </div>
              <span class="text-right text-xs tabular-nums">
                {row.net}
                <span :if={row.dismissed > 0} class="text-neutral-400">
                  +{row.dismissed} false {if row.dismissed == 1, do: "alarm", else: "alarms"}
                </span>
              </span>
            </div>
          </div>
        </.card>

        <.card>
          <:title>Judge confirm rate</:title>
          <p class="mb-3 text-xs text-neutral-500">
            The judge reviewed {@stats.reviewed} of {@stats.found} issues found in this
            range. Per rule: high = the rule finds real problems, low = it mostly
            raises false alarms.
          </p>
          <p :if={@judge == []} class="text-sm text-neutral-500">
            No judge reviews in this range (the judge may be disabled for this deployment).
          </p>
          <table :if={@judge != []} class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                <th class="py-1 pr-3 font-medium">Issue type</th>
                <th class="py-1 pr-3 font-medium">Version</th>
                <th class="py-1 pr-3 text-right font-medium">Confirmed</th>
                <th class="w-1/3 py-1 pl-3 font-medium">Confirm rate</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @judge} class="border-t border-neutral-100">
                <td class="py-1.5 pr-3 font-mono text-xs cursor-help" title={metric_help(row["metric"])}>
                  {row["metric"]}
                </td>
                <td class="py-1.5 pr-3"><.badge>v{row["evaluator_version"]}</.badge></td>
                <td class="py-1.5 pr-3 text-right tabular-nums">
                  {row["confirmed"]}/{row["total"]}
                </td>
                <td class="py-1.5 pl-3">
                  <div class="flex items-center gap-2">
                    <div class="h-2 flex-1 rounded-full bg-neutral-100">
                      <div
                        class="h-2 rounded-full bg-emerald-500"
                        style={"width: #{bar_width(row["confirmed"] || 0, row["total"] || 0)}"}
                      >
                      </div>
                    </div>
                    <span class="w-12 text-right text-xs tabular-nums text-neutral-500">
                      {pct(row["confirmed"] || 0, row["total"] || 0) || "—"}<span :if={pct(row["confirmed"] || 0, row["total"] || 0)}>%</span>
                    </span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </.card>

        <.card>
          <:title>Sessions with most issues</:title>
          <p class="mb-3 text-xs text-neutral-500">
            Where to look first — ranked by standing issues. Click through to the agent
            or the session transcript with its per-check details.
          </p>
          <p :if={@top == []} class="text-sm text-neutral-500">
            No sessions with issues in this range.
          </p>
          <table :if={@top != []} class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                <th class="py-1 pr-3 font-medium">Agent</th>
                <th class="py-1 pr-3 font-medium">Session</th>
                <th class="py-1 pr-3 text-right font-medium">Issues</th>
                <th class="py-1 pr-3 text-right font-medium">False alarms</th>
                <th class="py-1 text-right font-medium">Last seen</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @top} class="border-t border-neutral-100">
                <td class="py-1.5 pr-3">
                  <.link
                    :if={row["salix_agent_id"]}
                    navigate={"/dash/agents/#{row["salix_agent_id"]}"}
                    class="font-mono text-xs text-brand-600 hover:underline"
                  >
                    {Format.short_id(row["salix_agent_id"])}
                  </.link>
                  <span :if={!row["salix_agent_id"]} class="font-mono text-xs">—</span>
                </td>
                <td class="py-1.5 pr-3">
                  <.link
                    :if={row["salix_agent_id"] && row["session_id"]}
                    navigate={"/dash/agents/#{row["salix_agent_id"]}/sessions/#{row["session_id"]}"}
                    class="font-mono text-xs text-brand-600 hover:underline"
                  >
                    {Format.short_id(row["session_id"])}
                  </.link>
                  <span :if={!(row["salix_agent_id"] && row["session_id"])} class="font-mono text-xs">
                    {Format.short_id(row["session_id"])}
                  </span>
                </td>
                <td class="py-1.5 pr-3 text-right tabular-nums">{row["issues"]}</td>
                <td class="py-1.5 pr-3 text-right tabular-nums text-neutral-400">
                  {row["dismissed"]}
                </td>
                <td class="py-1.5 text-right font-mono text-xs text-neutral-500">{row["last_date"]}</td>
              </tr>
            </tbody>
          </table>
        </.card>

        <.card :if={@never_checked != nil}>
          <:title>Sessions never checked</:title>
          <p class="mb-3 text-xs text-neutral-500">
            Checks run when a round finishes. These sessions went quiet without ever
            finishing a round, so no check looked at them — the issue counts above
            cannot include them. Internal sessions only.
          </p>
          <p :if={@never_checked == []} class="text-sm text-neutral-500">
            Every session that went active in this range finished its rounds.
          </p>
          <table :if={@never_checked != []} class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                <th class="py-1 pr-3 font-medium">Session</th>
                <th class="py-1 pr-3 font-medium">Agent</th>
                <th class="py-1 text-right font-medium">Last activity</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @never_checked} class="border-t border-neutral-100">
                <td class="py-1.5 pr-3">
                  <.link
                    navigate={"/dash/agents/#{row["salix_agent_id"]}/sessions/#{row["session_id"]}#timeline"}
                    class="font-mono text-xs text-brand-600 hover:underline"
                  >
                    {Format.short_id(row["session_id"])}
                  </.link>
                </td>
                <td class="py-1.5 pr-3">
                  <.link
                    navigate={"/dash/agents/#{row["salix_agent_id"]}"}
                    class="font-mono text-xs text-brand-600 hover:underline"
                  >
                    {Format.short_id(row["salix_agent_id"])}
                  </.link>
                </td>
                <td class="py-1.5 text-right font-mono text-xs text-neutral-500">
                  {AgentTelemetry.ch_time_ago(row["last_activity_at"])}
                </td>
              </tr>
            </tbody>
          </table>
          <p class="mt-3 text-xs text-neutral-400">
            <.link navigate="/dash/runtime" class="text-brand-600 hover:underline">
              see all in Runtime Health →
            </.link>
          </p>
        </.card>
      </div>
    </div>
    """
  end

  # Summary tile for the strip above the cards.
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:note, :string, default: nil)

  defp stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-neutral-200 bg-white p-4">
      <p class="text-xs text-neutral-500">{@label}</p>
      <p class="mt-1 text-2xl font-semibold tabular-nums">{@value}</p>
      <p :if={@note} class="mt-0.5 text-xs text-neutral-400">{@note}</p>
    </div>
    """
  end

  defp max_net(metrics), do: metrics |> Enum.map(& &1.net) |> Enum.max(fn -> 0 end)

  # Segmented control for the issue-rate card header.
  attr(:current, :atom, required: true)

  defp view_toggle(assigns) do
    ~H"""
    <div
      class="inline-flex rounded-md border border-neutral-200 p-0.5"
      role="group"
      aria-label="Issue rate view"
    >
      <button
        :for={{value, label} <- [{:chart, "Chart"}, {:table, "Table"}]}
        type="button"
        phx-click="trend_view"
        phx-value-view={value}
        aria-pressed={to_string(@current == value)}
        class={[
          "rounded px-2 py-0.5 text-xs font-medium transition-colors",
          @current == value && "bg-neutral-100 text-neutral-900",
          @current != value && "text-neutral-500 hover:text-neutral-700"
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  # ============================== trend chart ==============================
  #
  # Server-rendered inline SVG — no charting library, no JS hook. LiveView
  # already re-renders the card when the range/group filter changes.
  #
  # The card is ~380px wide in the two-column layout and ~815px in the
  # one-column one. A uniformly scaled viewBox cannot serve both: `meet` either
  # letterboxes the short side or shrinks the type to mush. So the plot stretches
  # freely (`preserveAspectRatio="none"`, a fixed 0..1000 x 0..100 space) and
  # everything that must not stretch is kept out of that transform — strokes via
  # `non-scaling-stroke`, and all text as HTML around the SVG rather than in it.
  @plot_w 1000
  @plot_h 100

  # Dots stay legible up to a month; past that the line carries the shape and
  # only isolated points (a lone day between two gaps, which no line segment can
  # express) still need a mark of their own.
  @dot_limit 31

  attr(:series, :list, required: true)

  defp trend_chart(assigns) do
    points = assigns.series
    n = length(points)
    defined = Enum.reject(points, &is_nil(&1.rate))
    ceiling = y_ceiling(defined)
    segs = segments(points)

    assigns =
      assign(assigns,
        n: n,
        ceiling: ceiling,
        max_checks: points |> Enum.map(& &1.checks) |> Enum.max(fn -> 0 end),
        lines: Enum.filter(segs, &(length(&1) > 1)),
        dots: dot_points(defined, segs, n),
        ticks: x_ticks(points)
      )

    ~H"""
    <div>
      <div class="relative pl-9">
        <div class="absolute left-0 top-0 h-32 w-8 text-right text-[10px] leading-none text-neutral-400 tabular-nums">
          <span class="absolute right-0 top-0 -translate-y-1/2">{pct_label(@ceiling / 1)}</span>
          <span class="absolute right-0 top-1/2 -translate-y-1/2">{pct_label(@ceiling / 2)}</span>
          <span class="absolute right-0 bottom-0 translate-y-1/2">0%</span>
        </div>

        <div class="relative">
          <svg
            viewBox="0 0 1000 100"
            preserveAspectRatio="none"
            class="block h-32 w-full overflow-visible"
            role="img"
            aria-label="Issue rate by day"
          >
            <line
              :for={y <- [0, 50, 100]}
              x1="0"
              x2="1000"
              y1={y}
              y2={y}
              stroke-width="1"
              vector-effect="non-scaling-stroke"
              class="stroke-neutral-200"
            />
            <polyline
              :for={seg <- @lines}
              points={polyline_points(seg, @n, @ceiling)}
              fill="none"
              stroke-width="1.75"
              stroke-linecap="round"
              stroke-linejoin="round"
              vector-effect="non-scaling-stroke"
              class="stroke-amber-500"
            />
            <line
              :for={p <- @dots}
              data-dot="1"
              x1={cx(p.i, @n)}
              x2={cx(p.i, @n)}
              y1={cy(p.rate, @ceiling)}
              y2={cy(p.rate, @ceiling)}
              stroke-width="5"
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
              class="stroke-amber-500"
            />
          </svg>

          <svg
            viewBox="0 0 1000 100"
            preserveAspectRatio="none"
            class="mt-1.5 block h-4 w-full overflow-visible"
            aria-hidden="true"
          >
            <rect
              :for={p <- @series}
              :if={p.checks > 0}
              x={cx(p.i, @n) - bar_w(@n) / 2}
              y={100 - bar_h(p.checks, @max_checks)}
              width={bar_w(@n)}
              height={bar_h(p.checks, @max_checks)}
              class="fill-neutral-200"
            />
            <line
              x1="0"
              x2="1000"
              y1="100"
              y2="100"
              stroke-width="1"
              vector-effect="non-scaling-stroke"
              class="stroke-neutral-200"
            />
          </svg>

          <div class="absolute inset-0 flex">
            <div :for={p <- @series} class="flex-1" title={tooltip(p)}></div>
          </div>
        </div>

        <div class="relative mt-1 h-3">
          <span
            :for={tick <- @ticks}
            class="absolute whitespace-nowrap text-[10px] leading-none text-neutral-400 tabular-nums"
            style={tick_style(tick)}
          >{tick.label}</span>
        </div>
      </div>

      <p class="mt-3 text-xs text-neutral-400">
        Line: share of that day's checks that found a standing issue. Bars: how many
        checks ran, relative to the busiest day — a high rate over one check is not
        the same as a high rate over fifty. Gaps are days nothing ran. Hover any day
        for exact counts.
      </p>
    </div>
    """
  end

  # Round the axis up to a familiar step so the gridline labels read cleanly,
  # but always anchor at 0: a rate chart with a floating baseline exaggerates
  # every wobble.
  defp y_ceiling(defined_points) do
    max_rate = defined_points |> Enum.map(& &1.rate) |> Enum.max(fn -> 0.0 end)
    Enum.find([5, 10, 20, 25, 50, 100], 100, &(&1 >= max_rate))
  end

  # Runs of consecutive days that have a rate. Days with no checks split the
  # series, so the line breaks across them instead of diving to zero.
  defp segments(points) do
    points
    |> Enum.chunk_by(&is_nil(&1.rate))
    |> Enum.reject(fn [p | _] -> is_nil(p.rate) end)
  end

  defp dot_points(defined, _segs, n) when n <= @dot_limit, do: defined
  defp dot_points(_defined, segs, _n), do: segs |> Enum.filter(&match?([_], &1)) |> List.flatten()

  # Points sit at band centres, which lines up with the equal-width hover
  # columns of the overlay.
  defp band(n), do: @plot_w / max(n, 1)
  defp cx(i, n), do: (i + 0.5) * band(n)
  defp cy(rate, ceiling), do: @plot_h * (1 - rate / ceiling)

  defp bar_w(n), do: min(band(n) * 0.7, 28.0)

  defp bar_h(_checks, 0), do: 0.0

  # Floor at roughly a device pixel: a day that ran checks must never render as
  # no bar at all.
  defp bar_h(checks, max_checks), do: max(checks / max_checks * @plot_h, 6.0)

  defp polyline_points(segment, n, ceiling) do
    Enum.map_join(segment, " ", &"#{fmt(cx(&1.i, n))},#{fmt(cy(&1.rate, ceiling))}")
  end

  defp fmt(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)

  defp pct_label(v) do
    if v == trunc(v), do: "#{trunc(v)}%", else: "#{Float.round(v, 1)}%"
  end

  defp short_date(iso), do: String.slice(iso, 5, 5)

  # Edge labels hug the plot edges; the rest centre on their day.
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

      %{
        pos: pos,
        pct: cx(i, n) / 10,
        label: points |> Enum.at(i) |> Map.fetch!(:date) |> short_date()
      }
    end)
  end

  defp tooltip(%{rate: nil} = p), do: "#{p.date} · no checks ran"

  defp tooltip(p),
    do: "#{p.date} · #{p.with_issues} of #{p.checks} checks · #{p.rate}%"

  # Plain-language hover help for the L1 rule names (shown as title tooltips).
  @metric_help %{
    "tool_loop" => "Same tool called over and over without making progress",
    "confusion" => "Self-contradictory or confused output",
    "goal_drift" => "Wandered away from the stated goal",
    "silent_failure" => "A tool failed but the agent carried on as if it had worked"
  }

  defp metric_help(metric), do: @metric_help[to_string(metric)]
end
