defmodule CommaWeb.RecommendationOAuthSource do
  @moduledoc false

  alias CommaWeb.RecommendationMemberRead
  alias Salix.Control.OAuthBindings

  # Bounded reads: the existing resolver owns authorization and refresh,
  # and Req owns HTTP/JSON. Official provider SDKs target other languages;
  # keep the Elixir REST/GraphQL adapter isolated and test it through Req.Test.
  def read(workspace, source) do
    provider = source["appId"]
    tenant = workspace["salix_tenant_id"]
    group = workspace["default_group_id"]

    with true <- provider in ~w(github linear notion slack),
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
      request(provider, token)
    else
      _ -> {:error, :oauth_source_unavailable}
    end
  end

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
          comment { id body url }
        }
      }
    }
  }
  """

  # The member's Linear inbox. An archived notification is done.
  @linear_mentions ~w(issueMention issueCommentMention)
  @recent_seconds 7 * 86_400

  # Bounded self-scoped reads, not a global first page filtered afterward.
  # The runtime will pass the returned subject through publication fencing.
  def read_member(workspace, user_id, source, deadline \\ RecommendationMemberRead.deadline())

  def read_member(workspace, user_id, %{"appId" => provider} = source, deadline)
      when provider in ~w(linear github notion slack) do
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

  # Assigned issues, requested reviews and mentions are independent reads. One
  # that fails or that GitHub reports as incomplete leaves the others readable.
  defp member_request("github", http, identity, _source) do
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

      [issues, reviews, mentions] =
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
                  per_page: 40,
                  page: 1
                ]
              ]}},
            search.("is:pr is:open review-requested:#{login}"),
            search.("mentions:#{login} is:open updated:>=#{Date.to_iso8601(recent_date())}")
          ],
          fn {kind, spec} -> http.(kind, spec) end,
          3
        )

      failures =
        for({:error, reason} <- [issues, reviews, mentions], do: reason) ++
          for {:ok, %{"incomplete_results" => true}} <- [reviews, mentions],
              do: :github_search_incomplete

      if Enum.all?([issues, reviews, mentions], &match?({:error, _}, &1)) do
        issues
      else
        {:ok,
         RecommendationMemberRead.warn(
           github_items(
             id,
             github_list(issues, "issues"),
             github_list(reviews, "items"),
             github_mentions(github_list(mentions, "items"), login, http)
           ),
           failures
         )}
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

  defp member_request("slack", http, identity, _source) do
    case CommaWeb.RecommendationSlackMemberSource.read(
           fn "GET", url, options -> http.("slack", {:get, url, options}) end,
           DateTime.utc_now(),
           Map.take(identity, ~w(provider_user_id provider_workspace_id))
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

  defp github_items(id, issues, reviews, mention_items) do
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
      end)

    %{
      "issues" => Enum.uniq_by(review_items ++ mention_items ++ assigned, & &1["id"]),
      "memberRelation" => "assigned_review_requested_or_mentioned"
    }
  end

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
  end

  defp recent_date, do: Date.add(Date.utc_today(), -7)

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
    end)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(10)
  end

  defp recent?(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, time, _} -> DateTime.diff(DateTime.utc_now(), time) <= @recent_seconds
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
        Application.get_env(:comma_web, :recommendation_oauth_http_options, [])
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
      {:get, "https://slack.com/api/search.messages",
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
  defp normalize("github_issues", body) when is_list(body), do: {:ok, %{"issues" => body}}

  defp normalize("github", body) when is_list(body), do: {:ok, %{"notifications" => body}}
  defp normalize("linear", %{"errors" => [_ | _]}), do: {:error, :oauth_provider_query_failed}
  defp normalize("linear", %{"data" => data}) when is_map(data), do: {:ok, data}

  defp normalize("notion_self", body) when is_map(body), do: {:ok, body}

  defp normalize("notion", %{"results" => pages}) when is_list(pages),
    do: {:ok, %{"values" => pages}}

  defp normalize(_, _), do: {:error, :invalid_provider_response}
end
