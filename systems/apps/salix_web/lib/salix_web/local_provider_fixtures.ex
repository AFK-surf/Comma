if Application.compile_env(:salix_web, :local_recommendation_mock_compiled, false) do
  defmodule SalixWeb.LocalProviderFixtures do
    @moduledoc """
    The single local demo world behind every mocked provider read.

    `SalixWeb.LocalComposioMock` (Composio tool executions and Tool Router
    proxy reads) and
    `SalixWeb.LocalOAuthMock` (the `comma_local_search` remote-MCP tool) both
    project the entities defined here, so the same Slack thread, email, pull
    request, issues, page, event, and document appear consistently whichever
    transport a surface reads through.

    Two contracts this module keeps deliberately:

      * **Provider-faithful shapes.** Each `*_data` function returns the same
        JSON shape the real provider returns through Composio, including each
        record's own stable web link (`permalink`, `url`, `htmlLink`,
        `webViewLink`), so production collection, truncation, link-evidence,
        and rendering code paths run unmodified against local data. Records
        with no self-referencing URL (Gmail, Notion, GitHub notifications)
        stay link-free here exactly like production; the collector derives
        their links.
      * **Now-relative timestamps.** Every timestamp derives from
        `DateTime.utc_now/0` at read time, so "recent activity" fixtures stay
        inside the recipes' recency windows instead of drifting into the past
        as the hardcoded values age. Slack timestamps are the exception: they
        are part of the permalink, so they derive from the node's boot time.

    Links keep real provider hosts (`*.slack.com`, `linear.app`, ...) because
    client preview and link handling key on production URL shapes. The GitHub
    entities point at this repository's real PR #845 and resolve; the other
    hosts reference workspaces that only exist in this demo world, so opening
    them outside the local stack lands on the provider's not-found page.
    """

    @slack_team_id "TCOMMALOCAL"
    @slack_member_id "UCOMMALOCAL"
    @slack_workspace_url "https://comma-local.slack.com"
    @slack_release_channel %{"id" => "C01234567", "name" => "release"}
    @slack_launch_channel %{"id" => "C0LAUNCH89", "name" => "launch"}

    @slack_users %{
      "U_COMMA_DANA" => %{
        name: "dana",
        real_name: "Dana Wu",
        image_72: "https://avatars.slack-edge.com/2026-06-02/8973412650129_dana2c7f_72.png"
      },
      "U_COMMA_MILO" => %{
        name: "milo",
        real_name: "Milo Chen",
        image_72: "https://avatars.slack-edge.com/2026-06-02/8973412650130_milo9e1b_72.png"
      }
    }

    @github_repo "AFK-surf/Comma"
    @github_pull_number 845

    @linear_issues [
      %{
        identifier: "COMMA-143",
        title: "Fix onboarding crash on first launch",
        state: %{"name" => "In Review", "type" => "started", "color" => "#f2c94c"},
        priority: 2,
        priority_label: "High"
      },
      %{
        identifier: "COMMA-151",
        title: "Ship the launch checklist",
        state: %{"name" => "In Progress", "type" => "started", "color" => "#5e6ad2"},
        priority: 1,
        priority_label: "Urgent"
      }
    ]

    @notion_page_id "4b8e7d0d-9f1a-4ed8-9d6b-a8d11080a812"

    @calendar_event_id "evt123"
    @calendar_email "local@comma.test"
    @drive_member_permission_id "05553201938472910001"
    @drive_dana_permission_id "05553201938472910002"

    # Shaped like a real Google Docs file id (44 url-safe chars).
    @drive_document_id "1CommaLocalLaunchBrief_zX9tR4mQ7wA2bN8vC5dE1gH"

    # ---- Slack: search.messages ----

    def slack_release_thread do
      ts = slack_ts(hours_before_boot(2))

      %{
        "iid" => "local-slack-release",
        "team" => @slack_team_id,
        "score" => 0.99,
        "type" => "message",
        "channel" => channel_with_flags(@slack_release_channel),
        "user" => "U_COMMA_DANA",
        "username" => "dana",
        "ts" => ts,
        "text" =>
          "Are we go for the 0.9 release? Milo and I are waiting on your decision before we cut the build.",
        "blocks" => [
          %{
            "type" => "rich_text",
            "block_id" => "local",
            "elements" => [
              %{
                "type" => "rich_text_section",
                "elements" => [%{"type" => "text", "text" => "Are we go for the 0.9 release?"}]
              }
            ]
          }
        ],
        "permalink" => slack_permalink(@slack_release_channel["id"], ts)
      }
    end

    def slack_launch_mention do
      ts = slack_ts(hours_before_boot(5))

      %{
        "iid" => "local-slack-launch",
        "team" => @slack_team_id,
        "score" => 0.87,
        "type" => "message",
        "channel" => channel_with_flags(@slack_launch_channel),
        "user" => "U_COMMA_MILO",
        "username" => "milo",
        "ts" => ts,
        "text" =>
          "<@#{@slack_member_id}> can you confirm who owns the rollout checklist? I'd like to close it out today.",
        "permalink" => slack_permalink(@slack_launch_channel["id"], ts)
      }
    end

    def slack_search_data(query),
      do:
        slack_search(query || "recent activity", [slack_release_thread(), slack_launch_mention()])

    @doc """
    `search.messages` read through the proxy, answered by the query's
    operators the way Slack evaluates them: a mention search finds the
    messages that mention the local member. This world has no direct
    messages and no threads the member joined.
    """
    def slack_search_messages_data(query) do
      query = to_string(query)
      mention = "<@#{@slack_member_id}>"

      matches =
        Enum.filter([slack_release_thread(), slack_launch_mention()], fn message ->
          cond do
            String.starts_with?(query, "to:me") -> message["channel"]["is_im"]
            String.starts_with?(query, "is:thread") -> message["permalink"] =~ "thread_ts="
            true -> String.contains?(message["text"], mention)
          end
        end)

      slack_search(query, matches)
    end

    defp slack_search(query, matches) do
      %{
        "ok" => true,
        "query" => to_string(query),
        "messages" => %{
          "total" => length(matches),
          "matches" => matches,
          "pagination" => %{"total_count" => length(matches), "page" => 1, "page_count" => 1}
        }
      }
    end

    defp channel_with_flags(channel) do
      Map.merge(channel, %{
        "is_channel" => true,
        "is_group" => false,
        "is_im" => false,
        "is_mpim" => false,
        "is_private" => false,
        "is_shared" => false
      })
    end

    defp slack_permalink(channel_id, ts) do
      "#{@slack_workspace_url}/archives/#{channel_id}/p#{String.replace(ts, ".", "")}"
    end

    # Slack message timestamps are "<unix seconds>.<6-digit sequence>".
    defp slack_ts(datetime), do: "#{DateTime.to_unix(datetime)}.000200"

    # ---- Slack: Web API proxy reads for the message link preview ----
    # Slack's Web API answers HTTP 200 with `"ok" => false` for unknown
    # records; only transport failures change the status code.

    @doc """
    The workspace identity behind every proxied Slack read (`auth.test`).
    The link preview requires the session's first request to name the team
    whose subdomain the permalink carries, so the fixture workspace matches
    the host `slack_permalink/2` writes into every stored link.
    """
    def slack_auth_test_data do
      %{
        "ok" => true,
        "url" => "#{@slack_workspace_url}/",
        "team" => "Comma Local",
        "user" => "local",
        "team_id" => @slack_team_id,
        "user_id" => @slack_member_id
      }
    end

    @doc """
    One exact message read (`conversations.history` with `latest` +
    `inclusive`). The fixture timestamps regenerate now-relative on every
    read, so the message echoes the requested `latest` ts — the same
    any-id-resolves convention as the Linear and Notion single-record reads —
    and a stored permalink keeps resolving.
    """
    def slack_history_data(channel_id, latest_ts) do
      case slack_channel_message(channel_id) do
        nil ->
          %{"ok" => false, "error" => "channel_not_found"}

        message ->
          %{"ok" => true, "messages" => [slack_history_message(message, latest_ts)]}
      end
    end

    @doc """
    One exact thread-reply read (`conversations.replies` with `latest` +
    `inclusive`). Answers exactly like `slack_history_data/2`: the
    per-channel fixture message echoes the requested `latest` ts, so a
    stored reply permalink keeps resolving; an unknown channel is Slack's
    `ok: false` answer.
    """
    def slack_replies_data(channel_id, latest_ts),
      do: slack_history_data(channel_id, latest_ts)

    def slack_channel_info_data(channel_id) do
      case slack_channel(channel_id) do
        nil -> %{"ok" => false, "error" => "channel_not_found"}
        channel -> %{"ok" => true, "channel" => channel_with_flags(channel)}
      end
    end

    def slack_user_info_data(user_id) do
      case Map.get(@slack_users, to_string(user_id)) do
        nil -> %{"ok" => false, "error" => "user_not_found"}
        user -> %{"ok" => true, "user" => slack_user(to_string(user_id), user)}
      end
    end

    defp slack_channel(channel_id) do
      Enum.find(
        [@slack_release_channel, @slack_launch_channel],
        &(&1["id"] == to_string(channel_id))
      )
    end

    defp slack_channel_message(channel_id) do
      cond do
        to_string(channel_id) == @slack_release_channel["id"] -> slack_release_thread()
        to_string(channel_id) == @slack_launch_channel["id"] -> slack_launch_mention()
        true -> nil
      end
    end

    # Slack's `conversations.history` returns message bodies without the
    # search-result envelope (channel, permalink, score).
    defp slack_history_message(message, latest_ts) do
      ts = if latest_ts in [nil, ""], do: message["ts"], else: to_string(latest_ts)

      message
      |> Map.take(["type", "user", "text", "ts", "team", "blocks"])
      |> Map.put("ts", ts)
    end

    defp slack_user(id, user) do
      %{
        "id" => id,
        "team_id" => @slack_team_id,
        "name" => user.name,
        "real_name" => user.real_name,
        "profile" => %{
          "display_name" => user.name,
          "real_name" => user.real_name,
          "image_72" => user.image_72
        }
      }
    end

    # ---- Gmail: GMAIL_FETCH_EMAILS ----

    def gmail_fetch_data do
      %{
        "messages" => [
          %{
            "messageId" => "198f2ab4c7d3e011",
            "threadId" => "198f2ab4c7d3e011",
            "subject" => "Launch approval needed",
            "sender" => "Dana Wu <dana@comma.test>",
            "to" => "Comma Local User <#{@calendar_email}>",
            "labelIds" => ["INBOX", "IMPORTANT", "UNREAD"],
            "messageTimestamp" => iso(hours_ago(3)),
            "messageText" =>
              "Hi! Legal signed off this morning, so the launch is yours to approve. " <>
                "Could you confirm today so we can lock the announcement for Thursday?"
          }
        ],
        "resultSizeEstimate" => 1
      }
    end

    # ---- Gmail: the official API read through the proxy ----

    def gmail_profile_data do
      %{
        "emailAddress" => @calendar_email,
        "messagesTotal" => 1,
        "threadsTotal" => 1,
        "historyId" => "4242"
      }
    end

    def gmail_threads_data do
      threads =
        Enum.map(gmail_fetch_data()["messages"], fn message ->
          %{
            "id" => message["threadId"],
            "snippet" => String.slice(message["messageText"], 0, 100),
            "historyId" => "4242"
          }
        end)

      %{"threads" => threads, "resultSizeEstimate" => length(threads)}
    end

    @doc """
    One `threads.get` read with `format=full`: the same approval request as
    `gmail_fetch_data/0`, in Gmail's own message shape. Any id resolves, as
    in the other single-record reads.
    """
    def gmail_thread_data(thread_id) do
      [message] = gmail_fetch_data()["messages"]
      {:ok, sent_at, _offset} = DateTime.from_iso8601(message["messageTimestamp"])
      text = message["messageText"]

      %{
        "id" => thread_id,
        "historyId" => "4242",
        "messages" => [
          %{
            "id" => message["messageId"],
            "threadId" => thread_id,
            "labelIds" => message["labelIds"],
            "snippet" => String.slice(text, 0, 100),
            "internalDate" => sent_at |> DateTime.to_unix(:millisecond) |> Integer.to_string(),
            "payload" => %{
              "mimeType" => "text/plain",
              "headers" => [
                %{"name" => "From", "value" => message["sender"]},
                %{"name" => "To", "value" => message["to"]},
                %{"name" => "Subject", "value" => message["subject"]}
              ],
              "body" => %{
                "size" => byte_size(text),
                "data" => Base.url_encode64(text, padding: false)
              }
            }
          }
        ]
      }
    end

    # ---- GitHub: notifications + one pull request ----

    def github_notifications_data do
      %{
        "details" => [
          %{
            "id" => "nt-#{@github_pull_number}",
            "unread" => true,
            "reason" => "comment",
            "updated_at" => iso(hours_ago(1)),
            "subject" => %{
              "title" => "feat(chat): add inline task elements",
              "url" =>
                "https://api.github.com/repos/#{@github_repo}/pulls/#{@github_pull_number}",
              "type" => "PullRequest"
            },
            "repository" => %{
              "full_name" => @github_repo,
              "html_url" => "https://github.com/#{@github_repo}"
            }
          }
        ]
      }
    end

    def github_pull_request_data(arguments) do
      owner_repo =
        case {arguments["owner"], arguments["repo"]} do
          {owner, repo} when is_binary(owner) and is_binary(repo) -> "#{owner}/#{repo}"
          _ -> @github_repo
        end

      number = arguments["pull_number"] || @github_pull_number
      merged_at = days_ago(8)

      %{
        "number" => number,
        "title" => "feat(chat): add inline task elements",
        "state" => "closed",
        "merged" => true,
        "draft" => false,
        "html_url" => "https://github.com/#{owner_repo}/pull/#{number}",
        "user" => %{
          "login" => "CatsJuice",
          "avatar_url" => "https://avatars.githubusercontent.com/u/0?v=4"
        },
        "base" => %{"repo" => %{"full_name" => owner_repo}},
        "additions" => 12_593,
        "deletions" => 829,
        "changed_files" => 147,
        "merged_at" => iso(merged_at),
        "updated_at" => iso(merged_at)
      }
    end

    # ---- Linear: collection query and one-issue preview query ----

    def linear_issues_data do
      %{
        "issues" => %{
          "nodes" => Enum.map(@linear_issues, &linear_issue_node/1)
        }
      }
    end

    def linear_issue_data(identifier) do
      issue =
        Enum.find(@linear_issues, List.first(@linear_issues), &(&1.identifier == identifier))

      %{
        "issue" =>
          issue
          |> Map.put(:identifier, identifier || issue.identifier)
          |> linear_issue_node()
          |> Map.merge(%{
            "priorityLabel" => issue.priority_label,
            "updatedAt" => iso(hours_ago(3)),
            "team" => %{"key" => "COMMA"}
          })
      }
    end

    defp linear_issue_node(issue) do
      %{
        "id" => "local-#{String.downcase(issue.identifier)}",
        "identifier" => issue.identifier,
        "title" => issue.title,
        "url" => "https://linear.app/comma/issue/#{issue.identifier}",
        "priority" => issue.priority,
        "state" => issue.state,
        "assignee" => %{
          "id" => "local-zanwei",
          "name" => "Zanwei Guo",
          "displayName" => "zanwei",
          "email" => @calendar_email,
          "avatarUrl" => nil
        },
        "project" => %{"id" => "local-launch", "name" => "Launch"},
        "labels" => %{"nodes" => []}
      }
    end

    # ---- Notion: NOTION_FETCH_DATA pages and NOTION_FETCH_ROW ----

    def notion_pages_data do
      %{"values" => [notion_page()]}
    end

    def notion_row_data(arguments) do
      page_id = arguments["page_id"] || @notion_page_id
      hex = String.replace(page_id, "-", "")

      notion_page()
      |> Map.merge(%{
        "id" => page_id,
        "url" => "https://www.notion.so/comma/Q3-plan-#{hex}"
      })
    end

    defp notion_page do
      hex = String.replace(@notion_page_id, "-", "")

      %{
        "id" => @notion_page_id,
        "object" => "page",
        "url" => "https://www.notion.so/comma/Q3-plan-#{hex}",
        "icon" => %{"type" => "emoji", "emoji" => "🗺️"},
        "parent" => %{"type" => "workspace", "workspace" => true},
        "created_time" => iso(days_ago(27)),
        "last_edited_time" => iso(hours_ago(3)),
        "properties" => %{
          "title" => %{"type" => "title", "title" => [%{"plain_text" => "Q3 plan"}]}
        }
      }
    end

    # ---- Google Calendar: events.list and the per-event proxy read ----

    def calendar_events_data do
      %{"kind" => "calendar#events", "items" => [calendar_event(@calendar_event_id)]}
    end

    def calendar_primary_data do
      %{
        "kind" => "calendar#calendar",
        "id" => @calendar_email,
        "summary" => @calendar_email,
        "timeZone" => "UTC"
      }
    end

    def calendar_event(event_id) do
      starts_at = DateTime.add(DateTime.utc_now(), 5 * 60 * 60, :second)
      ends_at = DateTime.add(starts_at, 45 * 60, :second)

      %{
        "id" => event_id,
        "iCalUID" => "imported-#{event_id}@example.com",
        "status" => "confirmed",
        "visibility" => "public",
        "summary" => "Launch review",
        "location" => "Room 4",
        "htmlLink" => "https://calendar.google.com/calendar/event?eid=#{calendar_eid(event_id)}",
        "hangoutLink" => "https://meet.google.com/abc-defg-hij",
        "start" => %{"dateTime" => iso(starts_at)},
        "end" => %{"dateTime" => iso(ends_at)},
        "organizer" => %{"email" => "dana@comma.local", "displayName" => "Dana Wu"},
        "attendees" => [
          %{"email" => @calendar_email, "self" => true, "responseStatus" => "accepted"},
          %{"email" => "a@comma.local"},
          %{"email" => "b@comma.local"}
        ],
        "updated" => iso(DateTime.utc_now())
      }
    end

    # Google's `eid` is url-safe base64 of "<eventId> <calendar email>", which
    # is what the link-preview proxy read decodes back into an exact lookup.
    defp calendar_eid(event_id),
      do: Base.url_encode64("#{event_id} #{@calendar_email}", padding: false)

    # ---- Google Drive: files.list and the per-file proxy read ----

    def drive_files_data do
      %{"files" => [drive_file(@drive_document_id)]}
    end

    @doc """
    One exact file read (`files.get` by id). Any id resolves to the demo
    document with the requested id echoed and `webViewLink` recomputed from
    it — the same any-id-resolves convention as the other single-record
    reads. Google Docs files carry no `size`, and Google omits absent fields
    rather than sending null.
    """
    def drive_file_data(file_id) do
      Map.merge(drive_file(file_id), %{
        "kind" => "drive#file",
        "owners" => [%{"kind" => "drive#user", "displayName" => "Dana Wu"}]
      })
    end

    def drive_about_data do
      %{
        "user" => %{
          "kind" => "drive#user",
          "displayName" => "Comma Local User",
          "emailAddress" => @calendar_email,
          "permissionId" => @drive_member_permission_id,
          "me" => true
        }
      }
    end

    @doc """
    `files.list` read through the proxy. The demo document belongs to Dana,
    so a search for the member's own files finds nothing.
    """
    def drive_files_list_data(query) do
      files =
        if String.contains?(to_string(query), "'me' in owners"),
          do: [],
          else: [
            Map.put(drive_file(@drive_document_id), "owners", [
              %{"permissionId" => @drive_dana_permission_id}
            ])
          ]

      %{"files" => files}
    end

    @doc "Dana's open comment on the demo document asks the member for a decision."
    def drive_comments_data(_file_id) do
      %{
        "comments" => [
          %{
            "id" => "AAABcommaLocal01",
            "content" =>
              "+#{@calendar_email} can you confirm the launch date in the rollout section " <>
                "before Thursday?",
            "resolved" => false,
            "modifiedTime" => iso(hours_ago(1)),
            "author" => %{"displayName" => "Dana Wu", "me" => false},
            "replies" => []
          }
        ]
      }
    end

    defp drive_file(file_id) do
      %{
        "id" => file_id,
        "name" => "Launch brief",
        "mimeType" => "application/vnd.google-apps.document",
        "modifiedTime" => iso(hours_ago(2)),
        "webViewLink" => "https://docs.google.com/document/d/#{file_id}/edit"
      }
    end

    # ---- comma_local_search (remote-MCP mock) item projections ----

    @doc """
    The legacy recommendation-item projection served by the `comma_local_search`
    remote-MCP tool, derived from the same entities as the Composio shapes so
    both transports cite identical links.
    """
    def mcp_recommendation_items("linear") do
      Enum.map(@linear_issues, fn issue ->
        node = linear_issue_node(issue)
        verb = if issue.identifier == "COMMA-143", do: "Review ", else: "Follow up on "

        mcp_item(
          "linear-#{String.downcase(issue.identifier)}",
          String.trim(verb) <> " " <> issue.identifier,
          verb,
          issue.identifier,
          node["url"],
          "#{issue.title} is #{String.downcase(issue.state["name"])}.",
          "Open Linear issue #{issue.identifier} and summarize its latest status."
        )
      end)
    end

    def mcp_recommendation_items("notion") do
      page = notion_page()

      [
        mcp_item(
          "notion-q3-plan",
          "Review the Q3 plan",
          "Review ",
          "the Q3 plan",
          page["url"],
          "The planning document was updated today.",
          "Review the latest Q3 plan and summarize the important changes."
        )
      ]
    end

    def mcp_recommendation_items("github") do
      pull = github_pull_request_data(%{})

      [
        mcp_item(
          "github-pr-#{pull["number"]}",
          "Review PR ##{pull["number"]}",
          "Review ",
          "PR ##{pull["number"]}",
          pull["html_url"],
          "The pull request has new review activity.",
          "Open PR ##{pull["number"]} and summarize the latest review activity."
        )
      ]
    end

    def mcp_recommendation_items("google-workspace") do
      [file] = drive_files_data()["files"]

      [
        mcp_item(
          "google-launch-brief",
          "Review the launch brief",
          "Review ",
          "the launch brief",
          file["webViewLink"],
          "The document was edited this morning.",
          "Open the launch brief and summarize today's edits."
        )
      ]
    end

    def mcp_recommendation_items("slack") do
      thread = slack_release_thread()

      [
        mcp_item(
          "slack-release-thread",
          "Reply to the release thread",
          "Reply to ",
          "the release thread in ##{thread["channel"]["name"]}",
          thread["permalink"],
          "Two teammates are waiting on a release decision.",
          "Open the Slack release thread in ##{thread["channel"]["name"]} and draft a concise reply."
        )
      ]
    end

    def mcp_recommendation_items("feishu") do
      [
        mcp_item(
          "feishu-launch-thread",
          "Reply to the launch planning thread",
          "Reply to ",
          "the launch planning thread",
          "https://example.feishu.cn/messenger/thread/launch-planning",
          "Three launch items still need an owner.",
          "Open the Feishu launch planning thread and draft a reply."
        )
      ]
    end

    def mcp_recommendation_items(_source) do
      [
        mcp_item(
          "project-updates",
          "Review recent project updates",
          "Review ",
          "recent project updates",
          "https://example.com/comma-local/project-updates",
          "Recent project activity is ready for a concise briefing.",
          "Summarize the most relevant recent project updates."
        )
      ]
    end

    defp mcp_item(id, title, prefix, label, href, secondary_text, prompt) do
      %{
        id: id,
        title: title,
        parts: [
          %{kind: "markdown", text: prefix},
          %{kind: "inline-link", link: %{href: href, label: label}}
        ],
        secondaryText: secondary_text,
        prompt: prompt
      }
    end

    # ---- time helpers ----

    defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 60 * 60, :second)

    # A Slack permalink embeds its message ts, and the link is the message's
    # identity. These messages keep one timestamp per node boot, so reads agree
    # on the link instead of seeing a new message on every read.
    defp hours_before_boot(hours) do
      boot =
        case :persistent_term.get({__MODULE__, :boot}, nil) do
          nil ->
            now = DateTime.utc_now()
            :persistent_term.put({__MODULE__, :boot}, now)
            now

          boot ->
            boot
        end

      DateTime.add(boot, -hours * 60 * 60, :second)
    end

    defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)
    defp iso(datetime), do: DateTime.to_iso8601(datetime)
  end
end
