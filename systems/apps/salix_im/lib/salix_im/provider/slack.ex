defmodule SalixIM.Provider.Slack do
  @moduledoc false

  require Logger

  alias SalixIM.{
    Diagnostics,
    MessageRenderer,
    ProviderConnects,
    SlackRouterStatus,
    SlackTaskCard
  }

  alias SalixIM.MessageRenderer.{Input, Surface}
  alias SalixIM.Provider.Slack.{API, ConversationIngress, MessageRead}
  alias SalixIM.Provider.Slack.MessageRenderer, as: SlackMessageRenderer
  alias SalixStore.SlackRouterThreadParticipations

  import SalixIM.Provider.Util

  @triage_effect_request_timeout_ms 4_000
  @ambiguous_write_app_errors ~w(
    internal_error
    fatal_error
    timeout
    request_timeout
    service_unavailable
    temporarily_unavailable
  )
  @simple_calls %{
    "slack.join_channel" => {"conversations.join", [{"channel", "channel"}]},
    "slack.delete_message" => {"chat.delete", [{"channel", "channel"}, {"ts", "ts"}]},
    "slack.add_reaction" =>
      {"reactions.add", [{"channel", "channel"}, {"timestamp", "ts"}, {"name", :reaction}]},
    "slack.pin_message" => {"pins.add", [{"channel", "channel"}, {"timestamp", "ts"}]},
    "slack.unpin_message" => {"pins.remove", [{"channel", "channel"}, {"timestamp", "ts"}]},
    "slack.set_channel_topic" =>
      {"conversations.setTopic", [{"channel", "channel"}, {"topic", "topic"}]},
    "slack.set_channel_purpose" =>
      {"conversations.setPurpose", [{"channel", "channel"}, {"purpose", "purpose"}]},
    "slack.invite_users" => {"conversations.invite", [{"channel", "channel"}, {"users", :users}]},
    "slack.add_bookmark" =>
      {"bookmarks.add",
       [
         {"channel_id", "channel"},
         {"title", "title"},
         {"type", {:constant, "link"}},
         {"link", "url"}
       ]},
    "slack.list_emoji" => {"emoji.list", []}
  }

  # ---- Slack dispatch (willow callSlackProviderAPI) ----

  def call(tenant, connect, api, params), do: call(nil, tenant, connect, api, params)

  @doc false
  def call(agent_id, tenant, connect, "slack.add_reaction", params, opts)
      when is_list(opts),
      do: add_reaction(agent_id, tenant, connect, params, Keyword.get(opts, :request_options, []))

  def call(agent_id, tenant, connect, api, params, _opts),
    do: call(agent_id, tenant, connect, api, params)

  @doc false
  def post_triage_reply(tenant, connect, params) do
    params = Map.update(params, "text", "", &normalize_slack_text/1)

    result =
      write_slack_message(tenant, connect, :post, params,
        block_policy: :tool_noninteractive,
        request_options: [timeout_ms: @triage_effect_request_timeout_ms, pool_retries: 0]
      )

    emit_slack_outbound_diagnostic(connect, "slack.post_message", params, result)
    result
  end

  def set_assistant_thread_status(tenant, connect, channel_id, thread_ts, status) do
    channel_id = str(channel_id)
    thread_ts = str(thread_ts)
    status = str(status)

    if channel_id == "" or thread_ts == "" do
      {:error, "channel_id and thread_ts are required"}
    else
      with {:ok, token} <- slack_token(tenant, connect) do
        {:ok,
         token
         |> API.set_assistant_status(channel_id, thread_ts, status)
         |> Map.take(["ok"])}
      end
    end
  rescue
    error in API.Error ->
      {:error,
       %{
         code: assistant_status_error_code(error),
         message: API.provider_error_message(error),
         validation: assistant_status_validation(error),
         retry_after_ms:
           if(is_integer(error.retry_after), do: error.retry_after * 1_000, else: nil)
       }}
  end

  # Keep only schema diagnostics. Provider responses can echo private status text.
  defp assistant_status_validation(%API.Error{body: body}) when is_map(body) do
    metadata = body["response_metadata"]
    messages = if is_map(metadata), do: metadata["messages"], else: nil

    [body["detail"] | List.wrap(messages)]
    |> Enum.take(5)
    |> Enum.filter(fn
      message when is_binary(message) and byte_size(message) <= 256 ->
        Regex.match?(
          ~r/\A\[ERROR\] must be less than [0-9]{1,6} characters \[json-pointer:\/(?:status|loading_messages(?:\/[0-9]{1,2})?)\]\z/,
          message
        )

      _ ->
        false
    end)
  end

  defp assistant_status_validation(_error), do: []

  defp assistant_status_error_code(%API.Error{body: %{"error" => code}})
       when is_binary(code),
       do: code

  defp assistant_status_error_code(%API.Error{message: code}) when is_binary(code), do: code

  @doc false
  def task_card(tenant, connect, rec, mode) when is_map(rec) and mode in [:deliver, :verify] do
    case SlackTaskCard.project(rec) do
      {:ok, :noop, _, nil} ->
        {:ok, :task_card_projection_current}

      {:ok, action, desired, rendered}
      when mode == :deliver and action in [:post, :update] ->
        write_task_card(tenant, connect, rec, action, desired, rendered)

      {:ok, _action, desired, _rendered} when mode == :verify ->
        verify_task_card_write(tenant, connect, rec, desired)

      {:error, reason} ->
        if mode == :verify, do: {:unknown, reason}, else: {:error, reason}
    end
  end

  defp write_task_card(tenant, connect, rec, action, desired, rendered) do
    payload = rec["participant_payload"]
    channel = payload["channel_id"]
    expected_ts = if action == :post, do: nil, else: desired["message_ts"]

    params = %{
      "channel" => channel,
      "thread_ts" => payload["thread_ts"],
      "ts" => expected_ts,
      "text" => rendered["text"],
      "blocks" => rendered["blocks"],
      "render_mode" => "blocks",
      "metadata" => SlackTaskCard.metadata(rec, desired)
    }

    case write_slack_message(tenant, connect, action, params,
           block_policy: :trusted_product,
           ambiguous_write?: true,
           request_options: task_card_request_options()
         ) do
      {:error, reason} = error when action == :update ->
        if task_card_message_missing?(reason),
          do: write_task_card(tenant, connect, rec, :post, desired, rendered),
          else: error

      {:ok, response} ->
        SlackTaskCard.written(desired, expected_ts, channel, response)

      error ->
        error
    end
  end

  defp verify_task_card_write(_tenant, _connect, rec, _desired) do
    stored = rec["participant_payload"]

    if stored["message_ts"] == "",
      do: {:unknown, {:retry_after, 60_000, :awaiting_task_card_metadata}},
      else: {:missing, :retry_known_task_card_update}
  end

  defp task_card_request_options do
    timeout =
      Application.get_env(:salix_im, :slack_task_card_request_timeout_ms, 5_000)
      |> max(10)
      |> min(5_000)

    [timeout_ms: timeout, pool_retries: 0]
  end

  defp task_card_message_missing?(reason),
    do: reason |> inspect() |> String.contains?("message_not_found")

  @doc false
  def post_product_surface(tenant, connect, params, %Surface{} = surface, opts \\ [])
      when is_map(params) do
    with {:ok, rendered} <- MessageRenderer.render_surface(SlackMessageRenderer, surface) do
      params =
        params
        |> Map.put("text", rendered.text)
        |> Map.put("blocks", rendered.blocks)
        |> Map.put("render_mode", "blocks")

      block_policy = Keyword.get(opts, :block_policy, :trusted_product)
      write_slack_message(tenant, connect, :post, params, block_policy: block_policy)
    end
  end

  defp write_slack_message(tenant, connect, action, params, opts)
       when action in [:post, :update] do
    channel = str(params["channel"])
    message_ts = str(params["ts"])
    text = str(params["text"])
    block_policy = Keyword.fetch!(opts, :block_policy)
    request_opts = Keyword.delete(opts, :block_policy)

    with true <-
           channel != "" and text != "" and (action == :post or message_ts != ""),
         {:ok, rendered} <-
           render_slack_message(
             text,
             params["render_mode"],
             params["blocks"],
             block_policy
           ),
         {:ok, token} <- slack_token(tenant, connect),
         method = if(action == :post, do: "chat.postMessage", else: "chat.update"),
         body = %{
           "channel" => channel,
           "thread_ts" => if(action == :post, do: presence(str(params["thread_ts"]))),
           "ts" => if(action == :update, do: message_ts),
           "text" => rendered.text,
           "blocks" => rendered.blocks,
           "metadata" => slack_metadata(params["metadata"]),
           "unfurl_links" => optional_boolean(params["unfurl_links"]),
           "unfurl_media" => optional_boolean(params["unfurl_media"])
         },
         {:ok, response} <-
           slack_request(
             token,
             method,
             body,
             Keyword.put_new(
               request_opts,
               :ambiguous_write?,
               durable_delivery_metadata?(params["metadata"])
             )
           ) do
      {:ok, Map.take(response, ["channel", "ts"])}
    else
      false ->
        required = if action == :post, do: "channel and text", else: "channel, ts, and text"
        {:error, required <> " are required"}

      other ->
        other
    end
  end

  @doc """
  Post one runtime-owned interactive message into a person's own direct
  conversation with the bot.

  Not reachable from any model: it is not in the provider operation table, it
  takes rendered blocks rather than model text, and the destination is a user
  id the runtime resolved. `SalixIM.IFC.SlackConfirmation` is its only caller
  — a declassification is a question the runtime asks a person, so it has to
  arrive somewhere only that person can see and act on.
  """
  @spec post_direct_surface(term(), map(), String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def post_direct_surface(tenant, connect, user_id, text, blocks)
      when is_binary(user_id) and is_binary(text) and is_list(blocks) do
    with {:ok, token} <- slack_token(tenant, connect),
         {:ok, conversation} <-
           slack_request(token, "conversations.open", %{"users" => str(user_id)}),
         {:ok, channel_id} <- dm_channel_id(conversation) do
      write_slack_message(
        tenant,
        connect,
        :post,
        %{"channel" => channel_id, "text" => text, "blocks" => blocks, "render_mode" => "blocks"},
        block_policy: :trusted_product
      )
    end
  end

  @doc """
  Replace a runtime-owned interactive message with its settled form, so a
  decision cannot be taken twice from a card left sitting in a conversation.
  """
  @spec update_surface(term(), map(), String.t(), String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def update_surface(tenant, connect, channel, ts, text, blocks)
      when is_binary(channel) and is_binary(ts) and is_binary(text) and is_list(blocks) do
    write_slack_message(
      tenant,
      connect,
      :update,
      %{
        "channel" => channel,
        "ts" => ts,
        "text" => text,
        "blocks" => blocks,
        "render_mode" => "blocks"
      },
      block_policy: :trusted_product
    )
  end

  @doc false
  def apply_checkbox_action(tenant, connect, payload) when is_map(payload) do
    with {:ok, action} <- checkbox_action(payload),
         {:ok, message} <- checkbox_message(payload),
         :ok <- verify_checkbox_action_address(action, message),
         {:ok, selected_values} <- checkbox_selected_values(action),
         {:ok, blocks} <-
           SlackMessageRenderer.apply_checkbox_selection(
             message.blocks,
             action["action_id"],
             selected_values
           ),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, _response} <-
           slack_request(token, "chat.update", %{
             "channel" => message.channel,
             "ts" => message.ts,
             "text" => message.text,
             "blocks" => blocks
           }) do
      {:ok, :accepted}
    end
  end

  def apply_checkbox_action(_tenant, _connect, _payload),
    do: {:error, {:ignored, :invalid_interaction_payload}}

  def call(%{agent_id: agent_id} = scope, tenant, connect, api, params) do
    API.with_tool_rate_limit_retry(fn ->
      case api do
        "slack.post_task_card" ->
          SlackTaskCard.post(scope, connect, params)

        "slack.bind_thread_to_task" ->
          ConversationIngress.bind_thread_to_task(scope, connect, params)

        _other ->
          call(agent_id, tenant, connect, api, params)
      end
    end)
  end

  def call(agent_id, tenant, connect, api, params)
      when api in ["slack.post_map_card", "slack.post_stock_card", "slack.post_weather_card"] do
    channel = str(params["channel"])

    card_type =
      api |> String.replace_prefix("slack.post_", "") |> String.replace_suffix("_card", "")

    result =
      if channel == "" do
        {:error, "channel is required"}
      else
        surface = rich_card_surface(card_type, channel, params)

        params =
          params
          |> Map.put("unfurl_links", false)
          |> Map.put("unfurl_media", false)

        post_product_surface(tenant, connect, params, surface,
          block_policy: :product_noninteractive
        )
      end

    notify_thread_reply(agent_id, connect, channel, params["thread_ts"], result)
    emit_slack_outbound_diagnostic(connect, api, params, result)
    result
  end

  def call(agent_id, tenant, connect, "slack.reply_message", params) do
    if is_binary(params["thread_ts"]) and String.trim(params["thread_ts"]) != "" do
      call(agent_id, tenant, connect, "slack.post_message", params)
    else
      {:error,
       "slack.reply_message requires the original source thread_ts; never fall back to a channel post"}
    end
  end

  def call(agent_id, tenant, connect, "slack.post_channel_message", params) do
    if Map.has_key?(params, "thread_ts") do
      {:error, "slack.post_channel_message does not accept thread_ts; use slack.reply_message"}
    else
      call(agent_id, tenant, connect, "slack.post_message", params)
    end
  end

  # Product-owned transports and historical records retain this internal entrypoint.
  # It is not in the agent operation registry.
  def call(agent_id, tenant, connect, "slack.post_message", params) do
    channel = str(params["channel"])
    params = Map.put(params, "text", normalize_slack_text(params["text"]))

    result =
      write_slack_message(tenant, connect, :post, params, block_policy: :tool_noninteractive)

    notify_thread_reply(agent_id, connect, channel, params["thread_ts"], result)
    emit_slack_outbound_diagnostic(connect, "slack.post_message", params, result)
    result
  end

  def call(_agent_id, tenant, connect, "slack.send_dm", params) do
    text = normalize_slack_text(params["text"])
    user_id = str(params["user_id"])

    result =
      if user_id == "" or String.trim(text) == "" do
        {:error, "user_id and text are required"}
      else
        with {:ok, rendered} <-
               render_slack_message(
                 text,
                 params["render_mode"],
                 params["blocks"],
                 :tool_noninteractive
               ),
             {:ok, token} <- slack_token(tenant, connect),
             {:ok, conversation} <-
               slack_request(token, "conversations.open", %{"users" => user_id}),
             {:ok, channel_id} <- dm_channel_id(conversation),
             {:ok, resp} <-
               slack_request(token, "chat.postMessage", %{
                 "channel" => channel_id,
                 "text" => rendered.text,
                 "blocks" => rendered.blocks
               }) do
          {:ok, %{"channel" => resp["channel"], "ts" => resp["ts"]}}
        end
      end

    emit_slack_outbound_diagnostic(connect, "slack.send_dm", params, result)
    result
  end

  def call(_agent_id, tenant, connect, "slack.list_channels", params) do
    limit = slack_page_limit(params["limit"])

    exclude_archived =
      case params["exclude_archived"] do
        b when is_boolean(b) -> b
        _ -> true
      end

    types =
      case str(params["types"]) do
        "" -> ["public_channel", "private_channel"]
        s -> s |> String.split(",") |> Enum.map(&String.trim/1)
      end

    with {:ok, token} <- slack_token(tenant, connect),
         {:ok, resp} <-
           slack_request(token, "conversations.list", %{
             "limit" => limit,
             "cursor" => presence(str(params["cursor"])),
             "types" => Enum.join(types, ","),
             "exclude_archived" => exclude_archived
           }) do
      entries =
        resp
        |> Map.get("channels", [])
        |> Enum.map(fn ch ->
          %{"id" => ch["id"], "name" => ch["name"]}
          |> then(fn e -> if ch["is_private"], do: Map.put(e, "is_private", true), else: e end)
          |> then(fn e -> if ch["is_archived"], do: Map.put(e, "is_archived", true), else: e end)
        end)

      {:ok,
       %{"channels" => entries}
       |> put_present("next_cursor", slack_next_cursor(resp))}
    end
  end

  def call(_agent_id, tenant, connect, "slack.list_users", params) do
    limit = slack_page_limit(params["limit"])
    include_deleted = bool_or(params["include_deleted"], false)
    query = str(params["query"])

    with {:ok, token} <- slack_token(tenant, connect),
         {:ok, resp} <-
           slack_request(token, "users.list", %{
             "limit" => limit,
             "cursor" => presence(str(params["cursor"]))
           }) do
      users =
        resp
        |> Map.get("members", [])
        |> Enum.reject(fn user -> !include_deleted and user["deleted"] == true end)
        |> Enum.map(&slack_user_list_entry/1)
        |> Enum.filter(&slack_user_matches_query?(&1, query))

      result =
        %{"users" => users}
        |> put_present("next_cursor", slack_next_cursor(resp))

      {:ok, result}
    end
  end

  def call(_agent_id, tenant, connect, "slack.get_user_info", params) do
    user_id = str(params["user_id"])

    if user_id == "" do
      {:error, "user_id is required"}
    else
      with {:ok, token} <- slack_token(tenant, connect),
           {:ok, user} <- slack_request(token, "users.info", %{"user" => user_id}) do
        {:ok, slack_user_summary(user)}
      end
    end
  end

  def call(_agent_id, tenant, connect, "slack.update_message", params) do
    params = Map.update(params, "text", "", &normalize_slack_text/1)

    write_slack_message(tenant, connect, :update, params, block_policy: :tool_noninteractive)
  end

  def call(_agent_id, tenant, connect, "slack.add_reaction", params) do
    add_reaction(nil, tenant, connect, params, [])
  end

  def call(_agent_id, tenant, connect, "slack.create_channel", params) do
    with {:ok, name} <- slack_channel_name(params["name"]),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, channel} <-
           slack_request(token, "conversations.create", %{
             "name" => name,
             "is_private" => bool_or(params["is_private"], false)
           }) do
      {:ok, channel}
    end
  end

  def call(_agent_id, tenant, connect, "slack.invite_users", params) do
    invite_users(tenant, connect, params)
  end

  def call(_agent_id, tenant, connect, api, params) when is_map_key(@simple_calls, api) do
    {method, fields} = @simple_calls[api]

    with {:ok, body} <- simple_slack_body(fields, params),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, response} <- slack_request(token, method, body) do
      {:ok, response}
    end
  end

  def call(_agent_id, tenant, connect, "slack.list_channel_members", params) do
    with :ok <- require_params(params, ["channel"]),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, resp} <-
           slack_request(token, "conversations.members", %{
             "channel" => str(params["channel"]),
             "limit" => slack_page_limit(params["limit"]),
             "cursor" => presence(str(params["cursor"]))
           }) do
      {:ok,
       %{"members" => Map.get(resp, "members", [])}
       |> put_present("next_cursor", slack_next_cursor(resp))}
    end
  end

  def call(_agent_id, tenant, connect, "slack.get_thread_replies", params) do
    MessageRead.replies(tenant, connect, params)
  end

  def call(_agent_id, tenant, connect, "slack.get_channel_history", params) do
    MessageRead.history(tenant, connect, params)
  end

  def call(_agent_id, tenant, connect, "slack.search", params) do
    MessageRead.search(tenant, connect, params)
  end

  def call(_agent_id, _tenant, connect, "slack.semantic_search", params) do
    SalixIM.Provider.Slack.SemanticSearch.search(connect, params)
  end

  def call(agent_id, tenant, connect, "slack.fetch_file", params) do
    with :ok <- require_params(params, ["file_id"]),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, file} <-
           slack_request(token, "files.info", %{"file" => str(params["file_id"])}),
         {:ok, result} <- stage_fetched_file(agent_id, token, file) do
      {:ok, put_ifc(result, SalixIM.IFC.ReadLabels.for_scopes(connect, file_scopes(file)))}
    end
  end

  def call(agent_id, tenant, connect, "slack.upload_file", params) do
    path = str(params["path"])

    with :ok <- require_params(params, ["path"]),
         {:ok, resp} <-
           upload_files(
             agent_id,
             tenant,
             connect,
             [%{"path" => path, "title" => params["title"]}],
             params
           ) do
      {:ok, Map.delete(resp, "uploaded_files")}
    end
  end

  def call(_agent_id, tenant, connect, "slack.create_canvas", params) do
    title = str(params["title"])
    content = str(params["content"])
    channel = presence(str(params["channel"]))

    cond do
      String.trim(content) == "" ->
        {:error, "content is required"}

      channel == nil and title == "" ->
        {:error, "title is required for a standalone canvas"}

      true ->
        {method, body} =
          if channel do
            {"conversations.canvases.create",
             %{"channel_id" => channel, "document_content" => canvas_document(content)}}
          else
            {"canvases.create",
             %{"title" => title, "document_content" => canvas_document(content)}}
          end

        with {:ok, token} <- slack_token(tenant, connect),
             {:ok, resp} <- slack_request(token, method, body) do
          {:ok, %{"canvas_id" => resp["canvas_id"]}}
        end
    end
  end

  def call(_agent_id, tenant, connect, "slack.edit_canvas", params) do
    with :ok <- require_params(params, ["canvas_id"]),
         {:ok, changes} <- canvas_changes(params),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, _resp} <-
           slack_request(token, "canvases.edit", %{
             "canvas_id" => str(params["canvas_id"]),
             "changes" => changes
           }) do
      {:ok, %{"canvas_id" => str(params["canvas_id"])}}
    end
  end

  def call(_agent_id, tenant, connect, "slack.fetch_canvas", params) do
    with :ok <- require_params(params, ["canvas_id"]),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, {file, content}} <-
           slack_api_value(fn ->
             API.canvas_file_and_content(token, str(params["canvas_id"]))
           end) do
      {:ok,
       %{
         "canvas_id" => str(params["canvas_id"]),
         "content" => content,
         "content_format" => "provider_rendered_html",
         # Rolling callers may still read the old field. It aliases the same
         # provider-rendered body; content_format is the authoritative label.
         "markdown" => content
       }
       |> put_present("title", file["title"])
       |> put_ifc(SalixIM.IFC.ReadLabels.for_scopes(connect, file_scopes(file)))}
    end
  end

  def call(_agent_id, tenant, connect, "slack.delete_canvas", params) do
    with :ok <- require_params(params, ["canvas_id"]),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, _resp} <-
           slack_request(token, "canvases.delete", %{"canvas_id" => str(params["canvas_id"])}) do
      {:ok, %{"ok" => true}}
    end
  end

  def call(_agent_id, tenant, connect, "slack.set_canvas_access", params) do
    with :ok <- require_params(params, ["canvas_id", "access_level"]),
         {:ok, level} <- canvas_access_level(params["access_level"]),
         {:ok, targets} <- canvas_access_targets(params),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, _resp} <-
           slack_request(
             token,
             "canvases.access.set",
             Map.merge(
               %{"canvas_id" => str(params["canvas_id"]), "access_level" => level},
               targets
             )
           ) do
      {:ok, %{"ok" => true}}
    end
  end

  def call(_agent_id, tenant, connect, "slack.delete_canvas_access", params) do
    with :ok <- require_params(params, ["canvas_id"]),
         {:ok, targets} <- canvas_access_targets(params),
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, _resp} <-
           slack_request(
             token,
             "canvases.access.delete",
             Map.put(targets, "canvas_id", str(params["canvas_id"]))
           ) do
      {:ok, %{"ok" => true}}
    end
  end

  def call(_agent_id, _tenant, _connect, _api, _params),
    do: {:error, "unsupported Slack provider api"}

  defp add_reaction(_agent_id, tenant, connect, params, request_options) do
    {method, fields} = @simple_calls["slack.add_reaction"]

    with {:ok, body} <- simple_slack_body(fields, params),
         {:ok, token} <- slack_token(tenant, connect) do
      case slack_request(token, method, body, request_options: request_options) do
        {:error, "Slack API error: already_reacted"} ->
          {:ok, %{"already_reacted" => true}}

        result ->
          result
      end
    end
  end

  # conversations.invite rejects the whole call when any listed user cannot be
  # invited (already a member, deactivated, unknown) unless force=true, in which
  # case Slack invites the valid users and reports the rest under `errors`.
  # A single already-member invite is idempotent success; every other failure
  # carries Slack's per-user breakdown so the agent can report who was skipped.
  defp invite_users(tenant, connect, params) do
    {method, fields} = @simple_calls["slack.invite_users"]

    with {:ok, body} <- simple_slack_body(fields, params),
         {:ok, token} <- slack_token(tenant, connect) do
      body = if bool_or(params["force"], false), do: Map.put(body, "force", true), else: body
      single_user? = not String.contains?(body["users"], ",")

      case slack_request(token, method, body, error_reason: &invite_error_reason/1) do
        {:error, "Slack API error: already_in_channel"} when single_user? ->
          {:ok, %{"channel" => body["channel"], "already_in_channel" => true}}

        result ->
          result
      end
    end
  end

  defp invite_error_reason(%API.Error{body: %{"errors" => errors}} = error)
       when is_list(errors) and errors != [] do
    API.provider_error_message(error) <>
      " (" <> Enum.map_join(errors, ", ", &invite_error_detail/1) <> ")"
  end

  defp invite_error_reason(error), do: API.provider_error_message(error)

  defp invite_error_detail(%{"user" => user} = entry),
    do: str(user) <> ": " <> (presence(str(entry["error"])) || "ok")

  defp invite_error_detail(entry), do: inspect(entry)

  # Slack channel names are lowercase letters, numbers, hyphens, and underscores,
  # at most 80 characters. A leading `#` and upper-case letters are what people
  # type when naming a channel, so they are normalized; anything Slack would
  # reject (spaces, periods, other punctuation) fails here with an actionable
  # message instead of a provider `invalid_name_specials` round trip.
  @slack_channel_name_max_length 80

  defp slack_channel_name(value) do
    name = value |> str() |> String.trim_leading("#") |> String.trim() |> String.downcase()

    cond do
      name == "" ->
        {:error, "name required"}

      String.length(name) > @slack_channel_name_max_length ->
        {:error, "name must be at most #{@slack_channel_name_max_length} characters"}

      not Regex.match?(~r/^[\p{L}\p{N}_-]+$/u, name) ->
        {:error,
         "name may only contain lowercase letters, numbers, hyphens, and underscores (no spaces or periods)"}

      true ->
        {:ok, name}
    end
  end

  defp slack_channel_summary(%{} = channel) do
    %{
      "channel" => str(channel["id"]),
      "name" => str(channel["name"]),
      "is_private" => channel["is_private"] == true
    }
  end

  defp slack_channel_summary(channel), do: %{"channel" => str(channel)}

  defp slack_invite_errors(errors) when is_list(errors) and errors != [] do
    Enum.map(errors, fn
      %{} = entry ->
        %{"user" => str(entry["user"])}
        |> put_present("error", presence(str(entry["error"])))

      other ->
        %{"error" => inspect(other)}
    end)
  end

  defp slack_invite_errors(_errors), do: nil

  @doc false
  def upload_files(agent_id, tenant, connect, files, params \\ %{}) when is_list(files) do
    files = Enum.map(files, &slack_upload_file/1)

    result =
      with :ok <- require_slack_upload_files(files),
           {:ok, comment_fields} <- render_slack_upload_comment(params["initial_comment"]),
           {:ok, token} <- slack_token(tenant, connect),
           {:ok, uploaded_files} <- stage_slack_file_uploads(agent_id, token, files),
           {:ok, resp} <-
             slack_request(
               token,
               "files.completeUploadExternal",
               Map.merge(
                 %{
                   "files" => Enum.map(uploaded_files, &slack_completed_file/1),
                   "channel_id" => slack_file_channel_id(params),
                   "thread_ts" => presence(str(params["thread_ts"]))
                 },
                 comment_fields
               )
             ) do
        {:ok, Map.put(resp, "uploaded_files", uploaded_files)}
      end

    notify_thread_reply(
      agent_id,
      connect,
      slack_file_channel_id(params),
      params["thread_ts"],
      result
    )

    result
  end

  defp render_slack_upload_comment(value) do
    case value |> str() |> String.trim() do
      "" ->
        {:ok, %{}}

      text ->
        case render_slack_message(text, nil, nil, :tool_noninteractive) do
          {:ok, %{blocks: blocks}} ->
            # initial_comment takes precedence over blocks in Slack uploads.
            {:ok, %{"blocks" => blocks}}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp notify_thread_reply(agent_id, connect, channel_id, thread_ts, {:ok, result}) do
    SlackRouterStatus.provider_reply_sent(connect["connect_id"], channel_id, thread_ts)
    record_router_thread_participation(agent_id, connect, channel_id, thread_ts, result)
  end

  defp notify_thread_reply(_agent_id, _connect, _channel_id, _thread_ts, _result), do: :ok

  defp record_router_thread_participation(agent_id, connect, channel_id, thread_ts, result) do
    agent_id = str(agent_id)
    channel_id = str(channel_id)
    thread_ts = first_present([str(thread_ts), str(result["ts"])]) || ""

    with true <- agent_id != "" and channel_id != "" and thread_ts != "",
         {:ok, %{"role" => "router"} = router} <-
           ProviderConnects.resolve_im_connect_inbound_agent(connect),
         true <- str(router["agent_id"]) == agent_id do
      case SlackRouterThreadParticipations.mark_participating(
             connect["group_id"],
             connect["connect_id"],
             connect["workspace_id"],
             connect["bot_user_id"],
             channel_id,
             thread_ts
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "slack router outbound participating status was not recorded: #{inspect(reason)}"
          )
      end
    else
      _ -> :ok
    end
  end

  def find_conversation_delivery_message(tenant, connect, channel, thread_ts, operation_ref) do
    find_delivery_message(
      tenant,
      connect,
      channel,
      thread_ts,
      operation_ref,
      "salix_conversation_delivery"
    )
  end

  @doc false
  def find_triage_reply_message(tenant, connect, channel, thread_ts, operation_ref) do
    find_delivery_message(
      tenant,
      connect,
      channel,
      thread_ts,
      operation_ref,
      "salix_triage_reply_delivery"
    )
  end

  defp find_delivery_message(tenant, connect, channel, thread_ts, operation_ref, event_type) do
    channel = str(channel)
    thread_ts = str(thread_ts)
    operation_ref = str(operation_ref)
    method = if thread_ts == "", do: "conversations.history", else: "conversations.replies"

    with true <- channel != "" and operation_ref != "",
         {:ok, token} <- slack_token(tenant, connect),
         {:ok, resp} <-
           slack_request(token, method, %{
             "channel" => channel,
             "ts" => presence(thread_ts),
             "limit" => 200,
             "include_all_metadata" => true
           }) do
      message =
        Enum.find(
          Map.get(resp, "messages", []),
          &delivery_message?(&1, operation_ref, event_type)
        )

      cond do
        is_map(message) ->
          {:ok,
           %{
             "channel" => channel,
             "ts" => message["ts"],
             "thread_ts" => message["thread_ts"] || thread_ts,
             "operation_ref" => operation_ref
           }}

        presence(slack_next_cursor(resp)) ->
          {:error, :verification_window_incomplete}

        true ->
          {:ok, nil}
      end
    else
      false -> {:ok, nil}
      other -> other
    end
  end

  defp delivery_message?(message, operation_ref, event_type) when is_map(message) do
    get_in(message, ["metadata", "event_type"]) == event_type and
      get_in(message, ["metadata", "event_payload", "operation_ref"]) == operation_ref
  end

  defp delivery_message?(_message, _operation_ref, _event_type), do: false

  defp slack_token(_tenant, connect) do
    case Enum.map(~w(bot_token app_id workspace_id), &str(connect[&1])) do
      [token, _app_id, workspace_id] when token != "" and workspace_id != "" ->
        {:ok, API.installation(connect)}

      _ ->
        {:error, "Slack connect is not OAuth-complete"}
    end
  end

  defp dm_channel_id(conversation) do
    case str(conversation["id"]) do
      "" -> {:error, "Slack did not return a DM channel"}
      id -> {:ok, id}
    end
  end

  defp slack_request(token, method, body, opts \\ []) do
    body =
      body
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new(fn {key, value} -> {key, form_value(value)} end)

    {:ok,
     slack_success_payload(
       method,
       API.request_form(token, method, body, Keyword.get(opts, :request_options, []))
     )}
  rescue
    e in API.Error ->
      reason =
        cond do
          Keyword.get(opts, :ambiguous_write?, false) ->
            slack_error_reason(e)

          is_function(opts[:error_reason], 1) ->
            opts[:error_reason].(e)

          true ->
            API.provider_error_message(e)
        end

      {:error, reason}
  end

  defp durable_delivery_metadata?(%{
         "event_type" => event_type,
         "event_payload" => %{"operation_ref" => operation_ref}
       })
       when event_type in ["salix_conversation_delivery", "salix_triage_reply_delivery"],
       do: str(operation_ref) != ""

  defp durable_delivery_metadata?(_metadata), do: false

  defp slack_error_reason(%API.Error{status: status} = error)
       when status == 408 or (is_integer(status) and status >= 500),
       do: {:ambiguous, API.provider_error_message(error)}

  defp slack_error_reason(%API.Error{retry_after: seconds} = error)
       when is_integer(seconds) and seconds > 0,
       do: {:retry_after, seconds * 1_000, API.provider_error_message(error)}

  defp slack_error_reason(%API.Error{status: nil, message: message} = error)
       when message in @ambiguous_write_app_errors,
       do: {:ambiguous, API.provider_error_message(error)}

  defp slack_error_reason(
         %API.Error{status: nil, message: "slack api request failed:" <> _} = error
       ),
       do: {:ambiguous, API.provider_error_message(error)}

  defp slack_error_reason(error), do: API.provider_error_message(error)

  defp slack_api_ok(fun) do
    fun.()
  rescue
    e in API.Error -> {:error, API.provider_error_message(e)}
  end

  defp slack_api_value(fun) do
    {:ok, fun.()}
  rescue
    e in API.Error -> {:error, API.provider_error_message(e)}
  end

  defp emit_slack_outbound_diagnostic(connect, api, params, result) do
    connect
    |> slack_outbound_diagnostic(api, params, result)
    |> Diagnostics.emit()
  end

  defp slack_outbound_diagnostic(connect, api, params, result) do
    {status, severity, event_type, reason_class, summary} =
      slack_outbound_outcome(api, params, result)

    request_id = slack_request_id(params)
    channel_id = slack_result_channel(result) || str(params["channel"])
    message_ts = slack_result_ts(result)
    thread_ts = str(params["thread_ts"])
    message_id = slack_message_id(connect, channel_id, message_ts)
    source_message_id = slack_message_id(connect, channel_id, thread_ts)

    %{
      provider: "slack",
      source: "salix.im",
      domain: "conversation",
      event_type: event_type,
      severity: severity,
      status: status,
      reason_class: reason_class,
      summary: summary,
      tenant_id: safe_connect_value(connect, "tenant_id"),
      group_id: safe_connect_value(connect, "group_id"),
      connect_id: safe_connect_value(connect, "connect_id"),
      app_id: safe_connect_value(connect, "app_id"),
      workspace_id: safe_connect_value(connect, "workspace_id"),
      operation_api: api,
      request_id: request_id,
      correlation_id: first_present([request_id, message_id, source_message_id]),
      channel_id: channel_id,
      user_id: if(api == "slack.send_dm", do: str(params["user_id"]), else: nil),
      thread_ts: if(thread_ts == "", do: nil, else: thread_ts),
      message_ts: message_ts,
      message_id: message_id,
      source_message_id: if(thread_ts == "", do: nil, else: source_message_id),
      reply_message_id: if(thread_ts == "", do: nil, else: message_id),
      delivery_state: status
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp slack_outbound_outcome("slack.post_message", params, {:ok, _result}) do
    if str(params["thread_ts"]) == "" do
      {"sent", "info", "slack.message.sent", nil, "Slack message sent"}
    else
      {"reply_sent", "info", "slack.reply.sent", nil, "Slack reply sent"}
    end
  end

  defp slack_outbound_outcome("slack.post_message", params, {:error, reason}) do
    if str(params["thread_ts"]) == "" do
      {"send_failed", "error", "slack.message.failed", provider_reason_class(reason),
       "Slack message failed"}
    else
      {"reply_failed", "error", "slack.reply.failed", provider_reason_class(reason),
       "Slack reply failed"}
    end
  end

  defp slack_outbound_outcome(api, params, result)
       when api in ["slack.post_map_card", "slack.post_stock_card", "slack.post_weather_card"] do
    slack_outbound_outcome("slack.post_message", params, result)
  end

  defp slack_outbound_outcome("slack.send_dm", _params, {:ok, _result}),
    do: {"sent", "info", "slack.message.sent", nil, "Slack DM sent"}

  defp slack_outbound_outcome("slack.send_dm", _params, {:error, reason}),
    do:
      {"send_failed", "error", "slack.message.failed", provider_reason_class(reason),
       "Slack DM failed"}

  defp slack_result_channel({:ok, %{"channel" => channel}}), do: str(channel)
  defp slack_result_channel(_result), do: nil

  defp slack_result_ts({:ok, %{"ts" => ts}}), do: str(ts)
  defp slack_result_ts(_result), do: nil

  defp slack_request_id(params),
    do: first_present([params["request_id"], params["client_request_id"]])

  defp slack_message_id(connect, channel_id, ts) do
    SalixIM.Provider.Slack.SourceMessageId.app(
      safe_connect_value(connect, "connect_id"),
      channel_id,
      ts
    )
  end

  defp first_present(values) do
    Enum.find(values, fn value -> is_binary(value) and value != "" end)
  end

  defp safe_connect_value(connect, key) when is_map(connect), do: str(connect[key])
  defp safe_connect_value(_connect, _key), do: ""

  defp provider_reason_class(reason) do
    reason = if is_binary(reason), do: reason, else: inspect(reason)

    cond do
      String.contains?(reason, "rate_limited") -> "rate_limited"
      String.contains?(reason, "missing_scope") -> "missing_scope"
      String.contains?(reason, "OAuth-complete") -> "oauth_incomplete"
      String.contains?(reason, "required") -> "validation_error"
      String.contains?(reason, "Slack API error") -> "provider_api_error"
      String.contains?(reason, "Slack HTTP") -> "provider_http_error"
      true -> "provider_error"
    end
  end

  defp slack_success_payload("conversations.open", body), do: body["channel"] || %{}
  defp slack_success_payload("conversations.list", body), do: body
  defp slack_success_payload("users.list", body), do: body
  defp slack_success_payload("users.info", body), do: body["user"] || %{}
  defp slack_success_payload("chat.update", body), do: Map.take(body, ["channel", "ts"])
  defp slack_success_payload("chat.delete", body), do: Map.take(body, ["channel", "ts"])
  defp slack_success_payload("conversations.members", body), do: body
  defp slack_success_payload("conversations.replies", body), do: body
  defp slack_success_payload("conversations.history", body), do: body

  defp slack_success_payload("conversations.join", body) do
    channel = body["channel"] || %{}

    %{
      "channel" => channel["id"],
      "name" => channel["name"],
      "is_member" => channel["is_member"] == true
    }
    |> put_present("warning", body["warning"])
  end

  defp slack_success_payload("conversations.setTopic", body), do: Map.take(body, ["topic"])
  defp slack_success_payload("conversations.setPurpose", body), do: Map.take(body, ["purpose"])

  defp slack_success_payload("conversations.create", body),
    do: slack_channel_summary(body["channel"] || %{})

  defp slack_success_payload("conversations.invite", body) do
    body["channel"]
    |> slack_channel_summary()
    |> Map.take(["channel", "name"])
    |> put_present("errors", slack_invite_errors(body["errors"]))
  end

  defp slack_success_payload("bookmarks.add", body), do: Map.take(body, ["bookmark"])
  defp slack_success_payload("emoji.list", body), do: %{"emoji" => body["emoji"] || %{}}
  defp slack_success_payload("files.getUploadURLExternal", body), do: body
  defp slack_success_payload("files.info", body), do: body["file"] || %{}

  defp slack_success_payload("canvases.create", body), do: Map.take(body, ["canvas_id"])

  defp slack_success_payload("conversations.canvases.create", body),
    do: Map.take(body, ["canvas_id"])

  defp slack_success_payload("files.completeUploadExternal", body),
    do: %{"files" => body["files"] || []}

  defp slack_success_payload(_method, body), do: body

  defp slack_page_limit(value) do
    case int_or(value, 0) do
      n when n <= 0 -> 100
      n when n > 200 -> 200
      n -> n
    end
  end

  defp bool_or(value, _default) when is_boolean(value), do: value

  defp bool_or(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp bool_or(_value, default), do: default

  defp slack_user_list_entry(user) do
    user
    |> slack_user_summary()
    |> then(fn entry ->
      if user["deleted"] == true,
        do: Map.put(entry, "deleted", true),
        else: entry
    end)
  end

  defp slack_user_summary(user) do
    profile = user["profile"] || %{}

    %{
      "id" => user["id"],
      "name" => user["name"],
      "real_name" => user["real_name"],
      "is_bot" => user["is_bot"] == true
    }
    |> put_present("display_name", profile["display_name"])
    |> put_present("email", profile["email"])
    |> put_present("title", profile["title"])
  end

  defp slack_user_matches_query?(_entry, ""), do: true

  defp slack_user_matches_query?(entry, query) do
    normalized_query = normalize_slack_user_query(query)

    Enum.any?(["id", "name", "real_name", "display_name", "title", "email"], fn key ->
      entry
      |> Map.get(key)
      |> str()
      |> normalize_slack_user_query()
      |> String.contains?(normalized_query)
    end)
  end

  defp normalize_slack_user_query(value) do
    value
    |> str()
    |> String.downcase()
    |> String.trim()
    |> String.trim_leading("@")
  end

  defp slack_next_cursor(%{"response_metadata" => %{"next_cursor" => cursor}}), do: cursor
  defp slack_next_cursor(_resp), do: nil

  # Streams a Slack file (resolved via files.info) into the agent VFS on demand
  # and returns the provider-neutral attachment block: native input for an
  # image, a workspace-path announcement for anything else.
  # Where a file lives, as Slack itself reports it: `files.info` lists every
  # channel, private channel and DM the file was shared into. A file is one
  # thing in several places, so its audience is the join of all of them — see
  # `SalixIM.IFC.ReadLabels.for_scopes/2` for why that direction is the safe one.
  defp file_scopes(file) when is_map(file) do
    ~w(channels groups ims)
    |> Enum.flat_map(&List.wrap(file[&1]))
    |> Enum.filter(&is_binary/1)
  end

  defp file_scopes(_file), do: []

  # The block rides out under a reserved key that `SalixAgent.Tools.IMRouter`
  # pops before the result is encoded, so it never reaches the model as content.
  defp put_ifc(result, nil), do: result
  defp put_ifc(result, ifc), do: Map.put(result, "__ifc__", ifc)

  defp stage_fetched_file(agent_id, token, file) do
    url = SalixIM.SlackFiles.download_url(file)

    cond do
      to_string(agent_id || "") == "" ->
        {:error, "agent VFS is not available for this call"}

      map_size(file) == 0 ->
        {:error, "file not found"}

      url == "" ->
        {:error, "file has no downloadable content"}

      SalixIM.SlackFiles.oversized?(file) ->
        {:error, "file exceeds the #{SalixIM.SlackFiles.max_bytes()} byte staging limit"}

      true ->
        path = SalixIM.SlackFiles.file_vfs_path(file)

        case SalixIM.SlackFiles.stage(agent_id, token, path, url) do
          {:ok, path} ->
            {:ok,
             %{
               "vfs_path" => path,
               "name" => str(file["name"]),
               "mimetype" => SalixIM.SlackFiles.mime(file),
               "size" => file["size"]
             }}

          {:error, reason} ->
            {:error, "failed to stage file: #{inspect(reason)}"}
        end
    end
  end

  defp form_value(value) when is_binary(value), do: value
  defp form_value(value) when is_boolean(value), do: to_string(value)
  defp form_value(value) when is_integer(value), do: Integer.to_string(value)
  defp form_value(value) when is_float(value), do: Float.to_string(value)
  defp form_value(value) when is_list(value) or is_map(value), do: Jason.encode!(value)
  defp form_value(value), do: to_string(value)

  defp slack_metadata(metadata) when is_map(metadata), do: metadata
  defp slack_metadata(_metadata), do: nil

  defp optional_boolean(value) when is_boolean(value), do: value
  defp optional_boolean(_value), do: nil

  defp require_params(params, fields) do
    missing = Enum.filter(fields, &(str(params[&1]) == ""))

    if missing == [] do
      :ok
    else
      {:error, Enum.join(missing, ", ") <> " required"}
    end
  end

  defp require_slack_upload_files([]), do: {:error, "path required"}

  defp require_slack_upload_files(files) do
    case Enum.find(files, &(str(&1["path"]) == "")) do
      nil -> :ok
      _file -> {:error, "path required"}
    end
  end

  defp slack_upload_file(file) when is_map(file) do
    path = str(file["path"] || file[:path])

    %{
      "path" => path,
      "title" => presence(str(file["title"] || file[:title])) || Path.basename(path)
    }
  end

  defp slack_upload_file(_file), do: %{"path" => "", "title" => ""}

  defp stage_slack_file_uploads(agent_id, token, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case stage_slack_file_upload(agent_id, token, file) do
        {:ok, uploaded} -> {:cont, {:ok, acc ++ [uploaded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stage_slack_file_upload(agent_id, token, file) do
    path = file["path"]

    with {:ok, stream, size} <- read_vfs_stream(agent_id, path),
         {:ok, upload} <-
           slack_request(token, "files.getUploadURLExternal", %{
             "filename" => Path.basename(path),
             "length" => size
           }),
         :ok <-
           slack_api_ok(fn ->
             API.upload_stream_to_url(upload["upload_url"], stream, size)
           end) do
      {:ok,
       %{
         "id" => upload["file_id"],
         "path" => path,
         "title" => file["title"]
       }}
    end
  end

  defp slack_completed_file(file), do: %{"id" => file["id"], "title" => file["title"]}

  defp slack_file_channel_id(params),
    do: presence(str(params["channel_id"] || params["channel"]))

  defp slack_reaction_name(value) do
    value
    |> str()
    |> String.trim()
    |> String.trim(":")
  end

  defp simple_slack_body(fields, params) do
    required =
      Enum.map(fields, fn
        {_target, source} when is_binary(source) -> source
        {_target, :reaction} -> "name"
        {_target, :users} -> "users"
        {_target, {:constant, _value}} -> nil
      end)
      |> Enum.reject(&is_nil/1)

    with :ok <- require_params(params, required) do
      Enum.reduce_while(fields, {:ok, %{}}, fn {target, source}, {:ok, body} ->
        case simple_slack_value(source, params) do
          {:ok, value} -> {:cont, {:ok, Map.put(body, target, value)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp simple_slack_value({:constant, value}, _params), do: {:ok, value}
  defp simple_slack_value(:reaction, params), do: {:ok, slack_reaction_name(params["name"])}
  defp simple_slack_value(:users, params), do: slack_users(params["users"])
  defp simple_slack_value(source, params), do: {:ok, str(params[source])}

  # Accepts a list or a comma-separated string of Slack user IDs and yields the
  # trimmed, comma-joined form conversations.invite expects.
  defp slack_users(users) do
    users =
      users
      |> List.wrap()
      |> Enum.flat_map(&(&1 |> str() |> String.split(",")))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if users == [], do: {:error, "users required"}, else: {:ok, Enum.join(users, ",")}
  end

  defp read_vfs_stream(nil, _path), do: {:error, "agent_id is required for Slack file uploads"}

  defp read_vfs_stream(agent_id, path) do
    case SalixIM.Ports.AgentWorkspace.read_stream(agent_id, path) do
      {:ok, stream, size, _filename} -> {:ok, stream, size}
      {:error, :not_found} -> {:error, "file not found in agent VFS: #{path}"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "file not found in agent VFS: #{path}"}
    end
  end

  # ---- canvases ----

  defp canvas_document(markdown), do: %{"type" => "markdown", "markdown" => markdown}

  # Build the `changes` list for canvases.edit. Either an explicit JSON array via
  # `changes`, or a single operation synthesized from `operation`/`section_id`/`content`.
  defp canvas_changes(%{"changes" => raw}) when raw not in [nil, "", []] do
    case decode_canvas_changes(raw) do
      {:ok, list} -> {:ok, list}
      :error -> {:error, "changes must be a JSON array of canvas edit operations"}
    end
  end

  defp canvas_changes(params) do
    with {:ok, operation} <- canvas_operation(params["operation"]) do
      section_id = presence(str(params["section_id"]))
      content = str(params["content"])

      cond do
        operation == "delete" and section_id == nil ->
          {:error, "section_id is required for a delete operation"}

        operation in ["insert_after", "insert_before"] and section_id == nil ->
          {:error, "section_id is required for #{operation}"}

        operation != "delete" and String.trim(content) == "" ->
          {:error, "content is required"}

        true ->
          change =
            %{"operation" => operation}
            |> maybe_put("section_id", section_id)
            |> then(fn change ->
              if operation == "delete",
                do: change,
                else: Map.put(change, "document_content", canvas_document(content))
            end)

          {:ok, [change]}
      end
    end
  end

  defp decode_canvas_changes(raw) when is_list(raw), do: {:ok, raw}

  defp decode_canvas_changes(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  defp decode_canvas_changes(_raw), do: :error

  # Friendly aliases plus the raw Slack operation names.
  defp canvas_operation(value) do
    case value |> str() |> String.trim() |> String.downcase() do
      "" -> {:ok, "replace"}
      "replace" -> {:ok, "replace"}
      "append" -> {:ok, "insert_at_end"}
      "prepend" -> {:ok, "insert_at_start"}
      "insert_at_end" -> {:ok, "insert_at_end"}
      "insert_at_start" -> {:ok, "insert_at_start"}
      "insert_after" -> {:ok, "insert_after"}
      "insert_before" -> {:ok, "insert_before"}
      "delete" -> {:ok, "delete"}
      other -> {:error, "unsupported canvas operation: #{other}"}
    end
  end

  defp canvas_access_level(value) do
    case value |> str() |> String.trim() |> String.downcase() do
      level when level in ["read", "write"] -> {:ok, level}
      _ -> {:error, ~s(access_level must be "read" or "write")}
    end
  end

  # canvases.access.{set,delete} target channels and/or users; at least one required.
  defp canvas_access_targets(params) do
    channel_ids = canvas_id_list(params["channel_ids"])
    user_ids = canvas_id_list(params["user_ids"])

    if channel_ids == [] and user_ids == [] do
      {:error, "channel_ids or user_ids is required"}
    else
      targets =
        %{}
        |> maybe_put("channel_ids", presence(Enum.join(channel_ids, ",")))
        |> maybe_put("user_ids", presence(Enum.join(user_ids, ",")))

      {:ok, targets}
    end
  end

  defp canvas_id_list(value) when is_list(value),
    do: value |> Enum.map(&str/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp canvas_id_list(value) do
    value
    |> str()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp render_slack_message(text, render_mode, raw_blocks, :tool_noninteractive) do
    with :ok <- reject_model_owned_slack_layout(render_mode, raw_blocks),
         input = %Input{markdown: text} do
      case MessageRenderer.render(SlackMessageRenderer, input) do
        {:error, :text_required} ->
          {:error, "text is required"}

        {:error, :markdown_too_long} ->
          {:error, "text exceeds Slack's 12,000-character limit"}

        {:error, :table_too_large} ->
          {:error, "Slack tables exceed the 10,000-character aggregate limit"}

        {:error, :too_many_blocks} ->
          {:error, "Slack messages cannot contain more than 50 blocks"}

        other ->
          other
      end
    end
  end

  defp render_slack_message(text, render_mode, raw_blocks, block_policy)
       when block_policy in [:trusted_product, :product_noninteractive] do
    text = String.trim(text)

    try do
      blocks = parse_slack_blocks!(raw_blocks)

      cond do
        text == "" ->
          {:error, "text is required"}

        blocks == [] and render_mode in [nil, ""] ->
          MessageRenderer.render(SlackMessageRenderer, %Input{markdown: text})

        blocks == [] ->
          {:error, "trusted product blocks are required for native block rendering"}

        render_mode != "blocks" ->
          {:error, ~s(trusted product blocks require render_mode="blocks")}

        true ->
          with :ok <- SlackMessageRenderer.validate_block_limit(blocks) do
            validate_blocks_for_policy!(blocks, block_policy)
            {:ok, %{text: text, blocks: blocks}}
          else
            {:error, :too_many_blocks} ->
              {:error, "Slack messages cannot contain more than 50 blocks"}
          end
      end
    rescue
      e in RuntimeError -> {:error, e.message}
    end
  end

  defp reject_model_owned_slack_layout(render_mode, raw_blocks) do
    if render_mode in [nil, "", "blocks"] and raw_blocks == nil do
      :ok
    else
      {:error, "render_mode and blocks are not supported; send standard Markdown text"}
    end
  end

  defp normalize_slack_text(value), do: value |> to_string() |> String.trim()

  defp rich_card_surface(card_type, channel, params) do
    kind = String.to_existing_atom(card_type)

    data =
      Map.drop(params, ["channel", "thread_ts", "metadata", "blocks", "render_mode"])

    %Surface{
      kind: kind,
      id: "#{card_type}:#{channel}",
      fallback: "",
      data: data
    }
  end

  defp parse_slack_blocks!(nil), do: []
  defp parse_slack_blocks!(""), do: []
  defp parse_slack_blocks!(blocks) when is_list(blocks), do: blocks

  defp parse_slack_blocks!(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, blocks} when is_list(blocks) -> blocks
      {:ok, _} -> raise "blocks must be a JSON array"
      {:error, err} -> raise "invalid blocks JSON: #{Exception.message(err)}"
    end
  end

  defp parse_slack_blocks!(_raw), do: raise("blocks must be a JSON array")

  @noninteractive_block_types ~w(section header divider context image rich_text video markdown table)
  @interactive_element_types ~w(
    actions
    input
    button
    checkboxes
    channels_select
    conversations_select
    datepicker
    datetimepicker
    email_text_input
    external_select
    feedback_buttons
    file_input
    icon_button
    multi_channels_select
    multi_conversations_select
    multi_external_select
    multi_static_select
    multi_users_select
    number_input
    overflow
    plain_text_input
    radio_buttons
    rich_text_input
    static_select
    timepicker
    url_text_input
    users_select
    workflow_button
  )

  @product_noninteractive_block_types @noninteractive_block_types ++
                                        ~w(card container data_visualization)

  defp validate_blocks_for_policy!(blocks, :product_noninteractive),
    do: validate_noninteractive_blocks!(blocks, @product_noninteractive_block_types)

  defp validate_blocks_for_policy!(_blocks, :trusted_product), do: :ok

  defp validate_noninteractive_blocks!(blocks, allowed_types) do
    Enum.each(blocks, fn
      %{"type" => type} = block when is_binary(type) ->
        if type in allowed_types,
          do: reject_interactive_block_value!(block),
          else: raise("unsupported or interactive Block Kit block type: #{type}")

      block when is_map(block) ->
        raise "every Block Kit block requires a supported string type"

      _other ->
        raise "every Block Kit block must be an object"
    end)
  end

  defp reject_interactive_block_value!(%{} = value) do
    type = value["type"]

    if type in @interactive_element_types or
         (is_binary(value["action_id"]) and String.trim(value["action_id"]) != "") do
      raise "interactive Block Kit elements are not supported"
    end

    Enum.each(value, fn {_key, nested} -> reject_interactive_block_value!(nested) end)
  end

  defp reject_interactive_block_value!(value) when is_list(value),
    do: Enum.each(value, &reject_interactive_block_value!/1)

  defp reject_interactive_block_value!(_value), do: :ok

  defp checkbox_action(%{"type" => "block_actions", "actions" => [action]})
       when is_map(action) do
    cond do
      action["type"] != "checkboxes" ->
        {:error, {:ignored, :unsupported_action}}

      not SlackMessageRenderer.checkbox_action?(action["action_id"]) ->
        {:error, {:ignored, :unsupported_action}}

      true ->
        {:ok, action}
    end
  end

  defp checkbox_action(_payload), do: {:error, {:ignored, :invalid_interaction_payload}}

  defp checkbox_message(payload) do
    container = payload["container"] || %{}
    message = payload["message"] || %{}
    channel = str(container["channel_id"])
    ts = str(container["message_ts"])
    text = str(message["text"])
    blocks = message["blocks"]

    cond do
      container["type"] != "message" ->
        {:error, {:ignored, :unsupported_interaction_container}}

      channel == "" or ts == "" or text == "" or not is_list(blocks) ->
        {:error, {:ignored, :invalid_interaction_message}}

      str(message["ts"]) not in ["", ts] ->
        {:error, {:ignored, :interaction_message_mismatch}}

      str(get_in(payload, ["channel", "id"])) not in ["", channel] ->
        {:error, {:ignored, :interaction_channel_mismatch}}

      true ->
        {:ok, %{channel: channel, ts: ts, text: text, blocks: blocks}}
    end
  end

  defp verify_checkbox_action_address(action, message) do
    block_id = str(action["block_id"])
    action_id = str(action["action_id"])

    matching_blocks =
      Enum.filter(message.blocks, fn block ->
        block["type"] == "actions" and block["block_id"] == block_id and
          Enum.any?(block["elements"] || [], fn element ->
            element["type"] == "checkboxes" and element["action_id"] == action_id
          end)
      end)

    if block_id != "" and length(matching_blocks) == 1,
      do: :ok,
      else: {:error, {:ignored, :stale_or_invalid_checkbox_action}}
  end

  defp checkbox_selected_values(action) do
    case action["selected_options"] do
      options when is_list(options) ->
        values = Enum.map(options, &str(&1["value"]))

        if Enum.all?(values, &(&1 != "")),
          do: {:ok, values},
          else: {:error, {:ignored, :invalid_checkbox_selection}}

      _other ->
        {:error, {:ignored, :invalid_checkbox_selection}}
    end
  end
end
