defmodule SalixWeb.GitHubPullRequestTest do
  use ExUnit.Case, async: false

  alias SalixWeb.GitHub

  # GitHub's REST answers by method and path; each request is recorded for the test to read.
  defp stub(routes) do
    test = self()

    SystemsRuntime.put_env(:salix_web, :github_http_options,
      plug: fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = if raw == "", do: nil, else: Jason.decode!(raw)
        send(test, {:github, conn.method, conn.request_path, body})

        {status, answer} =
          Map.get(routes, {conn.method, conn.request_path}, {404, %{"message" => "Not Found"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(answer))
      end
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :github_http_options) end)
  end

  @pulls "/repos/acme/api/pulls"
  @commit "/repos/acme/api/commits/sha-head"

  defp listed(attrs),
    do:
      Map.merge(
        %{
          "number" => 12,
          "html_url" => "https://github.com/acme/api/pull/12",
          "title" => "Back off",
          "body" => "Make it back off",
          "state" => "open",
          "draft" => false,
          "merged_at" => nil,
          "head" => %{"sha" => "sha-head"}
        },
        attrs
      )

  test "an open pull request with its mergeability and checks: passed, failed, skipped, and the rest still running" do
    stub(%{
      {"GET", @pulls} => {200, [listed(%{})]},
      {"GET", @pulls <> "/12"} => {200, listed(%{"mergeable" => false})},
      {"GET", @commit <> "/check-runs"} =>
        {200,
         %{
           "check_runs" => [
             %{"status" => "completed", "conclusion" => "success"},
             %{"status" => "completed", "conclusion" => "skipped"},
             %{"status" => "completed", "conclusion" => "timed_out"},
             %{"status" => "in_progress", "conclusion" => nil}
           ]
         }},
      {"GET", @commit <> "/status"} =>
        {200, %{"statuses" => [%{"state" => "error"}, %{"state" => "pending"}]}}
    })

    assert {:ok, pr} = GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")

    assert pr == %{
             url: "https://github.com/acme/api/pull/12",
             number: 12,
             title: "Back off",
             body: "Make it back off",
             head_sha: "sha-head",
             state: "open",
             mergeable: "conflicting",
             checks: %{passed: 2, failed: 2, skipped: 1, total: 6},
             new_commits: false
           }

    assert_received {:github, "GET", @pulls, nil}
  end

  test "a merged pull request says whether the branch has moved past it, and reads no checks" do
    merged = listed(%{"state" => "closed", "merged_at" => "2026-10-23T10:00:00Z"})

    stub(%{
      {"GET", @pulls} => {200, [merged]},
      {"GET", "/repos/acme/api/branches/comma%2Fretry"} =>
        {200, %{"commit" => %{"sha" => "sha-later"}}}
    })

    assert {:ok, %{state: "merged", checks: nil, new_commits: true, mergeable: "unknown"}} =
             GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")

    refute_received {:github, "GET", @commit <> "/check-runs", _}

    stub(%{
      {"GET", @pulls} => {200, [merged]},
      {"GET", "/repos/acme/api/branches/comma%2Fretry"} =>
        {200, %{"commit" => %{"sha" => "sha-head"}}}
    })

    assert {:ok, %{state: "merged", new_commits: false}} =
             GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")
  end

  test "a branch with no pull request has none" do
    stub(%{{"GET", @pulls} => {200, []}})
    assert {:ok, nil} = GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")
  end

  test "a branch that carries another open pull request's last commit has that one as its pull request" do
    # A Task asked to continue #51 works on its own branch, which now ends where #51's head does.
    carried =
      listed(%{
        "number" => 51,
        "html_url" => "https://github.com/acme/api/pull/51",
        "title" => "Cards in the chat",
        "head" => %{"sha" => "sha-head", "ref" => "claude/cards"}
      })

    routes = %{
      {"GET", @pulls} => {200, []},
      {"GET", "/repos/acme/api/branches/comma%2Fretry"} =>
        {200, %{"commit" => %{"sha" => "sha-head"}}},
      {"GET", @commit <> "/pulls"} => {200, [carried]},
      {"GET", @pulls <> "/51"} => {200, Map.put(carried, "mergeable", true)}
    }

    stub(routes)

    assert {:ok, %{number: 51, state: "open", mergeable: "mergeable"}} =
             GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")

    # The branch's own pull request, closed (a duplicate of #51), gives way to the open one.
    stub(
      Map.put(routes, {"GET", @pulls}, {200, [listed(%{"number" => 57, "state" => "closed"})]})
    )

    assert {:ok, %{number: 51, state: "open"}} =
             GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")

    # Merged, it stays the branch's: with nothing after it, there is no new pull request to make.
    merged = Map.merge(carried, %{"state" => "closed", "merged_at" => "2026-10-23T10:00:00Z"})

    stub(Map.put(routes, {"GET", @commit <> "/pulls"}, {200, [merged]}))

    assert {:ok, %{number: 51, state: "merged", new_commits: false}} =
             GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")

    # A pull request the branch has moved past, or one closed unmerged, proposes less than the branch holds: none is its.
    stub(
      Map.merge(routes, %{
        {"GET", "/repos/acme/api/branches/comma%2Fretry"} =>
          {200, %{"commit" => %{"sha" => "sha-later"}}},
        {"GET", "/repos/acme/api/commits/sha-later/pulls"} =>
          {200, [put_in(carried, ["head", "sha"], "sha-head")]}
      })
    )

    assert {:ok, nil} = GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")

    stub(
      Map.put(routes, {"GET", @commit <> "/pulls"}, {200, [Map.put(carried, "state", "closed")]})
    )

    assert {:ok, nil} = GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")

    # Where GitHub cannot say which pull requests carry the commit, neither can this: an answer of none would let a
    # second one be opened.
    stub(Map.put(routes, {"GET", @commit <> "/pulls"}, {500, %{"message" => "Server Error"}}))

    assert {:error, _} = GitHub.pull_request("ghu_x", "acme", "api", "comma/retry")
  end

  test "a pull request is opened, edited and made ready; a refusal keeps GitHub's words" do
    stub(%{
      {"POST", @pulls} =>
        {201,
         %{
           "html_url" => "https://github.com/acme/api/pull/13",
           "number" => 13,
           "title" => "Back off"
         }},
      {"PATCH", @pulls <> "/13"} => {200, %{"number" => 13}},
      {"GET", @pulls <> "/13"} => {200, %{"number" => 13, "node_id" => "PR_node"}},
      {"POST", "/graphql"} =>
        {200,
         %{
           "data" => %{
             "markPullRequestReadyForReview" => %{"pullRequest" => %{"isDraft" => false}}
           }
         }}
    })

    attrs = %{
      "head" => "comma/retry",
      "base" => "main",
      "title" => "Back off",
      "body" => "Why",
      "draft" => true
    }

    assert {:ok, %{url: "https://github.com/acme/api/pull/13", number: 13, title: "Back off"}} =
             GitHub.create_pull_request("ghu_x", "acme", "api", attrs)

    assert_received {:github, "POST", @pulls, ^attrs}

    assert :ok =
             GitHub.update_pull_request("ghu_x", "acme", "api", 13, %{
               "title" => "Faster",
               "body" => ""
             })

    assert_received {:github, "PATCH", "/repos/acme/api/pulls/13",
                     %{"title" => "Faster", "body" => ""}}

    assert :ok = GitHub.ready_for_review("ghu_x", "acme", "api", 13)
    assert_received {:github, "POST", "/graphql", %{"variables" => %{"id" => "PR_node"}}}

    stub(%{
      {"POST", @pulls} =>
        {422,
         %{
           "message" => "Validation Failed",
           "errors" => [%{"message" => "No commits between main and comma/retry"}]
         }}
    })

    assert {:error, {:github, 422, "Validation Failed: No commits between main and comma/retry"}} =
             GitHub.create_pull_request("ghu_x", "acme", "api", attrs)
  end

  test "a merge goes the first way the repository allows, and a refused one says why" do
    stub(%{
      {"GET", "/repos/acme/api"} =>
        {200,
         %{
           "allow_squash_merge" => false,
           "allow_merge_commit" => true,
           "allow_rebase_merge" => true
         }},
      {"PUT", @pulls <> "/12/merge"} => {200, %{"merged" => true, "sha" => "sha-merge"}}
    })

    assert {:ok, "merge"} = GitHub.merge_method("ghu_x", "acme", "api")
    assert :ok = GitHub.merge_pull_request("ghu_x", "acme", "api", 12, "merge", "sha-head")

    # The merge names the head it was asked for: GitHub refuses it once the branch moved.
    assert_received {:github, "PUT", "/repos/acme/api/pulls/12/merge",
                     %{"merge_method" => "merge", "sha" => "sha-head"}}

    stub(%{
      {"PUT", @pulls <> "/12/merge"} =>
        {405, %{"message" => "Required status check \"ci\" is expected."}}
    })

    assert {:error, {:github, 405, "Required status check \"ci\" is expected."}} =
             GitHub.merge_pull_request("ghu_x", "acme", "api", 12, "squash", "sha-head")
  end

  test "a compare lists the branch's commits newest first, by their first line, and a commit reads its files" do
    stub(%{
      {"GET", "/repos/acme/api/compare/main...comma%2Fretry"} =>
        {200,
         %{
           "ahead_by" => 2,
           "files" => [],
           "commits" => [
             %{
               "sha" => "a1",
               "commit" => %{
                 "message" => "Back off\n\nWith jitter",
                 "author" => %{"name" => "Ann"},
                 "committer" => %{"date" => "2026-10-23T10:00:00Z"}
               }
             },
             %{
               "sha" => "b2",
               "author" => %{"login" => "bot"},
               "commit" => %{
                 "message" => "Test it",
                 "committer" => %{"date" => "2026-10-23T11:00:00Z"}
               }
             }
           ]
         }},
      {"GET", "/repos/acme/api/commits/a1"} =>
        {200,
         %{
           "files" => [
             %{
               "filename" => "retry.ex",
               "status" => "modified",
               "additions" => 1,
               "deletions" => 0
             }
           ]
         }}
    })

    assert {:ok, %{commits: commits}} = GitHub.compare("t", "acme", "api", "main", "comma/retry")

    assert commits == [
             %{sha: "b2", title: "Test it", author: "bot", at: "2026-10-23T11:00:00Z"},
             %{sha: "a1", title: "Back off", author: "Ann", at: "2026-10-23T10:00:00Z"}
           ]

    assert {:ok, %{files: [%{path: "retry.ex", additions: 1}]}} =
             GitHub.commit("t", "acme", "api", "a1")

    assert {:error, :not_found} = GitHub.commit("t", "acme", "api", "zz")
  end
end
