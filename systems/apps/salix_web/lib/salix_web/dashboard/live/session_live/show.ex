defmodule SalixWeb.Dashboard.SessionLive.Show do
  @moduledoc """
  Session detail: inspect transcript, view the reasoning trace, and search the
  agent's messages.
  """
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.{Control, Runtime}
  alias SalixAgent.TrajectoryEval
  alias SalixWeb.Dashboard.{AgentTelemetry, Format, MessageContent}
  import SalixWeb.Dashboard.LocalTime, only: [local_time: 1]

  @evals_shown 10

  # A round with no finish record only reads as a problem once the session
  # has been silent past the run-telemetry grace window (15 minutes).
  @timeline_grace_seconds 900

  @impl true
  def mount(%{"id" => agent_id, "session_id" => sid}, _session, socket) do
    # Archived agents stay reachable read-only so transcripts, evals and the
    # telemetry timeline keep working after a soft delete.
    with {:ok, agent} <- Control.get_including_archived(agent_id, socket.assigns.current_tenant),
         {:ok, session} <- Runtime.get_session(agent, sid) do
      {:ok,
       socket
       |> assign(
         active_nav: :agents,
         agent_id: agent_id,
         agent: agent,
         archived?: Control.archived?(agent),
         session_id: sid,
         session: session,
         page_title: session["name"] || sid,
         breadcrumbs: [
           {"Agents", "/dash/agents"},
           {agent["name"], "/dash/agents/#{agent_id}"},
           {"Sessions", "/dash/agents/#{agent_id}/sessions"},
           {session["name"] || sid, nil}
         ],
         trace: nil,
         search_results: nil,
         search_archived_not_searched: false
       )
       |> load_messages()
       |> load_evals()
       |> load_timeline()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found.")
         |> push_navigate(to: "/dash/agents/#{agent_id}/sessions")}
    end
  end

  @messages_page 500

  defp load_messages(socket) do
    # Bounded tail page, never the whole archive: older pages load on demand.
    case Runtime.get_session_messages(socket.assigns.agent, socket.assigns.session_id,
           history: {:tail, @messages_page}
         ) do
      {:ok, result} ->
        messages = result["messages"] || []

        assign(socket,
          messages: messages,
          session_models: session_models(messages),
          history_has_older: result["history_truncated"] == true,
          archived_through: result["archived_through"] || 0
        )

      _ ->
        assign(socket,
          messages: [],
          session_models: [],
          history_has_older: false,
          archived_through: 0
        )
    end
  end

  defp load_older_messages(socket) do
    oldest =
      socket.assigns.messages
      |> Enum.map(&(&1["seq"] || 0))
      |> Enum.filter(&(&1 > 0))
      |> Enum.min(fn -> nil end)

    if is_nil(oldest) do
      assign(socket, history_has_older: false)
    else
      case Runtime.get_session_messages(socket.assigns.agent, socket.assigns.session_id,
             history: {:before, oldest, @messages_page}
           ) do
        {:ok, result} ->
          older = result["messages"] || []

          assign(socket,
            messages: older ++ socket.assigns.messages,
            history_has_older: result["history_truncated"] == true
          )

        _ ->
          socket
      end
    end
  end

  # Distinct models that actually produced assistant turns, in first-use order —
  # the template can change mid-session, so this reflects what really ran.
  defp session_models(messages) do
    messages
    |> Enum.filter(&(message_role(&1) == "assistant"))
    |> Enum.map(&message_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp load_evals(socket) do
    evals =
      case TrajectoryEval.Store.read(socket.assigns.agent_id, socket.assigns.session_id) do
        {:ok, doc} -> Enum.take(doc["evals"] || [], @evals_shown)
        _ -> []
      end

    assign(socket, evals: evals)
  end

  # The telemetry timeline is the mechanics view under the eval card's
  # verdicts: every model call, tool call, and round ending ClickHouse has
  # for this session. `timeline: nil` (ClickHouse not configured) hides the
  # card entirely; an empty row list renders its explanatory empty state.
  defp load_timeline(socket) do
    case AgentTelemetry.queries_mod().session_trace(
           socket.assigns.current_tenant,
           socket.assigns.session_id
         ) do
      {:error, :not_configured} ->
        assign(socket, timeline: nil)

      result ->
        internal? = Control.runtime_kind(socket.assigns.agent) != "external"
        assign(socket, timeline: shape_timeline(AgentTelemetry.rows(result), internal?))
    end
  end

  defp shape_timeline(rows, internal?) do
    {run_rows, call_rows} = Enum.split_with(rows, &(&1["event_kind"] == "run"))
    finishes = Map.new(run_rows, &{&1["round_id"], &1})

    groups =
      call_rows
      |> Enum.group_by(&(&1["round_id"] || :outside))
      |> Enum.map(fn {round_id, group_rows} ->
        %{
          round_id: round_id,
          first_at: group_rows |> Enum.map(&(&1["started_at"] || "")) |> Enum.min(fn -> "" end),
          rows: fold_repeats(group_rows),
          finish: if(round_id != :outside, do: finishes[round_id])
        }
      end)
      |> Enum.sort_by(&{&1.round_id == :outside, &1.first_at})

    last_at =
      rows
      |> Enum.map(&(&1["started_at"] || &1["metered_at"] || ""))
      |> Enum.max(fn -> nil end)

    llm_rows = Enum.filter(call_rows, &(&1["event_kind"] == "llm"))
    tool_rows = Enum.filter(call_rows, &(&1["event_kind"] == "tool"))

    %{
      internal?: internal?,
      stale?: internal? and stale?(last_at),
      groups: groups,
      rounds: run_rows |> Enum.map(& &1["round_id"]) |> Enum.uniq() |> length(),
      model_ms: llm_rows |> Enum.map(&AgentTelemetry.num(&1["duration_ms"])) |> Enum.sum(),
      tool_ms: tool_rows |> Enum.map(&AgentTelemetry.num(&1["duration_ms"])) |> Enum.sum(),
      tokens: llm_rows |> Enum.map(&AgentTelemetry.num(&1["tokens"])) |> Enum.sum(),
      errors: Enum.count(call_rows, &(&1["status"] == "error")),
      last_at: last_at
    }
  end

  # Runs of consecutive identical calls (same tool, same input fingerprint,
  # same output fingerprint) fold into one row with a repeat count — a
  # polling loop would otherwise flood the table. A hint, not a verdict:
  # judged issues live in the Trajectory eval card above.
  defp fold_repeats(rows) do
    rows
    |> Enum.chunk_by(fn row ->
      if row["event_kind"] == "tool" and row["args_fingerprint"] != nil and
           row["result_fingerprint"] != nil,
         do: {row["name"], row["args_fingerprint"], row["result_fingerprint"]},
         else: make_ref()
    end)
    |> Enum.map(fn [first | _] = chunk -> Map.put(first, "repeat", length(chunk)) end)
  end

  defp stale?(nil), do: false

  defp stale?(last_at) do
    case NaiveDateTime.from_iso8601(String.replace(last_at, " ", "T")) do
      {:ok, naive} ->
        NaiveDateTime.diff(NaiveDateTime.utc_now(), naive, :second) > @timeline_grace_seconds

      _ ->
        false
    end
  end

  @impl true
  def handle_event("refresh", _p, socket),
    do: {:noreply, socket |> load_messages() |> load_evals() |> load_timeline()}

  def handle_event("send", _p, %{assigns: %{archived?: true}} = socket),
    do: {:noreply, put_flash(socket, :error, "Agent is archived and read-only.")}

  def handle_event("send", %{"content" => content}, socket) when is_binary(content) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      payload = %{
        content: content,
        session_id: socket.assigns.session_id,
        role: "user",
        created_at: System.system_time(:second)
      }

      opts = [
        source_message_id:
          "dashboard:session-message:" <>
            socket.assigns.session_id <>
            ":" <> Integer.to_string(System.unique_integer([:positive]))
      ]

      case SalixAgent.deliver(socket.assigns.agent_id, payload, opts) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, "Runtime message accepted.") |> load_messages()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Send failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("send", _p, socket), do: {:noreply, socket}

  def handle_event("load_older", _p, socket), do: {:noreply, load_older_messages(socket)}

  def handle_event("trace", _p, socket) do
    case Runtime.session_trace(socket.assigns.agent, socket.assigns.session_id,
           history: {:tail, 800}
         ) do
      {:ok, trace} ->
        {:noreply, assign(socket, trace: Format.pretty_json(trace))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Trace failed: #{inspect(reason)}")}
    end
  end

  def handle_event("search", %{"q" => q}, socket) when q != "" do
    case Runtime.search_messages(socket.assigns.agent, q, 20) do
      {:ok, %{"results" => results} = envelope} ->
        {:noreply,
         assign(socket,
           search_results: results,
           search_archived_not_searched: envelope["archived_not_searched"] == true
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Search failed: #{inspect(reason)}")}
    end
  end

  def handle_event("search", _p, socket),
    do: {:noreply, assign(socket, search_results: nil, search_archived_not_searched: false)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <div class="flex items-center gap-2">
            <h1 class="text-xl font-semibold">{@session["name"] || @session_id}</h1>
            <.badge :if={@archived?} color="amber">archived</.badge>
          </div>
          <p class="mt-1 font-mono text-xs text-neutral-500">{@session_id}</p>
          <p :if={@session_models != []} class="mt-1 text-xs text-neutral-500">
            model: <span class="font-mono">{Enum.join(@session_models, " → ")}</span>
          </p>
        </div>
        <div class="flex items-end gap-2">
          <.button size="sm" phx-click="trace">Load trace</.button>
          <.button
            size="sm"
            href={"/dash/agents/#{@agent_id}/sessions/#{@session_id}/trace"}
            target="_blank"
            rel="noopener"
          >
            <.icon name="bolt" class="h-4 w-4" /> Raw JSON
          </.button>
        </div>
      </div>

      <pre
        :if={@trace}
        class="max-h-96 overflow-auto rounded-md bg-neutral-950 p-3 text-xs text-neutral-100"
      >{@trace}</pre>

      <.card>
        <:title>Trajectory eval</:title>
        <div class="space-y-3">
          <div :for={eval <- @evals} class="rounded-md border border-neutral-200 p-3">
            <div class="mb-2 flex flex-wrap items-center gap-2 text-xs text-neutral-500">
              <span class={[
                "rounded px-1.5 py-0.5 font-medium",
                eval["outcome"] == "error" && "bg-red-100 text-red-700",
                eval["outcome"] != "error" && "bg-neutral-100 text-neutral-600"
              ]}>
                {eval["outcome"]}
              </span>
              <span
                :if={(eval["repeats"] || 1) > 1}
                class="rounded bg-neutral-100 px-1.5 py-0.5 font-medium text-neutral-600"
                title={"same result across #{eval["repeats"]} settles since #{eval["first_evaluated_at"]}"}
              >
                ×{eval["repeats"]} settles
              </span>
              <span>{eval["evaluated_at"]}</span>
              <span :if={round_id = get_in(eval, ["window", "round_id"])} class="font-mono">
                {round_id}
              </span>
              <span>
                {get_in(eval, ["window", "message_count"]) || 0} msgs · {eval["evaluator"]} v{eval[
                  "evaluator_version"
                ]}
              </span>
            </div>
            <p :if={(eval["findings"] || []) == []} class="text-sm text-neutral-500">
              No findings — clean window.
            </p>
            <div :for={finding <- eval["findings"] || []} class="mb-2">
              <div class="flex items-center gap-2">
                <span class={[
                  "rounded px-1.5 py-0.5 text-xs font-medium",
                  finding_severity_class(finding["score"])
                ]}>
                  {finding["metric"]}
                </span>
                <span class="text-xs text-neutral-500" title={"score #{format_score(finding["score"])}"}>
                  {severity_label(finding["score"])} · {finding["hits"]} hit(s)
                </span>
              </div>
              <ul class="mt-1 space-y-0.5 pl-4">
                <li
                  :for={evidence <- finding["evidence"] || []}
                  class="list-disc text-xs text-neutral-600"
                >
                  <span class="italic">“{evidence["quote"]}”</span>
                  <span :if={evidence["message_id"]} class="text-neutral-400">
                    #{evidence["message_id"]}
                  </span>
                </li>
              </ul>
            </div>
            <div :if={judge = eval["judge"]} class="mt-2 rounded-md bg-neutral-50 p-2">
              <p class="mb-1 text-xs font-medium text-neutral-500">
                LLM judge · {judge["model"]} · prompt v{judge["prompt_version"]}
              </p>
              <div
                :for={verdict <- judge["verdicts"] || []}
                class="flex flex-wrap items-center gap-2 text-xs"
              >
                <span class={[
                  "rounded px-1.5 py-0.5 font-medium",
                  verdict_class(verdict["verdict"], verdict["score"])
                ]}>
                  {verdict["metric"]}
                </span>
                <span
                  :if={verdict["verdict"] == "confirmed"}
                  class="text-neutral-500"
                  title={"score #{format_score(verdict["score"])}"}
                >
                  {severity_label(verdict["score"])}
                </span>
                <span :if={verdict["verdict"] == "rejected"} class="text-neutral-500">
                  cleared
                </span>
                <span class="text-neutral-600">{verdict["reason"]}</span>
              </div>
            </div>
          </div>
          <p :if={@evals == []} class="text-sm text-neutral-500">
            No trajectory evals yet. Evals run automatically after each settled round.
          </p>
        </div>
      </.card>

      <div :if={@timeline} id="timeline" class="scroll-mt-4">
      <.card>
        <:title>What actually ran</:title>
        <div class="space-y-3">
          <p class="text-xs text-neutral-500">
            Every model call, tool call and round ending recorded for this session, in
            order — the mechanics under the verdicts above. Model time includes retry
            waits; overlapping background calls can make tool time exceed the clock.
          </p>

          <p :if={@timeline.groups == []} class="text-sm text-neutral-500">
            No telemetry recorded for this session yet — events appear once calls finish.
          </p>

          <div :if={@timeline.groups != []}>
            <div class="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-5">
              <.timeline_stat label="Rounds" value={@timeline.rounds} />
              <.timeline_stat label="Model time" value={AgentTelemetry.fmt_ms(@timeline.model_ms)} />
              <.timeline_stat label="Tool time" value={AgentTelemetry.fmt_ms(@timeline.tool_ms)} />
              <.timeline_stat label="Tokens" value={AgentTelemetry.fmt_tokens(@timeline.tokens)} />
              <.timeline_stat label="Errors" value={@timeline.errors} alert={@timeline.errors > 0} />
            </div>

            <p :if={!@timeline.internal?} class="mb-2 text-xs text-neutral-400">
              External session — rounds here don't report endings.
            </p>

            <div class="overflow-x-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="text-left text-xs uppercase tracking-wide text-neutral-500">
                    <th class="py-1 pr-3 font-medium">Time</th>
                    <th class="py-1 pr-3 font-medium">Kind</th>
                    <th class="py-1 pr-3 font-medium">What</th>
                    <th class="py-1 pr-3 font-medium">Outcome</th>
                    <th class="py-1 pr-3 text-right font-medium">Took</th>
                    <th class="py-1 text-right font-medium">Tries</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for group <- @timeline.groups do %>
                    <tr class="border-t border-neutral-200 bg-neutral-50">
                      <td colspan="6" class="px-2 py-1 text-xs text-neutral-500">
                        <span :if={group.round_id == :outside}>
                          Outside rounds — model calls made without a round context
                        </span>
                        <span :if={group.round_id != :outside}>
                          Round <span class="font-mono text-neutral-700">{Format.short_id(group.round_id)}</span>
                          · <.clock at={group.first_at} /> ·
                          <.finish_label finish={group.finish} timeline={@timeline} />
                        </span>
                      </td>
                    </tr>
                    <tr :for={row <- group.rows} class="border-t border-neutral-100">
                      <td class="py-1.5 pr-3 font-mono text-xs text-neutral-500">
                        <.clock at={row["started_at"]} />
                      </td>
                      <td class="py-1.5 pr-3">
                        <span class="rounded bg-neutral-100 px-1.5 py-0.5 text-xs text-neutral-600">
                          {if row["event_kind"] == "llm", do: "model call", else: "tool call"}
                        </span>
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-xs">
                        <span :if={row["event_kind"] == "llm"}>
                          {row["model"] || row["name"]}
                        </span>
                        <span :if={row["event_kind"] == "tool"}>
                          {row["name"]}
                          <span class="text-neutral-400">{row["detail"]}</span>
                          <span :if={row["async"] in [true, 1, "true"]} class="text-neutral-400">
                            · async
                          </span>
                        </span>
                        <span
                          :if={(row["repeat"] || 1) > 1}
                          class="ml-1 rounded bg-neutral-100 px-1.5 py-0.5 text-xs text-neutral-500 cursor-help"
                          title="same input, same output as the previous call — a hint, not a verdict; judged issues live in the Trajectory eval card above"
                        >
                          repeat ×{row["repeat"]}
                        </span>
                      </td>
                      <td class="py-1.5 pr-3"><.outcome_chip row={row} /></td>
                      <td class="py-1.5 pr-3 text-right text-xs tabular-nums">
                        {AgentTelemetry.fmt_ms(row["duration_ms"])}
                        <span :if={row["first_token_ms"]} class="text-neutral-400">
                          · first reply {AgentTelemetry.fmt_ms(row["first_token_ms"])}
                        </span>
                      </td>
                      <td class="py-1.5 text-right text-xs">
                        <span
                          :if={AgentTelemetry.num(row["attempts"]) > 1}
                          class="rounded bg-amber-50 px-1.5 py-0.5 font-medium text-amber-700"
                        >
                          ×{AgentTelemetry.num(row["attempts"])}
                        </span>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
            <p class="mt-2 text-xs text-neutral-400">
              Cancelled background tool calls never report, so they don't appear.
              Identical consecutive calls fold into one row with a repeat count.
            </p>
          </div>
        </div>
      </.card>
      </div>

      <.card>
        <:title>Transcript</:title>
        <:actions>
          <.button size="sm" phx-click="refresh"><.icon name="refresh" class="h-4 w-4" /> Refresh</.button>
        </:actions>
        <div class="space-y-3">
          <button
            :if={@history_has_older}
            phx-click="load_older"
            class="mb-2 rounded-md border border-neutral-300 px-3 py-1 text-sm text-neutral-600 hover:bg-neutral-50"
          >
            加载更早的消息（已归档 {@archived_through} 条以内）
          </button>
          <div :for={m <- @messages} class="rounded-md border border-neutral-200 p-3">
            <p class="mb-1 text-xs font-medium uppercase tracking-wide text-neutral-500">
              {message_role(m)}
              <span :if={model = message_model(m)} class="font-mono font-normal normal-case text-neutral-400">
                · {model}
              </span>
            </p>
            <.markdown text={MessageContent.text(message_content(m))} />
          </div>
          <p :if={@messages == []} class="text-sm text-neutral-500">No messages yet.</p>
        </div>
        <form
          :if={!@archived?}
          id="session-runtime-message-form"
          phx-submit="send"
          class="mt-3 flex items-end gap-2"
        >
          <.input name="content" placeholder="Send a runtime message to this session" class="flex-1" />
          <.button type="submit" variant="primary">Send</.button>
        </form>
        <p :if={@archived?} class="mt-3 text-sm text-neutral-500">
          Agent archived — this transcript is read-only.
        </p>
      </.card>

      <.card>
        <:title>Search messages</:title>
        <form id="session-message-search-form" phx-submit="search" class="mb-3 flex items-end gap-2">
          <.input name="q" placeholder="Search this agent's messages" class="flex-1" />
          <.button type="submit">Search</.button>
        </form>
        <div :if={@search_results} class="space-y-2">
          <p :if={@search_archived_not_searched} class="text-xs text-neutral-400">
            仅搜索了活跃窗口；更早的已归档消息未包含在结果里。
          </p>
          <div :for={r <- @search_results} class="rounded-md border border-neutral-200 p-2 text-sm">
            {MessageContent.preview(r["snippet"] || r["content"] || r[:content], 160)}
          </div>
          <p :if={@search_results == []} class="text-sm text-neutral-500">No matches.</p>
        </div>
      </.card>
    </div>
    """
  end

  defp finding_severity_class(score) when is_number(score) and score >= 0.8,
    do: "bg-red-100 text-red-700"

  defp finding_severity_class(score) when is_number(score) and score >= 0.5,
    do: "bg-amber-100 text-amber-700"

  defp finding_severity_class(_score), do: "bg-neutral-100 text-neutral-600"

  # A confirmed problem is colored by severity — same thresholds as the L1 chip
  # above, so severe is red, moderate amber, minor neutral. A cleared false
  # positive recedes to neutral: warm color means "there is a problem".
  defp verdict_class("confirmed", score), do: finding_severity_class(score)
  defp verdict_class(_verdict, _score), do: "bg-neutral-100 text-neutral-600"

  defp format_score(score) when is_number(score),
    do: :erlang.float_to_binary(score / 1, decimals: 2)

  defp format_score(_score), do: "–"

  # Same thresholds as finding_severity_class, so the words match the colors.
  defp severity_label(score) when is_number(score) and score >= 0.8, do: "severe"
  defp severity_label(score) when is_number(score) and score >= 0.5, do: "moderate"
  defp severity_label(score) when is_number(score), do: "minor"
  defp severity_label(_score), do: "–"

  defp message_role(message) when is_map(message),
    do: message[:role] || message["role"] || "message"

  defp message_role(_message), do: "message"

  defp message_content(message) when is_map(message),
    do: message[:content] || message["content"]

  defp message_content(_message), do: nil

  defp message_model(message) when is_map(message),
    do: message[:model] || message["model"]

  defp message_model(_message), do: nil

  # ====================== "What actually ran" pieces ======================

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:alert, :boolean, default: false)

  defp timeline_stat(assigns) do
    ~H"""
    <div class="rounded-md border border-neutral-200 px-2.5 py-1.5">
      <p class="text-[10px] uppercase tracking-wide text-neutral-400">{@label}</p>
      <p class={["text-sm font-semibold tabular-nums", @alert && "text-red-600"]}>{@value}</p>
    </div>
    """
  end

  attr(:finish, :map, default: nil)
  attr(:timeline, :map, required: true)

  # The round header verdict: a finish record when one exists; otherwise
  # amber ONLY for internal sessions past the grace window — internal-ness
  # comes from the agent record this LiveView already loaded, never inferred
  # from ClickHouse. External rounds are covered by the card-level note.
  defp finish_label(assigns) do
    ~H"""
    <span :if={@finish && @finish["status"] == "completed"} class="text-emerald-600">
      finished OK in {AgentTelemetry.fmt_ms(@finish["duration_ms"])}
    </span>
    <span :if={@finish && @finish["status"] == "llm_failed"} class="text-red-600">
      failed — the model call gave up after {AgentTelemetry.fmt_ms(@finish["duration_ms"])}
    </span>
    <span :if={@finish && @finish["status"] == "actor_failed"} class="text-red-600">
      failed — the agent crashed after {AgentTelemetry.fmt_ms(@finish["duration_ms"])}
    </span>
    <span :if={@finish && @finish["status"] == "repair_failed"} class="text-red-600">
      failed — the agent would not call a tool when one was required, after {AgentTelemetry.fmt_ms(
        @finish["duration_ms"]
      )}
    </span>
    <span :if={@finish && parked?(@finish["status"])} class="text-amber-600">
      stopped — {parked_reason(@finish["status"])}, after {AgentTelemetry.fmt_ms(
        @finish["duration_ms"]
      )}
    </span>
    <span :if={@finish && unnamed_finish?(@finish["status"])} class="text-neutral-500">
      ended as {@finish["status"]} after {AgentTelemetry.fmt_ms(@finish["duration_ms"])}
    </span>
    <span :if={is_nil(@finish) and @timeline.internal? and @timeline.stale?} class="text-amber-600">
      no finish record — last activity {AgentTelemetry.ch_time_ago(@timeline.last_at)}
    </span>
    <span :if={is_nil(@finish) and @timeline.internal? and not @timeline.stale?} class="text-neutral-400">
      no finish record yet
    </span>
    <span :if={is_nil(@finish) and not @timeline.internal?} class="text-neutral-400">
      external — no ending reported
    </span>
    """
  end

  # These helpers sit after `finish_label/1` on purpose. An `attr`
  # declaration binds to the next function defined, so a plain helper
  # between the attrs and their component turns that helper into a
  # component and it receives assigns instead of its argument.
  #
  # The runtime owns both lists. Repeating them here is how a new status
  # reaches this page with no verdict at all.
  @parked_statuses SalixAgent.RunTelemetry.parked_statuses()
  @named_finish_statuses SalixAgent.RunTelemetry.terminal_statuses()

  # A guard stopped the run on purpose. That is not a crash, so it reads
  # amber and says which guard fired.
  defp parked?(status), do: status in @parked_statuses

  defp parked_reason("runaway_guard_parked"), do: "it kept going without making progress"
  defp parked_reason("repeated_tool_result_parked"), do: "one tool kept returning the same result"

  defp parked_reason("input_round_budget_parked"),
    do: "it used up its round budget for one input"

  defp parked_reason(_), do: "a guard stopped it"

  # Every span in `finish_label/1` tests one status, so a status none of them
  # names would render an empty verdict. Show the raw name instead.
  defp unnamed_finish?(status), do: status not in @named_finish_statuses

  attr(:row, :map, required: true)

  defp outcome_chip(assigns) do
    ~H"""
    <span
      :if={@row["status"] in ["completed", "ok"]}
      class="rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-700"
    >
      ok
    </span>
    <span
      :if={@row["status"] == "error"}
      class="rounded-full bg-red-50 px-2 py-0.5 text-xs font-medium text-red-700"
    >
      failed: {@row["error_type"] || "error"}
    </span>
    <span
      :if={@row["status"] == "guidance"}
      class="rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-700"
    >
      sent back: {plain_reason(@row["guidance_reason"])}
    </span>
    <span
      :if={@row["status"] not in ["completed", "ok", "error", "guidance"]}
      class="rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-500"
    >
      {@row["status"]}
    </span>
    """
  end

  defp plain_reason("invalid_params"), do: "wrong parameters"
  defp plain_reason("envelope_misuse"), do: "wrapper misused"
  defp plain_reason("not_callable"), do: "tool not available"
  defp plain_reason("not_disclosed"), do: "tool not shown to the model"
  defp plain_reason(other), do: other || "corrected"

  # A ClickHouse UTC timestamp as a wall-clock time in the viewer's time
  # zone (the dashboard's BrowserLocalTime hook rewrites the UTC text).
  attr(:at, :any, required: true)

  defp clock(%{at: at} = assigns) do
    assigns = assign(assigns, :ms, AgentTelemetry.ch_ms(at))

    ~H"""
    <.local_time :if={@ms} ms={@ms} format="time-seconds" />
    <span :if={is_nil(@ms)}>—</span>
    """
  end
end
