defmodule SalixIM.IFC.Ingress do
  @moduledoc """
  The label an inbound message carries into the session
  (`docs/verification.md` §3.3, §9).

  Every provider inbound crosses one funnel, and this is where its audience
  is decided — once, from provider facts, and then sealed into
  `trusted_origin` next to `principal_ref` and `provider_context`. The model
  never supplies it and can never change it.

  A stored label records what the audience *was* when the content entered.
  Re-tagging a channel tomorrow changes what happens to tomorrow's messages;
  it does not rewrite what yesterday's message was allowed to be.

  Two facts, both structural:

    * the **audience**: a public room's content is its whole space, anything
      else is its own conversation, joined with the operator's classification
      tags;
    * the **integrity class**: a message from an identified provider user is
      a `command`, including a Slack app's own user identity. Anonymous
      webhooks and system notifications are `data` — context the model may
      read and may never treat as an instruction.

  Total by construction: anything this module cannot establish it omits, and
  an input with no label reads as agent-private, which flows nowhere.
  """

  require Logger

  alias SalixIM.IFC.Projection

  @doc """
  The `ifc` block for one provider inbound, or `nil` when the message carries
  too little to label.
  """
  @spec provider_block(map(), map(), map() | nil) :: map() | nil
  def provider_block(group, metadata, principal_ref) when is_map(group) and is_map(metadata) do
    group_id = text(group["group_id"])
    tenant_id = text(group["tenant_id"])
    provider = text(metadata["provider"])
    connect_id = text(metadata["connect_id"])

    # A Group that has not opted in is not labelled at all. The Group record
    # is already in hand here, so this costs nothing, and it keeps the
    # projection — and the one provider lookup it may need — off the ingress
    # path of every workspace that is not using this.
    if group_id == "" or provider == "" or connect_id == "" or not enabled?(group) do
      nil
    else
      scope = %{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id}

      case audience(provider, scope, metadata) do
        nil ->
          nil

        atoms ->
          %{
            "label" => Enum.sort(atoms),
            "integrity" => integrity(metadata, principal_ref),
            "principal" => principal(provider, metadata, principal_ref),
            # Sealed from the same `users.info` read the profile already
            # needed, so a decision knows whether the sender is a member of
            # this workspace or a guest in it without asking again.
            "placement" => placement(metadata)
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
      end
    end
  rescue
    exception ->
      # A labelling fault must never drop a message. The input simply arrives
      # unlabelled, which is the fail-closed reading, and the fault is visible.
      Logger.warning("ifc ingress labelling failed: #{Exception.message(exception)}")
      nil
  catch
    _kind, _reason -> nil
  end

  def provider_block(_group, _metadata, _principal_ref), do: nil

  @doc "True when this Group has opted in to information-flow labelling."
  @spec enabled?(map()) :: boolean()
  def enabled?(group) when is_map(group) do
    case group["ifc"] do
      %{"mode" => mode} when is_binary(mode) -> text(mode) in ["audit", "enforce"]
      _absent -> false
    end
  end

  def enabled?(_group), do: false

  @doc """
  The `ifc` block for one internal Comma Conversation message.

  A Task conversation is its own audience (`task`), an ordinary Conversation
  is `conversation`; both name the same atom the destination resolver
  produces for that conversation id, so a Worker reporting into its own Task
  is a same-atom flow that needs no membership at all.
  """
  @spec conversation_block(map()) :: map() | nil
  def conversation_block(record) when is_map(record) do
    conversation_id = text(record["conversation_id"])

    with false <- conversation_id == "",
         atom when is_binary(atom) <-
           conversation_atom(record["conversation_kind"], conversation_id) do
      %{
        "label" => [atom],
        "integrity" => principal_integrity(record["principal_ref"]),
        "principal" => principal(record["principal_ref"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    else
      _other -> nil
    end
  end

  def conversation_block(_record), do: nil

  @doc """
  The audience atoms of one provider scope, named by its id.

  An inbound message and a read of the same channel must agree about who that
  channel's content belongs to, so both go through this. Ingress reaches it
  with the scope an event names; `SalixIM.IFC.ReadLabels` reaches it with the
  channel a hit came from.

  `nil` when the scope cannot be labelled at all, which reads as agent-private
  wherever it lands.
  """
  @spec scope_atoms(map(), term()) :: [String.t()] | nil
  def scope_atoms(scope, scope_id) when is_map(scope) do
    scope_id = text(scope_id)

    if scope_id == "" do
      nil
    else
      {canonical, row} = Projection.structure(scope, scope_id)
      atoms(scope, canonical, row)
    end
  rescue
    exception ->
      Logger.warning("ifc scope labelling failed: #{Exception.message(exception)}")
      nil
  catch
    _kind, _reason -> nil
  end

  def scope_atoms(_scope, _scope_id), do: nil

  @doc "The audience atom of one internal Comma Conversation, by kind."
  @spec conversation_atom(term(), String.t()) :: String.t() | nil
  def conversation_atom(kind, conversation_id) do
    atom =
      if kind == "agent_task",
        do: {:task, conversation_id},
        else: {:conversation, conversation_id}

    case SalixIFC.Codec.encode_atom(atom) do
      {:ok, encoded} -> encoded
      :error -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Audience
  # ---------------------------------------------------------------------------

  defp audience("slack", scope, metadata) do
    channel_id = text(metadata["channel_id"])
    sender = text(metadata["user_id"])

    if channel_id == "" do
      nil
    else
      {scope_id, row} = slack_scope(scope, channel_id, metadata, sender)
      atoms(scope, scope_id, row)
    end
  end

  defp audience("feishu", scope, metadata) do
    chat_id = text(metadata["chat_id"])
    sender = text(metadata["sender_open_id"] || metadata["sender_user_id"])

    cond do
      chat_id == "" ->
        nil

      text(metadata["chat_type"]) == "p2p" and sender != "" ->
        # The chat payload names neither participant, so this inbound — which
        # carries both — is the only place the pairing can be learned. A later
        # read or write naming only the chat id resolves through it.
        Projection.observe_direct(scope, chat_id, sender)
        {scope_id, row} = feishu_direct(scope, sender)
        atoms(scope, scope_id, row)

      true ->
        {canonical, row} = Projection.structure(scope, chat_id)
        atoms(scope, canonical, if(is_nil(row.kind), do: %{row | kind: "room"}, else: row))
    end
  end

  # A voice call is a private conversation with its caller. The call id
  # (chat_id) is recorded as naming that one-to-one, so a later
  # `voice.say` addressed to the call resolves to the same atom.
  defp audience("voice", scope, metadata) do
    call_id = text(metadata["chat_id"])
    caller = text(metadata["from_user_id"])

    if call_id == "" or caller == "" do
      nil
    else
      Projection.observe_direct(scope, call_id, caller)
      scope_id = Projection.direct_scope_id(caller)
      atoms(scope, scope_id, stored(scope, scope_id, "direct"))
    end
  end

  # A private Signal chat is named by its peer's ACI, which is also the
  # sender: record it as that one-to-one, like a voice call. A Signal group
  # (`group:<id>`) is a room; its membership is not projected, so it keeps
  # the room's own atom.
  defp audience("signal", scope, metadata) do
    chat_id = text(metadata["chat_id"])
    sender = text(metadata["from_user_id"])

    cond do
      chat_id == "" ->
        nil

      text(metadata["chat_type"]) == "private" and sender == chat_id ->
        Projection.observe_direct(scope, chat_id, sender)
        scope_id = Projection.direct_scope_id(sender)
        atoms(scope, scope_id, stored(scope, scope_id, "direct"))

      true ->
        {canonical, row} = Projection.structure(scope, chat_id)
        atoms(scope, canonical, if(is_nil(row.kind), do: %{row | kind: "room"}, else: row))
    end
  end

  # A message posted through the group's inbound API belongs to the whole
  # group (docs/product-features.md): the caller addressed
  # the group, not any one of its channels, so the content may reach any
  # destination inside it. Nothing narrower can be known about it.
  defp audience("api", scope, _metadata) do
    case encode_all([{:group, scope.group_id}]) do
      [] -> nil
      encoded -> encoded
    end
  end

  # Telegram and WeChat name their conversation in the event; the projection
  # decides what kind of place it is and, for a one-to-one, which person it is
  # with, so an inbound and a reply to it land on the same atom.
  defp audience(_provider, scope, metadata) do
    chat_id = text(metadata["chat_id"] || metadata["channel_id"] || metadata["wechat_id"])

    if chat_id == "" do
      nil
    else
      {canonical, row} = Projection.structure(scope, chat_id)
      atoms(scope, canonical, row)
    end
  end

  defp slack_scope(scope, channel_id, metadata, sender) do
    case Projection.event_kind(text(metadata["channel_type"])) do
      "direct" when sender != "" ->
        scope_id = Projection.direct_scope_id(sender)
        {scope_id, stored(scope, scope_id, "direct")}

      _unknown ->
        # `app_mention` carries no channel_type, so the projection answers —
        # from Postgres when it already knows this channel, and from one
        # bounded `conversations.info` when it does not.
        Projection.structure(scope, channel_id)
    end
  end

  defp feishu_direct(scope, sender) do
    scope_id = Projection.direct_scope_id(sender)
    {scope_id, stored(scope, scope_id, "direct")}
  end

  defp stored(scope, scope_id, kind) do
    {_canonical, row} = Projection.structure(scope, scope_id)
    if is_nil(row.kind), do: %{row | kind: kind}, else: row
  end

  # A public room's audience is its space, unless it is sealed — see
  # `SalixIM.IFC.Projection.space_audience?/1` for why sealing has to keep the
  # room's own atom.
  defp atoms(scope, scope_id, row) do
    base =
      if Projection.space_audience?(row),
        do: {:space, scope.connect_id},
        else: {:scope, scope.connect_id, scope_id}

    tags = Enum.map(row.tags, &{:tag, &1})

    case encode_all([base | tags]) do
      [] -> nil
      encoded -> encoded
    end
  end

  # Every atom crosses the app boundary through the kernel's own grammar, so
  # an id that cannot round-trip is refused here rather than becoming a label
  # that decodes to something else later.
  defp encode_all(atoms) do
    Enum.reduce_while(atoms, [], fn atom, acc ->
      case SalixIFC.Codec.encode_atom(atom) do
        {:ok, encoded} -> {:cont, acc ++ [encoded]}
        :error -> {:halt, []}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Integrity and principal
  # ---------------------------------------------------------------------------

  # Provider adapters seal the authenticated member identity. IFC does not
  # distinguish automated members from people; absent identity is data.
  defp integrity(%{"provider" => "api"} = metadata, _principal_ref),
    do: api_integrity(metadata)

  # A WebSocket voice call acts with its voice agent key, like an API
  # message. A phone call has no key and keeps its caller principal.
  defp integrity(%{"provider" => "voice"} = metadata, principal_ref) do
    if api_principal(metadata),
      do: "command",
      else: principal_integrity(principal_ref)
  end

  defp integrity(_metadata, principal_ref), do: principal_integrity(principal_ref)

  defp principal_integrity(principal_ref),
    do: if(is_nil(principal(principal_ref)), do: "data", else: "command")

  defp placement(metadata) do
    case text(metadata["user_placement"]) do
      "internal" -> "internal"
      "external" -> "external"
      _unknown -> nil
    end
  end

  defp api_integrity(metadata) do
    case api_principal(metadata) do
      nil -> "data"
      _principal -> "command"
    end
  end

  # An inbound API key acts with its creator's authority, as a schedule does
  # (docs/verification.md): the kernel keys
  # `{:api_key, id, creator}` by the creator, so every effect the message
  # causes is decided against the creator's current membership.
  defp api_principal(metadata) do
    with {:ok, principal} <- SalixIFC.Codec.decode_principal(metadata["api_key_principal"]),
         {:api_key, _id, _creator} <- principal,
         {:ok, encoded} <- SalixIFC.Codec.encode_principal(principal) do
      encoded
    else
      _other -> nil
    end
  end

  defp principal("api", metadata, _principal_ref), do: api_principal(metadata)

  defp principal("voice", metadata, principal_ref),
    do: api_principal(metadata) || principal(principal_ref)

  defp principal(_provider, _metadata, principal_ref), do: principal(principal_ref)

  # Provider identity is the only human principal in this model: a Bridge For
  # Teams login configures labels and never reads or writes through the
  # kernel (§3.1).
  defp principal(%{} = principal_ref) do
    connect = text(principal_ref["connect_id"])
    subject = text(principal_ref["subject_id"])

    principal =
      cond do
        connect != "" and subject != "" -> {:provider_user, connect, subject}
        subject != "" -> {:comma_user, subject}
        true -> nil
      end

    case principal && SalixIFC.Codec.encode_principal(principal) do
      {:ok, encoded} -> encoded
      _other -> nil
    end
  end

  defp principal(_principal_ref), do: nil

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
