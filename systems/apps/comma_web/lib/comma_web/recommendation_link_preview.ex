defmodule CommaWeb.RecommendationLinkPreview do
  @moduledoc false

  alias Salix.Bindings.GoogleCalendarError

  # On-demand hover metadata for recommendation inline links. The published
  # snapshot only carries `href`/`label`/`sourceId`, so the richer preview is
  # read lazily through the link's own connected account — the client never
  # talks to the provider. Supported link shapes, each read live:
  #
  #   * GitHub pull requests        -> state, title, author, diff, files
  #   * Linear issues               -> state, title, assignee, priority
  #   * Notion pages                -> title, icon, parent, edit time
  #   * Google Calendar events      -> the exact copy (calendar id + event id,
  #                                    never the shared iCalUID), only when the
  #                                    event is public
  #   * Slack messages              -> text, channel, author (the permalink's
  #                                    channel id + ts matched exactly, thread
  #                                    replies included, only after `auth.test`
  #                                    confirms the permalink's workspace)
  #   * Google Drive files          -> name, kind, owner, size, edit time
  #
  # Everything else (Gmail in particular: mail bodies are private) is
  # `:not_found`, and the client keeps its generic destination card.

  @github_pull_request ~r"^https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)(?:[/?#].*)?$"
  @linear_issue ~r"^https://linear\.app/[\w-]+/issue/([A-Za-z][A-Za-z0-9]*-\d+)(?:[/?#].*)?$"
  @notion_page ~r"^https://(?:www\.)?notion\.so/(?:[^/?#]+/)?(?:[^/?#]*?-)?([0-9a-fA-F]{32})(?:[/?#].*)?$"
  @calendar_event ~r"^https://(?:www\.google\.com|calendar\.google\.com)/calendar/(?:u/\d+/)?(?:r/)?(?:event\?(?:[^#]*&)?eid=([\w=-]+)|eventedit/([\w=-]+))"
  @slack_message ~r"^https://([\w-]+\.slack\.com)/archives/([A-Z0-9]+)/p(\d{10,})(?:[/?#].*)?$"
  # Real Drive/Docs file ids are long; a short segment is a link-shape
  # artifact — `/d/e/` published links capture a literal "e" otherwise.
  @google_drive_doc ~r"^https://docs\.google\.com/(?:document|spreadsheets|presentation|forms)/d/([\w-]{10,})(?:[/?#].*)?$"
  @google_drive_file ~r"^https://drive\.google\.com/file/d/([\w-]{10,})(?:[/?#].*)?$"
  @google_drive_open ~r"^https://drive\.google\.com/open\?(?:[^#]*&)?id=([\w-]{10,})"

  @pull_request_tool "GITHUB_GET_A_PULL_REQUEST"
  @linear_tool "LINEAR_RUN_QUERY_OR_MUTATION"
  @notion_tool "NOTION_FETCH_ROW"
  @google_calendar_api "https://www.googleapis.com/calendar/v3"
  @google_drive_api "https://www.googleapis.com/drive/v3"
  @slack_api "https://slack.com/api"

  @linear_issue_query """
  query CommaRecommendationLinkPreview($id: String!) {
    issue(id: $id) {
      identifier
      title
      url
      priority
      priorityLabel
      updatedAt
      state { name type color }
      assignee { name displayName avatarUrl }
      team { key }
      project { name }
    }
  }
  """

  def preview(workspace, sources, href, source_id) when is_map(workspace) do
    with {:ok, target} <- parse_href(href),
         {:ok, source} <- resolve_source(sources, source_id, toolkit(target)),
         {:ok, settings} <- settings_store().settings(workspace["salix_tenant_id"]) do
      read(target, settings, workspace, source, String.trim(href))
    end
  end

  @doc false
  def parse_href(href) when is_binary(href) do
    href = String.trim(href)

    cond do
      match = Regex.run(@github_pull_request, href) ->
        [_, owner, repo, number] = match
        {:ok, {:github_pull_request, owner, repo, String.to_integer(number)}}

      match = Regex.run(@linear_issue, href) ->
        [_, identifier] = match
        {:ok, {:linear_issue, String.upcase(identifier)}}

      match = Regex.run(@notion_page, href) ->
        [_, hex] = match
        {:ok, {:notion_page, String.downcase(hex)}}

      match = Regex.run(@calendar_event, href) ->
        case decode_calendar_eid(Enum.find(tl(match), &(is_binary(&1) and &1 != ""))) do
          {:ok, event_id, calendar_id} -> {:ok, {:google_calendar_event, event_id, calendar_id}}
          :error -> {:error, :not_found}
        end

      match = Regex.run(@slack_message, href) ->
        [_, host, channel_id, digits] = match
        ts = slack_ts(digits)
        {:ok, {:slack_message, host, channel_id, ts, slack_thread_ts(href, ts)}}

      match =
          Regex.run(@google_drive_doc, href) || Regex.run(@google_drive_file, href) ||
            Regex.run(@google_drive_open, href) ->
        [_, file_id] = match
        {:ok, {:google_drive_file, file_id}}

      true ->
        {:error, :not_found}
    end
  end

  def parse_href(_href), do: {:error, {:bad_request, "href is required"}}

  defp toolkit({:github_pull_request, _owner, _repo, _number}), do: "github"
  defp toolkit({:linear_issue, _identifier}), do: "linear"
  defp toolkit({:notion_page, _id}), do: "notion"
  defp toolkit({:google_calendar_event, _event_id, _calendar_id}), do: "googlecalendar"
  defp toolkit({:slack_message, _host, _channel_id, _ts, _thread_ts}), do: "slack"
  defp toolkit({:google_drive_file, _file_id}), do: "googledrive"

  # The `eid` is base64 of "<eventId> <calendar email>" (Google's own link
  # shape); the calendar half is optional and falls back to `primary`.
  defp decode_calendar_eid(nil), do: :error

  defp decode_calendar_eid(eid) do
    padded = eid |> String.replace("-", "+") |> String.replace("_", "/")
    padded = padded <> String.duplicate("=", rem(4 - rem(String.length(padded), 4), 4))

    with {:ok, decoded} <- Base.decode64(padded, ignore: :whitespace),
         [event_id | rest] when event_id != "" <- String.split(decoded, " ", parts: 2) do
      {:ok, event_id, List.first(rest) || "primary"}
    else
      _ -> :error
    end
  end

  # A Slack permalink writes the message ts with its dot removed: the digits
  # after `p` split back into "<seconds>.<microseconds>" (last six digits).
  defp slack_ts(digits) do
    {seconds, micros} = String.split_at(digits, -6)
    seconds <> "." <> micros
  end

  # A reply permalink appends `thread_ts=<seconds>.<micros>` naming its
  # parent. It matters only when it differs from the message's own ts: a
  # parent link repeats the ts, and such messages live in the plain history.
  defp slack_thread_ts(href, ts) do
    case URI.decode_query(URI.parse(href).query || "") do
      %{"thread_ts" => thread_ts} when thread_ts != ts ->
        if Regex.match?(~r/^\d+\.\d+$/, thread_ts), do: thread_ts

      _ ->
        nil
    end
  end

  # The link's sourceId pins the connected account that surfaced it; a link
  # without one (or whose account is gone) may still read through any enabled
  # source of the same toolkit, but never through another toolkit's account.
  defp resolve_source(sources, source_id, toolkit) when is_list(sources) do
    candidates =
      Enum.filter(sources, fn source ->
        is_map(source) and source["enabled"] == true and source["kind"] == "composio" and
          clean(source["toolkit"] || source["appId"]) == toolkit and
          is_binary(source["connectionId"]) and source["connectionId"] != ""
      end)

    pinned =
      if is_binary(source_id) and source_id != "",
        do: Enum.find(candidates, &(&1["connectionId"] == source_id)),
        else: nil

    case pinned || List.first(candidates) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end

  defp resolve_source(_sources, _source_id, _toolkit), do: {:error, :not_found}

  # ---------------------------------------------------------------- reads

  defp read({:github_pull_request, owner, repo, number}, settings, workspace, source, href) do
    arguments = %{"owner" => owner, "repo" => repo, "pull_number" => number}

    with {:ok, data} <- execute(settings, workspace, source, @pull_request_tool, arguments) do
      {:ok, pull_request_preview(data, href, owner, repo, number)}
    end
  end

  defp read({:linear_issue, identifier}, settings, workspace, source, href) do
    arguments = %{
      "query_or_mutation" => @linear_issue_query,
      "variables" => %{"id" => identifier}
    }

    with {:ok, data} <- execute(settings, workspace, source, @linear_tool, arguments),
         %{} = issue <- data["issue"] || get_in(data, ["data", "issue"]) || :not_found do
      {:ok, linear_issue_preview(issue, href, identifier)}
    else
      :not_found -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp read({:notion_page, hex}, settings, workspace, source, href) do
    # Composio's NOTION_FETCH_ROW identifies the row by its page UUID as
    # `page_id` (a `row_id` argument fails its required-input contract).
    arguments = %{"page_id" => notion_uuid(hex)}

    with {:ok, data} <- execute(settings, workspace, source, @notion_tool, arguments),
         %{} = page <- notion_page_object(data) || :not_found do
      {:ok, notion_page_preview(page, href)}
    else
      :not_found -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Google's `id` is the exact copy locator; `iCalUID` is shared by a whole
  # series and differs for imported events, so the read is always the exact
  # event-id lookup on the decoded calendar. Composio's googlecalendar toolkit
  # exposes no get-one-event action, so that exactness comes from proxying
  # Google's own `events.get` rather than from a tool call.
  defp read({:google_calendar_event, event_id, calendar_id}, settings, workspace, source, href) do
    endpoint =
      Enum.join(
        [
          @google_calendar_api,
          "calendars",
          URI.encode(calendar_id, &URI.char_unreserved?/1),
          "events",
          URI.encode(event_id, &URI.char_unreserved?/1)
        ],
        "/"
      )

    with {:ok, data} <-
           proxy_get(settings, workspace, source, "googlecalendar", endpoint,
             provider_error: &calendar_provider_error/2
           ),
         %{} = event <- calendar_event_object(data, event_id) || :not_found,
         true <- previewable_calendar_event?(event) || :not_found do
      {:ok, calendar_event_preview(event, href)}
    else
      :not_found -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Composio's slack toolkit has no permalink resolver, and Slack itself
  # locates a message only by channel + ts, so the read proxies the Web API
  # directly: the session first binds the permalink's workspace subdomain via
  # `auth.test`, then the message itself is required, while the channel name
  # and the author are best-effort garnishes fetched through the same session.
  defp read({:slack_message, host, channel_id, ts, thread_ts}, settings, workspace, source, href) do
    with {:ok, message, channel_name, author} <-
           slack_message_get(settings, workspace, source, host, channel_id, ts, thread_ts) do
      {:ok, slack_message_preview(message, channel_id, channel_name, author, href)}
    end
  end

  # Composio's googledrive toolkit reads files only through search-shaped
  # actions, so the exact by-id lookup proxies Drive's own `files.get`.
  defp read({:google_drive_file, file_id}, settings, workspace, source, href) do
    endpoint =
      @google_drive_api <>
        "/files/" <>
        URI.encode(file_id, &URI.char_unreserved?/1) <>
        "?fields=id,name,mimeType,modifiedTime,webViewLink,owners(displayName,photoLink),size" <>
        "&supportsAllDrives=true"

    with {:ok, file} <-
           proxy_get(settings, workspace, source, "googledrive", endpoint,
             provider_error: &drive_provider_error/2
           ) do
      {:ok, google_drive_file_preview(file, href)}
    end
  end

  # A Tool Router session is per-attempt: the preview is a single read, and a
  # leaked session would outlive the hover that asked for it. `fun` gets the
  # open session id and performs the provider requests; only a
  # `:proxy_session_missing` it lets through participates in the one bounded
  # missing-session replacement modeled in
  # tla/recommendations/RecommendationLinkPreviewProxy.tla.
  defp proxy_read(settings, workspace, source, toolkit, fun),
    do: proxy_read(settings, workspace, source, toolkit, fun, true)

  defp proxy_read(settings, workspace, source, toolkit, fun, retry_session?) do
    with {:ok, session_id} <- proxy_session(settings, workspace, source, toolkit) do
      result =
        case fun.(session_id) do
          # The Tool Router session endpoint was missing, not the provider's
          # object. Replace one missing session; a second miss is an
          # unavailable dependency rather than evidence about the object.
          {:error, :proxy_session_missing} when retry_session? ->
            :retry_proxy_session

          {:error, :proxy_session_missing} ->
            {:error, {:unavailable, :composio_proxy_session_unavailable}}

          other ->
            other
        end

      _ = composio_client().delete_proxy_session(settings, session_id)

      case result do
        :retry_proxy_session ->
          proxy_read(settings, workspace, source, toolkit, fun, false)

        other ->
          other
      end
    end
  end

  # The whole-session convenience for a read that is exactly one GET.
  defp proxy_get(settings, workspace, source, toolkit, endpoint, opts) do
    proxy_read(settings, workspace, source, toolkit, fn session_id ->
      proxy_request(settings, session_id, toolkit, endpoint, opts)
    end)
  end

  # One native GET through an open Tool Router session. A transport-level
  # `{:error, :not_found}` is the session endpoint itself missing — surfaced
  # as `:proxy_session_missing` so callers can tell it apart from any provider
  # answer.
  defp proxy_request(settings, session_id, toolkit, endpoint, opts) do
    request = %{
      "toolkit_slug" => toolkit,
      "endpoint" => endpoint,
      "method" => "GET"
    }

    case composio_client().proxy_execute(settings, session_id, request, error_mode: :structured) do
      {:ok, %{"status" => 200, "data" => data}} when is_map(data) ->
        {:ok, data}

      # A provider-level missing/deleted object is the only proxy response
      # that changes the domain fact to not-found.
      {:ok, %{"status" => status}} when status in [404, 410] ->
        {:error, :not_found}

      {:ok, %{"status" => status} = response} when is_integer(status) ->
        opts[:provider_error].(status, response["data"])

      {:error, :not_found} ->
        {:error, :proxy_session_missing}

      {:error, reason} ->
        {:error, {:unavailable, reason}}

      _other ->
        {:error, {:unavailable, :invalid_provider_response}}
    end
  end

  defp calendar_provider_error(status, data) when status in [403, 429] do
    reason = GoogleCalendarError.from_http_response(status, data)
    {:error, {:unavailable, reason}}
  end

  defp calendar_provider_error(status, _data),
    do: {:error, {:unavailable, {:google_calendar_http, status}}}

  defp slack_provider_error(status, _data),
    do: {:error, {:unavailable, {:slack_http, status}}}

  defp drive_provider_error(status, _data),
    do: {:error, {:unavailable, {:google_drive_http, status}}}

  defp proxy_session(settings, workspace, source, toolkit) do
    case composio_client().create_proxy_session(
           settings,
           workspace["default_group_id"],
           source["connectionId"],
           toolkit,
           error_mode: :structured
         ) do
      {:ok, session_id} when is_binary(session_id) and session_id != "" ->
        {:ok, session_id}

      {:error, reason} ->
        {:error, {:unavailable, reason}}

      _other ->
        {:error, {:unavailable, :invalid_provider_response}}
    end
  end

  # Google omits `visibility` entirely when an event inherits its calendar's
  # default, which is the overwhelming majority of them, so requiring an
  # explicit "public" left every ordinary event link-only. The reader here is
  # the calendar's own connected account, so only an author's explicit private
  # or confidential marking withholds the detail.
  defp previewable_calendar_event?(event) do
    event["visibility"] not in ["private", "confidential"]
  end

  defp execute(settings, workspace, source, tool, arguments) do
    case composio_client().execute_tool(
           settings,
           tool,
           workspace["default_group_id"],
           arguments,
           connected_account_id: source["connectionId"],
           error_mode: :structured
         ) do
      {:ok, %{"successful" => true, "data" => data}} when is_map(data) ->
        {:ok, data}

      {:ok, %{"successful" => false} = envelope} ->
        {:error, {:unavailable, {:provider_failed, envelope["error"]}}}

      {:ok, _envelope} ->
        {:error, {:unavailable, :invalid_provider_response}}

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  # ------------------------------------------------------- GitHub mapping

  # Composio wraps some GitHub reads in a `details` object; accept both.
  defp pull_request_preview(%{"details" => %{} = details} = data, href, owner, repo, number)
       when not is_map_key(data, "title"),
       do: pull_request_preview(details, href, owner, repo, number)

  defp pull_request_preview(data, href, owner, repo, number) do
    author = data["user"]

    %{
      "kind" => "github_pull_request",
      "href" => string(data["html_url"]) || href,
      "repository" => get_in(data, ["base", "repo", "full_name"]) || "#{owner}/#{repo}",
      "number" => integer(data["number"]) || number,
      "title" => string(data["title"]) || "#{owner}/#{repo} ##{number}",
      "state" => pull_request_state(data),
      "author" =>
        if is_map(author) and is_binary(author["login"]) do
          %{"login" => author["login"], "avatarUrl" => string(author["avatar_url"])}
        end,
      "additions" => integer(data["additions"]),
      "deletions" => integer(data["deletions"]),
      "changedFiles" => integer(data["changed_files"]),
      "updatedAt" => unix_ms(data["merged_at"]) || unix_ms(data["updated_at"])
    }
  end

  defp pull_request_state(%{"merged" => true}), do: "merged"
  defp pull_request_state(%{"merged_at" => merged_at}) when is_binary(merged_at), do: "merged"
  defp pull_request_state(%{"state" => "closed"}), do: "closed"
  defp pull_request_state(%{"draft" => true}), do: "draft"
  defp pull_request_state(_data), do: "open"

  # ------------------------------------------------------- Linear mapping

  defp linear_issue_preview(issue, href, identifier) do
    assignee = issue["assignee"]
    state = issue["state"]

    %{
      "kind" => "linear_issue",
      "href" => string(issue["url"]) || href,
      "identifier" => string(issue["identifier"]) || identifier,
      "title" => string(issue["title"]) || identifier,
      "state" =>
        if is_map(state) and is_binary(state["name"]) do
          %{
            "name" => state["name"],
            "type" => linear_state_type(state["type"]),
            "color" => string(state["color"])
          }
        end,
      "assignee" =>
        if is_map(assignee) and
             (is_binary(assignee["displayName"]) or is_binary(assignee["name"])) do
          %{
            "name" => string(assignee["displayName"]) || assignee["name"],
            "avatarUrl" => string(assignee["avatarUrl"])
          }
        end,
      "priority" => integer(issue["priority"]),
      "priorityLabel" => string(issue["priorityLabel"]),
      "team" => string(get_in(issue, ["team", "key"])),
      "project" => string(get_in(issue, ["project", "name"])),
      "updatedAt" => unix_ms(issue["updatedAt"])
    }
  end

  @linear_state_types ~w(triage backlog unstarted started completed canceled)
  defp linear_state_type(type) when type in @linear_state_types, do: type
  defp linear_state_type("cancelled"), do: "canceled"
  defp linear_state_type(_type), do: "unstarted"

  # ------------------------------------------------------- Notion mapping

  defp notion_uuid(hex) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    Enum.join([a, b, c, d, e], "-")
  end

  defp notion_page_object(%{"properties" => %{}} = page), do: page

  defp notion_page_object(data) do
    Enum.find_value(["row", "page", "data", "result"], fn key ->
      case data[key] do
        %{"properties" => %{}} = page -> page
        _ -> nil
      end
    end)
  end

  defp notion_page_preview(page, href) do
    parent = page["parent"]

    %{
      "kind" => "notion_page",
      "href" => string(page["url"]) || href,
      "title" => notion_title(page) || "Untitled",
      "icon" => notion_icon(page["icon"]),
      "parent" =>
        case parent do
          %{"type" => "database_id"} -> "database"
          %{"type" => "page_id"} -> "page"
          %{"type" => "block_id"} -> "page"
          _ -> "workspace"
        end,
      "archived" => page["archived"] == true or page["in_trash"] == true,
      "createdAt" => unix_ms(page["created_time"]),
      "updatedAt" => unix_ms(page["last_edited_time"])
    }
  end

  defp notion_title(%{"properties" => properties}) when is_map(properties) do
    properties
    |> Map.values()
    |> Enum.find_value(fn
      %{"type" => "title", "title" => parts} when is_list(parts) -> rich_text(parts)
      %{"title" => parts} when is_list(parts) -> rich_text(parts)
      _ -> nil
    end)
  end

  defp notion_title(_page), do: nil

  defp rich_text(parts) do
    parts
    |> Enum.map(fn
      %{"plain_text" => text} when is_binary(text) -> text
      %{"text" => %{"content" => text}} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join()
    |> String.trim()
    |> string()
  end

  defp notion_icon(%{"type" => "emoji", "emoji" => emoji}) when is_binary(emoji), do: emoji
  defp notion_icon(%{"emoji" => emoji}) when is_binary(emoji), do: emoji
  defp notion_icon(_icon), do: nil

  # ------------------------------------------------ Google Calendar mapping

  # The GET answer is one event, sometimes wrapped; it must be the event we
  # asked for — never some other item.
  # Google's `events.get` answers with the bare Event resource. Confirming the
  # id round-trips is what keeps a series master or a redirected copy from
  # being presented as the event the link named.
  defp calendar_event_object(data, event_id) do
    if data["id"] == event_id, do: data
  end

  defp calendar_event_preview(event, href) do
    {starts_at, all_day} = calendar_time(event["start"])
    {ends_at, _} = calendar_time(event["end"])
    organizer = event["organizer"]
    attendees = event["attendees"]

    %{
      "kind" => "google_calendar_event",
      "href" => string(event["htmlLink"]) || href,
      "title" => string(event["summary"]) || "(No title)",
      "status" =>
        case event["status"] do
          status when status in ["confirmed", "tentative", "cancelled"] -> status
          _ -> "confirmed"
        end,
      "allDay" => all_day,
      "startsAt" => starts_at,
      "endsAt" => ends_at,
      "location" => string(event["location"]),
      "organizer" =>
        if is_map(organizer) and
             (is_binary(organizer["displayName"]) or is_binary(organizer["email"])) do
          %{"name" => string(organizer["displayName"]) || organizer["email"]}
        end,
      "attendeeCount" => if(is_list(attendees), do: length(attendees)),
      "meetingUrl" => string(event["hangoutLink"]) || conference_url(event["conferenceData"]),
      "updatedAt" => unix_ms(event["updated"])
    }
  end

  defp calendar_time(%{"dateTime" => date_time}) when is_binary(date_time),
    do: {unix_ms(date_time), false}

  defp calendar_time(%{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, day} ->
        {day |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix(:millisecond), true}

      _ ->
        {nil, true}
    end
  end

  defp calendar_time(_value), do: {nil, false}

  defp conference_url(%{"entryPoints" => points}) when is_list(points) do
    Enum.find_value(points, fn
      %{"entryPointType" => "video", "uri" => uri} when is_binary(uri) -> uri
      _ -> nil
    end)
  end

  defp conference_url(_data), do: nil

  # -------------------------------------------------------- Slack mapping

  defp slack_message_get(settings, workspace, source, host, channel_id, ts, thread_ts) do
    proxy_read(settings, workspace, source, "slack", fn session_id ->
      with :ok <- slack_workspace_check(settings, session_id, host),
           {:ok, data} <-
             proxy_request(
               settings,
               session_id,
               "slack",
               slack_message_endpoint(channel_id, ts, thread_ts),
               provider_error: &slack_provider_error/2
             ),
           {:ok, message} <- slack_message(data, ts, thread_ts) do
        {:ok, message, slack_channel_name(settings, session_id, channel_id),
         slack_author(settings, session_id, message["user"])}
      end
    end)
  end

  # A permalink names its workspace in the subdomain, and the connected
  # account answers for exactly one workspace — without this binding,
  # `https://evil.slack.com/...` would dress a foreign link in a genuine
  # preview from the victim's workspace. The session's first request pins the
  # team via `auth.test` before any message is touched: a foreign subdomain
  # is a plain not-found, and an unverifiable team (transport failure,
  # `ok: false`) never skips the check.
  defp slack_workspace_check(settings, session_id, host) do
    endpoint = @slack_api <> "/auth.test"

    case proxy_request(settings, session_id, "slack", endpoint,
           provider_error: &slack_provider_error/2
         ) do
      {:ok, %{"ok" => true, "url" => url}} when is_binary(url) ->
        case URI.parse(url).host do
          team_host when is_binary(team_host) and team_host != "" ->
            if String.downcase(team_host) == String.downcase(host),
              do: :ok,
              else: {:error, :not_found}

          _ ->
            {:error, {:unavailable, :invalid_provider_response}}
        end

      {:ok, %{"ok" => false} = data} ->
        {:error, {:unavailable, {:slack_api, data["error"]}}}

      {:ok, _data} ->
        {:error, {:unavailable, :invalid_provider_response}}

      # `:proxy_session_missing` keeps the one bounded session replacement
      # bound to the session's first request; other errors surface as-is.
      {:error, _reason} = error ->
        error
    end
  end

  # A plain permalink reads through `conversations.history`. A thread reply
  # never appears there, so a permalink carrying a distinct `thread_ts` reads
  # through `conversations.replies` pinned to the same exact message ts.
  defp slack_message_endpoint(channel_id, ts, nil) do
    slack_endpoint("conversations.history", [
      {"channel", channel_id},
      {"latest", ts},
      {"inclusive", "true"},
      {"limit", "1"}
    ])
  end

  defp slack_message_endpoint(channel_id, ts, thread_ts) do
    slack_endpoint("conversations.replies", [
      {"channel", channel_id},
      {"ts", thread_ts},
      {"latest", ts},
      {"inclusive", "true"},
      {"limit", "1"}
    ])
  end

  # `latest=<ts>&inclusive=true&limit=1` answers with the message at or before
  # ts, so only an exact ts match is the linked message — anything else means
  # it was deleted or never existed.
  defp slack_message(%{"ok" => true} = data, ts, nil) do
    case data["messages"] do
      [%{"ts" => ^ts} = message | _] -> {:ok, message}
      _ -> {:error, :not_found}
    end
  end

  # `conversations.replies` answers with the thread parent first even when
  # `latest` pins a reply, so the linked reply is the exact-ts match anywhere
  # in the returned window — never just the head.
  defp slack_message(%{"ok" => true} = data, ts, _thread_ts) do
    with messages when is_list(messages) <- data["messages"],
         %{} = message <- Enum.find(messages, &match?(%{"ts" => ^ts}, &1)) do
      {:ok, message}
    else
      _ -> {:error, :not_found}
    end
  end

  # Slack fails inside an HTTP 200: `ok: false` plus an error slug. A missing
  # channel, message, or thread is the domain not-found; everything else
  # (missing scope, rate limit) is an unavailable provider.
  @slack_missing_errors ~w(channel_not_found message_not_found thread_not_found)

  defp slack_message(%{"ok" => false, "error" => error}, _ts, _thread_ts)
       when error in @slack_missing_errors,
       do: {:error, :not_found}

  defp slack_message(%{"ok" => false} = data, _ts, _thread_ts),
    do: {:error, {:unavailable, {:slack_api, data["error"]}}}

  defp slack_message(_data, _ts, _thread_ts),
    do: {:error, {:unavailable, :invalid_provider_response}}

  defp slack_channel_name(settings, session_id, channel_id) do
    endpoint = slack_endpoint("conversations.info", [{"channel", channel_id}])

    case proxy_request(settings, session_id, "slack", endpoint,
           provider_error: &slack_provider_error/2
         ) do
      {:ok, %{"ok" => true, "channel" => %{"name" => name}}} -> string(name)
      _ -> nil
    end
  end

  defp slack_author(settings, session_id, user_id) when is_binary(user_id) and user_id != "" do
    endpoint = slack_endpoint("users.info", [{"user", user_id}])

    case proxy_request(settings, session_id, "slack", endpoint,
           provider_error: &slack_provider_error/2
         ) do
      {:ok, %{"ok" => true, "user" => %{} = user}} ->
        profile = if is_map(user["profile"]), do: user["profile"], else: %{}

        name =
          string(profile["display_name"]) || string(profile["real_name"]) ||
            string(user["real_name"]) || string(user["name"])

        if name do
          %{
            "name" => name,
            "avatarUrl" => string(profile["image_72"]) || string(profile["image_48"])
          }
        end

      _ ->
        nil
    end
  end

  defp slack_author(_settings, _session_id, _user_id), do: nil

  defp slack_endpoint(method, params),
    do: @slack_api <> "/" <> method <> "?" <> URI.encode_query(params)

  defp slack_message_preview(message, channel_id, channel_name, author, href) do
    %{
      "kind" => "slack_message",
      "href" => href,
      "channel" => %{"id" => channel_id, "name" => channel_name},
      "author" => author,
      "text" => slack_text(message["text"]),
      "postedAt" => slack_ts_ms(message["ts"])
    }
  end

  @slack_text_limit 280

  defp slack_text(text) when is_binary(text) do
    if String.length(text) > @slack_text_limit,
      do: String.slice(text, 0, @slack_text_limit - 1) <> "…",
      else: text
  end

  defp slack_text(_text), do: ""

  defp slack_ts_ms(ts) when is_binary(ts) do
    with [seconds, micros] <- String.split(ts, ".", parts: 2),
         {seconds, ""} <- Integer.parse(seconds),
         {micros, ""} <- Integer.parse(micros) do
      seconds * 1000 + div(micros, 1000)
    else
      _ -> nil
    end
  end

  defp slack_ts_ms(_ts), do: nil

  # -------------------------------------------------- Google Drive mapping

  @drive_file_kinds %{
    "application/vnd.google-apps.document" => "document",
    "application/vnd.google-apps.spreadsheet" => "spreadsheet",
    "application/vnd.google-apps.presentation" => "presentation",
    "application/vnd.google-apps.form" => "form",
    "application/vnd.google-apps.folder" => "folder",
    "application/pdf" => "pdf"
  }

  defp google_drive_file_preview(file, href) do
    %{
      "kind" => "google_drive_file",
      "href" => string(file["webViewLink"]) || href,
      "title" => string(file["name"]) || "Untitled",
      "fileKind" => Map.get(@drive_file_kinds, file["mimeType"], "file"),
      "owner" => drive_owner(file["owners"]),
      "modifiedAt" => unix_ms(file["modifiedTime"]),
      "size" => drive_size(file["size"])
    }
  end

  # Drive can answer an owner whose `displayName` is the empty string (e.g. a
  # domain-owned file); like the Slack author, the owner card renders only
  # with a real name.
  defp drive_owner([owner | _rest]) when is_map(owner) do
    name = string(owner["displayName"])

    if name do
      %{"name" => name, "avatarUrl" => string(owner["photoLink"])}
    end
  end

  defp drive_owner(_owners), do: nil

  # Drive reports `size` as a decimal string (int64 outgrows a JSON number).
  defp drive_size(value) when is_integer(value), do: value

  defp drive_size(value) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} -> size
      _ -> nil
    end
  end

  defp drive_size(_value), do: nil

  # -------------------------------------------------------------- helpers

  defp unix_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp unix_ms(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp clean(nil), do: ""
  defp clean(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp settings_store,
    do:
      Application.get_env(
        :comma_web,
        :recommendation_composio_settings_mod,
        SalixAgent.ComposioStore
      )

  defp composio_client,
    do:
      Application.get_env(
        :comma_web,
        :recommendation_composio_client_mod,
        Application.get_env(:salix_agent, :composio_client_mod, SalixStore.Composio)
      )
end
