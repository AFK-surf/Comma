defmodule CommaWeb.RecommendationSourceCatalog do
  @moduledoc false

  @app_names %{
    "github" => "GitHub",
    "gmail" => "Gmail",
    "googlecalendar" => "Google Calendar",
    "googledrive" => "Google Drive",
    "linear" => "Linear",
    "notion" => "Notion",
    "slack" => "Slack"
  }
  @supported_toolkits Map.keys(@app_names)
  @linear_issues_query """
  query CommaRecommendationIssues($first: Int!) {
    issues(first: $first) {
      nodes {
        id
        identifier
        title
        url
        priority
        state { name }
        assignee { id name email }
        project { id name }
        labels { nodes { id name } }
      }
    }
  }
  """

  def supported_composio_toolkits, do: @supported_toolkits
  def supported_composio_toolkit?(toolkit), do: toolkit in @supported_toolkits
  def app_name(toolkit), do: Map.fetch!(@app_names, toolkit)

  def recipe("github", _now),
    do:
      {:ok,
       {"GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER",
        %{"all" => false, "page" => 1, "participating" => true, "per_page" => 12}}}

  def recipe("linear", _now) do
    {:ok,
     {"LINEAR_RUN_QUERY_OR_MUTATION",
      %{"query_or_mutation" => @linear_issues_query, "variables" => %{"first" => 12}}}}
  end

  def recipe("notion", _now),
    do: {:ok, {"NOTION_FETCH_DATA", %{"get_pages" => true, "page_size" => 12}}}

  def recipe("gmail", _now),
    do:
      {:ok,
       {"GMAIL_FETCH_EMAILS",
        %{"include_payload" => false, "max_results" => 12, "query" => "newer_than:1d"}}}

  def recipe("googlecalendar", now) do
    {:ok,
     {"GOOGLECALENDAR_EVENTS_LIST",
      %{
        "calendarId" => "primary",
        "maxResults" => 12,
        "orderBy" => "startTime",
        "singleEvents" => true,
        "timeMax" => now |> DateTime.add(86_400, :second) |> DateTime.to_iso8601(),
        "timeMin" => DateTime.to_iso8601(now)
      }}}
  end

  def recipe("googledrive", _now),
    do:
      {:ok,
       {"GOOGLEDRIVE_LIST_FILES",
        %{"orderBy" => "modifiedTime desc", "pageSize" => 12, "q" => "trashed = false"}}}

  def recipe("slack", now),
    do:
      {:ok,
       {"SLACK_SEARCH_FOR_MESSAGES_WITH_QUERY",
        %{
          "count" => 12,
          "query" => "after:#{now |> DateTime.add(-86_400, :second) |> DateTime.to_date()}",
          "sort" => "timestamp",
          "sort_dir" => "desc"
        }}}

  def recipe(toolkit, _now), do: {:error, {:unsupported_composio_toolkit, toolkit}}
end
