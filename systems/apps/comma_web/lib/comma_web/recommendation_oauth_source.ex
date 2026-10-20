defmodule CommaWeb.RecommendationOAuthSource do
  @moduledoc false

  alias CommaWeb.{RecommendationMemberRead, RecommendationSourceQuote}
  alias Salix.Control.OAuthBindings

  @managed_toolkits CommaWeb.RecommendationPreviewCatalog.managed_toolkits()

  # Bounded reads: the existing resolver owns authorization and refresh,
  # and Req owns HTTP/JSON. Official provider SDKs target other languages;
  # keep the Elixir REST/GraphQL adapter isolated and test it through Req.Test.
  def read(workspace, source) do
    with {:ok, token} <- token(workspace, source) do
      request(source["appId"], token)
    end
  end

  @doc """
  The Group's current access token for a managed OAuth source. The binding
  must be the provider's own alias in this Group; the resolver owns refresh.
  """
  def token(workspace, source) do
    provider = source["appId"]
    tenant = workspace["salix_tenant_id"]
    group = workspace["default_group_id"]

    with true <- provider in @managed_toolkits,
         {:ok, binding} <- OAuthBindings.get(group, source["connectionId"]),
         true <- binding["provider"] == provider and binding["alias"] == provider,
         {:ok, %{"TOKEN" => token}} <-
           Salix.Bindings.MCPCredentials.resolve(%{
             "tenant_id" => tenant,
             "group_id" => group,
             "oauth_binding_refs" => %{
               "TOKEN" => %{
                 "binding_id" => binding["binding_id"],
                 "provider" => provider,
                 "credential" => "access_token"
               }
             }
           }) do
      {:ok, token}
    else
      _ -> {:error, :oauth_source_unavailable}
    end
  end

  # A preview is a requester-scoped read, not a group-source collection.
  # Resolve the owner's binding before and after the fixed GitHub requests so
  # a disconnect, rebind or changed owner cannot publish the fetched result.
  def preview_github_pull_request(workspace, user_id, source, owner, repo, number)
      when is_binary(user_id) and is_binary(owner) and is_binary(repo) and
             is_integer(number) and number > 0 do
    with true <- source["kind"] == "managed_oauth" and source["appId"] == "github",
         {:ok, identity} <-
           CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source),
         {:ok, token} <- member_token(workspace, identity, "github"),
         {:ok, %{"id" => id}} <-
           request("github_user", token, {:get, "https://api.github.com/user", []}),
         true <- Integer.to_string(id) == identity["provider_user_id"],
         {:ok, data} <-
           request("github_pull_request", token, {
             :get,
             "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}",
             []
           }),
         {:ok, ^identity} <-
           CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source) do
      {:ok, data}
    else
      false -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  def preview_github_pull_request(_, _, _, _, _, _), do: {:error, :not_found}

  # A single authorization envelope for managed previews: resolve the Comma
  # member and pinned credential, read only a parsed fixed provider endpoint,
  # then re-resolve the binding before releasing any returned content.
  def preview_managed(workspace, user_id, source, target)
      when is_binary(user_id) and is_map(source) do
    provider = source["appId"]

    with true <-
           source["kind"] == "managed_oauth" and
             CommaWeb.RecommendationPreviewCatalog.managed?(provider),
         {:ok, identity} <-
           CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source),
         {:ok, token} <- member_token(workspace, identity, provider),
         {:ok, data} <- preview_request(provider, token, identity, target),
         {:ok, ^identity} <-
           CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source) do
      {:ok, data}
    else
      _ -> {:error, :not_found}
    end
  end

  def preview_managed(_, _, _, _), do: {:error, :not_found}

  @preview_linear_query """
  query CommaPreviewIssue($identifier: String!) {
    viewer { id }
    organization { id }
    issue(id: $identifier) {
      identifier title url priority priorityLabel updatedAt
      state { name type color }
      assignee { name displayName avatarUrl }
      team { key }
      project { name }
    }
  }
  """

  defp preview_request("linear", token, identity, {:linear_issue, identifier}) do
    with {:ok, data} <-
           request(
             "linear",
             token,
             {:post, "https://api.linear.app/graphql",
              [
                json: %{
                  "query" => @preview_linear_query,
                  "variables" => %{"identifier" => identifier}
                }
              ]}
           ),
         %{"id" => viewer} <- data["viewer"],
         %{"id" => organization} <- data["organization"],
         true <-
           viewer == identity["provider_user_id"] and
             organization == identity["provider_workspace_id"],
         %{"identifier" => ^identifier, "title" => title} = issue <- data["issue"],
         true <- is_binary(title) and String.trim(title) != "" do
      {:ok, issue}
    else
      _ -> {:error, :not_found}
    end
  end

  defp preview_request("notion", token, _identity, {:notion_page, uuid}) do
    # Notion's pages.retrieve enforces the integration's share/visibility ACL.
    # The token is tied to the exact member-bound connection, not a page URL.
    with true <- Regex.match?(~r/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/, uuid),
         {:ok, %{"object" => "page", "id" => ^uuid} = page} <-
           request(
             "notion_page",
             token,
             {:get, "https://api.notion.com/v1/pages/" <> uuid,
              [headers: [{"notion-version", "2022-06-28"}]]}
           ) do
      {:ok, page}
    else
      _ -> {:error, :not_found}
    end
  end

  defp preview_request(_, _, _, _), do: {:error, :not_found}

  @member_linear_query """
  query CommaMemberIssues {
    organization { id }
    viewer {
      id
      assignedIssues(first: 40, orderBy: updatedAt,
        filter: { completedAt: { null: true }, canceledAt: { null: true } }) {
        nodes {
          id identifier title url priority dueDate updatedAt description
          state { name type }
          assignee { id }
        }
      }
    }
    notifications(first: 50) {
      nodes {
        type createdAt archivedAt
        ... on IssueNotification {
          issue { id identifier title url description state { name type } }
          comment { id body url user { name } }
        }
      }
    }
  }
  """

  # The member's Linear inbox. An archived notification is done.
  @linear_mentions ~w(issueMention issueCommentMention)
  @recent_seconds 7 * 86_400

  @member_github_authored_query """
  query CommaMemberPullRequests($query: String!) {
    search(query: $query, type: ISSUE, first: 20) {
      nodes {
        ... on PullRequest {
          databaseId number title url state isDraft updatedAt reviewDecision
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
      }
    }
  }
  """

  # Bounded self-scoped reads, not a global first page filtered afterward.
  # The runtime will pass the returned subject through publication fencing.
  def read_member(workspace, user_id, source, deadline \\ RecommendationMemberRead.deadline())

  def read_member(workspace, user_id, %{"appId" => provider} = source, deadline)
      when provider in @managed_toolkits do
    with {:ok, identity} <-
           CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source),
         {:ok, token} <- member_token(workspace, identity, provider),
         # Each request ends by the source deadline, so a slow one cannot
         # consume the read that the others completed.
         http = fn kind, spec ->
           RecommendationMemberRead.request(deadline, fn -> request(kind, token, spec) end)
         end,
         {:ok, selected} <- member_request(provider, http, identity, source),
         {:ok, ^identity} <-
           CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source) do
      {:ok, selected, identity}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_source_changed}
    end
  end

  def read_member(_workspace, _user_id, _source, _deadline),
    do: {:error, :member_source_unsupported}

  @doc """
  One GET of a GitHub or Slack API URL with the member's managed grant of
  `source`, bounded like a member read. The proactive check reads the current
  state of a matter's links this way (`CommaWeb.ProactiveEvidence`).
  """
  def member_get(
        workspace,
        user_id,
        %{"appId" => provider} = source,
        url,
        deadline \\ RecommendationMemberRead.deadline()
      )
      when provider in ~w(github slack) do
    with {:ok, identity} <-
           CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source),
         {:ok, token} <- member_token(workspace, identity, provider) do
      kind = if provider == "github", do: "github_object", else: provider

      RecommendationMemberRead.request(deadline, fn ->
        request(kind, token, {:get, url, []})
      end)
    end
  end

  @doc """
  The member's own Slack messages through the source's managed grant, as
  `CommaWeb.RecommendationSlackMemberSource.own_messages/3` reads them.
  """
  def own_slack_messages(
        workspace,
        user_id,
        %{"appId" => "slack"} = source,
        deadline \\ RecommendationMemberRead.deadline()
      ) do
    with {:ok, identity} <-
           CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source),
         {:ok, token} <- member_token(workspace, identity, "slack") do
      CommaWeb.RecommendationSlackMemberSource.own_messages(
        fn "GET", url, options ->
          RecommendationMemberRead.request(deadline, fn ->
            request("slack", token, {:get, url, options})
          end)
        end,
        SystemsClock.utc_now(),
        Map.take(identity, ~w(provider_user_id provider_workspace_id))
      )
    end
  end

  defp member_token(workspace, identity, provider) do
    case Salix.Bindings.MCPCredentials.resolve(%{
           "tenant_id" => workspace["salix_tenant_id"],
           "group_id" => workspace["default_group_id"],
           "oauth_binding_refs" => %{
             "TOKEN" => %{
               "binding_id" => identity["binding_id"],
               "expected_connection_id" => identity["connection_id"],
               "provider" => provider,
               "credential" => "access_token"
             }
           }
         }) do
      {:ok, %{"TOKEN" => token}} -> {:ok, token}
      {:error, _} = error -> error
      _ -> {:error, :member_source_changed}
    end
  end

  defp member_request("linear", http, identity, _source) do
    with {:ok, data} <-
           http.(
             "linear",
             {:post, "https://api.linear.app/graphql", [json: %{"query" => @member_linear_query}]}
           ),
         do: member_linear_data(data, identity)
  end

  # Assigned issues, requested reviews, mentions, the member's own pull
  # requests and their notification inbox are independent reads. One that
  # fails or that GitHub reports as incomplete leaves the others readable.
  # Assigned work, requested reviews and own pull requests stay open for as long
  # as nobody closes them, so only those touched within `open_work_since/0`
  # count: a request left untouched for months would otherwise return in every
  # Routine.
  defp member_request("github", http, identity, source) do
    with {:ok, %{"id" => id, "login" => login}} when is_integer(id) and is_binary(login) <-
           http.("github_user", {:get, "https://api.github.com/user", []}),
         true <-
           Integer.to_string(id) == identity["provider_user_id"] and
             Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/, login) do
      search = fn query ->
        {"github_search",
         {:get, "https://api.github.com/search/issues",
          [params: [q: query, per_page: 20, page: 1, sort: "updated", order: "desc"]]}}
      end

      open_since = Date.to_iso8601(DateTime.to_date(open_work_since()))

      [issues, reviews, mentions, authored, notifications] =
        RecommendationMemberRead.map(
          [
            {"github_issues",
             {:get, "https://api.github.com/issues",
              [
                params: [
                  filter: "assigned",
                  state: "open",
                  sort: "updated",
                  direction: "desc",
                  since: DateTime.to_iso8601(open_work_since()),
                  per_page: 40,
                  page: 1
                ]
              ]}},
            search.("is:pr is:open review-requested:#{login} updated:>=#{open_since}"),
            search.("mentions:#{login} is:open updated:>=#{Date.to_iso8601(recent_date())}"),
            {"github_graphql",
             {:post, "https://api.github.com/graphql",
              [
                json: %{
                  "query" => @member_github_authored_query,
                  "variables" => %{
                    "query" => "is:pr is:open author:#{login} updated:>=#{open_since}"
                  }
                }
              ]}},
            {"github_notifications",
             {:get, "https://api.github.com/notifications",
              [
                params: [
                  all: true,
                  since: recent_date() |> DateTime.new!(~T[00:00:00]) |> DateTime.to_iso8601(),
                  per_page: 50,
                  page: 1
                ]
              ]}}
          ],
          fn {kind, spec} -> http.(kind, spec) end,
          5
        )

      reads = [issues, reviews, mentions, authored, notifications]

      failures =
        for({:error, reason} <- reads, do: reason) ++
          for {:ok, %{"incomplete_results" => true}} <- [reviews, mentions],
              do: :github_search_incomplete

      if Enum.all?(reads, &match?({:error, _}, &1)) do
        issues
      else
        data =
          id
          |> github_items(
            github_list(issues, "issues"),
            github_list(reviews, "items"),
            github_mentions(github_list(mentions, "items"), login, http),
            github_authored(authored),
            github_notifications(github_list(notifications, "notifications"), login, http)
          )
          |> Map.update!("issues", &(&1 ++ github_failed_runs(source, http)))

        {:ok, RecommendationMemberRead.warn(data, failures)}
      end
    else
      false -> {:error, :member_source_identity_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp member_request("notion", http, identity, _source) do
    CommaWeb.RecommendationNotionMemberSource.read(identity, fn kind, method, url, options ->
      http.(kind, {method, url, options})
    end)
  end

  defp member_request("slack", http, identity, source) do
    case CommaWeb.RecommendationSlackMemberSource.read(
           fn "GET", url, options -> http.("slack", {:get, url, options}) end,
           SystemsClock.utc_now(),
           Map.take(identity, ~w(provider_user_id provider_workspace_id)),
           targets: source["memberTargets"] || %{}
         ) do
      {:ok, data, _subject} -> {:ok, data}
      {:error, _} = error -> error
    end
  end

  defp github_list({:ok, body}, key) when is_map(body) do
    case body[key] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp github_list(_response, _key), do: []

  defp github_items(id, issues, reviews, mention_items, authored, notified) do
    assigned =
      issues
      |> Enum.filter(fn issue ->
        is_map(issue) and issue["state"] == "open" and
          is_integer(issue["id"]) and is_binary(issue["html_url"]) and
          is_list(issue["assignees"]) and
          Enum.any?(issue["assignees"], &(is_map(&1) and &1["id"] == id))
      end)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.take(40)
      |> Enum.map(fn item ->
        item
        |> CommaWeb.RecommendationSourceContext.attach(~w(state body))
        |> Map.take(~w(id number title html_url state updated_at pull_request context))
        |> Map.put("memberRelation", "assigned_to_you")
        |> RecommendationSourceQuote.put(title: item["title"], body: {:markdown, item["body"]})
      end)

    review_items =
      reviews
      |> Enum.filter(fn item ->
        is_map(item) and item["state"] == "open" and is_map(item["pull_request"]) and
          is_integer(item["id"]) and is_binary(item["html_url"])
      end)
      |> Enum.take(20)
      |> Enum.map(fn item ->
        item
        |> CommaWeb.RecommendationSourceContext.attach(~w(state body))
        |> Map.take(~w(id number title html_url state updated_at pull_request context))
        |> Map.put("memberRelation", "review_requested_from_you")
        |> RecommendationSourceQuote.put(title: item["title"], body: {:markdown, item["body"]})
      end)

    # A direct request leads. A pull request or issue reached through several
    # reads keeps its first, most specific relationship.
    %{
      "issues" =>
        (review_items ++ mention_items ++ authored ++ assigned ++ notified)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.uniq_by(& &1["html_url"]),
      "memberRelation" => "assigned_review_requested_mentioned_authored_or_notified"
    }
  end

  # The last day's failed Actions runs of the repositories where the owner's
  # work is reported (`CommaWeb.MemberPortrait.targets/1`), at most three a
  # repository. A repository the grant cannot read adds nothing.
  defp github_failed_runs(%{"memberTargets" => %{"repos" => [_ | _] = repos}}, http) do
    since = SystemsClock.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.to_date()

    repos
    |> RecommendationMemberRead.map(
      fn repo ->
        http.(
          "github_runs",
          {:get, "https://api.github.com/repos/#{repo}/actions/runs",
           [params: [status: "failure", per_page: 3, created: ">=#{since}"]]}
        )
      end,
      3
    )
    |> Enum.flat_map(fn
      {:ok, %{"workflow_runs" => runs}} when is_list(runs) ->
        for %{"id" => id, "html_url" => url} = run <- runs, is_integer(id), is_binary(url) do
          %{
            "id" => id,
            "title" =>
              "#{run["name"]} failed on #{run["head_branch"]} (attempt #{run["run_attempt"]})",
            "html_url" => url,
            "state" => run["conclusion"],
            "updated_at" => run["updated_at"],
            "memberRelation" => "failed_in_your_repo"
          }
        end

      _ ->
        []
    end)
  end

  defp github_failed_runs(_source, _http), do: []

  # The member's open pull requests with their checks and review outcome. A
  # new check or review result changes the item, so consumers judge it again.
  defp github_authored({:ok, %{"data" => %{"search" => %{"nodes" => nodes}}}})
       when is_list(nodes) do
    nodes
    |> Enum.filter(
      &(is_map(&1) and &1["state"] == "OPEN" and is_integer(&1["databaseId"]) and
          is_binary(&1["url"]))
    )
    |> Enum.take(20)
    |> Enum.map(fn pr ->
      checks =
        get_in(pr, ["commits", "nodes", Access.at(0), "commit", "statusCheckRollup", "state"])

      %{
        "id" => pr["databaseId"],
        "number" => pr["number"],
        "title" => pr["title"],
        "html_url" => pr["url"],
        "state" => "open",
        "updated_at" => pr["updatedAt"],
        "draft" => pr["isDraft"],
        "checks" => checks,
        "review" => pr["reviewDecision"]
      }
      |> CommaWeb.RecommendationSourceContext.attach(~w(state draft checks review))
      |> Map.take(~w(id number title html_url state updated_at context))
      |> Map.put("pull_request", %{})
      |> Map.put("memberRelation", "authored_by_you")
      |> RecommendationSourceQuote.put(
        title: pr["title"],
        facts: [
          checks: github_checks(checks),
          review: github_review(pr["reviewDecision"]),
          draft: pr["isDraft"]
        ]
      )
    end)
  end

  defp github_authored(_response), do: []

  defp github_checks("SUCCESS"), do: :passing
  defp github_checks(state) when state in ~w(FAILURE ERROR), do: :failing
  defp github_checks(state) when state in ~w(PENDING EXPECTED), do: :pending
  defp github_checks(_state), do: nil

  defp github_review("APPROVED"), do: :approved
  defp github_review("CHANGES_REQUESTED"), do: :changes_requested
  defp github_review("REVIEW_REQUIRED"), do: :review_required
  defp github_review(_decision), do: nil

  # GitHub decides which threads involve the member. Repository watching is not
  # a relationship, and the mention read already keeps the mentioning comment.
  @github_ignored_reasons ~w(subscribed mention)

  # A notification names only its thread and reason. The member's own merged
  # or closed pull request, for example, is no longer in the open pull request
  # read. One GraphQL request reads the state and latest comment of the issues
  # and pull requests that the kept notifications name, so the judge sees
  # resolved work and what happened. An unreadable subject keeps the
  # notification without them.
  @github_subject_fragment """
  fragment CommaSubject on IssueOrPullRequest {
    ... on PullRequest { state comments(last: 1) { nodes { author { login } body } } }
    ... on Issue { state comments(last: 1) { nodes { author { login } body } } }
  }
  """
  @github_comment_bytes 400

  defp github_notifications(notifications, login, http) do
    kept =
      notifications
      |> Enum.filter(
        &(is_map(&1) and is_binary(&1["id"]) and is_binary(&1["reason"]) and
            &1["reason"] not in @github_ignored_reasons and is_map(&1["subject"]) and
            is_binary(&1["subject"]["title"]) and is_map(&1["repository"]) and
            is_binary(&1["repository"]["html_url"]))
      )
      |> Enum.take(20)

    subjects = github_subjects(kept, http)

    Enum.map(kept, fn notification ->
      %{"subject" => subject, "repository" => repository} = notification
      found = subjects[notification["id"]] || %{}
      latest = github_latest_comment(found)

      %{
        "id" => notification["id"],
        "title" => subject["title"],
        "html_url" => github_subject_url(subject, repository["html_url"]),
        "updated_at" => notification["updated_at"],
        "reason" => notification["reason"],
        "type" => subject["type"],
        "repository" => repository["full_name"],
        "state" => if(is_binary(found["state"]), do: String.downcase(found["state"])),
        "latest_comment" => github_comment_context(latest, login)
      }
      |> CommaWeb.RecommendationSourceContext.attach(
        ~w(reason type repository state latest_comment)
      )
      |> Map.take(~w(id title html_url updated_at context))
      |> Map.put("memberRelation", "notified_you")
      |> RecommendationSourceQuote.put(
        title: subject["title"],
        author: latest && latest.author,
        body: latest && {:markdown, latest.body}
      )
    end)
  end

  # Notification ID => the issue or pull request that GitHub returned.
  defp github_subjects(notifications, http) do
    subjects =
      notifications
      |> Enum.flat_map(fn notification ->
        case Regex.run(
               ~r{^https://api\.github\.com/repos/([\w.-]+)/([\w.-]+)/(?:pulls|issues)/(\d+)$},
               notification["subject"]["url"] || ""
             ) do
          [_, owner, name, number] -> [{notification["id"], owner, name, number}]
          _ -> []
        end
      end)
      |> Enum.with_index()

    if subjects == [] do
      %{}
    else
      variables =
        subjects
        |> Enum.flat_map(fn {{_id, owner, name, number}, i} ->
          [{"o#{i}", owner}, {"n#{i}", name}, {"k#{i}", String.to_integer(number)}]
        end)
        |> Map.new()

      definitions =
        Enum.map_join(subjects, ", ", fn {_, i} ->
          "$o#{i}: String!, $n#{i}: String!, $k#{i}: Int!"
        end)

      selections =
        Enum.map_join(subjects, "\n", fn {_, i} ->
          "s#{i}: repository(owner: $o#{i}, name: $n#{i}) " <>
            "{ issueOrPullRequest(number: $k#{i}) { ...CommaSubject } }"
        end)

      query =
        "query CommaMemberNotificationSubjects(#{definitions}) {\n#{selections}\n}\n" <>
          @github_subject_fragment

      case http.(
             "github_subjects",
             {:post, "https://api.github.com/graphql",
              [json: %{"query" => query, "variables" => variables}]}
           ) do
        {:ok, %{"data" => data}} ->
          for {{id, _owner, _name, _number}, i} <- subjects,
              subject = get_in(data, ["s#{i}", "issueOrPullRequest"]),
              is_map(subject),
              into: %{},
              do: {id, subject}

        _unreadable ->
          %{}
      end
    end
  end

  defp github_latest_comment(subject) do
    with %{"comments" => %{"nodes" => [%{"body" => body} = comment | _]}} <- subject,
         true <- is_binary(body) and body != "" do
      %{
        author: get_in(comment, ["author", "login"]),
        body: String.slice(body, 0, @github_comment_bytes)
      }
    else
      _ -> nil
    end
  end

  defp github_comment_context(nil, _login), do: nil

  defp github_comment_context(%{author: author, body: body}, login) do
    author =
      case author do
        ^login -> "you"
        other when is_binary(other) -> other
        _ -> "someone"
      end

    author <> ": " <> body
  end

  # Notifications name the API resource. Pull requests, issues and commits map
  # to their pages; other subjects, such as a failed workflow run, open the
  # repository page that lists them.
  defp github_subject_url(%{"url" => url, "type" => type}, repository) when is_binary(url) do
    case Regex.run(
           ~r{^https://api\.github\.com/repos/([\w.-]+/[\w.-]+)/(pulls|issues|commits)/(\w+)$},
           url
         ) do
      [_, repo, "pulls", number] ->
        "https://github.com/#{repo}/pull/#{number}"

      [_, repo, "issues", number] ->
        "https://github.com/#{repo}/issues/#{number}"

      [_, repo, "commits", sha] ->
        "https://github.com/#{repo}/commit/#{sha}"

      _ ->
        github_repository_page(type, repository)
    end
  end

  defp github_subject_url(subject, repository),
    do: github_repository_page(subject["type"], repository)

  defp github_repository_page("CheckSuite", repository), do: repository <> "/actions"
  defp github_repository_page("WorkflowRun", repository), do: repository <> "/actions"
  defp github_repository_page("Release", repository), do: repository <> "/releases"
  defp github_repository_page("Discussion", repository), do: repository <> "/discussions"
  defp github_repository_page(_type, repository), do: repository

  # The comment that names the member is the request: the issue body may predate it.
  # The five most recent mentions read their comments; the rest keep the body,
  # as does a mention whose comments cannot be read.
  defp github_mentions(items, login, http) do
    items =
      items
      |> Enum.filter(fn item ->
        is_map(item) and item["state"] == "open" and is_integer(item["id"]) and
          is_binary(item["html_url"]) and is_binary(item["comments_url"])
      end)
      |> Enum.take(10)

    {latest, older} = Enum.split(items, 5)
    since = recent_date() |> DateTime.new!(~T[00:00:00]) |> DateTime.to_iso8601()
    name = ~r/(^|[^A-Za-z0-9-])@#{Regex.escape(login)}(?![A-Za-z0-9-])/i

    latest
    |> RecommendationMemberRead.map(
      fn item ->
        {item,
         http.(
           "github_comments",
           {:get, item["comments_url"], [params: [since: since, per_page: 30]]}
         )}
      end,
      5
    )
    |> Enum.map(fn
      {item, {:ok, %{"comments" => comments}}} ->
        comment =
          comments
          |> Enum.filter(
            &(is_map(&1) and is_binary(&1["body"]) and Regex.match?(name, &1["body"]))
          )
          |> List.last()

        github_mention(item, comment)

      {item, _unreadable} ->
        github_mention(item, nil)
    end)
    |> Kernel.++(Enum.map(older, &github_mention(&1, nil)))
  end

  defp github_mention(item, comment) do
    comment = if is_map(comment) and is_integer(comment["id"]), do: comment, else: %{}

    item
    |> Map.merge(%{
      "id" => comment["id"] || item["id"],
      "html_url" => comment["html_url"] || item["html_url"],
      "mention" => comment["body"] || item["body"]
    })
    |> CommaWeb.RecommendationSourceContext.attach(~w(state mention))
    |> Map.take(~w(id number title html_url state updated_at pull_request context))
    |> Map.put("memberRelation", "mentioned_you")
    |> RecommendationSourceQuote.put(
      title: item["title"],
      author: get_in(comment, ["user", "login"]),
      body: {:markdown, comment["body"] || item["body"]}
    )
  end

  defp recent_date, do: Date.add(Date.utc_today(), -7)

  @open_work_days 30
  defp open_work_since,
    do:
      SystemsClock.utc_now()
      |> DateTime.add(-@open_work_days * 86_400)
      |> DateTime.truncate(:second)

  defp member_linear_data(
         %{
           "viewer" => %{"id" => viewer, "assignedIssues" => %{"nodes" => nodes}},
           "organization" => %{"id" => organization},
           "notifications" => %{"nodes" => notifications}
         },
         identity
       )
       when is_list(nodes) and is_list(notifications) do
    if viewer == identity["provider_user_id"] and
         organization == identity["provider_workspace_id"] do
      issues =
        nodes
        |> Enum.filter(fn issue ->
          is_map(issue) and get_in(issue, ["assignee", "id"]) == viewer and
            get_in(issue, ["state", "type"]) in ~w(triage backlog unstarted started) and
            is_binary(issue["id"]) and is_binary(issue["url"])
        end)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.sort_by(fn issue ->
          priority = if issue["priority"] in 1..4, do: issue["priority"], else: 5
          {issue["dueDate"] || "9999-12-31", priority, issue["id"]}
        end)
        |> Enum.take(40)
        |> Enum.map(fn item ->
          item
          |> CommaWeb.RecommendationSourceContext.attach(~w(state description))
          |> Map.delete("description")
          |> RecommendationSourceQuote.put(
            title: item["title"],
            facts: [status: get_in(item, ["state", "name"])],
            body: {:markdown, item["description"]}
          )
        end)

      # A mention is a direct request, so it leads the bounded source envelope.
      {:ok,
       %{
         "issues" => %{"nodes" => linear_mentions(notifications) ++ issues},
         "memberRelation" => "assigned_or_mentioned_you"
       }}
    else
      {:error, :member_source_identity_mismatch}
    end
  end

  defp member_linear_data(_data, _identity), do: {:error, :invalid_provider_response}

  # A comment mention keeps the comment link, so it stays a separate request
  # even when the member also owns the issue.
  defp linear_mentions(notifications) do
    notifications
    |> Enum.filter(fn notification ->
      is_map(notification) and notification["type"] in @linear_mentions and
        is_nil(notification["archivedAt"]) and recent?(notification["createdAt"]) and
        is_binary(get_in(notification, ["issue", "id"])) and
        is_binary(get_in(notification, ["issue", "url"]))
    end)
    |> Enum.map(fn %{"issue" => issue} = notification ->
      comment = notification["comment"] || %{}

      issue
      |> Map.merge(%{
        "id" => comment["id"] || issue["id"],
        "url" => comment["url"] || issue["url"],
        "updatedAt" => notification["createdAt"],
        "mention" => comment["body"] || issue["description"],
        "memberRelation" => "mentioned_you"
      })
      |> CommaWeb.RecommendationSourceContext.attach(~w(state mention))
      |> Map.drop(~w(description mention))
      |> RecommendationSourceQuote.put(
        title: issue["title"],
        author: get_in(comment, ["user", "name"]),
        facts: [status: get_in(issue, ["state", "name"])],
        body: {:markdown, comment["body"] || issue["description"]}
      )
    end)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(10)
  end

  defp recent?(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, time, _} -> DateTime.diff(SystemsClock.utc_now(), time) <= @recent_seconds
      _ -> false
    end
  end

  defp recent?(_timestamp), do: false

  defp request(provider, token), do: request(provider, token, request_options(provider))

  defp request(provider, token, {method, url, options}) do
    {limit, options} = Keyword.pop(options, :max_bytes, 512_000)

    options =
      Keyword.merge(
        [
          method: method,
          url: url,
          auth: {:bearer, token},
          headers: [{"user-agent", "Comma"}],
          retry: false,
          redirect: false,
          receive_timeout: 10_000,
          pool_timeout: 10_000,
          connect_options: [timeout: 10_000]
        ],
        options
      )

    options =
      Keyword.merge(
        options,
        SystemsRuntime.get_env(:comma_web, :recommendation_oauth_http_options, [])
      )

    options = if provider == "slack", do: bound_slack_response(options, limit), else: options

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> normalize(provider, body)
      {:ok, %{status: status}} -> {:error, {:oauth_provider_http, status}}
      {:error, _} -> {:error, :oauth_provider_unavailable}
    end
  end

  defp bound_slack_response(options, limit) do
    Keyword.merge(options,
      decode_body: false,
      into: fn {:data, data}, {req, resp} ->
        body = (resp.body || "") <> data

        if byte_size(body) > limit,
          do: {:halt, {req, %{resp | body: :response_too_large}}},
          else: {:cont, {req, %{resp | body: body}}}
      end
    )
  end

  defp request_options("github"),
    do:
      {:get, "https://api.github.com/notifications",
       [params: [all: false, per_page: 12, page: 1]]}

  defp request_options("linear") do
    {:ok, {_slug, recipe}} = CommaWeb.RecommendationSourceCatalog.recipe("linear", nil)

    {:post, "https://api.linear.app/graphql",
     [json: %{"query" => recipe["query_or_mutation"], "variables" => recipe["variables"]}]}
  end

  defp request_options("slack"),
    do:
      {:get, CommaWeb.SlackWebAPI.url("search.messages"),
       [
         params: [
           count: 12,
           page: 1,
           sort: "timestamp",
           sort_dir: "desc",
           query: "after:#{Date.add(Date.utc_today(), -1)}"
         ]
       ]}

  defp request_options("notion"),
    do:
      {:post, "https://api.notion.com/v1/search",
       [
         headers: [{"notion-version", "2022-06-28"}, {"user-agent", "Comma"}],
         json: %{
           "page_size" => 12,
           "filter" => %{"property" => "object", "value" => "page"},
           "sort" => %{"direction" => "descending", "timestamp" => "last_edited_time"}
         }
       ]}

  defp normalize("slack", :response_too_large), do: {:error, :response_too_large}

  defp normalize("slack", body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> normalize("slack", decoded)
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp normalize("slack", %{"ok" => true} = body), do: {:ok, body}

  defp normalize("slack", %{"ok" => false, "error" => code}) when is_binary(code),
    do: {:error, {:member_provider_error, String.slice(code, 0, 64)}}

  defp normalize("github_search", %{"items" => items, "incomplete_results" => incomplete} = body)
       when is_list(items) and is_boolean(incomplete), do: {:ok, body}

  defp normalize("github_comments", body) when is_list(body), do: {:ok, %{"comments" => body}}

  defp normalize("github_user", %{"id" => id} = body) when is_integer(id), do: {:ok, body}

  defp normalize("github_runs", %{"workflow_runs" => runs} = body) when is_list(runs),
    do: {:ok, body}

  defp normalize("github_object", %{"html_url" => url} = body) when is_binary(url),
    do: {:ok, body}

  defp normalize("github_pull_request", %{"number" => number, "title" => title} = body)
       when is_integer(number) and is_binary(title), do: {:ok, body}

  defp normalize("github_issues", body) when is_list(body), do: {:ok, %{"issues" => body}}

  defp normalize("github_notifications", body) when is_list(body),
    do: {:ok, %{"notifications" => body}}

  defp normalize("github_graphql", %{"data" => %{"search" => %{"nodes" => nodes}}} = body)
       when is_list(nodes),
       do: {:ok, body}

  # GraphQL answers each lookup alone: one inaccessible repository leaves the
  # other subjects readable.
  defp normalize("github_subjects", %{"data" => data}) when is_map(data),
    do: {:ok, %{"data" => data}}

  defp normalize("github_graphql", %{"errors" => [_ | _]}),
    do: {:error, :oauth_provider_query_failed}

  defp normalize("github", body) when is_list(body), do: {:ok, %{"notifications" => body}}
  defp normalize("linear", %{"errors" => [_ | _]}), do: {:error, :oauth_provider_query_failed}
  defp normalize("linear", %{"data" => data}) when is_map(data), do: {:ok, data}

  defp normalize("notion_page", %{"object" => "page", "id" => id} = body)
       when is_binary(id), do: {:ok, body}

  defp normalize("notion_self", body) when is_map(body), do: {:ok, body}

  defp normalize("notion", %{"results" => pages}) when is_list(pages),
    do: {:ok, %{"values" => pages}}

  defp normalize(_, _), do: {:error, :invalid_provider_response}
end
