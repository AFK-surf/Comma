defmodule CommaWeb.Coding.Endpoints do
  @moduledoc """
  Coding sessions (Tasks that run `{kind: sandbox}`) for a Workspace's members:

    * `GET  /v1/comma/workspaces/:ws/coding/repos?page=` and
      `GET  …/coding/repos/:owner/:name/branches?page=`: one page (100) of what
      the Workspace's connected GitHub account reaches;
    * `POST …/coding/sessions` `{text, repo: {owner, name, base_ref?},
      model?: {provider, model?, effort?}, account_id?, client_request_id}`:
      starts a coding Task, owned by the caller, through the Workspace's Task
      placement (`SalixIM.TaskPlacement`);
    * `GET  …/coding/sessions/:task`: its repository, branch and sandbox state;
    * `GET  …/coding/sessions/:task/changes?commit=&uncommitted=`: the
      session branch's changes and its commits past the base, from its
      sandbox's worktree, or from GitHub once the sandbox is gone. Without a
      scope, everything against the base, with the branch's pull request as
      GitHub has it; `commit` (a full sha), what one of its commits changed;
      `uncommitted=1`, what the sandbox has not committed (nothing once it is
      gone);
    * `GET  …/coding/sessions/:task/history?before=&limit=`: a page of its
      Session's execution history (transcript entries, the latest first by
      page) and the tokens its model calls used, from its sandbox; `available`
      false, and nothing, while the sandbox is not running;
    * what the whole branch's changes, its pull request and the token use
      come to is kept for the Task's panel (`SalixWeb.CodingSandboxes.remember/4`),
      which shows it with the Task before its next read;
    * `GET  …/coding/sessions/:task/pull-request`: the branch's pull request
      as GitHub has it (`{pull_request}`, null where it has none);
    * `POST …/coding/sessions/:task/pull-request` `{title?, body?, draft?}`:
      opens a pull request of the branch into its base, titled for the Task
      and described with what it was asked unless given. While the sandbox
      runs, it pushes the branch and opens it; once it is gone, Comma opens it
      on GitHub with the Group's GitHub account (the sandbox pushed the branch
      before it stopped);
    * `PATCH …/coding/sessions/:task/pull-request` `{title?, body?, ready?}`:
      changes the open pull request's title and description, and marks a
      draft ready for review;
    * `POST …/coding/sessions/:task/pull-request/merge` `{number, head_sha}`:
      merges the open pull request the member confirmed, the first way the
      repository allows of squash, merge commit and rebase. Refused when the
      branch's open pull request is another one, or its head moved past
      `head_sha`;
    * `POST …/coding/sessions/:task/terminal`: the sandbox's L4ES web
      terminal, `<L4ES>/t/comma:<group>/<sandbox>`. The Workspace's members
      are made L4ES members first (`SalixWeb.L4ES.set_members/2`); signed
      in to L4ES with Comma, the member opens it there. The link is no
      credential: anyone may share it.

  Every member reads; a read-only member (`viewer`) changes nothing.
  """

  import Plug.Conn
  require Logger

  alias SalixWeb.StationTasks

  @text_bytes 16_000
  # GitHub keeps 65 536 characters of a description.
  @body_bytes 60_000
  # The branch's pull request is two to five GitHub reads, each bounded by SalixWeb.GitHub's own timeout.
  @pull_request_read_ms 60_000

  def repos(conn, workspace_id) do
    with_workspace(conn, workspace_id, :read, fn workspace, _user ->
      with {:ok, %{token: token}} <- github(workspace),
           {:ok, repos} <- github_client().repos(token, page(conn)) do
        json(conn, 200, %{repos: repos})
      end
    end)
  end

  def branches(conn, workspace_id, owner, name) do
    with_workspace(conn, workspace_id, :read, fn workspace, _user ->
      with {:ok, %{token: token}} <- github(workspace),
           {:ok, branches} <- github_client().branches(token, owner, name, page(conn)) do
        json(conn, 200, %{branches: branches})
      end
    end)
  end

  def start(conn, workspace_id) do
    with_workspace(conn, workspace_id, :write, fn workspace, user ->
      body = conn.body_params || %{}

      with {:ok, text} <- text(body["text"]),
           {:ok, request_id} <- request_id(body["client_request_id"]),
           {:ok, model} <- model(body["model"]),
           group = workspace.salix_group_id,
           {:ok, %{"router_agent_id" => router}} when is_binary(router) <-
             SalixIM.GroupDirectory.get_group(group),
           {:ok, created} <-
             SalixIM.TaskPlacement.create_task_conversation(
               group,
               router,
               %{
                 "runs_on" => %{"kind" => "sandbox"},
                 "repo" => body["repo"],
                 "content" => text,
                 "title" => title(text),
                 "client_request_id" => "comma-coding:" <> user["id"] <> ":" <> request_id,
                 "owner_user_id" => user["id"],
                 "initial_author" => "owner",
                 "source_refs" => %{"origin_agent_id" => router}
               }
               |> put_present("model", model)
               |> put_present("account_id", account(body["account_id"]))
             ) do
        json(conn, 201, %{task_id: created["conversation_id"], group_id: group})
      end
    end)
  end

  def show(conn, workspace_id, task) do
    with_workspace(conn, workspace_id, :read, fn workspace, _user ->
      with {:ok, conversation} <- coding_task(workspace, task) do
        spec =
          case SalixStore.CodingSandboxes.get_by_conversation(workspace.salix_tenant_id, task) do
            {:ok, workload} -> workload.spec
            {:error, _} -> %{}
          end

        json(conn, 200, %{
          repo:
            Map.take(conversation["repo"] || spec["repo"] || %{}, ~w(owner name base_ref branch)),
          state: spec["state"] || "starting",
          reason: spec["reason"]
        })
      end
    end)
  end

  def changes(conn, workspace_id, task) do
    with_workspace(conn, workspace_id, :read, fn workspace, _user ->
      with {:ok, conversation} <- coding_task(workspace, task),
           {:ok, scope} <- changes_scope(conn.query_params) do
        at = SystemsClock.utc_now()

        # The whole branch's changes come with its pull request as GitHub has it, sandbox or not: it is read beside
        # the diff, so a slow GitHub does not hold the diff up behind it.
        read =
          if scope == %{},
            do: SystemsRuntime.Task.async(fn -> branch_pull_request(workspace, conversation) end)

        pull_request = fn -> read_answer(read) end

        try do
          case StationTasks.ask(workspace.salix_group_id, task, "task.diff", scope, 20_000) do
            {:ok, diff} ->
              answer = pull_request.()
              if scope == %{}, do: remember_changes(workspace, task, diff["files"], answer, at)

              json(
                conn,
                200,
                diff
                |> Map.put("source", "sandbox")
                |> Map.put("pull_request", pull_request_value(answer))
              )

            {:error, _not_reachable} ->
              pushed_changes(conn, workspace, task, conversation, scope, pull_request, at)
          end
        after
          # An answer not waited for (no branch on GitHub, a failed read) is let go with the request.
          if read, do: SystemsRuntime.Task.shutdown(read, :brutal_kill)
        end
      end
    end)
  end

  # What the read beside the diff found: `{:ok, pull_request}` (nil where the branch has none), or `:error` when none
  # was read, or it did not answer within its bound.
  defp read_answer(nil), do: :error

  defp read_answer(read) do
    case SystemsRuntime.Task.yield(read, @pull_request_read_ms) ||
           SystemsRuntime.Task.shutdown(read, :brutal_kill) do
      {:ok, {:ok, _pull_request} = answer} -> answer
      _none -> :error
    end
  end

  defp pull_request_value({:ok, pull_request}), do: pull_request
  defp pull_request_value(:error), do: nil

  # The whole branch's change totals and its pull request, for the Task's panel. A pull request GitHub did not say
  # leaves the one kept as it is.
  defp remember_changes(workspace, task, files, pull_request, at) when is_list(files) do
    SalixWeb.CodingSandboxes.remember(
      workspace.salix_tenant_id,
      task,
      %{
        "changes" => {:ok, SalixWeb.CodingSandboxes.change_totals(files)},
        "pull_request" => pull_request_part(pull_request)
      },
      at
    )
  end

  defp remember_changes(_workspace, _task, _files, _pull_request, _at), do: :ok

  defp pull_request_part({:ok, found}),
    do: {:ok, SalixWeb.CodingSandboxes.pull_request_fact(found)}

  defp pull_request_part(:error), do: :error

  # What the changes are read of: the whole branch (no scope), one of its commits, or what is not committed.
  defp changes_scope(%{"commit" => sha}) when is_binary(sha) and sha != "" do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: {:ok, %{"commit" => sha}},
      else: {:error, {:bad_request, "a commit is named by its full sha"}}
  end

  defp changes_scope(%{"uncommitted" => "1"}), do: {:ok, %{"uncommitted" => true}}
  defp changes_scope(_params), do: {:ok, %{}}

  def history(conn, workspace_id, task) do
    with_workspace(conn, workspace_id, :read, fn workspace, _user ->
      with {:ok, _conversation} <- coding_task(workspace, task) do
        at = SystemsClock.utc_now()

        params =
          %{}
          |> put_present("before", count(conn.query_params["before"]))
          |> put_present("limit", count(conn.query_params["limit"]))

        case StationTasks.ask(workspace.salix_group_id, task, "task.history", params, 20_000) do
          {:ok, page} ->
            # A page carries the token use: it is kept for the Task's panel.
            SalixWeb.CodingSandboxes.remember(
              workspace.salix_tenant_id,
              task,
              %{"usage" => SalixWeb.CodingSandboxes.usage_part(page)},
              at
            )

            json(conn, 200, Map.put(page, "available", true))

          {:error, _not_reachable} ->
            json(conn, 200, %{
              "available" => false,
              "start" => 0,
              "total" => 0,
              "entries" => [],
              "usage" => nil
            })
        end
      end
    end)
  end

  defp count(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp count(_value), do: nil

  # The sandbox is gone: the pushed branch against its base, from GitHub, with its commits. One commit's changes
  # are GitHub's too; nothing is uncommitted once the sandbox has stopped (it committed and pushed before).
  defp pushed_changes(conn, workspace, task, conversation, scope, pull_request, at) do
    repo = conversation["repo"] || %{}

    with {:ok, %{token: token}} <- github(workspace) do
      case github_client().compare(
             token,
             repo["owner"],
             repo["name"],
             repo["base_ref"],
             repo["branch"]
           ) do
        {:ok, compare} ->
          case pushed_scope(token, repo, compare, scope, pull_request) do
            {:ok, files, answer} ->
              if scope == %{},
                do: remember_changes(workspace, task, files, answer, at)

              json(conn, 200, %{
                source: "github",
                files:
                  Enum.map(files, &Map.take(&1, [:path, :status, :additions, :deletions, :patch])),
                truncated: false,
                commits: Map.get(compare, :commits, []),
                uncommitted: false,
                pull_request: pull_request_value(answer)
              })

            error ->
              error
          end

        {:error, :not_found} ->
          json(conn, 200, %{
            source: "github",
            files: [],
            truncated: false,
            commits: [],
            uncommitted: false,
            pushed: false,
            pull_request: nil
          })

        error ->
          error
      end
    end
  end

  defp pushed_scope(token, repo, compare, %{"commit" => sha}, _pull_request) do
    if Enum.any?(Map.get(compare, :commits, []), &(&1.sha == sha)) do
      with {:ok, %{files: files}} <-
             github_client().commit(token, repo["owner"], repo["name"], sha),
           do: {:ok, files, :error}
    else
      {:error, :not_found}
    end
  end

  defp pushed_scope(_token, _repo, _compare, %{"uncommitted" => true}, _pull_request),
    do: {:ok, [], :error}

  defp pushed_scope(_token, _repo, compare, _all, pull_request),
    do: {:ok, compare.files, pull_request.()}

  # The branch's pull request on GitHub: `{:ok, pull_request}`, nil where it has none. A lookup that fails answers
  # `:error`, and the changes go without it.
  defp branch_pull_request(workspace, conversation) do
    repo = conversation["repo"] || %{}

    with {:ok, %{token: token}} <- github(workspace),
         {:ok, pull_request} <-
           github_client().pull_request(token, repo["owner"], repo["name"], repo["branch"]) do
      {:ok, pull_request}
    else
      _error -> :error
    end
  end

  def pull_request_status(conn, workspace_id, task) do
    with_workspace(conn, workspace_id, :read, fn workspace, _user ->
      with {:ok, conversation} <- coding_task(workspace, task),
           {:ok, %{token: token}} <- github(workspace),
           repo = conversation["repo"] || %{},
           {:ok, pull_request} <-
             github_client().pull_request(token, repo["owner"], repo["name"], repo["branch"]) do
        json(conn, 200, %{pull_request: pull_request})
      end
    end)
  end

  def pull_request(conn, workspace_id, task) do
    with_workspace(conn, workspace_id, :write, fn workspace, _user ->
      body = conn.body_params || %{}

      with {:ok, conversation} <- coding_task(workspace, task) do
        params = %{
          "draft" => body["draft"] == true,
          "title" =>
            short(body["title"], 256) || short(conversation["title"], 256) ||
              get_in(conversation, ["repo", "branch"]) || "Changes",
          "body" => short(body["body"], @body_bytes) || default_body(workspace, task)
        }

        # The station pushes first, so the pull request it answers or opens holds all the Task's work.
        case StationTasks.ask(workspace.salix_group_id, task, "task.pull_request", params, 60_000) do
          {:ok, %{"url" => url} = pr} when is_binary(url) ->
            json(conn, 200, pr)

          {:ok, _} ->
            json(conn, 502, %{error: "pull_request_failed"})

          {:error, {:station, why}} ->
            json(conn, 422, %{error: "pull_request_failed", detail: why})

          # No sandbox runs to push and open it: the branch it pushed before stopping is opened on GitHub.
          {:error, _not_running} ->
            open_on_github(conn, workspace, conversation, params)
        end
      end
    end)
  end

  defp open_on_github(conn, workspace, conversation, params) do
    with {:ok, %{token: token}} <- github(workspace),
         {:ok, pr} <- open_or_create(token, conversation["repo"] || %{}, params) do
      json(conn, 200, pr)
    end
  end

  @doc """
  The coding Task's open pull request as GitHub reads it now: `{:ok, pull_request}`. A branch without one gets one,
  opened on GitHub from what the branch holds. Mini App Publish merges through it: a Mini App Task's agent pushes and
  deploys, and opens no pull request.
  """
  def ensure_pull_request(workspace, task) do
    with {:ok, conversation} <- coding_task(workspace, task),
         {:ok, %{token: token}} <- github(workspace),
         repo = conversation["repo"] || %{},
         {:ok, _pr} <-
           open_or_create(token, repo, %{
             "draft" => false,
             "title" =>
               short(conversation["title"], 256) || get_in(conversation, ["repo", "branch"]) ||
                 "Changes",
             "body" => default_body(workspace, task)
           }) do
      open_pull_request(token, repo)
    end
  end

  # The branch's open pull request, else a new one from the branch it pushed: `{:ok, %{url, number, title}}`.
  defp open_or_create(token, repo, params) do
    with {:ok, branch} <- branch(repo),
         {:ok, existing} <-
           github_client().pull_request(token, repo["owner"], repo["name"], branch) do
      case existing do
        # One open already: that is the branch's pull request, as the sandbox answers too.
        %{state: state, url: url, number: number} = pr when state in ["open", "draft"] ->
          {:ok, %{url: url, number: number, title: pr.title}}

        # Merged with all the branch holds (its own, or one it carries): a new one would propose it again.
        %{state: "merged", new_commits: false, number: number} ->
          {:error, {:conflict, "the branch's work is merged already, in ##{number}"}}

        _none ->
          github_client().create_pull_request(
            token,
            repo["owner"],
            repo["name"],
            %{
              "head" => branch,
              "base" => repo["base_ref"],
              "title" => params["title"],
              "body" => params["body"],
              "draft" => params["draft"]
            }
          )
      end
    end
  end

  def update_pull_request(conn, workspace_id, task) do
    with_workspace(conn, workspace_id, :write, fn workspace, _user ->
      body = conn.body_params || %{}

      changes =
        %{}
        |> put_present("title", short(body["title"], 256))
        |> put_present(
          "body",
          if(is_binary(body["body"]), do: short_or_empty(body["body"], @body_bytes))
        )

      with {:ok, conversation} <- coding_task(workspace, task),
           {:ok, %{token: token}} <- github(workspace),
           repo = conversation["repo"] || %{},
           {:ok, pr} <- open_pull_request(token, repo),
           :ok <-
             if(changes == %{},
               do: :ok,
               else:
                 github_client().update_pull_request(
                   token,
                   repo["owner"],
                   repo["name"],
                   pr.number,
                   changes
                 )
             ),
           :ok <-
             if(body["ready"] == true and pr.state == "draft",
               do:
                 github_client().ready_for_review(token, repo["owner"], repo["name"], pr.number),
               else: :ok
             ),
           {:ok, now} <-
             github_client().pull_request(token, repo["owner"], repo["name"], repo["branch"]) do
        json(conn, 200, %{pull_request: now})
      end
    end)
  end

  def merge_pull_request(conn, workspace_id, task) do
    with_workspace(conn, workspace_id, :write, fn workspace, _user ->
      with {:ok, number, head_sha} <- merge_target(conn.body_params || %{}),
           {:ok, merged} <- merge(workspace, task, number, head_sha) do
        json(conn, 200, merged)
      end
    end)
  end

  @doc """
  Merges the coding Task's open pull request `number` at `head_sha` (what a member confirmed): `{:ok, %{method,
  pull_request}}`. Refused when the branch's open pull request is another one, is a draft, or its head moved
  past `head_sha`. Mini App Publish merges through here too.
  """
  def merge(workspace, task, number, head_sha) do
    with {:ok, conversation} <- coding_task(workspace, task),
         {:ok, %{token: token}} <- github(workspace),
         repo = conversation["repo"] || %{},
         {:ok, pr} <- open_pull_request(token, repo),
         :ok <-
           if(pr.number == number,
             do: :ok,
             else:
               {:error, {:conflict, "the branch's open pull request is not the one confirmed"}}
           ),
         :ok <-
           if(pr.state == "draft",
             do:
               {:error,
                {:conflict, "a draft pull request is marked ready for review before it merges"}},
             else: :ok
           ),
         {:ok, method} <- github_client().merge_method(token, repo["owner"], repo["name"]),
         :ok <-
           github_client().merge_pull_request(
             token,
             repo["owner"],
             repo["name"],
             pr.number,
             method,
             head_sha
           ),
         {:ok, now} <-
           github_client().pull_request(token, repo["owner"], repo["name"], repo["branch"]) do
      {:ok, %{method: method, pull_request: now}}
    end
  end

  # What the member confirmed merging: the pull request by its number, at the head they saw. Commits pushed after it
  # (a Worker still in its turn) are not merged unseen: GitHub refuses a merge whose head moved.
  defp merge_target(%{"number" => number, "head_sha" => sha})
       when is_integer(number) and number > 0 and is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: {:ok, number, sha},
      else: {:error, {:bad_request, "head_sha is a full commit sha"}}
  end

  defp merge_target(_body),
    do: {:error, {:bad_request, "a merge names the pull request's number and head_sha"}}

  # The branch's pull request, open or a draft: what an edit or a merge acts on.
  defp open_pull_request(token, repo) do
    with {:ok, branch} <- branch(repo) do
      case github_client().pull_request(token, repo["owner"], repo["name"], branch) do
        {:ok, %{state: state} = pr} when state in ["open", "draft"] -> {:ok, pr}
        {:ok, _none_open} -> {:error, {:conflict, "the branch has no open pull request"}}
        error -> error
      end
    end
  end

  defp branch(%{"branch" => branch}) when is_binary(branch) and branch != "", do: {:ok, branch}
  defp branch(_repo), do: {:error, {:conflict, "the session has no branch yet"}}

  # What the Task was asked, as the pull request's description, and where it was made.
  defp default_body(workspace, task) do
    footer = "Opened from a Comma coding Task."

    request =
      case SalixIM.Conversations.get_group_conversation_with_messages(
             workspace.salix_group_id,
             task,
             after_seq: 0,
             limit: 1
           ) do
        {:ok, %{"messages" => [first | _]}} -> message_text(first)
        _ -> nil
      end

    if request, do: request <> "\n\n---\n" <> footer, else: footer
  end

  defp message_text(%{"content" => content}) when is_binary(content),
    do: message_text(%{"content" => [%{"type" => "text", "text" => content}]})

  defp message_text(%{"content" => content}) when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")
      |> String.trim()

    if text == "", do: nil, else: short(text, @body_bytes - 64)
  end

  defp message_text(_message), do: nil

  def terminal(conn, workspace_id, task) do
    with_workspace(conn, workspace_id, :write, fn workspace, _user ->
      with {:ok, _conversation} <- coding_task(workspace, task),
           %{url: url} <- SalixWeb.L4ES.config() || {:error, :sandbox_unavailable},
           {:ok, workload} <-
             SalixStore.CodingSandboxes.get_by_conversation(workspace.salix_tenant_id, task),
           %{"state" => "ready", "sandbox" => name} when is_binary(name) <-
             workload.spec || {:error, :sandbox_not_running} do
        sync_members(workspace)

        json(conn, 200, %{
          url:
            url <> "/t/" <> SalixWeb.L4ES.workspace_ref(workspace.salix_group_id) <> "/" <> name
        })
      else
        %{} -> json(conn, 409, %{error: "sandbox_not_running"})
        other -> other
      end
    end)
  end

  # A Workspace whose sandboxes all started before its members were synced
  # gets them now. Not synced, the member finds no workspace in L4ES: the
  # link is answered still, and the next sandbox syncs again.
  defp sync_members(workspace) do
    with {:ok, members} <-
           CommaWeb.Coding.Members.members(workspace.salix_tenant_id, workspace.salix_group_id),
         :ok <- SalixWeb.L4ES.set_members(workspace.salix_group_id, members) do
      :ok
    else
      error -> Logger.warning("coding terminal: members not synced: #{inspect(error)}")
    end
  end

  # --- Access

  defp with_workspace(conn, workspace_id, access, fun) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        case Comma.Stations.member(user, session, workspace_id) do
          {:ok, _workspace, "viewer"} when access == :write ->
            json(conn, 403, %{error: "forbidden"})

          {:ok, workspace, _role} ->
            case fun.(workspace, user) do
              %Plug.Conn{} = done -> done
              error -> error(conn, error)
            end

          {:error, :forbidden} ->
            json(conn, 403, %{error: "forbidden"})

          _ ->
            json(conn, 404, %{error: "not_found"})
        end

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp github(workspace),
    do: github_client().token(workspace.salix_tenant_id, workspace.salix_group_id)

  defp github_client, do: SalixWeb.CodingSandboxes.github()

  defp coding_task(workspace, task) do
    case SalixIM.Conversations.get_group_conversation(workspace.salix_group_id, task) do
      {:ok, %{"kind" => "agent_task", "runs_on" => %{"kind" => "sandbox"}} = conversation} ->
        {:ok, conversation}

      _ ->
        {:error, :not_found}
    end
  end

  # --- Input

  defp text(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, {:bad_request, "text is required"}}
      byte_size(text) > @text_bytes -> {:error, {:bad_request, "text is too long"}}
      true -> {:ok, text}
    end
  end

  defp text(_text), do: {:error, {:bad_request, "text is required"}}

  defp request_id(id) when is_binary(id) and byte_size(id) in 1..128, do: {:ok, id}
  defp request_id(_id), do: {:error, {:bad_request, "client_request_id is required"}}

  defp model(nil), do: {:ok, nil}

  defp model(%{"provider" => provider} = model) when provider in ~w(claude codex) do
    {:ok,
     %{"kind" => "runtime", "provider" => provider}
     |> put_present("model", short(model["model"], 256))
     |> put_present("reasoning_effort", short(model["effort"], 32))}
  end

  defp model(_model), do: {:error, {:bad_request, "model must name provider claude or codex"}}

  defp account(id) when is_binary(id) and byte_size(id) in 1..128, do: id
  defp account(_id), do: nil

  defp title(text) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()
    if String.length(line) <= 80, do: line, else: String.slice(line, 0, 79) <> "…"
  end

  defp page(conn) do
    case Integer.parse(conn.query_params["page"] || "1") do
      {n, ""} when n in 1..100 -> n
      _ -> 1
    end
  end

  # At most `max` bytes, cut at a character's end: a cut inside one leaves text JSON cannot carry.
  defp short(value, max) when is_binary(value) and value != "" do
    if byte_size(value) <= max do
      value
    else
      case :unicode.characters_to_binary(binary_part(value, 0, max)) do
        {:incomplete, whole, _cut} -> whole
        whole when is_binary(whole) -> whole
        {:error, whole, _invalid} -> whole
      end
    end
  end

  defp short(_value, _max), do: nil

  # A description may be cleared: an empty one stands.
  defp short_or_empty("", _max), do: ""
  defp short_or_empty(value, max), do: short(value, max)

  # --- Answers

  defp error(conn, {:error, {:bad_request, message}}),
    do: json(conn, 400, %{error: "bad_request", message: message})

  defp error(conn, {:error, :not_found}), do: json(conn, 404, %{error: "not_found"})

  defp error(conn, {:error, reason})
       when reason in [
              :github_not_connected,
              :github_reauthorization_required,
              :sandbox_unavailable,
              :sandbox_not_running
            ],
       do: json(conn, 409, %{error: to_string(reason)})

  defp error(conn, {:error, {:runs_on, _reason, _source} = refusal}),
    do: json(conn, 409, %{error: "refused", message: SalixIM.TaskPlacement.message(refusal)})

  defp error(conn, {:error, {:model, _reason} = refusal}),
    do: json(conn, 409, %{error: "refused", message: SalixIM.TaskPlacement.message(refusal)})

  defp error(conn, {:error, {:conflict, message}}),
    do: json(conn, 409, %{error: "conflict", message: message})

  # GitHub refused a change and said why (no commits, checks, reviews, conflicts): the member reads it as it is.
  defp error(conn, {:error, {:github, status, message}}),
    do: json(conn, 422, %{error: "github_refused", status: status, message: message})

  defp error(conn, {:error, {:github, status}}),
    do: json(conn, 502, %{error: "github_failed", status: status})

  defp error(conn, _error), do: json(conn, 503, %{error: "coding_unavailable"})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
