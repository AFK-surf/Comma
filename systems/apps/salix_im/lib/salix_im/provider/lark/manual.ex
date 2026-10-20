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
  @minute_param "Lark Minutes link (/minutes/<token>) or minute token."
  @account_param "Optional signed-in Lark account (alias or open_id from lark.list_accounts) to read as that person instead of as the bot."
  @meeting_account_param "Optional signed-in Lark account (alias or open_id from lark.list_accounts). Omit to use every signed-in account."

  # Reads that can run as a signed-in person when the request names an
  # `account` (`SalixIM.Provider.Lark.Meetings.as_account/3`).
  @account_apis ~w(lark.fetch_doc lark.list_doc_comments lark.fetch_doc_media lark.get_minute
                   lark.list_minutes lark.fetch_minute_media)

  @doc "The names of the cloud document operations."
  @spec document_api_names() :: [String.t()]
  def document_api_names, do: Enum.map(document_apis(), & &1["name"])

  @doc "The names of the Minutes operations."
  @spec minutes_api_names() :: [String.t()]
  def minutes_api_names, do: Enum.map(minutes_apis(), & &1["name"])

  @doc "The names of the meeting operations, read as a signed-in person."
  @spec meeting_api_names() :: [String.t()]
  def meeting_api_names, do: Enum.map(meeting_apis(), & &1["name"])

  @doc "The reads that take an optional `account` to run as a signed-in person."
  @spec account_api_names() :: [String.t()]
  def account_api_names, do: @account_apis

  @doc "The operations a Worker holds besides the reads, whatever their safety class."
  @spec worker_api_names() :: [String.t()]
  def worker_api_names, do: document_api_names() ++ minutes_api_names() ++ meeting_api_names()

  @doc "The safety class of one operation, in the shape of `OperationRegistry.metadata/2`."
  @spec metadata(String.t()) :: {:ok, map()} | {:error, :unsupported}
  def metadata(api) do
    case Enum.find(manual()["apis"], &(&1["name"] == api)) do
      %{"safety" => safety} -> {:ok, %{"method" => nil, "safety" => safety}}
      _unknown -> {:error, :unsupported}
    end
  end

  @spec manual() :: map()
  def manual do
    chat_id = "Optional Lark chat ID (oc_...). Defaults to the chat of the current Lark source."

    %{
      "provider" => "lark",
      "overview" =>
        "Act as this Group's Lark bot: a custom app of the Lark open platform. The bot answers in private chats with people who wrote to it and in groups it was added to, where a message reaches you when it mentions the bot. It reads and writes only in chats it is in.",
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
        "To find a person or a chat, start with what the bot has seen: lark.list_observed_users, lark.lookup_users and lark.list_observed_chats read the people and chats whose messages reached the bot. For the organization's directory, lark.list_contact_scopes gives the departments and people the app may read; walk down with lark.list_departments and lark.list_department_users, and read one person with lark.get_user. Do not say a person does not exist before the departments were expanded.",
        "To mention a person, pass mentions=[{user_id, name}] with the person's open_id: the sender_open_id of a message, or a member_id of lark.list_chat_members. An @name in the text is plain text.",
        "An image of the current message is in your input already. Any other file of it is in your workspace at the path the message names. For a file of an earlier message, copy the exact resource_ref of its attachment from a history, thread, message, file-list or search result into lark.fetch_message_resource. Never build or shorten a resource_ref.",
        "lark.update_message and lark.delete_message work only on the bot's own messages: use the message_id a send returned, never the message of a person.",
        "Lark cloud documents (Docx and Docx pages in a wiki) are read and written as this app, by the Router and by Workers. The app opens a document only when it is shared with a chat that includes the bot, shared with the app, or open by link inside the tenant; on a permission error, ask the person to share the document with the source chat, and never say a document is empty or missing. Read with lark.fetch_doc (the outline first for a long document), then edit with lark.update_doc using block IDs from a detail=with-ids fetch, and fetch again after every write because block IDs change. Create with lark.create_doc and share_chat_id set to the source chat unless the person names another audience, then answer with the returned URL. Comments, collaborators, link sharing, embedded media and wiki discovery have their own lark.*doc* and lark.list_wiki_* operations. Sharing a document opens all of its content to that audience. Spreadsheets, Base, legacy /doc/ documents and Feishu (feishu.cn) links are not supported.",
        "Lark Minutes recordings are read as this app, by the Router and by Workers: lark.get_minute with include for the AI summary, todos, chapters, keywords or transcript; lark.list_minutes to find recordings; lark.fetch_minute_media for the audio or video. The same sharing rule applies as for documents. Minutes cannot be edited here. Ask before you call lark.request_minute_access, because Lark notifies the owner.",
        "Lark shows a meeting, its AI meeting notes, its transcript and its recording only to people. When people of the Agent Swarm signed in (lark.list_accounts), read them as those people without asking anyone to share: find the meeting with lark.search_meetings, read it with lark.get_meeting, then the notes with lark.get_note and lark.fetch_doc, and the recording with lark.get_minute, passing the account that found the meeting. The document and Minutes reads take the same account parameter when the bot itself cannot open a link. When the person who asks has no signed-in account (or theirs expired), let them sign in from the chat: call oauth.request_authorization with provider lark, an alias such as lark-<their name> (an expired account's own alias to renew it) and a reason, send the returned authorization_url in the chat the request came from (like any answer), and continue once the authorization completes. Swarm admins can also add accounts on the swarm's Connections page.",
        "The runtime publishes the Task card after im_api.internal.task.create for a request a person made in Lark. Do not publish again when task_card.status is queued. When that publication failed, call lark.post_task_card once for the existing conversation_id. The card answers the source message and follows the Task by itself; never create another Task to repair the card.",
        "When Lark refuses for a missing permission, do not retry. Tell the person that the app's owner must add the scope in the Lark Developer Console and publish a new version of the app.",
        SalixIM.Provider.Lark.RouterGuidance.meeting_instruction() <>
          " meeting.join is a Router tool: a Worker cannot join. A finished meeting reaches you later as a meeting.completed message: it is context only and asks for no answer.",
        "Keep a reminder or another message of your own to Lark owned by the current Router/session. Use schedule.create with run_at for one time, cron plus timezone for calendar recurrence, or interval_minutes for duration recurrence. Put the exact im_api.lark.send_message call, connect_id, chat_id, text and mentions in the schedule prompt. Find the named people in the chat members or the directory first and pass mentions=[{user_id, name}]; use mention_all=true only when the chat lets the bot mention everyone. A Worker that computes the content returns it to the Router and does not send to Lark.",
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
            "format" => "Optional. \"text\" sends the text literally, without Markdown.",
            "reply_to" =>
              "Optional message_id of a message of this chat to answer under. Not allowed with user_id.",
            "reply_in_thread" =>
              "Optional boolean, with reply_to. A reply goes into the thread of the message (and opens one when it has none) unless the chat is private; false makes it a plain quoting reply in the chat.",
            "mentions" => "Optional list of {user_id, name} to mention, by open_id.",
            "mention_all" =>
              "Optional boolean. Mentions everyone; the chat must allow the bot to do so.",
            "path" =>
              "Optional workspace path of one file to send after the text. An image of at most 10 MB shows inline; any other file of at most 30 MB shows as a file."
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
            "format" => "Optional. \"text\" sends the text literally, without Markdown."
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
            "Read one message by its message_id. Each attachment has the resource_ref that lark.fetch_message_resource takes.",
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
            "Search the people whose messages reached this bot. This is not a search of the organization's directory: use lark.list_chat_members for the people of a chat, or lark.get_user for a known ID.",
          "required_params" => [],
          "parameters" => %{
            "query" => "Optional. Only people with this text in one of their IDs.",
            "limit" => "Optional, default 50, at most 100."
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
      &(&1 ++ account_reads(document_apis() ++ minutes_apis()) ++ meeting_apis())
    )
  end

  defp account_reads(apis) do
    Enum.map(apis, fn api ->
      if api["name"] in @account_apis,
        do:
          Map.update(
            api,
            "parameters",
            %{"account" => @account_param},
            &Map.put(&1, "account", @account_param)
          ),
        else: api
    end)
  end

  # Meetings as a person who signed in for the Group: Lark shows a meeting,
  # its notes and its recording only to people.
  defp meeting_apis do
    [
      %{
        "name" => "lark.list_accounts",
        "safety" => "read",
        "description" =>
          "List the Lark people who signed in for this Agent Swarm: alias, open_id, name and status. The bot reads meetings, meeting notes, recordings and documents as one of them.",
        "required_params" => [],
        "parameters" => %{}
      },
      %{
        "name" => "lark.search_meetings",
        "safety" => "read",
        "description" =>
          "Search finished Lark meetings, newest first, as the signed-in accounts: each meeting the account took part in or can see, with meeting id, topic and times, and the account that found it. Pass at least one filter. For a recurring meeting such as a daily stand-up, search its topic with start and end. next_pages names a page_token per account; pass it with that account.",
        "required_params" => [],
        "parameters" => %{
          "account" => @meeting_account_param,
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
          "Read one finished Lark meeting as a signed-in account: topic, times, host and participants, its note_id (AI meeting notes) and the minute_token of its recording. Read the notes with lark.get_note and the recording with lark.get_minute, passing the same account.",
        "required_params" => ["meeting_id"],
        "parameters" => %{
          "meeting_id" =>
            "The meeting id from lark.search_meetings (a long number, not the 9-digit meeting number).",
          "account" => @meeting_account_param
        }
      },
      %{
        "name" => "lark.get_note",
        "safety" => "read",
        "description" =>
          "Read the AI meeting notes of a Lark meeting as a signed-in account: note_doc_token (the notes document), verbatim_doc_token (the transcript document) and shared_doc_tokens. Read each document with lark.fetch_doc, passing its token and the same account. A unified note (display_type unified) has no transcript document: pass include_transcript=true to get its transcript.",
        "required_params" => ["note_id"],
        "parameters" => %{
          "note_id" => "The note_id from lark.get_meeting.",
          "include_transcript" =>
            "Optional true: for a unified note, read its whole transcript as Markdown (a long one is put in your workspace).",
          "locale" => "Optional transcript language, such as zh_cn (default) or en_us.",
          "account" => @meeting_account_param
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
