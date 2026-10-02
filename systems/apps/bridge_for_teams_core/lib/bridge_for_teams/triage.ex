defmodule BridgeForTeams.Triage do
  @moduledoc """
  Org-scoped product boundary over the Salix native Slack Triage state — the
  BFT Triage Workbench's data side (design:
  `docs/bridge-for-teams/design.md` §4a).

  `SalixIM.Triage.ReadModel` owns record semantics; this module owns the two
  things Salix cannot know: **which org a row belongs to**, and **who is
  allowed to flip a switch**. Everything else is passed through byte-identically
  so the seam has exactly one authority per fact.

  ## Org scoping is a BFT-side join

  Receipts carry a `connect_id` and no tenant or group. The org's
  projects each map 1:1 to a Salix group, so the scope is built by fanning
  `connect_posture/2` out over the org's groups and inverting the result into a
  `connect_id => %{group_id, project_id, project_name}` map. Rows whose
  `connect_id` is not in that map are **dropped before render** and counted as
  `foreign_count` — defense in depth on top of the org-scoped route, and an
  honest number rather than a silent filter.

  When a group's posture read fails, that group contributes no connects, so its
  rows would be indistinguishable from another org's. Results therefore carry
  `scope_complete: false` and the failing groups in `unavailable_groups`: the
  UI must render "this view may be missing projects", never a quietly short
  list.

  The drop count splits along the same line. While the scope is complete a drop
  is confirmed foreign and lands in `foreign_count`; while it is incomplete the
  join could not decide, and the drop lands in `unattributed_count` instead. A
  row is never counted in both, and the UI must not label an unattributed row
  as another org's.

  ## Row shapes are not rewritten

  Receipt rows are string-keyed maps from Salix. Rather than duplicate a project
  name onto every row, scoped results carry the join separately as `owners` — the same
  `connect_id => %{group_id, project_id, project_name}` map, restricted to the
  connects actually present. `SalixIM.Triage.ReadModel` stays the single
  authority for what a row looks like.

  ## Namespace

  The runtime and Workbench both use `SalixStore.TriageKeys.default_namespace/0`.
  It is product-owned code, not a deployment or UI switch, so reads and writes
  cannot drift into different partitions. Source and channel authority remain
  the only normal product gate.

  ## The scope build is hard-bounded

  The join above fans a `triage_connect_posture/2` RPC out over the org's
  groups, which is the one part of this module whose cost grows with the org.
  Three bounds keep it off the render path's critical path:

    * **One build per render, not one per card.** The *assembled scope* is the
      cache entry (`{:triage_connect_scope, org_id}`), not the individual
      posture reads. The receipt window reuses it for the short scope TTL.
    * **Failures ride inside the cached value.** A group whose posture read
      failed is part of a perfectly successful scope — it is in
      `unavailable_groups` with `scope_complete: false` — so caching the scope
      also caches the failure for that same short TTL without ever caching an
      `{:error, _}`. A Salix outage therefore costs one fan-out per TTL, not
      one per card.
    * **Bounded concurrency and a deadline.** The fan-out runs through
      `Task.async_stream/3` with a fixed number of reads in flight
      (`@scope_max_concurrency`), a per-group timeout just past the seam's own
      3s read timeout (`@scope_group_timeout_ms`), and a wall-clock deadline
      (`@scope_deadline_ms`) after which it stops consuming. Groups that were
      cut off are reported unavailable (`reason: :deadline_exceeded`) rather
      than dropped. With every group sick the build costs one timeout of wall
      clock and one concurrency window of RPCs *whatever the project count
      is* — the bound does not scale with N.

  Cut-off is honest degradation, not silence: those projects show up in
  `unavailable_groups`, `scope_complete` is false, and rows that could not be
  checked against them are counted `unattributed`, never `foreign`.

  ## Failure posture

  Every function returns a tagged result the UI can degrade on independently
  (per-card, per-tab). `{:error, :unavailable}` is never rendered as empty and
  never cached — an empty scan and a failed scan stay visually distinct, the
  same distinction the ingress contract draws.
  """
  require Logger

  alias BridgeForTeams.Salix.{Client, ReadCache}
  alias BridgeForTeams.Schema.{Agent, Organization, Project, User}
  alias BridgeForTeams.{Agents, Conversations, Memberships, Observability, Orgs, Projects}

  # Posture and ring state change only when an admin acts or a deploy lands;
  # scans move with traffic. Errors are never cached (`ReadCache` returns
  # `{:error, _}` through uncached by construction), so a transient Salix fault
  # cannot be pinned for a TTL.
  @posture_cache_ttl_ms 15_000
  @channel_cache_ttl_ms 15_000
  @ring_cache_ttl_ms 15_000
  @scan_cache_ttl_ms 5_000

  # The assembled scope is its own entry, and it is what makes the fan-out
  # cost one build per render instead of one per card. It is a *successful*
  # value even when groups failed (they are in `unavailable_groups`), so this
  # is where a Salix outage gets its bounded negative cache — without ever
  # pinning an `{:error, _}`, which stays uncacheable by construction.
  @scope_cache_ttl_ms 5_000

  # Hard bounds on the per-group posture fan-out. The per-group timeout sits
  # just past the seam's own 3s triage read timeout, so the client's honest
  # `{:error, :timeout}` normally wins and this is only a backstop. The
  # deadline is shorter than the timeout on purpose: once the first slow group
  # has cost a full timeout, further waiting buys a page nobody is still
  # looking at, so the remaining groups are reported as unchecked instead.
  @scope_max_concurrency 8
  @scope_group_timeout_ms 3_500
  @scope_deadline_ms 3_000

  @channel_page_limit 100
  @max_channel_cursor_bytes 1_024

  # salix_web owns both process names; the read model takes them as arguments
  # because salix_im owns neither. They are resolved by name on the far side at
  # runtime, so naming them here is not a compile-time dependency on salix_web.
  @ring_refs %{
    runtime: Salix.Bindings.TriageReviewRuntime,
    recovery: Salix.Bindings.TriageReceiptRecovery
  }

  @audit_resource_type "project_im_connect_triage"

  # A message-text reveal is its own resource type: it names the receipt whose
  # raw Slack text was shown, not the connect whose switch was flipped, and the
  # two must stay separable when an operator audits "who read what".
  @audit_reveal_resource_type "im_triage_message_text"
  @audit_reveal_action "integration.slack.triage_text_revealed"

  # An audit `resource_id` is an opaque locator, not free text. Receipt refs are
  # `"s3://" <> key`; the bound is defense against a caller stuffing a page of
  # anything into an audit row.
  @max_receipt_ref_bytes 512

  @type org_ref :: Organization.t() | Ecto.UUID.t()
  @type actor_ref :: User.t() | Ecto.UUID.t()
  @type owner :: %{group_id: String.t(), project_id: Ecto.UUID.t(), project_name: String.t()}
  @type action ::
          :enable
          | :disable
          | {:provision, String.t()}
          | {:set_channel, String.t(), boolean()}
  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  The product-owned Salix runtime namespace.

  It is fixed in code so the evaluator, recovery worker, and Workbench cannot
  be retargeted independently by deployment configuration.
  """
  @spec namespace() :: {:ok, String.t()}
  def namespace do
    {:ok, SalixStore.TriageKeys.default_namespace()}
  end

  @doc """
  The deployment-wide Triage review ring as all provably discovered Salix
  nodes see it, optionally checked against one selected Agent's live template.

  Not org-scoped. When an Agent is supplied, `evaluation_readiness` is the
  combined runtime-wiring plus identity-bound provider-template truth across
  the complete Salix node set: `:ready`, `:unavailable`, or `:unknown`. A
  missing Agent never claims readiness. A missing/old sampled shape is
  normalized to `:unknown`; it is never interpreted as an explicit false.

  The recovery cursor is replaced by `cursor_token`, an opaque digest — see
  `redact_ring_cursor/1`.
  """
  @spec ring_status(Agent.t() | String.t() | nil) :: result()
  def ring_status(agent_or_id \\ nil)

  def ring_status(%Agent{salix_agent_id: agent_id}), do: ring_status(agent_id)

  def ring_status(agent_id) when is_binary(agent_id) or is_nil(agent_id) do
    with {:ok, agent_id} <- normalize_evaluation_agent_id(agent_id) do
      refs = maybe_put_evaluation_agent(@ring_refs, agent_id)

      ReadCache.fetch(ring_cache_key(agent_id), @ring_cache_ttl_ms, fn ->
        with {:ok, ring} <- client().triage_ring_status(refs) do
          {:ok, ring |> normalize_evaluation_readiness() |> redact_ring_cursor()}
        end
      end)
    end
  end

  def ring_status(_invalid), do: {:error, :invalid_evaluation_agent}

  defp normalize_evaluation_agent_id(nil), do: {:ok, nil}

  defp normalize_evaluation_agent_id(agent_id) when is_binary(agent_id) do
    case String.trim(agent_id) do
      "" -> {:error, :invalid_evaluation_agent}
      normalized -> {:ok, normalized}
    end
  end

  defp maybe_put_evaluation_agent(refs, nil), do: refs

  defp maybe_put_evaluation_agent(refs, agent_id),
    do: Map.put(refs, :evaluation_agent_id, agent_id)

  defp ring_cache_key(nil), do: :triage_ring_status
  defp ring_cache_key(agent_id), do: {:triage_ring_status, agent_id}

  defp normalize_evaluation_readiness(%{evaluation_readiness: readiness} = ring)
       when readiness in [:ready, :unavailable, :unknown] do
    normalize_runtime_readiness(ring, readiness)
  end

  defp normalize_evaluation_readiness(ring) when is_map(ring),
    do: ring |> Map.put(:evaluation_readiness, :unknown) |> normalize_runtime_readiness(:unknown)

  defp normalize_evaluation_readiness(_invalid),
    do: %{evaluation_readiness: :unknown, runtime: %{}, recovery: %{}}

  defp normalize_runtime_readiness(%{runtime: runtime} = ring, readiness)
       when is_map(runtime) do
    evaluation_ready =
      case readiness do
        :ready -> true
        :unavailable -> false
        :unknown -> nil
      end

    %{
      ring
      | runtime:
          runtime
          |> Map.put(:evaluation_readiness, readiness)
          |> Map.put(:evaluation_ready, evaluation_ready)
    }
  end

  defp normalize_runtime_readiness(ring, readiness),
    do: Map.put(ring, :runtime, %{evaluation_readiness: readiness, evaluation_ready: nil})

  # The recovery cursor is base64 of a raw receipt key, and that key carries an
  # unhashed `connect_id` — belonging to whichever org the deployment-wide ring
  # happens to be walking, which is very often not the org whose page is being
  # rendered. It is dropped here rather than in the UI so it never reaches a
  # socket at all, and the position is published as a non-reversible digest:
  # enough to see the ring advancing, useless as an identifier.
  defp redact_ring_cursor(%{recovery: recovery} = ring) when is_map(recovery) do
    token = cursor_token(Map.get(recovery, :cursor))

    %{ring | recovery: recovery |> Map.delete(:cursor) |> Map.put(:cursor_token, token)}
  end

  defp redact_ring_cursor(ring), do: ring

  defp cursor_token(cursor) when is_binary(cursor) and cursor != "" do
    :sha256 |> :crypto.hash(cursor) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  defp cursor_token(_cursor), do: nil

  @doc """
  Per-connect Slack Triage posture for every project in the org.

  Fans out over the org's groups. A group whose read fails contributes no
  connects and one `unavailable_groups` entry, so a single sick project
  degrades one row instead of the page.
  """
  @spec connect_posture(org_ref()) :: result()
  def connect_posture(org) do
    with {:ok, scope} <- connect_scope(org) do
      {:ok,
       %{
         connects: Enum.sort_by(scope.postures, &{&1.project_name, &1.connect_id}),
         unavailable_groups: scope.unavailable_groups,
         scope_complete: scope.unavailable_groups == []
       }}
    end
  end

  @doc """
  Rebuilds the org-level Slack posture projection after an explicit retry.

  The assembled scope caches partial results so one unavailable project does
  not fan out repeatedly during a render. An explicit user retry drops that
  assembled result; successful per-project posture reads remain cached, while
  failed reads were never cached and are attempted again.
  """
  @spec refresh_connect_posture(org_ref()) :: result()
  def refresh_connect_posture(org) do
    with {:ok, %Organization{} = org} <- fetch_org(org) do
      ReadCache.invalidate({:triage_connect_scope, org.id})
      connect_posture(org)
    end
  end

  @doc """
  One bounded page of Slack channels visible to an exact connect in the org.

  The org scope is resolved before the provider call, so a forged connect id
  cannot turn this picker into a cross-organization discovery endpoint. The
  Salix projection is credential-free and cached briefly to avoid repeating a
  Slack API read across the dead and connected LiveView renders.
  """
  @spec list_slack_channels(org_ref(), map(), String.t() | nil) :: result()
  def list_slack_channels(org, connect_ref, cursor \\ nil)

  def list_slack_channels(org, connect_ref, cursor)
      when is_map(connect_ref) and (is_binary(cursor) or is_nil(cursor)) do
    connect_id = trim(connect_ref[:connect_id] || connect_ref["connect_id"])

    if valid_channel_cursor?(cursor) do
      with {:ok, %Organization{} = org} <- fetch_org(org),
           {:ok, scope} <- connect_scope(org),
           {:ok, connect} <- resolve_connect(scope, connect_id, connect_ref) do
        cached(
          {:triage_slack_channels, org.id, connect.group_id, connect.connect_id, cursor},
          @channel_cache_ttl_ms,
          fn ->
            client().triage_list_slack_channels(
              org.salix_tenant_id,
              connect.group_id,
              connect.connect_id,
              cursor,
              @channel_page_limit
            )
          end
        )
      end
    else
      {:error, :invalid_channel_cursor}
    end
  end

  def list_slack_channels(_org, _connect_ref, _cursor),
    do: {:error, :connect_not_found}

  @doc """
  The org's group router agents — the Workbench Agent picker.

  This is a purely BFT-local read over the same project set `connect_posture/1`
  fans out over (projects with a Salix group), so it degrades with the database
  rather than with the ring: a Salix outage still renders the picker. Only
  provisioned agents are listed — an agent with no `salix_agent_id` has no
  Salix identity to evaluate with.
  """
  @spec router_agents(org_ref()) :: {:ok, [map()]} | {:error, term()}
  def router_agents(org) do
    with {:ok, %Organization{} = org} <- fetch_org(org) do
      # Each project's roster is one Salix read. Read them concurrently with the
      # same bound as the posture fan-out; a failed read still raises in the
      # caller, as the sequential read did.
      agents =
        org.id
        |> Projects.list_projects()
        |> Enum.filter(&present?(&1.salix_group_id))
        |> Task.async_stream(&project_router_agents/1,
          max_concurrency: @scope_max_concurrency,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, rows} -> rows end)
        |> Enum.sort_by(&{&1.project_name, &1.agent_name || "", &1.agent_id})

      {:ok, agents}
    end
  end

  defp project_router_agents(%Project{} = project) do
    project.id
    |> Agents.list_agents()
    |> Enum.filter(&(&1.role == "router" and present?(&1.salix_agent_id)))
    |> Enum.map(&router_agent_row(&1, project))
  end

  defp router_agent_row(%Agent{} = agent, %Project{} = project),
    do: %{
      agent_id: agent.id,
      salix_agent_id: agent.salix_agent_id,
      agent_name: agent.salix["name"],
      group_id: project.salix_group_id,
      project_id: project.id,
      project_name: project.name
    }

  @doc """
  Receipts created at or after `since_ms`, newest first, filtered to the org.

  `truncated: true` means the read model's page budget ran out before the scan
  completed and the window may be missing rows; the UI renders that rather than
  an unqualified count. Options are passed through (`:page_budget`).

  `since_ms` is part of the cache key, so a caller that wants the #{@scan_cache_ttl_ms}ms
  TTL to bite should quantize it (e.g. to the minute) rather than pass a raw
  `now - window`.
  """
  @spec recent_window(org_ref(), non_neg_integer(), keyword()) :: result()
  def recent_window(org, since_ms, opts \\ []) do
    with {:ok, scope} <- read_scope(org),
         {:ok, window} <-
           cached(
             {:triage_recent_window, scope.namespace, since_ms, opts},
             @scan_cache_ttl_ms,
             fn -> client().triage_recent_window(scope.namespace, since_ms, opts) end
           ) do
      {kept, foreign_count, unattributed_count} =
        scope_rows(window.receipts, scope, & &1["connect_id"])

      {:ok,
       window
       |> Map.put(:receipts, kept)
       |> put_drop_counts(foreign_count, unattributed_count)
       |> put_scope_fields(scope, kept, & &1["connect_id"])}
    end
  end

  @doc """
  Product-facing Triage activity for one exact Agent.

  The selected Agent tuple is re-authorized against this org before crossing
  the Salix seam. The read is intentionally uncached: the Timeline refresh
  button is an operator-requested snapshot of replies/silences and context
  effects, and both backing queries are already hard-bounded.

  A caller that holds a `router_agents/1` result for this org, such as the
  one the Workbench socket read when it connected, may pass it as
  `router_agents: agents`. The Agent tuple is then checked against that roster
  instead of reading every project's roster again.
  """
  @spec product_activity(org_ref(), map(), keyword()) :: result()
  def product_activity(org, agent, opts \\ [])

  def product_activity(
        org,
        %{agent_id: agent_id, project_id: project_id, group_id: group_id} = agent,
        opts
      )
      when is_binary(agent_id) and is_binary(project_id) and is_binary(group_id) and
             is_list(opts) do
    {roster, opts} = Keyword.pop(opts, :router_agents)

    with :ok <- authorize_product_agent(org, agent, roster),
         {:ok, activity} <-
           client().triage_product_activity(project_id, group_id, agent_id, opts) do
      {:ok, activity}
    else
      false -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
      _other -> {:error, :unavailable}
    end
  end

  def product_activity(_org, _agent, _opts), do: {:error, :agent_not_found}

  @heatmap_cache_ttl_ms 60_000

  @doc """
  Agent-wide hourly outcome counts per Slack channel for the last 7 days.

  The selected Agent is re-authorized like `product_activity/3`. The result is
  cached for one minute per Agent because it aggregates the whole window; an
  error is never cached.
  """
  @spec product_heatmap(org_ref(), map(), result() | nil) :: result()
  def product_heatmap(org, agent, roster \\ nil)

  def product_heatmap(
        org,
        %{agent_id: agent_id, project_id: project_id, group_id: group_id} = agent,
        roster
      )
      when is_binary(agent_id) and is_binary(project_id) and is_binary(group_id) do
    with :ok <- authorize_product_agent(org, agent, roster) do
      cached(
        {:triage_product_heatmap, project_id, group_id, agent_id},
        @heatmap_cache_ttl_ms,
        fn -> client().triage_product_heatmap(project_id, group_id, agent_id) end
      )
    end
  end

  def product_heatmap(_org, _agent, _roster), do: {:error, :agent_not_found}

  # `roster`, as in `product_heatmap/3`, is a `router_agents/1` result the
  # caller already holds; without it the Agent is checked against a fresh read.
  def processing_detail(org, agent, receipt_ref, roster \\ nil)

  def processing_detail(org, %{group_id: group_id} = agent, receipt_ref, roster)
      when is_binary(receipt_ref) do
    with :ok <- authorize_product_agent(org, agent, roster) do
      client().triage_processing_detail(group_id, receipt_ref)
    end
  end

  def processing_detail(_org, _agent, _receipt_ref, _roster), do: {:error, :invalid}

  def source_presentation(org, agent, refs, roster \\ nil)

  def source_presentation(org, %{group_id: group_id} = agent, refs, roster)
      when is_list(refs) and length(refs) <= 20 do
    with :ok <- authorize_product_agent(org, agent, roster) do
      client().triage_source_presentation(group_id, refs)
    end
  end

  def source_presentation(_org, _agent, _refs, _roster), do: {:error, :invalid}

  @doc """
  Reads the existing canonical Task for one selected Triage delegation.

  The selected Agent is re-authorized through the same current product scope
  as Timeline activity. One explicit user request performs one uncached exact
  lookup; list rendering never calls this function. The result retains the
  canonical API's string keys and never changes the stored Triage outcome.
  """
  @spec delegation_task(org_ref(), map(), String.t(), 0 | 1, result() | nil) :: result()
  def delegation_task(org, agent, obligation_id, index, roster \\ nil)

  def delegation_task(
        org,
        %{agent_id: agent_id, project_id: project_id, group_id: group_id} = agent,
        obligation_id,
        index,
        roster
      )
      when is_binary(agent_id) and is_binary(project_id) and is_binary(group_id) do
    with :ok <- authorize_product_agent(org, agent, roster),
         true <- is_binary(obligation_id) and obligation_id != "" and index in 0..1,
         {:ok, task} <-
           client().triage_delegation_task(project_id, group_id, agent_id, obligation_id, index) do
      {:ok, task}
    else
      false -> {:error, :invalid_delegation}
      {:error, _reason} = error -> error
      _other -> {:error, :unavailable}
    end
  end

  def delegation_task(_org, _agent, _obligation_id, _index, _roster),
    do: {:error, :agent_not_found}

  @doc """
  Reads one delegated Task and its latest 20 committed Messages for an opened
  batch detail. Rechecks administrator and project access before either read.
  A failed Message snapshot preserves the exact Task link, not stale content.
  """
  def delegation_task_preview(org, agent, actor_id, obligation_id, index, roster \\ nil) do
    with :ok <- Memberships.authorize(actor_id, :manage, %{org_id: org.id, min_org_role: "admin"}),
         {:ok, project} <- worker_project(org, agent, actor_id, :read),
         {:ok, task} <- delegation_task(org, agent, obligation_id, index, roster) do
      {:ok, put_task_preview(task, project)}
    end
  end

  defp put_task_preview(%{"disposition" => "created", "conversation_id" => id} = task, project)
       when is_binary(id) and id != "" do
    case Conversations.get_project_conversation_with_messages(project, id, tail: 20, limit: 20) do
      {:ok,
       %{
         conversation: %{"conversation_id" => ^id, "kind" => "agent_task"} = conversation,
         messages: messages
       }} ->
        task
        |> Map.put("conversation", conversation)
        |> Map.put("messages", Enum.take(messages, -20))
        |> Map.put(
          "participation_result",
          messages
          |> Enum.reverse()
          |> Enum.find_value(fn message ->
            case get_in(message, [
                   "metadata",
                   "triage_investigation_result",
                   "payload",
                   "communication"
                 ]) do
              %{"kind" => kind} = decision when kind in ~w(reply reaction silence) ->
                Map.take(decision, ~w(kind reason_code))

              _ ->
                nil
            end
          end)
        )

      _ ->
        Map.put(task, "preview_unavailable", true)
    end
  end

  defp put_task_preview(task, _project), do: task

  def worker_configuration(org, agent, actor_id, opts \\ []) do
    with {:ok, project} <- worker_project(org, agent, actor_id, :read),
         {:ok, view} <- client().triage_worker_configuration(project.salix_group_id, opts) do
      {:ok,
       Map.put(
         view,
         "can_manage",
         Memberships.authorize(actor_id, :write, %{
           project_id: project.id,
           min_project_role: "admin"
         }) == :ok
       )}
    end
  end

  def configure_worker(org, agent, actor_id, worker_id, revision) do
    with {:ok, project} <- worker_project(org, agent, actor_id, :write),
         {:ok, router} <- Agents.current_router(project),
         audit = %{
           org_id: org.id,
           actor_user_id: actor_id,
           action: "integration.slack.triage_worker_change_attempted",
           resource_type: "project",
           resource_id: project.id,
           resource_label: "Triage Worker",
           result: "ok",
           request_id: Ecto.UUID.generate(),
           metadata: %{
             "worker_agent_id" => worker_id,
             "expected_revision" => revision
           }
         },
         :ok <- strict_audit(audit, audit_writer()) do
      result =
        client().configure_triage_worker(
          project.salix_group_id,
          router.salix_agent_id,
          worker_id,
          revision,
          %{"actor_user_id" => actor_id, "request_id" => audit.request_id}
        )

      case result do
        {:ok, binding} ->
          recorded =
            strict_audit(
              %{
                audit
                | action: "integration.slack.triage_worker_changed",
                  metadata: Map.put(audit.metadata, "binding", binding)
              },
              audit_writer()
            )

          {:ok, Map.put(binding, "audit_recorded", recorded == :ok)}

        error ->
          error
      end
    end
  end

  defp worker_project(
         %Organization{id: org_id},
         %{project_id: project_id, group_id: group_id},
         actor_id,
         action
       ) do
    with {:ok, %Project{org_id: ^org_id, salix_group_id: ^group_id} = project} <-
           Projects.get_project(project_id),
         :ok <- Memberships.authorize(actor_id, action, %{project_id: project_id}) do
      {:ok, project}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp worker_project(_, _, _, _), do: {:error, :forbidden}

  defp authorize_product_agent(org, selected, nil),
    do: authorize_product_agent(org, selected, router_agents(org))

  defp authorize_product_agent(_org, selected, roster) do
    with {:ok, agents} when is_list(agents) <- roster,
         true <-
           Enum.any?(agents, fn agent ->
             agent.agent_id == selected.agent_id and agent.project_id == selected.project_id and
               agent.group_id == selected.group_id
           end) do
      :ok
    else
      false -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
      _other -> {:error, :unavailable}
    end
  end

  @doc """
  Invalidates only the selected Agent's deployment-wide evaluator-status cache.

  This is read-cache invalidation only: it does not change monitoring
  authority, queue work, or write Salix state. The next matching
  `ring_status/1` call re-reads Salix; recent processing remains independently
  cached.
  """
  @spec refresh_evaluation_status(Agent.t() | String.t() | nil) :: :ok | {:error, term()}
  def refresh_evaluation_status(agent_or_id \\ nil)

  def refresh_evaluation_status(%Agent{salix_agent_id: agent_id}),
    do: refresh_evaluation_status(agent_id)

  def refresh_evaluation_status(agent_id) when is_binary(agent_id) or is_nil(agent_id) do
    with {:ok, agent_id} <- normalize_evaluation_agent_id(agent_id) do
      ReadCache.invalidate(ring_cache_key(agent_id))
    end
  end

  def refresh_evaluation_status(_invalid), do: {:error, :invalid_evaluation_agent}

  @doc """
  Flip one connect's Slack Triage authority on behalf of an org owner/admin.

  `connect_ref` is a map carrying `:connect_id` and, optionally, `:project_id`
  or `:group_id` to pin the expected owner (a mismatch is `:connect_not_found`,
  not a silent retarget). `action` is:

    * `:enable` / `:disable` — `set_slack_triage_enabled/4`. Disabling rotates
      the connect generation, fencing in-flight admissions.
    * `{:provision, approved_channel_id}` — `provision_slack_triage_authority/4`,
      the one-way door: it stamps the approved channel and a permanent
      provisioning marker and leaves the connect **disabled**, so provisioning
      and enabling stay two deliberate acts.

  Every outcome is audited: success through `record_audit/1`, denial and
  failure through `record_write_attempt/1`. The metadata is a fixed allowlist
  of connect identity and old→new posture — never message text.

  `opts` accepts `:actor_label` and `:request_id` like the other write paths.
  """
  @spec set_connect_triage(org_ref(), actor_ref(), map(), action(), keyword()) :: result()
  def set_connect_triage(org, actor_user, connect_ref, action, opts \\ []) do
    with {:ok, %Organization{} = org} <- fetch_org(org),
         {:ok, actor_id, opts} <- resolve_actor(actor_user, opts),
         {:ok, action} <- validate_action(action),
         :ok <- authorize_write(org, actor_id, connect_ref, action, opts) do
      apply_connect_triage(org, actor_id, connect_ref, action, opts)
    end
  end

  @doc """
  Record that one receipt's raw Slack message text was revealed to an operator.

  `triage_event.text` is raw message content (RFC §7), and the workbench hides
  it behind click-to-reveal precisely so the access record can be *per message*
  rather than per tab entry — RFC §10 open question 1, answered here in favour
  of the finer grain.

  This function only writes the record. It does not return the text, does not
  read Salix, and is not the access control for the text: the page's flag and
  role gates are. The re-check here is defense in depth, and a denial is itself
  audited so a member probing the event is visible rather than silent.

  Metadata follows the same fixed allowlist as `set_connect_triage/5` — refs and
  connect identity, never the text that was revealed. `opts` accepts
  `:actor_label`, `:request_id`, `:connect_id`, and `:surface` (the tab the
  reveal happened on, for reading the trail back).
  """
  @spec record_text_reveal(org_ref(), actor_ref(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def record_text_reveal(org, actor_user, receipt_ref, opts \\ []) do
    with {:ok, %Organization{} = org} <- fetch_org(org),
         {:ok, actor_id, opts} <- resolve_actor(actor_user, opts),
         {:ok, receipt_ref} <- validate_receipt_ref(receipt_ref),
         :ok <- authorize_reveal(org, actor_id, receipt_ref, opts) do
      strict_audit(
        %{
          org_id: org.id,
          actor_user_id: actor_id,
          actor_label: Keyword.get(opts, :actor_label),
          action: @audit_reveal_action,
          resource_type: @audit_reveal_resource_type,
          resource_id: receipt_ref,
          resource_label: "Slack Triage",
          result: "ok",
          request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
          metadata: reveal_metadata(receipt_ref, opts)
        },
        audit_writer()
      )
    end
  end

  @doc """
  Records the reveal of several source messages at once, with the same
  contract as `record_text_reveal/4` for each one. The role check runs once
  and the audit rows are written in one transaction, so a timeline page costs
  one commit instead of two per message. Returns the receipt refs whose audit
  row was stored; only those may be shown. A denied actor falls back to the
  per-message path, which audits each denial.

  Each item is `%{receipt_ref: ref, connect_id: connect_id}`. `opts` accepts
  `:actor_label` and `:surface`.
  """
  @spec record_text_reveals(org_ref(), actor_ref(), [map()], keyword()) :: MapSet.t()
  def record_text_reveals(org, actor_user, items, opts \\ []) when is_list(items) do
    with {:ok, %Organization{} = org} <- fetch_org(org),
         {:ok, actor_id, opts} <- resolve_actor(actor_user, opts),
         refs = valid_reveal_items(items),
         true <- refs != [] do
      case Memberships.authorize(actor_id, :manage, %{org_id: org.id, min_org_role: "admin"}) do
        :ok -> record_allowed_reveals(org, actor_id, refs, opts)
        {:error, :forbidden} -> record_reveals_one_by_one(org, actor_id, refs, opts)
      end
    else
      _ -> MapSet.new()
    end
  end

  defp valid_reveal_items(items) do
    items
    |> Enum.flat_map(fn item ->
      case validate_receipt_ref(item[:receipt_ref]) do
        {:ok, ref} -> [{ref, item[:connect_id]}]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp record_allowed_reveals(org, actor_id, refs, opts) do
    attrs =
      Enum.map(refs, fn {ref, connect_id} ->
        reveal_opts = Keyword.put(opts, :connect_id, connect_id)

        %{
          org_id: org.id,
          actor_user_id: actor_id,
          actor_label: Keyword.get(opts, :actor_label),
          action: @audit_reveal_action,
          resource_type: @audit_reveal_resource_type,
          resource_id: ref,
          resource_label: "Slack Triage",
          result: "ok",
          request_id: Ecto.UUID.generate(),
          metadata: reveal_metadata(ref, reveal_opts)
        }
      end)

    case audit_batch_writer().(attrs) do
      {:ok, _audits} ->
        MapSet.new(refs, &elem(&1, 0))

      {:error, reason} ->
        Logger.warning("triage_reveal_audit_failed reason=#{inspect(reason)}")
        MapSet.new()
    end
  end

  defp record_reveals_one_by_one(org, actor_id, refs, opts) do
    for {ref, connect_id} <- refs,
        record_text_reveal(org, actor_id, ref, Keyword.put(opts, :connect_id, connect_id)) ==
          :ok,
        into: MapSet.new(),
        do: ref
  end

  defp reveal_metadata(receipt_ref, opts) do
    %{
      "receipt_ref" => receipt_ref,
      "connect_id" => trim_or_nil(Keyword.get(opts, :connect_id)),
      "surface" => trim_or_nil(Keyword.get(opts, :surface))
    }
  end

  defp validate_receipt_ref(receipt_ref) when is_binary(receipt_ref) do
    trimmed = String.trim(receipt_ref)

    if trimmed != "" and byte_size(trimmed) <= @max_receipt_ref_bytes do
      {:ok, trimmed}
    else
      {:error, :invalid_receipt_ref}
    end
  end

  defp validate_receipt_ref(_receipt_ref), do: {:error, :invalid_receipt_ref}

  defp authorize_reveal(%Organization{} = org, actor_id, receipt_ref, opts) do
    case Memberships.authorize(actor_id, :manage, %{org_id: org.id, min_org_role: "admin"}) do
      :ok ->
        :ok

      {:error, :forbidden} ->
        audit(
          %{
            org_id: org.id,
            actor_user_id: actor_id,
            actor_label: Keyword.get(opts, :actor_label),
            action: @audit_reveal_action,
            resource_type: @audit_reveal_resource_type,
            resource_id: receipt_ref,
            resource_label: "Slack Triage",
            result: "denied",
            reason: :forbidden,
            request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
            surface: "integration",
            metadata: %{"receipt_ref" => receipt_ref}
          },
          write_attempt_writer()
        )

        {:error, :forbidden}
    end
  end

  # ---- writes ----

  defp authorize_write(%Organization{} = org, actor_id, connect_ref, action, opts) do
    case Memberships.authorize(actor_id, :manage, %{org_id: org.id, min_org_role: "admin"}) do
      :ok ->
        :ok

      {:error, :forbidden} ->
        record_write_attempt(
          org,
          actor_id,
          action,
          :forbidden,
          "denied",
          %{"connect_id" => connect_ref[:connect_id] || connect_ref["connect_id"]},
          opts
        )

        {:error, :forbidden}
    end
  end

  defp apply_connect_triage(%Organization{} = org, actor_id, connect_ref, action, opts) do
    connect_id = trim(connect_ref[:connect_id] || connect_ref["connect_id"])

    with {:ok, scope} <- connect_scope(org),
         {:ok, before} <- resolve_connect(scope, connect_id, connect_ref) do
      result = call_write(org, before, action)
      finish_connect_triage(org, actor_id, before, action, result, opts)
    else
      {:error, reason} = error ->
        record_write_attempt(
          org,
          actor_id,
          action,
          reason,
          "failed",
          %{"connect_id" => connect_id},
          opts
        )

        error
    end
  end

  defp call_write(%Organization{} = org, before, :enable),
    do: client().triage_set_enabled(org.salix_tenant_id, before.group_id, before.connect_id, true)

  defp call_write(%Organization{} = org, before, :disable),
    do:
      client().triage_set_enabled(org.salix_tenant_id, before.group_id, before.connect_id, false)

  defp call_write(%Organization{} = org, before, {:provision, approved_channel_id}),
    do:
      client().triage_provision(
        org.salix_tenant_id,
        before.group_id,
        before.connect_id,
        approved_channel_id
      )

  defp call_write(%Organization{} = org, before, {:set_channel, channel_id, enabled?}),
    do:
      client().triage_set_channel_enabled(
        org.salix_tenant_id,
        before.group_id,
        before.connect_id,
        channel_id,
        enabled?
      )

  defp finish_connect_triage(org, actor_id, before, action, result, opts) do
    if write_ok?(result) do
      # The posture the write produced is the honest source of the "after"
      # state and of the generation-rotation evidence: the write APIs answer
      # with `:ok` or a public projection, not with the fields the audit row
      # needs. Drop the cached posture first so this read cannot serve the
      # pre-write value back to us (and to the next render).
      invalidate_posture(org, before.group_id)
      later = reread_posture(org, before)

      record_success_audit(org, actor_id, before, later, action, opts)
      {:ok, later || before}
    else
      {:error, reason} = error = normalize_write_error(result)

      # A failed write may still have moved the connect — a timeout is not an
      # outcome — and the page re-reads the posture after every attempt to say
      # what is actually true now. Serving that re-read out of a scope built
      # before the attempt would defeat it.
      invalidate_posture(org, before.group_id)

      record_write_attempt(
        org,
        actor_id,
        action,
        reason,
        "failed",
        %{"connect_id" => before.connect_id, "project_id" => before.project_id},
        opts
      )

      error
    end
  end

  defp write_ok?(:ok), do: true
  defp write_ok?({:ok, _value}), do: true
  defp write_ok?(_other), do: false

  defp normalize_write_error({:error, _reason} = error), do: error
  defp normalize_write_error(other), do: {:error, other}

  # Best effort: a failed re-read must not turn a successful write into an
  # error, so the audit row falls back to the pre-write posture and records
  # only what it actually observed.
  defp reread_posture(%Organization{} = org, before) do
    case client().triage_connect_posture(org.salix_tenant_id, before.group_id) do
      {:ok, postures} when is_list(postures) ->
        case Enum.find(postures, &(&1.connect_id == before.connect_id)) do
          nil -> nil
          posture -> Map.merge(posture, owner_fields(before))
        end

      _unavailable ->
        nil
    end
  end

  defp owner_fields(row),
    do: %{
      group_id: row.group_id,
      project_id: row.project_id,
      project_name: row.project_name
    }

  defp resolve_connect(scope, connect_id, connect_ref) do
    expected_project = connect_ref[:project_id] || connect_ref["project_id"]
    expected_group = connect_ref[:group_id] || connect_ref["group_id"]

    case Enum.find(scope.postures, &(&1.connect_id == connect_id)) do
      nil ->
        {:error, missing_connect_reason(scope, expected_project, expected_group)}

      posture ->
        if matches?(expected_project, posture.project_id) and
             matches?(expected_group, posture.group_id) do
          {:ok, posture}
        else
          {:error, :connect_not_found}
        end
    end
  end

  # Absence only proves absence when the scope could see everything. With a
  # group's posture unreadable, the connect may be sitting in exactly that
  # group, so `:connect_not_found` — which the UI renders as "no longer part of
  # this organization" — would be a false statement about a live connect. The
  # transient answer is `:unavailable`: retry, do not go looking for what
  # removed it. A pinned ref narrows the question to its own group; an unpinned
  # one is in doubt as soon as any group is unreadable.
  defp missing_connect_reason(scope, expected_project, expected_group) do
    unreadable? =
      Enum.any?(scope.unavailable_groups, fn group ->
        matches?(expected_project, group.project_id) and matches?(expected_group, group.group_id)
      end)

    if unreadable?, do: :unavailable, else: :connect_not_found
  end

  defp matches?(nil, _actual), do: true
  defp matches?(expected, actual), do: expected == actual

  defp validate_action(action) when action in [:enable, :disable], do: {:ok, action}

  defp validate_action({:provision, channel_id}) when is_binary(channel_id) do
    case trim(channel_id) do
      "" -> {:error, :invalid_action}
      channel_id -> {:ok, {:provision, channel_id}}
    end
  end

  defp validate_action({:set_channel, channel_id, enabled?})
       when is_binary(channel_id) and is_boolean(enabled?) do
    case trim(channel_id) do
      "" -> {:error, :invalid_action}
      channel_id -> {:ok, {:set_channel, channel_id, enabled?}}
    end
  end

  defp validate_action(_action), do: {:error, :invalid_action}

  defp resolve_actor(%User{} = user, opts),
    do: {:ok, user.id, Keyword.put_new(opts, :actor_label, user.email)}

  defp resolve_actor(user_id, opts) when is_binary(user_id), do: {:ok, user_id, opts}
  defp resolve_actor(_actor, _opts), do: {:error, :forbidden}

  # ---- audit ----

  defp record_success_audit(org, actor_id, before, later, action, opts) do
    audit(
      %{
        org_id: org.id,
        actor_user_id: actor_id,
        actor_label: Keyword.get(opts, :actor_label),
        action: audit_action(action),
        resource_type: @audit_resource_type,
        resource_id: before.connect_id,
        resource_label: audit_label(before),
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: audit_metadata(before, later, action)
      },
      audit_writer()
    )
  end

  defp record_write_attempt(org, actor_id, action, reason, result, extra, opts) do
    audit(
      %{
        org_id: org.id,
        actor_user_id: actor_id,
        actor_label: Keyword.get(opts, :actor_label),
        action: audit_action(action),
        resource_type: @audit_resource_type,
        resource_id: extra["connect_id"] || org.id,
        resource_label: "Slack Triage",
        result: result,
        reason: reason,
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        surface: "integration",
        metadata: Map.put(extra, "action", action_name(action))
      },
      write_attempt_writer()
    )
  end

  # Fire-and-forget, and correct here: these rows describe a write that already
  # happened (or a denial that already stopped one). Losing the record cannot
  # un-happen the effect, so failing the caller would only add a second failure
  # on top of a completed action. The loss is logged, never swallowed silently.
  defp audit(attrs, writer) do
    case writer.(attrs) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("triage_connect_audit_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  # Strict, and correct there: the reveal's audit row is written *before* the
  # text is shown, so the write is the access control's receipt and not a
  # description of the past. If it cannot be written the caller must not
  # reveal, which means this failure has to reach the caller.
  defp strict_audit(attrs, writer) do
    case writer.(attrs) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("triage_reveal_audit_failed reason=#{inspect(reason)}")
        {:error, :audit_unavailable}
    end
  end

  # Both writers are resolved through app env, the same seam `Salix.Client`
  # uses. No deployment sets them; a test does, because "the audit row could
  # not be written" is the branch the strict reveal path exists for and there
  # is no other way to produce it without corrupting the audit table.
  defp audit_writer,
    do:
      Application.get_env(
        :bridge_for_teams_core,
        :triage_audit_writer,
        &Observability.record_audit/1
      )

  # A configured single-row writer (tests use it to fail audits) also governs
  # batches, so the batch is stored only when every row would have been.
  defp audit_batch_writer do
    case Application.get_env(:bridge_for_teams_core, :triage_audit_writer) do
      nil ->
        &Observability.record_audits/1

      writer ->
        fn attrs ->
          Enum.reduce_while(attrs, {:ok, []}, fn row, {:ok, audits} ->
            case writer.(row) do
              {:ok, audit} -> {:cont, {:ok, [audit | audits]}}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
        end
    end
  end

  defp write_attempt_writer,
    do:
      Application.get_env(
        :bridge_for_teams_core,
        :triage_write_attempt_writer,
        &Observability.record_write_attempt/1
      )

  # A fixed allowlist. Message text is stored in the receipts this module
  # reads, and none of it may ever reach a BFT audit row.
  defp audit_metadata(before, later, action) do
    %{
      "action" => action_name(action),
      "connect_id" => before.connect_id,
      "project_id" => before.project_id,
      "group_id" => before.group_id,
      "triage_enabled_before" => before.triage_enabled,
      "triage_enabled_after" => later && later.triage_enabled,
      "provisioned_before" => before.provisioned?,
      "provisioned_after" => later && later.provisioned?,
      # Disable rotates the generation to fence in-flight admissions;
      # provisioning mints a fresh one. `nil` means the post-write posture read
      # did not answer, so rotation is unobserved rather than absent.
      "connect_generation_rotated" =>
        later && later.connect_generation != before.connect_generation,
      "approved_channel_configured" => later && later.approved_channel_id != nil,
      "post_write_posture_observed" => later != nil,
      "channel_id" => action_channel_id(action)
    }
  end

  defp audit_action(action), do: "integration.slack.triage_#{action_name(action)}"

  defp action_name(:enable), do: "enabled"
  defp action_name(:disable), do: "disabled"
  defp action_name({:provision, _channel_id}), do: "provisioned"
  defp action_name({:set_channel, _channel_id, true}), do: "channel_enabled"
  defp action_name({:set_channel, _channel_id, false}), do: "channel_paused"

  defp action_channel_id({:provision, channel_id}), do: channel_id
  defp action_channel_id({:set_channel, channel_id, _enabled?}), do: channel_id
  defp action_channel_id(_action), do: nil

  defp audit_label(%{project_name: name}) when is_binary(name) and name != "",
    do: "#{name} · Slack Triage"

  defp audit_label(_row), do: "Slack Triage"

  # ---- scope ----

  # Reads use the product-owned runtime namespace; writes do not (a connect's
  # source/channel authority is independent of process introspection).
  defp read_scope(org) do
    with {:ok, namespace} <- namespace(),
         {:ok, scope} <- connect_scope(org) do
      {:ok, Map.put(scope, :namespace, namespace)}
    end
  end

  # The whole scope — not the individual posture reads — is the cache entry.
  # Every card on a render asks for it, and rebuilding it per card is what
  # turned one Salix outage into O(projects) sequential timeouts several times
  # per navigation. `build_connect_scope/2` always answers with a map (failed
  # groups are *inside* it), so this caches a success and never an error.
  defp connect_scope(org) do
    with {:ok, %Organization{} = org} <- fetch_org(org),
         {:ok, tenant_id} <- tenant_id(org) do
      {:ok,
       cached({:triage_connect_scope, org.id}, @scope_cache_ttl_ms, fn ->
         build_connect_scope(org, tenant_id)
       end)}
    end
  end

  defp build_connect_scope(%Organization{} = org, tenant_id) do
    {postures, unavailable} =
      org.id
      |> Projects.list_projects()
      |> Enum.filter(&present?(&1.salix_group_id))
      |> fan_out_postures(tenant_id)

    %{
      org: org,
      tenant_id: tenant_id,
      postures: postures,
      connects: Map.new(postures, &{&1.connect_id, owner_fields(&1)}),
      unavailable_groups: unavailable
    }
  end

  # Bounded concurrency, a per-group timeout, and a wall-clock deadline. The
  # stream is unordered so one sick group at the head cannot discard the
  # healthy answers that already came back; each task carries its project id
  # home, and whatever did not answer before the deadline is reported as
  # unchecked rather than quietly omitted.
  defp fan_out_postures([], _tenant_id), do: {[], []}

  defp fan_out_postures(projects, tenant_id) do
    deadline = System.monotonic_time(:millisecond) + @scope_deadline_ms

    answered =
      projects
      |> Task.async_stream(
        fn project -> {project.id, cached_posture(tenant_id, project.salix_group_id)} end,
        max_concurrency: @scope_max_concurrency,
        timeout: @scope_group_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce_while(%{}, fn outcome, acc ->
        acc =
          case outcome do
            {:ok, {project_id, result}} -> Map.put(acc, project_id, result)
            {:exit, _reason} -> acc
          end

        if System.monotonic_time(:millisecond) >= deadline,
          do: {:halt, acc},
          else: {:cont, acc}
      end)

    {postures, unavailable} =
      Enum.reduce(projects, {[], []}, fn project, {postures, unavailable} ->
        case Map.fetch(answered, project.id) do
          {:ok, {:ok, group_postures}} when is_list(group_postures) ->
            {[Enum.map(group_postures, &decorate_posture(&1, project)) | postures], unavailable}

          {:ok, {:error, reason}} ->
            {postures, [unavailable_group(project, reason) | unavailable]}

          {:ok, other} ->
            {postures, [unavailable_group(project, other) | unavailable]}

          # Killed by the per-group timeout, or never reached before the
          # deadline. Either way this group was not checked, and saying so is
          # the difference between a short list and a wrong one.
          :error ->
            {postures, [unavailable_group(project, :deadline_exceeded) | unavailable]}
        end
      end)

    {postures |> Enum.reverse() |> List.flatten(), Enum.reverse(unavailable)}
  end

  defp unavailable_group(%Project{} = project, reason),
    do: %{
      project_id: project.id,
      project_name: project.name,
      group_id: project.salix_group_id,
      reason: reason
    }

  defp decorate_posture(posture, %Project{} = project),
    do:
      Map.merge(posture, %{
        group_id: project.salix_group_id,
        project_id: project.id,
        project_name: project.name
      })

  defp cached_posture(tenant_id, group_id) do
    cached({:triage_connect_posture, tenant_id, group_id}, @posture_cache_ttl_ms, fn ->
      client().triage_connect_posture(tenant_id, group_id)
    end)
  end

  # Both entries, always together: the assembled scope embeds the posture it
  # was built from, so dropping only the posture would let the next render read
  # the pre-write switch back out of a scope that is still inside its TTL.
  defp invalidate_posture(%Organization{} = org, group_id) do
    ReadCache.invalidate({:triage_connect_posture, org.salix_tenant_id, group_id})
    ReadCache.invalidate({:triage_connect_scope, org.id})
    :ok
  end

  defp cached(key, ttl_ms, fun), do: ReadCache.fetch(key, ttl_ms, fun)

  # A dropped row means one of two different things, and the difference is the
  # whole reason `scope_complete` exists. With every group readable, a row
  # outside the map is *confirmed* to belong to another org. With a group
  # unreadable, the same row may well be this org's — it just could not be
  # checked. Reporting both as "outside this org" would state a fact the join
  # did not establish, so drops taken while the scope is incomplete are counted
  # as `unattributed_count` instead.
  defp scope_rows(rows, scope, connect_id_fun) when is_list(rows) do
    {kept, dropped} =
      Enum.reduce(rows, {[], 0}, fn row, {kept, dropped} ->
        if Map.has_key?(scope.connects, connect_id_fun.(row)) do
          {[row | kept], dropped}
        else
          {kept, dropped + 1}
        end
      end)

    if scope.unavailable_groups == [] do
      {Enum.reverse(kept), dropped, 0}
    else
      {Enum.reverse(kept), 0, dropped}
    end
  end

  defp put_scope_fields(page, scope, kept, connect_id_fun) do
    owners =
      kept
      |> Enum.map(connect_id_fun)
      |> Enum.uniq()
      |> Map.new(&{&1, Map.fetch!(scope.connects, &1)})

    page
    |> Map.put(:owners, owners)
    |> Map.put(:unavailable_groups, scope.unavailable_groups)
    |> Map.put(:scope_complete, scope.unavailable_groups == [])
  end

  defp put_drop_counts(page, foreign_count, unattributed_count) do
    page
    |> Map.put(:foreign_count, foreign_count)
    |> Map.put(:unattributed_count, unattributed_count)
  end

  defp fetch_org(%Organization{} = org), do: {:ok, org}
  defp fetch_org(org_id) when is_binary(org_id), do: Orgs.get_org(org_id)
  defp fetch_org(_org), do: {:error, :not_found}

  defp tenant_id(%Organization{salix_tenant_id: tenant_id}) do
    if present?(tenant_id), do: {:ok, tenant_id}, else: {:error, :tenant_not_ready}
  end

  defp valid_channel_cursor?(nil), do: true

  defp valid_channel_cursor?(cursor) when is_binary(cursor),
    do: byte_size(cursor) <= @max_channel_cursor_bytes and cursor == String.trim(cursor)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp trim_or_nil(value) do
    case trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp client, do: Client.impl()
end
