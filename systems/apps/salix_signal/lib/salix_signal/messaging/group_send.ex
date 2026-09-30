defmodule SalixSignal.Messaging.GroupSend do
  @moduledoc """
  Sends one content message to the members of a stored group (CRS-09c
  section 6, CRS-06 section 10.2, CRS-07 §3.3 and §4).

  The group comes from the account's store (`SalixSignal.Messaging.Store`
  callback `group/2`): its decrypted state, its send endorsements and this
  device's own sender key. The recipients are the full members other than
  this account.

  1. Every recipient gets a session with each of its devices (CRS-07 §4).
  2. Recipients that are registered and have an endorsement use the
     sender-key path when there are at least 2 of them (section 6.4);
     everyone else gets individual sealed or identified 1:1 sends with the
     group ID set.
  3. Sender-key path: devices that lack the current distribution message
     get it first, as a 1:1 message with only content field 7, hint
     implicit and the group ID (section 6.2). The content is then encrypted
     once with the sender key. The advanced sender key is committed before
     the request, so a crash never reuses a message key. The sealed inner
     message (type 7, the sender certificate, the hint and the group ID) is
     sealed once for all devices and sent to `PUT
     /v1/messages/multi_recipient` with a group send token for exactly those
     recipients (section 6.3).
  4. A 409 or 410 corrects the device lists and sessions, marks the
     affected devices as not holding the sender key, and sends again with
     the same timestamp, at most `max_send_attempts` times in total. A
     device that a 1:1 send corrected is marked the same way, for every
     group (`Pipeline.sender_key_targets/3`). A 401 or 404 sends to the
     sender-key recipients individually instead, as the official clients
     do (CRS-07 §3.3). Recipients listed as unregistered are marked so.

  Sent content is kept per recipient device, as for 1:1 sends, so a retry
  request can be answered (CRS-07 §6.3).
  """

  alias SalixSignal.Messaging.{Api, Pipeline}
  alias SalixSignal.Service.Response
  alias SalixSignalProto.{Address, SealedSender, ServiceId}
  alias SalixSignalProto.Group.{Endorsements, Params, State}
  alias SalixSignalProto.Message.{Content, Padding, Wire}
  alias SalixSignalProto.SealedSender.Inner
  alias SalixSignalProto.SenderKey.Sending

  @implicit 2
  @resendable 1
  # A token must still be valid when the service checks it.
  @token_margin_s 3_600

  @doc """
  Sends a group text message with the group context (CRS-09b section 9).
  `opts`: `:timestamp` and the data options of
  `SalixSignalProto.Message.Content.text/3` (`:quote`, `:mentions`,
  `:styles`, `:attachments`).
  """
  @spec send_text(Pipeline.t(), <<_::256>>, String.t(), keyword()) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def send_text(pipeline, group_id, body, opts \\ []) do
    {timestamp, opts} = Keyword.pop(opts, :timestamp)

    member_send(pipeline, group_id, [timestamp: timestamp], fn timestamp, context ->
      Content.text(timestamp, body, [group: context] ++ opts)
    end)
  end

  @doc """
  Sends a reaction to the group message `(target_author, target_timestamp)`
  (CRS-05 section 5.5); `remove: true` removes it. A target author that is
  not an ACI string is `{:error, :invalid_author}`.
  """
  @spec send_reaction(
          Pipeline.t(),
          <<_::256>>,
          String.t(),
          String.t(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def send_reaction(pipeline, group_id, emoji, target_author, target_timestamp, opts \\ []) do
    case Pipeline.reaction_author(target_author) do
      {:ok, author} ->
        remove = Keyword.get(opts, :remove, false)

        member_send(pipeline, group_id, [], fn timestamp, context ->
          Content.reaction(timestamp, emoji, author, target_timestamp,
            remove: remove,
            group: context
          )
        end)

      :error ->
        {:error, :invalid_author, pipeline}
    end
  end

  @doc """
  Replaces the text of this account's group message sent at
  `target_timestamp` (CRS-05 section 5.8; the replacement carries the group
  context). `opts`: `:attachments` (a long-text attachment).
  """
  @spec send_edit(Pipeline.t(), <<_::256>>, non_neg_integer(), String.t(), keyword()) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def send_edit(pipeline, group_id, target_timestamp, body, opts \\ []) do
    member_send(pipeline, group_id, [], fn timestamp, context ->
      Content.edit(timestamp, target_timestamp, body,
        group: context,
        attachments: Keyword.get(opts, :attachments, [])
      )
    end)
  end

  @doc "Deletes this account's group message sent at `target_timestamp` (CRS-05 section 5.5)."
  @spec send_remote_delete(Pipeline.t(), <<_::256>>, non_neg_integer()) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def send_remote_delete(pipeline, group_id, target_timestamp) do
    member_send(pipeline, group_id, [], fn timestamp, context ->
      Content.remote_delete(timestamp, target_timestamp, group: context)
    end)
  end

  @doc """
  Sends a typing message in the group: the 32-byte group identifier in the
  typing message (CRS-05 section 6.2), online true, urgent false, implicit
  hint (CRS-07 §8).
  """
  @spec send_typing(Pipeline.t(), <<_::256>>, :started | :stopped) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def send_typing(pipeline, group_id, action) when action in [:started, :stopped] do
    member_send(
      pipeline,
      group_id,
      [online: true, urgent: false, content_hint: @implicit],
      fn timestamp, _context -> Content.typing(timestamp, action, group_id) end
    )
  end

  @doc """
  Sends the group-call-update data message with `era_id` to the group,
  urgent (CRS-14 section 3; CRS-05 section 5.1 field 19).
  """
  @spec send_call_update(Pipeline.t(), <<_::256>>, String.t()) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def send_call_update(pipeline, group_id, era_id) when is_binary(era_id) do
    member_send(pipeline, group_id, [urgent: true], fn timestamp, context ->
      Wire.Content.encode(%Wire.Content{
        data_message: %Wire.DataMessage{
          timestamp: timestamp,
          group_v2: %Wire.GroupContext{master_key: context.master_key, revision: context.revision},
          group_call_update: %Wire.GroupCallUpdate{era_id: era_id}
        }
      })
    end)
  end

  # A message of this account to a group it is a full member of: the
  # content gets the message timestamp and the group context (CRS-09b
  # section 9). A group without stored state is `:unknown_group`; a group
  # the account is no longer a full member of is `:not_a_member`.
  defp member_send(pipeline, group_id, opts, build) do
    with {:ok, group} <- member_group(pipeline, group_id) do
      {timestamp, pipeline} =
        case Keyword.get(opts, :timestamp) do
          nil -> Pipeline.timestamp(pipeline)
          timestamp -> {timestamp, pipeline}
        end

      context = %{master_key: group.master_key, revision: group.revision}
      content = build.(timestamp, context)
      opts = Keyword.put(opts, :timestamp, timestamp)
      send_content(pipeline, group_id, content, opts)
    else
      {:error, reason} -> {:error, reason, pipeline}
    end
  end

  @doc false
  # The stored group when this account is one of its full members.
  def member_group(pipeline, group_id) do
    case Pipeline.read(pipeline, :group, [group_id]) do
      %{state: %State{} = state} = group ->
        own = {:aci, pipeline.account.aci_uuid}
        if own in State.member_service_ids(state), do: {:ok, group}, else: {:error, :not_a_member}

      _ ->
        {:error, :unknown_group}
    end
  end

  @doc """
  Sends the serialized content container `content` to the group's members.
  Options: `:timestamp` (default now), `:content_hint` (default 1),
  `:urgent` (default true), `:online` (default false), and `:members`: ACI
  strings that limit the recipients to those full members (default: every
  full member).

  Returns `{:ok, %{timestamp, recipients, sender_key, unregistered,
  failed}, pipeline}`: the members that the service accepted the message
  for, those of them reached with the sender key, those it reported
  unregistered, and `[{member, reason}]` for the others.
  """
  @spec send_content(Pipeline.t(), <<_::256>>, binary(), keyword()) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def send_content(pipeline, group_id, content, opts \\ []) do
    case Pipeline.read(pipeline, :group, [group_id]) do
      %{state: %State{} = state} ->
        {timestamp, pipeline} =
          case Keyword.fetch(opts, :timestamp) do
            {:ok, timestamp} -> {timestamp, pipeline}
            :error -> Pipeline.timestamp(pipeline)
          end

        options = %{
          group_id: group_id,
          timestamp: timestamp,
          hint: Keyword.get(opts, :content_hint, @resendable),
          urgent: Keyword.get(opts, :urgent, true),
          online: Keyword.get(opts, :online, false),
          members: Keyword.get(opts, :members)
        }

        send_group(pipeline, state, content, options)

      _ ->
        {:error, :unknown_group, pipeline}
    end
  end

  defp send_group(pipeline, state, content, options) do
    own = pipeline.account.aci

    members =
      for {:aci, _} = id <- State.member_service_ids(state),
          name = ServiceId.to_string(id),
          name != own,
          options.members == nil or name in options.members,
          do: name

    result = %{
      timestamp: options.timestamp,
      recipients: [],
      sender_key: [],
      unregistered: [],
      failed: []
    }

    with {:ok, pipeline, ready, result} <- prepare(pipeline, members, result) do
      group = Pipeline.read(pipeline, :group, [options.group_id])

      {sender_key, individual} =
        Sending.partition_recipients(ready, &eligible?(pipeline, group, &1))

      {pipeline, certificate} =
        if sender_key == [], do: {pipeline, nil}, else: Pipeline.sender_certificate(pipeline)

      {sender_key, individual} =
        if certificate == nil, do: {[], sender_key ++ individual}, else: {sender_key, individual}

      with {:ok, pipeline, result, fallback} <-
             sender_key_send(pipeline, sender_key, content, options, certificate, result, 1),
           {:ok, pipeline, result} <-
             individual_send(pipeline, fallback ++ individual, content, options, result) do
        {:ok, result, pipeline}
      end
    end
  end

  # Sessions with every device of every member. A member without devices
  # is unregistered and is not sent to.
  defp prepare(pipeline, members, result) do
    Enum.reduce_while(members, {:ok, pipeline, [], result}, fn member,
                                                               {:ok, pipeline, ready, result} ->
      case Pipeline.prepare_sessions(pipeline, member) do
        {:ok, pipeline, _events} ->
          {:cont, {:ok, pipeline, ready ++ [member], result}}

        {:error, :fenced, pipeline} ->
          {:halt, {:error, :fenced, pipeline}}

        {:error, :unregistered, pipeline} ->
          {:cont,
           {:ok, pipeline, ready, %{result | unregistered: result.unregistered ++ [member]}}}

        {:error, reason, pipeline} ->
          {:cont, {:ok, pipeline, ready, %{result | failed: result.failed ++ [{member, reason}]}}}
      end
    end)
  end

  defp eligible?(pipeline, group, member) do
    endorsement(group, member, Pipeline.clock(pipeline)) != nil and
      not Pipeline.contact_state(pipeline, member).unregistered?
  end

  defp endorsement(
         %{endorsements: %{expiration: expiration, by_member: by_member}},
         member,
         now_ms
       )
       when expiration - div(now_ms, 1000) > @token_margin_s do
    {:ok, id} = ServiceId.parse(member)
    Map.get(by_member, id)
  end

  defp endorsement(_group, _member, _now_ms), do: nil

  # --- sender-key path --------------------------------------------------------

  defp sender_key_send(pipeline, [], _content, _options, _certificate, result, _attempt),
    do: {:ok, pipeline, result, []}

  defp sender_key_send(pipeline, members, _content, _options, _certificate, result, attempt)
       when attempt > pipeline.config.max_send_attempts do
    failed = for member <- members, do: {member, :too_many_attempts}
    {:ok, pipeline, %{result | failed: result.failed ++ failed}, []}
  end

  defp sender_key_send(pipeline, members, content, options, certificate, result, attempt) do
    group = Pipeline.read(pipeline, :group, [options.group_id])
    sending = group.sending || Sending.new()

    with {:ok, pipeline, sending, members, result, fallback} <-
           distribute(pipeline, sending, members, options, result),
         {:ok, message, sending} <- Sending.encrypt(sending, Padding.pad(content)),
         :ok <-
           write(pipeline, [
             {:put_group, options.group_id, %{group | sending: sending}},
             {:put_send_timestamp, options.timestamp}
           ]) do
      if members == [] do
        {:ok, pipeline, result, fallback}
      else
        post(pipeline, group, members, message, content, options, certificate, result, attempt)
        |> then(fn
          {:ok, pipeline, result, more} -> {:ok, pipeline, result, fallback ++ more}
          other -> other
        end)
      end
    else
      {:error, :fenced} -> {:error, :fenced, pipeline}
      {:error, :fenced, pipeline} -> {:error, :fenced, pipeline}
      {:error, reason} -> {:error, {:sender_key, reason}, pipeline}
    end
  end

  # CRS-09c section 6.2. A member whose distribution send fails is sent to
  # individually instead.
  defp distribute(pipeline, sending, members, options, result) do
    distribution =
      Wire.Content.encode(%Wire.Content{
        sender_key_distribution: Sending.distribution_message(sending)
      })

    Enum.reduce_while(members, {:ok, pipeline, sending, [], result, []}, fn member,
                                                                            {:ok, pipeline,
                                                                             sending, kept,
                                                                             result, fallback} ->
      targets = targets(pipeline, member)

      if Sending.needs_distribution(sending, targets) == [] do
        {:cont, {:ok, pipeline, sending, kept ++ [member], result, fallback}}
      else
        case Pipeline.send_content(pipeline, member, distribution,
               content_hint: @implicit,
               group_id: options.group_id,
               urgent: options.urgent,
               keep_sent: false
             ) do
          {:ok, info, pipeline} ->
            {:ok, id} = ServiceId.parse(member)

            # Targets with the devices' generations after this send, which
            # may have corrected the device list (CRS-07 §4).
            sending =
              sending
              |> Sending.forget_delivered(for d <- info.devices, do: {id, d})
              |> Sending.mark_delivered(
                Pipeline.sender_key_targets(pipeline, member, info.devices)
              )

            {:cont, {:ok, pipeline, sending, kept ++ [member], result, fallback}}

          {:error, :fenced, pipeline} ->
            {:halt, {:error, :fenced, pipeline}}

          {:error, :unregistered, pipeline} ->
            {:cont,
             {:ok, pipeline, sending, kept,
              %{result | unregistered: result.unregistered ++ [member]}, fallback}}

          {:error, _reason, pipeline} ->
            {:cont, {:ok, pipeline, sending, kept, result, fallback ++ [member]}}
        end
      end
    end)
  end

  defp post(pipeline, group, members, message, content, options, certificate, result, attempt) do
    params = Params.from_master_key(group.master_key)

    inner =
      Inner.encode(%Inner{
        type: :sender_key,
        certificate: certificate,
        content: message,
        content_hint: options.hint,
        group_id: options.group_id
      })

    recipients = Enum.map(members, &recipient(pipeline, &1))
    upload = SealedSender.seal_multi(inner, pipeline.account.identities.aci, recipients)
    ids = Enum.map(recipients, & &1.service_id)

    %{expiration: expiration, by_member: by_member} = group.endorsements
    {:ok, token} = Sending.group_send_token(params, by_member, ids, expiration)

    response =
      Pipeline.unidentified_request(
        pipeline,
        "PUT",
        Api.multi_recipient_path(options.timestamp, options.online, options.urgent),
        body: upload,
        headers: [
          {"content-type", Api.multi_recipient_content_type()},
          {"group-send-token", Endorsements.header_value(token)}
        ]
      )

    case response do
      {:ok, %Response{} = response} ->
        handle(
          Api.multi_result(response),
          pipeline,
          members,
          content,
          options,
          certificate,
          result,
          attempt
        )

      {:error, reason} ->
        failed = for member <- members, do: {member, {:transport, reason}}
        {:ok, pipeline, %{result | failed: result.failed ++ failed}, []}
    end
  end

  defp handle({:ok, not_registered}, pipeline, members, content, options, _cert, result, _attempt) do
    with {:ok, pipeline} <- mark_all_unregistered(pipeline, not_registered) do
      delivered = members -- not_registered
      sent = sent_ops(pipeline, delivered, content, options)

      case write(pipeline, sent) do
        :ok ->
          {:ok, pipeline,
           %{
             result
             | recipients: result.recipients ++ delivered,
               sender_key: result.sender_key ++ delivered,
               unregistered: result.unregistered ++ Enum.filter(not_registered, &(&1 in members))
           }, []}

        {:error, :fenced} ->
          {:error, :fenced, pipeline}
      end
    end
  end

  # CRS-07 §4 and §3.3: correct the device lists, forget sender-key delivery
  # for the affected devices, send again with the same timestamp.
  defp handle({:mismatch, entries}, pipeline, members, content, options, cert, result, attempt) do
    corrections = for e <- entries, do: {e.service_id, e.extra, e.missing, e.extra ++ e.missing}
    retry(pipeline, corrections, members, content, options, cert, result, attempt)
  end

  defp handle({:stale, entries}, pipeline, members, content, options, cert, result, attempt) do
    corrections = for e <- entries, do: {e.service_id, e.stale, e.stale, e.stale}
    retry(pipeline, corrections, members, content, options, cert, result, attempt)
  end

  # The token or an access check failed: send individually (CRS-07 §3.3).
  defp handle(outcome, pipeline, members, _content, _options, _cert, result, _attempt)
       when outcome in [:unauthorized, :not_found],
       do: {:ok, pipeline, result, members}

  defp handle(outcome, pipeline, members, _content, _options, _cert, result, _attempt) do
    failed = for member <- members, do: {member, outcome}
    {:ok, pipeline, %{result | failed: result.failed ++ failed}, []}
  end

  defp retry(pipeline, corrections, members, content, options, cert, result, attempt) do
    corrected =
      Enum.reduce_while(corrections, {:ok, pipeline}, fn {member, forget, fetch, affected},
                                                         {:ok, pipeline} ->
        with {:ok, pipeline, _events} <- Pipeline.correct_devices(pipeline, member, forget, fetch),
             :ok <- forget_delivered(pipeline, options.group_id, member, affected) do
          {:cont, {:ok, pipeline}}
        else
          {:error, :fenced} -> {:halt, {:error, :fenced, pipeline}}
          {:error, reason, pipeline} -> {:halt, {:error, reason, pipeline}}
        end
      end)

    case corrected do
      {:ok, pipeline} ->
        sender_key_send(pipeline, members, content, options, cert, result, attempt + 1)

      {:error, :fenced, pipeline} ->
        {:error, :fenced, pipeline}

      {:error, reason, pipeline} ->
        failed = for member <- members, do: {member, reason}
        {:ok, pipeline, %{result | failed: result.failed ++ failed}, []}
    end
  end

  defp forget_delivered(pipeline, group_id, member, devices) do
    group = Pipeline.read(pipeline, :group, [group_id])
    {:ok, id} = ServiceId.parse(member)

    case group.sending do
      nil ->
        :ok

      sending ->
        sending = Sending.forget_delivered(sending, for(d <- devices, do: {id, d}))
        write(pipeline, [{:put_group, group_id, %{group | sending: sending}}])
    end
  end

  # --- individual path ----------------------------------------------------------

  defp individual_send(pipeline, members, content, options, result) do
    Enum.reduce_while(members, {:ok, pipeline, result}, fn member, {:ok, pipeline, result} ->
      case Pipeline.send_content(pipeline, member, content,
             timestamp: options.timestamp,
             group_id: options.group_id,
             content_hint: options.hint,
             urgent: options.urgent,
             online: options.online
           ) do
        {:ok, _info, pipeline} ->
          {:cont, {:ok, pipeline, %{result | recipients: result.recipients ++ [member]}}}

        {:error, :fenced, pipeline} ->
          {:halt, {:error, :fenced, pipeline}}

        {:error, :unregistered, pipeline} ->
          {:cont, {:ok, pipeline, %{result | unregistered: result.unregistered ++ [member]}}}

        {:error, reason, pipeline} ->
          {:cont, {:ok, pipeline, %{result | failed: result.failed ++ [{member, reason}]}}}
      end
    end)
  end

  # --- helpers ------------------------------------------------------------------

  # A device that a 1:1 device-list correction named has a new generation
  # in its target, so it gets the distribution message again (CRS-07 §4).
  defp targets(pipeline, member),
    do:
      Pipeline.sender_key_targets(
        pipeline,
        member,
        Pipeline.read(pipeline, :device_ids, [member])
      )

  # CRS-06 section 8: each recipient with its identity key and the
  # registration ID of every device from the 1:1 session.
  defp recipient(pipeline, member) do
    {:ok, id} = ServiceId.parse(member)

    devices =
      for device <- Pipeline.read(pipeline, :device_ids, [member]),
          record = Pipeline.read(pipeline, :session, [Address.new(member, device)]),
          record != nil and record.current != nil,
          do: {device, record.current.remote_registration_id}

    %{
      service_id: id,
      identity_key: Pipeline.read(pipeline, :identity, [member]),
      devices: devices
    }
  end

  defp sent_ops(pipeline, members, content, options) do
    sent = %{
      content: content,
      content_hint: options.hint,
      urgent: options.urgent,
      group_id: options.group_id,
      sent_at_ms: Pipeline.clock(pipeline)
    }

    for member <- members,
        device <- Pipeline.read(pipeline, :device_ids, [member]),
        do: {:put_sent, {member, device, options.timestamp}, sent}
  end

  defp mark_all_unregistered(pipeline, members) do
    Enum.reduce_while(members, {:ok, pipeline}, fn member, {:ok, pipeline} ->
      case Pipeline.mark_unregistered(pipeline, member) do
        {:ok, pipeline} -> {:cont, {:ok, pipeline}}
        {:error, :fenced, pipeline} -> {:halt, {:error, :fenced, pipeline}}
      end
    end)
  end

  defp write(pipeline, ops) do
    case Pipeline.write(pipeline, ops) do
      :ok -> :ok
      {:error, :fenced} -> {:error, :fenced}
    end
  end
end
