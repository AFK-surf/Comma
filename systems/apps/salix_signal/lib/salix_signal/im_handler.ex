defmodule SalixSignal.IMHandler do
  @moduledoc """
  The product handler of every Signal account (`SalixSignal.Account.Handler`,
  docs/messaging-voice.md).

  Inbound messages: the admitted content is decoded and normalized here and
  handed to `SalixIM.SignalInbound.deliver/1`, which redeems claim codes or
  admits the message to the bound Group's Router. The sender's profile name
  (`SalixSignal.Account.profile_name/2`, stored data only) is its display
  name. Receipts, typing, sender-key-only containers, stories, stickers and
  call updates carry no Router input and are consumed. The account calls
  this handler from its delivery process, so it may download attachments
  and send on the account.

  Calls: an offer from a peer bound on this account rings; any other offer
  is refused as not permitted. A connected call is admitted to `salix_voice`
  through `SalixSignal.Carrier.admit/2` with the Group's `voice` connect as
  the delivery connect and the caller identity `{signal, <ACI>}`, so the
  Router answers with the voice operations.
  """

  @behaviour SalixSignal.Account.Handler

  require Logger

  alias SalixIM.{ProviderConnects, SignalConnects, SignalInbound}
  alias SalixSignal.{Account, Accounts, Attachments, IMPort, VoiceNote}
  alias SalixSignal.Messaging.Inbound
  alias SalixSignalProto.Attachment.Pointer
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Message.{Content, Wire}
  alias SalixSignalProto.ServiceId

  @long_text_type "text/x-signal-plain"
  @long_text_bytes 65_536

  # ---- messages ----

  @impl true
  def handle_inbound(account_id, seq, %Inbound{} = inbound) do
    case normalize(account_id, seq, inbound) do
      {:ok, event} -> event |> with_display_name(account_id) |> SignalInbound.deliver()
      :skip -> :ok
    end
  end

  defp with_display_name(event, account_id) do
    case Account.profile_name(account_id, event["sender"]) do
      {:ok, name} when is_binary(name) -> Map.put(event, "display_name", name)
      _ -> event
    end
  end

  @doc """
  Normalizes one admitted item to the `SalixIM.SignalInbound` event, or
  `:skip` when it carries no Router input.
  """
  def normalize(account_id, seq, %Inbound{outcome: :message, content: content} = inbound)
      when is_binary(content) and is_binary(inbound.sender) do
    case Content.decode(content) do
      {:ok, :data, %Wire.Content{data_message: %Wire.DataMessage{} = data}} ->
        data_event(account_id, seq, inbound, data)

      {:ok, :edit, %Wire.Content{edit_message: %Wire.EditMessage{} = edit}} ->
        edit_event(account_id, seq, inbound, edit)

      _other ->
        :skip
    end
  end

  def normalize(_account_id, _seq, _inbound), do: :skip

  defp data_event(account_id, seq, inbound, data) do
    base = base_event(account_id, seq, inbound, data)

    cond do
      is_nil(base) ->
        :skip

      data.story_context != nil or data.group_call_update != nil ->
        :skip

      data.reaction != nil ->
        reaction_event(base, data.reaction)

      data.remote_delete != nil and is_integer(data.remote_delete.target_message_timestamp) ->
        {:ok,
         Map.merge(base, %{
           "type" => "delete",
           "target_timestamp" => data.remote_delete.target_message_timestamp
         })}

      text(data.body) == "" and data.attachments == [] ->
        # Timer, profile-key and other control updates.
        :skip

      true ->
        {:ok, message_fields(base, account_id, data)}
    end
  end

  defp edit_event(account_id, seq, inbound, %Wire.EditMessage{data_message: data} = edit)
       when is_integer(edit.original_message_timestamp) and not is_nil(data) do
    case base_event(account_id, seq, inbound, data) do
      nil ->
        :skip

      base ->
        {:ok,
         base
         |> message_fields(account_id, data)
         |> Map.merge(%{"type" => "edit", "target_timestamp" => edit.original_message_timestamp})}
    end
  end

  defp edit_event(_account_id, _seq, _inbound, _edit), do: :skip

  defp base_event(account_id, seq, inbound, data) do
    case chat(inbound, data) do
      nil ->
        nil

      chat ->
        %{
          "account_id" => account_id,
          "seq" => seq,
          "guid" => guid(inbound.guid),
          "sender" => String.downcase(inbound.sender),
          "display_name" => nil,
          "timestamp" => inbound.timestamp,
          "server_timestamp" => inbound.server_timestamp,
          "chat" => chat,
          "type" => "message"
        }
    end
  end

  # The envelope GUID arrives as the 16 raw bytes of a UUID. Router input is
  # JSON text, so it carries the UUID's text form; raw bytes are not UTF-8
  # and would fail every append of this message.
  defp guid(<<_::binary-size(16)>> = bytes), do: ServiceId.uuid_string(bytes)
  defp guid(guid) when is_binary(guid), do: if(String.valid?(guid), do: guid)
  defp guid(_guid), do: nil

  # A group message names its group by master key (data message field 15);
  # a sender-key message also carries the group identifier.
  defp chat(inbound, data) do
    case data.group_v2 do
      %Wire.GroupContext{master_key: <<_::binary-size(32)>> = master_key} ->
        %{
          "kind" => "group",
          "peer" => IMPort.group_peer(Params.from_master_key(master_key).group_id)
        }

      %Wire.GroupContext{} ->
        nil

      nil when is_binary(inbound.group_id) and byte_size(inbound.group_id) == 32 ->
        %{"kind" => "group", "peer" => IMPort.group_peer(inbound.group_id)}

      nil ->
        %{"kind" => "user", "peer" => String.downcase(inbound.sender)}
    end
  end

  defp reaction_event(base, %Wire.Reaction{} = reaction) do
    with {:ok, author} <- author(reaction.target_author_aci, reaction.target_author_aci_string),
         emoji when emoji != "" <- text(reaction.emoji),
         true <- is_integer(reaction.target_message_timestamp) do
      {:ok,
       Map.merge(base, %{
         "type" => "reaction",
         "reaction" => %{
           "emoji" => emoji,
           "remove" => reaction.remove == true,
           "target_author" => author,
           "target_timestamp" => reaction.target_message_timestamp
         }
       })}
    else
      _ -> :skip
    end
  end

  defp message_fields(base, account_id, data) do
    environment = environment(account_id)

    {long_text, attachments} =
      Enum.split_with(data.attachments, &(&1.content_type == @long_text_type))

    base
    |> Map.put("text", long_text(long_text, environment) || text(data.body))
    |> Map.put("quote", quote_fields(data.quote))
    |> Map.put("attachments", Enum.map(attachments, &attachment(&1, environment)))
  end

  # The body holds at most 2,048 bytes; a longer text arrives as a
  # `text/x-signal-plain` attachment (CRS-05). Fall back to the body.
  defp long_text([pointer | _], environment) do
    case Attachments.download(pointer, download_opts(environment, @long_text_bytes)) do
      {:ok, text} -> if String.valid?(text), do: text
      _ -> nil
    end
  end

  defp long_text([], _environment), do: nil

  defp quote_fields(%Wire.Quote{quoted_message_timestamp: timestamp} = quoted)
       when is_integer(timestamp) do
    case author(quoted.author_aci, quoted.author_aci_string) do
      {:ok, author} ->
        %{"timestamp" => timestamp, "author" => author, "text" => text(quoted.text)}

      _ ->
        nil
    end
  end

  defp quote_fields(_quoted), do: nil

  defp attachment(%Pointer{} = pointer, environment) do
    %{
      "file_name" => pointer.file_name,
      "content_type" => pointer.content_type,
      "size" => pointer.size,
      "voice_note" => VoiceNote.voice_note?(pointer),
      "to_blob" => fn agent_id ->
        with {:ok, data} <-
               Attachments.download(
                 pointer,
                 download_opts(environment, SalixStore.Blob.max_bytes())
               ),
             {:ok, ref} <- SalixStore.Blob.put(agent_id, data) do
          {:ok, %{ref: ref, size: byte_size(data)}}
        end
      end
    }
  end

  defp download_opts(environment, max_bytes) do
    Keyword.merge(
      [environment: environment, max_bytes: max_bytes],
      Application.get_env(:salix_signal, :im_download_opts, [])
    )
  end

  defp environment(account_id) do
    case Accounts.get(account_id) do
      {:ok, %{environment: environment}} when environment in [:production, :staging] ->
        environment

      _ ->
        :production
    end
  end

  defp author(<<_::binary-size(16)>> = bytes, _string),
    do: {:ok, ServiceId.uuid_string(bytes)}

  defp author(_bytes, string) when is_binary(string) do
    case ServiceId.aci_from_string(string) do
      {:ok, bytes} -> {:ok, ServiceId.uuid_string(bytes)}
      :error -> :error
    end
  end

  defp author(_bytes, _string), do: :error

  defp text(value) when is_binary(value) do
    if String.valid?(value), do: value, else: ""
  end

  defp text(_value), do: ""

  # ---- calls ----

  @impl true
  def incoming_call(account_id, %{peer_aci: peer} = _info) do
    case SignalConnects.find_signal_connect(account_id, peer) do
      {:ok, connect} ->
        if SalixVoice.group_busy?(connect["group_id"]), do: :busy, else: :ring

      _ ->
        :needs_permission
    end
  end

  def incoming_call(_account_id, _info), do: :needs_permission

  @impl true
  def admit_call(account_id, %{peer_aci: peer, call_id: signal_call_id}, connection)
      when is_pid(connection) do
    with {:ok, connect} <- SignalConnects.find_signal_connect(account_id, peer),
         {:ok, voice} <-
           ProviderConnects.ensure_voice_im_connect(connect["tenant_id"], connect["group_id"]) do
      SalixSignal.Carrier.admit(connection, %{
        tenant_id: connect["tenant_id"],
        group_id: connect["group_id"],
        connect_id: voice["connect_id"],
        caller_aci: String.downcase(peer),
        signal_call_id: signal_call_id,
        display_name: connect["binding"]["display_name"]
      })
    else
      {:error, :not_found} -> {:error, :not_bound}
      {:error, _reason} = error -> error
    end
  end

  def admit_call(_account_id, _info, _connection), do: {:error, :not_bound}

  # A bound Signal group rang: join its call when the Group's one voice call
  # slot is free. The event callback must return quickly, so the join runs
  # in a task. The account runtime joins with its own plug-ins
  # (`SalixSignal.Account.join_group_call/3`).
  @impl true
  def handle_event(
        account_id,
        {:group_call_ring, <<_::binary-size(32)>> = group_id, _ring, :ring, _sender}
      ) do
    with {:ok, connect} <-
           SignalConnects.find_signal_connect(account_id, IMPort.group_peer(group_id)),
         false <- SalixVoice.group_busy?(connect["group_id"]) do
      {:ok, _pid} = Task.start(fn -> join_group_call(account_id, group_id, connect) end)
    end

    :ok
  end

  def handle_event(account_id, {:account_stopped, reason}) do
    Logger.warning("signal_account_stopped", account_id: account_id, reason: inspect(reason))
  end

  def handle_event(_account_id, _event), do: :ok

  defp join_group_call(account_id, group_id, connect) do
    admit = fn session, %{era_id: era_id} ->
      with {:ok, voice} <-
             ProviderConnects.ensure_voice_im_connect(connect["tenant_id"], connect["group_id"]) do
        SalixSignal.Carrier.admit_group_call(session, %{
          tenant_id: connect["tenant_id"],
          group_id: connect["group_id"],
          connect_id: voice["connect_id"],
          signal_group_id: group_id,
          era_id: era_id,
          display_name: connect["binding"]["display_name"]
        })
      end
    end

    case Account.join_group_call(account_id, group_id, admit: admit) do
      {:ok, _session} -> :ok
      {:error, reason} -> Logger.info("signal_group_call_join_failed", reason: inspect(reason))
    end
  end
end
