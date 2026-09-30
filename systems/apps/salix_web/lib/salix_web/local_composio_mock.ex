if Application.compile_env(:salix_web, :local_recommendation_mock_compiled, false) do
  defmodule SalixWeb.LocalComposioMock do
    @moduledoc """
    Build-gated Composio adapter used by Comma's local recommendation flow.

    It replaces the external Composio settings/client boundary for connected
    accounts, auth configuration, and read-only tool execution. Comma Web keeps
    production source discovery, fixed-recipe selection, bounded server-side
    collection, recommendation orchestration, renderer delivery, validation,
    persistence, and client rendering. The hidden recommendation renderer sees
    only the collected facts; it is not disclosed Composio, MCP, IM, discovery,
    web, or other source tools. Accounts remain group-scoped, exactly like
    production.

    The tool catalog lists the real Composio tool slugs that production code
    calls (the recommendation recipes and the link-preview reads), and every
    execution answers with the provider-faithful response shape from
    `SalixWeb.LocalProviderFixtures` — record links included, timestamps
    derived from now. Chat agents therefore discover and execute the same tool
    surface locally as in production instead of a fictional one, and a slug
    this mock does not implement fails as a structured provider error rather
    than returning made-up data.
    """

    alias SalixWeb.LocalProviderFixtures, as: Fixtures

    @state_key {__MODULE__, :accounts}
    @toolkits ~w(github gmail googlecalendar googledrive linear notion slack)

    # Real Composio tool slugs, per toolkit, with the recommendation recipe's
    # collection slug listed first (local renderer flows execute the first
    # listed tool of a toolkit).
    @toolkit_tools %{
      "github" => [
        {"GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER",
         "List notifications for the authenticated user."},
        {"GITHUB_GET_A_PULL_REQUEST", "Get a pull request by owner, repo, and number."}
      ],
      "gmail" => [
        {"GMAIL_FETCH_EMAILS", "Fetch emails matching a Gmail search query."}
      ],
      "googlecalendar" => [
        {"GOOGLECALENDAR_EVENTS_LIST", "List events from a Google Calendar."}
      ],
      "googledrive" => [
        {"GOOGLEDRIVE_LIST_FILES", "List files from Google Drive."}
      ],
      "linear" => [
        {"LINEAR_RUN_QUERY_OR_MUTATION", "Run a Linear GraphQL query or mutation."}
      ],
      "notion" => [
        {"NOTION_FETCH_DATA", "Fetch Notion pages and databases."},
        {"NOTION_FETCH_ROW", "Fetch one Notion database row or page."}
      ],
      "slack" => [
        {"SLACK_SEARCH_FOR_MESSAGES_WITH_QUERY", "Search Slack messages with a query."}
      ]
    }

    def get(_tenant_id), do: {:ok, settings()}
    def settings(_tenant_id), do: {:ok, settings()}

    def reset!, do: :persistent_term.put(@state_key, %{})

    def list_connected_accounts(_settings, group_id), do: accounts(group_id)
    def list_connected_accounts_all(_settings, group_id, _opts \\ []), do: accounts(group_id)

    def ensure_auth_config(_settings, toolkit),
      do: {:ok, "local-auth-config-#{normalize_toolkit(toolkit)}"}

    def create_connect_link(_settings, auth_config_id, group_id, _opts \\ []) do
      toolkit = String.replace_prefix(to_string(auth_config_id), "local-auth-config-", "")
      account = put_account(group_id, toolkit)

      {:ok,
       %{
         "redirect_url" => "http://127.0.0.1/local-composio/connected/#{account["id"]}",
         "connected_account_id" => account["id"]
       }}
    end

    def get_connected_account(_settings, id, _opts \\ []) do
      case all_accounts() |> Enum.find(&(&1["id"] == to_string(id))) do
        nil -> {:error, :not_found}
        account -> {:ok, account}
      end
    end

    def delete_connected_account(_settings, id) do
      update(fn by_group ->
        Map.new(by_group, fn {group_id, accounts} ->
          {group_id, Enum.reject(accounts, &(&1["id"] == to_string(id)))}
        end)
      end)

      :ok
    end

    def list_toolkits(_settings, _opts) do
      {:ok,
       Enum.map(@toolkits, fn toolkit ->
         %{
           "slug" => toolkit,
           "name" => humanize(toolkit),
           "meta" => %{
             "description" => "Local #{humanize(toolkit)} data",
             "tools_count" => length(Map.fetch!(@toolkit_tools, toolkit))
           }
         }
       end)}
    end

    def list_tools(_settings, opts) do
      toolkit = Keyword.get(opts, :toolkit)
      slugs = Keyword.get(opts, :tool_slugs)

      tools =
        @toolkits
        |> Enum.flat_map(&tools_for_toolkit/1)
        |> maybe_filter_toolkit(toolkit)
        |> maybe_filter_slugs(slugs)
        |> Enum.take(Keyword.get(opts, :limit, 20))

      {:ok, tools}
    end

    def execute_tool(_settings, tool_slug, group_id, arguments, opts \\ []) do
      toolkit = toolkit_for_slug(tool_slug)
      account_id = Keyword.get(opts, :connected_account_id)

      with true <- toolkit in @toolkits,
           {:ok, accounts} <- accounts(group_id),
           %{} <- matching_account(accounts, toolkit, account_id) do
        case validated_tool_data(tool_slug, toolkit, arguments) do
          {:ok, data} ->
            {:ok,
             %{
               "successful" => true,
               "data" => data,
               "log_id" => "local-composio-#{toolkit}"
             }}

          {:error, message} ->
            {:ok,
             %{
               "successful" => false,
               "error" => message,
               "log_id" => "local-composio-#{toolkit}"
             }}
        end
      else
        _ -> {:error, :not_found}
      end
    end

    # Tool Router proxy reads through the provider's own HTTP API. Each link
    # preview fetches one exact record: Slack's Web API (`auth.test`,
    # `conversations.history`, `conversations.replies`, `conversations.info`,
    # `users.info`), Google Drive's `files.get`, and Google Calendar's
    # `events.get`. The member Routine reads Slack `search.messages`, Gmail
    # profile and threads, the primary calendar and its events, and Drive
    # `about`, `files.list` and comments.
    def create_proxy_session(
          _settings,
          _user_id,
          _account_id,
          _toolkit \\ "googlecalendar",
          _opts \\ []
        ),
        do: {:ok, "local-proxy-session"}

    def proxy_execute(_settings, _session_id, %{"endpoint" => endpoint}, _opts \\ []) do
      uri = URI.parse(to_string(endpoint))
      {:ok, proxy_data(uri.host, uri.path || "", URI.decode_query(uri.query || ""))}
    end

    def delete_proxy_session(_settings, _session_id), do: :ok

    # Slack's Web API answers HTTP 200 with `"ok" => false` for unknown
    # records; only transport failures change the status code.
    defp proxy_data("slack.com", "/api/auth.test", _query),
      do: %{"status" => 200, "data" => Fixtures.slack_auth_test_data()}

    defp proxy_data("slack.com", "/api/conversations.history", query),
      do: %{
        "status" => 200,
        "data" => Fixtures.slack_history_data(query["channel"], query["latest"])
      }

    defp proxy_data("slack.com", "/api/conversations.replies", query),
      do: %{
        "status" => 200,
        "data" => Fixtures.slack_replies_data(query["channel"], query["latest"])
      }

    defp proxy_data("slack.com", "/api/conversations.info", query),
      do: %{"status" => 200, "data" => Fixtures.slack_channel_info_data(query["channel"])}

    defp proxy_data("slack.com", "/api/users.info", query),
      do: %{"status" => 200, "data" => Fixtures.slack_user_info_data(query["user"])}

    defp proxy_data("slack.com", "/api/search.messages", query),
      do: %{"status" => 200, "data" => Fixtures.slack_search_messages_data(query["query"])}

    defp proxy_data("gmail.googleapis.com", "/gmail/v1/users/me/profile", _query),
      do: %{"status" => 200, "data" => Fixtures.gmail_profile_data()}

    defp proxy_data("gmail.googleapis.com", "/gmail/v1/users/me/threads", _query),
      do: %{"status" => 200, "data" => Fixtures.gmail_threads_data()}

    defp proxy_data("gmail.googleapis.com", "/gmail/v1/users/me/threads/" <> thread_id, _query),
      do: %{"status" => 200, "data" => Fixtures.gmail_thread_data(URI.decode(thread_id))}

    defp proxy_data("www.googleapis.com", "/calendar/v3/calendars/primary", _query),
      do: %{"status" => 200, "data" => Fixtures.calendar_primary_data()}

    defp proxy_data("www.googleapis.com", "/calendar/v3/calendars/primary/events", _query),
      do: %{"status" => 200, "data" => Fixtures.calendar_events_data()}

    defp proxy_data("www.googleapis.com", "/drive/v3/about", _query),
      do: %{"status" => 200, "data" => Fixtures.drive_about_data()}

    defp proxy_data("www.googleapis.com", "/drive/v3/files", query),
      do: %{"status" => 200, "data" => Fixtures.drive_files_list_data(query["q"])}

    defp proxy_data(_host, path, _query) do
      cond do
        file_id = path_capture(~r"^/drive/v3/files/([^/]+)/comments$", path) ->
          %{"status" => 200, "data" => Fixtures.drive_comments_data(URI.decode(file_id))}

        file_id = path_capture(~r"^/drive/v3/files/([^/]+)$", path) ->
          %{"status" => 200, "data" => Fixtures.drive_file_data(URI.decode(file_id))}

        event_id = path_capture(~r"/events/([^/?#]+)$", path) ->
          %{"status" => 200, "data" => calendar_event(URI.decode(event_id))}

        true ->
          %{"status" => 404, "data" => %{}}
      end
    end

    defp path_capture(regex, path) do
      case Regex.run(regex, path) do
        [_, capture] -> capture
        _no_match -> nil
      end
    end

    # Reject arguments that omit a tool's required inputs, exactly like the
    # hosted provider would: a call that only works because the mock ignores
    # its arguments is a false green for the production recipes.
    defp validated_tool_data(tool_slug, toolkit, arguments) do
      arguments = if is_map(arguments), do: arguments, else: %{}
      {_properties, required} = tool_input(tool_slug)

      case Enum.reject(required, &(is_map_key(arguments, &1) and arguments[&1] not in [nil, ""])) do
        [] ->
          tool_data(tool_slug, toolkit, arguments)

        missing ->
          {:error, "required inputs missing for #{tool_slug}: #{Enum.join(missing, ", ")}"}
      end
    end

    # Every implemented slug answers with the provider-faithful shape from the
    # shared local fixtures; anything else fails as a structured provider
    # error so callers see an honest "tool unavailable" instead of fake data.
    defp tool_data("SLACK_SEARCH_FOR_MESSAGES_WITH_QUERY", _toolkit, arguments),
      do: {:ok, Fixtures.slack_search_data(arguments["query"])}

    defp tool_data("GMAIL_FETCH_EMAILS", _toolkit, _arguments),
      do: {:ok, Fixtures.gmail_fetch_data()}

    defp tool_data("GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER", _toolkit, _arguments),
      do: {:ok, Fixtures.github_notifications_data()}

    # The recommendation link preview reads one pull request on hover.
    defp tool_data("GITHUB_GET_A_PULL_REQUEST", _toolkit, arguments),
      do: {:ok, Fixtures.github_pull_request_data(arguments)}

    # Linear: the catalog's collection query has no `id` variable; the link
    # preview asks for one issue by identifier.
    defp tool_data("LINEAR_RUN_QUERY_OR_MUTATION", _toolkit, %{"variables" => %{"id" => id}})
         when is_binary(id),
         do: {:ok, Fixtures.linear_issue_data(id)}

    defp tool_data("LINEAR_RUN_QUERY_OR_MUTATION", _toolkit, _arguments),
      do: {:ok, Fixtures.linear_issues_data()}

    defp tool_data("NOTION_FETCH_DATA", _toolkit, _arguments),
      do: {:ok, Fixtures.notion_pages_data()}

    defp tool_data("NOTION_FETCH_ROW", _toolkit, arguments),
      do: {:ok, Fixtures.notion_row_data(arguments)}

    defp tool_data("GOOGLECALENDAR_EVENTS_LIST", _toolkit, _arguments),
      do: {:ok, Fixtures.calendar_events_data()}

    defp tool_data("GOOGLEDRIVE_LIST_FILES", _toolkit, _arguments),
      do: {:ok, Fixtures.drive_files_data()}

    defp tool_data(tool_slug, toolkit, _arguments) do
      available = @toolkit_tools |> Map.get(toolkit, []) |> Enum.map(&elem(&1, 0))

      {:error,
       "the local provider mock does not implement #{tool_slug}; " <>
         "available #{toolkit} tools: #{Enum.join(available, ", ")}"}
    end

    defp calendar_event(event_id), do: Fixtures.calendar_event(event_id)

    defp settings, do: %{"api_key" => "local-composio", "base_url" => "local://composio"}

    defp accounts(group_id) do
      group_id = to_string(group_id)

      accounts =
        :global.trans({__MODULE__, :state}, fn ->
          state = state()

          case Map.fetch(state, group_id) do
            {:ok, accounts} ->
              accounts

            :error ->
              accounts = Enum.map(@toolkits, &account(group_id, &1))
              :persistent_term.put(@state_key, Map.put(state, group_id, accounts))
              accounts
          end
        end)

      {:ok, accounts}
    end

    # Every Connect Link mints its own account, as the provider does: a
    # toolkit that is connected again holds two accounts until the completed
    # one retires the other. Newest first, with a `created_at`, so callers
    # can order them the way they order the provider's.
    defp put_account(group_id, toolkit) do
      group_id = to_string(group_id)
      toolkit = normalize_toolkit(toolkit)

      :global.trans({__MODULE__, :state}, fn ->
        state = state()
        existing = Map.get(state, group_id, [])
        # An id is never reissued after a delete: the suffix grows past every
        # suffix the toolkit has held in this group.
        repeat =
          existing
          |> Enum.filter(&(toolkit_slug(&1) == toolkit))
          |> Enum.map(&account_repeat(&1["id"], group_id, toolkit))
          |> Enum.max(fn -> -1 end)
          |> Kernel.+(1)

        new_account = account(group_id, toolkit, repeat)
        :persistent_term.put(@state_key, Map.put(state, group_id, [new_account | existing]))
        new_account
      end)
    end

    defp update(fun) do
      :global.trans({__MODULE__, :state}, fn ->
        :persistent_term.put(@state_key, fun.(state()))
      end)
    end

    defp state, do: :persistent_term.get(@state_key, %{})
    defp all_accounts, do: state() |> Map.values() |> List.flatten()

    defp account_repeat(id, group_id, toolkit) do
      case String.replace_prefix(to_string(id), "local-#{group_id}-#{toolkit}", "") do
        "" -> 0
        "-" <> suffix -> String.to_integer(suffix) - 1
      end
    end

    defp account(group_id, toolkit, repeat \\ 0) do
      id =
        if repeat == 0,
          do: "local-#{group_id}-#{toolkit}",
          else: "local-#{group_id}-#{toolkit}-#{repeat + 1}"

      %{
        "id" => id,
        "connected_account_id" => id,
        "user_id" => group_id,
        "toolkit" => %{"slug" => toolkit},
        "status" => "ACTIVE",
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    end

    defp tools_for_toolkit(toolkit) do
      Enum.map(Map.fetch!(@toolkit_tools, toolkit), fn {slug, description} ->
        %{
          "slug" => slug,
          "name" => slug |> String.downcase() |> String.replace("_", " ") |> String.capitalize(),
          "description" => description,
          "toolkit" => %{"slug" => toolkit},
          "input_parameters" => input_parameters(slug)
        }
      end)
    end

    defp input_parameters(tool_slug) do
      {properties, required} = tool_input(tool_slug)
      schema = %{"type" => "object", "properties" => properties}
      if required == [], do: schema, else: Map.put(schema, "required", required)
    end

    # {properties, required inputs} per slug — one table drives both the
    # advertised input schema and execute-time validation.
    defp tool_input("SLACK_SEARCH_FOR_MESSAGES_WITH_QUERY") do
      {%{
         "query" => %{"type" => "string"},
         "count" => %{"type" => "integer"},
         "sort" => %{"type" => "string"},
         "sort_dir" => %{"type" => "string"}
       }, ["query"]}
    end

    defp tool_input("GMAIL_FETCH_EMAILS") do
      {%{
         "query" => %{"type" => "string"},
         "max_results" => %{"type" => "integer"},
         "include_payload" => %{"type" => "boolean"}
       }, []}
    end

    defp tool_input("GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER") do
      {%{
         "all" => %{"type" => "boolean"},
         "participating" => %{"type" => "boolean"},
         "page" => %{"type" => "integer"},
         "per_page" => %{"type" => "integer"}
       }, []}
    end

    defp tool_input("GITHUB_GET_A_PULL_REQUEST") do
      {%{
         "owner" => %{"type" => "string"},
         "repo" => %{"type" => "string"},
         "pull_number" => %{"type" => "integer"}
       }, ["owner", "repo", "pull_number"]}
    end

    defp tool_input("LINEAR_RUN_QUERY_OR_MUTATION") do
      {%{
         "query_or_mutation" => %{"type" => "string"},
         "variables" => %{"type" => "object"}
       }, ["query_or_mutation", "variables"]}
    end

    defp tool_input("NOTION_FETCH_DATA") do
      {%{
         "get_pages" => %{"type" => "boolean"},
         "page_size" => %{"type" => "integer"}
       }, []}
    end

    # Composio's NOTION_FETCH_ROW takes the page's UUID as `page_id`.
    defp tool_input("NOTION_FETCH_ROW"),
      do: {%{"page_id" => %{"type" => "string"}}, ["page_id"]}

    defp tool_input("GOOGLECALENDAR_EVENTS_LIST") do
      {%{
         "calendarId" => %{"type" => "string"},
         "timeMin" => %{"type" => "string"},
         "timeMax" => %{"type" => "string"},
         "maxResults" => %{"type" => "integer"},
         "singleEvents" => %{"type" => "boolean"},
         "orderBy" => %{"type" => "string"}
       }, ["calendarId"]}
    end

    defp tool_input("GOOGLEDRIVE_LIST_FILES") do
      {%{
         "q" => %{"type" => "string"},
         "orderBy" => %{"type" => "string"},
         "pageSize" => %{"type" => "integer"}
       }, []}
    end

    defp tool_input(_tool_slug), do: {%{"query" => %{"type" => "string"}}, []}

    defp maybe_filter_toolkit(tools, nil), do: tools

    defp maybe_filter_toolkit(tools, toolkit),
      do: Enum.filter(tools, &(toolkit_slug(&1) == normalize_toolkit(toolkit)))

    defp maybe_filter_slugs(tools, nil), do: tools

    defp maybe_filter_slugs(tools, slugs) do
      wanted = slugs |> List.wrap() |> Enum.map(&(to_string(&1) |> String.upcase()))
      Enum.filter(tools, &(String.upcase(&1["slug"]) in wanted))
    end

    defp matching_account(accounts, toolkit, nil),
      do: Enum.find(accounts, &(toolkit_slug(&1) == toolkit))

    defp matching_account(accounts, toolkit, id),
      do: Enum.find(accounts, &(&1["id"] == id and toolkit_slug(&1) == toolkit))

    defp toolkit_slug(value),
      do: get_in(value, ["toolkit", "slug"]) || value["toolkit_slug"] || value["toolkit"]

    defp normalize_toolkit(value), do: value |> to_string() |> String.trim() |> String.downcase()

    defp toolkit_for_slug(slug) do
      slug = slug |> to_string() |> String.upcase()

      Enum.find(@toolkits, fn toolkit ->
        Enum.any?(Map.fetch!(@toolkit_tools, toolkit), &(elem(&1, 0) == slug)) or
          String.starts_with?(slug, String.upcase(toolkit) <> "_")
      end)
    end

    defp humanize(value), do: value |> String.replace(~r/[_-]+/, " ") |> String.capitalize()
  end
end
