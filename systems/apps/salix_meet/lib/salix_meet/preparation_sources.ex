defmodule SalixMeet.PreparationSources do
  @moduledoc """
  Shared originals for meeting preparation, independent of the Group IFC mode:
  public Slack channels of the meeting's workspace, or on Feishu/Lark the
  notice chat and the organization's public groups the bot is in.

  A Feishu/Lark chat other than the notice chat must be a public, internal
  group. The notice chat may be private: the shared report goes back to that
  chat, and a personal report may cite it only for a recipient who is in it.
  """

  alias SalixIM.Provider.Slack.{API, MessageRead, SearchQuery}
  alias SalixIM.ProviderConnects

  @operations ~w(history replies search file)
  @max_file_bytes 256 * 1024

  def read(plan, args) do
    if lark?(plan), do: read_lark(plan, args), else: read_slack(plan, args)
  end

  defp read_slack(plan, args) do
    channel_id = args["channel"]

    with true <- plan["research_enabled"] != false,
         :ok <- SalixMeet.CalendarConfiguration.authorize_plan(plan),
         operation when operation in @operations <- args["operation"],
         {:ok, connect} <- connect(plan),
         :ok <- public_channel(connect, channel_id),
         {:ok, params} <- params(operation, args),
         {:ok, result} <- read_page(operation, connect, params),
         :ok <- public_channel(connect, channel_id) do
      {:ok,
       result
       |> Map.delete("__ifc__")
       |> Map.put("channel", channel_id)
       |> Map.put("source_label", [scope_label(connect["connect_id"], channel_id)])}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_meeting_shared_source}
    end
  end

  # Labels come from stored original tool results, never report parameters.
  # Recheck channel visibility before saving: a public channel can become private.
  def authorize_labels(plan, user_id, labels) when is_list(labels) and length(labels) in 1..32 do
    if lark?(plan),
      do: authorize_lark_labels(plan, user_id, labels),
      else: authorize_slack_labels(plan, user_id, labels)
  end

  def authorize_labels(_plan, _user_id, _labels), do: {:error, :meeting_shared_source_required}

  defp authorize_slack_labels(plan, user_id, labels) do
    with {:ok, connect} <- connect(plan) do
      expected_connect = connect["connect_id"]

      Enum.reduce_while(Enum.uniq(labels), :ok, fn label, :ok ->
        case String.split(label, "|") do
          ["scope", ^expected_connect, "@" <> ^user_id] ->
            {:cont, :ok}

          ["scope", ^expected_connect, channel] ->
            case public_channel(connect, channel) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end

          _ ->
            {:halt, {:error, :meeting_shared_source_required}}
        end
      end)
    end
  end

  def authorize_files(_plan, []), do: :ok

  # Feishu/Lark preparation reads messages only; it cites no file.
  def authorize_files(%{"publication_target" => %{"provider" => provider}}, _files)
      when provider in ["feishu", "lark"],
      do: {:error, :meeting_shared_source_required}

  def authorize_files(plan, files) when is_list(files) and length(files) <= 32 do
    with {:ok, connect} <- connect(plan) do
      Enum.reduce_while(Enum.uniq(files), :ok, fn source, :ok ->
        with %{"connect_id" => connect_id, "channel" => channel, "file_id" => file_id} <- source,
             true <- connect_id == connect["connect_id"],
             true <- is_binary(file_id) and Regex.match?(~r/^F[A-Z0-9]+$/, file_id),
             :ok <- public_channel(connect, channel),
             :ok <-
               shared_file(API.file_info(API.installation(connect), file_id), file_id, channel) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, {:error, :meeting_shared_source_required}}
        end
      end)
    end
  rescue
    _error in [API.Error, ArgumentError] -> {:error, :meeting_shared_source_unavailable}
  end

  def authorize_files(_plan, _files), do: {:error, :meeting_shared_source_required}

  defp connect(plan),
    do:
      ProviderConnects.get_active_connect_by_id(
        plan["group_id"],
        get_in(plan, ["publication_target", "params", "connect_id"]),
        "slack"
      )

  defp public_channel(connect, channel_id) when is_binary(channel_id) do
    if Regex.match?(~r/^C[A-Z0-9]+$/, channel_id) do
      channel = API.conversation_info(API.installation(connect), channel_id)

      if channel["id"] == channel_id and channel["is_private"] == false and
           channel["is_im"] != true and channel["is_mpim"] != true and
           channel["is_shared"] != true and channel["is_ext_shared"] != true and
           channel["is_org_shared"] != true and channel["is_member"] == true,
         do: :ok,
         else: {:error, :meeting_shared_source_required}
    else
      {:error, :meeting_shared_source_required}
    end
  rescue
    _error in [API.Error, ArgumentError] -> {:error, :meeting_shared_source_unavailable}
  end

  defp public_channel(_connect, _channel), do: {:error, :meeting_shared_source_required}

  defp params("search", args) do
    with {:ok, parsed} <- SearchQuery.parse(args["query"]),
         true <- parsed.channel_id in [nil, args["channel"]] do
      {:ok,
       %{
         "query" =>
           if(parsed.channel_id,
             do: args["query"],
             else: "in:#{args["channel"]} " <> args["query"]
           ),
         "count" => 30,
         "cursor" => args["cursor"]
       }}
    else
      _ -> {:error, :invalid_meeting_shared_source}
    end
  end

  defp params("file", args) do
    if is_binary(args["file_id"]) and Regex.match?(~r/^F[A-Z0-9]+$/, args["file_id"]),
      do: {:ok, Map.take(args, ~w(channel file_id))},
      else: {:error, :invalid_meeting_shared_source}
  end

  defp params(_operation, args),
    do: {:ok, args |> Map.take(~w(channel ts cursor oldest latest)) |> Map.put("limit", 30)}

  defp read_page("history", connect, params), do: MessageRead.history(nil, connect, params)
  defp read_page("replies", connect, params), do: MessageRead.replies(nil, connect, params)
  defp read_page("search", connect, params), do: MessageRead.search(nil, connect, params)

  defp read_page("file", connect, params) do
    token = API.installation(connect)
    file_id = params["file_id"]
    channel = params["channel"]

    with file <- API.file_info(token, file_id),
         :ok <- shared_file(file, file_id, channel),
         :ok <- text_file(file),
         url when is_binary(url) and url != "" <-
           file["url_private_download"] || file["url_private"],
         {:ok, text} <- download_text(token, url),
         :ok <- shared_file(API.file_info(token, file_id), file_id, channel) do
      {:ok,
       %{
         "source_file" => %{
           "connect_id" => connect["connect_id"],
           "channel" => channel,
           "file_id" => file_id
         },
         "file_id" => file_id,
         "permalink" => file["permalink"],
         "text" => text,
         "bytes" => byte_size(text)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :meeting_shared_source_unavailable}
    end
  rescue
    _error in [API.Error, ArgumentError] -> {:error, :meeting_shared_source_unavailable}
  end

  defp shared_file(file, file_id, channel) when is_map(file) do
    channels = file["channels"]

    public_shares =
      case file["shares"] do
        %{"public" => shares} when is_map(shares) -> shares[channel]
        _ -> nil
      end

    if file["id"] == file_id and
         ((is_list(channels) and channel in channels) or
            (is_list(public_shares) and public_shares != [])),
       do: :ok,
       else: {:error, :meeting_shared_source_required}
  end

  defp shared_file(_file, _file_id, _channel), do: {:error, :meeting_shared_source_required}

  defp text_file(file) do
    size = file["size"]
    mime = file["mimetype"]

    cond do
      is_integer(size) and size > @max_file_bytes ->
        {:error, :meeting_shared_source_too_large}

      not (is_nil(size) or (is_integer(size) and size >= 0)) ->
        {:error, :invalid_meeting_shared_source}

      not (is_binary(mime) and String.starts_with?(mime, "text/")) ->
        {:error, :meeting_shared_source_requires_text}

      not (is_binary(file["permalink"]) and file["permalink"] != "") ->
        {:error, :meeting_shared_source_unavailable}

      true ->
        :ok
    end
  end

  defp download_text(token, url) do
    deadline = SystemsClock.monotonic_time(:millisecond) + 15_000

    result =
      API.stream_file(
        token,
        url,
        fn {:data, chunk}, {req, resp} ->
          bytes = (resp.private[:preparation_bytes] || 0) + byte_size(chunk)

          cond do
            bytes > @max_file_bytes ->
              {:halt,
               {req,
                Req.Response.put_private(
                  resp,
                  :preparation_error,
                  :meeting_shared_source_too_large
                )}}

            resp.status != 200 or SystemsClock.monotonic_time(:millisecond) >= deadline ->
              {:halt,
               {req,
                Req.Response.put_private(
                  resp,
                  :preparation_error,
                  :meeting_shared_source_unavailable
                )}}

            true ->
              resp =
                resp
                |> Req.Response.put_private(:preparation_bytes, bytes)
                |> Req.Response.put_private(:preparation_chunks, [
                  chunk | resp.private[:preparation_chunks] || []
                ])

              {:cont, {req, resp}}
          end
        end,
        redirect: false,
        receive_timeout: 5_000
      )

    case result do
      {:ok, %{status: 200, private: private}} ->
        case private[:preparation_error] do
          nil ->
            text =
              private
              |> Map.get(:preparation_chunks, [])
              |> Enum.reverse()
              |> IO.iodata_to_binary()

            if String.valid?(text),
              do: {:ok, text},
              else: {:error, :meeting_shared_source_requires_text}

          reason ->
            {:error, reason}
        end

      _ ->
        {:error, :meeting_shared_source_unavailable}
    end
  end

  defp scope_label(connect_id, channel), do: "scope|#{connect_id}|#{channel}"

  # ---------------------------------------------------------------------------
  # Feishu/Lark

  @lark_operations ~w(history replies)
  @lark_page_size 30
  @lark_member_pages 10

  defp lark?(plan), do: get_in(plan, ["publication_target", "provider"]) in ["feishu", "lark"]

  defp read_lark(plan, args) do
    chat_id = args["channel"]

    with true <- plan["research_enabled"] != false,
         :ok <- SalixMeet.CalendarConfiguration.authorize_plan(plan),
         operation when operation in @lark_operations <- args["operation"],
         {:ok, provider, connect} <- lark_connect(plan),
         :ok <- shared_chat(provider, connect, plan, chat_id),
         {:ok, page} <- lark_page(provider, connect, operation, chat_id, args),
         :ok <- same_chat(page["messages"], chat_id),
         :ok <- shared_chat(provider, connect, plan, chat_id) do
      {:ok,
       page
       |> Map.delete("__ifc__")
       |> Map.put("channel", chat_id)
       |> Map.put("source_label", [scope_label(connect["connect_id"], chat_id)])}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, {:meeting_shared_source_unavailable, reason}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_meeting_shared_source}
    end
  end

  defp authorize_lark_labels(plan, user_id, labels) do
    with {:ok, provider, connect} <- lark_connect(plan) do
      expected_connect = connect["connect_id"]

      Enum.reduce_while(Enum.uniq(labels), :ok, fn label, :ok ->
        case String.split(label, "|") do
          ["scope", ^expected_connect, "@" <> ^user_id] ->
            {:cont, :ok}

          ["scope", ^expected_connect, chat_id] ->
            case recipient_chat(provider, connect, plan, chat_id, user_id) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end

          _ ->
            {:halt, {:error, :meeting_shared_source_required}}
        end
      end)
    end
  end

  defp lark_connect(plan) do
    provider = get_in(plan, ["publication_target", "provider"])

    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             plan["group_id"],
             get_in(plan, ["publication_target", "params", "connect_id"]),
             provider
           ),
         do: {:ok, provider, connect}
  end

  defp notice_chat(plan) do
    params = get_in(plan, ["publication_target", "params"]) || %{}
    params["chat_id"] || params["receive_id"]
  end

  defp shared_chat(provider, connect, plan, chat_id) when is_binary(chat_id) and chat_id != "" do
    if chat_id == notice_chat(plan), do: :ok, else: public_chat(provider, connect, chat_id)
  end

  defp shared_chat(_provider, _connect, _plan, _chat_id),
    do: {:error, :meeting_shared_source_required}

  # A recipient may be told what the notice chat says only when they are in it.
  defp recipient_chat(provider, connect, plan, chat_id, user_id) do
    cond do
      chat_id != notice_chat(plan) -> public_chat(provider, connect, chat_id)
      chat_member?(provider, connect, chat_id, user_id, nil, @lark_member_pages) -> :ok
      true -> {:error, :meeting_shared_source_not_visible}
    end
  end

  defp public_chat(provider, connect, chat_id) do
    case im(provider).call(nil, connect, provider <> ".get_chat", %{"chat_id" => chat_id}) do
      {:ok, %{} = chat} ->
        if chat["chat_mode"] == "group" and chat["chat_type"] == "public" and
             chat["external"] != true,
           do: :ok,
           else: {:error, :meeting_shared_source_required}

      _ ->
        {:error, :meeting_shared_source_unavailable}
    end
  end

  defp chat_member?(_provider, _connect, _chat_id, _user_id, _page_token, 0), do: false

  defp chat_member?(provider, connect, chat_id, user_id, page_token, pages_left) do
    params =
      %{"chat_id" => chat_id, "page_size" => 100}
      |> then(&if(page_token, do: Map.put(&1, "page_token", page_token), else: &1))

    case im(provider).call(nil, connect, provider <> ".list_chat_members", params) do
      {:ok, %{} = page} ->
        cond do
          Enum.any?(List.wrap(page["members"]), &(&1["member_id"] == user_id)) ->
            true

          page["has_more"] == true and is_binary(page["next_page_token"]) ->
            chat_member?(
              provider,
              connect,
              chat_id,
              user_id,
              page["next_page_token"],
              pages_left - 1
            )

          true ->
            false
        end

      _ ->
        false
    end
  end

  defp lark_page(provider, connect, "history", chat_id, args) do
    params =
      args
      |> Map.take(~w(page_token start_time end_time))
      |> Map.merge(%{"chat_id" => chat_id, "page_size" => @lark_page_size})

    im(provider).call(nil, connect, provider <> ".get_chat_history", params)
  end

  defp lark_page(provider, connect, "replies", _chat_id, args) do
    if is_binary(args["thread_id"]) and args["thread_id"] != "" do
      params =
        args
        |> Map.take(~w(thread_id page_token))
        |> Map.put("page_size", @lark_page_size)

      im(provider).call(nil, connect, provider <> ".get_thread_replies", params)
    else
      {:error, :invalid_meeting_shared_source}
    end
  end

  # A thread names no chat: every message read must be of the chat asked for.
  defp same_chat(messages, chat_id) when is_list(messages) do
    if Enum.all?(messages, &(is_map(&1) and &1["chat_id"] == chat_id)),
      do: :ok,
      else: {:error, :meeting_shared_source_required}
  end

  defp same_chat(_messages, _chat_id), do: {:error, :invalid_meeting_shared_source}

  defp im("lark"), do: SalixIM.Provider.Lark
  defp im("feishu"), do: SalixIM.Provider.Feishu
end
