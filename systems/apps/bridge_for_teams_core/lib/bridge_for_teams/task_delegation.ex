defmodule BridgeForTeams.TaskDelegation do
  @moduledoc """
  Turn an accepted workspace conversation into real agent work.

  `dispatch/2` resolves the workspace item's own swarm from `project_id`, then
  creates one canonical Salix Task. The group's Router is the delegator and an
  active Worker is the command target. The Task command is its initial ordinary
  Message; there is no second dashboard hand-off Message.

  On success the canonical Task is synchronously projected back onto the
  existing workspace row. On any failure — no Worker, Salix unreachable, or
  Task creation rejected — the task keeps
  its status and notes the failure under `payload["delegation_error"]`, so the
  board can offer a retry; the error is also returned as `{:error, reason}`.

  Task copy travels to the agent as-is (this app deliberately has no
  translation dependency; the prompt contract is machine-facing English).
  """

  require Logger

  alias BridgeForTeams.{
    Agents,
    Artifacts,
    Conversations,
    Memberships,
    Projects,
    UserOnboardings,
    WorkspaceItems
  }

  alias BridgeForTeams.Schema.{Agent, Project}
  alias BridgeForTeams.WorkspaceItems.Item
  alias SalixStore.Ids

  # Categories with their own specialized payload contracts. Everything else
  # gets the artifact contract, whose prompt task data must carry the concrete
  # "artifact_slug" the file lands under (see `prompt_payload/1`).
  @specialized_categories ~w(email_drafts meeting_recaps reports)

  @doc """
  Delegate `task` to its own swarm's Worker. The target project is resolved from
  `task.project_id` (validated to still exist), and the acting user
  (`:actor_user_id`, defaulting to the task's owner) must still hold an
  effective role on that swarm (`BridgeForTeams.Memberships.project_role/2`) —
  a revoked membership refuses the dispatch instead of quietly running work on
  a swarm the actor can no longer see. Options: `:actor_user_id` /
  `:actor_label` flow into conversation observability/audit, and `:agent`
  overrides the resolved Worker `%Agent{}`.

  Returns `{:ok, updated_task}` (now `in_progress`, provenance stamped) or
  `{:error, :no_project | :not_project_member | :no_router | :no_worker | term()}` with the
  failure noted in the task payload.
  """
  @spec dispatch(Item.t(), keyword()) ::
          {:ok, Item.t()} | {:error, term()}
  def dispatch(%Item{} = task, opts \\ []) do
    with {:ok, %Project{} = project} <- resolve_project(task),
         :ok <- validate_membership(project, task, opts),
         {:ok, %Agent{} = router} <- Agents.current_router(project),
         {:ok, %Agent{} = worker} <- resolve_worker(project, opts),
         {:ok, task} <- ensure_conversation(task, project, router, worker, opts) do
      {:ok, task}
    else
      {:error, reason} = error ->
        note_delegation_error(task, reason)
        error
    end
  end

  @doc "Materialize and synchronously project the canonical Task for a workspace item."
  @spec ensure_conversation(Item.t(), Project.t(), Agent.t(), Agent.t(), keyword()) ::
          {:ok, Item.t()} | {:error, term()}
  def ensure_conversation(
        %Item{} = task,
        %Project{} = project,
        %Agent{role: "router"} = router,
        %Agent{role: "worker"} = worker,
        opts \\ []
      ) do
    case task.salix_conversation_id do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        if Ids.valid_conversation_id?(conversation_id) do
          project_existing_task(task, project, conversation_id)
        else
          {:error, :invalid_conversation_id}
        end

      _missing ->
        request_id = "workspace-item-conversation:#{task.id}"

        create_opts = [
          request_id: request_id,
          actor_user_id: Keyword.get(opts, :actor_user_id) || task.user_id,
          actor_label: Keyword.get(opts, :actor_label)
        ]

        with {:ok, %{"conversation_id" => conversation_id}} <-
               Conversations.create_project_task_conversation(
                 project,
                 router,
                 worker,
                 task_create_attrs(task, worker, request_id),
                 create_opts
               ),
             true <- Ids.valid_conversation_id?(conversation_id),
             {:ok, task} <-
               WorkspaceItems.update_task(task, %{
                 "status" => "in_progress",
                 "salix_conversation_id" => conversation_id,
                 "salix_agent_id" => worker.salix_agent_id,
                 "payload" => Map.delete(task.payload || %{}, "delegation_error")
               }),
             {:ok, task} <- project_existing_task(task, project, conversation_id) do
          {:ok, task}
        else
          false -> {:error, :invalid_conversation_id}
          {:error, _reason} = error -> error
          _invalid_response -> {:error, :invalid_response}
        end
    end
  end

  @doc """
  The Task command `dispatch/2` creates: task context plus the Worker's
  ordinary-Message reporting contract.

  Artifact-producing categories (everything outside the specialized
  email/recap/report contracts) get the owning user's concrete
  `artifact_slug` — `BridgeForTeams.Artifacts.slug(task.title, task.user_id)`
  — embedded in the prompt's task data, because the artifact contract names
  that slug as the directory the document file must land in.
  """
  @spec prompt(Item.t()) :: String.t()
  def prompt(%Item{} = task) do
    """
    Work on this task from the user's New Home board. Use your tools to complete it, then report back in this conversation.

    You are the Worker assigned to this canonical Task. Do the work here with your own tools. Do not create another Task, do not delegate it, and do not treat the command as a new chat request to route.

    Task: #{task.title}
    Category: #{target_category(task)}
    Platform: #{task.platform}#{prompt_notes(task)}#{prompt_payload(task)}#{prompt_user_brief(task)}

    #{reporting_contract(task)}
    """
    |> String.trim()
  end

  # The output type this task produces. Working-list tasks (category
  # `general`) carry their target widget in `payload["category"]` — the same
  # convention suggestions use — so "Draft a reply…" delegates with the
  # email-draft contract and its report files the result into Drafted emails.
  defp target_category(%Item{payload: payload, category: category}) do
    with %{} <- payload,
         target when is_binary(target) <- payload["category"],
         true <- target in WorkspaceItems.categories() do
      target
    else
      _no_target -> category
    end
  end

  # What onboarding captured about the task's owner (identity, key contacts,
  # capability grants) — the profile handoff, so agents write for the right
  # person instead of a stranger. Absent when onboarding captured nothing.
  defp prompt_user_brief(%Item{user_id: user_id}) when is_binary(user_id) do
    case UserOnboardings.agent_brief(user_id) do
      nil -> ""
      brief -> "\n\n" <> brief
    end
  end

  defp prompt_user_brief(_task), do: ""

  # Workers publish only ordinary Messages. The Router receives those Messages
  # as the delegator and owns the separate Conversation status mutation.
  defp reporting_contract(%Item{} = task) do
    target = target_category(task)

    """
    Reporting contract — whenever you make progress and when you finish, use call_im_provider_api to publish an ordinary Message in the current conversation (content blocks REQUIRE "type"):

    {"provider": "internal", "connect_id": "internal", "api": "internal.send_message", "conversation_id": "<current conversation_id>", "content": [{"type": "text", "text": "<your visible progress or result>"}]}

    Plain assistant text reaches nobody. Always publish the ordinary Message. internal.send_message accepts only Message content and routing fields; it never mutates lifecycle or workspace state.

    Rules:
    - The Router owns Conversation status and board projection through the separate Conversation API. You must never call internal.update_conversation.
    - Say clearly in the final ordinary Message whether the result is ready for review or fully done, so the Router can update Conversation status.
    - #{payload_contract(target)}
    """
    |> String.trim()
  end

  @doc """
  The category-shaped payload rule inside the reporting contract — public so
  other agent-facing hand-offs (the New Home board's one-shot chat run of a
  report offer) state the exact same rule instead of restating it.
  """
  @spec payload_contract(String.t()) :: String.t()
  def payload_contract(category)

  def payload_contract("email_drafts"),
    do:
      ~s(include the complete email draft in the ordinary result Message with shape {"to": "recipient", "subject": "…", "body": "full plain-text draft"}.)

  def payload_contract("meeting_recaps"),
    do:
      ~s(include the complete recap in the ordinary result Message with shape {"bullets": ["key point", …], "date": "YYYY-MM-DD"}.)

  # Reports are file-first: the run is an immutable Markdown file (flat
  # frontmatter + body) in the agent's VFS under the task's series directory;
  # the ordinary result Message attaches the file's path.
  def payload_contract("reports"),
    do:
      ~s[this task produces a report FILE. FIRST write the full report as Markdown to a NEW file at /.salix/reports/<series>/<YYYY-MM-DD>.md (today's date, UTC; <series> is the "series" value in the current task data, or a short lowercase dash-separated slug of the task title when absent; if that date's file already exists, never rewrite it — append the current time before the extension: <YYYY-MM-DD>-<HHMM>.md). Begin the file with a frontmatter block delimited by `---` lines — flat single-line `key: value` pairs: title, kind (daily|weekly|adhoc), period, summary, generated_at (ISO8601), plus site: <site name> if you also publish an HTML companion under /.salix/websites/ — then the report body as plain Markdown. THEN attach the file to your ordinary result Message by adding {"type": "file", "path": "<the exact file path you wrote>"} after the text block. Include {"vfs_path":"<exact path>","summary":"one line","period":"<covered>","kind":"daily|weekly|adhoc"} in the text for the Router.]

  # Every other category is artifact-first: the result is an immutable
  # Markdown document (flat frontmatter + body with fenced bft:block data
  # segments) in the agent's VFS under the task's artifact directory; the
  # ordinary result Message attaches the file's vfs_path.
  def payload_contract(_category) do
    """
    this task produces an artifact FILE. FIRST write the full result as Markdown to a NEW file at /.salix/artifacts/<slug>/<YYYY-MM-DD>.md (today's date, UTC; <slug> is the exact "artifact_slug" value in the current task data; if that date's file already exists, never rewrite it — append the current time before the extension: <YYYY-MM-DD>-<HHMM>.md). Begin the file with a frontmatter block delimited by `---` lines — flat single-line `key: value` pairs: title, kind (report|brief|recap|draft|dataset|note), summary, generated_at (ISO8601) — then the body as plain Markdown. Wherever the content is data-shaped, emit it in the body as a fenced block instead of prose:

    ```bft:block
    {"type": "kpis", "items": [{"label": "…", "value": "…"}]}
    ```

    Block vocabulary — one JSON object per fence, always "type" plus "items" (the block key is "type", NOT "kind" — "kind" belongs to the frontmatter; an optional "title" captions the block): kpis (items of label/value with optional delta/note), table ("columns", not "headers", plus rows), list (optional style plain|risks|actions|watch, string items), links (title/url), timeline (date/event), entities (name with optional detail). THEN attach the file to your ordinary result Message by adding {"type": "file", "path": "<the exact file path you wrote>"} after the text block. Include {"vfs_path":"<exact path>","summary":"one line"} in the text for the Router. Never put the document body in Message metadata.
    """
    |> String.trim()
  end

  defp prompt_notes(%Item{description: description})
       when is_binary(description) and description != "",
       do: "\nNotes: #{description}"

  defp prompt_notes(_task), do: ""

  # The task data line the prompt carries. Artifact-producing categories
  # always have one: the computed "artifact_slug" (title slugified and
  # namespaced to the owning user, so different users of one swarm never
  # collide) is merged in because the artifact contract points the agent at
  # the exact slug given here.
  defp prompt_payload(%Item{} = task) do
    case task_data(task) do
      empty when map_size(empty) == 0 ->
        ""

      data ->
        "\nCurrent task data (JSON): " <> String.slice(Jason.encode!(data), 0, 1500)
    end
  end

  defp task_data(%Item{payload: payload} = task) do
    data = if is_map(payload), do: Map.delete(payload, "delegation_error"), else: %{}

    if target_category(task) in @specialized_categories do
      data
    else
      Map.put(data, "artifact_slug", Artifacts.slug(task.title, task.user_id))
    end
  end

  # The task's own swarm: a preloaded association wins, otherwise the row is
  # loaded from `task.project_id`. A task whose project no longer exists cannot
  # be delegated (`:no_project`).
  defp resolve_project(%Item{project_id: project_id}) when is_binary(project_id) do
    case Projects.get_project(project_id) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, :not_found} -> {:error, :no_project}
    end
  end

  defp resolve_project(_task), do: {:error, :no_project}

  # Delegating validates membership on the task's own swarm: the acting user
  # (or the task's owner when no actor is given — e.g. system-driven retries)
  # must resolve an effective project role, which covers explicit grants and
  # the org owner/admin override alike.
  defp validate_membership(%Project{} = project, %Item{} = task, opts) do
    user_id = Keyword.get(opts, :actor_user_id) || task.user_id

    case Memberships.project_role(project.id, user_id) do
      {:ok, _role} -> :ok
      {:error, :not_found} -> {:error, :not_project_member}
    end
  end

  # The Task command always targets a Worker. A caller may pass an already
  # resolved Worker; otherwise choose the first active Worker in the roster.
  defp resolve_worker(%Project{} = project, opts) do
    case Keyword.get(opts, :agent) do
      %Agent{role: "worker"} = agent ->
        {:ok, agent}

      %Agent{} ->
        {:error, :no_worker}

      nil ->
        with {:ok, agents} <- Agents.fetch_agents(project.id, limit: 1, role: "worker") do
          case agents do
            [%Agent{} = agent | _rest] -> {:ok, agent}
            [] -> {:error, :no_worker}
          end
        end
    end
  end

  defp task_create_attrs(%Item{} = task, %Agent{} = worker, request_id) do
    metadata =
      %{
        "workspace_category" => target_category(task),
        "payload" => Map.delete(task.payload || %{}, "delegation_error"),
        "source" => task.source,
        "platform" => task.platform,
        "description" => task.description,
        "external_source" => task.external_source,
        "external_id" => task.external_id,
        "archived_at" => encode_datetime(task.archived_at)
      }
      |> reject_empty()

    source_refs =
      (task.source_refs || %{})
      |> Map.put("workspace_item_id", task.id)
      |> Map.put("agent_id", worker.salix_agent_id)
      |> reject_empty()

    %{
      "client_request_id" => request_id,
      "title" => task.title,
      "content" => prompt(task),
      "owner_user_id" => task.user_id,
      "created_by_user_id" => task.user_id,
      "source_refs" => source_refs,
      "conversation_metadata" => metadata,
      "labels" => task.labels || [],
      "latest_artifact" => task.latest_artifact,
      "artifact_manifest" => task.artifact_manifest
    }
    |> reject_empty()
  end

  defp project_existing_task(task, project, conversation_id) do
    user_id = task.row_user_id || task.user_id

    with {:ok, _items} <- Conversations.project_project_conversation(project, conversation_id),
         {:ok, projected} <-
           WorkspaceItems.get_task(user_id, conversation_id, project_id: project.id) do
      {:ok, projected}
    end
  end

  defp reject_empty(map),
    do: Map.reject(map, fn {_key, value} -> value in [nil, "", %{}] end)

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(_value), do: nil

  # Failed dispatch: the task keeps its status; the failure is noted in the
  # payload so the board can render a retry affordance. Best-effort — a task
  # that cannot even record the note still returns the original error.
  defp note_delegation_error(%Item{} = task, reason) do
    note = %{
      "reason" => delegation_reason(reason),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case WorkspaceItems.update_task(task, %{
           "payload" => Map.put(task.payload || %{}, "delegation_error", note)
         }) do
      {:ok, _task} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "task_delegation_error_note_failed task_id=#{task.id} reason=#{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  defp delegation_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp delegation_reason({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp delegation_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 120)
  defp delegation_reason(reason), do: reason |> inspect() |> String.slice(0, 120)
end
