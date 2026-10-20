defmodule SalixAgent.IFC.Destination do
  @moduledoc """
  What one tool call writes to, and who is allowed to cause that write
  (`docs/verification.md` §3.5).

  A destination is never taken from the model. This module reads the call's
  own parameters and produces a *descriptor* — a channel id, a conversation
  id, "public" — which the facts resolver turns into an audience label and a
  writer set from provider membership. A model that claims a private channel
  is public gains nothing, because it never supplies the label.

  ## Effect classes

    * `:egress` — content leaves for an audience of people.
    * `:persist` — content is stored where a later activation can read it.
    * `:read` and `:none` — no decision; reads keep their existing Group-level
      authorization and are labelled, not filtered (§7).

  A tool nobody has classified is treated as `:egress` to `{public}` with no
  writer restriction. That is deliberate: an unclassified tool that carries
  no labelled content still passes by declaring `sources: []`, while one that
  carries a private channel's content is refused until someone classifies it
  properly or a person confirms the flow.
  """

  @type class :: :egress | :persist | :read | :none
  @type descriptor :: %{optional(String.t()) => term()}

  # Provider operations that publish content into a conversation. The channel
  # or chat parameter names the audience.
  @scope_egress %{
    "slack.post_message" => "channel",
    "slack.reply_message" => "channel",
    "slack.post_channel_message" => "channel",
    "slack.upload_file" => "channel",
    "slack.post_task_card" => "channel",
    "slack.bind_thread_to_task" => "channel",
    "slack.post_map_card" => "channel",
    "slack.post_stock_card" => "channel",
    "slack.post_weather_card" => "channel",
    "slack.update_message" => "channel",
    "slack.set_channel_topic" => "channel",
    "slack.set_channel_purpose" => "channel",
    "slack.add_bookmark" => "channel",
    "slack.create_canvas" => "channel",
    "slack.edit_canvas" => "canvas_id",
    "telegram.open_task_topic" => "chat_id",
    "telegram.send_message" => "chat_id",
    "telegram.remove_reply_keyboard" => "chat_id",
    "telegram.send_photo" => "chat_id",
    "telegram.send_document" => "chat_id",
    "wechat.send_message" => "to_user"
  }

  # A live voice call speaks to its caller. `call_id` names the call and
  # defaults to the call of the current voice source; ingress records the call
  # as a one-to-one with its caller, so both directions share one atom.
  @voice_egress ~w(voice.say voice.note voice.hang_up)

  # Signal sends address a chat bound to the connect. `chat_id` defaults to
  # the chat of the current Signal source, so the default resolves to the
  # same atom as the inbound.
  @signal_egress ~w(signal.send_message signal.edit_message)

  # A QQ send addresses a chat that wrote to the bot. `chat_id` defaults to the
  # chat of the current QQ source, so the default resolves to the same atom as
  # the inbound.
  @qq_egress ~w(qq.send_message qq.stream_message qq.post_task_card)

  # A Lark send or edit names a chat the bot is in. `chat_id` defaults to the
  # chat of the current Lark source, so the default resolves to the same atom
  # as the inbound.
  @lark_egress ~w(lark.send_message lark.update_message)

  # `lark.send_message` can name one person (`user_id`) instead of a chat.
  # The person's ID is then the destination, whatever kind of ID it is.
  @lark_direct_egress ~w(lark.send_message)

  # A Lark Task card answers a message, and its audience is the chat of that
  # message. `chat_id` is a hint; without it the resolver asks Lark which
  # chat the message is in.
  @lark_message_egress ~w(lark.post_task_card)

  # Lark cloud documents, as the Feishu ones below. New content in an existing
  # document, a media block, or a comment reaches everyone who can read that
  # document; the resolver names that audience from the document's own link
  # setting.
  @lark_document_egress ~w(lark.update_doc lark.insert_doc_media
                           lark.add_doc_comment lark.reply_doc_comment)

  # `lark.update_doc` commands that only delete, move, or copy the document's
  # own blocks. They add nothing the document did not hold.
  @lark_document_reshape ~w(block_delete block_move_after block_copy_insert_after)

  # Operations whose target is one person, not a room.
  @direct_egress %{"slack.send_dm" => "user_id"}

  # Feishu addresses a send by `receive_id`, and `receive_id_type` says what
  # kind of id that is — a chat, or one person. Reading `chat_id` instead (which
  # its sends do not take) resolved every correctly addressed send to an empty
  # scope, which the resolver turns into a public destination with unknown
  # writers: refused under `enforce` however well the chat is known, and not
  # repairable by a receipt.
  @feishu_receive_egress ~w(feishu.send_text feishu.send_image feishu.send_file)

  # And a reply or an edit addresses a message rather than a place. The chat it
  # belongs to is the audience, so the descriptor carries the message and the
  # resolver looks it up — with the caller's own `chat_id` hint when the
  # operation happens to take one, which spares the round trip.
  @feishu_message_egress ~w(feishu.reply_text feishu.update_message feishu.post_task_card)

  @feishu_direct_id_types ~w(open_id user_id union_id email)

  # Feishu cloud documents. New content in an existing document, a media block,
  # or a comment reaches everyone who can read that document; the resolver
  # names that audience from the document's own link setting.
  @feishu_document_egress ~w(feishu.update_doc feishu.insert_doc_media
                             feishu.add_doc_comment feishu.reply_doc_comment)

  # `feishu.update_doc` commands that only delete, move, or copy the
  # document's own blocks. They add nothing the document did not hold.
  @feishu_document_reshape ~w(block_delete block_move_after block_copy_insert_after)

  # Writes with no content of their own: a reaction, a pin, a join. They move
  # no information, so they carry no decision.
  @contentless MapSet.new(~w(
    slack.add_reaction slack.pin_message slack.unpin_message slack.delete_message
    slack.join_channel slack.create_channel slack.invite_users slack.list_emoji
    slack.set_canvas_access slack.delete_canvas_access slack.delete_canvas
    feishu.add_reaction feishu.remove_reaction feishu.pin_message
    feishu.unpin_message feishu.delete_message
    feishu.resolve_doc_comment feishu.remove_doc_member feishu.delete_doc
    feishu.request_minute_access
    signal.react signal.delete_message signal.join_group signal.add_members
    signal.remove_members signal.leave_group
    qq.delete_message
    lark.add_reaction lark.remove_reaction lark.pin_message lark.unpin_message
    lark.delete_message
    lark.resolve_doc_comment lark.remove_doc_member lark.delete_doc
    lark.request_minute_access
  ))

  # Reads. Labelled at the result, never filtered.
  @read_prefixes ~w(
    slack.get_ slack.list_ slack.search slack.message_search slack.semantic_search
    slack.fetch_ feishu.get_ feishu.list_ feishu.fetch_ feishu.lookup_
    internal.read_ internal.search_ internal.list_ internal.get_
    telegram.get_ wechat.get_ signal.list_ qq.list_ qq.search_ qq.fetch_ qq.get_
    lark.get_ lark.list_ lark.search_ lark.fetch_ lark.lookup_
  )

  @doc """
  Classifies one prepared tool call and describes its destination.

  Returns `{class, descriptor}`; the descriptor is meaningless for `:read`
  and `:none`.
  """
  @spec describe(String.t(), map(), map()) :: {class(), descriptor()}
  def describe(name, args, ctx) when is_binary(name) and is_map(args) and is_map(ctx) do
    case String.split(name, ".", parts: 2) do
      ["im_api", operation] -> provider_operation(operation, args, ctx)
      _other -> tool(name, args, ctx)
    end
  end

  def describe(_name, _args, _ctx), do: {:none, %{}}

  def additional_destinations("im_api.internal.triage.complete", args, _ctx) do
    if get_in(args, ["decision", "context_candidates"]) in [nil, []],
      do: [],
      else: [{:persist, %{"kind" => "memory"}}]
  end

  # A new Feishu document is also opened to the chat or person it is shared
  # with at creation.
  def additional_destinations("im_api.feishu.create_doc", args, ctx) do
    cond do
      arg(args, "share_chat_id") != "" ->
        [{:egress, feishu_member("chat", arg(args, "share_chat_id"), args, ctx)}]

      arg(args, "share_user_id") != "" ->
        [{:egress, feishu_member("user", arg(args, "share_user_id"), args, ctx)}]

      true ->
        []
    end
  end

  # A new Lark document is opened to its share target in the same way.
  def additional_destinations("im_api.lark.create_doc", args, ctx) do
    cond do
      arg(args, "share_chat_id") != "" ->
        [{:egress, lark_member("chat", arg(args, "share_chat_id"), args, ctx)}]

      arg(args, "share_user_id") != "" ->
        [{:egress, lark_member("user", arg(args, "share_user_id"), args, ctx)}]

      true ->
        []
    end
  end

  def additional_destinations(_name, _args, _ctx), do: []

  # ---------------------------------------------------------------------------
  # Provider operations
  # ---------------------------------------------------------------------------

  defp provider_operation(operation, args, ctx) do
    api = String.replace(operation, "/", ".")

    cond do
      MapSet.member?(@contentless, api) ->
        {:none, %{}}

      read_operation?(api) ->
        {:read, %{}}

      api in @feishu_receive_egress ->
        {:egress, feishu_receive(api, args, ctx)}

      api in @feishu_message_egress ->
        {:egress, feishu_message(api, args, ctx)}

      api in @feishu_document_egress ->
        if api == "feishu.update_doc" and arg(args, "command") in @feishu_document_reshape,
          do: {:none, %{}},
          else:
            {:egress, feishu_document(api, arg(args, "doc"), arg(args, "doc_type"), args, ctx)}

      api == "feishu.create_doc" ->
        feishu_create_doc(args, ctx)

      api == "feishu.share_doc" ->
        {:egress, feishu_member(arg(args, "member_type"), arg(args, "member_id"), args, ctx)}

      api == "feishu.update_doc_link_share" ->
        if String.starts_with?(arg(args, "link_share_entity"), "tenant"),
          do: {:egress, feishu_space(args, ctx)},
          else: {:none, %{}}

      Map.has_key?(@scope_egress, api) ->
        {:egress, provider_scope(api, Map.fetch!(@scope_egress, api), args, ctx)}

      api in @voice_egress ->
        {:egress, voice_call(args, ctx)}

      api in @signal_egress ->
        {:egress, signal_chat(args, ctx)}

      api in @qq_egress ->
        {:egress, qq_chat(args, ctx)}

      api in @lark_document_egress ->
        if api == "lark.update_doc" and arg(args, "command") in @lark_document_reshape,
          do: {:none, %{}},
          else: {:egress, lark_document(api, arg(args, "doc"), arg(args, "doc_type"), args, ctx)}

      api == "lark.create_doc" ->
        lark_create_doc(args, ctx)

      api == "lark.share_doc" ->
        {:egress, lark_member(arg(args, "member_type"), arg(args, "member_id"), args, ctx)}

      api == "lark.update_doc_link_share" ->
        if String.starts_with?(arg(args, "link_share_entity"), "tenant"),
          do: {:egress, lark_space(args, ctx)},
          else: {:none, %{}}

      api in @lark_direct_egress and arg(args, "user_id") != "" ->
        {:egress, provider_direct(api, "user_id", args, ctx)}

      api in @lark_egress ->
        {:egress, lark_chat(args, ctx)}

      api in @lark_message_egress ->
        {:egress, lark_message(api, args, ctx)}

      Map.has_key?(@direct_egress, api) ->
        {:egress, provider_direct(api, Map.fetch!(@direct_egress, api), args, ctx)}

      api in ~w(internal.triage.read_source internal.triage.read_memory internal.triage.read_context) ->
        {:read, %{}}

      api == "internal.triage.complete" ->
        scope =
          get_in(ctx, [:trusted_origin, "triage_investigation"]) ||
            List.first(List.wrap(ctx[:triage_scopes]))

        case get_in(args, ["decision", "kind"]) do
          "silence" ->
            {:persist,
             %{"kind" => "conversation", "conversation_id" => scope && scope["conversation_id"]}}

          "reaction" ->
            {:none, %{}}

          _ ->
            {:egress, %{"kind" => "triage_result", "scope" => scope}}
        end

      api in ["internal.send_message", "internal.update_conversation"] ->
        {:egress, %{"kind" => "conversation", "conversation_id" => arg(args, "conversation_id")}}

      api in ["internal.task.create"] ->
        {:persist, pending_task(ctx)}

      api in ["internal.task.update"] ->
        {:egress, %{"kind" => "conversation", "conversation_id" => arg(args, "conversation_id")}}

      true ->
        {:egress, %{"kind" => "public"}}
    end
  end

  defp read_operation?(api), do: Enum.any?(@read_prefixes, &String.starts_with?(api, &1))

  defp provider_scope(api, key, args, ctx) do
    %{
      "kind" => "provider_scope",
      "provider" => provider_of(api),
      "connect_id" => connect_id(args, ctx),
      "scope_id" => arg(args, key),
      "thread_id" => arg(args, "thread_ts")
    }
  end

  defp voice_call(args, ctx) do
    call_id =
      case arg(args, "call_id") do
        "" -> trusted_voice_call_id(ctx)
        call_id -> call_id
      end

    %{
      "kind" => "provider_scope",
      "provider" => "voice",
      "connect_id" => connect_id(args, ctx),
      "scope_id" => call_id,
      "thread_id" => ""
    }
  end

  defp trusted_voice_call_id(ctx) do
    origin = Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin") || %{}

    if SalixAgent.IFC.text(SalixAgent.IFC.value(origin, "provider")) == "voice" do
      provider_context = SalixAgent.IFC.value(origin, "provider_context") || %{}
      SalixAgent.IFC.text(SalixAgent.IFC.value(provider_context, "chat_id"))
    else
      ""
    end
  end

  defp signal_chat(args, ctx) do
    chat_id =
      case arg(args, "chat_id") do
        "" -> trusted_signal_chat_id(ctx)
        chat_id -> chat_id
      end

    %{
      "kind" => "provider_scope",
      "provider" => "signal",
      "connect_id" => connect_id(args, ctx),
      "scope_id" => chat_id,
      "thread_id" => ""
    }
  end

  defp trusted_signal_chat_id(ctx) do
    origin = Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin") || %{}

    if SalixAgent.IFC.text(SalixAgent.IFC.value(origin, "provider")) == "signal" do
      provider_context = SalixAgent.IFC.value(origin, "provider_context") || %{}
      SalixAgent.IFC.text(SalixAgent.IFC.value(provider_context, "chat_id"))
    else
      ""
    end
  end

  defp qq_chat(args, ctx) do
    chat_id =
      case arg(args, "chat_id") do
        "" -> trusted_qq_chat_id(ctx)
        chat_id -> chat_id
      end

    %{
      "kind" => "provider_scope",
      "provider" => "qq",
      "connect_id" => connect_id(args, ctx),
      "scope_id" => chat_id,
      "thread_id" => ""
    }
  end

  defp trusted_qq_chat_id(ctx) do
    origin = Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin") || %{}

    if SalixAgent.IFC.text(SalixAgent.IFC.value(origin, "provider")) == "qq" do
      provider_context = SalixAgent.IFC.value(origin, "provider_context") || %{}
      SalixAgent.IFC.text(SalixAgent.IFC.value(provider_context, "chat_id"))
    else
      ""
    end
  end

  defp lark_chat(args, ctx) do
    chat_id =
      case arg(args, "chat_id") do
        "" -> trusted_lark_chat_id(ctx)
        chat_id -> chat_id
      end

    %{
      "kind" => "provider_scope",
      "provider" => "lark",
      "connect_id" => connect_id(args, ctx),
      "scope_id" => chat_id,
      "thread_id" => ""
    }
  end

  defp lark_message(api, args, ctx) do
    %{
      "kind" => "provider_message",
      "api" => api,
      "provider" => "lark",
      "connect_id" => connect_id(args, ctx),
      "message_id" => arg(args, "message_id"),
      "scope_id" => arg(args, "chat_id"),
      "thread_id" => ""
    }
  end

  defp trusted_lark_chat_id(ctx) do
    origin = Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin") || %{}

    if SalixAgent.IFC.text(SalixAgent.IFC.value(origin, "provider")) == "lark" do
      provider_context = SalixAgent.IFC.value(origin, "provider_context") || %{}
      SalixAgent.IFC.text(SalixAgent.IFC.value(provider_context, "chat_id"))
    else
      ""
    end
  end

  defp provider_direct(api, key, args, ctx) do
    %{
      "kind" => "provider_direct",
      "provider" => provider_of(api),
      "connect_id" => connect_id(args, ctx),
      "user_id" => arg(args, key)
    }
  end

  # `receive_id_type` defaults to `chat_id`, matching the adapter's own default.
  defp feishu_receive(api, args, ctx) do
    receive_id = arg(args, "receive_id")

    if arg(args, "receive_id_type") in @feishu_direct_id_types do
      %{
        "kind" => "provider_direct",
        "provider" => "feishu",
        "connect_id" => connect_id(args, ctx),
        "user_id" => receive_id
      }
    else
      %{
        "kind" => "provider_scope",
        "provider" => "feishu",
        "connect_id" => connect_id(args, ctx),
        "scope_id" => receive_id,
        "thread_id" => arg(args, "thread_id")
      }
    end
    |> Map.put("api", api)
  end

  defp feishu_message(api, args, ctx) do
    %{
      "kind" => "provider_message",
      "api" => api,
      "provider" => "feishu",
      "connect_id" => connect_id(args, ctx),
      "message_id" => arg(args, "message_id"),
      # Only `reply_text` and `post_task_card` take one, and only as a hint;
      # when it is absent the resolver asks the provider which chat the
      # message is in.
      "scope_id" => arg(args, "chat_id"),
      "thread_id" => arg(args, "thread_id")
    }
  end

  defp feishu_document(api, document, document_type, args, ctx) do
    %{
      "kind" => "provider_document",
      "api" => api,
      "provider" => "feishu",
      "connect_id" => connect_id(args, ctx),
      "document" => document,
      "document_type" => document_type
    }
  end

  # Without a parent the document lives in the app's own space with its link
  # closed, readable by nobody until it is shared; the share target is an
  # additional destination. A parent folder or wiki node lends the document
  # its own audience.
  defp feishu_create_doc(args, ctx) do
    parent = arg(args, "parent")

    cond do
      parent == "" ->
        {:persist, %{"kind" => "agent_private"}}

      String.contains?(parent, "/drive/folder/") ->
        {:egress, feishu_document("feishu.create_doc", parent, "folder", args, ctx)}

      String.contains?(parent, "/wiki/") ->
        {:egress, feishu_document("feishu.create_doc", parent, "wiki", args, ctx)}

      true ->
        {:egress,
         feishu_document("feishu.create_doc", parent, arg(args, "parent_type"), args, ctx)}
    end
  end

  # A document shared with a chat or a person becomes readable there, exactly
  # as a message sent there would be. A department is wider than any one
  # conversation, so it is the space.
  defp feishu_member("chat", chat_id, args, ctx),
    do: %{
      "kind" => "provider_scope",
      "provider" => "feishu",
      "connect_id" => connect_id(args, ctx),
      "scope_id" => chat_id,
      "thread_id" => ""
    }

  defp feishu_member("user", user_id, args, ctx),
    do: %{
      "kind" => "provider_direct",
      "provider" => "feishu",
      "connect_id" => connect_id(args, ctx),
      "user_id" => user_id
    }

  defp feishu_member(_department, _id, args, ctx), do: feishu_space(args, ctx)

  defp feishu_space(args, ctx),
    do: %{
      "kind" => "provider_space",
      "provider" => "feishu",
      "connect_id" => connect_id(args, ctx)
    }

  defp lark_document(api, document, document_type, args, ctx) do
    %{
      "kind" => "provider_document",
      "api" => api,
      "provider" => "lark",
      "connect_id" => connect_id(args, ctx),
      "document" => document,
      "document_type" => document_type
    }
  end

  # Without a parent the document is in the app's own space with its link
  # closed, and nobody reads it until it is shared; the share target is an
  # additional destination. A parent folder or wiki node lends the document
  # its own audience.
  defp lark_create_doc(args, ctx) do
    parent = arg(args, "parent")

    cond do
      parent == "" ->
        {:persist, %{"kind" => "agent_private"}}

      String.contains?(parent, "/drive/folder/") ->
        {:egress, lark_document("lark.create_doc", parent, "folder", args, ctx)}

      String.contains?(parent, "/wiki/") ->
        {:egress, lark_document("lark.create_doc", parent, "wiki", args, ctx)}

      true ->
        {:egress, lark_document("lark.create_doc", parent, arg(args, "parent_type"), args, ctx)}
    end
  end

  # A document shared with a chat or a person becomes readable there, as a
  # message sent there would be. A department is wider than any one
  # conversation, so it is the space.
  defp lark_member("chat", chat_id, args, ctx),
    do: %{
      "kind" => "provider_scope",
      "provider" => "lark",
      "connect_id" => connect_id(args, ctx),
      "scope_id" => chat_id,
      "thread_id" => ""
    }

  defp lark_member("user", user_id, args, ctx),
    do: %{
      "kind" => "provider_direct",
      "provider" => "lark",
      "connect_id" => connect_id(args, ctx),
      "user_id" => user_id
    }

  defp lark_member(_department, _id, args, ctx), do: lark_space(args, ctx)

  defp lark_space(args, ctx),
    do: %{
      "kind" => "provider_space",
      "provider" => "lark",
      "connect_id" => connect_id(args, ctx)
    }

  defp provider_of(api), do: api |> String.split(".", parts: 2) |> List.first()

  # A Task's audience is decided when it is created: its origin principal,
  # plus anyone the Router explicitly shares it with. The conversation does
  # not exist yet, so the descriptor names the activation instead and the
  # resolver supplies the membership.
  defp pending_task(ctx) do
    %{
      "kind" => "pending_task",
      "tool_call_id" => Map.get(ctx, :tool_call_id) || Map.get(ctx, "tool_call_id")
    }
  end

  # ---------------------------------------------------------------------------
  # Canonical tools
  # ---------------------------------------------------------------------------

  # Group memory is readable by the whole Group, so a note taken from a DM
  # cannot legally live there. `/memory/scoped/<name>.md` is the per-audience
  # home (§8): its audience is the join of whatever the write itself drew on,
  # so nothing leaves the audience it came from. `SalixAgent.IFC.Check` fills
  # that label in, because only it can see the declaration.
  # Worker names and purposes are durable configuration visible to the Group,
  # not a public post or a private note. AgentManagement still validates the
  # caller and target Group; model-supplied audience fields confer no authority.
  defp tool("agent.update", _args, ctx),
    do: {:persist, %{"kind" => "agent_configuration", "group_id" => group_id(ctx)}}

  defp tool("memory.write", args, ctx) do
    path = arg(args, "path")
    kind = if SalixAgent.Tools.Memory.scoped_path?(path), do: "memory_scoped", else: "memory"
    {:persist, %{"kind" => kind, "path" => path, "group_id" => group_id(ctx)}}
  end

  defp tool("memory.append", args, ctx), do: tool("memory.write", args, ctx)

  # An import copies the user's export into Group memory and the Group's
  # skills, so it takes the Group memory check. Recording outcomes and the
  # report touch only the Agent's own /imports folder. Appended instructions
  # are Agent configuration, like a Worker's name and purpose.
  defp tool("migration.import", _args, ctx),
    do: {:persist, %{"kind" => "memory", "group_id" => group_id(ctx)}}

  defp tool(name, _args, _ctx) when name in ~w(migration.resolve migration.finish),
    do: {:persist, %{"kind" => "agent_private"}}

  defp tool("migration.append_instructions", _args, ctx),
    do: {:persist, %{"kind" => "agent_configuration", "group_id" => group_id(ctx)}}

  # Every Session of the Group reads the Condensed Workspace, the audience of
  # Group memory, so a write takes the same check.
  defp tool("condensed_workspace.update", _args, ctx),
    do: {:persist, %{"kind" => "memory", "group_id" => group_id(ctx)}}

  defp tool("meeting.read_summary_materials", _args, _ctx), do: {:read, %{}}

  defp tool("meeting.submit_summary", args, ctx) do
    case SalixAgent.MeetingSummaryScope.origin(ctx, args) do
      # A Meeting from a Comma chat publishes its notes into that Conversation.
      %{"provider" => "comma", "provider_context" => context} ->
        {:egress, %{"kind" => "conversation", "conversation_id" => context["conversation_id"]}}

      %{"provider" => provider, "provider_context" => context} ->
        {:egress,
         %{
           "kind" => "provider_scope",
           "provider" => provider,
           "connect_id" => context["connect_id"],
           "scope_id" => context["channel_id"] || context["chat_id"],
           "thread_id" => context["thread_ts"]
         }}

      _ ->
        {:egress, %{"kind" => "public"}}
    end
  end

  defp tool("meeting.preparation.publish_personal_report", args, ctx),
    do: {:egress, provider_direct("slack.send_dm", "user_id", args, ctx)}

  defp tool("meeting.preparation.read_shared_source", _args, _ctx), do: {:read, %{}}
  defp tool("meeting.preparation.read_recipient", _args, _ctx), do: {:read, %{}}
  defp tool("meeting.preparation.read_status", _args, _ctx), do: {:read, %{}}

  defp tool(name, _args, _ctx) when name in ~w(history.list history.search history.get),
    do: {:read, %{}}

  defp tool("tool_call.get_result", _args, _ctx), do: {:read, %{}}
  defp tool("tool_call.get_status", _args, _ctx), do: {:read, %{}}

  defp tool("schedule.create", args, ctx) do
    # A schedule is checked twice: once here, against the destination its
    # creator declared, and again at every fire with current membership.
    {:persist,
     %{
       "kind" => "schedule",
       "group_id" => group_id(ctx),
       "conversation_id" => arg(args, "conversation_id")
     }}
  end

  defp tool("schedule.update", args, ctx), do: tool("schedule.create", args, ctx)

  # Background Loops (`SalixAgent.Tools.Loops`) never leave the Agent. `loop.sdk`,
  # `loop.list` and `loop.get` read the binary's header and the Agent's own
  # rows. `loop.build` writes the compiled object into the workspace at `path`,
  # so it is the same write `fs.write_file` would be there: private, unless the
  # path is on the Drive. `loop.create` stores the program's config and grants
  # and `loop.send` queues an event, both where only that Agent's Loop reads
  # them (§7: the Loop's own reads keep Group-level authorization and carry
  # the sealed origin). Pause, resume, delete, and webhook management carry no content.
  defp tool(name, _args, _ctx) when name in ~w(loop.sdk loop.list loop.get), do: {:read, %{}}

  defp tool("loop.build", args, ctx) do
    path = arg(args, "path")

    if is_binary(path) and SalixAgent.DriveMount.matches?(path),
      do: {:persist, %{"kind" => "drive", "path" => path, "group_id" => group_id(ctx)}},
      else: {:persist, %{"kind" => "agent_private"}}
  end

  defp tool(name, _args, _ctx) when name in ~w(loop.create loop.send),
    do: {:persist, %{"kind" => "agent_private"}}

  defp tool(name, _args, _ctx) when name in ~w(loop.pause loop.resume loop.delete loop.webhook),
    do: {:none, %{}}

  # A filesystem write is private unless it lands on the user's Drive
  # (`SalixAgent.DriveMount`, `/drive/...`): that mount is the Workspace's
  # shared folder, synced to every member's devices, so a write there has the
  # Group's humans as its audience, the way Group memory does (§8). The path
  # decides, so the args are read here rather than discarded.
  defp tool("fs." <> _ = name, args, ctx) do
    case drive_destination(name, args) do
      nil -> canonical(name)
      path -> {:persist, %{"kind" => "drive", "path" => path, "group_id" => group_id(ctx)}}
    end
  end

  # Stations (`SalixAgent.Stations`) are member machines enrolled in the
  # Workspace. Listing them and reading their files, process output or chat
  # status brings content in and is labelled like any other read. Anything
  # that hands content to a station leaves Salix: a command, process input,
  # a started process, or a task message to a station chat that the
  # Workspace's members and the station's own agent see. Until a station
  # audience can be resolved, those are the restrictive public egress that
  # `env.exec` already is for every target. Stopping a process carries no content.
  defp tool(name, _args, _ctx) when name in ~w(station.list station.fs), do: {:read, %{}}

  # Starting the Group's Cloud VM carries no content anywhere.
  defp tool("cloud_vm.start", _args, _ctx), do: {:none, %{}}

  defp tool("station.process", args, _ctx) do
    if arg(args, "action") == "stop",
      do: {:none, %{}},
      else: {:egress, %{"kind" => "public"}}
  end

  defp tool("station.session", args, _ctx) do
    if arg(args, "action") == "status",
      do: {:read, %{}},
      else: {:egress, %{"kind" => "public"}}
  end

  defp tool(name, args, _ctx) when name in ~w(env.process_list env.process_tail) do
    if station_target?(args), do: {:read, %{}}, else: canonical(name)
  end

  defp tool("env.exec", args, _ctx) do
    if station_target?(args), do: {:egress, %{"kind" => "public"}}, else: canonical("env.exec")
  end

  # A gateway request hands its URL, headers and body to a device on the
  # user's local network, whose audience Salix cannot resolve. Like `env.exec`,
  # it is the restrictive public egress.
  defp tool("device.lan_request", _args, _ctx), do: {:egress, %{"kind" => "public"}}

  # A miIO command goes to a device on the user's local network, like
  # device.lan_request.
  defp tool("device.miio_request", _args, _ctx), do: {:egress, %{"kind" => "public"}}

  # A Gree request goes to a device on the user's local network as well.
  defp tool("device.gree_request", _args, _ctx), do: {:egress, %{"kind" => "public"}}

  # A saved device secret is Group configuration: every Agent of the Group
  # can use it and list its name, host and model. Its value never comes back.
  defp tool("device.secret_save", _args, ctx),
    do: {:persist, %{"kind" => "device_secret", "group_id" => group_id(ctx)}}

  defp tool("device.secret_list", _args, _ctx), do: {:read, %{}}
  defp tool("device.secret_delete", _args, _ctx), do: {:none, %{}}

  # Tailnet settings are Group configuration like a device secret; status and
  # peers bring tailnet names in. Tailnet connections themselves are ssh.* and
  # web.* egress.
  defp tool("tailnet.connect", _args, ctx),
    do: {:persist, %{"kind" => "tailnet_settings", "group_id" => group_id(ctx)}}

  defp tool(name, _args, _ctx) when name in ~w(tailnet.status tailnet.peers), do: {:read, %{}}
  defp tool("tailnet.disconnect", _args, _ctx), do: {:none, %{}}

  # Discovery sends only its sources, its timeout and the platform's fixed
  # protocol probes; it brings LAN names in.
  defp tool("device.lan_discover", _args, _ctx), do: {:read, %{}}

  # Creation stores a private artifact. The later explicit Message send
  # resolves the actual audience and checks the artifact's source label.
  defp tool("ui.create", _args, _ctx), do: {:persist, %{"kind" => "agent_private"}}

  defp tool(name, _args, _ctx), do: canonical(name)

  # The visible filesystem is a closed set of operations, and every one of them
  # is either a read of it or a write into it. Naming them exhaustively matters
  # because the fallthrough is `:egress` to `{public}`: `fs.grep` reading a
  # file would otherwise be decided as *publishing* it, and `fs.edit_file`
  # would be a public post rather than a private write. Anything new under
  # `fs.` lands on the restrictive side until it is classified.
  @fs_reads ~w(fs.read_file fs.list_files fs.grep fs.glob fs.stat_file)

  # The path a filesystem write lands on when that path is on the Drive. A
  # copy or move lands on `to`; a delete carries no content and lands nowhere;
  # a read lands nowhere. Any other `fs.` operation writes its `path`.
  defp drive_destination(name, args) do
    written =
      cond do
        name in @fs_reads or String.starts_with?(name, "fs.read") or
            String.starts_with?(name, "fs.list") ->
          nil

        name == "fs.delete_file" ->
          nil

        name in ~w(fs.copy_file fs.move_file) ->
          arg(args, "to")

        true ->
          arg(args, "path")
      end

    if is_binary(written) and SalixAgent.DriveMount.matches?(written), do: written, else: nil
  end

  defp canonical(name) do
    cond do
      name in ~w(help wait_for end_turn agent.list im.connects_list im.provider_apis_list) ->
        {:none, %{}}

      name in @fs_reads or String.starts_with?(name, "fs.read") or
          String.starts_with?(name, "fs.list") ->
        {:read, %{}}

      String.starts_with?(name, "fs.") ->
        {:persist, %{"kind" => "agent_private"}}

      name in ~w(memory.get memory.search memory.ask_worker) ->
        {:read, %{}}

      String.starts_with?(name, "web.") ->
        {:egress, %{"kind" => "public"}}

      String.starts_with?(name, "preview.") ->
        {:egress, %{"kind" => "public"}}

      name in ~w(env.exec script.run script.run_file decide) ->
        {:egress, %{"kind" => "public"}}

      # Every ssh.* tool talks to, or configures trust in, a remote host.
      String.starts_with?(name, "ssh.") ->
        {:egress, %{"kind" => "public"}}

      # Discovery reads the group's stored binding projection; it does not call
      # the remote server. Returned metadata keeps its connector audience label.
      name == "mcp.list" ->
        {:read, %{}}

      String.starts_with?(name, "mcp.") or String.starts_with?(name, "composio.") ->
        {:egress, %{"kind" => "public"}}

      String.starts_with?(name, "recommendations.") or String.starts_with?(name, "plugin.") ->
        {:none, %{}}

      String.starts_with?(name, "skill.") or String.starts_with?(name, "oauth.") ->
        {:none, %{}}

      String.starts_with?(name, "runtime.") or String.starts_with?(name, "location.") ->
        {:none, %{}}

      # The saved report or fallback baseline later leaves through Calendar and
      # the Slack receiver.
      # Until both audiences can be resolved together, use the restrictive
      # public-egress decision rather than the contentless meeting default.
      name in ~w(meeting.preparation.publish_report meeting.preparation.record_decision) ->
        {:egress, %{"kind" => "public"}}

      String.starts_with?(name, "peers.") or String.starts_with?(name, "meeting.") ->
        {:none, %{}}

      String.starts_with?(name, "calendar.") ->
        {:none, %{}}

      true ->
        {:egress, %{"kind" => "public"}}
    end
  end

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp connect_id(args, ctx) do
    case arg(args, "connect_id") do
      "" -> trusted_connect_id(ctx)
      connect_id -> connect_id
    end
  end

  defp trusted_connect_id(ctx) do
    origin = Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin") || %{}
    provider_context = SalixAgent.IFC.value(origin, "provider_context") || %{}
    SalixAgent.IFC.text(SalixAgent.IFC.value(provider_context, "connect_id"))
  end

  defp station_target?(args), do: SalixAgent.Stations.station_id(arg(args, "device_id")) != nil

  defp group_id(ctx),
    do: SalixAgent.IFC.text(Map.get(ctx, :group_id) || Map.get(ctx, "group_id"))

  defp arg(args, key) when is_map(args) do
    args
    |> Map.get(key, Map.get(args, safe_atom(key)))
    |> SalixAgent.IFC.text()
  end

  defp arg(_args, _key), do: ""

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
