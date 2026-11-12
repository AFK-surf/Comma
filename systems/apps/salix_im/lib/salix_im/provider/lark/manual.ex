defmodule SalixIM.Provider.Lark.Manual do
  @moduledoc """
  What the Agent reads about the Lark operations (`im_api.lark.*`):
  `SalixIM.Provider.Manuals` serves it as the manual of the provider `lark`.

  A Worker holds every read operation, including the meeting reads, and the
  whole cloud document and Minutes surface.
  `SalixIM.Provider.OperationRegistry` and the role fence of
  `SalixIM.Provider` read their names and safety classes from here.
  """

  alias SalixIM.LarkCalendarContract

  @page "Optional page_token of the page before. An empty next_page_token means the last page."
  @doc_param "Lark document URL (/docx/ or /wiki/) or token. A bare wiki token needs doc_type=wiki."
  @doc_type_param "Optional. docx (default) or wiki; only needed when doc is a bare wiki node token."
  @base_param "Required Lark Base URL (/base/<app_token>?table=...&view=...), a wiki URL of a Base, or a bare app_token. The URL's table and view become the defaults."
  @sheet_param "Required Lark spreadsheet URL (/sheets/<token>?sheet=...), a wiki URL of a spreadsheet, or a bare spreadsheet token. The URL's sheet becomes the default."
  @minute_param "Lark Minutes link (/minutes/<token>) or minute token."
  @account_param "Optional signed-in Lark account (alias or open_id from lark.list_accounts) to read as that person instead of as the bot."
  @meeting_account_param "Optional: app for the app's own identity, or a signed-in Lark account (alias or open_id from lark.list_accounts). Omit to use the app and then every signed-in account."

  @accounts_from_param "Optional: the accounts_from of the result before. A call reads as at most 10 identities; more_accounts names where the next call starts."

  @write_account_param "Optional signed-in Lark account (alias or open_id from lark.list_accounts) of the person who asked, to write as that person when the app may not edit the document. Only after that person agrees: the edit history shows them as the author. Never another person's account."

  # Reads that can run as a signed-in person when the request names an
  # `account` (`SalixIM.Provider.Lark.Meetings.as_account/3`).
  # The bot cannot read an external chat; a member who signed in can.
  @account_reads ~w(lark.fetch_doc lark.list_doc_comments lark.fetch_doc_media
                    lark.get_base lark.list_base_fields lark.list_base_records
                    lark.get_sheet lark.get_sheet_range lark.get_minute
                    lark.list_minutes lark.fetch_minute_media lark.list_wiki_spaces
                    lark.list_wiki_nodes lark.get_chat_history lark.get_thread_replies lark.get_message)

  # Content writes that can run as the person who asked, when the app may
  # not edit the document. Sharing, link and delete operations stay the app's.
  @account_writes ~w(lark.update_doc lark.insert_doc_media lark.add_doc_comment
                     lark.reply_doc_comment lark.resolve_doc_comment)

  @account_apis @account_reads ++ @account_writes

  @doc "The names of the cloud document operations."
  @spec document_api_names() :: [String.t()]
  def document_api_names, do: Enum.map(document_apis(), & &1["name"])

  @doc "The names of the Base and spreadsheet operations."
  @spec table_api_names() :: [String.t()]
  def table_api_names, do: Enum.map(table_apis(), & &1["name"])

  @doc "The names of the Minutes operations."
  @spec minutes_api_names() :: [String.t()]
  def minutes_api_names, do: Enum.map(minutes_apis(), & &1["name"])

  @doc "The names of the meeting operations, read as a signed-in person."
  @spec meeting_api_names() :: [String.t()]
  def meeting_api_names, do: Enum.map(meeting_apis(), & &1["name"])

  @doc "The reads and content writes that take an optional `account` to run as a signed-in person."
  @spec account_api_names() :: [String.t()]
  def account_api_names, do: @account_apis

  @doc "The operations a Worker holds besides the reads, whatever their safety class."
  @spec worker_api_names() :: [String.t()]
  def worker_api_names,
    do: document_api_names() ++ table_api_names() ++ minutes_api_names() ++ meeting_api_names()

  @doc "The safety class of one operation, in the shape of `OperationRegistry.metadata/2`."
  @spec metadata(String.t()) :: {:ok, map()} | {:error, :unsupported}
  def metadata(api) do
    case Enum.find(manual()["apis"], &(&1["name"] == api)) do
      %{"safety" => safety} -> {:ok, %{"method" => nil, "safety" => safety}}
      _unknown -> {:error, :unsupported}
    end
  end

  # The user scopes one need asks for beyond the default sign-in.
  defp lark_sign_in_scopes(need),
    do: Enum.join(SalixStore.OAuth.Adapters.Lark.on_demand_scopes()[need], ", ")

  @spec manual() :: map()
  def manual do
    chat_id = "Optional Lark chat ID (oc_...). Defaults to the chat of the current Lark source."

    %{
      "provider" => "lark",
      "overview" =>
        "Act as this Group's Lark bot: a custom app of the Lark open platform. The bot answers in private chats with people who wrote to it and in groups it was added to, where a message reaches you when it mentions the bot. It reads and writes only in chats it is in. It can also create private groups and add people when the app has the required permissions.",
      "source_context_mapping" => %{
        "connect_id" => "Use as the top-level connect_id argument.",
        "chat_id" => "The Lark chat. Omit chat_id to act in the current chat.",
        "chat_type" => "p2p for a private chat, group for a group.",
        "message_id" => "The source message. Pass it as reply_to to answer under it.",
        "message_thread_id" =>
          "The thread of the source message, when it is in one. Read it with lark.get_thread_replies.",
        "sender_open_id" => "The sender's open_id for this app. It means nothing to another app.",
        "structured_mentions" =>
          "The people the message mentions, without the bot: open_id and name. For a Google Calendar invitation, read the email of each with lark.get_user.",
        "bot_mentioned" => "True when the message mentions this bot."
      },
      "workflow" => [
        "Answer with lark.send_message. The text is standard Markdown and shows as a rich text post. In a group, always pass the source message_id as reply_to: the answer then goes into the thread of that message, and the people of the group can go on in that thread without mentioning the bot again. A send without reply_to is a new top-level message of the chat.",
        "A message of a thread you answered in reaches you without a mention. Answer it in the same way, with its message_id as reply_to, so the talk stays in its thread. Such a message carries only its own text; read the thread with lark.get_thread_replies when it depends on what was said before.",
        "A group mention carries only its own text. When it depends on the conversation before it, read that with lark.get_chat_history, a thread with lark.get_thread_replies, and search the chats the bot is in by keyword with lark.search_messages. The search reads a local record: check incomplete and stale before you take no hit to mean that nothing was said.",
        "To write to one person in private, pass user_id (an open_id) to lark.send_message instead of chat_id. Use it only when the request asks for a private message: an answer belongs in the chat the request came from.",
        "To find a person by name, call lark.lookup_users with the name: it reads the people the bot has seen and the whole contact data range, from its stored copy when anyone there matches. For everyone, the whole directory or all members, call lark.list_directory_users yourself in this session, with no Task and no machine, and call it again with the continue_from it returns until complete is true. lark.list_observed_users and lark.list_observed_chats read the people and chats whose messages reached the bot. lark.list_contact_scopes gives the departments and people the app may read; lark.list_department_users lists only a department's direct members, so walk sub-departments with lark.list_departments. Read one person with lark.get_user. An empty department or search is not a missing permission: only a Lark error says that.",
        "To join a public group a person asked for, find it with lark.search_chats and call lark.join_chat. Neither Lark nor an administrator can put the bot into private groups in bulk: a member of each one adds it.",
        "To mention a person, pass mentions=[{user_id, name}] with the person's open_id: the sender_open_id of a message, or a member_id of lark.list_chat_members. To mention one at a place in the text, such as after each owner in a list, also write <at user_id=\"ID\">name</at> there; the others show at the start. An @name in the text is plain text.",
        "An image of the current message is in your input already. Any other file of it is in your workspace at the path the message names. For a file of an earlier message, copy the exact resource_ref of its attachment from a history, thread, message, file-list or search result into lark.fetch_message_resource. Never build or shorten a resource_ref.",
        "To give a file or a message of a chat to another chat or person, forward it with lark.forward_message. Do not fetch the file and send it again: a send takes at most 30 MB, and a fetch fails above 100 MB.",
        "lark.update_message and lark.delete_message work only on the bot's own messages: use the message_id a send returned, never the message of a person.",
        "Lark cloud documents (Docx and Docx pages in a wiki), spreadsheets and Base are read in one order of identities, by the Router and by Workers. 1. Read as this app. The app opens a document only when it is shared with a chat that includes the bot, shared with the app, or open by link inside the tenant. 2. When the app is denied, read again with account set to the signed-in account of the person who asked (lark.list_accounts), never another person's account. 3. When that person has no signed-in account, or it is expired or needs authorization again, call oauth.request_authorization with provider lark, send its authorization_url in the chat the request came from, and read with their account when it completes. The default sign-in reads documents only: for a spreadsheet or Base read, pass scopes [#{lark_sign_in_scopes("tables")}] to oauth.request_authorization, also when their account exists but lacks them. Such a sign-in keeps the default scopes, and a person who signed in before grants only the new ones. 4. When their account is denied too, offer to ask the owner for access as them with lark.request_doc_access; call it only after they agree, once per document, and after the owner approves read it with their account. The person may prefer to share the document with the source chat instead; that is their choice, not your first answer. A missing app scope (Lark error 99991672) is not a sharing problem: tell the person that a tenant admin must enable the scopes the error names in the Lark developer console and publish a new app version. When a sign-in lacks a scope (error 99991679), call oauth.request_authorization again with those scopes; if the authorization page refuses them (error 20027), a tenant admin must enable them as user scopes there first. Never say a document is empty or missing. Writes follow the same order: write as this app; when the app may not edit the document, ask the person who asked whether you may write as them, because the edit history shows them as the author, and only after they agree pass their account to lark.update_doc, lark.insert_doc_media or the comment operations; with no signed-in account, an expired one, or one without the write scopes, call oauth.request_authorization with scopes [#{lark_sign_in_scopes("document_writes")}]; when their account may not edit either, offer lark.request_doc_access with perm edit. Creating, sharing, link settings and deleting run as the app only and take no account. Read with lark.fetch_doc (the outline first for a long document), then edit with lark.update_doc using block IDs from a detail=with-ids fetch, and fetch again after every write because block IDs change. Create with lark.create_doc and share_chat_id set to the source chat unless the person names another audience, then answer with the returned URL. Comments, collaborators, link sharing, embedded media and wiki discovery have their own lark.*doc* and lark.list_wiki_* operations. Sharing a document opens all of its content to that audience. Legacy /doc/ documents and Feishu (feishu.cn) links are not supported.",
        "Lark Base (/base/ links) and spreadsheets (/sheets/ links) are read in the same order of identities as documents, by the Router and by Workers, and every table read takes account; a wiki page that holds one is read the same way. With filter or sort the search runs over the whole table and the view does not apply, so pass the bare app_token and table_id then, without a view. For a Base, call lark.get_base for its tables, lark.list_base_fields for the columns and views of the table the link names (?table= and ?view=), then lark.list_base_records page by page until has_more is false, with the link's view_id so the person's filter applies. For a spreadsheet, call lark.get_sheet for its sheets and their row counts, then lark.get_sheet_range in ranges of at most 500 rows. Never ask a person to export a Base or spreadsheet to Excel or CSV: when a read is denied, take the next step of that order. These reads are read-only: writing cells or records is not supported here.",
        "Lark Minutes recordings are read as this app, by the Router and by Workers: lark.get_minute with include for the AI summary, todos, chapters, keywords or transcript; lark.list_minutes to find recordings; lark.fetch_minute_media for the audio or video. The same sharing rule applies as for documents. Minutes cannot be edited here. Ask before you call lark.request_minute_access, because Lark notifies the owner.",
        "Find Lark content yourself; never ask a person to paste a link. The app and every person who signed in for the Agent Swarm (lark.list_accounts) each see their own documents, wiki, meetings, AI meeting notes and Minutes, lark.search_docs (documents and wiki pages by keyword), lark.list_drive_files (a cloud space) and lark.search_meetings run as the app and then as each signed-in person unless you name one account (account=app for the app alone); lark.list_wiki_spaces, lark.list_wiki_nodes and lark.list_minutes run as the app, so call them again with each signed-in account to see what that person sees. Read what you found with the same account: documents and wiki pages with lark.fetch_doc, a meeting with lark.get_meeting and then its notes with lark.get_note and lark.fetch_doc, a recording with lark.get_minute, a message link someone shared (/client/message/link/open?token=...) with lark.read_message_link. A person sees far more than the app. When the person who asks has no signed-in account (or theirs expired) and the app finds nothing, let them sign in from the chat: call oauth.request_authorization with provider lark, an alias such as lark-<their name> (an expired account's own alias to renew it) and a reason, send the returned authorization_url in the chat the request came from (like any answer), and continue once the authorization completes. Swarm admins can also add accounts on the swarm's Connections page.",
        "The runtime publishes the Task card after im_api.internal.task.create for a request a person made in Lark. Do not publish again when task_card.status is queued. When that publication failed, call lark.post_task_card once for the existing conversation_id. The card answers the source message and follows the Task by itself; never create another Task to repair the card.",
        "When Lark refuses the app for a missing permission, do not retry. Tell the person that the app's owner must add the scope in the Lark Developer Console and publish a new version of the app. A person's sign-in that lacks a scope is renewed with oauth.request_authorization and that scope, as the document rules say.",
        SalixIM.Provider.Lark.RouterGuidance.meeting_instruction() <>
          " meeting.join is a Router tool: a Worker cannot join. A finished meeting reaches you later as a meeting.completed message: it is context only and asks for no answer.",
        "Use schedule.create for a Lark reminder: a message whose text is known now, sent by the current Router/session at a time or on a cadence. Use run_at for one time, cron plus timezone for calendar recurrence, or interval_minutes for duration recurrence. Put the exact im_api.lark.send_message call, connect_id, chat_id, text and mentions in the schedule prompt. Find the named people in the chat members or the directory first and pass mentions=[{user_id, name}]; use mention_all=true only when the chat lets the bot mention everyone. Work that repeats or keeps watching something (a recurring check, digest or monitor that must look something up or decide at each run) is a Loop Task, im_api.internal.task.create with loop: its Worker runs it and reports each run as the Task says, and when that Worker or Loop fails you continue in that Task, never on schedule.create. A worker that computes a reminder's content returns it to the Router and does not send to Lark.",
        LarkCalendarContract.instruction(),
        "Google Calendar is the source of truth for meeting time and invitations. A notice in Lark when a Calendar meeting starts is a separate setting of the operator: never say one will be sent because the event was created. Create a schedule.create reminder for a Calendar meeting only when the person asks for a separate reminder, and do not repeat a configured Calendar notice. schedule.create is the normal path for a reminder that is not a Calendar meeting."
      ],
      "apis" => [
        %{
          "name" => "lark.send_message",
          "safety" => "write",
          "description" =>
            "Send Markdown text, and optionally one file from your workspace, to a Lark chat, or to one person as a private message (user_id). Returns the sent message, and the file's message when a file went with it.",
          "required_params" => [],
          "parameters" => %{
            "chat_id" => chat_id,
            "user_id" =>
              "Optional. The person to send a private message to, instead of chat_id. Pass one of the two, never both. The person must be in the app's availability range.",
            "user_id_type" =>
              "Optional, with user_id. open_id (default), user_id, union_id or email.",
            "text" =>
              "Standard Markdown. May be empty when path is given. An external image becomes a labelled link.",
            "format" =>
              "Optional. Leave it out to send Markdown. \"text\" sends plain text: Markdown marks such as ** and ` show as typed.",
            "reply_to" =>
              "Optional message_id of a message of this chat to answer under. Not allowed with user_id.",
            "reply_in_thread" =>
              "Optional boolean, with reply_to. A reply goes into the thread of the message (and opens one when it has none) unless the chat is private; false makes it a plain quoting reply in the chat.",
            "mentions" =>
              "Optional list of {user_id, name} to mention, by open_id. Each shows at the start, unless the text places it with <at user_id=\"ID\">name</at>.",
            "mention_all" =>
              "Optional boolean. Mentions everyone; the chat must allow the bot to do so.",
            "path" =>
              "Optional workspace path of one file to send after the text. An image of at most 10 MB shows inline; any other file of at most 30 MB shows as a file.",
            "question" => SalixIM.QuestionCard.parameter()
          }
        },
        %{
          "name" => "lark.forward_message",
          "safety" => "write",
          "description" =>
            "Forward one message, as it is, to a Lark chat or to one person. Lark copies the message on its side, so a file of any size goes without a download. Returns the new message.",
          "required_params" => ["message_id"],
          "parameters" => %{
            "message_id" =>
              "The message to forward: a message_id from a history, thread, message, file-list or search result.",
            "chat_id" =>
              "The Lark chat ID (oc_...) to forward to. Pass chat_id or user_id, never both.",
            "user_id" => "The person to forward to in private, instead of chat_id.",
            "user_id_type" =>
              "Optional, with user_id. open_id (default), user_id, union_id or email."
          }
        },
        %{
          "name" => "lark.post_task_card",
          "safety" => "write",
          "description" =>
            "Publish the Task card of a Task after im_api.internal.task.create. The card answers the source message, and the runtime keeps the same card in step with the status and the public progress of the Task.",
          "required_params" => ["conversation_id", "chat_id", "message_id"],
          "parameters" => %{
            "conversation_id" => "The conversation_id im_api.internal.task.create returned.",
            "chat_id" => "The Lark chat_id of the source context.",
            "message_id" =>
              "The message to answer: the root message of the source's thread when it is in one, otherwise the source message_id.",
            "chat_type" =>
              "The source chat_type, group or p2p. Defaults to group, where the card goes into the thread of the message."
          }
        },
        %{
          "name" => "lark.update_message",
          "safety" => "write",
          "description" => "Replace the text of a message this bot sent.",
          "required_params" => ["message_id", "text"],
          "parameters" => %{
            "chat_id" => chat_id,
            "message_id" => "The message_id a send of this bot returned.",
            "text" => "The new standard Markdown text.",
            "format" =>
              "Optional. Leave it out to send Markdown. \"text\" sends plain text: Markdown marks such as ** and ` show as typed."
          }
        },
        %{
          "name" => "lark.delete_message",
          "safety" => "write",
          "description" => "Take back a message this bot sent.",
          "required_params" => ["message_id"],
          "parameters" => %{"message_id" => "The message_id a send of this bot returned."}
        },
        %{
          "name" => "lark.get_chat_history",
          "safety" => "read",
          "description" =>
            "Read one page of a chat's top-level messages from Lark, newest first: text, sender, time, thread_id and attachments. Each attachment has the resource_ref that lark.fetch_message_resource takes.",
          "required_params" => ["chat_id"],
          "parameters" => %{
            "chat_id" => "The Lark chat ID.",
            "start_time" => "Optional lower bound, Unix seconds.",
            "end_time" => "Optional upper bound, Unix seconds.",
            "sort_type" => "Optional. ByCreateTimeDesc (default) or ByCreateTimeAsc.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.get_thread_replies",
          "safety" => "read",
          "description" =>
            "Read one page of the messages of a thread. Each attachment has the resource_ref that lark.fetch_message_resource takes.",
          "required_params" => ["thread_id"],
          "parameters" => %{
            "thread_id" => "The thread_id of a message.",
            "sort_type" => "Optional. ByCreateTimeDesc (default) or ByCreateTimeAsc.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.get_message",
          "safety" => "read",
          "description" =>
            "Read one message by its message_id. Each attachment has the resource_ref that lark.fetch_message_resource takes. A merged forward (message_type merge_forward) comes with the messages it carries in forwarded_messages, each naming the forward that holds it in upper_message_id.",
          "required_params" => ["message_id"],
          "parameters" => %{"message_id" => "The Lark message ID (om_...)."}
        },
        %{
          "name" => "lark.search_messages",
          "safety" => "read",
          "description" =>
            "Search by keyword the messages of the chats this bot is in, thread replies too: what Lark delivered to the bot, what the bot sent, and the earlier history, which is read in from Lark over time. It reads a local record, not Lark. A hit has the shape of a message of lark.get_chat_history. stale=true on a hit means a newer state of the message is on its way. incomplete.reason=not_synced means a part of the history is not read in yet, not that nothing matches; incomplete.older_than is the time (Unix milliseconds) before which messages can be missing. Read that part with lark.get_chat_history.",
          "required_params" => ["query"],
          "parameters" => %{
            "query" =>
              "Keywords, all of which must match. Narrow with in:<chat_id>, from:<open_id>, after:YYYY-MM-DD, before:YYYY-MM-DD and has:file; exclude a word with -word.",
            "thread_id" => "Optional. Only messages of this thread.",
            "count" => "Optional, default 30, at most 200.",
            "sort_dir" => "Optional. desc (default, newest first) or asc.",
            "cursor" => "Optional next_cursor of the page before."
          }
        },
        %{
          "name" => "lark.list_chat_files",
          "safety" => "read",
          "description" =>
            "List the files and images of one page of a chat's top-level messages, each with the resource_ref that lark.fetch_message_resource takes.",
          "required_params" => ["chat_id"],
          "parameters" => %{
            "chat_id" => "The Lark chat ID.",
            "start_time" => "Optional lower bound, Unix seconds.",
            "end_time" => "Optional upper bound, Unix seconds.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.fetch_message_resource",
          "safety" => "read",
          "description" =>
            "Copy one file or image of a message into your workspace, at most 100 MB, and return its path. Pass the exact resource_ref of the attachment; a resource_ref of another connect is refused.",
          "required_params" => ["resource_ref"],
          "parameters" => %{
            "resource_ref" =>
              "The resource_ref of the attachment, as a history, thread, message, file-list or search result gives it. Copy it unchanged: it names the message, the file and its kind.",
            "file_name" => "Optional name for the copy."
          }
        },
        %{
          "name" => "lark.add_reaction",
          "safety" => "write",
          "description" => "Add an emoji reaction to a message.",
          "required_params" => ["message_id", "emoji_type"],
          "parameters" => %{
            "message_id" => "The message to react to.",
            "emoji_type" => "Lark's name of the emoji, such as THUMBSUP, OK or DONE."
          }
        },
        %{
          "name" => "lark.list_reactions",
          "safety" => "read",
          "description" => "List the reactions of a message, each with its reaction_id.",
          "required_params" => ["message_id"],
          "parameters" => %{
            "message_id" => "The message.",
            "emoji_type" => "Optional. Only reactions of this emoji.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.remove_reaction",
          "safety" => "write",
          "description" => "Remove a reaction this bot added.",
          "required_params" => ["message_id", "reaction_id"],
          "parameters" => %{
            "message_id" => "The message.",
            "reaction_id" => "The reaction_id from lark.add_reaction or lark.list_reactions."
          }
        },
        %{
          "name" => "lark.pin_message",
          "safety" => "write",
          "description" => "Pin a message in its chat.",
          "required_params" => ["message_id"],
          "parameters" => %{"message_id" => "The message to pin."}
        },
        %{
          "name" => "lark.unpin_message",
          "safety" => "write",
          "description" => "Remove the pin of a message.",
          "required_params" => ["message_id"],
          "parameters" => %{"message_id" => "The pinned message."}
        },
        %{
          "name" => "lark.list_pins",
          "safety" => "read",
          "description" => "List the pinned messages of a chat.",
          "required_params" => ["chat_id"],
          "parameters" => %{
            "chat_id" => "The Lark chat ID.",
            "start_time" => "Optional lower bound, Unix milliseconds.",
            "end_time" => "Optional upper bound, Unix milliseconds.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.search_chats",
          "safety" => "read",
          "description" =>
            "Search the groups this app can see by keyword, including public groups it has not joined (search_types with public_not_joined). Private groups the bot is not in are never returned. Returns chat_id, name, description and owner of each. Check has_more and notice before treating a result as complete; Lark can stop a deep result with an error asking for a more specific keyword.",
          "required_params" => [],
          "parameters" => %{
            "query" => "Optional keyword, at most 50 characters. Matches group and member names.",
            "search_types" =>
              "Optional list among private, external, public_joined, public_not_joined.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.join_chat",
          "safety" => "admin",
          "description" =>
            "Make this bot join one public group of the organization, which puts it in the group for its messages from then on. Only for a group the person asked for: the members see the bot join. Public groups only: a private group needs a member to add the bot, and a public group with join verification refuses (232075). Needs the published im:chat.members:write_only permission. Find the chat_id with lark.search_chats.",
          "required_params" => ["chat_id"],
          "parameters" => %{
            "chat_id" =>
              "The public group ID (oc_...). Required. Never inferred from the current chat."
          }
        },
        %{
          "name" => "lark.create_chat",
          "safety" => "admin",
          "description" =>
            "Create a private group with the requested name and people. The bot joins as the owner. Resolve people with lark.list_chat_members or lark.get_user first. Needs the published im:chat:create permission, and the people must be in the app's availability range. Returns chat_id. Check members with lark.list_chat_members before reporting that everyone joined. Do not repeat after an unknown result: a new call can create another group.",
          "required_params" => ["name", "user_ids"],
          "parameters" => %{
            "name" => "The group name the person requested.",
            "user_ids" =>
              "List of 1 to 50 person open_ids (ou_...). Include the requester when they want to join."
          }
        },
        %{
          "name" => "lark.add_chat_members",
          "safety" => "admin",
          "description" =>
            "Add the requested people to an existing group. They may gain access to its history and shared content. Needs the published im:chat.members:write_only permission and permission to add members in this group. The people must be in the app's availability range. Lark rejects the request if any person is unavailable.",
          "required_params" => ["chat_id", "user_ids"],
          "parameters" => %{
            "chat_id" =>
              "The target group ID (oc_...). Required. Never inferred from the current chat.",
            "user_ids" => "List of 1 to 50 person open_ids (ou_...) from Lark, not names."
          }
        },
        %{
          "name" => "lark.list_chats",
          "safety" => "read",
          "description" => "List the groups this bot is in: chat_id, name and owner.",
          "required_params" => [],
          "parameters" => %{
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.get_chat",
          "safety" => "read",
          "description" => "Read one chat: name, description, owner and settings.",
          "required_params" => ["chat_id"],
          "parameters" => %{"chat_id" => "The Lark chat ID."}
        },
        %{
          "name" => "lark.list_chat_members",
          "safety" => "read",
          "description" =>
            "List the members of a group: member_id (the open_id) and name. Bots are not listed.",
          "required_params" => ["chat_id"],
          "parameters" => %{
            "chat_id" => "The Lark chat ID.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.get_user",
          "safety" => "read",
          "description" =>
            "Read one person of the organization: name, email and departments, as far as the app's contact scopes allow.",
          "required_params" => ["user_id"],
          "parameters" => %{
            "user_id" => "The person's ID.",
            "user_id_type" => "Optional. open_id (default), user_id or union_id."
          }
        },
        %{
          "name" => "lark.list_observed_chats",
          "safety" => "read",
          "description" =>
            "List the chats whose messages reached this bot, newest first: chat_id and chat_type. It reads a local list, not Lark; lark.list_chats reads every group the bot is in.",
          "required_params" => [],
          "parameters" => %{
            "query" => "Optional. Only chats whose chat_id or chat_type holds this text.",
            "limit" => "Optional, default 50, at most 100."
          }
        },
        %{
          "name" => "lark.list_observed_users",
          "safety" => "read",
          "description" =>
            "List the people whose messages reached this bot, newest first: open_id, user_id and union_id. It reads a local list, not Lark, and it holds no names; read a name with lark.get_user.",
          "required_params" => [],
          "parameters" => %{
            "query" => "Optional. Only people with this text in one of their IDs.",
            "limit" => "Optional, default 50, at most 100."
          }
        },
        %{
          "name" => "lark.lookup_users",
          "safety" => "read",
          "description" =>
            "Find people by name, English name, nickname or email: first the people whose messages reached this bot, then the app's contact data range: its stored copy when anyone there matches (directory.stored is true, directory.synced_at says when it was read), else every department of the live range. Each user has source observed or directory; directory.complete says whether the whole data range was read, and directory.error gives a Lark refusal. When several people match, ask the requester which one they mean before you act.",
          "required_params" => [],
          "parameters" => %{
            "query" => "Text to find. Without it only the people the bot has seen are listed.",
            "limit" => "Optional, default 50, at most 100."
          }
        },
        %{
          "name" => "lark.list_directory_users",
          "safety" => "read",
          "description" =>
            "List everyone in the app's Contacts data range, for a request about the whole directory or all members: each person once with name, en_name, email, enterprise_email, employee_no, job_title, open_id and the paths of their departments, no phone numbers. One call reads whole departments with at most 120 Lark requests; while complete is false, call it again with the returned continue_from until complete is true, and merge the calls' users by open_id. data_range says how many of the range's roots the walk reached. To find one person by name, use lark.lookup_users.",
          "required_params" => [],
          "parameters" => %{
            "continue_from" =>
              "Optional. The continue_from of the previous call, exactly as returned. Omit it to start at the beginning."
          }
        },
        %{
          "name" => "lark.list_contact_scopes",
          "safety" => "read",
          "description" =>
            "List one page of the departments, people and user groups that the app's contact data range names. These are the roots the app may read, not the whole directory: expand the departments before you say a person is absent.",
          "required_params" => [],
          "parameters" => %{
            "user_id_type" => "Optional. open_id (default), union_id or user_id.",
            "department_id_type" => "Optional. open_department_id (default) or department_id.",
            "page_size" => "Optional, at most 100 across the three lists.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.list_departments",
          "safety" => "read",
          "description" =>
            "List one page of the direct child departments of a department, as far as the app's contact data range allows. Start at department_id 0 and go down one level at a time.",
          "required_params" => [],
          "parameters" => %{
            "department_id" => "Optional parent department ID. Defaults to the root, 0.",
            "department_id_type" => "Optional. open_department_id (default) or department_id.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        },
        %{
          "name" => "lark.list_department_users",
          "safety" => "read",
          "description" =>
            "List one page of the people directly in a department. Use lark.list_departments for its child departments and lark.get_user for one person.",
          "required_params" => ["department_id"],
          "parameters" => %{
            "department_id" => "The department ID. 0 is the root department.",
            "department_id_type" => "Optional. open_department_id (default) or department_id.",
            "user_id_type" => "Optional. open_id (default), user_id or union_id.",
            "page_size" => "Optional, at most 50.",
            "page_token" => @page
          }
        }
      ]
    }
    |> Map.update!(
      "apis",
      &(account_reads(&1) ++
          account_reads(document_apis() ++ table_apis() ++ minutes_apis()) ++ meeting_apis())
    )
  end

  defp account_reads(apis) do
    Enum.map(apis, fn api ->
      cond do
        api["name"] in @account_reads -> put_account(api, @account_param)
        api["name"] in @account_writes -> put_account(api, @write_account_param)
        true -> api
      end
    end)
  end

  defp put_account(api, param),
    do: Map.update(api, "parameters", %{"account" => param}, &Map.put(&1, "account", param))

  # Discovery and meetings, as the app or a person who signed in for the
  # Group (`SalixIM.Provider.Lark.Meetings`).
  defp meeting_apis do
    [
      %{
        "name" => "lark.list_accounts",
        "safety" => "read",
        "description" =>
          "List the Lark people who signed in for this Agent Swarm: alias, open_id, name, status, and account (what to pass as account to read as them). The bot reads meetings, meeting notes, recordings and documents as one of them.",
        "required_params" => [],
        "parameters" => %{}
      },
      %{
        "name" => "lark.search_docs",
        "safety" => "read",
        "description" =>
          "Search Lark documents and wiki pages by keyword (title and content), as the app and as the signed-in accounts: each hit with title, type, url, token, owner and the account that found it. A person finds what they may open, so search before asking anyone for a link. Read a hit with lark.fetch_doc (docx and wiki pages) passing its url and the same account. next_pages names a page_token per account; pass it with that account.",
        "required_params" => ["query"],
        "parameters" => %{
          "query" => "Keyword, at most 30 characters.",
          "account" => @meeting_account_param,
          "accounts_from" => @accounts_from_param,
          "page_size" => "Optional, at most 20.",
          "page_token" => "Optional page_token from next_pages, with its account."
        }
      },
      %{
        "name" => "lark.list_drive_files",
        "safety" => "read",
        "description" =>
          "List one folder of a Lark cloud space, as the app and as the signed-in accounts: name, type, token and url of each file and folder, and the account it belongs to. Without folder, the root of each identity's own space. Open a folder by passing its token as folder with the same account; read a docx with lark.fetch_doc.",
        "required_params" => [],
        "parameters" => %{
          "folder" => "Optional folder token; omit for the root of the space.",
          "account" => @meeting_account_param,
          "accounts_from" => @accounts_from_param,
          "page_token" => "Optional page_token from next_pages, with its account."
        }
      },
      %{
        "name" => "lark.search_meetings",
        "safety" => "read",
        "description" =>
          "Search finished Lark meetings, newest first, as the app and as the signed-in accounts: each meeting the identity took part in or can see, with meeting id, topic and times, and the account that found it. Pass at least one filter. For a recurring meeting such as a daily stand-up, search its topic with start and end. next_pages names a page_token per account; pass it with that account.",
        "required_params" => [],
        "parameters" => %{
          "account" => @meeting_account_param,
          "accounts_from" => @accounts_from_param,
          "query" => "Optional keyword or 9-digit meeting number, at most 50 characters.",
          "organizer_ids" => "Optional list of organizer open_ids (any of them).",
          "participant_ids" => "Optional list of participant open_ids (any of them).",
          "start" => "Optional earliest start time: RFC 3339 or YYYY-MM-DD.",
          "end" => "Optional latest start time: RFC 3339 or YYYY-MM-DD.",
          "page_size" => "Optional, at most 30.",
          "page_token" => "Optional page_token from next_pages, with its account."
        }
      },
      %{
        "name" => "lark.get_meeting",
        "safety" => "read",
        "description" =>
          "Read one finished Lark meeting as the app or a signed-in account (each in turn until one may see it): topic, times, host and participants, its note_id (AI meeting notes) and the minute_token of its recording. Read the notes with lark.get_note and the recording with lark.get_minute, passing the same account.",
        "required_params" => ["meeting_id"],
        "parameters" => %{
          "meeting_id" =>
            "The meeting id from lark.search_meetings (a long number, not the 9-digit meeting number).",
          "account" => @meeting_account_param,
          "accounts_from" => @accounts_from_param
        }
      },
      %{
        "name" => "lark.read_message_link",
        "safety" => "read",
        "description" =>
          "Read a Lark message link (https://applink.../client/message/link/open?token=..., what \"copy message link\" makes; a shared one shows as a link such as \"message link from <chat>\"): the messages it holds, each in the shape of lark.get_message, as copied when the link was made, as the app or a signed-in account (each in turn until one may read it). chat names the chat they came from when that identity may see it. The token is not a message ID.",
        "required_params" => ["url"],
        "parameters" => %{
          "url" => "The whole message link, unchanged.",
          "account" => @meeting_account_param,
          "accounts_from" => @accounts_from_param
        }
      },
      %{
        "name" => "lark.get_note",
        "safety" => "read",
        "description" =>
          "Read the AI meeting notes of a Lark meeting as the app or a signed-in account: note_doc_token (the notes document), verbatim_doc_token (the transcript document) and shared_doc_tokens. Read each document with lark.fetch_doc, passing its token and the same account. A unified note (display_type unified) has no transcript document: pass include_transcript=true to get its transcript, which Lark gives only to a signed-in account.",
        "required_params" => ["note_id"],
        "parameters" => %{
          "note_id" => "The note_id from lark.get_meeting.",
          "include_transcript" =>
            "Optional true: for a unified note, read its whole transcript as Markdown (a long one is put in your workspace).",
          "locale" => "Optional transcript language, such as zh_cn (default) or en_us.",
          "account" => @meeting_account_param,
          "accounts_from" => @accounts_from_param
        }
      }
    ]
  end

  # Cloud documents as the connect's app.
  defp document_apis do
    [
      %{
        "name" => "lark.fetch_doc",
        "safety" => "read",
        "description" =>
          "Read a Lark document (Docx, or a Docx page in a wiki) that is shared with a chat containing this bot, shared with the app, or open by link inside the tenant. Returns Markdown by default with unresolved comments in reference_map. For a large document read the outline first, then one section, range or keyword match. Use detail=with-ids before editing, so block IDs can target lark.update_doc.",
        "required_params" => ["doc"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "format" => "Optional. markdown (default) or xml. xml keeps every Lark block type.",
          "detail" =>
            "Optional. simple (default), with-ids (block IDs for editing and #block_id links), or full (also styles).",
          "scope" =>
            "Optional. full (default), outline (headings only), section (one heading's section; needs start_block_id), range (start_block_id and/or end_block_id), or keyword (needs keyword; '|' separates alternatives).",
          "start_block_id" => "Section anchor or range start block ID.",
          "end_block_id" => "Range end block ID; -1 reads to the end.",
          "keyword" => "Keyword for scope=keyword.",
          "context_before" => "Optional top-level sibling blocks to add before each match.",
          "context_after" => "Optional top-level sibling blocks to add after each match.",
          "max_depth" =>
            "Optional heading level cap for outline, or subtree depth for other scopes.",
          "revision_id" => "Optional historical revision; omit for the latest."
        },
        "example_params" => %{
          "doc" => "https://example.larksuite.com/docx/AbCdEfGhIjKlMnOpQrStUvWx"
        }
      },
      %{
        "name" => "lark.list_doc_comments",
        "safety" => "read",
        "description" => "List one page of the comments and replies on a Lark document.",
        "required_params" => ["doc"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "is_solved" => "Optional boolean filter.",
          "page_size" => "Optional, at most 50.",
          "page_token" => @page
        }
      },
      %{
        "name" => "lark.list_doc_members",
        "safety" => "read",
        "description" =>
          "List a Lark document's collaborators and its link-sharing setting. Lark requires share permission on the document for this read.",
        "required_params" => ["doc"],
        "parameters" => %{"doc" => @doc_param, "doc_type" => @doc_type_param}
      },
      %{
        "name" => "lark.fetch_doc_media",
        "safety" => "media",
        "description" =>
          "Copy one image or attachment embedded in a Lark document into your workspace and return its path. Take file_token from the token attribute of an <img> or <source> in lark.fetch_doc content.",
        "required_params" => ["doc", "file_token"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "file_token" => "The media token from the document content."
        }
      },
      %{
        "name" => "lark.list_wiki_spaces",
        "safety" => "read",
        "description" => "List one page of the wiki spaces this app can see.",
        "required_params" => [],
        "parameters" => %{
          "page_size" => "Optional, at most 50.",
          "page_token" => @page
        }
      },
      %{
        "name" => "lark.list_wiki_nodes",
        "safety" => "read",
        "description" =>
          "List one page of wiki nodes under a space root or a parent node. A docx node's node_token is a wiki document token for the other document operations.",
        "required_params" => ["space_id"],
        "parameters" => %{
          "space_id" => "The wiki space ID.",
          "parent_node_token" => "Optional parent node; omit for the space root.",
          "page_size" => "Optional, at most 50.",
          "page_token" => @page
        }
      },
      %{
        "name" => "lark.create_doc",
        "safety" => "write",
        "description" =>
          "Create a Lark document from Markdown or Lark XML. Without parent, the document is in this app's own space, its link stays closed, and only the share target can open it: pass share_chat_id (usually the source chat) or share_user_id, otherwise nobody can open it. With parent, it is created in that folder (only folders this app created) or under that wiki node and inherits its readers. Returns the document URL.",
        "required_params" => [],
        "parameters" => %{
          "title" => "Document title. title or content is required.",
          "content" => "Document body in the given format.",
          "format" => "Optional. markdown (default) or xml.",
          "parent" => "Optional folder or wiki node URL, or a token with parent_type.",
          "parent_type" => "folder or wiki; required when parent is a bare token.",
          "share_chat_id" => "Optional Lark chat_id whose members get access.",
          "share_user_id" => "Optional open_id of one person who gets access.",
          "share_perm" => "Optional. view, edit (default), or full_access for the share target."
        },
        "example_params" => %{
          "title" => "Weekly report",
          "content" => "## Summary\n\n- Item",
          "share_chat_id" => "oc_example"
        }
      },
      %{
        "name" => "lark.update_doc",
        "safety" => "write",
        "description" =>
          "Edit a Lark document. First read it with lark.fetch_doc detail=with-ids (a section, range or keyword scope for a large document). Commands: str_replace (inline text; pattern + content, empty content deletes), block_replace (block_id, or start_block_id + end_block_id of siblings; content), block_insert_after (block_id; -1 is the end, 0 the start; content), append (content at the end), block_delete (block_id or a sibling range), block_move_after and block_copy_insert_after (block_id + src_block_ids), overwrite (replace everything; loses comments and images, use only on request). Every write changes block IDs: fetch again before the next edit. Check warnings even on success.",
        "required_params" => ["doc", "command"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "command" =>
            "str_replace, block_replace, block_insert_after, append, block_delete, block_move_after, block_copy_insert_after, or overwrite.",
          "format" =>
            "Optional. markdown (default) or xml for content. In markdown, escape literal Markdown characters such as \\*, \\_, \\[ and \\< ; fetched Markdown is already escaped.",
          "content" => "New content for content commands.",
          "pattern" => "Inline text to find for str_replace, in the fetched (escaped) form.",
          "block_id" => "Target block ID.",
          "start_block_id" => "First block of a sibling range; 0 is the document start.",
          "end_block_id" => "Last block of a sibling range; -1 is the document end.",
          "src_block_ids" => "Comma-separated source block IDs, or a list.",
          "revision_id" => "Optional base revision; omit for the latest."
        },
        "example_params" => %{
          "doc" => "https://example.larksuite.com/docx/AbCdEfGhIjKlMnOpQrStUvWx",
          "command" => "block_insert_after",
          "block_id" => "doxcnHeading",
          "content" => "New paragraph."
        }
      },
      %{
        "name" => "lark.insert_doc_media",
        "safety" => "media",
        "description" =>
          "Append an image or file from your workspace (at most 20 MB) to the end of a Lark document. Move it afterwards with lark.update_doc block_move_after.",
        "required_params" => ["doc", "path"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "path" => "The workspace path of the file.",
          "media_type" => "Optional. image or file; inferred from the file extension.",
          "caption" => "Optional image caption."
        }
      },
      %{
        "name" => "lark.add_doc_comment",
        "safety" => "write",
        "description" =>
          "Add a comment to a Lark document, on one block when block_id is given, otherwise on the whole document.",
        "required_params" => ["doc", "text"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "text" => "The comment text.",
          "block_id" => "Optional block ID from lark.fetch_doc detail=with-ids."
        }
      },
      %{
        "name" => "lark.reply_doc_comment",
        "safety" => "write",
        "description" => "Reply to an existing comment on a Lark document.",
        "required_params" => ["doc", "comment_id", "text"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "comment_id" => "The comment ID.",
          "text" => "The reply text."
        }
      },
      %{
        "name" => "lark.resolve_doc_comment",
        "safety" => "write",
        "description" => "Mark a Lark document comment solved, or reopen it with solved=false.",
        "required_params" => ["doc", "comment_id"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "comment_id" => "The comment ID.",
          "solved" => "Optional boolean; defaults to true."
        }
      },
      %{
        "name" => "lark.share_doc",
        "safety" => "admin",
        "description" =>
          "Give a chat or a person access to a Lark document. Lark does not let an app add a department. Everyone in that audience can then read the whole document; share only where the document's content may go. Needs full access on the document.",
        "required_params" => ["doc", "member_type", "member_id"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "member_type" => "chat or user.",
          "member_id" => "The chat_id or open_id.",
          "perm" => "Optional. view (default), edit, or full_access."
        }
      },
      %{
        "name" => "lark.request_doc_access",
        "safety" => "write",
        "description" =>
          "Ask the owner of a Lark document, spreadsheet or Base, as the person who asked you, to give that person access. Lark sends the owner a card to approve; once approved, read it (or edit it, with perm edit) with the same account. Lark takes the request only from a signed-in person, never from the app. Call it only after that person agrees, and only once per document.",
        "required_params" => ["doc", "account"],
        "parameters" => %{
          "doc" =>
            "Lark document, spreadsheet or Base URL (/docx/, /wiki/, /sheets/ or /base/) or token. A bare token other than a Docx needs doc_type.",
          "doc_type" =>
            "Optional. docx (default), wiki, sheet or bitable; only needed when doc is a bare token.",
          "account" =>
            "Required signed-in Lark account (alias or open_id from lark.list_accounts) of the person who asked. Never another person's account.",
          "perm" => "Optional. view (default) or edit.",
          "remark" =>
            "Optional note on the owner's card: why the person needs the document. The owner reads it."
        }
      },
      %{
        "name" => "lark.remove_doc_member",
        "safety" => "admin",
        "description" => "Remove one collaborator from a Lark document.",
        "required_params" => ["doc", "member_type", "member_id"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "member_type" => "chat, user, or department.",
          "member_id" => "The chat_id, open_id, or open_department_id."
        }
      },
      %{
        "name" => "lark.update_doc_link_share",
        "safety" => "admin",
        "description" =>
          "Set who can open a Lark document by link: closed, tenant_readable, or tenant_editable. Internet-wide links are not available here.",
        "required_params" => ["doc", "link_share_entity"],
        "parameters" => %{
          "doc" => @doc_param,
          "doc_type" => @doc_type_param,
          "link_share_entity" => "closed, tenant_readable, or tenant_editable."
        }
      },
      %{
        "name" => "lark.delete_doc",
        "safety" => "destructive",
        "description" =>
          "Move a Lark Docx document to the trash. Only for documents the person asked to delete; this app must own the document or have full access. Wiki pages are not deleted here.",
        "required_params" => ["doc"],
        "parameters" => %{"doc" => "The Docx document URL or token."}
      }
    ]
  end

  # Base (多维表格) and spreadsheets, read as the connect's app or, with
  # `account`, as a signed-in person (`SalixIM.Provider.Lark.Tables`).
  # Workers hold every one of these.
  defp table_apis do
    [
      %{
        "name" => "lark.get_base",
        "safety" => "read",
        "description" =>
          "Read a Lark Base (多维表格) that is shared with a chat containing this bot, shared with the app, or open by link inside the tenant: its name and one page of its tables (table_id and name). Then read a table's fields with lark.list_base_fields and its rows with lark.list_base_records.",
        "required_params" => ["base"],
        "parameters" => %{
          "base" => @base_param,
          "page_size" => "Optional, at most 100.",
          "page_token" => @page
        },
        "example_params" => %{
          "base" =>
            "https://example.larksuite.com/base/AbCdEfGhIjKlMnOpQrStUvWx?table=tblXXXX&view=vewXXXX"
        }
      },
      %{
        "name" => "lark.list_base_fields",
        "safety" => "read",
        "description" =>
          "List the fields (name, field_id, type, options) of one table of a Lark Base, and the table's views. Read this before lark.list_base_records to know the column names and which view holds the rows the person means. Views come with the first page (views_has_more and views_next_page_token page them with views_page_token). A Base with advanced permissions (is_advanced in lark.get_base) restricts rows and fields per collaborator, so its reads stay private to you.",
        "required_params" => ["base"],
        "parameters" => %{
          "base" => @base_param,
          "table_id" => "Table ID (tbl...). Optional when base is a URL with ?table=.",
          "view_id" => "Optional view ID (vew...); fields are listed in that view's order.",
          "page_size" => "Optional, at most 100.",
          "page_token" => @page,
          "views_page_token" =>
            "Optional views_next_page_token of the result before: pages the views alone, with no fields."
        }
      },
      %{
        "name" => "lark.list_base_records",
        "safety" => "read",
        "description" =>
          "Read one page of the records of one table of a Lark Base, each as record_id and fields keyed by field name. Pass the view_id the person's link names so hidden rows and the view's filter apply. A page holds at most 500 records (100 by default); continue with next_page_token until has_more is false, and never guess that a table ends at one page. With filter or sort the search runs over the whole table and the view does not apply, so pass the bare app_token and table_id then. A page larger than one tool result is put in your workspace as JSON.",
        "required_params" => ["base"],
        "parameters" => %{
          "base" => @base_param,
          "table_id" => "Table ID (tbl...). Optional when base is a URL with ?table=.",
          "view_id" => "Optional view ID (vew...). Defaults to the URL's ?view=.",
          "field_names" => "Optional JSON array of field names to return; omit for every field.",
          "filter" =>
            "Optional Base search filter object: {\"conjunction\":\"and\",\"conditions\":[{\"field_name\":\"状态\",\"operator\":\"is\",\"value\":[\"已审核\"]}]}.",
          "sort" => "Optional JSON array of {field_name, desc}.",
          "automatic_fields" => "Optional true to include created/modified time and people.",
          "page_size" => "Optional, at most 500; default 100.",
          "page_token" => @page
        }
      },
      %{
        "name" => "lark.get_sheet",
        "safety" => "read",
        "description" =>
          "Read a Lark spreadsheet that is shared with a chat containing this bot, shared with the app, or open by link inside the tenant: its title and its sheets (sheet_id, title, row and column counts). Then read cells with lark.get_sheet_range.",
        "required_params" => ["sheet"],
        "parameters" => %{"sheet" => @sheet_param},
        "example_params" => %{
          "sheet" => "https://example.larksuite.com/sheets/AbCdEfGhIjKlMnOpQrStUvWx?sheet=0a1b2c"
        }
      },
      %{
        "name" => "lark.get_sheet_range",
        "safety" => "read",
        "description" =>
          "Read the cell values of one A1 range of one sheet of a Lark spreadsheet, as rows of strings. A call reads at most 500 rows and 100 columns; without range it reads the sheet's first block (every column up to 100, 500 rows). has_more says whether the sheet holds more: follow next_range, one cursor that visits each cell once (rows below, then the next columns), until has_more is false, and never total a sheet from one range. A range larger than one tool result is put in your workspace as JSON.",
        "required_params" => ["sheet"],
        "parameters" => %{
          "sheet" => @sheet_param,
          "sheet_id" =>
            "Sheet ID from lark.get_sheet. Optional when sheet is a URL with ?sheet=.",
          "range" => "Optional A1 range inside the sheet, such as A1:H300. Default A1:Z500."
        }
      }
    ]
  end

  # Minutes as the connect's app. Lark offers Minutes edits only to a user
  # identity, so these are reads and an access request to the owner.
  defp minutes_apis do
    [
      %{
        "name" => "lark.get_minute",
        "safety" => "read",
        "description" =>
          "Read one Lark Minutes recording that is shared with a chat containing this bot, shared with the app, or open by link inside the tenant: title, owner, times, and the AI summary, todos, chapters, keywords or transcript named in include. A long transcript is put in your workspace. If Lark is still processing the recording, try again later instead of reporting it empty.",
        "required_params" => ["minute"],
        "parameters" => %{
          "minute" => @minute_param,
          "include" =>
            "Optional list (or comma-separated string) of summary, todos, chapters, keywords, transcript. Omit for details only."
        },
        "example_params" => %{
          "minute" => "https://example.larksuite.com/minutes/obusexampleminute1",
          "include" => ["summary", "todos"]
        }
      },
      %{
        "name" => "lark.list_minutes",
        "safety" => "read",
        "description" =>
          "Search one page of the Lark Minutes recordings this app can see, newest first. Pass at least one filter. Not finding a recording does not prove it does not exist; it may not be shared with the bot.",
        "required_params" => [],
        "parameters" => %{
          "query" => "Optional keyword, at most 50 characters.",
          "owner_ids" => "Optional list of owner open_ids (any of them).",
          "participant_ids" => "Optional list of participant open_ids (any of them).",
          "start" => "Optional earliest creation time: RFC 3339 or YYYY-MM-DD.",
          "end" => "Optional latest creation time: RFC 3339 or YYYY-MM-DD.",
          "page_size" => "Optional, at most 30.",
          "page_token" => @page
        }
      },
      %{
        "name" => "lark.fetch_minute_media",
        "safety" => "media",
        "description" =>
          "Copy the audio or video file of a Lark Minutes recording into your workspace (at most 100 MB) and return its path. Prefer lark.get_minute with include=transcript when text is enough.",
        "required_params" => ["minute"],
        "parameters" => %{"minute" => @minute_param}
      },
      %{
        "name" => "lark.request_minute_access",
        "safety" => "write",
        "description" =>
          "Send the recording's owner a request to give this app access. Lark notifies the owner. Call it only when the person agrees, and only once per recording.",
        "required_params" => ["minute"],
        "parameters" => %{
          "minute" => @minute_param,
          "perm" => "Optional. view (default) or edit."
        }
      }
    ]
  end
end
