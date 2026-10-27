defmodule SalixWeb.GitHub do
  @moduledoc """
  The GitHub REST calls coding sessions make with their Group's connected
  GitHub account: the Group's managed OAuth binding (provider and alias
  `github`), whose token `Salix.Bindings.MCPCredentials` resolves and
  refreshes. Every call reads one page, with a 10-second budget.

  `config :salix_web, :github_http_options` merges into each request (tests
  point it at a stub).
  """

  require Logger

  @api "https://api.github.com"
  @timeout_ms 10_000
  @page 100

  @doc """
  The Group's GitHub token: `{:ok, %{token, expires_at}}` (`expires_at` in
  milliseconds, nil for a token that does not expire), or
  `:github_not_connected` / `:github_reauthorization_required`.
  """
  def token(tenant, group) do
    with {:ok, binding} <- github_binding(group),
         {:ok, %{"TOKEN" => token}} <-
           Salix.Bindings.MCPCredentials.resolve(%{
             "tenant_id" => tenant,
             "group_id" => group,
             "oauth_binding_refs" => %{
               "TOKEN" => %{
                 "binding_id" => binding["binding_id"],
                 "provider" => "github",
                 "credential" => "access_token"
               }
             }
           }) do
      {:ok, %{token: token, expires_at: expires_at(binding)}}
    else
      {:error, :github_not_connected} = error ->
        error

      {:error, {:missing_oauth, reason}} ->
        if reason |> to_string() |> String.contains?("authoriz"),
          do: {:error, :github_reauthorization_required},
          else: {:error, :github_not_connected}

      _ ->
        {:error, :github_not_connected}
    end
  end

  defp github_binding(group) do
    case Salix.Control.OAuthBindings.select_provider_record(group, "github", "github") do
      {:ok, %{"enabled" => false}} -> {:error, :github_not_connected}
      {:ok, binding} -> {:ok, binding}
      _ -> {:error, :github_not_connected}
    end
  end

  defp expires_at(%{"connection_id" => id}) when is_binary(id) do
    case SalixStore.OAuth.get(id) do
      {:ok, %{"expires_at" => at}} when is_integer(at) -> at
      _ -> nil
    end
  end

  defp expires_at(_binding), do: nil

  @doc "The account a token is for: `%{login, id, email}` (its no-reply address)."
  def user(token) do
    case get(token, "/user", []) do
      {:ok, %{"login" => login, "id" => id}} ->
        {:ok, %{login: login, id: id, email: "#{id}+#{login}@users.noreply.github.com"}}

      error ->
        error
    end
  end

  @doc "Repository `owner/name`: `%{full_name, default_branch, private, push}`."
  def repo(token, owner, name) do
    case get(token, "/repos/#{seg(owner)}/#{seg(name)}", []) do
      {:ok, %{"full_name" => full, "default_branch" => default} = repo} ->
        {:ok,
         %{
           full_name: full,
           default_branch: default,
           private: repo["private"] == true,
           push: get_in(repo, ["permissions", "push"]) == true
         }}

      {:error, {:github, 404}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @doc "One page (100) of the repositories the account can reach, recently pushed first."
  def repos(token, page \\ 1) do
    case get(token, "/user/repos", sort: "pushed", per_page: @page, page: max(page, 1)) do
      {:ok, repos} when is_list(repos) ->
        {:ok,
         Enum.flat_map(repos, fn
           %{"owner" => %{"login" => owner}, "name" => name} = r ->
             [
               %{
                 owner: owner,
                 name: name,
                 default_branch: r["default_branch"],
                 private: r["private"] == true,
                 pushed_at: r["pushed_at"]
               }
             ]

           _ ->
             []
         end)}

      {:ok, _} ->
        {:error, :github_unexpected}

      error ->
        error
    end
  end

  @doc "One page (100) of a repository's branch names."
  def branches(token, owner, name, page \\ 1) do
    case get(token, "/repos/#{seg(owner)}/#{seg(name)}/branches",
           per_page: @page,
           page: max(page, 1)
         ) do
      {:ok, branches} when is_list(branches) ->
        {:ok, for(%{"name" => b} <- branches, do: b)}

      {:error, {:github, 404}} ->
        {:error, :not_found}

      {:ok, _} ->
        {:error, :github_unexpected}

      error ->
        error
    end
  end

  @doc """
  The pushed branch's changes against `base`, for a session whose sandbox is
  gone: files (at most 300, as GitHub answers) with their patches, and the
  branch's commits past `base`, newest first (the first #{@page} GitHub lists).
  """
  def compare(token, owner, name, base, head) do
    path = "/repos/#{seg(owner)}/#{seg(name)}/compare/#{seg(base)}...#{seg(head)}"

    case get(token, path, per_page: @page) do
      {:ok, %{"files" => files} = c} when is_list(files) ->
        {:ok,
         %{
           ahead_by: c["ahead_by"],
           files: Enum.map(files, &file_change/1),
           commits: c |> Map.get("commits", []) |> Enum.map(&commit_entry/1) |> Enum.reverse()
         }}

      {:error, {:github, 404}} ->
        {:error, :not_found}

      {:ok, _} ->
        {:error, :github_unexpected}

      error ->
        error
    end
  end

  @doc """
  What one commit changed: its files (at most 300, as GitHub answers) with their patches.
  """
  def commit(token, owner, name, sha) do
    case get(token, "/repos/#{seg(owner)}/#{seg(name)}/commits/#{seg(sha)}", per_page: @page) do
      {:ok, %{"files" => files}} when is_list(files) ->
        {:ok, %{files: Enum.map(files, &file_change/1)}}

      {:error, {:github, status}} when status in [404, 422] ->
        {:error, :not_found}

      {:ok, _} ->
        {:error, :github_unexpected}

      error ->
        error
    end
  end

  defp file_change(f) do
    %{
      path: f["filename"],
      status: f["status"],
      additions: f["additions"],
      deletions: f["deletions"],
      patch: f["patch"]
    }
  end

  # A commit as Comma lists it: the full sha, the message's first line, its author's name, and when it was committed.
  defp commit_entry(c) do
    commit = c["commit"] || %{}
    message = commit["message"] || ""

    %{
      sha: c["sha"],
      title: message |> String.split("\n", parts: 2) |> hd(),
      author: get_in(commit, ["author", "name"]) || get_in(c, ["author", "login"]) || "",
      at: get_in(commit, ["committer", "date"]) || get_in(commit, ["author", "date"])
    }
  end

  @doc """
  The pull request of `branch` in the repository, the latest where it has had several, as GitHub has it: its url,
  number, title and description; the commit its head is at (`head_sha`), which a merge names; where it stands (`open`, `draft`, `merged`, `closed`); whether it merges cleanly
  (`mergeable`, `conflicting`, `unknown` until GitHub has computed it); its checks while open (`%{passed, failed,
  skipped, total}`: `skipped` counts the passed ones GitHub skipped, the rest of `total` still run; nil where it has
  none); and, once merged, whether the branch has commits made after
  its last one (`new_commits`), which a new pull request would propose. `{:ok, nil}` where the branch has none.

  Where no open pull request has `branch` as its head, one of another head whose head is the branch's last commit
  is the branch's, open or merged: a Task that continues a pull request works on its own branch, and that pull
  request proposes (or merged) what the branch holds. Two to six reads.
  """
  def pull_request(token, owner, name, branch) do
    listing = [
      head: "#{owner}:#{branch}",
      state: "all",
      sort: "created",
      direction: "desc",
      per_page: 1
    ]

    case get(token, pulls(owner, name), listing) do
      {:ok, [%{"number" => number} = listed | _]} when is_integer(number) ->
        # Its own pull request closed or merged: one it carries now is the branch's.
        if pull_request_state(listed) in ["open", "draft"] do
          pull_request_status(token, owner, name, branch, listed)
        else
          with {:ok, carried} <- carried_pull_request(token, owner, name, branch) do
            pull_request_status(token, owner, name, branch, carried || listed)
          end
        end

      {:ok, []} ->
        case carried_pull_request(token, owner, name, branch) do
          {:ok, %{} = carried} -> pull_request_status(token, owner, name, branch, carried)
          other -> other
        end

      {:error, {:github, 404}} ->
        {:ok, nil}

      {:ok, _} ->
        {:error, :github_unexpected}

      error ->
        error
    end
  end

  # A pull request of another head whose last commit is the branch's: it proposes exactly what the branch holds, or
  # merged it. An open one first: a merged one stays the branch's, so the branch is not proposed again. `{:ok, nil}`
  # where none does, or the branch is not pushed; an error where GitHub cannot say, so none is opened beside one.
  defp carried_pull_request(token, owner, name, branch) do
    repo = "/repos/#{seg(owner)}/#{seg(name)}"

    with {:ok, %{"commit" => %{"sha" => sha}}} when is_binary(sha) <-
           get(token, "#{repo}/branches/#{seg(branch)}", []),
         {:ok, pulls} when is_list(pulls) <-
           get(token, "#{repo}/commits/#{seg(sha)}/pulls", per_page: @page) do
      carried =
        Enum.filter(pulls, fn pr ->
          get_in(pr, ["head", "sha"]) == sha and get_in(pr, ["head", "ref"]) != branch
        end)

      {:ok,
       Enum.find(carried, &(pull_request_state(&1) in ["open", "draft"])) ||
         Enum.find(carried, &(pull_request_state(&1) == "merged"))}
    else
      {:error, {:github, status}} when status in [404, 422] -> {:ok, nil}
      {:ok, _} -> {:error, :github_unexpected}
      error -> error
    end
  end

  defp pull_request_status(token, owner, name, branch, listed) do
    state = pull_request_state(listed)

    # Only GitHub's own read of one pull request says whether it merges cleanly: an open one is read again.
    pr =
      if state in ["open", "draft"] do
        case get(token, "#{pulls(owner, name)}/#{listed["number"]}", []) do
          {:ok, %{"number" => _} = detail} -> detail
          _ -> listed
        end
      else
        listed
      end

    head = get_in(pr, ["head", "sha"])

    {:ok,
     %{
       url: pr["html_url"],
       number: pr["number"],
       title: pr["title"],
       body: pr["body"],
       head_sha: head,
       state: state,
       mergeable: pull_request_mergeable(pr),
       checks: if(state in ["open", "draft"], do: check_counts(token, owner, name, head)),
       new_commits: state == "merged" and new_commits?(token, owner, name, branch, head)
     }}
  end

  defp pull_request_state(%{"merged" => true}), do: "merged"
  defp pull_request_state(%{"merged_at" => at}) when is_binary(at), do: "merged"
  defp pull_request_state(%{"state" => "closed"}), do: "closed"
  defp pull_request_state(%{"draft" => true}), do: "draft"
  defp pull_request_state(_pr), do: "open"

  # GitHub computes mergeability after the fact: nil until it has.
  defp pull_request_mergeable(%{"mergeable" => true}), do: "mergeable"
  defp pull_request_mergeable(%{"mergeable" => false}), do: "conflicting"
  defp pull_request_mergeable(_pr), do: "unknown"

  # A commit's check runs (the latest of each) and commit statuses. A run GitHub counts as passed (success, neutral,
  # skipped) passed, and the skipped ones are counted again on their own; one that ended any other way failed, the
  # rest still run. Nil where it has none, or they cannot be read.
  defp check_counts(token, owner, name, sha) when is_binary(sha) do
    commit = "/repos/#{seg(owner)}/#{seg(name)}/commits/#{seg(sha)}"

    with {:ok, %{"check_runs" => runs}} when is_list(runs) <-
           get(token, commit <> "/check-runs", per_page: @page),
         {:ok, %{"statuses" => statuses}} when is_list(statuses) <-
           get(token, commit <> "/status", per_page: @page) do
      outcomes = Enum.map(runs, &run_outcome/1) ++ Enum.map(statuses, &status_outcome/1)

      if outcomes == [] do
        nil
      else
        %{
          passed: Enum.count(outcomes, &(&1 == :passed)),
          failed: Enum.count(outcomes, &(&1 == :failed)),
          skipped: Enum.count(runs, &match?(%{"conclusion" => "skipped"}, &1)),
          total: length(outcomes)
        }
      end
    else
      _ -> nil
    end
  end

  defp check_counts(_token, _owner, _name, _sha), do: nil

  defp run_outcome(%{"conclusion" => c}) when c in ["success", "neutral", "skipped"], do: :passed
  defp run_outcome(%{"conclusion" => c}) when is_binary(c) and c != "", do: :failed
  defp run_outcome(_run), do: :pending

  defp status_outcome(%{"state" => "success"}), do: :passed
  defp status_outcome(%{"state" => state}) when state in ["failure", "error"], do: :failed
  defp status_outcome(_status), do: :pending

  # The branch moved past the merged pull request's last commit: there is work it does not have.
  defp new_commits?(token, owner, name, branch, head) when is_binary(head) do
    case get(token, "/repos/#{seg(owner)}/#{seg(name)}/branches/#{seg(branch)}", []) do
      {:ok, %{"commit" => %{"sha" => sha}}} when is_binary(sha) -> sha != head
      _ -> false
    end
  end

  defp new_commits?(_token, _owner, _name, _branch, _head), do: false

  @doc """
  Where pull request `number` stands and its branches: `{:ok, %{state, head_ref, head_repo, base_ref}}`, `head_repo`
  the `owner/name` its head branch is in (nil where that repository is gone), or `{:error, :not_found}`.
  """
  def pull_request_refs(token, owner, name, number) do
    case get(token, "#{pulls(owner, name)}/#{seg(number)}", []) do
      {:ok, %{"head" => %{"ref" => head}, "base" => %{"ref" => base}} = pr}
      when is_binary(head) and is_binary(base) ->
        {:ok,
         %{
           state: pull_request_state(pr),
           head_ref: head,
           head_repo: get_in(pr, ["head", "repo", "full_name"]),
           base_ref: base
         }}

      {:error, {:github, 404}} ->
        {:error, :not_found}

      {:ok, _} ->
        {:error, :github_unexpected}

      error ->
        error
    end
  end

  @doc """
  Opens a pull request of `head` into `base`: `{:ok, %{url, number, title}}`, or `{:error, {:github, status,
  message}}` with what GitHub says (no commits between them, one open already, …).
  """
  def create_pull_request(token, owner, name, %{} = pr) do
    body = Map.take(pr, ["head", "base", "title", "body", "draft"])

    case send_json(:post, token, pulls(owner, name), body) do
      {:ok, %{"html_url" => url, "number" => number} = made} when is_binary(url) ->
        {:ok, %{url: url, number: number, title: made["title"]}}

      {:ok, _} ->
        {:error, :github_unexpected}

      error ->
        error
    end
  end

  @doc "Changes pull request `number`'s `title` and `body`, those given."
  def update_pull_request(token, owner, name, number, %{} = changes) do
    case send_json(
           :patch,
           token,
           "#{pulls(owner, name)}/#{number}",
           Map.take(changes, ["title", "body"])
         ) do
      {:ok, %{"number" => _}} -> :ok
      {:ok, _} -> {:error, :github_unexpected}
      error -> error
    end
  end

  @ready_for_review """
  mutation($id: ID!) {
    markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } }
  }
  """

  @doc "Marks draft pull request `number` ready for review: GitHub does it in GraphQL only."
  def ready_for_review(token, owner, name, number) do
    with {:ok, %{"node_id" => id}} when is_binary(id) <-
           get(token, "#{pulls(owner, name)}/#{number}", []),
         {:ok, %{"data" => %{"markPullRequestReadyForReview" => %{}}}} <-
           send_json(:post, token, "/graphql", %{
             "query" => @ready_for_review,
             "variables" => %{"id" => id}
           }) do
      :ok
    else
      {:ok, %{"errors" => [%{"message" => message} | _]}} -> {:error, {:github, 422, message}}
      {:ok, _} -> {:error, :github_unexpected}
      error -> error
    end
  end

  @doc """
  How the repository lets pull requests merge, the first it allows of squash, merge commit and rebase; a merge
  commit where it does not say.
  """
  def merge_method(token, owner, name) do
    case get(token, "/repos/#{seg(owner)}/#{seg(name)}", []) do
      {:ok, %{} = repo} ->
        {:ok,
         cond do
           repo["allow_squash_merge"] == true -> "squash"
           repo["allow_merge_commit"] == true -> "merge"
           repo["allow_rebase_merge"] == true -> "rebase"
           true -> "merge"
         end}

      {:error, {:github, 404}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @doc """
  Merges pull request `number` by `method`, only while its head is at `sha`: GitHub refuses it once the branch moved.
  GitHub's refusal (checks, reviews, conflicts, a moved head) comes back as it says it.
  """
  def merge_pull_request(token, owner, name, number, method, sha) do
    case send_json(:put, token, "#{pulls(owner, name)}/#{number}/merge", %{
           "merge_method" => method,
           "sha" => sha
         }) do
      {:ok, %{"merged" => true}} -> :ok
      {:ok, %{"message" => message}} when is_binary(message) -> {:error, {:github, 405, message}}
      {:ok, _} -> {:error, :github_unexpected}
      error -> error
    end
  end

  @doc """
  Whether commit `sha` is on `branch` (the branch's head or one of its ancestors): `:ok`, or
  `{:error, :commit_not_on_branch}`. One compare read.
  """
  def commit_on_branch(token, owner, name, sha, branch) do
    path = "/repos/#{seg(owner)}/#{seg(name)}/compare/#{seg(sha)}...#{seg(branch)}"

    case get(token, path, per_page: 1) do
      {:ok, %{"status" => status}} when status in ["ahead", "identical"] -> :ok
      {:ok, %{"status" => _diverged_or_behind}} -> {:error, :commit_not_on_branch}
      {:error, {:github, status}} when status in [404, 422] -> {:error, :commit_not_on_branch}
      {:ok, _} -> {:error, :github_unexpected}
      error -> error
    end
  end

  @doc """
  Makes repository `owner/name`, private, from the template repository `template` (`"owner/name"`), with only its
  default branch: `{:ok, %{owner, name, default_branch}}`. `owner` is the token's account.
  """
  def generate_from_template(token, template, owner, name) do
    with [template_owner, template_name] <- String.split(template, "/", parts: 2),
         {:ok, %{"name" => made, "owner" => %{"login" => login}} = repo} <-
           send_json(
             :post,
             token,
             "/repos/#{seg(template_owner)}/#{seg(template_name)}/generate",
             %{
               "owner" => owner,
               "name" => name,
               "private" => true,
               "include_all_branches" => false
             }
           ) do
      {:ok, %{owner: login, name: made, default_branch: repo["default_branch"] || "main"}}
    else
      {:ok, _} -> {:error, :github_unexpected}
      [_] -> {:error, :invalid_template}
      error -> error
    end
  end

  @doc "Whether `path` exists in the repository at its default branch: `:ok` or `{:error, :not_found}`."
  def file_exists(token, owner, name, path) do
    case get(token, "/repos/#{seg(owner)}/#{seg(name)}/contents/#{path_segs(path)}", []) do
      {:ok, %{"type" => "file"}} -> :ok
      {:ok, _} -> {:error, :not_found}
      {:error, {:github, 404}} -> {:error, :not_found}
      error -> error
    end
  end

  @max_push_files 500
  @max_push_bytes 20 * 1024 * 1024

  @doc """
  Makes a private repository `name` in the token's account and commits `files` (`[{path, content, executable?}]`,
  at most #{@max_push_files} files and 20 MiB) as one commit on branch `main`, its default branch, through the Git
  Data API (blobs, tree, commit, ref): `{:ok, %{owner, name, default_branch: "main"}}`.
  """
  def create_repo_with_files(token, name, files, message) when is_list(files) do
    total = files |> Enum.map(fn {_path, content, _exec} -> byte_size(content) end) |> Enum.sum()

    cond do
      length(files) > @max_push_files ->
        {:error, {:too_large, "the source has more than #{@max_push_files} files"}}

      total > @max_push_bytes ->
        {:error, {:too_large, "the source is larger than 20 MiB"}}

      true ->
        with {:ok, %{"name" => made, "owner" => %{"login" => owner}} = repo} <-
               send_json(:post, token, "/user/repos", %{
                 "name" => name,
                 "private" => true,
                 "auto_init" => true
               }),
             default = repo["default_branch"] || "main",
             git = "/repos/#{seg(owner)}/#{seg(made)}/git",
             {:ok, %{"object" => %{"sha" => parent}}} <-
               get(token, "#{git}/ref/heads/#{seg(default)}", []),
             {:ok, tree} <- push_tree(token, git, files),
             {:ok, %{"sha" => commit}} <-
               send_json(:post, token, "#{git}/commits", %{
                 "message" => message,
                 "tree" => tree,
                 "parents" => [parent]
               }),
             :ok <- point_main(token, owner, made, git, default, commit) do
          {:ok, %{owner: owner, name: made, default_branch: "main"}}
        else
          {:ok, _} -> {:error, :github_unexpected}
          error -> error
        end
    end
  end

  defp push_tree(token, git, files) do
    files
    |> Enum.reduce_while({:ok, []}, fn {path, content, executable?}, {:ok, entries} ->
      case send_json(:post, token, "#{git}/blobs", %{
             "content" => Base.encode64(content),
             "encoding" => "base64"
           }) do
        {:ok, %{"sha" => sha}} ->
          mode = if executable?, do: "100755", else: "100644"

          {:cont,
           {:ok, [%{"path" => path, "mode" => mode, "type" => "blob", "sha" => sha} | entries]}}

        {:ok, _} ->
          {:halt, {:error, :github_unexpected}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        case send_json(:post, token, "#{git}/trees", %{"tree" => Enum.reverse(entries)}) do
          {:ok, %{"sha" => tree}} -> {:ok, tree}
          {:ok, _} -> {:error, :github_unexpected}
          error -> error
        end

      error ->
        error
    end
  end

  # The commit goes on `main`, the repository's default branch: where the account names another default, `main` is
  # made and becomes the default.
  defp point_main(token, _owner, _name, git, "main", commit) do
    case send_json(:patch, token, "#{git}/refs/heads/main", %{"sha" => commit, "force" => true}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp point_main(token, owner, name, git, _other, commit) do
    with {:ok, _} <-
           send_json(:post, token, "#{git}/refs", %{"ref" => "refs/heads/main", "sha" => commit}),
         {:ok, _} <-
           send_json(:patch, token, "/repos/#{seg(owner)}/#{seg(name)}", %{
             "default_branch" => "main"
           }) do
      :ok
    end
  end

  defp path_segs(path), do: path |> String.split("/") |> Enum.map_join("/", &seg/1)

  defp pulls(owner, name), do: "/repos/#{seg(owner)}/#{seg(name)}/pulls"

  defp get(token, path, params) do
    [
      method: :get,
      url: @api <> path,
      params: params,
      auth: {:bearer, token},
      headers: [
        {"user-agent", "Comma"},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"}
      ],
      retry: false,
      redirect: false,
      receive_timeout: @timeout_ms,
      pool_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms]
    ]
    |> Keyword.merge(SystemsRuntime.get_env(:salix_web, :github_http_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :github_reauthorization_required}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:github, status}}

      {:error, reason} ->
        Logger.warning("github: GET failed: #{Exception.message(reason)}")
        {:error, :github_unavailable}
    end
  end

  # A write: its answer on 200 or 201, else what GitHub says went wrong (`{:github, status, message}`).
  defp send_json(method, token, path, body) do
    [
      method: method,
      url: @api <> path,
      json: body,
      auth: {:bearer, token},
      headers: [
        {"user-agent", "Comma"},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"}
      ],
      retry: false,
      redirect: false,
      receive_timeout: @timeout_ms,
      pool_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms]
    ]
    |> Keyword.merge(SystemsRuntime.get_env(:salix_web, :github_http_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :github_reauthorization_required}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github, status, github_message(body)}}

      {:error, reason} ->
        Logger.warning("github: #{method} failed: #{Exception.message(reason)}")
        {:error, :github_unavailable}
    end
  end

  # GitHub's own words for a refused write: its message, and the first of the errors it lists.
  defp github_message(%{"message" => message} = body) when is_binary(message) do
    case body["errors"] do
      [%{"message" => detail} | _] when is_binary(detail) -> message <> ": " <> detail
      _ -> message
    end
  end

  defp github_message(_body), do: "GitHub refused the change"

  defp seg(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
