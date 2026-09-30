defmodule BridgeForTeamsWeb.Dashboard.TriageLive.Index do
  @moduledoc """
  Triage Workbench (`/orgs/:org/triage`) — P1, read-mostly.

  The product window over the native Slack Triage vertical: which Slack sources
  are listening, whether AI evaluation is ready, what recently happened to
  received work, and what the group router agents remember. Design:
  `docs/bridge-for-teams/design.md`.

  ## Gates

  Two of them, in order of who they exclude:

    1. `owner`/`admin` only — the same predicate family as Operations, and for
       the same reason twice over: the page renders raw Slack message text
       (RFC §7) and flips connect-level authority.
  The page is a normal product surface, not a deployment rollout. Its source,
  channel and listening controls own desired state; Salix ingress still accepts
  only current, ready, explicitly enabled authority. AI evaluation is a fixed
  product capability on the product-owned namespace, not a second switch or a
  deploy-time engine choice. If that capability is unavailable, the page stays
  open and says so separately from the saved monitoring state.

  A member (or a non-member, or a bad slug) gets the Operations denial: one
  generic "Organization not found" redirect to `/orgs`, so the page's existence
  is not a probe.

  ## Honesty rules this page is built to keep

    * **Received evidence only.** Ignored and fail-closed events are zero-write
      by design (a safety property, not a gap), so every receipt row is durable
      evidence that Comma received the event. It is not evidence that AI evaluated
      it; recent processing derives that from bucket and fence state.
    * **No fabricated quality metrics.** Noise-ignore rate, per-member
      breakdowns, and per-decision ratings need data that does not exist yet
      (RFC §9); they are absent, not estimated.
    * **No fabricated reasoning.** Review output is a suggestion, never an
      executed Slack action. A missing or unreadable processing record renders
      unavailable rather than being guessed from receipt or process liveness.
    * **Every section degrades alone.** A Salix timeout blanks one card, never
      the page, and an empty scan never renders as a failed one.

  ## Freshness after a switch write

  `Triage.set_connect_triage/5` drops the written connect's group from the
  posture `ReadCache` before it re-reads, so the row the operator just flipped
  is re-rendered from the post-write posture. Other groups' rows can still be
  up to the cache TTL (15s) stale — acceptable, and cheaper than a page-wide
  invalidation that would re-fan-out over every project on every toggle.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view
  import BridgeForTeamsWeb.Dashboard.Components.SlackText, only: [slack_text: 1]

  alias BridgeForTeams.{
    Memberships,
    Orgs,
    ProjectKnowledge,
    Projects,
    SlackHistoryOnboarding,
    Triage,
    Workspace
  }

  alias BridgeForTeams.SourcedContext.{Grounding, Previews, Publications}
  alias BridgeForTeamsWeb.Dashboard.ConversationLive.Show, as: TaskConversation
  alias BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup

  @tabs [:overview, :timeline, :knowledge, :data]

  # Params this page will act on. Anything else in the query string is dropped
  # before it can reach a read — the Operations whitelist discipline.
  @filter_keys ~w(agent bucket bucket_cursor connect file kind mode path q receipt_cursor scope step)

  # The Timeline window. `recent_window/3` is a bounded scan, not a query, so a
  # wider window buys nothing without a bigger page budget; it reports
  # `truncated: true` and the UI renders that.
  @window_days 7

  # `since_ms` is part of the read cache key, so it is quantized to the minute
  # (the context's own advice) rather than moving every render.
  @window_quantum_ms 60_000

  # Slack discovery returns one bounded page (currently at most 100 rows). The
  # dialog searches that already-loaded page locally and renders at most eight
  # matches at a time, so opening or typing never fans out into more Slack API
  # calls and never needs a product-facing pagination control.
  @channel_picker_visible_limit 8

  # Memory is browsable only under the router agent's `/memory` subtree. This is
  # enforced here, server-side, on every list and read: the seam itself would
  # happily serve any workspace path.
  @memory_root "/memory"

  # A memory file is rendered as preformatted text, not parsed. The bound keeps
  # one pathological file from becoming the page's payload.
  @memory_file_limit_bytes 200_000

  @impl true
  def mount(%{"org" => slug} = _params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, org_role} <- Memberships.org_role(org.id, user.id),
         true <- can_view_triage?(org_role) do
      {:ok, mount_workbench(socket, org, org_role, orgs)}
    else
      _denied ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization not found."))
         |> redirect(to: ~p"/orgs")}
    end
  end

  defp mount_workbench(socket, org, org_role, orgs) do
    socket
    |> assign(:page_title, gettext("Triage"))
    |> assign(:active_nav, :triage)
    |> assign(:current_org, org)
    |> assign(:current_org_role, org_role)
    |> assign(:can_manage_triage, can_manage_triage?(org_role))
    |> assign(:orgs, orgs)
    |> assign(:tabs, @tabs)
    |> assign(:filters, %{})
    |> assign(:current_tab, :overview)
    |> assign(:loaded?, false)
    |> assign(:window_days, @window_days)
    |> assign(:breadcrumbs, [])
    # Reveals and the selected receipt are per-session UI state, deliberately not
    # persisted: a reveal is an access event, and it should not survive a
    # reload as a silently pre-opened message.
    |> assign(:revealed, MapSet.new())
    |> assign(:source_presentation_token, nil)
    |> assign(:selected_receipt, nil)
    |> assign(:selected_assertion, nil)
    |> assign(:posture, nil)
    |> assign(:selected_connect, nil)
    |> assign(:channels, nil)
    |> assign(:show_channel_dialog, false)
    |> assign(:channel_dialog_query, "")
    |> assign(:channel_dialog_selection, [])
    |> assign(:ring, nil)
    |> assign(:recent_processing, nil)
    |> assign(:product_activity, nil)
    |> assign(:activity_heatmap, nil)
    |> assign(:heatmap_token, nil)
    |> assign(:feedback_selection, nil)
    |> assign(:model_debug_selection, nil)
    |> assign(:activity_selection, nil)
    |> assign(:activity_processing, nil)
    |> assign(:activity_navigation, %{cursors: [nil], kind: "all", channel: nil, before: nil})
    |> assign(:delegation_tasks, %{})
    |> assign(:window, nil)
    |> assign(:window_token, nil)
    |> assign(:receipts, nil)
    |> assign(:buckets, nil)
    |> assign(:bucket_detail, nil)
    |> assign(:router_agents, {:ok, []})
    |> assign(:agent_context_loaded?, false)
    |> assign(
      :agent_source_posture,
      {:ok, %{connects: [], unavailable_groups: [], scope_complete: true}}
    )
    |> assign(:selected_agent, nil)
    |> assign(:selected_agent_missing?, false)
    |> assign(:project_knowledge, nil)
    |> assign(:sourced_context_knowledge, nil)
    |> assign(:memory_agent, nil)
    |> assign(:memory_agent_missing?, false)
    |> assign(:memory_entries, nil)
    |> assign(:memory_file, nil)
    |> assign(:slack_history_runs, nil)
    |> assign(:slack_history_active_run, nil)
    |> assign(:slack_history_history_page, nil)
    |> assign(:slack_history_history_cursor, nil)
    |> assign(:slack_history_history_back, [])
    |> assign(:slack_history_preview, nil)
    |> assign(:slack_history_review, nil)
    |> assign(:slack_history_selected_artifact_ids, [])
    |> assign(:slack_history_readiness, SlackHistoryOnboarding.readiness())
    |> reset_slack_history_scope()
    |> assign(:slack_history_confirmed, false)
    |> assign(:slack_history_confirmed_review, nil)
    |> assign(:slack_history_client_request_id, Ecto.UUID.generate())
    |> assign(:slack_history_poll_token, nil)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    readiness = SlackHistoryOnboarding.readiness()
    socket = assign(socket, :slack_history_readiness, readiness)

    if socket.assigns.live_action == :context and not readiness.onboarding_preview? do
      {:noreply,
       redirect(socket,
         to:
           tab_path(
             socket.assigns.current_org,
             :overview,
             Map.take(params, ["agent"])
           )
       )}
    else
      {:noreply,
       socket
       |> reset_channel_dialog()
       |> assign_filters(params)
       |> assign_current_tab(socket.assigns.live_action)
       |> assign(:content_chrome, content_chrome(socket.assigns.live_action))
       |> assign(
         :suppress_onboarding_checklist,
         suppress_onboarding_checklist?(socket.assigns.live_action)
       )
       |> load_connected_workbench()
       |> assign_breadcrumbs()}
    end
  end

  @impl true
  def handle_event("open-receipt", %{"ref" => ref}, socket) when is_binary(ref) do
    socket = ensure_window(socket)

    case receipt_in_window(socket.assigns.window, ref) do
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("That timeline item is no longer available."))}

      receipt ->
        {:noreply, assign(socket, :selected_receipt, receipt)}
    end
  end

  def handle_event("open-receipt", _params, socket), do: {:noreply, socket}

  def handle_event("close-receipt", _params, socket),
    do: {:noreply, assign(socket, :selected_receipt, nil)}

  def handle_event("open-knowledge", %{"id" => assertion_id}, socket)
      when is_binary(assertion_id) do
    case assertion_in_knowledge(socket.assigns.project_knowledge, assertion_id) do
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("That knowledge item is no longer available."))}

      assertion ->
        {:noreply,
         socket
         |> ensure_window()
         |> assign(:selected_assertion, assertion)}
    end
  end

  def handle_event("open-knowledge", _params, socket), do: {:noreply, socket}

  def handle_event("close-knowledge", _params, socket),
    do: {:noreply, assign(socket, :selected_assertion, nil)}

  def handle_event("select-agent", %{"agent" => agent_id}, socket) when is_binary(agent_id) do
    if agent_in_projection?(socket.assigns.router_agents, agent_id) do
      {:noreply,
       push_patch(socket,
         to:
           tab_path(
             socket.assigns.current_org,
             socket.assigns.current_tab,
             Map.put(nav_filters(socket.assigns.filters), "agent", agent_id)
           )
       )}
    else
      {:noreply, put_flash(socket, :error, gettext("That Agent is no longer available."))}
    end
  end

  def handle_event("select-agent", _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("That Agent is no longer available."))}

  def handle_event("filter-knowledge", params, socket) do
    filters =
      nav_filters(socket.assigns.filters)
      |> Map.put("kind", knowledge_kind(params["kind"]))
      |> Map.put("q", String.slice(String.trim(params["q"] || ""), 0, 120))

    {:noreply,
     push_patch(socket,
       to: tab_path(socket.assigns.current_org, :knowledge, filters)
     )}
  end

  def handle_event("select-assistant", %{"connect" => connect_id}, socket)
      when is_binary(connect_id) do
    if selected_agent_connect?(socket, connect_id) do
      socket =
        if socket.assigns.current_tab == :context do
          reset_slack_history_scope(socket)
        else
          socket
        end

      {:noreply,
       push_patch(socket,
         to:
           tab_path(
             socket.assigns.current_org,
             socket.assigns.current_tab,
             Map.put(nav_filters(socket.assigns.filters), "connect", connect_id)
           )
       )}
    else
      {:noreply,
       put_flash(socket, :error, gettext("That Slack assistant is no longer available."))}
    end
  end

  def handle_event("select-assistant", _params, socket),
    do:
      {:noreply,
       put_flash(socket, :error, gettext("That Slack assistant is no longer available."))}

  def handle_event("open-channel-dialog", _params, socket) do
    if channel_dialog_available?(socket) do
      {:noreply,
       socket
       |> assign(:show_channel_dialog, true)
       |> assign(:channel_dialog_query, "")
       |> assign(:channel_dialog_selection, [])}
    else
      {:noreply, put_flash(socket, :error, channel_selection_message())}
    end
  end

  def handle_event("close-channel-dialog", _params, socket),
    do: {:noreply, reset_channel_dialog(socket)}

  def handle_event("change-channel-dialog", params, socket) do
    query = params |> Map.get("query", "") |> normalize_channel_query()

    selected =
      params
      |> Map.get("channel_ids", [])
      |> normalize_channel_ids()
      |> Enum.filter(&channel_allowed?(socket, selected_connect_id(socket), &1))

    {:noreply,
     socket
     |> assign(:channel_dialog_query, query)
     |> assign(:channel_dialog_selection, selected)}
  end

  def handle_event("validate-slack-history-import", params, socket) do
    allowed_ids =
      socket.assigns.channels
      |> SlackContextSetup.eligible_channels()
      |> MapSet.new(& &1.id)

    channel_ids =
      params
      |> Map.get("channel_ids", [])
      |> normalize_channel_ids()
      |> Enum.filter(&MapSet.member?(allowed_ids, &1))
      |> Enum.take(10)

    range_days = if params["range_days"] in ~w(3 7 14), do: params["range_days"], else: "7"

    form = %{channel_ids: channel_ids, range_days: range_days}
    current_scope = slack_history_scope(socket, form)

    confirmed_scope =
      cond do
        form.channel_ids == [] -> nil
        form != socket.assigns.slack_history_form -> nil
        params["scope_confirmed"] == "true" -> current_scope
        true -> nil
      end

    {:noreply,
     socket
     |> assign(:slack_history_form, form)
     |> assign(:slack_history_confirmed_scope, confirmed_scope)
     |> assign(
       :slack_history_scope_confirmed,
       not is_nil(current_scope) and confirmed_scope == current_scope
     )}
  end

  def handle_event("validate-slack-history-commit", params, socket) do
    selected_artifact_ids =
      selected_review_artifact_ids(params["artifact_ids"], socket.assigns.slack_history_preview)

    selection_changed? =
      selected_artifact_ids != socket.assigns.slack_history_selected_artifact_ids

    confirmed_review =
      if not selection_changed? and
           params["confirmed"] == "true" and
           selected_artifact_ids != [] and
           review_params_match?(params, socket.assigns.slack_history_review) do
        %{
          review: socket.assigns.slack_history_review,
          artifact_ids: selected_artifact_ids
        }
      end

    {:noreply,
     socket
     |> assign(:slack_history_selected_artifact_ids, selected_artifact_ids)
     |> assign(:slack_history_confirmed, not is_nil(confirmed_review))
     |> assign(:slack_history_confirmed_review, confirmed_review)}
  end

  def handle_event("start-slack-history-import", params, socket) do
    form = socket.assigns.slack_history_form
    current_scope = slack_history_scope(socket, form)

    if socket.assigns.slack_history_scope_confirmed and
         not is_nil(current_scope) and
         socket.assigns.slack_history_confirmed_scope == current_scope and
         params["scope_confirmed"] == "true" do
      return_path = slack_context_base_path(socket)

      with true <- socket.assigns.can_manage_triage,
           %{project_id: project_id} <- socket.assigns.selected_agent,
           %{connect_id: connect_id} <- socket.assigns.selected_connect,
           true <- same_ref?(params["connect"], connect_id),
           {:ok, _run} <-
             SlackHistoryOnboarding.start_dry_run(
               socket.assigns.current_org,
               socket.assigns.current_user,
               %{
                 project_id: project_id,
                 connect_id: connect_id,
                 expected_source_installation:
                   source_installation(socket.assigns.selected_connect),
                 channel_ids: form.channel_ids,
                 range_days: form.range_days,
                 client_request_id: params["client_request_id"],
                 replaces_run_id: replacement_run_id(socket)
               }
             ) do
        {:noreply,
         socket
         |> assign(:slack_history_client_request_id, Ecto.UUID.generate())
         |> reset_slack_history_scope()
         |> assign(:slack_history_history_cursor, nil)
         |> assign(:slack_history_history_back, [])
         |> load_slack_history()
         |> put_flash(
           :info,
           slack_history_start_success_message(socket.assigns.slack_history_readiness.grounding?)
         )
         |> push_patch(to: return_path)}
      else
        error ->
          socket =
            if error == {:error, :source_installation_changed},
              do: reset_slack_history_scope(socket),
              else: socket

          {:noreply,
           put_flash(
             socket,
             :error,
             slack_history_start_error_message(error)
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Confirm the selected channels and time range first."))}
    end
  end

  def handle_event("refresh-slack-history", _params, socket),
    do: {:noreply, load_slack_history(socket)}

  def handle_event("refresh-slack-context", _params, socket) do
    source_posture = Triage.refresh_connect_posture(socket.assigns.current_org)

    {:noreply,
     socket
     |> load_agent_context(source_posture)
     |> load_tab()
     |> revalidate_slack_history_scope_confirmation()}
  end

  def handle_event("older-slack-history", _params, socket) do
    case socket.assigns.slack_history_history_page do
      {:ok, %{next_cursor: cursor}} when is_binary(cursor) ->
        previous = socket.assigns.slack_history_history_cursor

        {:noreply,
         socket
         |> assign(:slack_history_history_cursor, cursor)
         |> update(:slack_history_history_back, &[previous | &1])
         |> load_slack_history_history_page(cursor)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("newer-slack-history", _params, socket) do
    case socket.assigns.slack_history_history_back do
      [cursor | rest] ->
        {:noreply,
         socket
         |> assign(:slack_history_history_cursor, cursor)
         |> assign(:slack_history_history_back, rest)
         |> load_slack_history_history_page(cursor)}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "commit-slack-history",
        %{"run_id" => run_id, "confirmed" => "true"} = params,
        socket
      ) do
    with true <- socket.assigns.slack_history_confirmed,
         %{review: %{run_id: ^run_id} = confirmed_review, artifact_ids: selected_artifact_ids} <-
           socket.assigns.slack_history_confirmed_review,
         true <- confirmed_review == socket.assigns.slack_history_review,
         true <- review_params_match?(params, confirmed_review),
         {:ok, run} <- authorized_slack_history_run(socket, run_id),
         true <- SlackHistoryOnboarding.readiness().commit?,
         true <- run.state == "preview_ready",
         true <- confirmed_review == slack_history_review(run),
         {:ok, preview} <- Previews.get(run.id, socket.assigns.current_user.id),
         true <-
           selected_artifact_ids ==
             selected_review_artifact_ids(params["artifact_ids"], {:ok, preview}),
         {:ok, commit_run} <-
           prepare_selected_review(
             run,
             preview,
             selected_artifact_ids,
             socket.assigns.current_user.id
           ),
         {:ok, _result} <-
           Publications.commit(commit_run.id, %{
             expected_generation: commit_run.generation,
             user_id: socket.assigns.current_user.id,
             command_id: "commit:" <> commit_run.review_revision_id,
             snapshot_id: commit_run.snapshot_id,
             derivation_id: commit_run.derivation_id,
             review_revision_id: commit_run.review_revision_id,
             confirmed?: true
           }) do
      {:noreply,
       socket
       |> load_slack_history()
       |> put_flash(
         :info,
         slack_history_commit_success_message(socket.assigns.slack_history_readiness.grounding?)
       )
       |> push_patch(to: slack_context_base_path(socket))}
    else
      _error ->
        {:noreply,
         socket
         |> load_slack_history()
         |> put_flash(
           :error,
           gettext(
             "The preview changed or could not be confirmed. Review the latest revision before retrying."
           )
         )}
    end
  end

  def handle_event("commit-slack-history", _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Explicit confirmation is required."))}

  def handle_event("rollback-slack-history", %{"run_id" => run_id}, socket) do
    with {:ok, run} <- authorized_slack_history_run(socket, run_id),
         true <- run.state == "committed",
         {:ok, _result} <-
           Publications.rollback(run.id, %{
             expected_generation: run.generation,
             user_id: socket.assigns.current_user.id,
             command_id: "rollback:" <> run.publication_id,
             reason: "workbench_explicit_rollback"
           }) do
      {:noreply,
       socket
       |> load_slack_history()
       |> put_flash(
         :info,
         gettext(
           "This import was rolled back. Its source bundle remains under the shared Context Lifecycle."
         )
       )}
    else
      _error ->
        {:noreply,
         socket
         |> load_slack_history()
         |> put_flash(
           :error,
           gettext(
             "This import could not be rolled back. Refresh its current state before retrying."
           )
         )}
    end
  end

  def handle_event("rollback-slack-history", _params, socket), do: {:noreply, socket}

  def handle_event("reveal-text", %{"ref" => ref} = params, socket) do
    # The audit row is the price of the reveal: if it cannot be written, the
    # text is not shown. That ordering is the whole point of click-to-reveal
    # (RFC §7 / §10 open question 1) — an unaudited read would be worse than
    # no read.
    case Triage.record_text_reveal(socket.assigns.current_org, socket.assigns.current_user, ref,
           connect_id: params["connect"],
           surface: "triage_#{socket.assigns.current_tab}"
         ) do
      :ok ->
        {:noreply, update(socket, :revealed, &MapSet.put(&1, ref))}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The message text could not be revealed: the access record failed to write.")
         )}
    end
  end

  def handle_event("set-triage", %{"connect" => connect_id, "action" => action}, socket)
      when is_binary(connect_id) do
    with true <- socket.assigns.can_manage_triage,
         {:ok, action} <- switch_action(action),
         %{connect_id: ^connect_id} = connect <- socket.assigns.selected_connect,
         true <- switch_action_available?(connect, action) do
      {:noreply, write_switch(socket, connect_id, action)}
    else
      _denied -> {:noreply, put_flash(socket, :error, switch_denied_message())}
    end
  end

  def handle_event("set-triage", _params, socket),
    do: {:noreply, put_flash(socket, :error, switch_denied_message())}

  def handle_event("refresh-evaluation-status", _params, socket) do
    :ok = Triage.refresh_evaluation_status(evaluation_agent_id(socket.assigns.selected_agent))
    {:noreply, load_evaluation_status(socket)}
  end

  def handle_event("open-triage-activity", %{"type" => kind, "subject" => id}, socket)
      when kind in ["outcome", "receipt"] do
    {:noreply,
     socket
     |> assign(:activity_selection, %{type: kind, id: id})
     |> assign(:model_debug_selection, nil)
     |> load_activity_tasks(kind, id)
     |> load_activity_processing(kind, id)}
  end

  def handle_event("close-triage-activity", _, socket) do
    {:noreply,
     socket
     |> assign(:activity_selection, nil)
     |> assign(:activity_processing, nil)
     |> assign(:delegation_tasks, %{})
     |> assign(:model_debug_selection, nil)
     |> assign(:feedback_selection, nil)}
  end

  def handle_event("open-triage-model-debug", %{"type" => kind, "subject" => id}, socket) do
    result =
      Triage.model_debug(
        socket.assigns.current_org,
        socket.assigns.selected_agent,
        socket.assigns.current_user.id,
        kind,
        id
      )

    selection =
      case result do
        {:ok, record} ->
          %{
            type: kind,
            id: id,
            result: {:ok, BridgeForTeamsWeb.ResponseSanitizer.sanitize(record)}
          }

        {:error, reason} when reason in [:not_found, :too_large, :forbidden] ->
          %{type: kind, id: id, result: {:error, reason}}

        _ ->
          %{type: kind, id: id, result: {:error, :unavailable}}
      end

    {:noreply, assign(socket, :model_debug_selection, selection)}
  end

  def handle_event("close-triage-model-debug", _, socket),
    do: {:noreply, assign(socket, :model_debug_selection, nil)}

  def handle_event("open-triage-feedback", %{"type" => type, "subject" => id}, socket) do
    case Triage.feedback(
           socket.assigns.current_org,
           socket.assigns.selected_agent,
           socket.assigns.current_user.id,
           type,
           id
         ) do
      {:ok, reviews} ->
        {:noreply, assign(socket, :feedback_selection, %{type: type, id: id, reviews: reviews})}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Feedback is unavailable for this item."))}
    end
  end

  def handle_event("close-triage-feedback", _, socket),
    do: {:noreply, assign(socket, :feedback_selection, nil)}

  def handle_event("save-triage-feedback", params, socket) do
    case socket.assigns.feedback_selection do
      %{type: type, id: id} ->
        case Triage.add_feedback(
               socket.assigns.current_org,
               socket.assigns.selected_agent,
               socket.assigns.current_user.id,
               type,
               id,
               params
             ) do
          {:ok, _} ->
            case Triage.feedback(
                   socket.assigns.current_org,
                   socket.assigns.selected_agent,
                   socket.assigns.current_user.id,
                   type,
                   id
                 ) do
              {:ok, reviews} ->
                {:noreply,
                 socket
                 |> assign(:feedback_selection, %{type: type, id: id, reviews: reviews})
                 |> put_flash(:info, gettext("Internal feedback saved."))}

              _ ->
                {:noreply,
                 socket
                 |> assign(:feedback_selection, nil)
                 |> assign(:model_debug_selection, nil)
                 |> assign(:activity_selection, nil)
                 |> assign(:activity_processing, nil)
                 |> put_flash(
                   :info,
                   gettext("Feedback saved. Reopen this item to refresh its reviews.")
                 )}
            end

          _ ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "Enter a score from 1 to 5 or a comment up to 4,000 characters. Your access will be checked again."
               )
             )}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("filter-triage-activity", %{"kind" => kind} = params, socket)
      when kind in ~w(all reply reaction silence investigation) do
    channel = activity_channel_filter(socket, params["channel"])

    {:noreply,
     socket
     |> assign(:activity_navigation, %{
       cursors: [nil],
       kind: kind,
       channel: channel,
       before: socket.assigns.activity_navigation[:before]
     })
     |> fetch_product_activity()}
  end

  # A heatmap cell opens that channel's Timeline at the end of the cell's
  # time bucket. The channel is checked like the filter select.
  def handle_event(
        "select-triage-heatmap-cell",
        %{"channel" => channel, "before" => before},
        socket
      ) do
    with channel when is_binary(channel) <- activity_channel_filter(socket, channel),
         {before_ms, ""} when before_ms >= 0 <- Integer.parse(before) do
      {:noreply,
       socket
       |> assign(:activity_navigation, %{
         cursors: [nil],
         kind: socket.assigns.activity_navigation.kind,
         channel: channel,
         before: before_ms
       })
       |> fetch_product_activity()}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("clear-triage-activity-time", _params, socket) do
    {:noreply,
     socket
     |> assign(:activity_navigation, %{
       socket.assigns.activity_navigation
       | cursors: [nil],
         before: nil
     })
     |> fetch_product_activity()}
  end

  def handle_event("next-triage-activity", _params, socket) do
    case socket.assigns.product_activity do
      {:ok, %{next_cursor: cursor}} when is_binary(cursor) ->
        navigation = socket.assigns.activity_navigation

        {:noreply,
         socket
         |> assign(:activity_navigation, %{navigation | cursors: [cursor | navigation.cursors]})
         |> fetch_product_activity()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("previous-triage-activity", _params, socket) do
    case socket.assigns.activity_navigation do
      %{cursors: [_, _ | _] = cursors} = navigation ->
        {:noreply,
         socket
         |> assign(:activity_navigation, %{navigation | cursors: tl(cursors)})
         |> fetch_product_activity()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("refresh-triage-processing", _params, socket) do
    {:noreply, socket |> load_product_activity() |> load_heatmap_async()}
  end

  def handle_event("load-triage-processing-diagnostics", _params, socket) do
    org = socket.assigns.current_org
    since_ms = window_since_ms()
    opts = [limit: 12, page_budget: 8]

    :ok = Triage.refresh_recent_processing(org, since_ms, opts)

    {:noreply,
     socket
     |> load_recent_processing(since_ms, opts)}
  end

  def handle_event(
        "lookup-delegation-task",
        %{"obligation" => obligation_id, "index" => index},
        socket
      )
      when is_binary(obligation_id) and index in ["0", "1"] do
    index = String.to_integer(index)
    locator = {obligation_id, index}

    with true <- socket.assigns.current_tab == :timeline,
         true <- delegation_in_selection?(socket, locator),
         {:ok, role} <-
           Memberships.org_role(socket.assigns.current_org.id, socket.assigns.current_user.id),
         true <- can_view_triage?(role) do
      result =
        Triage.delegation_task_preview(
          socket.assigns.current_org,
          socket.assigns.selected_agent,
          socket.assigns.current_user.id,
          obligation_id,
          index
        )

      # Only the open outcome's two delegations enter this map. Each preview
      # reads at most 20 Messages. No timer or list render performs Task reads.
      {:noreply, update(socket, :delegation_tasks, &Map.put(&1, locator, result))}
    else
      _unavailable ->
        {:noreply,
         socket
         |> assign(:delegation_tasks, %{})
         |> put_flash(:error, gettext("That delegation is no longer available."))}
    end
  end

  def handle_event("lookup-delegation-task", _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("That delegation is no longer available."))}

  def handle_event(
        "provision-triage",
        %{"connect" => connect_id, "channel_ids" => channel_ids},
        socket
      )
      when is_binary(connect_id) and is_list(channel_ids) do
    channel_ids = normalize_channel_ids(channel_ids)

    if socket.assigns.can_manage_triage and channel_ids != [] and
         channel_controls_available?(socket.assigns.selected_connect, connect_id) and
         Enum.all?(channel_ids, &channel_allowed?(socket, connect_id, &1)) do
      {:noreply,
       socket
       |> write_channels(connect_id, channel_ids)
       |> reset_channel_dialog()}
    else
      {:noreply, put_flash(socket, :error, channel_selection_message())}
    end
  end

  def handle_event(
        "set-triage-channel",
        %{"connect" => connect_id, "channel" => channel_id, "action" => action},
        socket
      )
      when is_binary(connect_id) and is_binary(channel_id) do
    with true <- socket.assigns.can_manage_triage,
         %{connect_id: ^connect_id} <- socket.assigns.selected_connect,
         true <- socket.assigns.selected_connect[:channel_scope_complete?] == true,
         true <- socket.assigns.selected_connect[:channel_controls_available?] == true,
         true <- configured_channel?(socket.assigns.selected_connect, channel_id),
         {:ok, enabled?} <- channel_switch_action(action) do
      {:noreply, write_switch(socket, connect_id, {:set_channel, channel_id, enabled?})}
    else
      _denied -> {:noreply, put_flash(socket, :error, switch_denied_message())}
    end
  end

  # A form field can arrive as a list or a map (`channel_id[]=a&channel_id[]=b`),
  # and `to_string/1` on either would have handed the write path a stringified
  # container. A payload that is not two strings is not a provisioning request:
  # it falls through to the same denial an unauthorized one gets.
  def handle_event("provision-triage", _params, socket),
    do: {:noreply, put_flash(socket, :error, channel_selection_message())}

  @impl true
  def handle_info(:refresh_slack_history, socket), do: {:noreply, load_slack_history(socket)}

  def handle_info(
        {:refresh_slack_history, token},
        %{assigns: %{slack_history_poll_token: token}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:slack_history_poll_token, nil)
     |> load_slack_history()}
  end

  def handle_info({:refresh_slack_history, _stale_token}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        {:source_presentation, token},
        {:ok, {:ok, labels}},
        %{assigns: %{source_presentation_token: token}} = socket
      ) do
    activity =
      case socket.assigns.product_activity do
        {:ok, %{intake: {:ok, intake}} = activity} ->
          items =
            Enum.map(intake.items, fn item ->
              presentation = Map.get(labels, item.receipt_ref, %{})

              item
              |> Map.put(:source_actor_label, presentation[:speaker_label])
              |> Map.put(:mentions, presentation[:mentions] || %{})
            end)

          {:ok, %{activity | intake: {:ok, %{intake | items: items}}}}

        activity ->
          activity
      end

    {:noreply, assign(socket, :product_activity, activity)}
  end

  def handle_async({:source_presentation, _token}, _result, socket), do: {:noreply, socket}

  def handle_async({:window, token}, result, %{assigns: %{window_token: token}} = socket) do
    window =
      case result do
        {:ok, window} -> window
        {:exit, _reason} -> {:error, :unavailable}
      end

    {:noreply, socket |> assign(:window, window) |> assign(:window_token, nil)}
  end

  # A later navigation or a synchronous read replaced this window.
  def handle_async({:window, _token}, _result, socket), do: {:noreply, socket}

  def handle_async({:heatmap, token}, result, %{assigns: %{heatmap_token: token}} = socket) do
    heatmap =
      case result do
        {:ok, {:ok, heatmap}} -> {:ok, heatmap}
        _failed -> nil
      end

    {:noreply, socket |> assign(:activity_heatmap, heatmap) |> assign(:heatmap_token, nil)}
  end

  # A later Agent or refresh replaced this heatmap read.
  def handle_async({:heatmap, _token}, _result, socket), do: {:noreply, socket}

  defp write_switch(socket, connect_id, action) do
    org = socket.assigns.current_org

    socket =
      case Triage.set_connect_triage(
             org,
             socket.assigns.current_user,
             %{connect_id: connect_id},
             action
           ) do
        {:ok, _posture} -> put_flash(socket, :info, switch_ok_message(action))
        {:error, reason} -> put_flash(socket, :error, switch_error_message(reason))
      end

    # Re-read either way: a failed write may still have moved the connect (the
    # post-write posture read is best effort inside the context), and a stale
    # switch is the one thing this card must never show.
    posture = Triage.connect_posture(org)

    socket
    |> assign(:posture, posture)
    |> assign(:agent_source_posture, posture)
    |> assign_selected_connect(posture)
    |> load_selected_channels()
  end

  defp write_channels(socket, connect_id, channel_ids) do
    org = socket.assigns.current_org

    {added, failed} =
      Enum.reduce(channel_ids, {0, []}, fn channel_id, {added, failed} ->
        case Triage.set_connect_triage(
               org,
               socket.assigns.current_user,
               %{connect_id: connect_id},
               {:provision, channel_id}
             ) do
          {:ok, _posture} -> {added + 1, failed}
          {:error, reason} -> {added, [{channel_id, reason} | failed]}
        end
      end)

    socket =
      cond do
        failed == [] ->
          put_flash(
            socket,
            :info,
            ngettext("1 Slack channel added.", "%{count} Slack channels added.", added)
          )

        added > 0 ->
          put_flash(
            socket,
            :error,
            gettext(
              "%{added} channels were added; %{failed} could not be added. The current state was re-read.",
              added: added,
              failed: length(failed)
            )
          )

        true ->
          {_channel_id, reason} = hd(failed)
          put_flash(socket, :error, switch_error_message(reason))
      end

    posture = Triage.connect_posture(org)

    socket
    |> assign(:posture, posture)
    |> assign(:agent_source_posture, posture)
    |> assign_selected_connect(posture)
    |> load_selected_channels()
  end

  defp switch_action("enable"), do: {:ok, :enable}
  defp switch_action("disable"), do: {:ok, :disable}
  defp switch_action(_other), do: :error

  defp channel_switch_action("enable"), do: {:ok, true}
  defp channel_switch_action("pause"), do: {:ok, false}
  defp channel_switch_action(_other), do: :error

  defp channel_selection_message, do: gettext("Choose one or more Slack channels from the list.")

  defp slack_history_start_success_message(true),
    do: gettext("Comma started reading and organizing Slack. Nothing new is enabled yet.")

  defp slack_history_start_success_message(false),
    do: gettext("Comma started reading and organizing Slack. Nothing new is saved yet.")

  defp slack_history_commit_success_message(true),
    do: gettext("The reviewed project context is now enabled.")

  defp slack_history_commit_success_message(false),
    do: gettext("The reviewed project knowledge is now saved in Knowledge.")

  defp slack_history_start_error_message({:error, :connect_generation_not_advanced}),
    do:
      gettext(
        "Slack has not finished reconnecting yet. Wait for the new connection, or start a normal context update instead."
      )

  defp slack_history_start_error_message({:error, :replacement_workspace_changed}),
    do:
      gettext(
        "The reconnected source belongs to a different Slack workspace. Start a separate context update instead."
      )

  defp slack_history_start_error_message({:error, :source_installation_changed}),
    do: gettext("Slack connection changed. Confirm the source and read scope again.")

  defp slack_history_start_error_message(_error),
    do: gettext("Comma could not start reading Slack. Check the selected source and scope.")

  defp switch_ok_message(:enable), do: gettext("Triage monitoring enabled for this assistant.")

  defp switch_ok_message(:disable),
    do:
      gettext(
        "Triage monitoring disabled for this assistant. Ambient messages will no longer be received, recorded, or processed. Explicit human @bot commands remain available."
      )

  defp switch_ok_message({:provision, _channel_id}),
    do:
      gettext(
        "Triage authority provisioned. The connect stays disabled until you enable it explicitly."
      )

  defp switch_ok_message({:set_channel, _channel_id, true}),
    do: gettext("This channel is active in Triage.")

  defp switch_ok_message({:set_channel, _channel_id, false}),
    do: gettext("This channel is paused. Other configured channels are unchanged.")

  defp switch_denied_message,
    do: gettext("Only organization owners and admins can change Triage switches.")

  defp switch_error_message(:forbidden), do: switch_denied_message()

  defp switch_error_message(:connect_not_found),
    do: gettext("That connect is no longer part of this organization.")

  defp switch_error_message(:invalid_action),
    do: gettext("An approved channel is required before Triage authority can be provisioned.")

  defp switch_error_message(:tenant_not_ready),
    do: gettext("This organization is not connected to Salix yet.")

  # A timeout is the one outcome that is not an outcome: the call may have
  # landed on the far side and lost its answer on the way back. Saying "the
  # switch could not be changed" would be a claim this page cannot support, so
  # the copy sends the operator to the re-read below instead.
  defp switch_error_message(:timeout),
    do:
      gettext(
        "Salix did not answer in time, so the result is unconfirmed: the change may or may not have landed. The state below was re-read after the attempt — check it before retrying."
      )

  # `:unavailable` reaches here from two places: the write itself failing, and
  # the connect being unresolvable because a project's posture could not be
  # read. Both are transient and both are retried the same way, so one honest
  # sentence covers them.
  defp switch_error_message(:unavailable),
    do:
      gettext(
        "Salix could not be reached, so the switch was not changed. This is a transient fault, not a missing connect — the state below was re-read; try again."
      )

  defp switch_error_message(reason),
    do:
      gettext("The Triage switch could not be changed (%{reason}).", reason: reason_text(reason))

  # ---- loading ----

  # The first HTTP render paints only the page frame and a loading state. Salix
  # reads, Slack message text, and its reveal audit rows happen once, on the
  # connected mount, instead of once per render.
  defp load_connected_workbench(socket) do
    if connected?(socket) do
      socket
      |> load_agent_context()
      |> load_tab()
      |> revalidate_slack_history_scope_confirmation()
      |> assign(:loaded?, true)
    else
      socket
    end
  end

  # Independent reads for one navigation run concurrently. Each read keeps its
  # own Salix timeout, so the slowest read bounds the wait instead of the sum of
  # all reads. A read that raises still crashes the LiveView, as it did inline.
  defp read_concurrently(reads) do
    reads
    |> Enum.map(fn {key, read} -> {key, Task.async(read)} end)
    |> Map.new(fn {key, task} -> {key, Task.await(task, :infinity)} end)
  end

  # The roster is read once per connected socket; each read costs one Salix
  # call per project. Tab switches reuse it. Overview and Context show the
  # Triage switches, so they re-read the posture through its short cache; the
  # other tabs reuse it for source labels. "Refresh" re-reads both.
  defp load_agent_context(%{assigns: %{agent_context_loaded?: true}} = socket) do
    posture =
      if socket.assigns.current_tab in [:overview, :context],
        do: Triage.connect_posture(socket.assigns.current_org),
        else: socket.assigns.agent_source_posture

    assign_agent_context(socket, posture, socket.assigns.router_agents)
  end

  defp load_agent_context(socket) do
    org = socket.assigns.current_org

    %{posture: posture, agents: agents} =
      read_concurrently(
        posture: fn -> Triage.connect_posture(org) end,
        agents: fn -> Triage.router_agents(org) end
      )

    assign_agent_context(socket, posture, agents)
  end

  defp load_agent_context(socket, source_posture),
    do:
      assign_agent_context(
        socket,
        source_posture,
        Triage.router_agents(socket.assigns.current_org)
      )

  defp assign_agent_context(socket, source_posture, result) do
    agents = agent_list(result)
    requested = socket.assigns.filters["agent"]
    selected = select_agent(agents, requested, socket.assigns.current_tab)

    socket
    |> assign(:router_agents, result)
    |> assign(:agent_context_loaded?, match?({:ok, _agents}, result))
    |> assign(:agent_source_posture, source_posture)
    |> assign(:selected_agent, selected)
    |> assign(:delegation_tasks, %{})
    |> assign(:selected_agent_missing?, requested_agent_missing?(agents, requested))
    |> assign(:project_knowledge, nil)
    |> assign(:sourced_context_knowledge, nil)
    |> assign(:selected_assertion, nil)
  end

  defp load_tab(%{assigns: %{current_tab: :overview}} = socket) do
    posture = socket.assigns.agent_source_posture
    socket = socket |> assign(:posture, posture) |> assign_selected_connect(posture)
    agent_id = evaluation_agent_id(socket.assigns.selected_agent)

    %{channels: channels, ring: ring} =
      read_concurrently(
        channels: selected_channels_read(socket),
        ring: fn -> Triage.ring_status(agent_id) end
      )

    socket
    |> assign(:channels, channels)
    |> assign(:ring, ring)
    |> load_slack_history()
  end

  defp load_tab(%{assigns: %{current_tab: :context}} = socket) do
    posture = socket.assigns.agent_source_posture

    socket
    |> assign(:posture, posture)
    |> assign_selected_connect(posture)
    |> load_selected_channels()
    |> maybe_preselect_slack_history_form()
    |> load_slack_history()
  end

  defp load_tab(%{assigns: %{current_tab: :timeline}} = socket) do
    agent = socket.assigns.selected_agent
    socket = reset_product_activity(socket)

    activity =
      if agent,
        do: product_activity_read(socket, socket.assigns.router_agents),
        else: fn -> :no_agent end

    # The receipt window is a 7-day scan and only backs the knowledge panel's
    # source text, so `open-knowledge` reads it when the panel opens.
    %{knowledge: knowledge, activity: activity} =
      read_concurrently(
        knowledge: fn -> load_project_knowledge(agent) end,
        activity: activity
      )

    socket
    |> assign(:window, nil)
    |> assign(:window_token, nil)
    |> assign(:project_knowledge, knowledge)
    |> assign_product_activity(activity)
    |> load_heatmap_async()
  end

  defp load_tab(%{assigns: %{current_tab: :knowledge}} = socket) do
    agent = socket.assigns.selected_agent
    user = socket.assigns.current_user

    %{knowledge: knowledge, sourced: sourced, active: active} =
      read_concurrently(
        knowledge: fn -> load_project_knowledge(agent) end,
        sourced: fn -> load_sourced_context_knowledge(agent, user) end,
        active: fn -> active_context_run(agent, user) end
      )

    socket
    |> assign(:slack_history_readiness, SlackHistoryOnboarding.readiness())
    |> assign(:project_knowledge, knowledge)
    |> assign(:sourced_context_knowledge, sourced)
    |> assign(:slack_history_active_run, active)
  end

  # `load_agent_context/1` holds this socket's roster already.
  defp load_tab(%{assigns: %{current_tab: :memory}} = socket) do
    agents = agent_list(socket.assigns.router_agents)
    requested = socket.assigns.filters["agent"]
    agent = select_memory_agent(agents, requested)

    socket
    |> assign(:memory_agent, agent)
    |> assign(:memory_agent_missing?, requested_agent_missing?(agents, requested))
    |> load_memory(agent)
  end

  defp load_tab(%{assigns: %{current_tab: :data}} = socket) do
    org = socket.assigns.current_org
    filters = socket.assigns.filters

    agent_id = evaluation_agent_id(socket.assigns.selected_agent)

    reads =
      read_concurrently(
        ring: fn -> Triage.ring_status(agent_id) end,
        receipts: fn -> Triage.list_receipts(org, filters["receipt_cursor"]) end,
        buckets: fn -> Triage.list_buckets(org, filters["bucket_cursor"]) end,
        bucket_detail: fn -> load_bucket_detail(org, filters["bucket"]) end
      )

    socket
    |> assign(reads)
    |> load_window_async()
  end

  # The heatmap aggregates 7 days, so it loads after the Timeline and never
  # delays or fails it. Filters and pages reuse it; only opening the Timeline,
  # switching Agent, or Refresh reads it again.
  defp load_heatmap_async(%{assigns: %{selected_agent: nil}} = socket),
    do: socket |> assign(:activity_heatmap, nil) |> assign(:heatmap_token, nil)

  defp load_heatmap_async(socket) do
    org = socket.assigns.current_org
    agent = socket.assigns.selected_agent
    roster = socket.assigns.router_agents
    token = make_ref()

    socket
    |> assign(:activity_heatmap, nil)
    |> assign(:heatmap_token, token)
    |> start_async({:heatmap, token}, fn -> Triage.product_heatmap(org, agent, roster) end)
  end

  # The 7-day receipt window is a scan that takes about a second on a cache
  # miss. On Data it only fills the collapsed diagnostics, so the tab renders
  # first and the window arrives later.
  defp load_window_async(socket) do
    org = socket.assigns.current_org
    token = make_ref()

    socket
    |> assign(:window, :loading)
    |> assign(:window_token, token)
    |> start_async({:window, token}, fn -> Triage.recent_window(org, window_since_ms()) end)
  end

  defp ensure_window(%{assigns: %{window: window, current_org: org}} = socket)
       when window in [nil, :loading],
       do:
         socket
         |> assign(:window, Triage.recent_window(org, window_since_ms()))
         |> assign(:window_token, nil)

  defp ensure_window(socket), do: socket

  defp load_evaluation_status(socket),
    do:
      assign(
        socket,
        :ring,
        Triage.ring_status(evaluation_agent_id(socket.assigns.selected_agent))
      )

  defp evaluation_agent_id(%{salix_agent_id: agent_id}) when is_binary(agent_id), do: agent_id
  defp evaluation_agent_id(_agent), do: nil

  defp load_activity_processing(socket, "receipt", id) do
    result =
      with :timeline <- socket.assigns.current_tab,
           {:ok, role} <-
             Memberships.org_role(socket.assigns.current_org.id, socket.assigns.current_user.id),
           true <- can_view_triage?(role),
           {:ok, %{intake: {:ok, %{items: items}}}} <- socket.assigns.product_activity,
           true <- Enum.any?(items, &(&1.receipt_ref == id)) do
        Triage.processing_detail(socket.assigns.current_org, socket.assigns.selected_agent, id)
      else
        _ -> {:error, :not_found}
      end

    assign(socket, :activity_processing, result)
  end

  defp load_activity_processing(socket, _kind, _id),
    do: assign(socket, :activity_processing, nil)

  defp processing_detail_item(item, {:ok, %{state: state} = detail})
       when state != :unavailable,
       do: Map.merge(item, detail)

  defp processing_detail_item(item, _result), do: item

  defp processing_detail_unavailable?({:ok, %{state: state}}), do: state == :unavailable
  defp processing_detail_unavailable?(_), do: true

  defp load_recent_processing(socket, since_ms, opts) do
    assign(
      socket,
      :recent_processing,
      Triage.recent_processing(socket.assigns.current_org, since_ms, opts)
    )
  end

  defp load_product_activity(%{assigns: %{selected_agent: nil}} = socket),
    do: assign_product_activity(socket, :no_agent)

  defp load_product_activity(socket),
    do: socket |> reset_product_activity() |> fetch_product_activity()

  defp reset_product_activity(%{assigns: %{selected_agent: nil}} = socket), do: socket

  defp reset_product_activity(socket) do
    socket
    |> assign(:feedback_selection, nil)
    |> assign(:model_debug_selection, nil)
    |> assign(:activity_selection, nil)
    |> assign(:activity_processing, nil)
    |> assign(:activity_navigation, %{cursors: [nil], kind: "all", channel: nil, before: nil})
  end

  defp fetch_product_activity(socket),
    do: assign_product_activity(socket, product_activity_read(socket, nil).())

  # `roster` is the `router_agents/1` result this socket holds, or nil
  # to make the read re-check the Agent against a fresh roster.
  defp product_activity_read(socket, roster) do
    org = socket.assigns.current_org
    agent = socket.assigns.selected_agent
    navigation = socket.assigns.activity_navigation

    opts = [
      limit: 20,
      context_limit: 20,
      page: true,
      include_intake: true,
      include_follow_ups: true,
      cursor: hd(navigation.cursors),
      kind: navigation.kind
    ]

    opts =
      if navigation.channel, do: Keyword.put(opts, :channel_id, navigation.channel), else: opts

    # Only a first page starts at `before`; later pages follow their cursor.
    opts =
      case {hd(navigation.cursors), navigation.before} do
        {nil, before} when is_integer(before) -> Keyword.put(opts, :before_ms, before)
        _page -> opts
      end

    opts = if roster, do: Keyword.put(opts, :router_agents, roster), else: opts

    fn -> Triage.product_activity(org, agent, opts) end
  end

  defp assign_product_activity(socket, :no_agent),
    do:
      socket
      |> assign(:product_activity, nil)
      |> assign(:delegation_tasks, %{})

  defp assign_product_activity(socket, activity) do
    socket
    |> assign(:model_debug_selection, nil)
    |> assign(:activity_selection, nil)
    |> assign(:activity_processing, nil)
    |> assign(:delegation_tasks, %{})
    |> assign(:product_activity, activity)
    |> reveal_timeline_sources()
    |> load_source_presentation()
  end

  defp load_source_presentation(socket) do
    refs =
      case socket.assigns.product_activity do
        {:ok, %{intake: {:ok, %{items: items}}}} ->
          items
          |> Enum.filter(&MapSet.member?(socket.assigns.revealed, &1.receipt_ref))
          |> Enum.map(& &1.receipt_ref)

        _ ->
          []
      end

    previous = socket.assigns.source_presentation_token
    socket = if previous, do: cancel_async(socket, {:source_presentation, previous}), else: socket
    token = make_ref()
    socket = assign(socket, :source_presentation_token, token)
    org = socket.assigns.current_org
    agent = socket.assigns.selected_agent

    if connected?(socket) and refs != [] do
      start_async(socket, {:source_presentation, token}, fn ->
        Triage.source_presentation(org, agent, refs)
      end)
    else
      socket
    end
  end

  defp reveal_timeline_sources(socket) do
    {outcomes, _context} = product_activity_sections(socket.assigns.product_activity)

    items =
      socket.assigns.product_activity
      |> product_timeline(outcomes, socket.assigns.activity_navigation, %{})
      |> Enum.flat_map(fn
        %{kind: :processing, item: item} -> [item]
        %{kind: :outcome, item: item} -> product_source_messages(item)
      end)
      |> Enum.filter(&is_binary(&1[:receipt_ref]))

    pending =
      items
      |> Enum.uniq_by(& &1.receipt_ref)
      |> Enum.reject(&MapSet.member?(socket.assigns.revealed, &1.receipt_ref))
      |> Enum.map(&%{receipt_ref: &1.receipt_ref, connect_id: &1[:connect_id]})

    if pending == [] do
      socket
    else
      recorded =
        Triage.record_text_reveals(
          socket.assigns.current_org,
          socket.assigns.current_user,
          pending,
          surface: "triage_timeline"
        )

      update(socket, :revealed, &MapSet.union(&1, recorded))
    end
  end

  defp active_context_run(%{project_id: project_id}, user),
    do: SlackHistoryOnboarding.active_context_run(project_id, user.id)

  defp active_context_run(_agent, _user), do: nil

  defp load_bucket_detail(_org, nil), do: nil
  defp load_bucket_detail(org, bucket_key), do: {bucket_key, Triage.get_bucket(org, bucket_key)}

  defp assign_selected_connect(socket, {:ok, %{connects: connects}}) when is_list(connects) do
    requested = socket.assigns.filters["connect"]

    agent_connects =
      socket.assigns.selected_agent
      |> agent_source_view({:ok, %{connects: connects, unavailable_groups: []}})
      |> Map.fetch!(:sources)

    selected =
      Enum.find(agent_connects, List.first(agent_connects), &(&1.connect_id == requested))

    assign(socket, :selected_connect, selected)
  end

  defp assign_selected_connect(socket, _unavailable), do: assign(socket, :selected_connect, nil)

  defp load_selected_channels(socket),
    do: assign(socket, :channels, selected_channels_read(socket).())

  defp selected_channels_read(%{assigns: %{selected_connect: connect}} = socket)
       when is_map(connect) do
    if selected_channel_read_available?(socket, connect) do
      org = socket.assigns.current_org
      fn -> Triage.list_slack_channels(org, connect) end
    else
      fn -> nil end
    end
  end

  defp selected_channels_read(_socket), do: fn -> nil end

  defp selected_channel_read_available?(
         %{assigns: %{current_tab: :context, slack_history_readiness: %{discovery?: true}}},
         connect
       ),
       do: context_source_ready?(connect)

  defp selected_channel_read_available?(%{assigns: %{current_tab: :overview}}, connect),
    do: monitoring_channel_controls_available?(connect)

  defp selected_channel_read_available?(_socket, _connect), do: false

  defp context_source_ready?(connect) do
    posture_complete?(connect) and connect[:source_ready?] == true and
      Enum.all?(
        [:connect_id, :connect_generation, :workspace_id, :app_id],
        &nonblank_ref?(connect[&1])
      )
  end

  defp nonblank_ref?(value), do: is_binary(value) and String.trim(value) != ""

  defp monitoring_channel_controls_available?(connect),
    do:
      posture_complete?(connect) and connect[:channel_scope_complete?] == true and
        connect[:channel_controls_available?] == true

  defp reset_slack_history_scope(socket) do
    socket
    |> assign(:slack_history_form, %{channel_ids: [], range_days: "7"})
    |> assign(:slack_history_scope_confirmed, false)
    |> assign(:slack_history_confirmed_scope, nil)
  end

  defp maybe_preselect_slack_history_form(
         %{
           assigns: %{
             current_tab: :context,
             filters: %{"step" => "range"},
             slack_history_form: %{channel_ids: []} = form,
             selected_connect:
               %{
                 channel_scope_complete?: true,
                 channel_controls_available?: true
               } = connect,
             channels: {:ok, %{channels: channels}}
           }
         } = socket
       )
       when is_map(connect) and is_list(channels) do
    eligible_ids =
      {:ok, %{channels: channels}}
      |> SlackContextSetup.eligible_channels()
      |> MapSet.new(& &1.id)

    selected =
      connect
      |> Map.get(:configured_channels, [])
      |> Enum.filter(&(&1[:enabled] == true))
      |> Enum.map(& &1[:channel_id])
      |> Enum.filter(&MapSet.member?(eligible_ids, &1))
      |> Enum.uniq()
      |> Enum.take(10)

    assign(socket, :slack_history_form, %{form | channel_ids: selected})
  end

  defp maybe_preselect_slack_history_form(socket), do: socket

  defp replacement_run_id(%{
         assigns: %{
           filters: %{"mode" => "reconnect"},
           slack_history_active_run: {:ok, %{id: run_id}}
         }
       }),
       do: run_id

  defp replacement_run_id(_socket), do: nil

  defp load_slack_history(%{assigns: %{selected_agent: %{project_id: project_id}}} = socket) do
    user_id = socket.assigns.current_user.id
    first_page = SlackHistoryOnboarding.list_runs_page(project_id, user_id)
    active_run = SlackHistoryOnboarding.active_context_run(project_id, user_id)

    runs =
      case first_page do
        {:ok, page} -> {:ok, page.runs}
        {:error, reason} -> {:error, reason}
      end

    history_page =
      case socket.assigns.slack_history_history_cursor do
        nil -> first_page
        cursor -> SlackHistoryOnboarding.list_runs_page(project_id, user_id, before: cursor)
      end

    preview =
      case runs do
        {:ok, [%{state: state} = run | _]}
        when state in ["preview_ready", "committed", "rolled_back"] ->
          Previews.get(run.id, socket.assigns.current_user.id)

        _other ->
          nil
      end

    socket
    |> assign(:slack_history_runs, runs)
    |> assign(:slack_history_active_run, active_run)
    |> assign(:slack_history_history_page, history_page)
    |> assign(:slack_history_preview, preview)
    |> assign(:slack_history_review, preview_review(runs, preview))
    |> assign(:slack_history_selected_artifact_ids, preview_artifact_ids(preview))
    |> assign(:slack_history_readiness, SlackHistoryOnboarding.readiness())
    |> assign(:slack_history_confirmed, false)
    |> assign(:slack_history_confirmed_review, nil)
    |> schedule_slack_history_poll()
  end

  defp load_slack_history(socket) do
    socket
    |> assign(:slack_history_runs, nil)
    |> assign(:slack_history_active_run, nil)
    |> assign(:slack_history_history_page, nil)
    |> assign(:slack_history_history_cursor, nil)
    |> assign(:slack_history_history_back, [])
    |> assign(:slack_history_preview, nil)
    |> assign(:slack_history_review, nil)
    |> assign(:slack_history_selected_artifact_ids, [])
    |> assign(:slack_history_readiness, SlackHistoryOnboarding.readiness())
    |> assign(:slack_history_confirmed, false)
    |> assign(:slack_history_confirmed_review, nil)
    |> assign(:slack_history_poll_token, nil)
  end

  # At most one five-second timer exists per connected Workbench socket. Each
  # tick reads the newest 20 runs and, only while an operator is paging older
  # evidence, that one additional 20-row ledger page. There is no per-run or
  # per-channel timer, so cost is bounded by open operator pages.
  defp schedule_slack_history_poll(socket) do
    active? =
      case socket.assigns.slack_history_runs do
        {:ok, [%{state: state, paused_reason: paused_reason} | _]} ->
          state in ["created", "acquiring", "acquired", "deriving"] or
            (state == "paused" and paused_reason != "bound_reached")

        _other ->
          false
      end

    if connected?(socket) and active? and is_nil(socket.assigns.slack_history_poll_token) do
      token = make_ref()
      Process.send_after(self(), {:refresh_slack_history, token}, 5_000)
      assign(socket, :slack_history_poll_token, token)
    else
      if active?, do: socket, else: assign(socket, :slack_history_poll_token, nil)
    end
  end

  defp authorized_slack_history_run(socket, run_id) do
    with %{project_id: project_id} <- socket.assigns.selected_agent,
         {:ok, run} <-
           SlackHistoryOnboarding.get_run(
             project_id,
             socket.assigns.current_user.id,
             run_id
           ),
         true <- run.org_id == socket.assigns.current_org.id do
      {:ok, run}
    else
      _error -> {:error, :not_found}
    end
  end

  defp preview_review({:ok, [%{state: "preview_ready"} = run | _]}, {:ok, _preview}),
    do: slack_history_review(run)

  defp preview_review(_runs, _preview), do: nil

  defp slack_history_review(run) do
    %{
      run_id: to_string(run.id),
      expected_generation: to_string(run.generation),
      snapshot_id: run.snapshot_id,
      derivation_id: run.derivation_id,
      review_revision_id: run.review_revision_id
    }
  end

  defp review_params_match?(params, review) when is_map(review) do
    Enum.all?(review, fn {key, value} -> same_ref?(params[to_string(key)], value) end)
  end

  defp review_params_match?(_params, _review), do: false

  defp preview_artifact_ids({:ok, %{items: items}}) when is_list(items),
    do: items |> Enum.map(&to_string(&1.artifact_id)) |> Enum.sort()

  defp preview_artifact_ids(_preview), do: []

  defp selected_review_artifact_ids(value, preview) do
    allowed = preview |> preview_artifact_ids() |> MapSet.new()

    value
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(allowed, &1))
    |> Enum.take(100)
    |> Enum.sort()
  end

  defp prepare_selected_review(run, preview, selected_artifact_ids, user_id) do
    selected = MapSet.new(selected_artifact_ids)
    all = preview.items |> Enum.map(&to_string(&1.artifact_id)) |> MapSet.new()

    if MapSet.equal?(selected, all) do
      {:ok, run}
    else
      items =
        preview.items
        |> Enum.filter(&MapSet.member?(selected, to_string(&1.artifact_id)))
        |> Enum.map(&%{artifact_id: &1.artifact_id})

      case Previews.revise(run.id, %{
             expected_generation: run.generation,
             user_id: user_id,
             parent_review_revision_id: run.review_revision_id,
             items: items
           }) do
        {:ok, %{run: revised_run}} -> {:ok, revised_run}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp load_slack_history_history_page(
         %{assigns: %{selected_agent: %{project_id: project_id}}} = socket,
         cursor
       ) do
    page =
      SlackHistoryOnboarding.list_runs_page(
        project_id,
        socket.assigns.current_user.id,
        before: cursor
      )

    assign(socket, :slack_history_history_page, page)
  end

  defp load_slack_history_history_page(socket, _cursor), do: socket

  defp channel_page({:ok, page}) when is_map(page), do: page
  defp channel_page(_other), do: nil

  defp channel_dialog_available?(socket) do
    socket.assigns.can_manage_triage and
      channel_controls_available?(
        socket.assigns.selected_connect,
        selected_connect_id(socket)
      ) and
      available_channel_options(socket.assigns.selected_connect, socket.assigns.channels) !=
        []
  end

  defp selected_connect_id(%{assigns: %{selected_connect: %{connect_id: connect_id}}}),
    do: connect_id

  defp selected_connect_id(_socket), do: nil

  defp reset_channel_dialog(socket) do
    socket
    |> assign(:show_channel_dialog, false)
    |> assign(:channel_dialog_query, "")
    |> assign(:channel_dialog_selection, [])
  end

  defp normalize_channel_ids(channel_ids) when is_list(channel_ids) do
    channel_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_channel_ids(_channel_ids), do: []

  defp normalize_channel_query(query) when is_binary(query),
    do: query |> String.trim() |> String.slice(0, 80)

  defp normalize_channel_query(_query), do: ""

  defp slack_history_scope(
         %{
           assigns: %{
             selected_agent: %{agent_id: agent_id, project_id: project_id},
             selected_connect: %{
               connect_id: connect_id,
               connect_generation: connect_generation,
               workspace_id: workspace_id,
               app_id: app_id
             }
           }
         },
         %{channel_ids: [_first | _rest] = channel_ids, range_days: range_days}
       ) do
    %{
      agent_id: agent_id,
      project_id: project_id,
      connect_id: connect_id,
      connect_generation: connect_generation,
      workspace_id: workspace_id,
      app_id: app_id,
      channel_ids: channel_ids,
      range_days: range_days
    }
  end

  defp slack_history_scope(_socket, _form), do: nil

  defp source_installation(connect) when is_map(connect) do
    Map.take(connect, [:connect_id, :connect_generation, :workspace_id, :app_id])
  end

  defp revalidate_slack_history_scope_confirmation(socket) do
    current_scope = slack_history_scope(socket, socket.assigns.slack_history_form)

    confirmed? =
      not is_nil(current_scope) and socket.assigns.slack_history_confirmed_scope == current_scope

    socket
    |> assign(:slack_history_scope_confirmed, confirmed?)
    |> assign(
      :slack_history_confirmed_scope,
      if(confirmed?, do: socket.assigns.slack_history_confirmed_scope, else: nil)
    )
  end

  defp selected_agent_connect?(socket, connect_id) do
    socket.assigns.selected_agent
    |> agent_source_view(socket.assigns.posture)
    |> Map.fetch!(:sources)
    |> Enum.any?(&same_ref?(&1[:connect_id], connect_id))
  end

  defp channel_allowed?(socket, connect_id, channel_id) do
    with %{connect_id: ^connect_id} <- socket.assigns.selected_connect,
         %{channels: channels} <- channel_page(socket.assigns.channels) do
      Enum.any?(channels, &(&1.id == channel_id))
    else
      _other -> false
    end
  end

  defp configured_channel?(connect, channel_id) do
    Enum.any?(connect[:configured_channels] || [], &(&1.channel_id == channel_id))
  end

  defp channel_controls_available?(%{connect_id: connect_id} = connect, connect_id),
    do:
      connect[:channel_scope_complete?] == true and
        connect[:channel_controls_available?] == true

  defp channel_controls_available?(_connect, _connect_id), do: false

  defp available_channel_options(connect, {:ok, %{channels: channels}}) do
    configured = MapSet.new(connect[:configured_channels] || [], & &1.channel_id)
    Enum.reject(channels, &MapSet.member?(configured, &1.id))
  end

  defp available_channel_options(_connect, _channels), do: []

  defp channel_dialog_options(channels, query) do
    normalized_query = query |> normalize_channel_query() |> String.downcase()

    channels
    |> Enum.filter(fn channel ->
      normalized_query == "" or
        String.contains?(String.downcase(channel.name || ""), normalized_query) or
        String.contains?(String.downcase(channel.id || ""), normalized_query)
    end)
    |> Enum.take(@channel_picker_visible_limit)
  end

  defp channel_page_truncated?({:ok, %{next_cursor: cursor}}),
    do: is_binary(cursor) and cursor != ""

  defp channel_page_truncated?(_channels), do: false

  # The picker degrades like every other section: a failed read is carried as a
  # tagged result and rendered as a fault. Collapsing it to `[]` here would put
  # "no router agents" — a statement about the org — on the screen when the
  # truth is that the database did not answer.
  defp agent_list({:ok, agents}), do: agents
  defp agent_list(_error), do: []

  defp select_agent([], _requested, _tab), do: nil

  defp select_agent(agents, requested, :context) when is_binary(requested),
    do: Enum.find(agents, &(&1.agent_id == requested))

  defp select_agent(_agents, _requested, :context), do: nil

  defp select_agent([first | _rest] = agents, requested, _tab) do
    Enum.find(agents, first, &(&1.agent_id == requested))
  end

  defp load_project_knowledge(nil), do: nil

  defp load_project_knowledge(agent) do
    ProjectKnowledge.list_for_agent(agent.agent_id)
  end

  defp load_sourced_context_knowledge(nil, _user), do: nil

  defp load_sourced_context_knowledge(agent, user) do
    Grounding.list_active_context_for_agent(agent.agent_id, user.id)
  end

  defp select_memory_agent([], _requested), do: nil

  defp select_memory_agent([first | _rest] = agents, requested) do
    Enum.find(agents, first, &(&1.agent_id == requested))
  end

  # Falling back to the first agent keeps the tab usable, but the operator
  # asked for a specific agent's memory and is now reading someone else's. That
  # substitution is rendered, never silent.
  defp requested_agent_missing?(agents, requested)
       when is_binary(requested) and requested != "",
       do: not Enum.any?(agents, &(&1.agent_id == requested))

  defp requested_agent_missing?(_agents, _requested), do: false

  defp load_memory(socket, nil) do
    socket
    |> assign(:memory_entries, nil)
    |> assign(:memory_file, nil)
  end

  defp load_memory(socket, agent) do
    filters = socket.assigns.filters
    path = memory_path(filters["path"])

    socket
    |> assign(:memory_entries, list_memory(agent, path))
    |> assign(:memory_file, read_memory(socket, agent, filters["file"]))
  end

  # The whole point of the guard: a path that is not inside `/memory` is
  # refused here, before the seam is called, whatever the query string says.
  defp memory_path(nil), do: @memory_root

  defp memory_path(path) when is_binary(path) do
    if memory_scoped?(path), do: path, else: @memory_root
  end

  defp memory_path(_path), do: @memory_root

  defp memory_scoped?(path) when is_binary(path) do
    (path == @memory_root or String.starts_with?(path, @memory_root <> "/")) and
      not String.contains?(path, "..") and not String.contains?(path, <<0>>)
  end

  defp memory_scoped?(_path), do: false

  defp list_memory(agent, path) do
    with {:ok, project} <- Projects.get_project(agent.project_id) do
      case Workspace.list_files(project, path, salix_agent_id: agent.salix_agent_id) do
        {:ok, entries} when is_list(entries) -> {:ok, %{path: path, entries: entries}}
        {:file, _entry} -> {:ok, %{path: path, entries: []}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_memory(_socket, _agent, nil), do: nil

  defp read_memory(socket, agent, path) when is_binary(path) do
    cond do
      not memory_scoped?(path) ->
        # An out-of-scope path is refused, and refused *visibly*: silently
        # rewriting it to the root would hide the attempt from the operator.
        {path, {:error, :out_of_scope}}

      connected?(socket) ->
        {path, do_read_memory(socket, agent, path)}

      true ->
        # The dead render is skipped deliberately. `handle_params/3` runs twice
        # for one page view — once for the HTTP response, once on connect — and
        # reading the body in both would ship the same file to the same
        # operator twice and write two access records for one act. The audit
        # trail has to match what the operator did, so the body is read once,
        # on the render that survives.
        nil
    end
  end

  # Memory bodies are the one tab surface that is not redacted metadata: the
  # file is raw user data the agent distilled out of the conversations it
  # triaged. So the read is audited with the same strictness as a text reveal —
  # the row is written *before* the seam is asked for the body, and an audit
  # that cannot be persisted refuses the read instead of degrading it (owner
  # decision, 2026-08-19; RFC §7). The audit precedes the fetch deliberately:
  # nothing can then order a body ahead of its own access record.
  #
  # Which is also why the pre-fetch row records an *attempt* rather than a read:
  # at write time the fetch has not happened yet, and it can still come back
  # `:not_found`, stale, or timed out. The outcome is reported after the seam
  # answers, and only when it failed — so one operator view of a file that is
  # actually there stays one row, while a view that rendered nothing appends the
  # row saying so instead of leaving a row that claims a successful read.
  #
  # `path` reaches the audit and the seam as the same binary, so the row's
  # `resource_id` names the key that was actually fetched.
  defp do_read_memory(socket, agent, path) do
    case Triage.record_memory_read_attempt(
           socket.assigns.current_org,
           socket.assigns.current_user,
           agent,
           path,
           surface: "triage_memory"
         ) do
      {:ok, request_id} ->
        finish_memory_read(socket, agent, path, request_id)

      # The one failure with no seam call behind it: the body was never asked
      # for, so there is no fetch outcome to report.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_memory_read(socket, agent, path, request_id) do
    case fetch_memory(agent, path) do
      {:ok, body} when is_binary(body) ->
        {:ok, truncate_memory(body)}

      # A directory listing where a file body was asked for: the seam answered,
      # but not with a body, so the read did not succeed either.
      {:ok, _other} ->
        record_memory_read_failure(socket, agent, path, :unavailable, request_id)

      {:error, reason} ->
        record_memory_read_failure(socket, agent, path, reason, request_id)
    end
  end

  defp fetch_memory(agent, path) do
    with {:ok, project} <- Projects.get_project(agent.project_id) do
      Workspace.read_file(project, path, salix_agent_id: agent.salix_agent_id)
    end
  end

  # Same `request_id` as the attempt row, so the pair reads back as one operator
  # action that ended in nothing being rendered.
  defp record_memory_read_failure(socket, agent, path, reason, request_id) do
    Triage.record_memory_read_failure(
      socket.assigns.current_org,
      socket.assigns.current_user,
      agent,
      path,
      reason,
      surface: "triage_memory",
      request_id: request_id
    )

    {:error, reason}
  end

  defp truncate_memory(body) when byte_size(body) > @memory_file_limit_bytes do
    head = body |> binary_part(0, @memory_file_limit_bytes) |> valid_utf8_prefix()
    %{body: head, truncated?: true}
  end

  defp truncate_memory(body), do: %{body: body, truncated?: false}

  # `binary_part/3` cuts on a byte boundary, so it can split a multi-byte
  # character — likely here, since memory files are mostly prose. The partial
  # character is invalid UTF-8, which survives the dead render but crashes the
  # LiveView socket's JSON encoder on every diff, leaving the page in a
  # reconnect loop rather than showing an error. Drop it.
  defp valid_utf8_prefix(binary) do
    case :unicode.characters_to_binary(binary) do
      valid when is_binary(valid) -> valid
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
    end
  end

  defp window_since_ms do
    since = System.system_time(:millisecond) - @window_days * 24 * 60 * 60 * 1000
    div(since, @window_quantum_ms) * @window_quantum_ms
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="triage-workbench"
      class={[@current_tab == :context && "flex min-h-0 flex-1 flex-col", @current_tab != :context && "space-y-5"]}
    >
      <div :if={@current_tab != :context} class="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
        <div class="min-w-0">
          <h1 class="text-lg font-semibold tracking-tight text-neutral-900">
            {gettext("Triage")}
          </h1>
          <p class="mt-1 max-w-[78ch] text-sm leading-relaxed text-neutral-500">
            {gettext(
              "Turn collaboration streams into traceable project knowledge, then see where an Agent used it. Slack is the first supported source for %{name}.",
              name: @current_org.name
            )}
          </p>
        </div>
        <.agent_picker
          :if={ok?(@router_agents) and agent_list(@router_agents) != []}
          agents={agent_list(@router_agents)}
          selected_agent={@selected_agent}
          selected_connect={@selected_connect}
          source_posture={@agent_source_posture}
        />
      </div>

      <.section_fault
        :if={@current_tab != :context and faulted?(@router_agents)}
        result={@router_agents}
        label={gettext("Agents")}
      />
      <.notice :if={@current_tab != :context and @selected_agent_missing? and @selected_agent} tone="amber">
        {gettext(
          "The requested Agent is not available in this organization. Showing %{name} instead.",
          name: agent_label(@selected_agent)
        )}
      </.notice>

      <.tabs :if={@current_tab != :context} id="triage-tabs">
        <:tab
          :for={tab <- @tabs}
          label={tab_label(tab)}
          patch={tab_path(@current_org, tab, nav_filters(@filters))}
          active={@current_tab == tab}
        />
      </.tabs>

      <.workbench_loading :if={not @loaded?} tab={@current_tab} />

      <div :if={@loaded?} data-role="workbench-content" class={[@current_tab == :context && "flex min-h-0 flex-1 flex-col", @current_tab != :context && "space-y-5"]}>
      <.overview
        :if={@current_tab == :overview}
        posture={@posture}
        selected_agent={@selected_agent}
        selected_connect={@selected_connect}
        channels={@channels}
        can_manage={@can_manage_triage}
        org={@current_org}
        show_channel_dialog={@show_channel_dialog}
        channel_dialog_query={@channel_dialog_query}
        channel_dialog_selection={@channel_dialog_selection}
        ring={@ring}
      />
      <.live_component
        :if={@current_tab == :overview and @selected_agent}
        module={BridgeForTeamsWeb.Dashboard.TriageLive.WorkerConfiguration}
        id="triage-worker-settings"
        current_org={@current_org}
        current_user={@current_user}
        selected_agent={@selected_agent}
      />
      <SlackContextSetup.summary
        :if={
          @slack_history_readiness.onboarding_preview? and @current_tab == :overview and
            @selected_agent
        }
        can_manage={@can_manage_triage}
        selected_connect={@selected_connect}
        source_view={agent_source_view(@selected_agent, @posture)}
        runs={@slack_history_runs}
        active_run={@slack_history_active_run}
        readiness={@slack_history_readiness}
        org={@current_org}
        agent={@selected_agent}
      />
      <SlackContextSetup.task
        :if={@current_tab == :context and @selected_agent}
        readiness={@slack_history_readiness}
        can_manage={@can_manage_triage}
        selected_connect={@selected_connect}
        source_view={agent_source_view(@selected_agent, @posture)}
        channels={@channels}
        runs={@slack_history_runs}
        active_run={@slack_history_active_run}
        history={@slack_history_history_page}
        history_previous?={@slack_history_history_back != []}
        preview={@slack_history_preview}
        selected_artifact_ids={@slack_history_selected_artifact_ids}
        form={@slack_history_form}
        scope_confirmed?={@slack_history_scope_confirmed}
        confirmed?={@slack_history_confirmed}
        client_request_id={@slack_history_client_request_id}
        org={@current_org}
        agent={@selected_agent}
        filters={@filters}
      />
      <SlackContextSetup.agent_required
        :if={@current_tab == :context and is_nil(@selected_agent)}
        org={@current_org}
        agents={@router_agents}
      />
      <.timeline
        :if={@current_tab == :timeline}
        window={@window}
        window_days={@window_days}
        org={@current_org}
        revealed={@revealed}
        knowledge={@project_knowledge}
        agent={@selected_agent}
        source_posture={@agent_source_posture}
        selected_assertion={@selected_assertion}
        recent_processing={@recent_processing}
        product_activity={@product_activity}
        activity_heatmap={@activity_heatmap}
        activity_navigation={@activity_navigation}
        activity_selection={@activity_selection}
        activity_processing={@activity_processing}
        model_debug_selection={@model_debug_selection}
        can_debug={@can_manage_triage}
        feedback_selection={@feedback_selection}
        delegation_tasks={@delegation_tasks}
      />
      <.knowledge
        :if={@current_tab == :knowledge}
        knowledge={@project_knowledge}
        sourced_context={@sourced_context_knowledge}
        agent={@selected_agent}
        filters={@filters}
        org={@current_org}
        can_manage={@can_manage_triage}
        onboarding_preview?={@slack_history_readiness.onboarding_preview?}
        grounding?={@slack_history_readiness.grounding?}
        inspection?={@slack_history_readiness.knowledge_inspection?}
        active_context={@slack_history_active_run}
      />
      <.memory
        :if={@current_tab == :memory}
        org={@current_org}
        router_agents={@router_agents}
        memory_agent={@memory_agent}
        memory_agent_missing?={@memory_agent_missing?}
        memory_entries={@memory_entries}
        memory_file={@memory_file}
      />
      <.data
        :if={@current_tab == :data}
        org={@current_org}
        filters={@filters}
        window={@window}
        window_days={@window_days}
        ring={@ring}
        receipts={@receipts}
        buckets={@buckets}
        bucket_detail={@bucket_detail}
        revealed={@revealed}
      />
      </div>
    </div>
    """
  end

  attr(:tab, :atom, required: true)

  # Shown by the first HTTP render, before the connected mount reads Salix.
  defp workbench_loading(assigns) do
    ~H"""
    <div id="triage-workbench-loading" role="status" aria-live="polite" class="space-y-4">
      <span class="sr-only">{gettext("Loading Triage…")}</span>
      <div class="rounded-lg border border-neutral-200 bg-white p-4">
        <div class="h-4 w-40 animate-pulse rounded bg-neutral-100"></div>
        <div class="mt-3 h-3 w-64 max-w-full animate-pulse rounded bg-neutral-100"></div>
        <div class="mt-5 space-y-3">
          <div :for={_ <- 1..3} class="h-10 animate-pulse rounded-md bg-neutral-50"></div>
        </div>
      </div>
      <div :if={@tab != :overview} class="rounded-lg border border-neutral-200 bg-white p-4">
        <div :for={_ <- 1..3} class="mb-4 space-y-2 last:mb-0">
          <div class="h-3 w-32 animate-pulse rounded bg-neutral-100"></div>
          <div class="h-3 w-full animate-pulse rounded bg-neutral-50"></div>
          <div class="h-3 w-2/3 animate-pulse rounded bg-neutral-50"></div>
        </div>
      </div>
    </div>
    """
  end

  attr(:agents, :list, required: true)
  attr(:selected_agent, :map, required: true)
  attr(:selected_connect, :map, default: nil)
  attr(:source_posture, :any, required: true)

  defp agent_picker(assigns) do
    options =
      Enum.map(assigns.agents, fn agent ->
        %{agent: agent, source_view: agent_source_view(agent, assigns.source_posture)}
      end)

    assigns =
      assigns
      |> assign(:option_groups, agent_option_groups(options))
      |> assign(
        :selected_source_view,
        assigns.selected_agent
        |> agent_source_view(assigns.source_posture)
        |> prioritize_source(assigns.selected_connect)
      )

    ~H"""
    <div class="w-full max-w-sm">
      <label id="triage-agent-picker-label" class="mb-1 block text-xs font-medium text-neutral-600">
        {gettext("Current Agent")}
      </label>
      <details
        id="triage-agent-picker"
        class="group relative"
        phx-mounted={JS.ignore_attributes("open")}
        phx-click-away={JS.remove_attribute("open", to: "#triage-agent-picker")}
        phx-window-keydown={JS.remove_attribute("open", to: "#triage-agent-picker")}
        phx-key="escape"
      >
        <summary
          aria-labelledby="triage-agent-picker-label"
          class="grid min-h-14 cursor-pointer list-none grid-cols-[2rem_minmax(0,1fr)_1rem] items-center gap-2.5 rounded-lg border border-neutral-300 bg-white px-2.5 py-2 text-left marker:hidden hover:border-neutral-400 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 group-open:border-brand-300 group-open:ring-2 group-open:ring-brand-100"
        >
          <span class="grid h-8 w-8 place-items-center rounded-lg bg-brand-600 text-[0.65rem] font-semibold text-white">
            {agent_initials(@selected_agent)}
          </span>
          <span class="min-w-0">
            <span class="flex min-w-0 items-center gap-1.5">
              <strong class="truncate text-xs font-semibold text-neutral-900">
                {agent_label(@selected_agent)}
              </strong>
              <span
                :if={agent_project_badge?(@selected_agent)}
                class="shrink-0 rounded bg-neutral-100 px-1.5 py-0.5 text-[0.625rem] font-medium text-neutral-500"
              >
                {@selected_agent.project_name}
              </span>
            </span>
            <span class={[
              "mt-1 block truncate text-[0.6875rem]",
              @selected_source_view.state == :unavailable && "text-amber-700",
              @selected_source_view.state != :unavailable && "text-neutral-500"
            ]}>
              {agent_source_summary(@selected_source_view)}
            </span>
          </span>
          <.icon
            name="chevron-down"
            variant="outlined"
            class="h-4 w-4 text-neutral-400 transition-transform group-open:rotate-180"
          />
        </summary>

        <div class="absolute right-0 top-[calc(100%+0.375rem)] z-40 w-full rounded-lg border border-neutral-200 bg-white shadow-popover">
          <div role="listbox" aria-labelledby="triage-agent-picker-label" class="max-h-80 overflow-y-auto p-1.5">
            <div :for={group <- @option_groups} :if={group.total > 0} role="group" aria-labelledby={"triage-agent-group-#{group.key}"}>
              <div id={"triage-agent-group-#{group.key}"} class="flex items-center justify-between px-2 py-2 text-[0.6875rem] font-medium text-neutral-500">
                <span>{group.label}</span>
                <span>{group.total}</span>
              </div>
          <button
            :for={option <- group.options}
            id={"triage-agent-option-#{option.agent.agent_id}"}
            type="button"
            role="option"
            aria-selected={
              to_string(option.agent.agent_id == @selected_agent.agent_id)
            }
            phx-click={
              JS.push("select-agent", value: %{agent: option.agent.agent_id})
              |> JS.remove_attribute("open", to: "#triage-agent-picker")
            }
            class={[
              "grid w-full grid-cols-[2rem_minmax(0,1fr)_1rem] items-start gap-2.5 rounded-md px-2 py-2 text-left hover:bg-neutral-50",
              option.agent.agent_id == @selected_agent.agent_id && "bg-neutral-50"
            ]}
          >
            <span class="grid h-8 w-8 place-items-center rounded-lg bg-brand-600 text-[0.65rem] font-semibold text-white">
              {agent_initials(option.agent)}
            </span>
            <span class="min-w-0">
              <span class="flex min-w-0 items-center gap-1.5">
                <strong class="truncate text-xs font-semibold text-neutral-900">
                  {agent_label(option.agent)}
                </strong>
                <span
                  :if={agent_project_badge?(option.agent)}
                  class="shrink-0 rounded bg-neutral-100 px-1.5 py-0.5 text-[0.625rem] font-medium text-neutral-500"
                >
                  {option.agent.project_name}
                </span>
              </span>
              <span :if={option.source_view.sources != []} class="mt-1 block space-y-0.5">
                <span
                  :for={source <- option.source_view.sources}
                  class="block truncate text-[0.6875rem] text-neutral-500"
                >
                  {slack_source_label(source)}
                </span>
                <span
                  :if={option.source_view.state == :partial}
                  class="block text-[0.6875rem] text-amber-700"
                >
                  {gettext("Some Slack connection status is unavailable")}
                </span>
              </span>
              <span
                :if={option.source_view.sources == []}
                class={[
                  "mt-1 block text-[0.6875rem]",
                  option.source_view.state == :unavailable && "text-amber-700",
                  option.source_view.state != :unavailable && "text-neutral-500"
                ]}
              >
                {agent_source_summary(option.source_view)}
              </span>
            </span>
            <.icon
              :if={option.agent.agent_id == @selected_agent.agent_id}
              name="check"
              variant="outlined"
              class="mt-1 h-4 w-4 text-brand-600"
            />
          </button>
            </div>
          </div>
        </div>
      </details>
    </div>
    """
  end

  # ---- overview ----

  attr(:posture, :any, required: true)
  attr(:selected_agent, :map, required: true)
  attr(:selected_connect, :any, required: true)
  attr(:channels, :any, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:org, :map, required: true)
  attr(:show_channel_dialog, :boolean, required: true)
  attr(:channel_dialog_query, :string, required: true)
  attr(:channel_dialog_selection, :list, required: true)
  attr(:ring, :any, required: true)

  defp overview(assigns) do
    assigns =
      assign(
        assigns,
        :sources,
        agent_source_view(assigns.selected_agent, assigns.posture).sources
      )

    ~H"""
    <div id="triage-overview" class="space-y-4">
      <.section_fault :if={faulted?(@posture)} result={@posture} label={gettext("Slack assistants")} />

      <div :if={ok?(@posture)} class="space-y-3">
        <.empty_state
          :if={unwrap(@posture).connects == []}
          icon="chat-bubble"
          title={gettext("No Slack assistants yet")}
          description={gettext("Connect a Slack assistant before setting up Triage channels.")}
        >
          <:actions>
            <.link
              navigate={~p"/orgs/#{@org.slug}/projects"}
              class="inline-flex h-9 items-center rounded-md bg-brand-500 px-3 text-sm font-medium text-white hover:bg-brand-600"
            >
              {gettext("Choose a project to connect Slack")}
            </.link>
          </:actions>
        </.empty_state>

        <.assistant_workspace
          :if={@selected_connect}
          sources={@sources}
          connect={@selected_connect}
          channels={@channels}
          can_manage={@can_manage}
          show_channel_dialog={@show_channel_dialog}
          channel_dialog_query={@channel_dialog_query}
          channel_dialog_selection={@channel_dialog_selection}
          ring={@ring}
        />

        <.empty_state
          :if={unwrap(@posture).connects != [] and @sources == []}
          icon="chat-bubble"
          title={gettext("No Slack source connected to this Agent")}
          description={gettext("Choose another Agent, or connect Slack for this Agent from its project settings.")}
        />

        <.unavailable_groups groups={unwrap(@posture).unavailable_groups} />
      </div>
    </div>
    """
  end

  attr(:sources, :list, required: true)
  attr(:connect, :map, required: true)
  attr(:channels, :any, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:show_channel_dialog, :boolean, required: true)
  attr(:channel_dialog_query, :string, required: true)
  attr(:channel_dialog_selection, :list, required: true)
  attr(:ring, :any, required: true)

  defp assistant_workspace(assigns) do
    available_channels = available_channel_options(assigns.connect, assigns.channels)
    visible_channels = channel_dialog_options(available_channels, assigns.channel_dialog_query)
    visible_ids = MapSet.new(visible_channels, & &1.id)

    assigns =
      assigns
      |> assign(:available_channels, available_channels)
      |> assign(:visible_channel_options, visible_channels)
      |> assign(
        :hidden_channel_selection,
        Enum.reject(assigns.channel_dialog_selection, &MapSet.member?(visible_ids, &1))
      )
      |> assign(:channel_dialog_truncated?, channel_page_truncated?(assigns.channels))

    ~H"""
    <div id="triage-assistant-workspace" class="space-y-4">
      <.card>
        <:title>{blank_dash(slack_bot_name(@connect))}</:title>
        <div class="space-y-4">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="min-w-0 space-y-1 text-sm">
              <p class="text-neutral-700">{slack_source_meta(@connect)}</p>
              <p class="text-xs text-neutral-500">{blank_dash(@connect.project_name)}</p>
            </div>
            <div class="flex items-center gap-2">
              <.switch_control connect={@connect} can_manage={@can_manage} />
            </div>
          </div>

          <div :if={length(@sources) > 1} id="triage-source-picker" class="border-t border-neutral-100 pt-4">
            <.section_label>{gettext("Slack source")}</.section_label>
            <p class="mt-1 text-sm text-neutral-500">
              {gettext("Choose which bot and workspace to manage for this Agent.")}
            </p>
            <div class="mt-3 grid gap-2 sm:grid-cols-2">
              <button
                :for={source <- @sources}
                id={"triage-source-option-#{source.connect_id}"}
                type="button"
                aria-selected={to_string(same_ref?(source.connect_id, @connect.connect_id))}
                phx-click="select-assistant"
                phx-value-connect={source.connect_id}
                class={[
                  "min-w-0 rounded-lg border px-3 py-2 text-left transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500",
                  same_ref?(source.connect_id, @connect.connect_id) &&
                    "border-brand-300 bg-brand-50",
                  not same_ref?(source.connect_id, @connect.connect_id) &&
                    "border-neutral-200 bg-white hover:border-neutral-300"
                ]}
              >
                <span class="block truncate text-sm font-medium text-neutral-900">
                  {slack_bot_name(source, gettext("Bot name unavailable"))}
                </span>
                <span class="mt-0.5 block truncate text-xs text-neutral-500">
                  {slack_source_meta(source)}
                </span>
                <span
                  :if={not posture_complete?(source)}
                  class="mt-1 block text-xs font-medium text-amber-700"
                >
                  {gettext("Connection status unavailable")}
                </span>
              </button>
            </div>
          </div>

          <div class="border-t border-neutral-100 pt-4">
            <div class="flex items-start justify-between gap-4">
              <div>
                <.section_label>{gettext("Slack channels")}</.section_label>
                <p class="mt-1 text-sm text-neutral-500">
                  {gettext("Choose which channels this assistant monitors for ambient information. Each channel can be paused independently.")}
                </p>
              </div>
              <.button
                :if={
                  (@connect[:configured_channels] || []) != [] and @available_channels != [] and
                    @can_manage
                }
                id="open-triage-channel-dialog"
                type="button"
                variant="secondary"
                size="sm"
                class="shrink-0 whitespace-nowrap"
                phx-click="open-channel-dialog"
              >
                {gettext("Add monitoring channels")}
              </.button>
            </div>

            <div :if={(@connect[:configured_channels] || []) != []} class="mt-3 divide-y divide-neutral-100 rounded-lg border border-neutral-200">
              <div
                :for={channel <- @connect[:configured_channels] || []}
                id={"triage-channel-#{channel.channel_id}"}
                class="flex items-center justify-between gap-4 px-3 py-3"
              >
                <div class="min-w-0">
                  <p class="truncate text-sm font-medium text-neutral-900">#{channel.channel_name}</p>
                  <p class="mt-0.5 text-xs text-neutral-500">
                    {if channel.enabled, do: gettext("Included in ambient Triage monitoring"), else: gettext("Paused")}
                  </p>
                </div>
                <.toggle
                  id={"triage-channel-toggle-#{channel.channel_id}"}
                  name={"triage-channel-toggle-#{channel.channel_id}"}
                  checked={channel.enabled}
                  disabled={
                    not @can_manage or @connect[:channel_scope_complete?] == false or
                      @connect[:channel_controls_available?] != true
                  }
                  phx-click="set-triage-channel"
                  phx-value-connect={@connect.connect_id}
                  phx-value-channel={channel.channel_id}
                  phx-value-action={if channel.enabled, do: "pause", else: "enable"}
                />
              </div>
            </div>

            <.notice
              :if={
                posture_complete?(@connect) and @connect[:channel_scope_complete?] == false
              }
              tone="amber"
            >
              {gettext("Configured channels could not be read completely, so channel controls are unavailable.")}
            </.notice>

            <.notice
              :if={
                posture_complete?(@connect) and
                  @connect[:channel_scope_complete?] != false and
                  @connect[:channel_controls_available?] != true
              }
              tone="amber"
            >
              {channel_upgrade_notice(@connect)}
            </.notice>

            <.empty_state
              :if={
                posture_complete?(@connect) and
                  @connect[:channel_scope_complete?] != false and
                  (@connect[:configured_channels] || []) == []
              }
              icon="inbox"
              title={gettext("No channels configured")}
              description={gettext("Add one or more Slack channels before turning on Triage monitoring.")}
            >
              <:actions :if={@available_channels != [] and @can_manage}>
                <.button
                  id="open-triage-channel-dialog-empty"
                  type="button"
                  variant="primary"
                  size="sm"
                  phx-click="open-channel-dialog"
                >
                  {gettext("Add monitoring channels")}
                </.button>
              </:actions>
            </.empty_state>
          </div>

          <div
            :if={
              posture_complete?(@connect) and @connect[:channel_scope_complete?] == true and
                @connect[:channel_controls_available?] == true and
                (faulted?(@channels) or
                   (ok?(@channels) and @available_channels == [] and
                      (@connect[:configured_channels] || []) != []))
            }
            class="space-y-3 border-t border-neutral-100 pt-4"
          >
            <.notice :if={faulted?(@channels)} tone="amber">
              {gettext(
                "Slack's channel list cannot be refreshed right now. Your configured channels are still shown and can be managed; try adding channels again later."
              )}
            </.notice>
            <.empty_state
              :if={
                ok?(@channels) and @available_channels == [] and
                  (@connect[:configured_channels] || []) != []
              }
              icon="inbox"
              title={gettext("No additional Slack channels available")}
              description={gettext("Invite this Slack assistant to another channel, then try again.")}
            />
          </div>

          <.notice :if={not posture_complete?(@connect)} tone="amber">
            {posture_unavailable_notice(@connect)}
          </.notice>

          <.evaluation_status ring={@ring} monitoring?={monitoring_active?(@connect)} />
        </div>
      </.card>

      <.modal
        :if={@show_channel_dialog}
        id="triage-channel-dialog"
        show
        on_cancel={JS.push("close-channel-dialog")}
      >
        <:title>{gettext("Add monitoring channels")}</:title>

        <form
          id="triage-channel-form"
          phx-change="change-channel-dialog"
          phx-submit="provision-triage"
          class="space-y-4"
        >
          <input type="hidden" name="connect" value={@connect.connect_id} />
          <input
            :for={channel_id <- @hidden_channel_selection}
            type="hidden"
            name="channel_ids[]"
            value={channel_id}
          />

          <div>
            <label for="triage-channel-search" class="block text-xs font-medium text-neutral-700">
              {gettext("Search Slack channels")}
            </label>
            <input
              id="triage-channel-search"
              type="search"
              name="query"
              value={@channel_dialog_query}
              placeholder={gettext("Search by channel name")}
              phx-debounce="150"
              autocomplete="off"
              class="mt-1 h-10 w-full rounded-md border border-neutral-300 bg-white px-3 text-sm text-neutral-900 outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
            />
          </div>

          <div class="space-y-2" role="group" aria-label={gettext("Slack channels") }>
            <label
              :for={channel <- @visible_channel_options}
              for={"triage-channel-option-#{channel.id}"}
              class="flex cursor-pointer items-center gap-3 rounded-lg border border-neutral-200 px-3 py-2.5 transition hover:border-neutral-300 hover:bg-neutral-50"
            >
              <input
                id={"triage-channel-option-#{channel.id}"}
                type="checkbox"
                name="channel_ids[]"
                value={channel.id}
                checked={channel.id in @channel_dialog_selection}
                class="h-4 w-4 rounded border-neutral-300 text-brand-600 focus:ring-brand-500"
              />
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm font-medium text-neutral-900">
                  #{channel.name}
                </span>
                <span :if={channel.private?} class="mt-0.5 block text-xs text-neutral-500">
                  {gettext("Private channel")}
                </span>
              </span>
            </label>

            <.empty_state
              :if={@visible_channel_options == []}
              icon="magnifying-glass"
              title={gettext("No matching channels")}
              description={gettext("Try another channel name.")}
              class="py-8"
            />
          </div>

          <p class="text-xs text-neutral-500">
            {ngettext(
              "1 channel selected",
              "%{count} channels selected",
              length(@channel_dialog_selection),
              count: length(@channel_dialog_selection)
            )}
          </p>
          <p :if={@channel_dialog_truncated?} class="text-xs text-neutral-500">
            {gettext("Large workspaces show the first 100 channels returned by Slack.")}
          </p>
        </form>

        <:footer>
          <.button type="button" variant="secondary" phx-click="close-channel-dialog">
            {gettext("Cancel")}
          </.button>
          <.button
            type="submit"
            form="triage-channel-form"
            variant="primary"
            disabled={@channel_dialog_selection == []}
          >
            {gettext("Add selected channels")}
          </.button>
        </:footer>
      </.modal>
    </div>
    """
  end

  attr(:window, :any, required: true)
  attr(:window_days, :integer, required: true)

  defp window_stats(assigns) do
    ~H"""
    <div>
      <p :if={@window == :loading} role="status" class="text-sm text-neutral-500">
        {gettext("Loading the recent window…")}
      </p>
      <.section_fault :if={faulted?(@window)} result={@window} label={gettext("Recent window")} />
      <div :if={ok?(@window)} class="space-y-3">
        <div class="grid grid-cols-2 gap-3 xl:grid-cols-4">
          <.stat_card
            label={gettext("Received")}
            value={length(unwrap(@window).receipts)}
            detail={
              ngettext(
                "Typed receipt in the last %{count} day",
                "Typed receipts in the last %{count} days",
                @window_days
              )
            }
          />
          <.stat_card
            label={gettext("Connects")}
            value={map_size(unwrap(@window).owners)}
            detail={gettext("Connects with a received message in the window")}
          />
          <.stat_card
            label={gettext("Pages scanned")}
            value={unwrap(@window).scanned_pages}
            detail={gettext("The receipt keyspace is key-ordered, so this is a scan, not a query")}
          />
          <.stat_card
            label={gettext("Skipped")}
            value={
              unwrap(@window).legacy_count + unwrap(@window).invalid_count +
                unavailable_count(unwrap(@window))
            }
            detail={
              gettext("Legacy, malformed, and unreadable objects the scan could not emit")
            }
          />
        </div>

        <.notice :if={unwrap(@window).truncated} tone="amber">
          {gettext(
            "The scan budget ran out before the window completed: rows may be missing. These counts are a floor, not a total."
          )}
        </.notice>
        <.notice :if={unavailable_count(unwrap(@window)) > 0} tone="amber">
          {gettext(
            "%{count} objects in this window could not be read. Unreadable is not absent: those received messages may exist and are simply missing from the counts above.",
            count: unavailable_count(unwrap(@window))
          )}
        </.notice>
        <.scope_notice result={@window} />
        <.empty_state
          :if={unwrap(@window).receipts == []}
          icon="inbox"
          title={gettext("No received messages in the visible window")}
          description={window_empty_description(unwrap(@window), @window_days)}
        />
        <.notice tone="neutral">
          {gettext(
            "The ledger shows durable receipts only. Ignored and fail-closed events write nothing by design — a safety property, not a gap — so \"what was dropped\" is not answerable from this page. A receipt proves the message was received, not that AI evaluated it."
          )}
        </.notice>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)
  attr(:id, :string, default: nil)

  # The mock's stat tile: the number leads, the label names it, the third line
  # is the caveat. Reading order is size, not position.
  defp stat_card(assigns) do
    ~H"""
    <div id={@id} class="h-full rounded-lg border border-neutral-200 bg-white px-4 py-3 shadow-subtle">
      <div class="text-2xl font-semibold leading-none tabular-nums text-neutral-900">{@value}</div>
      <div class="mt-2 text-xs font-medium text-neutral-500">{@label}</div>
      <div class="mt-1 text-[11px] leading-snug text-neutral-400">{@detail}</div>
    </div>
    """
  end

  attr(:tone, :string, default: "neutral", values: ~w(neutral brand green amber red))
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  # One pill treatment for every semantic label on this page. The pairs are the
  # dashboard's own notice palette (amber-50/amber-900, red-50/red-900,
  # brand-50/brand-700) taken down to chip scale, so a status here reads the
  # same as the banner that would explain it.
  defp chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium leading-5",
      chip_tone(@tone),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp chip_tone("brand"), do: "bg-brand-50 text-brand-700"
  defp chip_tone("green"), do: "bg-green-50 text-green-700"
  defp chip_tone("amber"), do: "bg-amber-50 text-amber-800"
  defp chip_tone("red"), do: "bg-red-50 text-red-700"
  defp chip_tone(_neutral), do: "bg-neutral-100 text-neutral-600"

  attr(:ms, :integer, required: true)

  attr(:format, :string,
    required: true,
    values: ~w(month-day-time month-day time time-seconds date-time)
  )

  attr(:fallback, :string, required: true)
  attr(:rest, :global)

  defp browser_local_time(assigns) do
    iso8601 =
      case DateTime.from_unix(assigns.ms, :millisecond) do
        {:ok, datetime} -> DateTime.to_iso8601(datetime)
        _invalid -> nil
      end

    assigns = assign(assigns, :iso8601, iso8601)

    ~H"""
    <time
      datetime={@iso8601}
      data-local-time-ms={@ms}
      data-local-time-format={@format}
      {@rest}
    >{@fallback}</time>
    """
  end

  slot(:inner_block, required: true)

  # `fast_path` and its kind are qualifiers on a decision, not the decision, so
  # they get the mock's outlined tag rather than a filled chip.
  defp tag(assigns) do
    ~H"""
    <span class="inline-flex items-center whitespace-nowrap rounded border border-brand-200 px-1.5 text-[10px] font-medium uppercase tracking-wide text-brand-700">
      {render_slot(@inner_block)}
    </span>
    """
  end

  slot(:inner_block, required: true)

  # The small-caps section label the mock uses to head a group without
  # spending a heading level on it.
  defp section_label(assigns) do
    ~H"""
    <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-neutral-400">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:ring, :any, required: true)
  attr(:monitoring?, :boolean, required: true)

  defp evaluation_status(assigns) do
    assigns =
      assigns
      |> assign(:readiness, evaluation_readiness(assigns.ring))
      |> assign(:observed_at, evaluation_observed_at(assigns.ring))

    ~H"""
    <div id="triage-evaluation-status" class="border-t border-neutral-100 pt-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <.section_label>{gettext("AI evaluation")}</.section_label>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <.chip tone={evaluation_readiness_tone(@readiness)}>
              {evaluation_readiness_label(@readiness)}
            </.chip>
            <span :if={@observed_at} class="text-xs text-neutral-400">
              {gettext("Checked %{at}", at: format_datetime(@observed_at))}
            </span>
          </div>
        </div>
        <.button
          id="refresh-evaluation-status"
          type="button"
          variant="secondary"
          size="sm"
          phx-click="refresh-evaluation-status"
        >
          {gettext("Refresh status")}
        </.button>
      </div>

      <p
        :if={@readiness == :ready and @monitoring?}
        class="mt-2 text-sm leading-relaxed text-neutral-600"
      >
        {gettext(
          "New messages from the enabled channels can be evaluated. Review results are suggestions; Comma does not post them to Slack automatically."
        )}
      </p>
      <p
        :if={@readiness == :ready and not @monitoring?}
        class="mt-2 text-sm leading-relaxed text-neutral-600"
      >
        {gettext(
          "AI evaluation is available, but this Slack source is paused. Turn on monitoring when you want enabled channels to send new ambient messages to Triage."
        )}
      </p>
      <p
        :if={@readiness == :unavailable}
        class="mt-2 text-sm leading-relaxed text-amber-800"
      >
        {gettext(
          "AI evaluation is temporarily unavailable. Your monitoring settings are saved, but new messages may complete without an AI review. Check Timeline for the result."
        )}
      </p>
      <p :if={@readiness == :unknown} class="mt-2 text-sm leading-relaxed text-neutral-600">
        {gettext(
          "Comma could not verify the current AI evaluation status. Your monitoring settings are saved; refresh to check again."
        )}
      </p>
    </div>
    """
  end

  attr(:ring, :any, required: true)

  defp ring_body(assigns) do
    assigns =
      assigns
      |> assign(:readiness, evaluation_readiness(assigns.ring))
      |> assign(:processing_status, background_processing_status(assigns.ring))

    ~H"""
    <div class="space-y-3">
      <.notice :if={faulted?(@ring)} tone="amber">
        {gettext(
          "Comma could not verify the current AI evaluation status. Monitoring settings are unchanged; this does not prove the service is down."
        )}
      </.notice>
      <div :if={ok?(@ring)} class="space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <.chip tone={evaluation_readiness_tone(@readiness)}>
            {evaluation_readiness_label(@readiness)}
          </.chip>
          <.chip tone={background_processing_tone(@processing_status)}>
            {background_processing_label(@processing_status)}
          </.chip>
        </div>
        <p
          :if={@readiness == :unavailable}
          class="max-w-[78ch] text-xs leading-relaxed text-amber-800"
        >
          {gettext(
            "AI evaluation is temporarily unavailable. Monitoring remains saved. New work may finish without an AI review; use Timeline to inspect the latest results."
          )}
        </p>
        <p
          :if={@readiness == :unknown}
          class="max-w-[78ch] text-xs leading-relaxed text-neutral-600"
        >
          {gettext(
            "Comma could not verify every evaluator in this snapshot. This is an unknown status, not proof that evaluation is unavailable."
          )}
        </p>
        <p class="text-xs leading-relaxed text-neutral-500">
          {gettext(
            "The counts below are deployment-wide diagnostics. Project-specific recent processing appears on Timeline."
          )}
        </p>
        <dl class="grid grid-cols-1 gap-3 rounded-md border border-neutral-200 px-4 py-3 sm:grid-cols-3 lg:grid-cols-4">
          <div class="min-w-0">
            <dt class="text-[10px] font-semibold uppercase tracking-[0.08em] text-neutral-400">
              {gettext("Evaluating now")}
            </dt>
            <dd class="mt-0.5 text-sm tabular-nums text-neutral-800">
              {blank_dash(ring_runtime_value(@ring, :active_evaluations))}
            </dd>
          </div>
          <div class="min-w-0">
            <dt class="text-[10px] font-semibold uppercase tracking-[0.08em] text-neutral-400">
              {gettext("Waiting to batch")}
            </dt>
            <dd class="mt-0.5 text-sm tabular-nums text-neutral-800">
              {blank_dash(ring_runtime_value(@ring, :open_buckets))}
            </dd>
          </div>
          <div class="min-w-0">
            <dt class="text-[10px] font-semibold uppercase tracking-[0.08em] text-neutral-400">
              {gettext("Waiting to start")}
            </dt>
            <dd class="mt-0.5 text-sm tabular-nums text-neutral-800">
              {blank_dash(ring_runtime_value(@ring, :scheduled_buckets))}
            </dd>
          </div>
          <div class="min-w-0">
            <dt class="text-[10px] font-semibold uppercase tracking-[0.08em] text-neutral-400">
              {gettext("Waiting for recovery")}
            </dt>
            <dd class="mt-0.5 text-sm tabular-nums text-neutral-800">
              {blank_dash(ring_recovery_value(@ring, :pending_receipts))}
            </dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  attr(:connect, :map, required: true)
  attr(:can_manage, :boolean, required: true)

  defp switch_control(assigns) do
    assigns = assign(assigns, :posture_complete?, posture_complete?(assigns.connect))

    ~H"""
    <div class="flex items-center justify-end gap-2">
      <span
        :if={not @posture_complete?}
        class="text-right text-xs text-red-700"
        title={
          gettext(
            "We could not refresh this Slack connection. Some details may be missing; try again before changing its setup."
          )
        }
      >
        {gettext("Connection status unavailable — try again")}
      </span>

      <span :if={not @can_manage} class="text-xs text-neutral-400">
        {gettext("View only")}
      </span>

      <span class="text-xs font-medium text-neutral-600">
        {cond do
          @connect.triage_enabled -> gettext("On")
          not @posture_complete? or @connect[:authority_valid?] == false -> gettext("Unavailable")
          true -> gettext("Off")
        end}
      </span>
      <button
        :if={@can_manage and (@posture_complete? or @connect.triage_enabled)}
        type="button"
        role="switch"
        aria-checked={to_string(@connect.triage_enabled)}
        aria-label={
          if @connect.triage_enabled,
            do: gettext("Turn off Triage monitoring"),
            else: gettext("Turn on Triage monitoring")
        }
        disabled={not switch_action_available?(@connect, switch_action_for(@connect))}
        phx-click="set-triage"
        phx-value-connect={@connect.connect_id}
        phx-value-action={if @connect.triage_enabled, do: "disable", else: "enable"}
        data-confirm={switch_confirm(@connect)}
        class={[
          "relative inline-flex h-6 w-11 shrink-0 rounded-full transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50",
          if(@connect.triage_enabled, do: "bg-brand-500", else: "bg-neutral-300")
        ]}
      >
        <span class={[
          "pointer-events-none absolute top-0.5 h-5 w-5 rounded-full bg-white shadow-sm transition-transform",
          if(@connect.triage_enabled, do: "translate-x-5", else: "translate-x-0.5")
        ]}></span>
      </button>

    </div>
    """
  end

  defp switch_confirm(%{triage_enabled: true} = connect) do
    gettext(
      "Turn off Triage monitoring for %{name}? Ambient messages from every configured channel will stop being received, recorded, and processed. Explicit human @bot commands remain available. Existing timelines and knowledge are kept.",
      name: connect.project_name || connect.connect_id
    )
  end

  defp switch_confirm(connect) do
    gettext(
      "Turn on Triage monitoring for %{name}? Ambient messages from every active configured channel can be received, recorded, and processed. Explicit human @bot commands remain available independently.",
      name: connect.project_name || connect.connect_id
    )
  end

  defp switch_action_for(%{triage_enabled: true}), do: :disable
  defp switch_action_for(_connect), do: :enable

  # ProviderConnects intentionally treats disable as a fail-safe operation: it
  # does not require readiness or current channel authority and rotates the
  # activation fence. Enable is the opposite — it may only be offered from a
  # complete, current posture with at least one configured channel.
  defp switch_action_available?(connect, :disable),
    do: connect[:triage_enabled] == true

  defp switch_action_available?(connect, :enable),
    do:
      posture_complete?(connect) and connect[:triage_enabled] != true and
        connect[:authority_valid?] == true and (connect[:configured_channels] || []) != []

  # A row whose raw record could not be read has no honest provisioning state,
  # and "Not provisioned" fronts a one-way door: submitting it would rotate the
  # generation of a connect that may be live and observing right now. Only an
  # explicit `false` suppresses the controls, so a row from an older Salix that
  # does not carry the field is treated as complete rather than frozen.
  defp posture_complete?(connect), do: connect[:posture_complete?] != false

  attr(:groups, :list, required: true)

  defp unavailable_groups(assigns) do
    ~H"""
    <.notice :if={@groups != []} tone="amber">
      {gettext("Connect posture could not be read for: %{groups}.",
        groups: Enum.map_join(@groups, ", ", & &1.project_name)
      )}
    </.notice>
    """
  end

  attr(:result, :any, required: true)

  # Every section that filters rows by the org join renders this: an incomplete
  # scope means rows were dropped that this page could not prove were foreign,
  # so the list below may be short and the drop counts mean something weaker
  # than they usually do. Naming the failing projects and groups is the point —
  # "may be missing projects" without saying which is not actionable.
  defp scope_notice(assigns) do
    assigns =
      assigns
      |> assign(:scope_complete?, scope_field(assigns.result, :scope_complete, true))
      |> assign(:groups, scope_field(assigns.result, :unavailable_groups, []))

    ~H"""
    <.notice :if={not @scope_complete?} tone="amber">
      {gettext(
        "This view may be missing projects: connect posture could not be read for %{groups}. Rows that could not be checked against it are counted as unattributed, not as belonging to another organization.",
        groups: group_identifiers(@groups)
      )}
    </.notice>
    """
  end

  defp group_identifiers([]), do: gettext("an Agent Swarm this page cannot name")

  defp group_identifiers(groups),
    do:
      Enum.map_join(groups, ", ", fn group ->
        "#{blank_dash(group.project_name)} (#{blank_dash(group.group_id)})"
      end)

  defp scope_field({:ok, value}, key, default), do: Map.get(value, key, default)
  defp scope_field(_result, _key, default), do: default

  # ---- project knowledge timeline ----

  attr(:window, :any, required: true)
  attr(:window_days, :integer, required: true)
  attr(:org, :map, required: true)
  attr(:revealed, :any, required: true)
  attr(:knowledge, :any, required: true)
  attr(:agent, :any, required: true)
  attr(:source_posture, :any, required: true)
  attr(:selected_assertion, :any, required: true)
  attr(:recent_processing, :any, required: true)
  attr(:product_activity, :any, required: true)
  attr(:delegation_tasks, :map, required: true)

  attr(:activity_heatmap, :any, required: true)
  attr(:activity_navigation, :map, required: true)

  attr(:activity_selection, :any, required: true)
  attr(:activity_processing, :any, required: true)
  attr(:model_debug_selection, :any, required: true)
  attr(:can_debug, :boolean, required: true)
  attr(:feedback_selection, :any, required: true)

  defp timeline(assigns) do
    ~H"""
    <div id="triage-timeline" class="space-y-4">
      <.product_activity_panel
        activity={@product_activity}
        heatmap={@activity_heatmap}
        revealed={@revealed}
        navigation={@activity_navigation}
        activity_selection={@activity_selection}
        activity_processing={@activity_processing}
        model_debug_selection={@model_debug_selection}
        can_debug={@can_debug}
        feedback_selection={@feedback_selection}
        agent={@agent}
        org={@org}
        delegation_tasks={@delegation_tasks}
        source_posture={@source_posture}
      />

      <details id="triage-processing-diagnostics" class="rounded-lg border border-neutral-200 bg-white">
        <summary class="cursor-pointer select-none px-4 py-3 text-sm font-medium text-neutral-600 marker:text-neutral-400 hover:text-neutral-900">
          {gettext("Processing diagnostics")}
        </summary>
        <div class="border-t border-neutral-200 p-4">
          <.button type="button" size="sm" variant="secondary" phx-click="load-triage-processing-diagnostics">{gettext("Load processing diagnostics")}</.button>
          <.recent_processing_panel
            :if={@recent_processing != nil}
            processing={@recent_processing}
            agent={@agent}
            source_posture={@source_posture}
          />
        </div>
      </details>

      <div>
        <h3 class="text-sm font-semibold text-neutral-900">{gettext("Project knowledge")}</h3>
        <p class="mt-1 text-xs leading-relaxed text-neutral-500">
          {gettext(
            "Only durable sourced knowledge appears below. A received message or review suggestion is not project knowledge by itself."
          )}
        </p>
      </div>

      <.section_fault :if={faulted?(@knowledge)} result={@knowledge} label={gettext("Project knowledge")} />
      <.notice :if={ok?(@knowledge) and usage_unavailable?(@knowledge)} tone="amber">
        {gettext("Agent-use evidence is temporarily unavailable. Knowledge and sources are still shown; zero uses is not being claimed.")}
      </.notice>
      <.notice :if={ok?(@knowledge) and not unwrap(@knowledge).usage_complete and not usage_unavailable?(@knowledge)} tone="amber">
        {gettext("The bounded session scan did not cover all history. Use counts below are a floor, not a total.")}
      </.notice>
      <.notice :if={faulted?(@window)} tone="neutral">
        {gettext("Slack receipt details are unavailable, so source references remain visible but message text cannot be opened.")}
      </.notice>

      <div :if={ok?(@knowledge)} class="space-y-4">
        <.empty_state
          :if={unwrap(@knowledge).assertions == []}
          icon="inbox"
          title={gettext("No project knowledge yet")}
          description={gettext("Sourced facts and decisions recorded for this project will appear here.")}
        />

        <div
          :for={{day, assertions} <- group_knowledge_by_day(unwrap(@knowledge).assertions)}
          class="space-y-2"
        >
          <h3 class="px-0.5 pt-2 text-[11px] font-semibold uppercase tracking-[0.08em] text-neutral-400">
            {day}
          </h3>
          <div class="ml-[5px] space-y-2 border-l-2 border-neutral-200 pl-5">
            <.knowledge_timeline_card :for={assertion <- assertions} assertion={assertion} />
          </div>
        </div>

        <.knowledge_panel
          :if={@selected_assertion}
          assertion={@selected_assertion}
          receipt={receipt_for_assertion(@window, @selected_assertion)}
          revealed={@revealed}
          usage_status={unwrap(@knowledge).usage_status}
        />
      </div>
    </div>
    """
  end

  attr(:activity, :any, required: true)
  attr(:agent, :any, required: true)
  attr(:org, :map, required: true)
  attr(:delegation_tasks, :map, required: true)
  attr(:source_posture, :any, required: true)

  attr(:navigation, :map, required: true)
  attr(:heatmap, :any, default: nil)

  attr(:activity_selection, :any, required: true)
  attr(:activity_processing, :any, required: true)
  attr(:model_debug_selection, :any, required: true)
  attr(:can_debug, :boolean, required: true)
  attr(:feedback_selection, :any, required: true)

  attr(:revealed, :any, required: true)

  defp product_activity_panel(assigns) do
    {outcomes, context} = product_activity_sections(assigns.activity)

    channel_names = product_channel_names(assigns.agent, assigns.source_posture)

    assigns =
      assigns
      |> assign(:context, context)
      |> assign(:activity_counts, product_activity_counts(outcomes))
      |> assign(
        :timeline,
        product_timeline(assigns.activity, outcomes, assigns.navigation, channel_names)
      )

    assigns =
      assigns
      |> assign(:threads, product_thread_groups(assigns.timeline))
      |> assign(:channel_options, product_channel_options(assigns.agent, assigns.source_posture))
      |> assign(
        :filtered?,
        assigns.navigation.kind != "all" or not is_nil(assigns.navigation[:channel]) or
          not is_nil(assigns.navigation[:before])
      )
      |> assign(:heatmap_view, heatmap_view(assigns.heatmap, channel_names))

    ~H"""
    <section
      id="triage-product-activity"
      phx-hook="BrowserLocalTime"
      class="overflow-hidden rounded-lg border border-neutral-200 bg-white text-xs leading-5"
    >
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-200 px-3 py-2.5">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-neutral-900">{gettext("Triage activity")}</h3>
          <p :if={@agent} class="mt-0.5 text-xs leading-5 text-neutral-500">
            {gettext("Viewed with %{name}'s access", name: agent_label(@agent))}
          </p>
        </div>
        <.button
          id="refresh-triage-processing"
          type="button"
          variant="secondary"
          size="sm"
          phx-click="refresh-triage-processing"
        >
          {gettext("Refresh status")}
        </.button>
      </div>

      <div class="space-y-3 p-3" :if={faulted?(@activity) or is_nil(@agent)}>
        <.notice :if={faulted?(@activity)} tone="amber">
          {gettext(
            "Triage activity is temporarily unavailable. Listening settings are unchanged; refresh to check again."
          )}
        </.notice>

        <.empty_state
          :if={is_nil(@agent)}
          icon="inbox"
          title={gettext("Select an Agent")}
          description={gettext("Choose an Agent to inspect its replies, reactions, silence decisions, and collected context.")}
        />
      </div>


      <div :if={match?({:ok, %{intake: {:error, _}}}, @activity)} class="px-3 py-2">
        <.notice tone="amber">{gettext("Processing status is unavailable. Refresh to retry.")}</.notice>
      </div>

      <section id="triage-product-outcomes">
        <form id="triage-activity-filter" phx-change="filter-triage-activity" class="flex flex-wrap items-center justify-between gap-2 border-b border-neutral-200 px-3 py-2">
          <fieldset class="flex flex-wrap items-center gap-1">
            <legend class="sr-only">{gettext("Show")}</legend>
            <label
              :for={{value, label} <- [{"all", gettext("All activity")}, {"reply", gettext("Replies")}, {"reaction", gettext("Reactions")}, {"silence", gettext("Silence")}, {"investigation", gettext("Investigations")}]}
              class="cursor-pointer"
            >
              <input type="radio" name="kind" value={value} checked={@navigation.kind == value} class="peer sr-only" />
              <span class="inline-flex h-7 items-center rounded-md px-2.5 text-xs font-medium text-neutral-500 transition-colors hover:bg-neutral-50 hover:text-neutral-800 peer-checked:bg-neutral-100 peer-checked:text-neutral-900 peer-focus-visible:ring-2 peer-focus-visible:ring-brand-500">
                {label}
              </span>
            </label>
          </fieldset>
          <div :if={@channel_options != []}>
            <label for="triage-activity-channel" class="sr-only">{gettext("Channel")}</label>
            <select
              id="triage-activity-channel"
              name="channel"
              class="h-7 rounded-md border border-neutral-200 bg-white py-0 pl-2 pr-7 text-xs text-neutral-700 focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
            >
              <option value="" selected={is_nil(@navigation[:channel])}>{gettext("All channels")}</option>
              <option :for={{id, label} <- @channel_options} value={id} selected={@navigation[:channel] == id}>{label}</option>
            </select>
          </div>
        </form>
        <div
          :if={@activity_counts.total > 0}
          id="triage-activity-summary"
          class="flex flex-wrap items-center gap-x-2 gap-y-1 border-b border-neutral-200 bg-neutral-50/70 px-3 py-2 text-xs leading-5 text-neutral-500"
        >
          <span class="font-medium text-neutral-700">
            {ngettext(
              "1 visible outcome",
              "%{count} visible outcomes",
              @activity_counts.total
            )}
          </span>
          <span aria-hidden="true" class="text-neutral-300">·</span>
          <span data-role="decision-counts" class="text-neutral-400">{gettext("Decision")}:</span>
          <span data-outcome-kind="reply">{gettext("Reply")} {@activity_counts.reply}</span>
          <span aria-hidden="true" class="text-neutral-300">·</span>
          <span data-outcome-kind="reaction">{gettext("Reaction")} {@activity_counts.reaction}</span>
          <span aria-hidden="true" class="text-neutral-300">·</span>
          <span data-outcome-kind="silence">{gettext("Stayed silent")} {@activity_counts.silence}</span>
          <span :if={@activity_counts.in_progress > 0} aria-hidden="true" class="text-neutral-300">·</span>
          <span :if={@activity_counts.in_progress > 0} data-outcome-state="in-progress" class="text-blue-700">
            {gettext("Effect in progress")} {@activity_counts.in_progress}
          </span>
          <span :if={@activity_counts.failed > 0} aria-hidden="true" class="text-neutral-300">·</span>
          <span :if={@activity_counts.failed > 0} data-outcome-state="failed" class="font-medium text-amber-700">
            {gettext("Triage action failed")} {@activity_counts.failed}
          </span>
        </div>

        <.activity_heatmap :if={@heatmap_view} view={@heatmap_view} navigation={@navigation} />

        <div
          :if={@navigation[:before]}
          id="triage-activity-time-filter"
          class="flex flex-wrap items-center gap-2 border-b border-neutral-200 px-3 py-2 text-xs leading-5 text-neutral-600"
        >
          <span>{gettext("Showing activity before")}</span>
          <.browser_local_time
            ms={@navigation.before}
            format="month-day-time"
            fallback={format_timeline_datetime(@navigation.before)}
            class="font-medium tabular-nums text-neutral-900"
          />
          <button
            type="button"
            phx-click="clear-triage-activity-time"
            class="rounded-md px-1.5 font-medium text-brand-600 hover:bg-brand-50"
          >
            {gettext("Show latest")}
          </button>
        </div>

        <div :if={ok?(@activity) and @timeline == []} class="px-3 py-4">
          <.empty_state
            :if={not @filtered?}
            icon="inbox"
            title={gettext("No Triage activity yet")}
            description={gettext("A reply, reaction, deliberate silence, or blocked attempt will appear here after Slack activity is evaluated.")}
          />
          <.empty_state
            :if={@filtered?}
            icon="magnifying-glass"
            title={gettext("No activity matches this filter")}
            description={gettext("Try another channel or activity type.")}
          />
        </div>

        <ol :if={@timeline != []} id="triage-activity-feed" class="py-2">
          <li
            :for={thread <- @threads}
            data-role="thread"
            class="relative grid grid-cols-[3.5rem_minmax(0,1fr)] gap-x-10 py-3 pl-3 pr-4 before:absolute before:bottom-0 before:left-[5.5rem] before:top-0 before:w-px before:bg-neutral-200 first:before:top-5 last:before:bottom-auto last:before:h-5"
          >
            <div class="row-span-2 pt-0.5 text-right leading-tight">
              <.browser_local_time
                ms={thread.at}
                format="time"
                fallback={format_time(thread.at)}
                class="block text-sm font-medium tabular-nums text-neutral-900"
              />
              <.browser_local_time
                ms={thread.at}
                format="month-day"
                fallback={format_month_day(thread.at)}
                class="mt-0.5 block text-[11px] tabular-nums text-neutral-400"
              />
              <span
                aria-hidden="true"
                data-role="thread-node"
                class={[
                  "absolute left-[calc(5.5rem-4.5px)] top-[1.05rem] h-2.5 w-2.5 rounded-full ring-4 ring-white",
                  timeline_node_class(thread.tone)
                ]}
              />
            </div>
            <header class="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs leading-5 text-neutral-500">
              <span class="text-sm font-semibold text-neutral-900">{thread.channel_label}</span>
              <span aria-hidden="true" class="text-neutral-300">·</span>
              <span>{gettext("Thread")}</span>
              <.browser_local_time ms={thread.started_at || thread.at} format="month-day-time" fallback={format_timeline_datetime(thread.started_at || thread.at)} class="tabular-nums" />
              <span :if={length(thread.rows) > 1} class="rounded-full bg-neutral-100 px-1.5 text-[11px] font-medium text-neutral-600">{ngettext("1 activity", "%{count} activities", length(thread.rows))}</span>
              <a :if={thread.url} href={thread.url} target="_blank" rel="noopener noreferrer" class="ml-auto shrink-0 rounded px-1.5 py-0.5 text-neutral-500 transition-colors hover:bg-neutral-100 hover:text-neutral-900">{gettext("Open in Slack")}<span aria-hidden="true"> ↗</span></a>
            </header>
            <ol class="space-y-4">
          <li :for={%{kind: kind, item: item, id: id} <- thread.rows} id={id} data-kind={kind} class="min-w-0">
            <%= if kind == :outcome do %>
                  <div
                    :if={product_source_messages(item) != []}
                    data-section="source-messages"
                    class="min-w-0"
                  >
                    <ol class="space-y-3">
                      <li
                        :for={message <- product_source_messages(item)}
                        class="grid min-w-0 grid-cols-[1.75rem_minmax(0,1fr)] gap-x-2.5"
                      >
                        <span aria-hidden="true" class="mt-0.5 flex h-7 w-7 items-center justify-center rounded-full bg-neutral-100 text-xs font-medium text-neutral-600">
                          {product_actor_initial(product_source_actor_label(message))}
                        </span>
                        <div class="min-w-0">
                          <div class="flex items-baseline gap-2 text-xs leading-5 text-neutral-400">
                            <p class="text-[13px] font-medium text-neutral-900">{product_source_actor_label(message)}</p>
                            <.browser_local_time
                              :if={message[:occurred_at_ms]}
                              ms={message.occurred_at_ms}
                              format="time-seconds"
                              fallback={format_time_with_seconds(message.occurred_at_ms)}
                              class="tabular-nums"
                            />
                          </div>
                          <p class="mt-0.5 whitespace-pre-wrap break-words text-sm leading-6 text-neutral-800"><.slack_text text={product_source_excerpt(message, @revealed)} mentions={message[:mentions] || %{}} /></p>
                          <.source_file_catalogue catalogue={message[:file_attachments]} />
                        </div>
                      </li>
                    </ol>
                  </div>
              <button type="button" phx-click="open-triage-activity" phx-value-type="outcome" phx-value-subject={item.event_ref} aria-label={gettext("View batch details")} class={["group mt-3 grid w-full cursor-pointer grid-cols-[minmax(0,1fr)_auto] items-start gap-x-3 rounded-lg border bg-white px-3 py-2.5 text-left transition-colors hover:bg-neutral-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500", product_outcome_border(item)]}>
                <span class="grid min-w-0 gap-1">
                  <span class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-xs leading-5">
                    <span class="font-medium text-neutral-500">{gettext("Agent decision")}</span>
                    <span data-role="outcome-label">
                      <.chip tone={product_outcome_tone(item)}>{product_outcome_label(item)}</.chip>
                    </span>
                    <.browser_local_time
                      ms={item.updated_at_ms || item.inserted_at_ms}
                      format="time"
                      fallback={format_time(item.updated_at_ms || item.inserted_at_ms)}
                      class="shrink-0 tabular-nums text-neutral-400"
                    />
                  </span>
                  <span
                    data-role="decision-summary"
                    class={["whitespace-pre-wrap break-words leading-6", product_outcome_body_class(item)]}
                  >{product_outcome_body(item)}</span>
                  <span class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 text-xs leading-5 text-neutral-400">
                    <span data-role="evidence-summary">{product_evidence_label(item, :total_sources)}</span>
                    <span :if={product_outcome_effect_summary(item)} aria-hidden="true" class="text-neutral-300">·</span>
                    <span
                      :if={product_outcome_effect_summary(item)}
                      data-role="effect-summary"
                      class="min-w-0 text-neutral-500"
                    >
                      {product_outcome_effect_summary(item)}
                    </span>
                  </span>
                </span>
                <span aria-hidden="true" data-role="outcome-chevron" class="mt-0.5 flex items-center gap-1 text-xs leading-5 text-neutral-400 group-hover:text-neutral-700">
                  <span class="hidden sm:inline">{gettext("Details")}</span>
                  <.icon name="chevron-down" class="h-3.5 w-3.5 -rotate-90" />
                </span>
              </button>

              <.side_panel :if={@activity_selection == %{type: "outcome", id: item.event_ref}} id="triage-activity-panel" show size="xl" on_cancel={JS.push("close-triage-activity")}>
                <:title>{gettext("Batch details")} · {thread.channel_label}</:title>
                <:navigation>
                  <.activity_detail_tabs can_debug={@can_debug} kind="outcome" subject={item[:obligation_id]} debug_selected={@model_debug_selection != nil} />
                </:navigation>
                <.model_debug_panel :if={@model_debug_selection != nil} selection={@model_debug_selection} />
              <div
                id={"#{item.event_ref}-details"}
                :if={@model_debug_selection == nil}
                class="divide-y divide-neutral-200 text-xs leading-5"
              >
                <section data-section="decision" class="pb-4">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-xs leading-5 font-medium text-neutral-500">
                      {gettext("Decision")}
                    </p>
                    <.chip tone={product_outcome_tone(item)}>{product_outcome_label(item)}</.chip>
                    <button type="button" class="ml-auto rounded px-1.5 py-1 text-xs leading-5 text-neutral-500 hover:bg-neutral-100 hover:text-neutral-800 focus-visible:outline focus-visible:outline-2 focus-visible:outline-blue-500" phx-click="open-triage-feedback" phx-value-type="outcome" phx-value-subject={item[:obligation_id]} :if={is_binary(item[:obligation_id])}>{gettext("Feedback")}</button>
                  </div>
                  <p class="mt-2 whitespace-pre-wrap break-words text-xs leading-5 text-neutral-800">{product_outcome_body(item)}</p>
                  <.internal_feedback :if={@feedback_selection && @feedback_selection.type == "outcome" && @feedback_selection.id == item[:obligation_id]} selection={@feedback_selection} />
                </section>

                <section data-section="source" class="py-4">
                  <p class="text-xs leading-5 font-medium text-neutral-800">
                    {gettext("Source and trigger")}
                  </p>
                  <dl class="mt-1.5 space-y-1">
                    <div class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Channel")}</dt>
                      <dd class="min-w-0 font-medium text-neutral-800">{item.channel_label}</dd>
                    </div>
                    <div :if={product_thread_started_at_ms(item)} class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Thread")}</dt>
                      <dd class="min-w-0 text-neutral-700">
                        {gettext("Thread started")}
                        <.browser_local_time
                          ms={product_thread_started_at_ms(item)}
                          format="date-time"
                          fallback={format_datetime(product_thread_started_at_ms(item))}
                        />
                      </dd>
                    </div>
                    <div class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Trigger")}</dt>
                      <dd class="min-w-0 text-neutral-700">
                        {gettext("Slack event or scheduled recheck")}
                      </dd>
                    </div>
                    <div class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Observed")}</dt>
                      <dd class="min-w-0 text-neutral-700">{product_source_message_label(item)}</dd>
                    </div>
                    <div :if={product_source_latest_activity_ms(item)} class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Latest activity")}</dt>
                      <dd class="min-w-0 text-neutral-700">
                        <.browser_local_time
                          ms={product_source_latest_activity_ms(item)}
                          format="date-time"
                          fallback={format_datetime(product_source_latest_activity_ms(item))}
                        />
                      </dd>
                    </div>
                  </dl>

                </section>

                <section data-section="evidence" class="py-4">
                  <p class="text-xs leading-5 font-medium text-neutral-800">
                    {gettext("Evidence used")}
                  </p>
                  <dl class="mt-1.5 space-y-1">
                    <div class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Cited sources")}</dt>
                      <dd class="min-w-0 font-medium text-neutral-800">
                        {product_evidence_total_label(item)}
                      </dd>
                    </div>
                    <div :if={product_evidence_count(item, :communication_sources) > 0} class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Communication")}</dt>
                      <dd class="min-w-0 text-neutral-700">
                        {product_evidence_label(item, :communication_sources)}
                      </dd>
                    </div>
                    <div :if={product_evidence_count(item, :companion_reaction_sources) > 0} class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Companion reaction")}</dt>
                      <dd class="min-w-0 text-neutral-700">
                        {product_evidence_label(item, :companion_reaction_sources)}
                      </dd>
                    </div>
                    <div :if={product_evidence_count(item, :context_sources) > 0} class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Project context")}</dt>
                      <dd class="min-w-0 text-neutral-700">
                        {product_evidence_label(item, :context_sources)}
                      </dd>
                    </div>
                    <div :if={product_evidence_count(item, :delegation_sources) > 0} class="flex min-w-0 gap-3">
                      <dt class="w-28 shrink-0 text-neutral-500">{gettext("Delegation evidence")}</dt>
                      <dd class="min-w-0 text-neutral-700">
                        {product_evidence_label(item, :delegation_sources)}
                      </dd>
                    </div>
                  </dl>
                </section>

                <section data-section="context" class="py-4">
                  <p class="text-xs leading-5 font-medium text-neutral-800">
                    {gettext("Related context")}
                  </p>
                  <p :if={item[:related_context] in [nil, []]} class="mt-2 text-neutral-500">
                    {gettext("No project context was retained from this evaluation.")}
                  </p>
                  <ul :if={is_list(item[:related_context]) and item.related_context != []} class="mt-3 divide-y divide-neutral-200">
                    <li :for={context <- item.related_context} class="py-3 first:pt-0 last:pb-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <.chip tone={product_context_tone(context)}>{product_context_kind_label(context)}</.chip>
                        <span class="text-xs leading-5 text-neutral-400">{product_context_state_label(context)}</span>
                        <span class="font-medium text-neutral-800">{context.subject}</span>
                      </div>
                      <p class="mt-1 text-xs leading-5 text-neutral-700">{context.value}</p>
                      <p class="mt-1 text-xs leading-5 text-neutral-400">
                        {product_context_evidence_label(context)}
                      </p>
                    </li>
                  </ul>
                </section>

                <section :if={product_has_effect_details?(item)} data-section="effects" class="py-4">
                  <p class="text-xs leading-5 font-medium text-neutral-800">
                    {gettext("Effects")}
                  </p>
                  <ul class="mt-1.5 space-y-1 text-neutral-700">
                    <li :if={product_companion_effect_label(item)}>
                      {product_companion_effect_label(item)}
                    </li>
                    <li :if={product_context_effect_label(item)}>{product_context_effect_label(item)}</li>
                    <li :if={product_delegation_count(item, "created") > 0}>
                      {ngettext("1 worker task created", "%{count} worker tasks created", product_delegation_count(item, "created"))}
                    </li>
                    <li :if={local_rehearsal_outcome?(item)} class="font-medium text-green-700">
                      {gettext("Local rehearsal · Slack writes 0")}
                    </li>
                  </ul>
                  <ul :if={item.delegations != []} class="mt-2 space-y-1 text-neutral-500">
                    <.product_delegation
                      :for={delegation <- item.delegations}
                      item={item}
                      delegation={delegation}
                      results={@delegation_tasks}
                      agent={@agent}
                      org={@org}
                    />
                  </ul>
                </section>

                <section data-section="lifecycle" class="pt-4">
                  <p class="text-xs leading-5 font-medium text-neutral-800">
                    {gettext("Lifecycle")}
                  </p>
                  <ol class="relative ml-1 mt-2 border-l border-neutral-300 text-neutral-600">
                    <li class="relative flex justify-between gap-3 pb-2 pl-5">
                      <span aria-hidden="true" class="absolute -left-[4px] top-1 h-2 w-2 rounded-full bg-neutral-500 ring-4 ring-neutral-50" />
                      <span>{gettext("Decision recorded")}</span>
                      <.browser_local_time
                        ms={item.inserted_at_ms}
                        format="time-seconds"
                        fallback={format_time_with_seconds(item.inserted_at_ms)}
                        class="tabular-nums text-neutral-700"
                      />
                    </li>
                    <li :if={product_outcome_terminal?(item)} class="relative flex justify-between gap-3 pl-5">
                      <span aria-hidden="true" class="absolute -left-[4px] top-1 h-2 w-2 rounded-full bg-green-600 ring-4 ring-neutral-50" />
                      <span>{gettext("Effect settled")}</span>
                      <.browser_local_time
                        ms={item.updated_at_ms}
                        format="time-seconds"
                        fallback={format_time_with_seconds(item.updated_at_ms)}
                        class="tabular-nums text-neutral-700"
                      />
                    </li>
                    <li :if={!product_outcome_terminal?(item)} class="relative flex justify-between gap-3 pl-5">
                      <span aria-hidden="true" class="absolute -left-[4px] top-1 h-2 w-2 rounded-full bg-blue-500 ring-4 ring-neutral-50" />
                      <span>{gettext("Effect in progress")}</span>
                      <.browser_local_time
                        ms={item.updated_at_ms}
                        format="time-seconds"
                        fallback={format_time_with_seconds(item.updated_at_ms)}
                        class="tabular-nums text-neutral-700"
                      />
                    </li>
                  </ol>
                  <p class="mt-2 text-neutral-500">
                    <span :if={product_outcome_duration_label(item)} class="font-medium text-neutral-800">
                      {product_outcome_duration_label(item)}
                    </span>
                    <span :if={product_outcome_duration_label(item)} aria-hidden="true"> · </span>
                    {ngettext("1 attempt", "%{count} attempts", item[:attempts] || 0)}
                  </p>
                </section>
              </div>
              </.side_panel>
            <% else %>
                <div class="grid min-w-0 grid-cols-[1.75rem_minmax(0,1fr)] gap-x-2.5">
                <span aria-hidden="true" class="mt-0.5 flex h-7 w-7 items-center justify-center rounded-full bg-neutral-100 text-xs font-medium text-neutral-600">
                  {product_actor_initial(product_source_actor_label(%{speaker_label: item[:source_actor_label], actor_kind: :human}))}
                </span>
                <div class="min-w-0">
                <div class="flex flex-wrap items-baseline gap-2 text-xs leading-5 text-neutral-400">
                  <span class="text-[13px] font-medium text-neutral-900">{product_source_actor_label(%{speaker_label: item[:source_actor_label], actor_kind: :human})}</span>
                  <span>{item.channel_label}</span>
                  <.browser_local_time ms={item.received_at_ms} format="month-day-time" fallback={format_time(item.received_at_ms)} class="tabular-nums" />
                </div>
                <p :if={MapSet.member?(@revealed, item.receipt_ref)} class="mt-0.5 whitespace-pre-wrap break-words text-sm leading-6 text-neutral-800"><.slack_text text={item[:source_text]} mentions={item[:mentions] || %{}} /></p>
                <p :if={!MapSet.member?(@revealed, item.receipt_ref)} class="mt-0.5 text-xs leading-5 text-amber-700">{gettext("Source access could not be recorded. Refresh to retry.")}</p>
                </div>
              </div>
              <div class="mt-3 rounded-lg border border-dashed border-neutral-200 px-3 py-2.5">
                <.chip tone={processing_tone(item)}>{processing_label(item)}</.chip>
                <p class="mt-1.5 text-xs leading-5 text-neutral-500">{processing_description(item)}</p>
                <button type="button" class="mt-1.5 text-xs leading-5 text-neutral-600 hover:text-neutral-900" phx-click="open-triage-activity" phx-value-type="receipt" phx-value-subject={item.receipt_ref}>{gettext("View batch details")} →</button>
                <.side_panel :if={@activity_selection == %{type: "receipt", id: item.receipt_ref}} id="triage-activity-panel" show size="xl" on_cancel={JS.push("close-triage-activity")}>
                  <:title>{gettext("Batch details")} · {item.channel_label}</:title>
                  <:navigation>
                    <.activity_detail_tabs can_debug={@can_debug} kind="receipt" subject={item.receipt_ref} debug_selected={@model_debug_selection != nil} />
                  </:navigation>
                  <.model_debug_panel :if={@model_debug_selection != nil} selection={@model_debug_selection} />
                  <div :if={@model_debug_selection == nil} class="space-y-5 text-sm leading-6">
                    <section :if={MapSet.member?(@revealed, item.receipt_ref)} class="border-b border-neutral-200 pb-4">
                      <p class="mb-2 text-xs text-neutral-500">{gettext("Source message")}</p>
                      <p class="whitespace-pre-wrap break-words text-neutral-800"><.slack_text text={item[:source_text]} mentions={item[:mentions] || %{}} /></p>
                    </section>
                    <% detail = processing_detail_item(item, @activity_processing) %>
                    <div>
                      <.chip tone={processing_tone(detail)}>{processing_label(detail)}</.chip>
                      <p class="mt-2 text-neutral-600">{processing_description(detail)}</p>
                    </div>
                    <.notice :if={processing_detail_unavailable?(@activity_processing)} tone="amber">
                      {gettext("Batch evidence is unavailable. The recorded processing status is still shown.")}
                    </.notice>
                    <.processing_event_details item={detail} expanded />
                  </div>
                </.side_panel>
              </div>
            <% end %>
          </li>
            </ol>
          </li>
        </ol>

        <nav
          :if={ok?(@activity)}
          id="triage-activity-pager"
          aria-label={gettext("Triage activity")}
          class="flex items-center justify-between gap-3 border-t border-neutral-200 px-3 py-2"
        >
          <span class="text-xs leading-5 tabular-nums text-neutral-500">
            {gettext("Page %{page}", page: length(@navigation.cursors))}
          </span>
          <div class="flex items-center gap-2">
            <.button type="button" size="sm" variant="secondary" phx-click="previous-triage-activity" disabled={length(@navigation.cursors) == 1}>{gettext("Previous")}</.button>
            <.button type="button" size="sm" variant="secondary" phx-click="next-triage-activity" disabled={!match?({:ok, %{next_cursor: cursor}} when is_binary(cursor), @activity)}>{gettext("Next")}</.button>
          </div>
        </nav>
      </section>

      <section id="triage-product-follow-ups" class="border-t border-neutral-200 px-3 py-3">
        <h3 class="text-sm font-semibold">{gettext("Follow-up work")}</h3>
        <p class="mt-1 text-xs leading-5 text-neutral-500">{gettext("Latest 20 retained follow-ups, ordered by last change. A proposed follow-up is not a scheduled reminder.")}</p>
        <%= case @activity do %>
          <% {:ok, %{follow_ups: {:ok, entries}}} -> %>
            <p :if={entries == []} class="mt-2 text-xs leading-5 text-neutral-500">{gettext("No follow-ups in this view.")}</p>
            <ol class="mt-2 divide-y divide-neutral-100">
              <li :for={entry <- entries} id={"follow-up-#{entry.context_ref}"} class="py-3">
                <.chip tone={product_context_tone(entry)}>{product_context_state_label(entry)}</.chip>
                <span class="ml-2 text-sm font-medium">{entry.subject}</span>
                <p class="mt-1 text-sm text-neutral-600">{entry.value}</p>
                <p :if={entry[:follow_up_basis]} class="mt-1 text-xs leading-5 text-neutral-500">{entry.follow_up_basis}</p>
                <p :if={entry[:next_check_at_ms]} class="mt-1 text-xs leading-5 text-neutral-500">{gettext("Recheck after %{time}", time: format_datetime(entry.next_check_at_ms))}</p>
                <.button type="button" size="sm" variant="secondary" phx-click="open-triage-feedback" phx-value-type="follow_up" phx-value-subject={entry.entry_id}>{gettext("Rate or comment")}</.button>
                <.internal_feedback :if={@feedback_selection && @feedback_selection.type == "follow_up" && @feedback_selection.id == entry.entry_id} selection={@feedback_selection} />
              </li>
            </ol>
          <% _ -> %>
            <p class="mt-2 text-xs leading-5 text-amber-700">{gettext("Follow-up status is unavailable.")}</p>
        <% end %>
      </section>

      <details id="triage-product-context" class="group border-t border-neutral-200">
        <summary class="cursor-pointer select-none px-3 py-2.5 marker:text-neutral-400 hover:bg-neutral-50">
          <div class="ml-1 inline-flex max-w-[calc(100%-1.5rem)] flex-wrap items-baseline gap-x-3 gap-y-1 align-middle">
            <span class="text-sm font-semibold text-neutral-900">{gettext("Context collected")}</span>
            <span class="text-xs leading-5 text-neutral-500">
              {ngettext("1 context item", "%{count} context items", length(@context))}
            </span>
            <span class="text-xs leading-5 text-neutral-400">
              {gettext("Facts, decisions, and follow-ups retained with their sources.")}
            </span>
          </div>
        </summary>

        <div :if={ok?(@activity) and @context == []} class="border-t border-neutral-200 px-3 py-3 text-xs leading-5 text-neutral-500">
          {gettext("No Triage context has been collected in this view.")}
        </div>

        <ul :if={@context != []} class="divide-y divide-neutral-100 border-t border-neutral-200">
          <li :for={entry <- @context} id={entry.context_ref} class="px-3 py-2.5">
            <div class="flex flex-wrap items-center gap-2">
              <.chip tone={product_context_tone(entry)}>{product_context_kind_label(entry)}</.chip>
              <span class="text-xs leading-5 text-neutral-400">{product_context_state_label(entry)}</span>
              <span class="text-sm font-medium text-neutral-800">{entry.subject}</span>
            </div>
            <p class="mt-1 text-xs leading-5 text-neutral-600">{entry.value}</p>
            <p :if={entry[:next_check_at_ms]} class="mt-1 text-xs leading-5 text-neutral-500">
              {gettext("Recheck after %{time}", time: format_datetime(entry.next_check_at_ms))}
            </p>
          </li>
        </ul>
      </details>
    </section>
    """
  end

  attr(:selection, :map, required: true)

  defp internal_feedback(assigns) do
    ~H"""
      <section id="triage-internal-feedback" class="mt-2 rounded border border-neutral-200 bg-neutral-50 px-3 py-3">
        <div class="flex items-center justify-between">
          <h3 class="text-sm font-semibold">{gettext("Internal feedback")}</h3>
          <.button type="button" variant="secondary" size="sm" phx-click="close-triage-feedback">{gettext("Close")}</.button>
        </div>
        <p class="mt-1 text-xs leading-5 text-neutral-500">{gettext("Scores and comments stay in this dashboard. They do not instruct the Agent or authorize follow-up work.")}</p>
        <form id="triage-feedback-form" phx-submit="save-triage-feedback" class="mt-3 space-y-2">
          <label for="triage-feedback-score" class="block text-xs leading-5">{gettext("Score (1 poor, 5 excellent)")}</label>
          <select id="triage-feedback-score" name="score" class="rounded border-neutral-200 text-sm">
            <option value="">{gettext("No score")}</option>
            <option :for={score <- 1..5} value={score}>{score}</option>
          </select>
          <label for="triage-feedback-comment" class="block text-xs leading-5">{gettext("Comment")}</label>
          <textarea id="triage-feedback-comment" name="comment" maxlength="4000" rows="3" class="w-full rounded border-neutral-200 text-sm"></textarea>
          <.button type="submit" size="sm" phx-disable-with={gettext("Saving…")}>{gettext("Save feedback")}</.button>
        </form>
        <ol class="mt-3 divide-y divide-neutral-200">
          <li :for={review <- @selection.reviews.items} class="py-2 text-xs leading-5">
            <span class="font-medium">{if review.score, do: gettext("Score %{score}/5", score: review.score), else: gettext("Comment only")}</span>
            <span class="ml-2 text-neutral-400">{DateTime.to_iso8601(review.inserted_at)}</span>
            <p class="mt-1 whitespace-pre-wrap text-sm">{review.comment}</p>
          </li>
        </ol>
        <p :if={@selection.reviews.truncated} class="text-xs leading-5 text-neutral-500">{gettext("Showing the latest 20 reviews.")}</p>
      </section>
    """
  end

  attr(:processing, :any, required: true)
  attr(:agent, :any, required: true)
  attr(:source_posture, :any, required: true)

  defp recent_processing_panel(assigns) do
    items =
      recent_processing_items(assigns.processing, assigns.agent, assigns.source_posture)

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:scope_incomplete?, recent_processing_scope_incomplete?(assigns.processing))
      |> assign(:truncated?, recent_processing_truncated?(assigns.processing))
      |> assign(:records_incomplete?, recent_processing_records_incomplete?(assigns.processing))

    ~H"""
    <.card>
      <:title>{gettext("Recent processing")}</:title>
      <div id="triage-recent-processing" class="space-y-3">
        <div>
          <p class="max-w-[72ch] text-xs leading-5 text-neutral-500">
            {gettext(
              "Latest durable processing states for this Agent. Refresh when you want a new snapshot; this page does not continuously poll."
            )}
          </p>
        </div>

        <.notice :if={faulted?(@processing)} tone="amber">
          {gettext(
            "Recent processing status is temporarily unavailable. Monitoring settings are unchanged; refresh to check again."
          )}
        </.notice>
        <.notice :if={@scope_incomplete?} tone="amber">
          {gettext(
            "Some project connection status could not be checked, so recent processing may be incomplete."
          )}
        </.notice>
        <.notice :if={@truncated?} tone="amber">
          {gettext(
            "The bounded recent scan did not cover every receipt. The items below are a recent sample, not a total."
          )}
        </.notice>
        <.notice :if={@records_incomplete?} tone="amber">
          {gettext(
            "Some recent receipt status could not be verified, so processing history may be incomplete."
          )}
        </.notice>

        <.empty_state
          :if={
            ok?(@processing) and @items == [] and not @scope_incomplete? and not @truncated? and
              not @records_incomplete?
          }
          icon="inbox"
          title={gettext("No recent Triage processing")}
          description={gettext("When an enabled Slack channel sends ambient messages, their verified processing state will appear here.")}
        />

        <.empty_state
          :if={
            ok?(@processing) and @items == [] and
              (@scope_incomplete? or @truncated? or @records_incomplete?)
          }
          icon="inbox"
          title={gettext("No matching processing was found in this bounded sample")}
          description={gettext("Comma could not inspect every recent receipt, so this is not evidence that this Agent had no recent processing.")}
        />

        <ol :if={@items != []} class="divide-y divide-neutral-100 rounded-lg border border-neutral-200">
          <li
            :for={item <- @items}
            id={processing_dom_id(item)}
            class="flex flex-wrap items-start gap-x-3 gap-y-1 px-3 py-3"
          >
            <span class="w-14 shrink-0 text-xs leading-5 tabular-nums text-neutral-400">
              {format_time(item[:observed_at_ms] || item[:received_at_ms])}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <.chip tone={processing_tone(item)}>{processing_label(item)}</.chip>
                <span class="truncate text-xs leading-5 text-neutral-400">
                  {processing_owner_label(item)}
                </span>
                <span class="text-xs leading-5 text-neutral-400">
                  {processing_receipt_count_label(item)}
                </span>
              </div>
              <p class="mt-1 text-xs leading-5 text-neutral-600">
                {processing_description(item)}
              </p>
              <.processing_event_details item={item} />
            </div>
          </li>
        </ol>
      </div>
    </.card>
    """
  end

  attr(:can_debug, :boolean, required: true)
  attr(:kind, :string, required: true)
  attr(:subject, :string, required: true)
  attr(:debug_selected, :boolean, required: true)

  defp activity_detail_tabs(assigns) do
    ~H"""
    <div role="tablist" aria-label={gettext("Batch details")} class="-mb-px flex gap-5 text-xs leading-5">
      <button type="button" role="tab" aria-selected={to_string(!@debug_selected)} phx-click="close-triage-model-debug" class={["border-b-2 py-3", !@debug_selected && "border-neutral-800 font-medium text-neutral-900", @debug_selected && "border-transparent text-neutral-500"]}>{gettext("Triage detail")}</button>
      <button :if={@can_debug} type="button" role="tab" aria-selected={to_string(@debug_selected)} phx-click="open-triage-model-debug" phx-value-type={@kind} phx-value-subject={@subject} phx-disable-with={gettext("Loading…")} class={["border-b-2 py-3", @debug_selected && "border-neutral-800 font-medium text-neutral-900", !@debug_selected && "border-transparent text-neutral-500"]}>{gettext("Model debug")}</button>
    </div>
    """
  end

  attr(:selection, :map, required: true)

  defp model_debug_panel(assigns) do
    ~H"""
    <section data-section="model-debug" class="space-y-5 text-xs leading-5">
      <%= case @selection.result do %>
        <% {:ok, record} -> %>
          <div>
            <p class="break-words font-medium text-neutral-800">{record[:model] || gettext("Model not recorded")} · {record[:provider] || gettext("Provider not recorded")} · {record[:status]}</p>
            <p class="mt-1 break-all font-mono text-[11px] text-neutral-500">{record[:run_id]}</p>
          </div>
          <p :if={record.requests == []} class="mt-2 text-neutral-500">{gettext("No model request payload was retained for this attempt.")}</p>
          <section :for={{request, index} <- Enum.with_index(record.requests, 1)}>
            <h3 class="font-medium text-neutral-800">{gettext("Request %{index}", index: index)}</h3>
            <p class="mt-1 text-neutral-500">{gettext("JSON content expanded for reading.")}</p>
            <.model_debug_payload value={request} raw_label={gettext("Request JSON")} />
          </section>
          <section :if={model_debug_tools(record.requests) != []}>
            <h3 class="font-medium text-neutral-800">{gettext("Tool calls and results in retained requests")}</h3>
            <.model_debug_payload value={model_debug_tools(record.requests)} />
          </section>
          <section :if={record.tool_receipts != []}>
            <h3 class="font-medium text-neutral-800">{gettext("Tool receipts")}</h3>
            <.model_debug_payload value={record.tool_receipts} />
          </section>
          <section :if={record[:participation_decision] != nil}>
            <h3 class="font-medium text-neutral-800">{gettext("Contribution selection")}</h3>
            <.model_debug_payload value={record.participation_decision} />
          </section>
          <section>
            <h3 class="font-medium text-neutral-800">{gettext("Stored decision")}</h3>
            <p class="mt-1 text-neutral-500">{gettext("The raw model response was not retained. The decision below is the stored result, not the original response.")}</p>
            <.model_debug_payload value={record.decision} />
          </section>
        <% {:error, :not_found} -> %>
          <p class="mt-2 text-neutral-500">{gettext("No debug record was found for this batch.")}</p>
        <% {:error, :too_large} -> %>
          <p class="mt-2 text-amber-700">{gettext("This debug record exceeds the 2 MiB read limit.")}</p>
        <% {:error, :forbidden} -> %>
          <p class="mt-2 text-amber-700">{gettext("Debug records could not be loaded. Administrator access to this Agent is required.")}</p>
        <% _ -> %>
          <p class="mt-2 text-amber-700">{gettext("Debug records could not be loaded. Try again.")}</p>
      <% end %>
    </section>
    """
  end

  attr(:value, :any, required: true)
  attr(:raw_label, :string, default: nil)

  defp model_debug_payload(assigns) do
    value = omit_debug_reasoning(assigns.value)

    assigns =
      assign(assigns,
        readable: value |> expand_debug_json() |> model_debug_json(),
        raw: model_debug_json(value)
      )

    ~H"""
    <div class="mt-2 min-w-0">
      <pre data-debug-view="readable" class="whitespace-pre-wrap break-words rounded-md bg-neutral-50 p-3 text-[11px] leading-5 text-neutral-700 [overflow-wrap:anywhere]">{@readable}</pre>
      <details :if={@readable != @raw} data-debug-view="raw" class="mt-2">
        <summary class="cursor-pointer py-1 text-neutral-500 hover:text-neutral-800">{@raw_label || gettext("Source JSON")}</summary>
        <pre class="mt-2 whitespace-pre-wrap break-words rounded-md bg-neutral-50 p-3 text-[11px] leading-5 text-neutral-700 [overflow-wrap:anywhere]">{@raw}</pre>
      </details>
    </div>
    """
  end

  defp model_debug_tools(requests) do
    requests
    |> Enum.flat_map(fn request ->
      messages = request["messages"] || request["input"] || []
      if is_list(messages), do: messages, else: []
    end)
    |> Enum.flat_map(fn
      %{"role" => "tool"} = item ->
        [item]

      %{"tool_calls" => calls} = item when is_list(calls) ->
        [item]

      %{"type" => type} = item when type in ["function_call", "function_call_output"] ->
        [item]

      %{"content" => content} when is_list(content) ->
        Enum.filter(content, &(is_map(&1) and &1["type"] in ["tool_use", "tool_result"]))

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp model_debug_json(value) do
    json = Jason.encode!(value, pretty: true)

    if byte_size(json) > 131_072,
      do: String.slice(json, 0, 32_768) <> "\n[Display shortened]",
      else: json
  end

  defp expand_debug_json(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, expand_debug_json(nested)} end)

  defp expand_debug_json(value) when is_list(value), do: Enum.map(value, &expand_debug_json/1)

  defp expand_debug_json(value) when is_binary(value) do
    case decode_debug_json(value) do
      {:ok, decoded} -> expand_debug_json(decoded)
      :error -> value
    end
  end

  defp expand_debug_json(value), do: value

  defp decode_debug_json(value) do
    case String.trim_leading(value) do
      <<first, _::binary>> = json when first in [?{, ?[] ->
        case Jason.decode(json) do
          {:ok, decoded} when is_map(decoded) or is_list(decoded) -> {:ok, decoded}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp omit_debug_reasoning(value) when is_map(value),
    do:
      value
      |> Map.drop(["thinking", "reasoning", "reasoning_content", "signature"])
      |> Map.new(fn {k, v} -> {k, omit_debug_reasoning(v)} end)

  defp omit_debug_reasoning(value) when is_list(value),
    do:
      value
      |> Enum.reject(
        &(is_map(&1) and &1["type"] in ["thinking", "redacted_thinking", "reasoning"])
      )
      |> Enum.map(&omit_debug_reasoning/1)

  defp omit_debug_reasoning(value) when is_binary(value) do
    case decode_debug_json(value) do
      {:ok, decoded} ->
        filtered =
          decoded |> BridgeForTeamsWeb.ResponseSanitizer.sanitize() |> omit_debug_reasoning()

        if filtered == decoded, do: value, else: Jason.encode!(filtered)

      :error ->
        value
    end
  end

  defp omit_debug_reasoning(value), do: value

  attr(:item, :map, required: true)
  attr(:expanded, :boolean, default: false)

  defp processing_event_details(assigns) do
    assigns =
      assigns
      |> assign(:diagnostics, assigns.item[:diagnostics] || %{})
      |> assign(:milestones, get_in(assigns.item, [:diagnostics, :milestones]) || %{})

    ~H"""
    <.dynamic_tag tag_name={if @expanded, do: "section", else: "details"} class={if @expanded, do: "group", else: "group mt-2 rounded-md border border-neutral-200 bg-neutral-50/60 px-3 py-2"}>
      <.dynamic_tag tag_name={if @expanded, do: "h3", else: "summary"} class="cursor-pointer select-none text-xs font-medium text-neutral-600 marker:text-neutral-400 hover:text-neutral-900">
        {gettext("Triage event details")}
      </.dynamic_tag>
      <div class="mt-3 space-y-3 border-t border-neutral-200 pt-3 text-xs">
        <.processing_detail label={gettext("Source")}>
          <div class="space-y-1">
            <p class="font-medium text-neutral-800">{@item[:channel_label] || gettext("Slack channel unavailable")}</p>
            <p :if={processing_thread_label(get_in(@diagnostics, [:source, :thread_ts]))} class="font-mono text-neutral-500">
              {processing_thread_label(get_in(@diagnostics, [:source, :thread_ts]))}
            </p>
            <p class="text-neutral-500">
              {processing_addressing_label(get_in(@diagnostics, [:source, :addressing_kind]))}
              <span aria-hidden="true"> · </span>
              {processing_source_mode_label(get_in(@diagnostics, [:source, :source_mode]))}
            </p>
            <p :if={processing_trigger_label(get_in(@diagnostics, [:source, :trigger_kind]))} class="text-neutral-500">
              {processing_trigger_label(get_in(@diagnostics, [:source, :trigger_kind]))}
            </p>
          </div>
        </.processing_detail>

        <.processing_detail label={gettext("Milestones")}>
          <ol class="space-y-1 text-neutral-500">
            <li :for={{label, at_ms} <- processing_milestones(@milestones)} class="flex justify-between gap-3">
              <span>{label}</span>
              <.browser_local_time ms={at_ms} format="time-seconds" fallback={format_time_with_seconds(at_ms)} class="font-mono tabular-nums text-neutral-700" />
            </li>
          </ol>
          <p :if={processing_duration(@milestones)} class="mt-1 font-medium text-neutral-800">
            {gettext("Total %{duration}", duration: processing_duration(@milestones))}
          </p>
        </.processing_detail>

        <.processing_detail :if={@diagnostics[:evaluator]} label={gettext("Evaluator")}>
          <div class="space-y-1 text-neutral-500">
            <p class="font-medium text-neutral-800">
              {@diagnostics.evaluator.model}
              <span class="font-normal text-neutral-500"> · {@diagnostics.evaluator.provider}</span>
            </p>
            <p>
              {gettext("Prompt %{prompt} · policy %{policy}",
                prompt: @diagnostics.evaluator.prompt_ref || gettext("unavailable"),
                policy: @diagnostics.evaluator.policy_ref || gettext("unavailable")
              )}
            </p>
            <p>{processing_evaluator_request_label(@diagnostics.evaluator)}</p>
            <p>{processing_evaluator_retry_label(@diagnostics.evaluator)}</p>
          </div>
        </.processing_detail>

        <.processing_detail :if={@item[:terminal_status] == "failed" and !@diagnostics[:evaluator]} label={gettext("Evaluator")}>
          <p class="text-neutral-500">{gettext("No model request details were retained for this attempt.")}</p>
        </.processing_detail>

        <.processing_detail :if={@diagnostics[:trace_ref]} label={gettext("Trace")}>
          <code class="font-mono text-neutral-700">{@diagnostics.trace_ref}</code>
        </.processing_detail>

        <.processing_detail label={gettext("Processing evidence")}>
          <span class={processing_blocker_class(@item)}>{processing_blocker_label(@item)}</span>
          <p :if={processing_decision_reason(@diagnostics)} class="mt-1 text-neutral-500">
            {processing_decision_reason(@diagnostics)}
          </p>
        </.processing_detail>
      </div>
    </.dynamic_tag>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp processing_detail(assigns) do
    ~H"""
    <div class="grid gap-1 sm:grid-cols-[8rem_minmax(0,1fr)] sm:gap-4">
      <p class="text-xs text-neutral-500">
        {@label}
      </p>
      <div class="min-w-0 break-words">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr(:assertion, :map, required: true)

  defp knowledge_timeline_card(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open-knowledge"
      phx-value-id={@assertion.id}
      class="relative block w-full rounded-lg border border-neutral-200 bg-white px-4 py-3 text-left shadow-subtle transition hover:border-brand-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
    >
      <span
        class="absolute -left-[26px] top-4 h-2.5 w-2.5 rounded-full border-2 border-green-500 bg-white"
        aria-hidden="true"
      />
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-mono text-xs tabular-nums text-neutral-400">
          {format_time(@assertion.observed_at)}
        </span>
        <.chip tone="green">{knowledge_kind_label(@assertion.kind)}</.chip>
        <.tag :if={@assertion.uses != []}>
          {ngettext("used once", "used %{count} times", length(@assertion.uses))}
        </.tag>
        <span class="ml-auto text-xs text-neutral-400">
          {subject_names(@assertion.subjects)}
        </span>
      </div>
      <p class="mt-2 text-sm font-medium leading-relaxed text-neutral-900">{@assertion.content}</p>
      <p class="mt-1 truncate font-mono text-[11px] text-neutral-400">{@assertion.source.ref}</p>
    </button>
    """
  end

  attr(:assertion, :map, required: true)
  attr(:receipt, :any, required: true)
  attr(:revealed, :any, required: true)
  attr(:usage_status, :any, required: true)

  defp knowledge_panel(assigns) do
    ~H"""
    <.side_panel id="triage-knowledge-panel" show size="lg" on_cancel={JS.push("close-knowledge")}>
      <:title>{gettext("Triage details")}</:title>
      <div id="triage-knowledge-detail" class="space-y-5">
        <div>
          <div class="flex flex-wrap items-center gap-2">
            <.chip tone="green">{knowledge_kind_label(@assertion.kind)}</.chip>
            <span class="text-xs text-neutral-400">{format_datetime(@assertion.observed_at)}</span>
          </div>
          <p class="mt-2 text-base font-semibold leading-relaxed text-neutral-900">
            {@assertion.content}
          </p>
        </div>

        <div class="space-y-3 border-l-2 border-neutral-200 pl-5">
          <.knowledge_trace_step number="1" title={gettext("Information entered")}>
            <p class="text-sm leading-relaxed text-neutral-600">
              {source_description(@assertion.source)}
            </p>
            <.revealable_text
              :if={@receipt}
              ref={@receipt["receipt_ref"]}
              connect_id={@receipt["connect_id"]}
              text={get_in(@receipt, ["triage_event", "text"])}
              revealed={@revealed}
            />
            <.ref_row label={gettext("Source ref")} value={@assertion.source.ref} />
          </.knowledge_trace_step>

          <.knowledge_trace_step number="2" title={gettext("Recorded by Triage")}>
            <p class="text-sm leading-relaxed text-neutral-600">
              {gettext("The sourced assertion was recorded in this project's append-only knowledge record. This view does not invent an extraction model run that was not recorded.")}
            </p>
          </.knowledge_trace_step>

          <.knowledge_trace_step number="3" title={gettext("Project knowledge formed")}>
            <p class="text-sm font-medium leading-relaxed text-neutral-900">{@assertion.content}</p>
            <div class="mt-2 flex flex-wrap gap-2">
              <.tag :for={subject <- @assertion.subjects}>
                {entity_kind_label(subject.kind)} · {subject.name}
              </.tag>
            </div>
          </.knowledge_trace_step>

          <.knowledge_trace_step number="4" title={gettext("Agent use")}>
            <div
              :if={usage_status_unavailable?(@usage_status)}
              class="text-sm leading-relaxed text-amber-700"
            >
              {gettext(
                "Agent-use evidence is unavailable. The page will not describe these assertions as unused."
              )}
            </div>
            <div
              :if={not usage_status_unavailable?(@usage_status) and @assertion.uses == []}
              class="text-sm leading-relaxed text-neutral-500"
            >
              {gettext("No accepted Agent use appears in the scanned session history.")}
            </div>
            <div :for={use <- @assertion.uses} class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2">
              <p class="text-xs font-medium text-neutral-800">
                {gettext("Used in session %{session}", session: use["session_id"])}
              </p>
              <p :if={use["assistant_excerpt"]} class="mt-1 text-sm leading-relaxed text-neutral-600">
                {use["assistant_excerpt"]}
              </p>
              <p class="mt-1 text-[11px] text-neutral-400">{format_unix_seconds(use["used_at"])}</p>
            </div>
          </.knowledge_trace_step>
        </div>
      </div>
    </.side_panel>
    """
  end

  attr(:number, :string, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp knowledge_trace_step(assigns) do
    ~H"""
    <section class="relative rounded-lg border border-neutral-200 bg-white px-4 py-3">
      <span class="absolute -left-[31px] top-3 flex h-5 w-5 items-center justify-center rounded-full bg-brand-500 text-[10px] font-semibold text-white">
        {@number}
      </span>
      <h3 class="text-sm font-semibold text-neutral-900">{@title}</h3>
      <div class="mt-2 space-y-2">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  # ---- project knowledge ----

  attr(:knowledge, :any, required: true)
  attr(:sourced_context, :any, required: true)
  attr(:agent, :any, required: true)
  attr(:filters, :map, required: true)
  attr(:org, :map, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:onboarding_preview?, :boolean, required: true)
  attr(:grounding?, :boolean, required: true)
  attr(:inspection?, :boolean, required: true)
  attr(:active_context, :any, required: true)

  defp knowledge(assigns) do
    project_rows =
      if ok?(assigns.knowledge),
        do: knowledge_rows(unwrap(assigns.knowledge), assigns.filters),
        else: []

    imported_rows = imported_knowledge_rows(assigns.sourced_context, assigns.filters)
    triage_rows = retained_context_rows(assigns.knowledge, assigns.filters)

    assigns =
      assigns
      |> assign(:project_rows, project_rows)
      |> assign(:imported_rows, imported_rows)
      |> assign(:triage_rows, triage_rows)
      |> assign(
        :any_knowledge?,
        ok?(assigns.knowledge) or ok?(assigns.sourced_context)
      )

    ~H"""
    <div id="triage-knowledge" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <p class="text-xs font-medium text-neutral-500">
            {if @agent, do: @agent.project_name, else: gettext("Project")}
          </p>
          <h2 class="mt-1 text-base font-semibold text-neutral-900">
            {gettext("People, projects, decisions, and context")}
          </h2>
          <p class="mt-1 text-sm text-neutral-500">
            {knowledge_ownership_copy()}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.chip tone="green">{gettext("Every item keeps its source")}</.chip>
          <.button
            :if={@onboarding_preview? && @agent && @can_manage}
            patch={~p"/orgs/#{@org.slug}/triage/context?agent=#{@agent.agent_id}"}
            variant="secondary"
          >
            {gettext("Initialize or update from Slack")}
          </.button>
        </div>
      </div>

      <.section_fault :if={faulted?(@knowledge)} result={@knowledge} label={gettext("Project knowledge")} />
      <.section_fault
        :if={faulted?(@sourced_context)}
        result={@sourced_context}
        label={gettext("Imported Slack knowledge")}
      />
      <.notice :if={active_context?(@active_context) and not @inspection?} tone="amber">
        {gettext("Imported Slack knowledge is saved, but this environment cannot show it yet. Existing context remains unchanged.")}
      </.notice>

      <div :if={@any_knowledge?} class="space-y-4">
        <.notice :if={ok?(@knowledge) and usage_unavailable?(@knowledge)} tone="amber">
          {gettext("Agent-use evidence is unavailable. The page will not describe these assertions as unused.")}
        </.notice>
        <.notice :if={ok?(@knowledge) and retained_context_unavailable?(@knowledge)} tone="amber">
          {gettext("Triage knowledge is temporarily unavailable. Existing project knowledge remains visible.")}
        </.notice>
        <.notice :if={knowledge_projection_incomplete?(@knowledge)} tone="amber">
          {gettext("The bounded knowledge projection is incomplete. The visible rows are a prefix, not a total.")}
        </.notice>

        <form
          id="triage-knowledge-filter"
          phx-submit="filter-knowledge"
          class="flex flex-wrap items-end gap-3 rounded-lg border border-neutral-200 bg-white p-3"
        >
          <label class="min-w-56 flex-1 text-xs font-medium text-neutral-600">
            {gettext("Search project knowledge")}
            <input
              type="search"
              name="q"
              value={@filters["q"]}
              placeholder={gettext("Search people, projects, decisions, or context")}
              class="mt-1 h-10 w-full rounded-md border border-neutral-300 px-3 text-sm"
            />
          </label>
          <label class="text-xs font-medium text-neutral-600">
            {gettext("Type")}
            <select name="kind" class="mt-1 h-10 rounded-md border border-neutral-300 bg-white px-3 text-sm">
              <option :for={{value, label} <- knowledge_filter_options()} value={value} selected={knowledge_kind(@filters["kind"]) == value}>
                {label}
              </option>
            </select>
          </label>
          <.button type="submit" variant="secondary">{gettext("Apply")}</.button>
        </form>

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <.stat_card id="triage-knowledge-count-person" label={gettext("People")} value={knowledge_total_count(@knowledge, @sourced_context, :person)} detail={gettext("People found in project knowledge")} />
          <.stat_card id="triage-knowledge-count-project" label={gettext("Projects")} value={knowledge_total_count(@knowledge, @sourced_context, :project)} detail={gettext("Projects found in shared knowledge")} />
          <.stat_card id="triage-knowledge-count-decision" label={gettext("Decisions")} value={knowledge_total_count(@knowledge, @sourced_context, :decision)} detail={gettext("Sourced project decisions")} />
          <.stat_card id="triage-knowledge-count-context" label={gettext("Context")} value={knowledge_total_count(@knowledge, @sourced_context, :context)} detail={gettext("Other reviewed team context")} />
        </div>

        <.empty_state
          :if={@project_rows == [] and @imported_rows == [] and @triage_rows == []}
          icon="inbox"
          title={gettext("No matching project knowledge")}
          description={gettext("Try another search or type filter.")}
        />

        <section :if={@triage_rows != []} id="triage-recorded-context-knowledge" class="space-y-2">
          <div>
            <h3 class="text-sm font-semibold text-neutral-900">{gettext("Recorded by Triage")}</h3>
            <p class="mt-0.5 text-xs leading-5 text-neutral-500">
              {gettext("Facts, decisions, and follow-ups retained with their sources.")}
            </p>
          </div>
          <div class="divide-y divide-neutral-100 rounded-lg border border-neutral-200 bg-white">
            <article
              :for={row <- @triage_rows}
              id={"triage-context-knowledge-row-#{row.id}"}
              class="flex items-start gap-3 px-4 py-3"
            >
              <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-brand-50 text-xs font-semibold text-brand-700">
                {entity_kind_glyph(row.kind)}
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <strong class="text-sm font-semibold text-neutral-900">{row.name}</strong>
                  <.chip tone="neutral">{entity_kind_label(row.kind)}</.chip>
                </div>
                <p class="mt-1 text-sm leading-relaxed text-neutral-600">{row.content}</p>
                <p class="mt-1 text-xs text-neutral-400">
                  {product_context_evidence_label(row)}
                  <span :if={row.updated_at_ms} aria-hidden="true"> · </span>
                  <span :if={row.updated_at_ms}>
                    {gettext("Last updated")}:
                    <.browser_local_time
                      ms={row.updated_at_ms}
                      format="date-time"
                      fallback={format_datetime(row.updated_at_ms)}
                    />
                  </span>
                </p>
              </div>
            </article>
          </div>
        </section>

        <section :if={@imported_rows != []} id="triage-sourced-context-knowledge" class="space-y-2">
          <div>
            <h3 class="text-sm font-semibold text-neutral-900">{gettext("Imported from Slack")}</h3>
            <p class="mt-0.5 text-xs leading-5 text-neutral-500">
              {gettext("Reviewed Slack history stays here even if Slack is later disconnected. Open an item to inspect its source references.")}
            </p>
            <p :if={not @grounding?} class="mt-1 text-xs leading-5 text-amber-700">
              {gettext("Agent use of imported Slack knowledge is not enabled in this environment.")}
            </p>
          </div>
          <div class="divide-y divide-neutral-100 rounded-lg border border-neutral-200 bg-white">
            <details :for={row <- @imported_rows} id={"slack-knowledge-row-#{row.id}"} class="group px-4 py-3">
              <summary class="flex cursor-pointer list-none items-start gap-3">
                <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-brand-50 text-xs font-semibold text-brand-700">
                  {entity_kind_glyph(row.kind)}
                </span>
                <span class="min-w-0 flex-1">
                  <strong class="block text-sm font-semibold text-neutral-900">{row.name}</strong>
                  <span class="mt-0.5 block text-xs text-neutral-500">{row.summary}</span>
                </span>
                <.chip tone="neutral">{entity_kind_label(row.kind)}</.chip>
              </summary>
              <div class="grid gap-4 pb-1 pl-12 pt-4 lg:grid-cols-2">
                <section :if={row.aliases != []}>
                  <.section_label>{gettext("Names found")}</.section_label>
                  <p class="mt-2 text-sm leading-6 text-neutral-700">{Enum.join(row.aliases, " · ")}</p>
                </section>
                <section>
                  <.section_label>{gettext("Slack source references")}</.section_label>
                  <ul class="mt-2 space-y-1 font-mono text-[11px] text-neutral-500">
                    <li :for={source <- row.source_refs} class="break-all">{source.ref}</li>
                  </ul>
                </section>
              </div>
            </details>
          </div>
        </section>

        <div :if={@project_rows != []} class="divide-y divide-neutral-100 rounded-lg border border-neutral-200 bg-white">
          <details :for={row <- @project_rows} id={"knowledge-row-#{row.id}"} class="group px-4 py-3">
            <summary class="flex cursor-pointer list-none items-start gap-3">
              <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-neutral-100 text-xs font-semibold text-neutral-600">
                {entity_kind_glyph(row.kind)}
              </span>
              <span class="min-w-0 flex-1">
                <strong class="block text-sm font-semibold text-neutral-900">{row.name}</strong>
                <span class="mt-0.5 block text-xs text-neutral-500">{row.summary}</span>
              </span>
              <.chip tone="neutral">{entity_kind_label(row.kind)}</.chip>
            </summary>
            <div class="grid gap-4 pb-1 pl-12 pt-4 lg:grid-cols-2">
              <section :if={row.member}>
                <.section_label>{gettext("Project member")}</.section_label>
                <div class="mt-2 space-y-2">
                  <.chip tone="neutral">{row.member.role}</.chip>
                  <p class="break-all font-mono text-[11px] text-neutral-400">
                    {row.member.source.ref}
                  </p>
                </div>
              </section>
              <section :if={row.assertions != []}>
                <.section_label>{gettext("Known assertions")}</.section_label>
                <div class="mt-2 space-y-2">
                  <div :for={assertion <- row.assertions} class="rounded-md border border-neutral-200 px-3 py-2">
                    <p class="text-sm font-medium leading-relaxed text-neutral-800">{assertion.content}</p>
                    <p class="mt-1 break-all font-mono text-[11px] text-neutral-400">{assertion.source.ref}</p>
                  </div>
                </div>
              </section>
              <section :if={row.assertions != []}>
                <.section_label>{gettext("Agent use")}</.section_label>
                <div class="mt-2 space-y-2">
                  <div :if={row.uses == [] and not usage_unavailable?(@knowledge)} class="text-sm text-neutral-500">
                    {gettext("No accepted use appears in the scanned history.")}
                  </div>
                  <div :for={use <- row.uses} class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2">
                    <p class="text-xs font-medium text-neutral-800">{use["session_id"]}</p>
                    <p :if={use["assistant_excerpt"]} class="mt-1 text-sm text-neutral-600">{use["assistant_excerpt"]}</p>
                  </div>
                </div>
              </section>
            </div>
          </details>
        </div>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  # Every id, ref, and scope reads the same way: a micro label, then mono text
  # small enough to sit under it and broken wherever it must be to stay in the
  # column.
  defp ref_row(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-[10px] font-semibold uppercase tracking-[0.08em] text-neutral-400">
        {@label}
      </dt>
      <dd class="mt-0.5 break-all font-mono text-xs leading-relaxed text-neutral-700">
        {blank_dash(@value)}
      </dd>
    </div>
    """
  end

  attr(:ref, :string, required: true)
  attr(:connect_id, :any, default: nil)
  attr(:text, :any, required: true)
  attr(:revealed, :any, required: true)

  defp revealable_text(assigns) do
    assigns = assign(assigns, :shown?, MapSet.member?(assigns.revealed, assigns.ref))

    ~H"""
    <div class="mt-2">
      <p :if={@shown?} class="whitespace-pre-wrap text-sm text-neutral-800">{@text}</p>
      <button
        :if={not @shown?}
        type="button"
        phx-click="reveal-text"
        phx-value-ref={@ref}
        phx-value-connect={@connect_id}
        class="inline-flex items-center gap-1.5 rounded-md border border-dashed border-neutral-300 px-2 py-1 text-xs text-neutral-500 hover:border-brand-300 hover:text-brand-700"
      >
        <.icon name="chat-bubble" class="h-3.5 w-3.5" />
        {gettext("Reveal message text (recorded in the audit log)")}
      </button>
    </div>
    """
  end

  # ---- memory ----

  attr(:org, :map, required: true)
  attr(:router_agents, :any, required: true)
  attr(:memory_agent, :any, required: true)
  attr(:memory_agent_missing?, :boolean, required: true)
  attr(:memory_entries, :any, required: true)
  attr(:memory_file, :any, required: true)

  defp memory(assigns) do
    ~H"""
    <div id="triage-memory" class="space-y-4">
      <.notice tone="neutral">
        {gettext(
          "Memory belongs to an agent, not to the organization. Only the group's router agent carries semantic memory — workers get their context from task inputs — so this browser shows the router's /memory tree, read-only."
        )}
      </.notice>

      <.section_fault
        :if={faulted?(@router_agents)}
        result={@router_agents}
        label={gettext("Router agents")}
      />

      <.empty_state
        :if={ok?(@router_agents) and unwrap(@router_agents) == []}
        icon="users"
        title={gettext("No router agents")}
        description={
          gettext(
            "No Agent Swarm in this organization has a provisioned router agent, so there is no memory to browse."
          )
        }
      />

      <.notice :if={@memory_agent_missing? and @memory_agent} tone="amber">
        {gettext(
          "The requested agent is not one of this organization's router agents. Showing %{name} instead — this is not that agent's memory.",
          name: memory_agent_label(@memory_agent)
        )}
      </.notice>

      <div
        :if={ok?(@router_agents) and unwrap(@router_agents) != []}
        class="inline-flex flex-wrap gap-1 rounded-md bg-neutral-100 p-1"
      >
        <.link
          :for={agent <- unwrap(@router_agents)}
          patch={tab_path(@org, :memory, %{"agent" => agent.agent_id})}
          class={[
            "rounded px-3 py-1 text-xs focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500",
            @memory_agent && @memory_agent.agent_id == agent.agent_id &&
              "bg-white font-medium text-neutral-900 shadow-subtle",
            !(@memory_agent && @memory_agent.agent_id == agent.agent_id) &&
              "text-neutral-500 hover:text-neutral-900"
          ]}
        >
          {memory_agent_label(agent)}
        </.link>
      </div>

      <div
        :if={@memory_agent}
        class="grid grid-cols-1 overflow-hidden rounded-lg border border-neutral-200 bg-white lg:grid-cols-[16rem_1fr]"
      >
        <div class="border-b border-neutral-200 bg-neutral-100 py-3 lg:border-b-0 lg:border-r">
          <div class="px-4 pb-1">
            <.section_label>{gettext("Files")}</.section_label>
          </div>
          <.memory_entries
            entries={@memory_entries}
            org={@org}
            agent={@memory_agent}
            selected={@memory_file && elem(@memory_file, 0)}
          />
        </div>

        <div class="min-w-0 px-5 py-4">
          <.section_label>{gettext("Contents")}</.section_label>
          <.memory_body file={@memory_file} />
        </div>
      </div>
    </div>
    """
  end

  defp memory_agent_label(%{project_name: project} = agent) do
    label = agent_label(agent)
    if label == project, do: project, else: "#{project} · #{label}"
  end

  attr(:entries, :any, required: true)
  attr(:org, :map, required: true)
  attr(:agent, :map, required: true)
  attr(:selected, :any, default: nil)

  defp memory_entries(assigns) do
    assigns = assign(assigns, :root, @memory_root)

    ~H"""
    <div>
      <div class="px-4">
        <.section_fault :if={faulted?(@entries)} result={@entries} label={gettext("Memory")} />
      </div>
      <div :if={ok?(@entries)}>
        <div class="flex items-baseline justify-between gap-2 px-4 pb-2">
          <span class="truncate font-mono text-[11px] text-neutral-400">
            {unwrap(@entries).path}
          </span>
          <.link
            :if={unwrap(@entries).path != @root}
            patch={tab_path(@org, :memory, %{"agent" => @agent.agent_id})}
            class="shrink-0 text-[11px] text-brand-700 hover:underline focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
          >
            {gettext("Back to /memory")}
          </.link>
        </div>

        <.empty_state
          :if={unwrap(@entries).entries == []}
          icon="folder"
          title={gettext("Nothing here")}
          description={gettext("This router agent has written no memory under this path yet.")}
        />

        <ul>
          <li :for={entry <- unwrap(@entries).entries}>
            <.link
              patch={memory_entry_path(@org, @agent, entry)}
              aria-current={@selected == entry["path"] && "page"}
              class={[
                "flex items-center gap-2 px-4 py-1.5 text-xs focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand-500",
                @selected == entry["path"] && "bg-brand-50 font-medium text-brand-700",
                @selected != entry["path"] &&
                  "text-neutral-600 hover:bg-neutral-200/60 hover:text-neutral-900"
              ]}
            >
              <.icon
                name={if entry["kind"] == "dir", do: "folder", else: "document-text"}
                class={
                  "h-3.5 w-3.5 shrink-0 " <>
                    if(@selected == entry["path"], do: "text-brand-500", else: "text-neutral-400")
                }
              />
              <span class="truncate font-mono">{entry["path"]}</span>
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr(:file, :any, required: true)

  defp memory_body(assigns) do
    ~H"""
    <div class="mt-2">
      <.empty_state
        :if={is_nil(@file)}
        icon="document-text"
        title={gettext("No file selected")}
        description={gettext("Pick a file from the list to read it.")}
      />

      <div :if={@file} class="space-y-3">
        <div class="break-all font-mono text-xs text-neutral-500">{elem(@file, 0)}</div>
        <.section_fault
          :if={faulted?(elem(@file, 1))}
          result={elem(@file, 1)}
          label={gettext("Memory file")}
        />
        <div :if={ok?(elem(@file, 1))} class="space-y-2">
          <.notice :if={unwrap(elem(@file, 1)).truncated?} tone="amber">
            {gettext("This file is longer than the render limit and has been cut short.")}
          </.notice>
          <pre class="max-h-[32rem] overflow-auto whitespace-pre-wrap rounded-md border border-neutral-200 bg-neutral-50 p-3 font-mono text-xs leading-relaxed text-neutral-700">{unwrap(elem(@file, 1)).body}</pre>
        </div>
      </div>
    </div>
    """
  end

  # ---- data ----

  attr(:org, :map, required: true)
  attr(:filters, :map, required: true)
  attr(:window, :any, required: true)
  attr(:window_days, :integer, required: true)
  attr(:ring, :any, required: true)
  attr(:receipts, :any, required: true)
  attr(:buckets, :any, required: true)
  attr(:bucket_detail, :any, required: true)
  attr(:revealed, :any, required: true)

  defp data(assigns) do
    ~H"""
    <div id="triage-data" class="space-y-4">
      <details class="rounded-lg border border-neutral-200 bg-white px-4 py-3 shadow-subtle">
        <summary class="cursor-pointer text-sm font-medium text-neutral-800">
          {gettext("Processing diagnostics")}
        </summary>
        <div class="mt-4 space-y-4 border-t border-neutral-100 pt-4">
          <.window_stats window={@window} window_days={@window_days} />
          <.ring_body ring={@ring} />
        </div>
      </details>

      <.card>
        <:title>{gettext("Receipt scan")}</:title>
        <.receipt_scan receipts={@receipts} org={@org} filters={@filters} revealed={@revealed} />
      </.card>

      <.card>
        <:title>{gettext("Buckets")}</:title>
        <.bucket_list
          buckets={@buckets}
          detail={@bucket_detail}
          org={@org}
          filters={@filters}
          revealed={@revealed}
        />
      </.card>
    </div>
    """
  end

  attr(:receipts, :any, required: true)
  attr(:org, :map, required: true)
  attr(:filters, :map, required: true)
  attr(:revealed, :any, required: true)

  defp receipt_scan(assigns) do
    ~H"""
    <div>
      <.section_fault
        :if={faulted?(@receipts)}
        result={@receipts}
        label={gettext("Receipt scan")}
        reset_patch={scan_reset_path(@org, @filters)}
      />
      <div :if={ok?(@receipts)} class="space-y-3">
        <div id="triage-scan-counts" class="flex flex-wrap items-center gap-2 text-xs">
          <.count_chip label={gettext("scanned")} value={unwrap(@receipts).scanned_count} />
          <.count_chip label={gettext("legacy")} value={unwrap(@receipts).legacy_count} />
          <.count_chip label={gettext("invalid")} value={unwrap(@receipts).invalid_count} />
          <.count_chip label={gettext("unavailable")} value={unwrap(@receipts).unavailable_count} />
          <.count_chip label={gettext("outside this org")} value={unwrap(@receipts).foreign_count} />
          <.count_chip
            :if={not unwrap(@receipts).scope_complete}
            label={gettext("unattributed")}
            value={unwrap(@receipts).unattributed_count}
          />
        </div>
        <p class="text-xs text-neutral-500">
          {gettext(
            "These counts describe the unfiltered page: they are scan health, not this organization's content. The keyspace is key-ordered, so a page is a position in a scan and not a moment in time."
          )}
        </p>
        <p :if={not unwrap(@receipts).scope_complete} class="text-xs text-neutral-500">
          {gettext(
            "\"unattributed\" is rows this page dropped without being able to check them, because a project's posture could not be read. They are not confirmed to belong to another organization."
          )}
        </p>
        <.scope_notice result={@receipts} />

        <.empty_state
          :if={unwrap(@receipts).receipts == []}
          icon="inbox"
          title={gettext("No receipts on this page")}
          description={
            gettext("The scan returned no typed receipts belonging to this organization here.")
          }
        />

        <.table
          :if={unwrap(@receipts).receipts != []}
          id="triage-receipt-scan"
          rows={unwrap(@receipts).receipts}
        >
          <:col :let={receipt} label={gettext("Created")}>
            <span class="font-mono text-xs text-neutral-500">
              {format_datetime(receipt["created_at"])}
            </span>
          </:col>
          <:col :let={receipt} label={gettext("Agent Swarm")}>
            {owner_label(unwrap(@receipts).owners, receipt["connect_id"])}
          </:col>
          <:col :let={receipt} label={gettext("Refs")}>
            <div class="max-w-[26rem] space-y-1">
              <div class="truncate font-mono text-xs" title={receipt["receipt_ref"]}>
                {receipt["receipt_ref"]}
              </div>
              <div
                class="truncate font-mono text-xs text-neutral-500"
                title={receipt["source_message_ref"]}
              >
                {receipt["source_message_ref"]}
              </div>
            </div>
          </:col>
          <:col :let={receipt} label={gettext("Message")}>
            <div class="max-w-[24rem]">
              <.revealable_text
                ref={receipt["receipt_ref"]}
                connect_id={receipt["connect_id"]}
                text={(receipt["triage_event"] || %{})["text"]}
                revealed={@revealed}
              />
            </div>
          </:col>
        </.table>

        <.next_page
          :if={unwrap(@receipts).next_cursor}
          patch={
            tab_path(
              @org,
              :data,
              Map.put(@filters, "receipt_cursor", unwrap(@receipts).next_cursor)
            )
          }
        />
      </div>
    </div>
    """
  end

  attr(:buckets, :any, required: true)
  attr(:detail, :any, required: true)
  attr(:org, :map, required: true)
  attr(:filters, :map, required: true)
  attr(:revealed, :any, required: true)

  defp bucket_list(assigns) do
    ~H"""
    <div>
      <.section_fault
        :if={faulted?(@buckets)}
        result={@buckets}
        label={gettext("Buckets")}
        reset_patch={scan_reset_path(@org, @filters)}
      />
      <div :if={ok?(@buckets)} class="space-y-3">
        <div class="flex flex-wrap items-center gap-2 text-xs">
          <.count_chip label={gettext("invalid")} value={unwrap(@buckets).invalid_count} />
          <.count_chip
            label={gettext("unavailable")}
            value={unavailable_count(unwrap(@buckets))}
          />
          <.count_chip label={gettext("outside this org")} value={unwrap(@buckets).foreign_count} />
          <.count_chip
            :if={not unwrap(@buckets).scope_complete}
            label={gettext("unattributed")}
            value={unwrap(@buckets).unattributed_count}
          />
        </div>
        <p class="text-xs text-neutral-500">
          {gettext(
            "\"invalid\" is objects the scan refused to emit; \"unavailable\" is objects it could not read. An unreadable bucket may be perfectly valid and is not counted as poison."
          )}
        </p>
        <.notice :if={Map.get(unwrap(@buckets), :truncated, false)} tone="amber">
          {gettext(
            "This bucket page is incomplete because its safe read limit was reached. Remaining bucket bodies were not opened."
          )}
        </.notice>
        <.scope_notice result={@buckets} />

        <.empty_state
          :if={unwrap(@buckets).buckets == []}
          icon="folder"
          title={gettext("No buckets on this page")}
          description={bucket_empty_description(unwrap(@buckets))}
        />

        <div class="grid grid-cols-1 gap-3 xl:grid-cols-2">
          <div
            :for={bucket <- unwrap(@buckets).buckets}
            id={scope_dom_id(bucket.bucket_scope)}
            class={[
              "rounded-lg border px-4 py-3 shadow-subtle",
              expanded_bucket?(@filters, bucket) && "xl:col-span-2",
              @filters["scope"] == bucket.bucket_scope && "border-brand-300 bg-brand-50/30",
              @filters["scope"] != bucket.bucket_scope && "border-neutral-200 bg-white"
            ]}
          >
            <div class="flex items-start justify-between gap-3">
              <span class="min-w-0 break-all font-mono text-xs leading-relaxed text-neutral-700">
                {bucket.bucket_scope}
              </span>
              <.link
                patch={bucket_toggle_path(@org, @filters, bucket)}
                class="shrink-0 text-xs font-medium text-brand-700 hover:underline focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
              >
                {if expanded_bucket?(@filters, bucket),
                  do: gettext("Collapse"),
                  else: gettext("Receipts")}
              </.link>
            </div>

            <div class="mt-3 flex flex-wrap items-center gap-2">
              <.chip tone="neutral">
                {ngettext("%{count} receipt", "%{count} receipts", bucket.receipt_count)}
              </.chip>
              <.tag :if={bucket.fast_path}>{gettext("fast path")}</.tag>
            </div>

            <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-neutral-400">
              <span class="tabular-nums">
                {gettext("Opened %{at}", at: format_datetime(bucket.open_first_at))}
              </span>
              <span class="tabular-nums">
                {gettext("Last %{at}", at: format_datetime(bucket.open_last_at))}
              </span>
              <span class="min-w-0 break-all font-mono">{blank_dash(bucket.bucket_key)}</span>
            </div>

            <.bucket_detail
              :if={expanded_bucket?(@filters, bucket)}
              detail={@detail}
              revealed={@revealed}
            />
          </div>
        </div>

        <.next_page
          :if={unwrap(@buckets).next_cursor}
          patch={
            tab_path(@org, :data, Map.put(@filters, "bucket_cursor", unwrap(@buckets).next_cursor))
          }
        />
      </div>
    </div>
    """
  end

  # The same split as `timeline_empty_description/2`, for the same reason: "no
  # bucket here belongs to this org" is a claim about the org, and the page can
  # only make it when every object on the page was readable *and* every
  # project's posture was too. A failed GET hides a bucket that may well be
  # this org's; an incomplete scope drops rows it could not attribute. Either
  # way the honest sentence is about what came back, not about what exists.
  defp bucket_empty_description(page) do
    if unavailable_count(page) > 0 or Map.get(page, :truncated, false) or
         not page.scope_complete do
      gettext(
        "No readable, attributable bucket came back for this page. Part of the read did not complete, so this is not evidence that this organization has no buckets."
      )
    else
      gettext("No durable bucket on this page belongs to this organization.")
    end
  end

  attr(:detail, :any, required: true)
  attr(:revealed, :any, required: true)

  defp bucket_detail(assigns) do
    assigns =
      assigns
      |> assign(:result, assigns.detail && elem(assigns.detail, 1))
      |> assign(:detail_receipts, bucket_detail_receipts(assigns.detail))

    ~H"""
    <div class="mt-3 border-t border-neutral-100 pt-3">
      <.section_fault
        :if={faulted?(@result)}
        result={@result}
        label={gettext("Bucket receipts")}
      />
      <ul :if={ok?(@result)} class="space-y-2">
        <li
          :for={receipt <- @detail_receipts}
          class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2"
        >
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-neutral-400">
            <span class="font-mono tabular-nums">{format_datetime(receipt["created_at"])}</span>
            <span class="font-mono">{(receipt["triage_event"] || %{})["actor_id"]}</span>
            <span class="min-w-0 break-all font-mono">{receipt["receipt_ref"]}</span>
          </div>
          <.revealable_text
            ref={receipt["receipt_ref"]}
            connect_id={receipt["connect_id"]}
            text={(receipt["triage_event"] || %{})["text"]}
            revealed={@revealed}
          />
        </li>
      </ul>
    </div>
    """
  end

  defp bucket_detail_receipts({_bucket_key, {:ok, detail}}) do
    Map.get(detail, :sealed_receipts, []) ++ Map.get(detail, :receipts, [])
  end

  defp bucket_detail_receipts(_detail), do: []

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  # The honest-count strip: one labelled pill per count, the number carried in
  # tabular figures so a row of them lines up.
  defp count_chip(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 whitespace-nowrap rounded-full bg-neutral-100 px-2.5 py-0.5 text-[11px] leading-5">
      <span class="font-medium text-neutral-500">{@label}</span>
      <span class="font-semibold tabular-nums text-neutral-800">{@value}</span>
    </span>
    """
  end

  attr(:patch, :string, required: true)

  defp next_page(assigns) do
    ~H"""
    <.link patch={@patch} class="inline-flex text-sm font-medium text-brand-700 hover:underline">
      {gettext("Next page")}
    </.link>
    """
  end

  # ---- degradation ----

  attr(:result, :any, required: true)
  attr(:label, :string, required: true)
  attr(:reset_patch, :any, default: nil)

  # One component for every failure a section can render, because "the read
  # failed", "the requested record is absent", and "there is nothing here" are
  # different facts and must never look alike. Runtime enablement is not one of
  # these states: AI evaluation is a fixed product capability.
  defp section_fault(assigns) do
    ~H"""
    <div>
      <.empty_state
        :if={fault_kind(@result) == :not_found}
        icon="folder"
        title={gettext("Not found")}
        description={
          gettext("%{label} is not stored here, or does not belong to this organization.",
            label: @label
          )
        }
      />

      <div
        :if={fault_kind(@result) == :invalid_position}
        class="rounded-md border border-amber-200 bg-amber-50 px-3 py-3 text-sm text-amber-900"
      >
        <div class="font-medium">
          {gettext("%{label}: this page position is not valid", label: @label)}
        </div>
        <p class="mt-1 text-xs text-amber-800">
          {gettext(
            "The cursor in the address bar does not address a position in this scan (%{reason}). Nothing is wrong with the data — the link was truncated, hand-edited, or left over from an older page shape.",
            reason: reason_text(fault_reason(@result))
          )}
        </p>
        <.link
          :if={@reset_patch}
          patch={@reset_patch}
          class="mt-2 inline-flex text-xs font-medium text-amber-900 underline"
        >
          {gettext("Start from the first page")}
        </.link>
      </div>

      <div
        :if={fault_kind(@result) == :audit_unavailable}
        class="rounded-md border border-red-200 bg-red-50 px-3 py-3 text-sm text-red-900"
      >
        <div class="font-medium">
          {gettext("%{label} was not shown", label: @label)}
        </div>
        <p class="mt-1 text-xs text-red-800">
          {gettext(
            "The access record failed to write, so the body was never fetched — nothing was read and nothing is shown. This does not establish whether the file exists or is empty: its content was never looked at, because an unaudited read of user data would be worse than no read."
          )}
        </p>
      </div>

      <div
        :if={fault_kind(@result) == :unavailable}
        class="rounded-md border border-red-200 bg-red-50 px-3 py-3 text-sm text-red-900"
      >
        <div class="font-medium">
          {gettext("%{label} is unavailable", label: @label)}
        </div>
        <p class="mt-1 text-xs text-red-800">
          {gettext(
            "The read failed (%{reason}). This is not an empty result: rows may exist and could not be fetched. The rest of the page is unaffected.",
            reason: reason_text(fault_reason(@result))
          )}
        </p>
      </div>
    </div>
    """
  end

  defp fault_kind({:error, :not_found}), do: :not_found
  defp fault_kind({:error, :no_agent}), do: :not_found
  defp fault_kind({:error, :agent_not_found}), do: :not_found

  # Its own kind, not the red "the read failed" box: nothing failed to read,
  # because nothing was read. The access record could not be written, so the
  # seam was never asked — the page says that and nothing more (it cannot say
  # the file exists; existence is exactly what was never checked), and only
  # that sentence sends an operator to the audit store rather than to Salix.
  defp fault_kind({:error, :audit_unavailable}), do: :audit_unavailable

  # A cursor the read model refuses is a fact about the URL, not about Salix.
  # Rendering it in the red "the read failed, rows may exist" box sends an
  # operator to look for an outage; the honest answer is that the position is
  # unusable and the fix is one link away.
  defp fault_kind({:error, reason})
       when reason in [
              :invalid_triage_bucket_cursor,
              :invalid_triage_bucket_page,
              :invalid_slack_triage_cursor
            ],
       do: :invalid_position

  defp fault_kind({:error, _reason}), do: :unavailable
  defp fault_kind(_result), do: nil

  # Only ever reached from the `:unavailable` branch above, which by
  # construction holds an `{:error, reason}`.
  defp fault_reason({:error, reason}), do: reason

  defp faulted?({:error, _reason}), do: true
  defp faulted?(_result), do: false

  defp ok?({:ok, _value}), do: true
  defp ok?(_result), do: false

  defp active_context?({:ok, %{id: id}}) when is_binary(id), do: true
  defp active_context?(_result), do: false

  defp unwrap({:ok, value}), do: value

  defp evaluation_readiness({:ok, %{evaluation_readiness: readiness}})
       when readiness in [:ready, :unavailable, :unknown],
       do: readiness

  # An RPC fault, a rolling-deploy old shape, or any malformed response means
  # "we do not know". It must never be collapsed into an explicit service-down
  # claim: monitoring authority and evaluator readiness are separate facts.
  defp evaluation_readiness(_ring), do: :unknown

  defp evaluation_readiness_label(:ready), do: gettext("Available")
  defp evaluation_readiness_label(:unavailable), do: gettext("Temporarily unavailable")
  defp evaluation_readiness_label(:unknown), do: gettext("Status unavailable")

  defp evaluation_readiness_tone(:ready), do: "green"
  defp evaluation_readiness_tone(:unavailable), do: "amber"
  defp evaluation_readiness_tone(:unknown), do: "neutral"

  defp background_processing_status({:ok, %{running: true}}), do: :active
  defp background_processing_status({:ok, %{running: false}}), do: :unavailable
  defp background_processing_status(_ring), do: :unknown

  defp background_processing_label(:active), do: gettext("Background processing active")

  defp background_processing_label(:unavailable),
    do: gettext("Background processing unavailable")

  defp background_processing_label(:unknown), do: gettext("Background status unavailable")

  defp background_processing_tone(:active), do: "green"
  defp background_processing_tone(:unavailable), do: "amber"
  defp background_processing_tone(:unknown), do: "neutral"

  defp evaluation_observed_at({:ok, %{runtime: %{observed_at_ms: observed_at_ms}}})
       when is_integer(observed_at_ms),
       do: observed_at_ms

  defp evaluation_observed_at(_ring), do: nil

  defp ring_runtime_value({:ok, %{runtime: runtime}}, key) when is_map(runtime),
    do: Map.get(runtime, key)

  defp ring_runtime_value(_ring, _key), do: nil

  defp ring_recovery_value({:ok, %{recovery: recovery}}, key) when is_map(recovery),
    do: Map.get(recovery, key)

  defp ring_recovery_value(_ring, _key), do: nil

  defp monitoring_active?(connect) when is_map(connect) do
    connect[:triage_enabled] == true and
      Enum.any?(connect[:configured_channels] || [], &(&1[:enabled] == true))
  end

  defp monitoring_active?(_connect), do: false

  attr(:tone, :string, default: "neutral", values: ~w(neutral amber))
  slot(:inner_block, required: true)

  defp notice(assigns) do
    ~H"""
    <p class={[
      "rounded-md px-3 py-2 text-xs leading-relaxed",
      @tone == "amber" && "border border-amber-200 bg-amber-50 text-amber-900",
      @tone == "neutral" && "bg-neutral-100/70 text-neutral-500"
    ]}>
      {render_slot(@inner_block)}
    </p>
    """
  end

  # ---- params ----

  defp assign_filters(socket, params) do
    filters =
      Enum.reduce(@filter_keys, %{}, fn key, acc ->
        case params[key] do
          value when is_binary(value) and value != "" -> Map.put(acc, key, value)
          _blank -> acc
        end
      end)

    assign(socket, :filters, filters)
  end

  defp assign_current_tab(socket, tab) when tab in @tabs, do: assign(socket, :current_tab, tab)
  defp assign_current_tab(socket, :context), do: assign(socket, :current_tab, :context)
  # Keep old deep links functional for operators who bookmarked the read-only
  # memory browser. It is intentionally absent from the new product tabs:
  # project knowledge is the supported Triage surface, while this route remains
  # a compatibility view until its separate retirement is explicitly decided.
  defp assign_current_tab(socket, :memory), do: assign(socket, :current_tab, :memory)
  defp assign_current_tab(socket, _other), do: assign(socket, :current_tab, :overview)

  defp assign_breadcrumbs(socket) do
    org = socket.assigns.current_org

    breadcrumbs =
      case socket.assigns.current_tab do
        :overview ->
          [{org.name, ~p"/orgs/#{org.slug}"}, {gettext("Triage"), nil}]

        tab ->
          [
            {org.name, ~p"/orgs/#{org.slug}"},
            {gettext("Triage"), ~p"/orgs/#{org.slug}/triage"},
            {tab_label(tab), nil}
          ]
      end

    assign(socket, :breadcrumbs, breadcrumbs)
  end

  # Cursors and the expanded bucket are positions inside one tab, not a global
  # filter: carrying them across a tab switch would scroll a fresh tab to a
  # meaningless place.
  defp nav_filters(filters),
    do: Map.drop(filters, ["bucket", "bucket_cursor", "file", "receipt_cursor"])

  defp tab_path(org, :overview, params), do: ~p"/orgs/#{org.slug}/triage?#{compact(params)}"

  defp tab_path(org, :context, params),
    do: ~p"/orgs/#{org.slug}/triage/context?#{compact(params)}"

  defp tab_path(org, :timeline, params),
    do: ~p"/orgs/#{org.slug}/triage/timeline?#{compact(params)}"

  defp tab_path(org, :knowledge, params),
    do: ~p"/orgs/#{org.slug}/triage/knowledge?#{compact(params)}"

  defp tab_path(org, :memory, params), do: ~p"/orgs/#{org.slug}/triage/memory?#{compact(params)}"
  defp tab_path(org, :data, params), do: ~p"/orgs/#{org.slug}/triage/data?#{compact(params)}"

  defp slack_context_base_path(socket) do
    filters =
      socket.assigns.filters
      |> nav_filters()
      |> Map.drop(["mode", "step"])

    tab_path(socket.assigns.current_org, :context, filters)
  end

  defp compact(params), do: Map.reject(params, fn {_key, value} -> value in [nil, ""] end)

  defp content_chrome(_action), do: :panel

  defp suppress_onboarding_checklist?(:context), do: true
  defp suppress_onboarding_checklist?(_action), do: false

  defp memory_entry_path(org, agent, %{"kind" => "dir", "path" => path}),
    do: tab_path(org, :memory, %{"agent" => agent.agent_id, "path" => path})

  defp memory_entry_path(org, agent, %{"path" => path}),
    do: tab_path(org, :memory, %{"agent" => agent.agent_id, "file" => path})

  # The escape hatch from an unusable cursor: keep the tab's other filters,
  # drop every position-bearing one so the next render starts from the top of
  # both scans.
  defp scan_reset_path(org, filters),
    do: tab_path(org, :data, Map.drop(filters, ["bucket", "bucket_cursor", "receipt_cursor"]))

  defp bucket_toggle_path(org, filters, bucket) do
    if expanded_bucket?(filters, bucket) do
      tab_path(org, :data, Map.delete(filters, "bucket"))
    else
      tab_path(org, :data, Map.put(filters, "bucket", bucket.bucket_key))
    end
  end

  defp expanded_bucket?(filters, bucket), do: filters["bucket"] == bucket.bucket_key

  # The bucket key is a sha256 that BFT cannot derive from a receipt, so a
  # Timeline card links by the scope it *can* compute and the Data tab anchors
  # on the matching row.
  defp scope_dom_id(scope), do: "bucket-" <> Base.url_encode64(to_string(scope), padding: false)

  # ---- formatting ----

  defp product_activity_sections({:ok, %{outcomes: outcomes, context: context}})
       when is_list(outcomes) and is_list(context),
       do: {Enum.take(outcomes, 20), Enum.take(context, 20)}

  defp product_activity_sections(_activity), do: {[], []}

  defp product_activity_counts(outcomes) do
    %{
      total: length(outcomes),
      reply: Enum.count(outcomes, &(get_in(&1, [:communication, :kind]) == :reply)),
      reaction: Enum.count(outcomes, &(get_in(&1, [:communication, :kind]) == :reaction)),
      silence:
        Enum.count(outcomes, fn item ->
          get_in(item, [:communication, :kind]) == :silence and
            get_in(item, [:communication, :reason]) != "worker_pending"
        end),
      in_progress: Enum.count(outcomes, &product_outcome_in_progress?/1),
      failed: Enum.count(outcomes, &product_outcome_failed?/1)
    }
  end

  @heatmap_column_ms 3 * 3_600_000
  @heatmap_columns 56
  @heatmap_rows 8

  # Groups hourly Salix cells into 3-hour columns over the 7-day window. Rows
  # are the busiest channels; each cell's level is relative to the busiest cell.
  defp heatmap_view({:ok, %{since_ms: since_ms, cells: [_ | _] = cells} = heatmap}, channel_names) do
    filterable =
      MapSet.new(channel_names, fn {{_connect_id, channel_id}, _name} -> channel_id end)

    channels =
      cells
      |> Enum.group_by(&{&1.connect_id, &1.channel_id})
      |> Enum.map(fn {{connect_id, channel_id}, channel_cells} ->
        columns =
          Enum.reduce(channel_cells, %{}, fn cell, acc ->
            index =
              min(max(div(cell.at_ms - since_ms, @heatmap_column_ms), 0), @heatmap_columns - 1)

            Map.update(
              acc,
              index,
              Map.take(cell, [:reply, :reaction, :silence, :total]),
              fn sum ->
                Map.new(sum, fn {key, value} -> {key, value + cell[key]} end)
              end
            )
          end)

        name = Map.get(channel_names, {to_string(connect_id), to_string(channel_id)})

        %{
          channel_id: channel_id,
          label: if(is_binary(name) and name != "", do: "#" <> name, else: channel_id),
          filterable?: MapSet.member?(filterable, channel_id),
          total: channel_cells |> Enum.map(& &1.total) |> Enum.sum(),
          columns: columns
        }
      end)
      |> Enum.sort_by(&{-&1.total, &1.label})

    {shown, hidden} = Enum.split(channels, @heatmap_rows)
    peak = shown |> Enum.flat_map(&Map.values(&1.columns)) |> Enum.map(& &1.total) |> Enum.max()

    rows =
      Enum.map(shown, fn row ->
        cells =
          for index <- 0..(@heatmap_columns - 1) do
            counts = Map.get(row.columns, index, %{reply: 0, reaction: 0, silence: 0, total: 0})
            start_ms = since_ms + index * @heatmap_column_ms

            Map.merge(counts, %{
              start_ms: start_ms,
              end_ms: start_ms + @heatmap_column_ms,
              level: heatmap_level(counts.total, peak),
              acted?: counts.reply + counts.reaction > 0
            })
          end

        row |> Map.delete(:columns) |> Map.put(:cells, cells)
      end)

    %{
      rows: rows,
      hidden: length(hidden),
      truncated: heatmap[:truncated] == true,
      ticks: for(day <- 0..6, do: since_ms + day * 8 * @heatmap_column_ms)
    }
  end

  defp heatmap_view(_heatmap, _channel_names), do: nil

  defp heatmap_level(0, _peak), do: 0
  defp heatmap_level(total, peak), do: max(1, min(4, ceil(4 * total / peak)))

  defp heatmap_level_class(0), do: "bg-neutral-100"
  defp heatmap_level_class(1), do: "bg-brand-100"
  defp heatmap_level_class(2), do: "bg-brand-200"
  defp heatmap_level_class(3), do: "bg-brand-400"
  defp heatmap_level_class(_level), do: "bg-brand-600"

  defp heatmap_cell_summary(cell) do
    [
      ngettext("1 outcome", "%{count} outcomes", cell.total),
      "#{gettext("Reply")} #{cell.reply}",
      "#{gettext("Reaction")} #{cell.reaction}",
      "#{gettext("Stayed silent")} #{cell.silence}"
    ]
    |> Enum.join(" · ")
  end

  attr(:view, :map, required: true)
  attr(:navigation, :map, required: true)

  defp activity_heatmap(assigns) do
    ~H"""
    <div id="triage-activity-heatmap" class="border-b border-neutral-200 px-3 py-3">
      <div class="mb-2 flex flex-wrap items-center justify-between gap-2 text-xs leading-5">
        <span class="font-medium text-neutral-700">{gettext("Last 7 days by channel")}</span>
        <span class="flex items-center gap-1 text-neutral-500" aria-hidden="true">
          {gettext("Fewer")}
          <span :for={level <- 0..4} class={["h-2.5 w-2.5 rounded-sm", heatmap_level_class(level)]} />
          {gettext("More")}
          <span class="ml-2 h-1.5 w-1.5 rounded-full bg-green-500" />
          {gettext("Replied or reacted")}
        </span>
      </div>
      <div class="grid grid-cols-[9rem_minmax(0,1fr)] items-center gap-x-2 gap-y-1">
        <%= for row <- @view.rows do %>
          <span data-role="heatmap-channel" class="truncate text-xs text-neutral-600" title={row.label}>{row.label}</span>
          <div data-role="heatmap-row" class="grid grid-cols-[repeat(56,minmax(0,1fr))] gap-px">
            <%= for cell <- row.cells do %>
              <button
                :if={row.filterable? and cell.total > 0}
                type="button"
                data-role="heatmap-cell"
                data-level={cell.level}
                data-local-title-ms={cell.start_ms}
                data-local-title-end-ms={cell.end_ms}
                data-local-title-suffix={heatmap_cell_summary(cell)}
                title={"#{format_timeline_datetime(cell.start_ms)} UTC · #{heatmap_cell_summary(cell)}"}
                aria-label={"#{row.label} #{format_timeline_datetime(cell.start_ms)} UTC · #{heatmap_cell_summary(cell)}"}
                phx-click="select-triage-heatmap-cell"
                phx-value-channel={row.channel_id}
                phx-value-before={cell.end_ms}
                class={[
                  "relative grid h-4 place-items-center rounded-sm hover:ring-2 hover:ring-brand-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500",
                  heatmap_level_class(cell.level),
                  @navigation[:channel] == row.channel_id and @navigation[:before] == cell.end_ms &&
                    "ring-2 ring-neutral-900"
                ]}
              >
                <span :if={cell.acted?} class="h-1.5 w-1.5 rounded-full bg-green-500 ring-1 ring-white" />
              </button>
              <span
                :if={not (row.filterable? and cell.total > 0)}
                data-role="heatmap-cell"
                data-level={cell.level}
                data-local-title-ms={cell.total > 0 && cell.start_ms}
                data-local-title-end-ms={cell.total > 0 && cell.end_ms}
                data-local-title-suffix={cell.total > 0 && heatmap_cell_summary(cell)}
                class={["grid h-4 place-items-center rounded-sm", heatmap_level_class(cell.level)]}
              >
                <span :if={cell.acted?} class="h-1.5 w-1.5 rounded-full bg-green-500 ring-1 ring-white" />
              </span>
            <% end %>
          </div>
        <% end %>
        <span />
        <div class="grid grid-cols-7 text-[11px] tabular-nums text-neutral-400">
          <.browser_local_time
            :for={tick <- @view.ticks}
            ms={tick}
            format="month-day"
            fallback={format_month_day(tick)}
            class="truncate"
          />
        </div>
      </div>
      <p :if={@view.hidden > 0 or @view.truncated} class="mt-2 text-xs text-neutral-500">
        <span :if={@view.hidden > 0}>
          {ngettext("1 quieter channel not shown.", "%{count} quieter channels not shown.", @view.hidden)}
        </span>
        <span :if={@view.truncated}>{gettext("Older cells were omitted.")}</span>
      </p>
    </div>
    """
  end

  defp product_outcome_in_progress?(%{state: state}) when state in [:pending, :claimed], do: true

  defp product_outcome_in_progress?(%{companion_effect: %{state: state}})
       when state in [:pending, :claimed],
       do: true

  defp product_outcome_in_progress?(_item), do: false

  defp product_outcome_failed?(%{state: :failed}), do: true
  defp product_outcome_failed?(%{companion_effect: %{state: :failed}}), do: true
  defp product_outcome_failed?(_item), do: false

  # Only a channel configured for the selected Agent's Slack sources can be a
  # filter; anything else from the client falls back to all channels.
  defp activity_channel_filter(socket, channel) when is_binary(channel) and channel != "" do
    known =
      socket.assigns.selected_agent
      |> product_channel_options(socket.assigns.agent_source_posture)
      |> Enum.any?(fn {id, _label} -> id == channel end)

    if known, do: channel
  end

  defp activity_channel_filter(_socket, _channel), do: nil

  defp product_channel_options(agent, source_posture) do
    agent
    |> product_channel_names(source_posture)
    |> Enum.map(fn {{_connect_id, channel_id}, name} ->
      {channel_id, if(is_binary(name) and name != "", do: "#" <> name, else: channel_id)}
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&{elem(&1, 1), elem(&1, 0)})
  end

  defp product_channel_names(nil, _source_posture), do: %{}

  defp product_channel_names(agent, source_posture) do
    agent
    |> agent_source_view(source_posture)
    |> Map.fetch!(:sources)
    |> Enum.flat_map(fn source ->
      Enum.map(source[:configured_channels] || [], fn channel ->
        {{to_string(source.connect_id), to_string(channel.channel_id)}, channel.channel_name}
      end)
    end)
    |> Map.new()
  end

  defp put_product_channel_label(item, channel_names) do
    source = item[:source] || %{}

    Map.put(
      item,
      :channel_label,
      product_channel_label(source[:connect_id], source[:channel_id], channel_names)
    )
  end

  defp product_channel_label(connect_id, channel_id, channel_names) do
    channel_name = Map.get(channel_names, {to_string(connect_id), to_string(channel_id)})

    cond do
      is_binary(channel_name) and channel_name != "" ->
        "#" <> channel_name

      true ->
        gettext("Slack channel unavailable")
    end
  end

  defp product_outcome_tone(%{state: :failed}), do: "amber"
  defp product_outcome_tone(%{companion_effect: %{state: :failed}}), do: "amber"

  defp product_outcome_tone(%{companion_effect: %{state: state}})
       when state in [:pending, :claimed],
       do: "brand"

  defp product_outcome_tone(%{state: :stale}), do: "amber"
  defp product_outcome_tone(%{state: state}) when state in [:pending, :claimed], do: "brand"
  defp product_outcome_tone(%{communication: %{reason: "worker_pending"}}), do: "brand"
  defp product_outcome_tone(%{communication: %{kind: :reply}}), do: "green"
  defp product_outcome_tone(%{communication: %{kind: :reaction}}), do: "green"
  defp product_outcome_tone(%{communication: %{kind: :silence}}), do: "neutral"
  defp product_outcome_tone(_item), do: "neutral"

  defp product_outcome_effect_summary(item) do
    context_count =
      case item[:context] do
        %{candidates: count} when is_integer(count) and count > 0 -> count
        _context -> 0
      end

    []
    |> maybe_add_outcome_effect(
      context_count > 0,
      ngettext("1 context effect", "%{count} context effects", context_count)
    )
    |> add_product_delegation_summaries(item)
    |> maybe_add_outcome_effect(
      get_in(item, [:communication, :kind]) == :reaction and
        get_in(item, [:effect, :external_writes]) == 1,
      gettext("1 Slack reaction")
    )
    |> maybe_add_outcome_effect(
      get_in(item, [:companion_reaction, :kind]) == :reaction and
        get_in(item, [:companion_effect, :external_writes]) == 1,
      gettext("1 Slack reaction")
    )
    |> maybe_add_outcome_effect(
      get_in(item, [:companion_reaction, :kind]) == :reaction and
        get_in(item, [:companion_effect, :state]) in [:pending, :claimed],
      gettext("Reaction in progress")
    )
    |> maybe_add_outcome_effect(local_rehearsal_outcome?(item), gettext("0 Slack writes"))
    |> case do
      [] -> nil
      effects -> Enum.join(effects, " · ")
    end
  end

  defp maybe_add_outcome_effect(effects, true, label), do: effects ++ [label]
  defp maybe_add_outcome_effect(effects, false, _label), do: effects

  defp add_product_delegation_summaries(effects, item) do
    created = product_delegation_count(item, "created")
    routed = product_delegation_count(item, "routed")
    proposed = product_delegation_count(item, "proposed")
    retrying = product_delegation_count(item, "retry_scheduled")
    stale = product_delegation_count(item, "suppressed_stale")
    unavailable = product_delegation_count(item, "unavailable")

    effects
    |> maybe_add_outcome_effect(
      created > 0,
      ngettext("1 worker task created", "%{count} worker tasks created", created)
    )
    |> maybe_add_outcome_effect(
      routed > 0,
      ngettext("1 investigation routed", "%{count} investigations routed", routed)
    )
    |> maybe_add_outcome_effect(
      proposed > 0,
      ngettext("1 worker task proposed", "%{count} worker tasks proposed", proposed)
    )
    |> maybe_add_outcome_effect(
      retrying > 0,
      ngettext("1 worker task awaiting retry", "%{count} worker tasks awaiting retry", retrying)
    )
    |> maybe_add_outcome_effect(
      stale > 0,
      ngettext("1 stale worker task suppressed", "%{count} stale worker tasks suppressed", stale)
    )
    |> maybe_add_outcome_effect(
      unavailable > 0,
      ngettext(
        "1 worker task status unavailable",
        "%{count} worker task statuses unavailable",
        unavailable
      )
    )
  end

  defp product_delegation_count(%{delegations: delegations}, status)
       when is_list(delegations) and
              status in ~w(created routed proposed retry_scheduled suppressed_stale unavailable) do
    Enum.count(delegations, &(product_delegation_status(&1) == status))
  end

  defp product_delegation_count(_item, _status), do: 0

  attr(:item, :map, required: true)
  attr(:delegation, :map, required: true)
  attr(:results, :map, required: true)
  attr(:agent, :any, required: true)
  attr(:org, :map, required: true)

  defp product_delegation(assigns) do
    locator = delegation_locator(assigns.item, assigns.delegation)
    result = Map.get(assigns.results, locator)
    {conversation_id, message} = delegation_task_presentation(result)

    task =
      case result do
        {:ok, task} -> task
        _ -> %{}
      end

    assigns =
      assigns
      |> assign(:locator, locator)
      |> assign(:queried?, not is_nil(result))
      |> assign(:conversation_id, conversation_id)
      |> assign(:lookup_message, message)
      |> assign(:task, task)

    ~H"""
    <li data-delegation-index={Map.get(@delegation, :index)} class="mt-4 space-y-3 rounded-lg border border-neutral-200 p-4">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
      <span class="min-w-0 flex-1 font-medium text-neutral-800">{product_delegation_label(@delegation)}</span>
      <.link
        :if={@conversation_id && @agent}
        navigate={~p"/orgs/#{@org.slug}/projects/#{@agent.project_id}/tasks/#{@conversation_id}"}
        class="ml-2 font-medium text-blue-700 hover:underline"
      >
        {gettext("Open Task")}
      </.link>
      <button
        :if={@locator && @agent}
        type="button"
        phx-click="lookup-delegation-task"
        phx-value-obligation={elem(@locator, 0)}
        phx-value-index={elem(@locator, 1)}
        phx-disable-with={gettext("Checking…")}
        class="ml-2 font-medium text-blue-700 hover:underline disabled:opacity-50"
      >
        {if @queried?, do: gettext("Refresh Task"), else: gettext("Load Task")}
      </button>
      </div>
      <p :if={@lookup_message} role="status" class="text-xs text-neutral-500">
        {@lookup_message}
      </p>
      <p :if={@task["preview_unavailable"]} role="status" class="text-sm text-amber-700">
        {gettext("Task content is unavailable. Open the Task or try refreshing.")}
      </p>
      <div :if={@task["conversation"]} data-role="task-preview" class="space-y-4">
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <span class="font-medium text-neutral-800">{@task["conversation"]["title"]}</span>
          <span data-role="task-status" class="text-neutral-600">{task_status_label(@task["conversation"]["status"])}</span>
        </div>
        <p :if={@task["conversation"]["status"] == "ready_for_review"} class="text-xs text-neutral-500">
          {gettext("The Worker finished. This Task is waiting for human review.")}
        </p>
        <p :if={get_in(@task, ["conversation", "metadata", "triage_investigation_state", "delivery_error"])} data-role="worker-delivery-error" class="text-sm text-amber-700">
          {gettext("Worker delivery could not be confirmed. It may still finish. Check this Task before retrying.")}
        </p>
        <p :if={@task["participation_result"]} data-role="participation-result" class="text-sm text-neutral-700">
          {gettext("Worker decision: %{decision}", decision: participation_result_label(@task["participation_result"]))}
        </p>
        <p class="text-xs text-neutral-500">
          {gettext("Private Task activity · latest 20 messages")}
        </p>
        <p :if={@task["messages"] == []} class="text-sm text-neutral-500">{gettext("No Task messages yet.")}</p>
        <div class="space-y-4">
          <article :for={message <- @task["messages"]} data-task-message={message["message_id"]} class="min-w-0 border-l-2 border-neutral-200 pl-3">
            <div class="mb-1 flex flex-wrap items-baseline gap-2 text-xs text-neutral-500">
              <span class="font-medium text-neutral-700">{task_message_actor(message)}</span>
              <time>{format_datetime(message["created_at"])}</time>
            </div>
            <div class="break-words text-sm leading-6 text-neutral-800">
              <TaskConversation.message_body message={message} org={@org} project={%{id: @agent.project_id}} conversation={@task["conversation"]} />
            </div>
          </article>
        </div>
      </div>
    </li>
    """
  end

  defp participation_result_label(%{
         "kind" => "silence",
         "reason_code" => "insufficient_evidence"
       }),
       do: gettext("Required evidence unavailable")

  defp participation_result_label(%{"kind" => "silence", "reason_code" => "already_handled"}),
    do: gettext("Already handled")

  defp participation_result_label(%{"kind" => "silence", "reason_code" => "no_useful_addition"}),
    do: gettext("No useful addition")

  defp participation_result_label(%{"kind" => "silence"}),
    do: gettext("Silence · reason unclassified")

  defp participation_result_label(%{"kind" => "reply"}), do: gettext("Reply")
  defp participation_result_label(%{"kind" => "reaction"}), do: gettext("Reaction")

  defp task_status_label("ready_for_review"), do: gettext("Ready for review")
  defp task_status_label("completed"), do: gettext("Completed")
  defp task_status_label("failed"), do: gettext("Failed")
  defp task_status_label("cancelled"), do: gettext("Cancelled")
  defp task_status_label("escalated"), do: gettext("Blocked")

  defp task_status_label(status) when status in ["pending", "accepted", "active", "in_progress"],
    do: gettext("In progress")

  defp task_status_label(status) when is_binary(status), do: status
  defp task_status_label(_), do: gettext("Status unavailable")

  defp task_message_actor(%{"actor_type" => "agent"} = message),
    do: message["agent_name"] || message["role_label"] || gettext("Worker")

  defp task_message_actor(message),
    do: message["display_name"] || message["role_label"] || gettext("Task message")

  defp load_activity_tasks(socket, "outcome", id) do
    socket = assign(socket, :delegation_tasks, %{})

    with :timeline <- socket.assigns.current_tab,
         {:ok, role} <-
           Memberships.org_role(socket.assigns.current_org.id, socket.assigns.current_user.id),
         true <- can_view_triage?(role),
         {:ok, %{outcomes: outcomes}} <- socket.assigns.product_activity,
         %{} = item <- Enum.find(outcomes, &(&1.event_ref == id)) do
      results =
        item.delegations
        |> Enum.take(2)
        |> Enum.reduce(%{}, fn delegation, results ->
          case delegation_locator(item, delegation) do
            {obligation, index} = locator ->
              result =
                Triage.delegation_task_preview(
                  socket.assigns.current_org,
                  socket.assigns.selected_agent,
                  socket.assigns.current_user.id,
                  obligation,
                  index
                )

              Map.put(results, locator, result)

            nil ->
              results
          end
        end)

      assign(socket, :delegation_tasks, results)
    else
      _ -> socket
    end
  end

  defp load_activity_tasks(socket, _, _), do: assign(socket, :delegation_tasks, %{})

  defp delegation_in_selection?(socket, locator) do
    with %{type: "outcome", id: id} <- socket.assigns.activity_selection,
         {:ok, %{outcomes: outcomes}} <- socket.assigns.product_activity,
         %{} = item <- Enum.find(outcomes, &(&1.event_ref == id)) do
      Enum.any?(Enum.take(item.delegations, 2), &(delegation_locator(item, &1) == locator))
    else
      _ -> false
    end
  end

  defp delegation_locator(%{obligation_id: obligation_id}, %{index: index})
       when is_binary(obligation_id) and obligation_id != "" and index in 0..1,
       do: {obligation_id, index}

  defp delegation_locator(_item, _delegation), do: nil

  defp delegation_task_presentation(
         {:ok, %{"disposition" => "created", "conversation_id" => conversation_id}}
       )
       when is_binary(conversation_id) and conversation_id != "",
       do: {conversation_id, nil}

  defp delegation_task_presentation({:ok, %{"disposition" => "not_created"}}),
    do: {nil, gettext("No Task has been created yet.")}

  defp delegation_task_presentation({:ok, %{"disposition" => "reserved_task_unavailable"}}),
    do: {nil, gettext("The Task is currently unavailable.")}

  defp delegation_task_presentation(nil), do: {nil, nil}

  defp delegation_task_presentation(_unavailable),
    do: {nil, gettext("Task lookup is unavailable. Try again.")}

  defp product_delegation_label(%{task: task} = delegation) do
    case product_delegation_status(delegation) do
      "created" -> gettext("Worker task created: %{task}", task: task)
      "routed" -> gettext("Investigation routed: %{task}", task: task)
      "proposed" -> gettext("Worker task proposed: %{task}", task: task)
      "retry_scheduled" -> gettext("Worker task will retry: %{task}", task: task)
      "suppressed_stale" -> gettext("Stale worker task suppressed: %{task}", task: task)
      "unavailable" -> gettext("Worker task status unavailable: %{task}", task: task)
    end
  end

  defp product_delegation_status(%{status: status})
       when status in ~w(created routed proposed retry_scheduled suppressed_stale),
       do: status

  defp product_delegation_status(_delegation), do: "unavailable"

  defp product_outcome_duration(%{inserted_at_ms: first, updated_at_ms: last})
       when is_integer(first) and is_integer(last) and last >= first,
       do: format_duration_ms(last - first)

  defp product_outcome_duration(_item), do: nil

  defp product_outcome_duration_label(item) do
    case product_outcome_duration(item) do
      nil ->
        nil

      duration ->
        if product_outcome_terminal?(item) do
          gettext("Total %{duration}", duration: duration)
        else
          gettext("Elapsed %{duration}", duration: duration)
        end
    end
  end

  defp product_outcome_terminal?(%{state: state, companion_effect: %{state: companion_state}})
       when state in [:applied, :stale, :failed] and
              companion_state in [:applied, :stale, :failed],
       do: true

  defp product_outcome_terminal?(%{state: state} = item)
       when state in [:applied, :stale, :failed],
       do: is_nil(item[:companion_effect])

  defp product_outcome_terminal?(_item), do: false

  defp format_timeline_datetime(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%m-%d %H:%M")
  end

  defp format_timeline_datetime(_ms), do: "—"

  defp product_outcome_label(%{state: :failed}), do: gettext("Triage action failed")

  defp product_outcome_label(%{state: :stale}), do: gettext("Action suppressed")

  defp product_outcome_label(%{state: state}) when state in [:pending, :claimed],
    do: gettext("Settling decision")

  defp product_outcome_label(%{
         state: :applied,
         communication: %{kind: :reply},
         effect: %{status: status},
         companion_effect: %{state: companion_state}
       })
       when status in ["queued", "delivered"] and companion_state in [:pending, :claimed] do
    primary_label =
      case status do
        "queued" -> gettext("Reply queued")
        "delivered" -> gettext("Reply delivered")
      end

    primary_label <> " · " <> gettext("Reaction in progress")
  end

  defp product_outcome_label(%{
         state: :applied,
         communication: %{kind: :reply},
         effect: %{status: "delivered"},
         companion_effect: %{state: :failed}
       }),
       do: gettext("Reply delivered · reaction failed")

  defp product_outcome_label(%{
         state: :applied,
         communication: %{kind: :reply},
         effect: %{status: "queued"},
         companion_effect: %{state: :failed}
       }),
       do: gettext("Reply queued · reaction failed")

  defp product_outcome_label(%{
         effect: %{adapter: "audit_sink"},
         communication: %{kind: :reply},
         companion_reaction: %{kind: :reaction}
       }),
       do: gettext("Would reply and react")

  defp product_outcome_label(%{effect: %{adapter: "audit_sink"}, communication: %{kind: :reply}}),
    do: gettext("Would reply")

  defp product_outcome_label(%{
         effect: %{adapter: "audit_sink"},
         communication: %{kind: :reaction}
       }),
       do: gettext("Would react")

  defp product_outcome_label(%{
         communication: %{kind: :reply},
         companion_reaction: %{kind: :reaction}
       }),
       do: gettext("Reply and reaction")

  defp product_outcome_label(%{communication: %{kind: :reply}, effect: %{status: "queued"}}),
    do: gettext("Reply queued")

  defp product_outcome_label(%{communication: %{kind: :reply}, effect: %{status: "delivered"}}),
    do: gettext("Reply delivered")

  defp product_outcome_label(%{communication: %{kind: :reply}}), do: gettext("Reply")

  defp product_outcome_label(%{communication: %{kind: :reaction}, effect: %{status: "added"}}),
    do: gettext("Reaction added")

  defp product_outcome_label(%{communication: %{kind: :reaction}}), do: gettext("Reaction")

  defp product_outcome_label(%{communication: %{kind: :silence, reason: "worker_pending"}}),
    do: gettext("Assigned to Worker")

  defp product_outcome_label(%{communication: %{kind: :silence}}), do: gettext("Stayed silent")
  defp product_outcome_label(_item), do: gettext("Outcome unavailable")

  defp product_outcome_body(%{state: :stale, communication: %{text: text}})
       when is_binary(text),
       do: gettext("Suppressed draft after Slack changed: %{text}", text: text)

  defp product_outcome_body(%{communication: %{kind: :reply, text: text}})
       when is_binary(text),
       do: text

  defp product_outcome_body(%{communication: %{kind: :reaction, emoji: emoji}})
       when is_binary(emoji),
       do: ":#{emoji}:"

  defp product_outcome_body(%{communication: %{kind: :silence, explanation: explanation}})
       when is_binary(explanation) and explanation != "",
       do: explanation

  defp product_outcome_body(%{communication: %{kind: :silence, reason: "worker_pending"}}),
    do: gettext("Assigned to the Worker for investigation and a participation decision.")

  defp product_outcome_body(%{communication: %{kind: :silence, reason: reason}}),
    do:
      gettext("Silence category: %{reason}. No message-specific explanation was recorded.",
        reason: product_silence_reason(reason)
      )

  defp product_outcome_body(%{state: :failed}),
    do:
      gettext(
        "Comma could not complete this Triage action. No successful Slack action is being claimed."
      )

  defp product_outcome_body(_item), do: gettext("The product outcome is temporarily unavailable.")

  defp product_has_effect_details?(item) do
    product_companion_effect_label(item) != nil or product_context_effect_label(item) != nil or
      product_delegation_count(item, "created") > 0 or item.delegations != [] or
      local_rehearsal_outcome?(item)
  end

  defp product_companion_effect_label(%{
         companion_reaction: %{kind: :reaction, emoji: emoji},
         companion_effect: %{state: state}
       })
       when is_binary(emoji) do
    status =
      case state do
        :applied -> gettext("added")
        :stale -> gettext("suppressed")
        :failed -> gettext("failed")
        _state -> gettext("in progress")
      end

    gettext("Reaction :%{emoji}: · %{status}", emoji: emoji, status: status)
  end

  defp product_companion_effect_label(_item), do: nil

  defp product_silence_reason("no_actionable_request"), do: gettext("no actionable request")
  defp product_silence_reason("already_answered"), do: gettext("the thread was already answered")
  defp product_silence_reason("insufficient_evidence"), do: gettext("insufficient evidence")
  defp product_silence_reason("stale_or_changed"), do: gettext("the source changed")
  defp product_silence_reason("outside_authority"), do: gettext("outside the enabled scope")
  defp product_silence_reason("low_confidence"), do: gettext("confidence was too low")
  defp product_silence_reason("duplicate"), do: gettext("duplicate activity")
  defp product_silence_reason(_reason), do: gettext("reason unavailable")

  defp product_thread_started_at_ms(%{source: %{thread_ts: thread_ts}})
       when is_binary(thread_ts) and thread_ts != "" do
    slack_timestamp_ms(thread_ts)
  end

  defp product_thread_started_at_ms(_item), do: nil

  defp product_source_message_label(%{source: %{message_count: count}})
       when is_integer(count) and count >= 0,
       do:
         ngettext(
           "1 Slack message in this evaluation",
           "%{count} Slack messages in this evaluation",
           count
         )

  defp product_source_message_label(_item), do: gettext("Source message count unavailable")

  defp product_source_latest_activity_ms(%{source: %{latest_activity_at_ms: value}})
       when is_integer(value),
       do: value

  defp product_source_latest_activity_ms(_item), do: nil

  attr(:catalogue, :any, default: nil)

  defp source_file_catalogue(%{catalogue: %{"total_count" => count}} = assigns)
       when count > 0 do
    ~H"""
    <div data-section="source-files" class="mt-2 border-l-2 border-neutral-200 pl-2 text-xs text-neutral-600">
      <p class="font-medium">
        {ngettext("1 attached file", "%{count} attached files", @catalogue["total_count"])}
      </p>
      <ul class="mt-1 space-y-1">
        <li :for={file <- @catalogue["items"]} class="flex min-w-0 items-baseline gap-2">
          <span class="min-w-0 break-all">{if file["name"] == "", do: gettext("Unnamed file"), else: file["name"]}</span>
          <span class="shrink-0 text-[10px] uppercase tracking-wide text-neutral-400">{file["kind"]}</span>
        </li>
      </ul>
      <p class="mt-1 text-[11px] text-neutral-400">
        {if @catalogue["truncated"],
          do: gettext("File list or names shortened; file contents are not shown."),
          else: gettext("File names only; file contents are not shown.")}
      </p>
    </div>
    """
  end

  defp source_file_catalogue(assigns),
    do: ~H"""
    """

  # Group only this bounded page; missing identities remain independent.
  defp product_thread_groups(rows) do
    rows
    |> Enum.group_by(fn row ->
      source = row.item[:source] || %{}
      connect = source[:connect_id] || row.item[:connect_id]
      channel = source[:channel_id] || row.item[:source_channel]
      thread = source[:thread_ts] || row.item[:source_thread_ts]

      if Enum.all?([connect, channel, thread], &(is_binary(&1) and &1 != "")),
        do: {connect, channel, thread},
        else: {:unknown, row.id}
    end)
    |> Enum.map(fn {_key, entries} ->
      latest = Enum.max_by(entries, &{&1.at, &1.id})
      item = latest.item
      source = item[:source] || %{}

      %{
        rows: Enum.sort_by(entries, &{&1.at, &1.id}),
        at: latest.at,
        tone: timeline_row_tone(latest),
        channel_label: item.channel_label,
        started_at:
          product_thread_started_at_ms(item) || slack_timestamp_ms(item[:source_thread_ts]),
        url:
          source[:url] || item[:source_url] ||
            Enum.find_value(product_source_messages(item), & &1[:url])
      }
    end)
    |> Enum.sort_by(&{&1.at, hd(&1.rows).id}, :desc)
  end

  defp product_timeline(activity, outcomes, navigation, channel_names) do
    intake =
      case activity do
        {:ok, %{intake: {:ok, %{items: items}}}} -> items
        _ -> []
      end

    processing =
      if navigation.kind == "all" and navigation.cursors == [nil] do
        intake
        |> Enum.reject(&is_binary(&1[:outcome_ref]))
        |> Enum.map(fn item ->
          label = product_channel_label(item.connect_id, item[:source_channel], channel_names)

          %{
            id: "intake-" <> item.receipt_ref,
            kind: :processing,
            at: item.received_at_ms,
            item: Map.put(item, :channel_label, label)
          }
        end)
      else
        []
      end

    completed =
      Enum.map(outcomes, fn item ->
        sources =
          Enum.filter(
            intake,
            &(&1[:outcome_ref] == item.event_ref)
          )

        item =
          item |> original_timeline_sources(sources) |> put_product_channel_label(channel_names)

        %{
          id: item.event_ref,
          kind: :outcome,
          at: item.inserted_at_ms,
          item: item
        }
      end)

    Enum.sort_by(processing ++ completed, &{&1.at, &1.id}, :desc)
  end

  defp original_timeline_sources(item, []), do: item

  defp original_timeline_sources(item, sources) do
    original_messages = product_source_messages(item)

    original_messages =
      if original_messages == [],
        do:
          Enum.map(Enum.take(sources, 3), fn source ->
            %{
              excerpt: source.source_text,
              receipt_ref: source.receipt_ref,
              connect_id: source.connect_id,
              speaker_label: source[:source_actor_label],
              mentions: source[:mentions] || %{},
              actor_kind: :unknown,
              message_ts: source[:source_message_ts],
              occurred_at_ms: source[:source_at_ms],
              url: source[:source_url]
            }
          end),
        else: original_messages

    messages =
      Enum.map(original_messages, fn message ->
        case Enum.find(
               sources,
               &(is_binary(message[:message_ts]) and
                   &1[:source_message_ts] == message[:message_ts])
             ) do
          nil ->
            message

          source ->
            Map.merge(message, %{
              excerpt: source.source_text,
              receipt_ref: source.receipt_ref,
              connect_id: source.connect_id,
              speaker_label: source[:source_actor_label] || message[:speaker_label],
              mentions: source[:mentions] || %{}
            })
        end
      end)

    put_in(item, [:source, :messages], messages)
  end

  defp product_source_messages(%{source: %{messages: messages}}) when is_list(messages),
    do: messages

  defp product_source_messages(_item), do: []

  defp timeline_row_tone(%{kind: :outcome, item: item}), do: product_outcome_tone(item)
  defp timeline_row_tone(%{item: item}), do: processing_tone(item)

  # The node on the time axis carries the thread's latest state.
  defp timeline_node_class("green"), do: "bg-green-500"
  defp timeline_node_class("brand"), do: "bg-brand-500"
  defp timeline_node_class("amber"), do: "bg-amber-500"
  defp timeline_node_class(_neutral), do: "bg-neutral-300"

  defp format_month_day(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%m-%d")

  defp format_month_day(_ms), do: "—"

  defp product_actor_initial(label) when is_binary(label) do
    label |> String.trim_leading("@") |> String.first() |> Kernel.||("?") |> String.upcase()
  end

  # The decision card's edge carries the outcome state, so a failure or an
  # in-flight effect stands out while scanning a long feed.
  defp product_outcome_border(item) do
    case product_outcome_tone(item) do
      "amber" -> "border-amber-300"
      "brand" -> "border-brand-200"
      _other -> "border-neutral-200"
    end
  end

  # A reply is the product output, so it reads as body text. Silence and
  # other explanations stay secondary.
  defp product_outcome_body_class(%{communication: %{kind: :reply}}),
    do: "text-sm text-neutral-900"

  defp product_outcome_body_class(_item), do: "text-[13px] text-neutral-600"

  defp product_source_actor_label(%{speaker_label: label})
       when is_binary(label) and label != "" do
    if Regex.match?(~r/^@?[UW][A-Z0-9]{2,31}$/, label) do
      gettext("Slack participant")
    else
      if String.starts_with?(label, "@"), do: label, else: "@" <> label
    end
  end

  defp product_source_actor_label(%{actor_kind: :human}), do: gettext("Slack participant")
  defp product_source_actor_label(%{actor_kind: :agent}), do: gettext("Slack app")
  defp product_source_actor_label(%{actor_kind: :system}), do: gettext("Slack")
  defp product_source_actor_label(_message), do: gettext("Unknown sender")

  defp product_source_excerpt(%{receipt_ref: ref} = message, revealed) do
    if MapSet.member?(revealed, ref),
      do: product_source_excerpt(message),
      else: gettext("Source access could not be recorded. Refresh to retry.")
  end

  defp product_source_excerpt(message, _revealed), do: product_source_excerpt(message)

  defp product_source_excerpt(%{excerpt: excerpt}) when is_binary(excerpt) and excerpt != "",
    do: excerpt

  defp product_source_excerpt(_message), do: gettext("No text preview available")

  defp product_evidence_count(%{evidence: evidence}, key) when is_map(evidence) do
    case evidence[key] do
      count when is_integer(count) and count >= 0 -> count
      _invalid -> 0
    end
  end

  defp product_evidence_count(_item, _key), do: 0

  defp product_evidence_total_label(item) do
    count = product_evidence_count(item, :total_sources)
    ngettext("1 verified source record", "%{count} verified source records", count)
  end

  defp product_evidence_label(item, key) do
    count = product_evidence_count(item, key)
    ngettext("1 cited source", "%{count} cited sources", count)
  end

  defp product_context_evidence_label(%{confidence: confidence} = context) do
    source_count = if is_integer(context[:source_count]), do: context.source_count, else: 0

    gettext("%{confidence} · %{sources}",
      confidence: product_context_confidence_label(confidence),
      sources: ngettext("1 cited source", "%{count} cited sources", source_count)
    )
  end

  defp product_context_evidence_label(_context),
    do: gettext("Evidence unavailable")

  defp product_context_confidence_label("explicit"), do: gettext("explicit evidence")
  defp product_context_confidence_label("inferred"), do: gettext("inferred evidence")
  defp product_context_confidence_label(_confidence), do: gettext("confidence unavailable")

  defp slack_timestamp_ms(timestamp) when is_binary(timestamp) do
    case String.split(timestamp, ".", parts: 2) do
      [seconds] ->
        parse_slack_timestamp_ms(seconds, "0")

      [seconds, fraction] ->
        parse_slack_timestamp_ms(seconds, fraction)
    end
  end

  defp slack_timestamp_ms(_timestamp), do: nil

  defp parse_slack_timestamp_ms(seconds, fraction) do
    millis = fraction |> String.slice(0, 3) |> String.pad_trailing(3, "0")

    with {seconds, ""} <- Integer.parse(seconds),
         {millis, ""} <- Integer.parse(millis) do
      seconds * 1_000 + millis
    else
      _invalid -> nil
    end
  end

  defp product_context_effect_label(%{context: %{candidates: count} = counts}) when count > 0 do
    gettext("Context: %{active} retained · %{proposed} proposed",
      active: count_value(counts, :active),
      proposed: count_value(counts, :proposed)
    )
  end

  defp product_context_effect_label(_item), do: nil

  defp count_value(%{} = counts, key), do: counts[key] || 0

  defp local_rehearsal_outcome?(%{
         effect: %{adapter: "audit_sink", external_writes: 0}
       }),
       do: true

  defp local_rehearsal_outcome?(_item), do: false

  defp product_context_tone(%{state: :proposed}), do: "amber"
  defp product_context_tone(%{kind: "follow_up"}), do: "brand"
  defp product_context_tone(_entry), do: "green"

  defp product_context_kind_label(%{kind: "project_fact"}), do: gettext("Project fact")
  defp product_context_kind_label(%{kind: "decision"}), do: gettext("Decision")
  defp product_context_kind_label(%{kind: "follow_up"}), do: gettext("Follow-up")
  defp product_context_kind_label(_entry), do: gettext("Context")

  defp product_context_state_label(%{state: :active}), do: gettext("retained")
  defp product_context_state_label(%{state: :proposed}), do: gettext("needs review")

  defp product_context_state_label(%{state: :resolved, resolved_reason: "reminder_delivered"}),
    do: gettext("reminder delivered")

  defp product_context_state_label(%{state: :resolved}), do: gettext("resolved")
  defp product_context_state_label(%{state: :stopped}), do: gettext("stopped")
  defp product_context_state_label(%{state: :superseded}), do: gettext("superseded")
  defp product_context_state_label(_entry), do: gettext("state unavailable")

  defp assertion_in_knowledge({:ok, %{assertions: assertions}}, assertion_id)
       when is_list(assertions),
       do: Enum.find(assertions, &(&1.id == assertion_id))

  defp assertion_in_knowledge(_knowledge, _assertion_id), do: nil

  defp agent_in_projection?({:ok, agents}, agent_id) when is_list(agents),
    do: Enum.any?(agents, &(&1.agent_id == agent_id))

  defp agent_in_projection?(_projection, _agent_id), do: false

  defp group_knowledge_by_day(assertions) do
    assertions
    |> Enum.group_by(&day_label(&1.observed_at))
    |> Enum.sort_by(fn {day, _assertions} -> day end, :desc)
  end

  defp recent_processing_items({:ok, %{items: items}}, agent, source_posture)
       when is_list(items) do
    sources =
      agent
      |> agent_source_view(source_posture)
      |> Map.fetch!(:sources)

    connect_ids = MapSet.new(sources, &to_string(&1.connect_id))

    channel_names =
      for source <- sources,
          channel <- source[:configured_channels] || [],
          into: %{} do
        {{to_string(source.connect_id), to_string(channel.channel_id)}, channel.channel_name}
      end

    items
    |> Enum.filter(&MapSet.member?(connect_ids, to_string(&1[:connect_id])))
    |> Enum.take(12)
    |> Enum.map(&put_processing_channel_label(&1, channel_names))
  end

  defp recent_processing_items(_processing, _agent, _source_posture), do: []

  defp recent_processing_scope_incomplete?({:ok, processing}),
    do: processing[:scope_complete] == false

  defp recent_processing_scope_incomplete?(_processing), do: false

  defp recent_processing_truncated?({:ok, processing}), do: processing[:truncated] == true
  defp recent_processing_truncated?(_processing), do: false

  defp recent_processing_records_incomplete?({:ok, processing}) do
    positive_count?(processing[:unavailable_count]) or
      positive_count?(processing[:unattributed_count])
  end

  defp recent_processing_records_incomplete?(_processing), do: false

  defp positive_count?(count), do: is_integer(count) and count > 0

  defp put_processing_channel_label(item, channel_names) do
    channel_id = get_in(item, [:diagnostics, :source, :channel_id])
    channel_name = Map.get(channel_names, {to_string(item[:connect_id]), to_string(channel_id)})

    label =
      cond do
        is_binary(channel_name) and channel_name != "" ->
          "#" <> channel_name

        is_binary(channel_id) and channel_id != "" ->
          gettext("Slack channel %{channel}", channel: channel_id)

        true ->
          gettext("Slack channel unavailable")
      end

    Map.put(item, :channel_label, label)
  end

  defp processing_dom_id(item) do
    ref = to_string(item[:receipt_ref] || "unknown")
    digest = :sha256 |> :crypto.hash(ref) |> Base.url_encode64(padding: false)
    "triage-processing-" <> binary_part(digest, 0, 12)
  end

  defp processing_owner_label(%{owner: %{project_name: name}}) when is_binary(name), do: name
  defp processing_owner_label(_item), do: gettext("Project")

  defp processing_receipt_count_label(%{receipt_count: count})
       when is_integer(count) and count > 0,
       do: ngettext("1 message", "%{count} messages", count)

  defp processing_receipt_count_label(_item), do: ngettext("1 message", "%{count} messages", 1)

  defp processing_tone(%{state: :terminal, terminal_status: "evaluated"}), do: "green"

  defp processing_tone(%{state: state, terminal_status: status})
       when state in [:terminal, :settled] and status in ["failed", "skipped_timeout"],
       do: "amber"

  defp processing_tone(%{state: :evaluating}), do: "brand"
  defp processing_tone(%{state: :finalizing}), do: "brand"
  defp processing_tone(%{state: :sealed}), do: "brand"
  defp processing_tone(%{state: :unavailable}), do: "amber"
  defp processing_tone(_item), do: "neutral"

  defp processing_label(%{state: :settled, terminal_status: "evaluated"}),
    do: gettext("Evaluation finished")

  defp processing_label(%{state: :settled} = item),
    do: processing_label(%{item | state: :terminal})

  defp processing_label(%{state: :received}), do: gettext("Received")
  defp processing_label(%{state: :queued}), do: gettext("Waiting to batch")
  defp processing_label(%{state: :sealed}), do: gettext("Ready for evaluation")
  defp processing_label(%{state: :evaluating}), do: gettext("Evaluating")
  defp processing_label(%{state: :finalizing}), do: gettext("Finalizing review evidence")

  defp processing_label(%{state: :terminal, terminal_status: "evaluated"}),
    do: gettext("Review suggestion ready")

  defp processing_label(%{state: :terminal, terminal_status: "failed"}),
    do: gettext("Evaluation failed")

  defp processing_label(%{state: :terminal, terminal_status: "skipped_timeout"}),
    do: gettext("Skipped after timeout")

  defp processing_label(%{state: :terminal, terminal_status: "skipped_already_answered"}),
    do: gettext("Skipped — already answered")

  defp processing_label(%{state: :terminal}), do: gettext("Processing finished")
  defp processing_label(%{state: :unavailable}), do: gettext("Status unavailable")
  defp processing_label(_item), do: gettext("Status unavailable")

  defp processing_description(%{state: :settled}),
    do: gettext("Evaluation ended. Open batch details to inspect its evidence.")

  defp processing_description(%{state: :received}),
    do:
      gettext(
        "Comma recorded the Slack message; its next durable processing step has not appeared yet."
      )

  defp processing_description(%{state: :queued}),
    do: gettext("Comma is waiting briefly for related messages before starting evaluation.")

  defp processing_description(%{state: :sealed}),
    do: gettext("The message batch is sealed and waiting for the evaluator.")

  defp processing_description(%{state: :evaluating}),
    do: gettext("AI evaluation is in progress. Nothing is being posted to Slack.")

  defp processing_description(%{state: :finalizing}),
    do:
      gettext(
        "AI evaluation finished, but Comma has not yet verified the public review record. No suggestion is shown until that evidence agrees."
      )

  defp processing_description(%{
         state: :terminal,
         terminal_status: "evaluated",
         suggested_action: action
       })
       when is_binary(action) do
    gettext(
      "Review suggestion: %{action}. It has not been executed or posted to Slack.",
      action: suggested_action_label(action)
    )
  end

  defp processing_description(%{state: :terminal, terminal_status: "evaluated"}),
    do: gettext("A review suggestion is ready. It has not been executed or posted to Slack.")

  defp processing_description(%{state: :terminal, terminal_status: "failed"}),
    do: gettext("Evaluation ended without a review suggestion. Slack was not changed.")

  defp processing_description(%{state: :terminal, terminal_status: "skipped_timeout"}),
    do: gettext("Evaluation timed out without a review suggestion. Slack was not changed.")

  defp processing_description(%{
         state: :terminal,
         terminal_status: "skipped_already_answered"
       }),
       do: gettext("The thread already had an answer, so no new suggestion was produced.")

  defp processing_description(%{state: :terminal}),
    do: gettext("Processing reached a terminal state. Slack was not changed by Triage.")

  defp processing_description(%{state: :unavailable}),
    do: gettext("Comma cannot verify the next durable processing step right now.")

  defp processing_description(_item),
    do: gettext("Comma cannot verify the next durable processing step right now.")

  defp processing_addressing_label("ambient"), do: gettext("Ambient message")
  defp processing_addressing_label("direct"), do: gettext("Direct message")
  defp processing_addressing_label("mention"), do: gettext("Mentioned message")
  defp processing_addressing_label("directed"), do: gettext("Mentioned message")
  defp processing_addressing_label(_kind), do: gettext("Message routing unavailable")

  defp processing_thread_label(thread_ts) when is_binary(thread_ts) and thread_ts != "",
    do: gettext("Thread %{thread}", thread: thread_ts)

  defp processing_thread_label(_thread_ts), do: nil

  defp processing_trigger_label("mention"), do: gettext("Trigger: mention")
  defp processing_trigger_label("question_heuristic"), do: gettext("Trigger: question heuristic")
  defp processing_trigger_label(_kind), do: nil

  defp processing_source_mode_label("callback"), do: gettext("Slack callback")
  defp processing_source_mode_label("clickhouse_etl"), do: gettext("Slack history ingestion")
  defp processing_source_mode_label("fast_path"), do: gettext("Fast path")
  defp processing_source_mode_label(_mode), do: gettext("Source mode unavailable")

  defp processing_decision_reason(%{decision_reason: "evidence_invalid"}),
    do: gettext("Evidence invalid")

  defp processing_decision_reason(%{decision_reason: "evaluation_unavailable"}),
    do: gettext("Evaluation unavailable")

  defp processing_decision_reason(%{decision_reason: "source_read_unavailable"}),
    do: gettext("Slack source read unavailable")

  defp processing_decision_reason(_diagnostics), do: nil

  defp processing_milestones(milestones) when is_map(milestones) do
    [
      {gettext("Received"), milestones[:received_at_ms]},
      {gettext("Waiting to batch"), milestones[:queued_at_ms]},
      {gettext("Batch sealed"), milestones[:sealed_at_ms]},
      {gettext("Evaluation started"), milestones[:evaluation_started_at_ms]},
      {gettext("Settled"), milestones[:settled_at_ms]}
    ]
    |> Enum.filter(fn {_label, at_ms} -> is_integer(at_ms) end)
  end

  defp processing_milestones(_milestones), do: []

  defp processing_duration(%{received_at_ms: first, settled_at_ms: last})
       when is_integer(first) and is_integer(last) and last >= first,
       do: format_duration_ms(last - first)

  defp processing_duration(_milestones), do: nil

  defp format_duration_ms(ms) when ms < 1_000, do: gettext("%{count} ms", count: ms)

  defp format_duration_ms(ms) do
    seconds = ms / 1_000

    if rem(ms, 1_000) == 0,
      do: gettext("%{count} s", count: trunc(seconds)),
      else: gettext("%{count} s", count: :erlang.float_to_binary(seconds, decimals: 1))
  end

  defp format_time_with_seconds(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time_with_seconds(_ms), do: "—"

  defp processing_evaluator_request_label(%{request_count: count, tool_names: tools})
       when is_integer(count) and is_list(tools) do
    request_label = ngettext("1 model request", "%{count} model requests", count)

    case tools do
      [] ->
        request_label

      names ->
        gettext("%{requests} · tools: %{tools}",
          requests: request_label,
          tools: Enum.join(names, ", ")
        )
    end
  end

  defp processing_evaluator_request_label(_evaluator), do: gettext("Request evidence unavailable")

  defp processing_evaluator_retry_label(%{retry: true}), do: gettext("Retry: yes")
  defp processing_evaluator_retry_label(%{retry: false}), do: gettext("Retry: no")
  defp processing_evaluator_retry_label(_evaluator), do: gettext("Retry evidence unavailable")

  defp processing_blocker_label(%{state: :unavailable}), do: gettext("Evidence unavailable")

  defp processing_blocker_label(%{state: :terminal, terminal_status: "failed"}),
    do: gettext("Evaluation failed")

  defp processing_blocker_label(%{state: :terminal, terminal_status: "skipped_timeout"}),
    do: gettext("Evaluation timeout")

  defp processing_blocker_label(%{state: :received}),
    do: gettext("No processing step recorded after receipt")

  defp processing_blocker_label(%{state: :terminal}), do: gettext("Processing finished")
  defp processing_blocker_label(_item), do: gettext("Processing has not finished")

  defp processing_blocker_class(%{state: :unavailable}), do: "font-medium text-amber-700"

  defp processing_blocker_class(%{state: :terminal, terminal_status: status})
       when status in ["failed", "skipped_timeout"],
       do: "font-medium text-amber-700"

  defp processing_blocker_class(_item), do: "text-neutral-600"

  defp suggested_action_label("silence"), do: gettext("stay silent")
  defp suggested_action_label("reply"), do: gettext("draft a reply")
  defp suggested_action_label("react"), do: gettext("suggest a reaction")
  defp suggested_action_label("delegate"), do: gettext("suggest a delegated task")
  defp suggested_action_label("remember"), do: gettext("suggest project context")
  defp suggested_action_label(_action), do: gettext("review the message")

  defp receipt_for_assertion({:ok, %{receipts: receipts}}, assertion) when is_list(receipts),
    do: Enum.find(receipts, &(&1["receipt_ref"] == assertion.source.ref))

  defp receipt_for_assertion(_window, _assertion), do: nil

  defp usage_unavailable?({:ok, %{usage_status: {:unavailable, _reason}}}), do: true
  defp usage_unavailable?(_knowledge), do: false

  defp retained_context_unavailable?({:ok, %{retained_context_status: {:unavailable, _reason}}}),
    do: true

  defp retained_context_unavailable?(_knowledge), do: false

  defp knowledge_projection_incomplete?(
         {:ok,
          %{
            assertions_complete: assertions_complete?,
            entities_complete: entities_complete?,
            members_complete: members_complete?,
            retained_context_status: retained_context_status,
            retained_context_complete: retained_context_complete?
          }}
       ) do
    not assertions_complete? or not entities_complete? or not members_complete? or
      (retained_context_status == :available and not retained_context_complete?)
  end

  defp knowledge_projection_incomplete?(_knowledge), do: false

  defp usage_status_unavailable?({:unavailable, _reason}), do: true
  defp usage_status_unavailable?(_status), do: false

  defp usage_identity(use) do
    {use["session_id"], use["retrieval_id"], use["assistant_message_id"]}
  end

  defp source_description(%{type: "slack_receipt"}),
    do:
      gettext(
        "This assertion points to a received Slack message. Reveal is audited before its text is shown."
      )

  defp source_description(%{type: type}),
    do: gettext("This assertion was recorded from a %{type} source.", type: type)

  defp subject_names(subjects),
    do: subjects |> Enum.map(& &1.name) |> Enum.join(" · ")

  # Router is an execution role and the provisioned Agent's historical default
  # database name, not a product identity. Preserve names users assigned, but
  # fall back to the owning project when the only name is that internal role.
  defp agent_label(%{agent_name: name, project_name: project})
       when is_binary(name) and name != "" and is_binary(project) and project != "" do
    if internal_agent_name?(name), do: project, else: name
  end

  defp agent_label(%{agent_name: name}) when is_binary(name) and name != "", do: name
  defp agent_label(%{project_name: name}), do: name

  defp agent_project_badge?(%{project_name: project} = agent),
    do: is_binary(project) and project != "" and agent_label(agent) != project

  defp internal_agent_name?(name), do: name |> String.trim() |> String.downcase() == "router"

  defp agent_initials(agent) do
    initials =
      agent
      |> agent_label()
      |> to_string()
      |> String.trim()
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.take(2)
      |> Enum.map_join(&(&1 |> String.graphemes() |> List.first()))

    if initials == "", do: "A", else: String.upcase(initials)
  end

  defp agent_option_groups(options) do
    for {key, label, states} <- [
          {:connected, gettext("Slack connected"), [:ready]},
          {:unconnected, gettext("Slack not connected"), [:empty]},
          {:unavailable, gettext("Connection status incomplete"), [:partial, :unavailable]}
        ] do
      members = Enum.filter(options, &(&1.source_view.state in states))

      %{key: key, label: label, total: length(members), options: members}
    end
  end

  defp agent_source_view(agent, {:ok, posture}) when is_map(posture) do
    sources =
      posture
      |> Map.get(:connects, [])
      |> Enum.filter(&same_ref?(&1[:inbound_agent_id], agent[:salix_agent_id]))
      |> Enum.sort_by(fn source ->
        {slack_bot_name(source), source_name(source[:workspace_name]),
         to_string(source[:connect_id])}
      end)

    incomplete? =
      posture
      |> Map.get(:unavailable_groups, [])
      |> Enum.any?(fn group ->
        same_ref?(group[:project_id], agent[:project_id]) or
          same_ref?(group[:group_id], agent[:group_id])
      end)

    state =
      cond do
        incomplete? and sources == [] -> :unavailable
        incomplete? -> :partial
        sources == [] -> :empty
        true -> :ready
      end

    %{sources: sources, state: state}
  end

  defp agent_source_view(_agent, _posture), do: %{sources: [], state: :unavailable}

  defp prioritize_source(%{sources: sources} = view, %{connect_id: connect_id}) do
    {selected, rest} = Enum.split_with(sources, &same_ref?(&1[:connect_id], connect_id))
    %{view | sources: selected ++ rest}
  end

  defp prioritize_source(view, _selected_connect), do: view

  defp agent_source_summary(%{state: :unavailable}),
    do: gettext("Slack connection status unavailable")

  defp agent_source_summary(%{state: :empty}), do: gettext("Slack not connected")

  defp agent_source_summary(%{state: state, sources: [source]})
       when state in [:ready, :partial] do
    label = slack_source_label(source)

    if state == :partial,
      do: gettext("%{source} · status incomplete", source: label),
      else: label
  end

  defp agent_source_summary(%{state: state, sources: [source | rest]})
       when state in [:ready, :partial] do
    label =
      gettext("%{source} · %{count} more",
        source: slack_source_label(source),
        count: length(rest)
      )

    if state == :partial,
      do: gettext("%{source} · status incomplete", source: label),
      else: label
  end

  defp slack_source_label(source) do
    gettext("Slack Bot · %{bot} · %{workspace}",
      bot: slack_bot_name(source, gettext("Bot name unavailable")),
      workspace: source_name(source[:workspace_name], gettext("Workspace unavailable"))
    )
  end

  defp slack_bot_name(source, fallback \\ "") do
    source_name(source[:app_name], source_name(source[:bot_username], fallback))
  end

  defp slack_source_meta(source) do
    workspace = source_name(source[:workspace_name], gettext("Workspace unavailable"))
    app_name = source_name(source[:app_name])
    username = source_name(source[:bot_username])

    if app_name != "" and username != "" and app_name != username,
      do: "@#{username} · #{workspace}",
      else: workspace
  end

  defp source_name(value, fallback \\ "")
  defp source_name(value, _fallback) when is_binary(value) and value != "", do: value
  defp source_name(_value, fallback), do: fallback

  defp same_ref?(left, right) when not is_nil(left) and not is_nil(right),
    do: to_string(left) == to_string(right)

  defp same_ref?(_left, _right), do: false

  defp channel_upgrade_notice(%{authority_valid?: false, triage_enabled: true}) do
    gettext(
      "This Slack source needs attention. You can still turn Triage off safely; channel settings stay unavailable until the source is ready."
    )
  end

  defp channel_upgrade_notice(%{authority_valid?: false}) do
    gettext(
      "Triage cannot be turned on until this Slack source is ready and has at least one configured channel."
    )
  end

  defp channel_upgrade_notice(%{triage_enabled: false, configured_channels: []}) do
    gettext(
      "Channel setup is unavailable until the Slack channel upgrade finishes, so Triage cannot be turned on yet."
    )
  end

  defp channel_upgrade_notice(_connect) do
    gettext(
      "Per-channel controls will become available after the Slack channel upgrade finishes. The main Triage switch remains available."
    )
  end

  defp posture_unavailable_notice(%{triage_enabled: true}) do
    gettext(
      "Setup and channel controls are unavailable, but you can still turn Triage off safely."
    )
  end

  defp posture_unavailable_notice(_connect) do
    gettext("Setup and channel controls are unavailable until this Slack source is ready.")
  end

  defp knowledge_kind_label(:decision), do: gettext("Decision")
  defp knowledge_kind_label(_kind), do: gettext("Fact")

  defp entity_kind_label(:person), do: gettext("Person")
  defp entity_kind_label(:project), do: gettext("Project")
  defp entity_kind_label(:decision), do: gettext("Decision")
  defp entity_kind_label(:context), do: gettext("Context")

  defp entity_kind_glyph(:person), do: gettext("P")
  defp entity_kind_glyph(:project), do: gettext("Pr")
  defp entity_kind_glyph(:decision), do: gettext("D")
  defp entity_kind_glyph(:context), do: gettext("C")

  defp knowledge_ownership_copy do
    gettext("This knowledge belongs to the project and keeps its sources with each item.")
  end

  defp knowledge_filter_options do
    [
      {"all", gettext("All")},
      {"person", gettext("People")},
      {"project", gettext("Projects")},
      {"decision", gettext("Decisions")},
      {"context", gettext("Context")}
    ]
  end

  defp knowledge_kind(value) when value in ~w(person project decision context), do: value
  defp knowledge_kind(_value), do: "all"

  defp knowledge_rows(result, filters) do
    query = filters |> Map.get("q", "") |> String.trim() |> String.downcase()
    kind = knowledge_kind(filters["kind"])

    result
    |> all_knowledge_rows()
    |> Enum.filter(&(kind == "all" or to_string(&1.kind) == kind))
    |> Enum.filter(fn row ->
      query == "" or
        String.contains?(
          String.downcase(
            row.name <> " " <> row.summary <> " " <> assertion_text(row.assertions)
          ),
          query
        )
    end)
  end

  defp all_knowledge_rows(result) do
    member_rows =
      result
      |> Map.get(:members, [])
      |> Map.new(fn member ->
        {{:person, member.id},
         %{
           id: "person-#{member.id}",
           kind: :person,
           name: member.name,
           summary: gettext("Project member"),
           member: member,
           assertions: [],
           uses: []
         }}
      end)

    assertion_entity_rows =
      result.assertions
      |> Enum.flat_map(fn assertion ->
        Enum.map(assertion.subjects, &{&1, assertion})
      end)
      |> Enum.group_by(fn {subject, _assertion} -> {subject.kind, subject.id} end)
      |> Map.new(fn {{kind, id} = key, entries} ->
        subject = entries |> hd() |> elem(0)
        assertions = entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)

        {key,
         %{
           id: "#{kind}-#{id}",
           kind: kind,
           name: subject.name,
           summary:
             ngettext("1 sourced assertion", "%{count} sourced assertions", length(assertions)),
           member: nil,
           assertions: assertions,
           uses: assertions |> Enum.flat_map(& &1.uses) |> Enum.uniq_by(&usage_identity/1)
         }}
      end)

    entity_rows =
      member_rows
      |> Map.merge(assertion_entity_rows, fn _key, member_row, assertion_row ->
        %{assertion_row | name: member_row.name, member: member_row.member}
      end)
      |> Map.values()

    decisions =
      result.assertions
      |> Enum.filter(&(&1.kind == :decision))
      |> Enum.map(fn assertion ->
        %{
          id: "decision-#{assertion.id}",
          kind: :decision,
          name: assertion.content,
          summary: subject_names(assertion.subjects),
          member: nil,
          assertions: [assertion],
          uses: assertion.uses
        }
      end)

    Enum.sort_by(entity_rows ++ decisions, &{entity_kind_rank(&1.kind), &1.name})
  end

  defp entity_kind_rank(:person), do: 0
  defp entity_kind_rank(:project), do: 1
  defp entity_kind_rank(:decision), do: 2
  defp entity_kind_rank(:context), do: 3

  defp assertion_text(assertions), do: Enum.map_join(assertions, " ", & &1.content)

  defp knowledge_count(result, :person) do
    member_ids = result |> Map.get(:members, []) |> Enum.map(& &1.id)

    assertion_ids =
      result.assertions
      |> Enum.flat_map(& &1.subjects)
      |> Enum.filter(&(&1.kind == :person))
      |> Enum.map(& &1.id)

    (member_ids ++ assertion_ids) |> Enum.uniq() |> length()
  end

  defp knowledge_count(result, :project) do
    result.assertions
    |> Enum.flat_map(& &1.subjects)
    |> Enum.filter(&(&1.kind == :project))
    |> Enum.uniq_by(& &1.id)
    |> length()
  end

  defp knowledge_count(result, :decision) do
    Enum.count(result.assertions, &(&1.kind == :decision)) +
      Enum.count(result.retained_context, &(&1.kind == :decision))
  end

  defp knowledge_count(result, :context),
    do: Enum.count(result.retained_context, &(&1.kind == :context))

  defp imported_knowledge_rows({:ok, %{items: items}}, filters) when is_list(items) do
    query = filters |> Map.get("q", "") |> String.trim() |> String.downcase()
    kind = knowledge_kind(filters["kind"])

    items
    |> Enum.map(&imported_knowledge_row/1)
    |> Enum.filter(&(kind == "all" or to_string(&1.kind) == kind))
    |> Enum.filter(fn row ->
      query == "" or
        String.contains?(
          String.downcase(row.name <> " " <> Enum.join(row.aliases, " ")),
          query
        )
    end)
  end

  defp imported_knowledge_rows(_result, _filters), do: []

  defp imported_knowledge_row(item) do
    source_refs =
      Enum.filter(item.source_refs, &(&1.type == "sourced_context_object"))

    aliases = Map.get(item, :aliases, [])

    %{
      id: item.id,
      kind: item.kind,
      name: Map.get(item, :name) || Map.fetch!(item, :content),
      aliases: aliases,
      source_refs: source_refs,
      summary:
        ngettext(
          "%{count} Slack reference",
          "%{count} Slack references",
          length(source_refs),
          count: length(source_refs)
        )
    }
  end

  defp retained_context_rows({:ok, %{retained_context: context}}, filters)
       when is_list(context) do
    query = filters |> Map.get("q", "") |> String.trim() |> String.downcase()
    kind = knowledge_kind(filters["kind"])

    context
    |> Enum.filter(&(kind == "all" or to_string(&1.kind) == kind))
    |> Enum.filter(fn row ->
      query == "" or
        String.contains?(String.downcase(row.name <> " " <> row.content), query)
    end)
  end

  defp retained_context_rows(_knowledge, _filters), do: []

  defp knowledge_total_count(knowledge, sourced_context, kind) do
    project_count = if ok?(knowledge), do: knowledge_count(unwrap(knowledge), kind), else: 0

    imported_count =
      case sourced_context do
        {:ok, %{items: items}} when is_list(items) -> Enum.count(items, &(&1.kind == kind))
        _other -> 0
      end

    project_count + imported_count
  end

  defp day_label(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d")
  end

  defp day_label(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d")

  defp day_label(_ms), do: gettext("Unknown date")

  defp format_datetime(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp format_datetime(%DateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  defp format_datetime(_ms), do: "—"

  defp format_time(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M")
  end

  defp format_time(%DateTime{} = value), do: Calendar.strftime(value, "%H:%M")

  defp format_time(_ms), do: "—"

  defp format_unix_seconds(seconds) when is_integer(seconds),
    do: seconds |> DateTime.from_unix!(:second) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

  defp format_unix_seconds(_seconds), do: "—"

  defp owner_label(owners, connect_id) do
    case Map.get(owners, connect_id) do
      %{project_name: name} -> name
      _missing -> "—"
    end
  end

  # Read defensively: `unavailable_count` is newer than the erpc seam it
  # crosses, and a mixed-version deploy can answer with a page shape that
  # predates it. Absent means "nothing reported", which is 0.
  defp unavailable_count(page), do: Map.get(page, :unavailable_count, 0)

  defp window_empty_description(window, window_days) do
    if window.truncated or not Map.get(window, :scope_complete, true) or
         unavailable_count(window) > 0 do
      gettext(
        "No rows in the scanned window. The scan did not complete, so this is not evidence that nothing was received in the last %{count} days.",
        count: window_days
      )
    else
      gettext(
        "The scan completed and found no typed receipts for this organization in the last %{count} days.",
        count: window_days
      )
    end
  end

  defp receipt_in_window({:ok, %{receipts: receipts}}, ref) when is_list(receipts) do
    Enum.find(receipts, &(&1["receipt_ref"] == ref))
  end

  defp receipt_in_window(_window, _ref), do: nil

  defp blank_dash(nil), do: "—"
  defp blank_dash(""), do: "—"
  defp blank_dash(value) when is_binary(value), do: value
  defp blank_dash(value), do: to_string(value)

  defp reason_text(reason) when is_atom(reason), do: to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp tab_label(:timeline), do: gettext("Timeline")
  defp tab_label(:knowledge), do: gettext("Knowledge")
  defp tab_label(:memory), do: gettext("Knowledge")
  defp tab_label(:data), do: gettext("Raw data")
  defp tab_label(:context), do: gettext("Initialize project context")
  defp tab_label(_tab), do: gettext("Overview")

  defp can_view_triage?(role), do: role in ["owner", "admin"]
  defp can_manage_triage?(role), do: role in ["owner", "admin"]
end
