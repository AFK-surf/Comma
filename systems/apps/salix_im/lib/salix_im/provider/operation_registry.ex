defmodule SalixIM.Provider.OperationRegistry do
  @moduledoc false

  @manual_keys [
    "name",
    "description",
    "required_scopes",
    "required_params",
    "parameters",
    "example_params",
    "safety",
    "input_schema",
    "connect_required",
    "task_payload_params"
  ]

  @message_search_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "query" => %{"type" => "string", "description" => "Query, 1–4096 UTF-8 bytes."},
      "mode" => %{"type" => "string", "enum" => ["keyword", "semantic", "hybrid"]},
      "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 20},
      "channel" => %{"type" => "string", "description" => "Optional channel ID filter."},
      "workspace" => %{"type" => "string", "description" => "Optional workspace ID filter."},
      "sender" => %{
        "type" => "string",
        "description" => "Optional opaque sender ID, such as a Slack user or bot ID."
      },
      "kind" => %{
        "type" => "string",
        "enum" => ~w(message_text image video_segment ocr_text asr_transcript document_text)
      },
      "oldest" => %{
        "type" => "string",
        "description" => "Inclusive Slack timestamp; defaults to the start of retained history."
      },
      "latest" => %{
        "type" => "string",
        "description" => "Exclusive Slack timestamp; defaults to now."
      },
      "cursor" => %{
        "type" => "string",
        "description" => "Continue with next_cursor alone; windows expire after 15 minutes."
      }
    },
    "oneOf" => [
      %{"required" => ["query"], "not" => %{"required" => ["cursor"]}},
      %{
        "required" => ["cursor"],
        "not" => %{
          "anyOf" =>
            Enum.map(
              ~w(query mode count channel workspace sender kind oldest latest),
              &%{"required" => [&1]}
            )
        }
      }
    ]
  }

  @slack_operations [
    %{
      "name" => "slack.post_task_card",
      "method" => "chat.postMessage/chat.update",
      "safety" => "write",
      "description" =>
        "Publish one native Slack Task surface after im_api.internal.task.create. Tasks use task_card. The dedicated Conversation participant keeps the same surface synchronized with authoritative Task status and public progress.",
      "required_params" => ["conversation_id", "channel", "thread_ts"],
      "parameters" => %{
        "conversation_id" => "Task conversation_id returned by im_api.internal.task.create.",
        "channel" => "Slack channel ID from the source context.",
        "thread_ts" => "Slack source thread root timestamp."
      }
    },
    %{
      "name" => "slack.bind_thread_to_task",
      "method" => "im.slack.bind_thread_to_task",
      "safety" => "write",
      "description" =>
        "Explicitly hand one Slack thread to an existing Router-owned Task. Use this separately from Task creation only when the Router decides that future thread messages should enter that Task directly or when the user asks for the handover. The operation creates an ordinary Slack thread participant, posts its idempotent Task supervision link, and makes the binding durable; it does not create a Task or Task card.",
      "required_params" => ["conversation_id", "channel", "thread_ts"],
      "parameters" => %{
        "conversation_id" => "Existing Router-owned Task conversation_id.",
        "channel" => "Slack channel ID from the source context.",
        "thread_ts" => "Slack root thread timestamp from the source context."
      }
    },
    %{
      "name" => "slack.post_map_card",
      "method" => "chat.postMessage",
      "safety" => "write",
      "required_scopes" => ["chat:write"],
      "description" =>
        "Post a product-rendered compact map card. Pass semantic location data only; the Slack provider owns the Block Kit, localized labels, accessibility fallback, and duplicate-unfurl suppression. Never pass or generate blocks.",
      "required_params" => ["channel", "location", "latitude", "longitude"],
      "parameters" => %{
        "channel" => "Required Slack channel ID.",
        "location" => "Required human-readable place name.",
        "latitude" => "Required latitude from -90 to 90, as a number or numeric string.",
        "longitude" => "Required longitude from -180 to 180, as a number or numeric string.",
        "address" => "Optional street address.",
        "note" =>
          "Optional context line. It is truncated as needed so the complete map link remains visible.",
        "map_url" =>
          "Optional HTTPS map destination that must fit Slack's card-body limit. A Google Maps coordinate link is generated when omitted.",
        "image_url" =>
          "Optional HTTPS static map image. Omit when no trusted image URL is available.",
        "locale" => %{
          "type" => "string",
          "enum" => ["en", "zh-CN"],
          "description" =>
            "Optional card-label locale. Use zh-CN when the active conversation is Chinese; defaults to en."
        },
        "thread_ts" => "Optional parent thread timestamp."
      },
      "example_params" => %{
        "channel" => "C123",
        "location" => "Comma Shanghai office",
        "latitude" => "31.2304",
        "longitude" => "121.4737",
        "locale" => "zh-CN"
      }
    },
    %{
      "name" => "slack.post_stock_card",
      "method" => "chat.postMessage",
      "safety" => "write",
      "required_scopes" => ["chat:write"],
      "description" =>
        "Post a product-rendered compact stock quote with clear price hierarchy, key metrics, and an in-card sparkline. Pass normalized quote data only; the Slack provider owns the Block Kit, localized labels, accessibility fallback, and duplicate-unfurl suppression. Never pass or generate blocks.",
      "required_params" => ["channel", "symbol", "price", "currency"],
      "parameters" => %{
        "channel" => "Required Slack channel ID.",
        "symbol" => "Required ticker symbol.",
        "price" => "Required display price from the chosen market-data source.",
        "currency" => "Required ISO currency code such as USD or CNY.",
        "company_name" => "Optional company name.",
        "exchange" => "Optional exchange label such as NASDAQ or SSE.",
        "period" => "Optional quote period such as 1D, 5D, or 1M.",
        "change" => "Optional signed absolute change, for example +2.40.",
        "change_percent" =>
          "Optional numeric signed percentage from -100 to 100, without the percent sign.",
        "open" => "Optional numeric session open.",
        "high" => "Optional numeric session high.",
        "low" => "Optional numeric session low.",
        "volume" => "Optional non-negative numeric volume.",
        "price_history" => %{
          "type" => "array",
          "description" =>
            "Optional 1-20 point price trend. Each object requires a short label and numeric value.",
          "items" => %{"type" => "object", "required" => ["label", "value"]}
        },
        "market_status" => "Optional market status such as Open or Closed.",
        "as_of" => "Optional human-readable quote timestamp.",
        "source_url" => "Optional HTTPS quote source.",
        "locale" => %{
          "type" => "string",
          "enum" => ["en", "zh-CN"],
          "description" =>
            "Optional card-label locale. Use zh-CN when the active conversation is Chinese; defaults to en."
        },
        "thread_ts" => "Optional parent thread timestamp."
      },
      "example_params" => %{
        "channel" => "C123",
        "symbol" => "AAPL",
        "price" => "231.40",
        "currency" => "USD",
        "change" => "+2.40",
        "change_percent" => "+1.05",
        "locale" => "zh-CN"
      }
    },
    %{
      "name" => "slack.post_weather_card",
      "method" => "chat.postMessage",
      "safety" => "write",
      "required_scopes" => ["chat:write"],
      "description" =>
        "Post one product-rendered weather container with semantic condition emoji, current conditions, compact hourly trend, and daily forecast. Pass normalized weather data only; the Slack provider owns the Block Kit, localized labels, accessibility fallback, and duplicate-unfurl suppression. Never pass or generate blocks.",
      "required_params" => ["channel", "location", "condition", "temperature", "unit"],
      "parameters" => %{
        "channel" => "Required Slack channel ID.",
        "location" => "Required human-readable location.",
        "condition" => "Required concise condition such as Sunny or Light rain.",
        "temperature" => "Required current temperature without a unit suffix.",
        "unit" => %{
          "type" => "string",
          "enum" => ["C", "F"],
          "description" => "Required temperature unit."
        },
        "feels_like" => "Optional feels-like temperature without a unit suffix.",
        "high" => "Optional daily high without a unit suffix.",
        "low" => "Optional daily low without a unit suffix.",
        "precipitation_percent" => "Optional numeric precipitation probability from 0 to 100.",
        "humidity_percent" => "Optional numeric humidity from 0 to 100.",
        "hourly_forecast" => %{
          "type" => "array",
          "description" =>
            "Optional 1-20 point hourly trend. Each object requires time and numeric temperature.",
          "items" => %{"type" => "object", "required" => ["time", "temperature"]}
        },
        "daily_forecast" => %{
          "type" => "array",
          "description" =>
            "Optional 1-10 day forecast. Each object requires day, condition, numeric high, and numeric low.",
          "items" => %{"type" => "object", "required" => ["day", "condition", "high", "low"]}
        },
        "wind" => "Optional display wind, for example NE 12 km/h.",
        "as_of" => "Optional human-readable observation timestamp.",
        "forecast_url" => "Optional HTTPS forecast source.",
        "locale" => %{
          "type" => "string",
          "enum" => ["en", "zh-CN"],
          "description" =>
            "Optional card-label locale. Use zh-CN when the active conversation is Chinese; defaults to en."
        },
        "thread_ts" => "Optional parent thread timestamp."
      },
      "example_params" => %{
        "channel" => "C123",
        "location" => "Shanghai",
        "condition" => "Light rain",
        "temperature" => "27",
        "unit" => "C",
        "high" => "30",
        "low" => "24",
        "locale" => "zh-CN"
      }
    },
    %{
      "name" => "slack.post_channel_message",
      "task_payload_params" => ["text"],
      "method" => "chat.postMessage",
      "safety" => "write",
      "required_scopes" => ["chat:write"],
      "description" =>
        "Start a new top-level Slack topic only when you are certain a channel post is intended; otherwise use slack.reply_message. Never use this operation for an existing request or Task reply, or as a fallback when its source is unclear. Requires an explicit channel and rejects thread_ts. Send standard Markdown, not Block Kit JSON; the provider owns rendering. Use dedicated operations for map, stock, and weather cards.",
      "required_params" => ["channel", "text"],
      "parameters" => %{
        "channel" =>
          "Required Slack channel ID, for example C123. Use source context, user instruction, or slack.list_channels to choose it.",
        "text" =>
          "Required standard Markdown. Preserve the intended document structure. Use <@USER_ID> to address a resolved Slack user and <#CHANNEL_ID> to refer to a resolved Slack channel; plain @name text is not a mention. Lead with the conclusion and let the provider adapter own native presentation."
      }
    },
    %{
      "name" => "slack.reply_message",
      "task_payload_params" => ["text"],
      "method" => "chat.postMessage",
      "safety" => "write",
      "required_scopes" => ["chat:write"],
      "description" =>
        "Reply in the original request or Task source thread, not the latest unrelated thread. Requires explicit channel and thread_ts; recover missing source coordinates rather than posting to the channel. Send standard Markdown, not Block Kit JSON; the provider owns rendering. Use dedicated operations for map, stock, and weather cards.",
      "required_params" => ["channel", "text", "thread_ts"],
      "parameters" => %{
        "channel" =>
          "Required Slack channel ID, for example C123. Use source context, user instruction, or slack.list_channels to choose it.",
        "text" =>
          "Required standard Markdown. Preserve the intended document structure. Use <@USER_ID> to address a resolved Slack user and <#CHANNEL_ID> to refer to a resolved Slack channel; plain @name text is not a mention. Lead with the conclusion and let the provider adapter own native presentation.",
        "thread_ts" =>
          "Required original source thread timestamp (or source message_ts for a top-level request). For Task results use task_reply_source.thread_ts."
      }
    },
    %{
      "name" => "slack.send_dm",
      "method" => "conversations.open+chat.postMessage",
      "safety" => "write",
      "description" =>
        "Open or resume a DM with a Slack user and send a message. When the target is named by handle or display name instead of user ID, resolve it with slack.list_users, paginate with next_cursor when needed, and use the returned id; ask for clarification if the match remains ambiguous or absent.",
      "required_params" => ["user_id", "text"],
      "parameters" => %{
        "user_id" =>
          "Required Slack user ID, for example U123. Use source context, an explicit <@U...> mention, or slack.list_users with query to resolve a named Slack user.",
        "text" =>
          "Required standard Markdown message text. Use <@USER_ID> to address a Slack user and <#CHANNEL_ID> to refer to a Slack channel."
      }
    },
    %{
      "name" => "slack.list_channels",
      "method" => "conversations.list",
      "safety" => "read",
      "description" =>
        "List one bounded page of channels visible to the connected Slack bot. For named-channel discovery, pass every non-empty next_cursor back as cursor with the same limit, types, and exclude_archived values until the target is found or next_cursor is absent or empty. A short or empty channels page is not exhaustion while next_cursor is non-empty; never infer completion from the row count.",
      "required_params" => [],
      "parameters" => %{
        "limit" =>
          "Optional per-page upper bound, default 100, max 200. Slack may return fewer channels, including none, while next_cursor is non-empty.",
        "cursor" =>
          "Optional Slack pagination cursor from next_cursor; preserve the same filters and limit across pages.",
        "types" =>
          "Optional comma-separated Slack conversation types. Defaults to public_channel,private_channel.",
        "exclude_archived" => "Optional boolean, default true."
      }
    },
    %{
      "name" => "slack.join_channel",
      "method" => "conversations.join",
      "safety" => "admin",
      "description" =>
        "Join the connected Slack bot to an explicit public channel. A validated channel_created event uses this operation to join its exact new public channel automatically. This operation cannot join private channels; a current private-channel member must invite the bot instead. Existing Slack installs must be reauthorized after the channels:join scope is added before this operation can succeed.",
      "required_params" => ["channel"],
      "parameters" => %{
        "channel" =>
          "Required public Slack channel ID, for example C123. Resolve a named channel with paginated slack.list_channels and do not call this operation for a private channel."
      },
      "example_params" => %{"channel" => "C123"}
    },
    %{
      "name" => "slack.create_channel",
      "method" => "conversations.create",
      "safety" => "admin",
      "required_scopes" => ["channels:manage", "groups:write"],
      "description" =>
        "Create a new Slack channel only on an explicit user request. Slack channel names are lowercase letters, numbers, hyphens, and underscores, at most 80 characters; a leading # and upper-case letters are normalized, anything else is rejected before the call. Public is the default; pass is_private=true for a private channel. The connected bot becomes a member of the new channel automatically, and Slack rejects a name that is already taken. To add people afterwards, call slack.invite_users with the returned channel ID. Existing Slack installs must be reauthorized after the groups:write scope is added before a private channel can be created.",
      "required_params" => ["name"],
      "parameters" => %{
        "name" =>
          "Required channel name, for example launch-room. Lowercase letters, numbers, hyphens, and underscores only, at most 80 characters.",
        "is_private" => "Optional boolean, default false. When true, creates a private channel."
      },
      "example_params" => %{"name" => "launch-room", "is_private" => false}
    },
    %{
      "name" => "slack.list_users",
      "method" => "users.list",
      "safety" => "read",
      "description" =>
        "List users visible to the connected Slack bot. Use query to resolve a named Slack person by id, handle, real name, display name, title, or email; follow next_cursor if the first page has no clear match. Results are bot-visible and paginated. Email is included when Slack returns it; the connected app must grant users:read.email, and existing installs must be reauthorized after that scope is added.",
      "required_params" => [],
      "parameters" => %{
        "query" =>
          "Optional case-insensitive local filter over returned id, name, real_name, display_name, title, and email. Use this when a named person needs a Slack user ID.",
        "limit" => "Optional max count, default 100, max 200.",
        "cursor" => "Optional Slack pagination cursor from next_cursor.",
        "include_deleted" => "Optional boolean, default false."
      }
    },
    %{
      "name" => "slack.get_user_info",
      "method" => "users.info",
      "safety" => "read",
      "description" =>
        "Resolve a Slack user ID from source context or user instruction to profile information. Email is included when Slack returns it; the connected app must grant users:read.email.",
      "required_params" => ["user_id"],
      "parameters" => %{
        "user_id" => "Required Slack user ID, for example U123."
      }
    },
    %{
      "name" => "slack.update_message",
      "method" => "chat.update",
      "safety" => "write",
      "description" =>
        "Update an existing Slack message from standard Markdown by channel and message timestamp.",
      "required_params" => ["channel", "ts", "text"],
      "parameters" => %{
        "channel" => "Required Slack channel ID containing the message.",
        "ts" => "Required Slack message timestamp to update.",
        "text" =>
          "Required replacement standard Markdown text. Use <@USER_ID> to address a Slack user and <#CHANNEL_ID> to refer to a Slack channel."
      },
      "example_params" => %{
        "channel" => "C123",
        "ts" => "1710000000.000100",
        "text" => "updated message"
      }
    },
    %{
      "name" => "slack.delete_message",
      "method" => "chat.delete",
      "safety" => "destructive",
      "description" => "Delete a Slack message by channel and message timestamp.",
      "required_params" => ["channel", "ts"],
      "parameters" => %{
        "channel" => "Required Slack channel ID containing the message.",
        "ts" => "Required Slack message timestamp to delete."
      },
      "example_params" => %{"channel" => "C123", "ts" => "1710000000.000100"}
    },
    %{
      "name" => "slack.list_channel_members",
      "method" => "conversations.members",
      "safety" => "read",
      "description" => "List Slack user IDs in a channel.",
      "required_params" => ["channel"],
      "parameters" => %{
        "channel" => "Required Slack channel ID.",
        "limit" => "Optional max count, default 100, max 200.",
        "cursor" => "Optional Slack pagination cursor from next_cursor."
      },
      "example_params" => %{"channel" => "C123", "limit" => 100}
    },
    %{
      "name" => "slack.get_thread_replies",
      "method" => "conversations.replies",
      "safety" => "read",
      "description" =>
        "conversations.replies: one page of one thread, oldest first. channel plus ts (the thread parent, or an unthreaded message — then only that message is returned). Continue by passing next_cursor back as cursor. oldest/latest/inclusive/limit match Slack; default limit 100, max 1000. before_ts is exclusive latest for the page before the current trigger (do not combine it with cursor, oldest, latest, or inclusive). Each human message's user field is an opaque Slack user ID, not a person's name. Before naming or attributing content to a person, call slack.get_user_info for every relevant ID. Never infer identity from message text, prior memory, or another user's profile. Files are metadata only; fetch bytes with slack.fetch_file. stale=true means this copy may lag a later edit. incomplete.reason=not_synced means older replies are not indexed yet, not that the thread is empty." <>
          " Returned messages still show what was said. Use their supported details without claiming that the history is complete." <>
          " If the request needs original material, fetch the returned file instead of treating its metadata as the material." <>
          " Do not ask the user to wait for synchronization when the returned messages or an available original file can answer the question.",
      "required_params" => ["channel", "ts"],
      "parameters" => %{
        "channel" =>
          "Required Slack channel ID. Use source channel_id for the current Slack thread.",
        "ts" =>
          "Required timestamp of the thread parent, or of an unthreaded message (then only that message is returned). Use source thread_ts for the current Slack thread.",
        "before_ts" =>
          "Optional exclusive upper bound for the first chronological page before this timestamp. Use source message_ts for messages before the current trigger. Continue a partial result with next_cursor. Cannot be combined with cursor, oldest, latest, or inclusive.",
        "root_already_preloaded" =>
          "Optional boolean after a successful automatic preload that explicitly included the root. When true, omits only the exact root ts from this result. Leave false or omit after an unavailable preload.",
        "oldest" => "Optional oldest reply timestamp.",
        "latest" => "Optional latest reply timestamp.",
        "inclusive" => "Optional boolean for oldest/latest bounds.",
        "limit" => "Optional reply count, default 100, max 1000.",
        "cursor" =>
          "Pass next_cursor from the previous page unchanged. Reuse the same time bounds and limit. Replace an initial before_ts with latest set to that same timestamp and inclusive=false; do not combine cursor with before_ts."
      },
      "example_params" => %{
        "channel" => "C123",
        "ts" => "1710000000.000100",
        "before_ts" => "1710000123.000200",
        "limit" => 15
      }
    },
    %{
      "name" => "slack.get_channel_history",
      "method" => "conversations.history",
      "safety" => "read",
      "description" =>
        "conversations.history: one page of top-level channel messages, newest first. Does not return thread replies; use slack.get_thread_replies. Continue by passing next_cursor back as cursor. oldest/latest/inclusive/limit match Slack; default limit 100, max 1000. One top-level permalink: oldest=latest=<ts>, inclusive=true, limit=1. Each human message's user field is an opaque Slack user ID, not a person's name. Before naming or attributing content to a person, call slack.get_user_info for every relevant ID. Never infer identity from message text, prior memory, or another user's profile. Files are metadata only; fetch bytes with slack.fetch_file. stale=true means this copy may lag a later edit. incomplete.reason=not_synced means older history is not indexed yet, not that the channel is empty.",
      "required_params" => ["channel"],
      "parameters" => %{
        "channel" =>
          "Required Slack channel ID. Use source channel_id for the current Slack channel or slack.list_channels to choose another visible channel.",
        "limit" => "Optional message count, default 100, max 1000.",
        "cursor" => "Pass next_cursor from the previous page unchanged.",
        "oldest" => "Optional oldest message timestamp.",
        "latest" => "Optional latest message timestamp.",
        "inclusive" => "Optional boolean for oldest/latest bounds."
      },
      "example_params" => %{"channel" => "C123", "limit" => 100}
    },
    %{
      "name" => "slack.search",
      "safety" => "read",
      "description" =>
        "One page of indexed Slack messages matching query, newest first, including thread replies. Required query. count default 30, max 200. Continue by passing next_cursor back as cursor. sort is timestamp only (default desc); sort=score is rejected. Matching is case-insensitive substring on text and blocks. Juxtaposed terms AND; OR combines AND-groups; -term and -\"phrase\" exclude. Supported modifiers: from:<@U…> or from:U…, in:C… or in:<#C…>, after:YYYY-MM-DD, before:YYYY-MM-DD, has:file, quoted phrases. in: must be a channel id — resolve names with slack.list_channels. Unsupported syntax (-from:, has:link, on:, during:, in:channel_name, parentheses) errors rather than being ignored. Each human message's user field is an opaque Slack user ID, not a person's name. Before naming or attributing content to a person, call slack.get_user_info for every relevant ID. Never infer identity from message text, prior memory, or another user's profile. Files are metadata only; fetch bytes with slack.fetch_file. stale=true means this copy may lag a later edit. incomplete.reason=not_synced means older history is not indexed yet, not that there were no matches. This reads the local index, not Slack search.messages.",
      "required_params" => ["query"],
      "parameters" => %{
        "query" =>
          "Required search string. Case-insensitive. Whitespace-separated terms AND; OR combines AND-groups; -term / -\"phrase\" exclude. Quoted phrases are substrings. Modifiers: from:<@U…> / from:U…, in:C… / in:<#C…>, after:YYYY-MM-DD, before:YYYY-MM-DD, has:file. Mentions as <@U…>. Channel names are not accepted in in:.",
        "count" => "Optional page size, default 30, max 200.",
        "cursor" => "Pass next_cursor from the previous page unchanged. Omit on the first page.",
        "sort" =>
          "Optional. Only timestamp is supported. Default timestamp. sort=score is rejected.",
        "sort_dir" => "Optional asc or desc. Default desc."
      },
      "example_params" => %{
        "query" => "from:<@U12345678> in:C12345678 after:2026-01-01 deploy",
        "count" => 30
      }
    },
    %{
      "name" => "slack.message_search",
      "safety" => "read",
      "connect_required" => false,
      "description" =>
        "Search retained Slack messages and processed media across this group's connected data domains. Every agent in the group uses the same search scope. Omit connect_id and channel for group-wide search; either is an optional narrowing filter. Default hybrid combines semantic ranking and literal case-insensitive substring matches; keyword and semantic are explicit alternatives. Results are grouped by message with the matching text/file/page/time locator. History has no fixed day window. Text is indexed in resumable slices; processed images, video, OCR, speech transcripts and documents participate. Background coverage is partial, and independent file edits may lag. No matches does not prove absence. Continue using next_cursor alone; the finite result window expires after 15 minutes and rechecks current access. Open original messages/files through their separately authorized read operations.",
      "required_params" => [],
      "input_schema" => @message_search_schema,
      "example_params" => %{"query" => "为什么上次部署回滚了？", "mode" => "hybrid", "count" => 20}
    },
    %{
      "name" => "slack.semantic_search",
      "safety" => "read",
      "connect_required" => false,
      "description" =>
        "Group-scoped message search with semantic mode as its default, using the independent index; mode may explicitly select keyword or hybrid. Omit connect_id/channel to search retained history across the group's connected Slack data domains. There is no fixed 14-day window or 8000-character text truncation. Up to 20 distinct messages per page; processed media return file/page/time locators. Coverage is partial and file snapshots may lag; an empty result does not prove absence. Continue with next_cursor alone. Ordinary original-message/file reads retain their own authorization.",
      "required_params" => [],
      "input_schema" => @message_search_schema,
      "parameters" => %{
        "channel" => "Optional Slack channel ID filter; names are not accepted.",
        "query" => "Natural-language query, 1–4096 UTF-8 bytes. No keyword modifiers.",
        "count" => "Optional result count, default 10, maximum 20.",
        "oldest" =>
          "Optional inclusive Slack timestamp; defaults to the start of retained history.",
        "latest" => "Optional exclusive Slack timestamp; defaults to now."
      },
      "example_params" => %{"channel" => "C12345678", "query" => "为什么上次部署回滚了？"}
    },
    %{
      "name" => "slack.fetch_file",
      "method" => "files.info",
      "safety" => "media",
      "description" =>
        "Download one Slack file into the agent VFS on demand and return a structured VFS attachment. An image from a synchronous result is attached natively to the following model request; every other file type is staged in the workspace and identified by its VFS path only, and you read it yourself with fs.read_file or convert it on a connected runner with env.copy plus env.exec. If the fetch completes asynchronously, wait for completion, then call tool_call.get_result without offset or limit. Use this to view an attachment listed by slack.get_thread_replies / slack.get_channel_history. Pass the file id from that listing.",
      "required_params" => ["file_id"],
      "parameters" => %{
        "file_id" =>
          "Required Slack file ID (the id from a message's files list, e.g. F0123ABCD)."
      },
      "example_params" => %{"file_id" => "F0123ABCD"}
    },
    %{
      "name" => "slack.add_reaction",
      "method" => "reactions.add",
      "safety" => "write",
      "description" => "Add an emoji reaction to a Slack message.",
      "required_params" => ["channel", "ts", "name"],
      "parameters" => %{
        "channel" => "Required Slack channel ID containing the message.",
        "ts" => "Required Slack message timestamp.",
        "name" => "Required emoji reaction name without surrounding colons."
      },
      "example_params" => %{
        "channel" => "C123",
        "ts" => "1710000000.000100",
        "name" => "white_check_mark"
      }
    },
    %{
      "name" => "slack.pin_message",
      "method" => "pins.add",
      "safety" => "write",
      "description" => "Pin a Slack message to its channel.",
      "required_params" => ["channel", "ts"],
      "parameters" => %{
        "channel" => "Required Slack channel ID containing the message.",
        "ts" => "Required Slack message timestamp."
      },
      "example_params" => %{"channel" => "C123", "ts" => "1710000000.000100"}
    },
    %{
      "name" => "slack.unpin_message",
      "method" => "pins.remove",
      "safety" => "write",
      "description" => "Remove a Slack message pin from its channel.",
      "required_params" => ["channel", "ts"],
      "parameters" => %{
        "channel" => "Required Slack channel ID containing the message.",
        "ts" => "Required Slack message timestamp."
      },
      "example_params" => %{"channel" => "C123", "ts" => "1710000000.000100"}
    },
    %{
      "name" => "slack.set_channel_topic",
      "method" => "conversations.setTopic",
      "safety" => "admin",
      "description" => "Set a Slack channel topic.",
      "required_params" => ["channel", "topic"],
      "parameters" => %{
        "channel" => "Required Slack channel ID.",
        "topic" => "Required topic text."
      },
      "example_params" => %{"channel" => "C123", "topic" => "Current topic"}
    },
    %{
      "name" => "slack.set_channel_purpose",
      "method" => "conversations.setPurpose",
      "safety" => "admin",
      "description" => "Set a Slack channel purpose.",
      "required_params" => ["channel", "purpose"],
      "parameters" => %{
        "channel" => "Required Slack channel ID.",
        "purpose" => "Required purpose text."
      },
      "example_params" => %{"channel" => "C123", "purpose" => "Current purpose"}
    },
    %{
      "name" => "slack.invite_users",
      "method" => "conversations.invite",
      "safety" => "admin",
      "required_scopes" => ["channels:manage", "groups:write"],
      "description" =>
        "Invite one or more Slack users to a channel the connected bot is a member of, on an explicit user request. Resolve named people to user IDs with slack.list_users first and use the channel ID from source context, slack.list_channels, or slack.create_channel. Inviting a single user who is already a member succeeds idempotently with already_in_channel=true. With several users, Slack rejects the whole call when any user is invalid or already a member unless force=true, which invites the valid users and reports the rest under errors. Existing Slack installs must be reauthorized after the groups:write scope is added before inviting into a private channel.",
      "required_params" => ["channel", "users"],
      "parameters" => %{
        "channel" => "Required Slack channel ID, for example C123.",
        "users" =>
          "Required Slack user IDs as a list or comma-separated string, for example [\"U123\", \"U456\"].",
        "force" =>
          "Optional boolean, default false. When true and several users are given, invite the valid users and report the failed ones under errors instead of rejecting the whole call."
      },
      "example_params" => %{"channel" => "C123", "users" => ["U123", "U456"]}
    },
    %{
      "name" => "slack.add_bookmark",
      "method" => "bookmarks.add",
      "safety" => "write",
      "description" => "Add a link bookmark to a Slack channel.",
      "required_params" => ["channel", "title", "url"],
      "parameters" => %{
        "channel" => "Required Slack channel ID.",
        "title" => "Required bookmark title.",
        "url" => "Required bookmark URL."
      },
      "example_params" => %{
        "channel" => "C123",
        "title" => "Runbook",
        "url" => "https://example.com/runbook"
      }
    },
    %{
      "name" => "slack.list_emoji",
      "method" => "emoji.list",
      "safety" => "read",
      "description" => "List custom emoji available in the Slack workspace.",
      "required_params" => [],
      "parameters" => %{},
      "example_params" => %{}
    },
    %{
      "name" => "slack.upload_file",
      "method" => "files.getUploadURLExternal+files.completeUploadExternal",
      "safety" => "media",
      "description" =>
        "Upload a file from the agent VFS to Slack using Slack's external upload flow.",
      "required_params" => ["path"],
      "parameters" => %{
        "path" => "Required agent VFS path to upload. Host filesystem paths are not read.",
        "channel" => "Optional Slack channel ID where the file will be shared.",
        "thread_ts" => "Optional parent message timestamp for threaded uploads.",
        "title" => "Optional Slack file title.",
        "initial_comment" =>
          "Optional standard-Markdown message introducing the file; common emphasis, links, lists, quotes, and code are converted to safe Slack-compatible mrkdwn."
      },
      "example_params" => %{
        "path" => "/attachments/report.pdf",
        "channel" => "C123",
        "initial_comment" => "**Report**\n\n- Ready for review"
      }
    },
    %{
      "name" => "slack.fetch_canvas",
      "method" => "files.info",
      "safety" => "read",
      "required_scopes" => ["canvases:read", "files:read"],
      "description" =>
        "Read the provider-rendered HTML content of a Slack canvas by its canvas/file ID. Use slack.list_channels or conversations.info to discover a channel canvas ID, or use the canvas_id returned by slack.create_canvas.",
      "required_params" => ["canvas_id"],
      "parameters" => %{
        "canvas_id" => "Required Slack canvas ID, for example F123 (canvas file ID)."
      },
      "example_params" => %{"canvas_id" => "F0123CANVAS"}
    },
    %{
      "name" => "slack.create_canvas",
      "method" => "canvases.create",
      "safety" => "write",
      "required_scopes" => ["canvases:write"],
      "description" =>
        "Create a Slack canvas from markdown only when a user-authorized or product-owned workflow needs a new long-form document; do not substitute it for a conversational reply. Omit channel for a standalone canvas (title required); pass a channel to create that channel's tab canvas. Returns the new canvas_id.",
      "required_params" => ["content"],
      "parameters" => %{
        "title" => "Required canvas title for a standalone canvas; ignored for a channel canvas.",
        "content" => "Required canvas body as markdown.",
        "channel" =>
          "Optional Slack channel ID. When set, creates the channel's canvas via conversations.canvases.create instead of a standalone canvas."
      },
      "example_params" => %{"title" => "Runbook", "content" => "# Runbook\nSteps..."}
    },
    %{
      "name" => "slack.edit_canvas",
      "method" => "canvases.edit",
      "safety" => "write",
      "required_scopes" => ["canvases:write"],
      "description" =>
        "Edit an existing Slack canvas. By default replaces the whole document with content; use operation append/prepend to add markdown, or operation insert_after/insert_before/delete with section_id for section-level edits. Advanced callers may pass a raw changes JSON array.",
      "required_params" => ["canvas_id"],
      "parameters" => %{
        "canvas_id" => "Required Slack canvas ID to edit.",
        "content" =>
          "Markdown content for the change. Required unless operation is delete or a raw changes array is supplied.",
        "operation" =>
          "Optional: replace (default), append, prepend, insert_after, insert_before, or delete.",
        "section_id" =>
          "Optional canvas section ID; required for insert_after, insert_before, and delete.",
        "changes" =>
          "Optional raw Slack canvases.edit changes as a JSON array, overriding operation/content."
      },
      "example_params" => %{
        "canvas_id" => "F0123CANVAS",
        "operation" => "replace",
        "content" => "# Updated\nNew body"
      }
    },
    %{
      "name" => "slack.delete_canvas",
      "method" => "canvases.delete",
      "safety" => "destructive",
      "required_scopes" => ["canvases:write"],
      "description" => "Delete a Slack canvas by its canvas/file ID.",
      "required_params" => ["canvas_id"],
      "parameters" => %{
        "canvas_id" => "Required Slack canvas ID to delete."
      },
      "example_params" => %{"canvas_id" => "F0123CANVAS"}
    },
    %{
      "name" => "slack.set_canvas_access",
      "method" => "canvases.access.set",
      "safety" => "admin",
      "required_scopes" => ["canvases:write"],
      "description" =>
        "Set read or write access on a Slack canvas for specific channels and/or users.",
      "required_params" => ["canvas_id", "access_level"],
      "parameters" => %{
        "canvas_id" => "Required Slack canvas ID.",
        "access_level" => "Required access level: read or write.",
        "channel_ids" => "Slack channel IDs as a list or comma-separated string.",
        "user_ids" => "Slack user IDs as a list or comma-separated string."
      },
      "example_params" => %{
        "canvas_id" => "F0123CANVAS",
        "access_level" => "read",
        "channel_ids" => ["C123"]
      }
    },
    %{
      "name" => "slack.delete_canvas_access",
      "method" => "canvases.access.delete",
      "safety" => "admin",
      "required_scopes" => ["canvases:write"],
      "description" =>
        "Remove channel and/or user access entries from a Slack canvas, reverting them to the canvas default.",
      "required_params" => ["canvas_id"],
      "parameters" => %{
        "canvas_id" => "Required Slack canvas ID.",
        "channel_ids" => "Slack channel IDs as a list or comma-separated string.",
        "user_ids" => "Slack user IDs as a list or comma-separated string."
      },
      "example_params" => %{"canvas_id" => "F0123CANVAS", "channel_ids" => ["C123"]}
    }
  ]

  @feishu_operations [
    %{
      "name" => "feishu.send_text",
      "task_payload_params" => ["text"],
      "method" => "POST /im/v1/messages",
      "safety" => "write",
      "description" => "Send text to an explicit Feishu chat or user ID.",
      "required_params" => ["receive_id", "text"],
      "parameters" => %{
        "receive_id" => "Required chat/user/open ID.",
        "receive_id_type" => "Optional; defaults to chat_id.",
        "text" => "Required message text.",
        "mentions" =>
          "Optional list of {user_id, name} entries. Resolve named people with list_chat_members or directory tools before sending.",
        "mention_all" =>
          "Optional boolean. Prepends an @all tag; the bot must be allowed to @all by the target chat's settings."
      }
    },
    %{
      "name" => "feishu.reply_text",
      "method" => "POST /im/v1/messages/:message_id/reply",
      "safety" => "write",
      "description" =>
        "Reply to an explicit Feishu message. For a top-level group @mention, pass reply_in_thread=true and source chat_id so later replies in the created thread can continue without another mention.",
      "required_params" => ["message_id", "text"],
      "parameters" => %{
        "message_id" => "Required source Feishu message ID.",
        "text" => "Required message text.",
        "reply_in_thread" =>
          "Optional boolean; defaults to true when chat_type=group and thread_id is absent.",
        "chat_id" => "Source chat ID, required to remember participation in a created thread.",
        "chat_type" => "Source chat type (group or p2p), used for the safe thread default.",
        "thread_id" => "Existing source thread ID when replying inside a thread.",
        "mentions" => "Optional list of {user_id, name} entries to mention in the reply.",
        "mention_all" => "Optional boolean to mention all members when the chat permits it."
      }
    },
    %{
      "name" => "feishu.send_image",
      "method" => "POST /im/v1/images + POST /im/v1/messages",
      "safety" => "media",
      "description" => "Upload and send an image from the agent VFS.",
      "required_params" => ["receive_id", "path"],
      "parameters" => %{
        "receive_id" => "Required chat/user/open ID.",
        "receive_id_type" => "Optional; defaults to chat_id.",
        "path" => "Required absolute agent VFS path."
      }
    },
    %{
      "name" => "feishu.send_file",
      "method" => "POST /im/v1/files + POST /im/v1/messages",
      "safety" => "media",
      "description" => "Upload and send a file from the agent VFS.",
      "required_params" => ["receive_id", "path"],
      "parameters" => %{
        "receive_id" => "Required chat/user/open ID.",
        "receive_id_type" => "Optional; defaults to chat_id.",
        "path" => "Required absolute agent VFS path."
      }
    },
    %{
      "name" => "feishu.get_chat_history",
      "method" => "GET /im/v1/messages?container_id_type=chat",
      "safety" => "read",
      "description" =>
        "Read one bounded page of bot-visible top-level Feishu chat history. This mirrors Slack channel history: it does not automatically expand threads. Use feishu.get_thread_replies for an explicit thread_id. Attachments are metadata only; fetch needed bytes with feishu.fetch_message_resource.",
      "required_params" => ["chat_id"],
      "parameters" => %{
        "chat_id" => "Required source chat ID.",
        "start_time" => "Optional inclusive Unix timestamp in seconds.",
        "end_time" => "Optional inclusive Unix timestamp in seconds.",
        "sort_type" => "Optional ByCreateTimeAsc or ByCreateTimeDesc.",
        "page_size" => "Optional page size, default and max 50.",
        "page_token" => "Optional Feishu page token returned by the prior call."
      }
    },
    %{
      "name" => "feishu.get_thread_replies",
      "method" => "GET /im/v1/messages?container_id_type=thread",
      "safety" => "read",
      "description" =>
        "Read one bounded page of a Feishu thread. Attachments are listed as metadata; fetch one with feishu.fetch_message_resource before claiming its content cannot be read.",
      "required_params" => ["thread_id"],
      "parameters" => %{
        "thread_id" => "Required source thread ID.",
        "sort_type" => "Optional ByCreateTimeAsc or ByCreateTimeDesc.",
        "page_size" => "Optional page size, default and max 50.",
        "page_token" => "Optional Feishu page token."
      }
    },
    %{
      "name" => "feishu.get_message",
      "method" => "GET /im/v1/messages/:message_id",
      "safety" => "read",
      "description" => "Get and normalize one Feishu message, including attachment metadata.",
      "required_params" => ["message_id"],
      "parameters" => %{"message_id" => "Required Feishu message ID."}
    },
    %{
      "name" => "feishu.list_chat_files",
      "method" => "GET /im/v1/messages (bounded attachment projection)",
      "safety" => "read",
      "description" =>
        "List file/image/audio/video attachments found in one bounded page (at most 50 top-level messages) of Feishu chat history. This does not expand threads; use feishu.get_thread_replies for attachments in a known thread. Paginate deliberately for older files.",
      "required_params" => ["chat_id"],
      "parameters" => %{
        "chat_id" => "Required source chat ID.",
        "start_time" => "Optional Unix timestamp in seconds.",
        "end_time" => "Optional Unix timestamp in seconds.",
        "sort_type" => "Optional sort order.",
        "page_size" => "Optional number of top-level messages to scan, default and max 50.",
        "page_token" => "Optional Feishu history page token."
      }
    },
    %{
      "name" => "feishu.fetch_message_resource",
      "method" => "GET /im/v1/messages/:message_id/resources/:file_key",
      "safety" => "media",
      "description" =>
        "Download a historical message attachment into the agent VFS and return a structured VFS attachment. Pass the exact checksummed resource_ref from the selected attachment in a Feishu history, thread, message, or file-list result; do not reconstruct message_id/file_key fields. An image from a synchronous result is attached natively to the following model request; every other file type is staged in the workspace and identified by its VFS path only, and you read it yourself with fs.read_file or convert it on a connected runner with env.copy plus env.exec. If the fetch completes asynchronously, wait for completion, then call tool_call.get_result without offset or limit. Feishu limits each resource to 100 MB.",
      "required_params" => ["resource_ref"],
      "parameters" => %{
        "resource_ref" => %{
          "type" => "string",
          "description" =>
            "Required exact opaque resource_ref returned with the selected attachment. Copy it unchanged; it already binds message ID, resource key, and type."
        },
        "file_name" => "Optional display filename override."
      }
    },
    %{
      "name" => "feishu.update_message",
      "method" => "PUT /im/v1/messages/:message_id",
      "safety" => "write",
      "description" => "Update a text message authored by this connected Feishu bot.",
      "required_params" => ["message_id", "text"],
      "parameters" => %{"message_id" => "Bot-authored message ID.", "text" => "Replacement text."}
    },
    %{
      "name" => "feishu.delete_message",
      "method" => "DELETE /im/v1/messages/:message_id",
      "safety" => "destructive",
      "description" => "Recall a message authored by this connected Feishu bot.",
      "required_params" => ["message_id"],
      "parameters" => %{"message_id" => "Bot-authored message ID."}
    },
    %{
      "name" => "feishu.add_reaction",
      "method" => "POST /im/v1/messages/:message_id/reactions",
      "safety" => "write",
      "description" => "Add a Feishu emoji reaction to a message.",
      "required_params" => ["message_id", "emoji_type"],
      "parameters" => %{
        "message_id" => "Target message ID.",
        "emoji_type" => "Feishu emoji type such as SMILE."
      }
    },
    %{
      "name" => "feishu.list_reactions",
      "method" => "GET /im/v1/messages/:message_id/reactions",
      "safety" => "read",
      "description" => "List one bounded page of reactions on a Feishu message.",
      "required_params" => ["message_id"],
      "parameters" => %{
        "message_id" => "Target message ID.",
        "emoji_type" => "Optional reaction filter.",
        "page_size" => "Optional page size, max 50.",
        "page_token" => "Optional Feishu page token."
      }
    },
    %{
      "name" => "feishu.remove_reaction",
      "method" => "DELETE /im/v1/messages/:message_id/reactions/:reaction_id",
      "safety" => "write",
      "description" => "Remove a reaction authored by this connected Feishu bot.",
      "required_params" => ["message_id", "reaction_id"],
      "parameters" => %{
        "message_id" => "Target message ID.",
        "reaction_id" => "Bot-authored reaction ID."
      }
    },
    %{
      "name" => "feishu.pin_message",
      "method" => "POST /im/v1/pins",
      "safety" => "write",
      "description" => "Pin a visible Feishu message in its chat.",
      "required_params" => ["message_id"],
      "parameters" => %{"message_id" => "Target message ID."}
    },
    %{
      "name" => "feishu.unpin_message",
      "method" => "DELETE /im/v1/pins/:message_id",
      "safety" => "write",
      "description" => "Remove the Pin from a visible Feishu message.",
      "required_params" => ["message_id"],
      "parameters" => %{"message_id" => "Target message ID."}
    },
    %{
      "name" => "feishu.list_pins",
      "method" => "GET /im/v1/pins",
      "safety" => "read",
      "description" => "List one bounded page of Pin messages in a Feishu chat.",
      "required_params" => ["chat_id"],
      "parameters" => %{
        "chat_id" => "Required chat ID.",
        "start_time" => "Optional start timestamp in milliseconds.",
        "end_time" => "Optional end timestamp in milliseconds.",
        "page_size" => "Optional page size, max 50.",
        "page_token" => "Optional Feishu page token."
      }
    },
    %{
      "name" => "feishu.list_chats",
      "method" => "GET /im/v1/chats",
      "safety" => "read",
      "description" => "List one page of Feishu chats visible to the bot.",
      "required_params" => [],
      "parameters" => %{
        "page_size" => "Optional page size, max 50.",
        "page_token" => "Optional page token."
      }
    },
    %{
      "name" => "feishu.list_chat_members",
      "method" => "GET /im/v1/chats/:chat_id/members",
      "safety" => "read",
      "description" => "List one page of members in a Feishu chat.",
      "required_params" => ["chat_id"],
      "parameters" => %{
        "chat_id" => "Required chat ID.",
        "page_size" => "Optional page size, max 50.",
        "page_token" => "Optional page token."
      }
    },
    %{
      "name" => "feishu.get_chat",
      "method" => "GET /im/v1/chats/:chat_id",
      "safety" => "read",
      "description" => "Get bot-visible metadata for a Feishu chat.",
      "required_params" => ["chat_id"],
      "parameters" => %{"chat_id" => "Required Feishu chat ID."}
    },
    %{
      "name" => "feishu.get_user",
      "method" => "GET /contact/v3/users/:user_id",
      "safety" => "read",
      "description" => "Get one known Feishu user by an explicit ID visible to the bot.",
      "required_params" => ["user_id"],
      "parameters" => %{
        "user_id" => "Required user ID.",
        "user_id_type" => "Optional open_id, user_id, or union_id; defaults to open_id."
      }
    },
    %{
      "name" => "feishu.list_departments",
      "method" => "GET /contact/v3/departments/:department_id/children",
      "safety" => "read",
      "description" =>
        "List one bounded page of direct child departments visible in the app's Feishu directory data range. Start at department_id=0 and traverse deliberately; this does not perform an unbounded tenant scan.",
      "required_params" => [],
      "parameters" => %{
        "department_id" => "Optional parent department ID; defaults to root department 0.",
        "department_id_type" =>
          "Optional open_department_id or department_id; defaults to open_department_id.",
        "page_size" => "Optional page size, max 50.",
        "page_token" => "Optional Feishu page token."
      }
    },
    %{
      "name" => "feishu.list_department_users",
      "method" => "GET /contact/v3/users/find_by_department",
      "safety" => "read",
      "description" =>
        "List one bounded page of users directly assigned to a visible Feishu directory department. Use list_departments to traverse the hierarchy and get_user for one selected ID.",
      "required_params" => ["department_id"],
      "parameters" => %{
        "department_id" => "Required department ID; use 0 for the root department.",
        "department_id_type" =>
          "Optional open_department_id or department_id; defaults to open_department_id.",
        "user_id_type" => "Optional open_id, user_id, or union_id; defaults to open_id.",
        "page_size" => "Optional page size, max 50.",
        "page_token" => "Optional Feishu page token."
      }
    },
    %{
      "name" => "feishu.list_contact_scopes",
      "method" => "GET /contact/v3/scopes",
      "safety" => "read",
      "description" =>
        "List one bounded page of departments, users, and user groups explicitly included in this app's Feishu Contacts data range. These are authorization roots, not a complete directory listing; expand returned departments deliberately before claiming a person is absent.",
      "required_params" => [],
      "parameters" => %{
        "user_id_type" => "Optional open_id (default), union_id, or user_id.",
        "department_id_type" => "Optional open_department_id (default) or department_id.",
        "page_size" => "Optional page size, default and max 100 across all returned ID lists.",
        "page_token" => "Optional token returned by the prior call."
      }
    },
    %{
      "name" => "feishu.lookup_users",
      "method" => "local observed-user projection",
      "safety" => "read",
      "description" =>
        "Search users previously observed in inbound Feishu events. This is not a tenant-wide directory keyword search; use feishu.list_chat_members for a chat or feishu.get_user for a known ID.",
      "required_params" => [],
      "parameters" => %{
        "query" => "Optional local filter.",
        "limit" => "Optional max result count."
      }
    },
    %{
      "name" => "feishu.list_observed_chats",
      "method" => "local observed-chat projection",
      "safety" => "read",
      "description" => "List Feishu chats observed from inbound events.",
      "required_params" => [],
      "parameters" => %{
        "query" => "Optional local filter.",
        "limit" => "Optional max result count."
      }
    },
    %{
      "name" => "feishu.list_observed_users",
      "method" => "local observed-user projection",
      "safety" => "read",
      "description" => "List Feishu users observed from inbound events.",
      "required_params" => [],
      "parameters" => %{
        "query" => "Optional local filter.",
        "limit" => "Optional max result count."
      }
    }
  ]

  @slack_by_name Map.new(@slack_operations, &{&1["name"], &1})
  @feishu_by_name Map.new(@feishu_operations, &{&1["name"], &1})

  def api_names("slack"), do: Enum.map(@slack_operations, & &1["name"])
  def api_names("feishu"), do: Enum.map(@feishu_operations, & &1["name"])
  def api_names(_provider), do: []

  def manual_api_entries("slack"), do: Enum.map(@slack_operations, &manual_entry/1)
  def manual_api_entries("feishu"), do: Enum.map(@feishu_operations, &manual_entry/1)
  def manual_api_entries(_provider), do: []

  def metadata("slack", api) do
    case Map.fetch(@slack_by_name, api) do
      {:ok, operation} ->
        {:ok,
         %{
           "method" => operation["method"],
           "safety" => operation["safety"]
         }}

      :error ->
        {:error, :unsupported}
    end
  end

  def metadata("feishu", api) do
    case Map.fetch(@feishu_by_name, api) do
      {:ok, operation} ->
        {:ok, %{"method" => operation["method"], "safety" => operation["safety"]}}

      :error ->
        {:error, :unsupported}
    end
  end

  def metadata(_provider, _api), do: {:error, :unsupported}

  defp manual_entry(operation) do
    operation
    |> Map.take(@manual_keys)
  end
end
