defmodule SalixIM.Provider.Signal do
  @moduledoc """
  Router operations on Signal (`signal.*`). Contract: `docs/messaging-voice.md`.

  Every operation addresses a peer that is bound to this Signal connect
  (`SalixIM.SignalConnects`): a private chat (the peer's ACI) or a Signal
  group (`group:<id>`). The binding names the Comma Signal account that talks
  with the peer, so the Router never picks an account or an arbitrary
  recipient. `chat_id` defaults to the chat of the current Signal source.

  The account runtime is reached through `SalixIM.Ports.SignalAccount`.
  """

  alias SalixIM.Ports.SignalAccount
  alias SalixIM.Provider.Util
  alias SalixIM.SignalConnects

  # One message carries at most 16,000 bytes of text. The account runtime
  # sends text over the 2,048-byte body limit of CRS-05 as a long-text
  # attachment (`SalixSignal.Account`).
  @max_text_bytes 16_000
  @max_attachment_bytes 26_214_400
  @max_members 20

  @ops ~w(signal.send_message signal.react signal.edit_message signal.delete_message
    signal.list_groups signal.join_group signal.add_members signal.remove_members
    signal.leave_group)

  @doc "The Signal operation names."
  def operations, do: @ops

  def call(agent_id, connect, api, params) when is_map(connect) do
    params = if is_map(params), do: params, else: %{}

    with true <- api in @ops || {:error, "Unsupported Signal operation"},
         :ok <- Util.ensure_connected(connect) do
      operation(api, agent_id, connect, params)
    end
  end

  # ---- operations ----

  defp operation("signal.send_message", agent_id, connect, params) do
    with {:ok, binding} <- chat_binding(connect, params),
         {:ok, text} <- message_text(params["text"], params["path"]),
         {:ok, attachments} <- attachments(agent_id, binding, params),
         {:ok, quoted} <- quote_param(params) do
      opts = [attachments: attachments] ++ if(quoted, do: [quote: quoted], else: [])

      with {:ok, result} <-
             binding["account_id"]
             |> SignalAccount.send_text(binding["peer"], text, opts)
             |> error_text() do
        stamp = timestamp(result)
        {:ok, %{"chat_id" => binding["peer"], "timestamp" => stamp, "timestamps" => [stamp]}}
      end
    end
  end

  defp operation("signal.react", _agent_id, connect, params) do
    with {:ok, binding} <- chat_binding(connect, params),
         {:ok, emoji} <- emoji(params["emoji"]),
         {:ok, author, timestamp} <- target(connect, params, :source) do
      SignalAccount.send_reaction(
        binding["account_id"],
        binding["peer"],
        emoji,
        author,
        timestamp,
        params["remove"] == true
      )
      |> sent(binding)
    end
  end

  defp operation("signal.edit_message", _agent_id, connect, params) do
    with {:ok, binding} <- chat_binding(connect, params),
         {:ok, text} <- message_text(params["text"], nil),
         {:ok, _author, timestamp} <- target(connect, params, :own) do
      binding["account_id"]
      |> SignalAccount.send_edit(binding["peer"], timestamp, text)
      |> sent(binding)
    end
  end

  defp operation("signal.delete_message", _agent_id, connect, params) do
    with {:ok, binding} <- chat_binding(connect, params),
         {:ok, _author, timestamp} <- target(connect, params, :own) do
      binding["account_id"]
      |> SignalAccount.send_delete(binding["peer"], timestamp)
      |> sent(binding)
    end
  end

  defp operation("signal.list_groups", _agent_id, connect, _params) do
    groups = Enum.filter(bindings(connect), &(&1["kind"] == "group"))

    titles =
      groups
      |> Enum.map(& &1["account_id"])
      |> Enum.uniq()
      |> Enum.flat_map(fn account_id ->
        case SignalAccount.groups(account_id) do
          {:ok, list} -> Enum.map(list, &{{account_id, &1["peer"]}, &1})
          _ -> []
        end
      end)
      |> Map.new()

    {:ok,
     %{
       "groups" =>
         Enum.map(groups, fn binding ->
           info = Map.get(titles, {binding["account_id"], binding["peer"]}, %{})

           %{
             "chat_id" => binding["peer"],
             "title" => info["title"] || binding["display_name"],
             "member_count" => info["member_count"],
             "admin" => info["admin"]
           }
         end)
     }}
  end

  defp operation("signal.join_group", _agent_id, connect, params) do
    with {:ok, url} <- invite_url(params["invite_url"]),
         {:ok, account_id} <- account_for_join(connect),
         {:ok, %{"peer" => peer} = joined} <-
           join_error_text(SignalAccount.join_group(account_id, url)),
         {:ok, bound} <-
           SignalConnects.bind_peer(
             connect["tenant_id"],
             connect["group_id"],
             account_id,
             %{"kind" => "group", "peer" => peer, "display_name" => joined["title"]},
             "router:join_group"
           ) do
      {:ok, %{"status" => joined["status"], "chat_id" => bound["binding"]["peer"]}}
    else
      {:error, :signal_peer_in_use} ->
        {:error, "This Signal group is already bound to another Comma group"}

      other ->
        error_text(other)
    end
  end

  defp operation(api, _agent_id, connect, params)
       when api in ["signal.add_members", "signal.remove_members"] do
    action = if api == "signal.add_members", do: :add, else: :remove

    with {:ok, binding} <- chat_binding(connect, params),
         true <- binding["kind"] == "group" || {:error, "chat_id must name a Signal group"},
         {:ok, members} <- members(params["members"]) do
      binding["account_id"]
      |> SignalAccount.change_members(binding["peer"], action, members)
      |> error_text()
    end
  end

  defp operation("signal.leave_group", _agent_id, connect, params) do
    with {:ok, binding} <- chat_binding(connect, params),
         true <- binding["kind"] == "group" || {:error, "chat_id must name a Signal group"},
         {:ok, result} <-
           error_text(SignalAccount.leave_group(binding["account_id"], binding["peer"])) do
      _ =
        SignalConnects.remove_binding(
          connect["tenant_id"],
          connect["group_id"],
          binding["binding_id"]
        )

      {:ok, Map.put(result, "left", true)}
    end
  end

  # ---- addressing ----

  # The chat must be a peer bound to this connect. Its binding names the
  # account; the Router cannot choose one.
  defp chat_binding(connect, params) do
    chat_id =
      case param(params, "chat_id") do
        "" -> origin_context(connect)["chat_id"] || ""
        chat_id -> chat_id
      end

    cond do
      chat_id == "" ->
        {:error, "chat_id is required outside a Signal source"}

      binding = SignalConnects.binding_for_peer(connect, chat_id) ->
        {:ok, binding}

      true ->
        {:error, "This Signal connect can only address chats bound to it"}
    end
  end

  defp account_for_join(connect) do
    origin_peer = origin_context(connect)["chat_id"]

    case {origin_peer && SignalConnects.binding_for_peer(connect, origin_peer),
          connect |> bindings() |> Enum.map(& &1["account_id"]) |> Enum.uniq()} do
      {%{"account_id" => account_id}, _} -> {:ok, account_id}
      {_, [account_id]} -> {:ok, account_id}
      _ -> {:error, "Join a Signal group from a bound Signal chat"}
    end
  end

  # The trusted origin is the Signal message this Router round answers. Only
  # an origin of this connect supplies defaults.
  defp origin_context(connect) do
    case SalixIM.Provider.current_tool_context()["trusted_origin"] do
      %{"provider" => "signal", "provider_context" => %{} = context} ->
        if context["connect_id"] == connect["connect_id"], do: context, else: %{}

      _ ->
        %{}
    end
  end

  # :source defaults to the current source message; :own requires an
  # explicit timestamp of a message this account sent.
  defp target(connect, params, default) do
    timestamp = param(params, "target_timestamp")
    author = param(params, "target_author")
    context = origin_context(connect)

    {timestamp, author} =
      if timestamp == "" and default == :source,
        do: {to_string(context["message_id"] || ""), to_string(context["from_user_id"] || "")},
        else: {timestamp, author}

    case Integer.parse(timestamp) do
      {ts, ""} when ts > 0 ->
        if default == :source and author == "",
          do: {:error, "target_author is required with target_timestamp"},
          else: {:ok, author, ts}

      _ ->
        {:error, "target_timestamp must be a message timestamp in milliseconds"}
    end
  end

  # ---- content ----

  defp message_text(text, path) do
    text = if is_binary(text), do: String.trim(text), else: ""

    cond do
      text == "" and param(%{"path" => path}, "path") != "" -> {:ok, ""}
      text == "" -> {:error, "text is required"}
      not String.valid?(text) -> {:error, "text must be valid UTF-8"}
      byte_size(text) > @max_text_bytes -> {:error, "text is at most #{@max_text_bytes} bytes"}
      true -> {:ok, text}
    end
  end

  defp attachments(agent_id, binding, params) do
    case param(params, "path") do
      "" ->
        {:ok, []}

      path ->
        with {:ok, upload} <- Util.read_agent_upload(agent_id, path),
             true <-
               byte_size(upload.data) <= @max_attachment_bytes ||
                 {:error, "attachments are at most 25 MiB"},
             {:ok, attachment} <-
               binding["account_id"]
               |> SignalAccount.upload_attachment(upload.data,
                 content_type: MIME.from_path(upload.filename),
                 file_name: upload.filename
               )
               |> error_text() do
          {:ok, [attachment]}
        end
    end
  end

  defp quote_param(params) do
    case {param(params, "quote_timestamp"), param(params, "quote_author")} do
      {"", _} ->
        {:ok, nil}

      {timestamp, author} ->
        case Integer.parse(timestamp) do
          {ts, ""} when ts > 0 and author != "" -> {:ok, %{timestamp: ts, author: author}}
          _ -> {:error, "quote_timestamp and quote_author must name one message"}
        end
    end
  end

  defp sent(result, binding) do
    with {:ok, result} <- error_text(result) do
      {:ok, %{"chat_id" => binding["peer"], "timestamp" => timestamp(result)}}
    end
  end

  defp timestamp(%{} = result), do: result["timestamp"] || result[:timestamp]
  defp timestamp(_result), do: nil

  defp emoji(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 64 and String.valid?(value),
      do: {:ok, value},
      else: {:error, "emoji must be one emoji"}
  end

  defp emoji(_value), do: {:error, "emoji is required"}

  defp invite_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: "https", host: "signal.group", fragment: fragment}
      when is_binary(fragment) and fragment != "" and byte_size(value) <= 2_048 ->
        {:ok, value}

      _ ->
        {:error, "invite_url must be a https://signal.group/# link"}
    end
  end

  defp invite_url(_value), do: {:error, "invite_url is required"}

  defp members(list) when is_list(list) and list != [] and length(list) <= @max_members do
    members =
      list |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase())) |> Enum.uniq()

    if Enum.all?(members, &Regex.match?(~r/\A[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/, &1)),
      do: {:ok, members},
      else: {:error, "members must be Signal ACIs"}
  end

  defp members(_list), do: {:error, "members must list 1 to #{@max_members} Signal ACIs"}

  # ---- results ----

  defp join_error_text({:error, reason})
       when reason in [:link_disabled, :not_found, :invalid, :unknown_version],
       do:
         coded(
           "signal_group_link_invalid",
           "signal_group_link_invalid: ask a group admin for a current invite link"
         )

  defp join_error_text(result), do: error_text(result)

  defp error_text({:ok, _} = ok), do: ok
  defp error_text({:error, %{"error_class" => _, "message" => _}} = error), do: error
  defp error_text({:error, message}) when is_binary(message), do: {:error, message}
  defp error_text({:error, :signal_unavailable}), do: {:error, "signal_unavailable"}

  defp error_text({:error, reason}) when reason in [:not_started, :fenced],
    do: {:error, "signal_account_unavailable: try again shortly"}

  # These codes are lasting target or account states. A stable error class
  # keeps that fact in model context after repair removes the diagnostic text.
  defp error_text({:error, :unregistered}), do: coded("signal_recipient_unregistered")
  defp error_text({:error, :forbidden}), do: coded("signal_forbidden")

  defp error_text({:error, reason}) when reason in [:not_a_member, :unknown_group],
    do:
      coded(
        "signal_group_unavailable",
        "signal_group_unavailable: this account is not a member of that group"
      )

  defp error_text({:error, :no_profile_credential}),
    do:
      coded(
        "signal_profile_unavailable",
        "signal_profile_unavailable: the account needs a published Signal profile before it can join groups"
      )

  defp error_text({:error, {:forbidden, _reason}}), do: coded("signal_forbidden")

  defp error_text({:error, :conflict}),
    do: coded("signal_group_changed", "signal_group_changed: retry with the current group state")

  defp error_text({:error, :invalid_member}), do: {:error, "members must be Signal ACIs"}

  defp error_text({:error, {:rate_limited, seconds}}),
    do: coded("signal_rate_limited", "signal_rate_limited: retry after #{seconds || 60} seconds")

  defp error_text({:error, {:challenge_required, _challenge}}),
    do:
      coded(
        "signal_challenge_required",
        "signal_challenge_required: an operator must answer the account challenge"
      )

  defp error_text({:error, _reason}), do: {:error, "signal_send_failed"}
  defp error_text(_other), do: {:error, "signal_send_failed"}

  defp coded(code, message \\ nil),
    do: {:error, %{"error_class" => code, "message" => message || code}}

  defp bindings(connect) do
    connect |> Map.get("bindings", Map.get(connect, "signal_bindings", [])) |> List.wrap()
  end

  defp param(params, key) do
    case params[key] do
      value when is_binary(value) -> String.trim(value)
      value when is_integer(value) -> Integer.to_string(value)
      _ -> ""
    end
  end
end
