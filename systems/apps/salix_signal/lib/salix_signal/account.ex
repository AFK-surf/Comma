defmodule SalixSignal.Account do
  @moduledoc """
  Operations on one Signal account, for the product layer (C12). Each call
  runs in the account's owner process (`SalixSignal.Account.Server`) on
  its ring owner node, reached through `SalixSignal.Accounts.call/3` from
  any node.

  Recipients are ACI strings. Send results are `{:ok, %{timestamp, devices,
  sealed?}}` or `{:error, reason}`, with the reasons of
  `SalixSignal.Messaging.Pipeline` plus `:not_started` (no owner reachable)
  and `:fenced` (the owner moved while sending; retry).

  Long text (CRS-05 section 5): a body over 2,048 bytes of UTF-8 is
  uploaded as a `text/x-signal-plain` attachment, which goes first among
  the attachments, and the message body is its longest UTF-8 prefix of at
  most 2,048 bytes. This applies to texts and edits, 1:1 and in groups.

  Uploads (`upload_attachment/3` and long text) run in the caller's
  process over the account's chat socket, so the owner process is not
  blocked while bytes go to the CDN.
  """

  alias SalixSignal.{Accounts, Attachments, Profiles, Storage}
  alias SalixSignalProto.Group.ProfileKeyCredential

  @long_text_type "text/x-signal-plain"
  @body_limit 2_048
  @upload_options [:content_type, :file_name, :voice_note, :flags, :width, :height, :caption]
  @change_timeout 120_000
  @profile_timeout_ms 15_000

  def send_text(id, recipient, body, opts \\ []) do
    with {:ok, body, opts} <- long_text(id, body, opts),
         do: pipeline(id, :send_text, [recipient, body, opts])
  end

  def send_reaction(id, recipient, emoji, target_author, target_timestamp, opts \\ []),
    do: pipeline(id, :send_reaction, [recipient, emoji, target_author, target_timestamp, opts])

  def send_edit(id, recipient, target_timestamp, body) do
    with {:ok, body, opts} <- long_text(id, body, []),
         do: pipeline(id, :send_edit, [recipient, target_timestamp, body, opts])
  end

  def send_remote_delete(id, recipient, target_timestamp),
    do: pipeline(id, :send_remote_delete, [recipient, target_timestamp])

  def send_typing(id, recipient, action) when action in [:started, :stopped],
    do: pipeline(id, :send_typing, [recipient, action])

  def send_receipt(id, author, kind, timestamps) when kind in [:read, :viewed],
    do: pipeline(id, :send_receipt, [author, kind, timestamps])

  def set_expire_timer(id, recipient, seconds),
    do: pipeline(id, :set_expire_timer, [recipient, seconds])

  @doc "Repairs the identity link for a peer that already contacted this account's phone number."
  def send_pni_signature(id, recipient), do: pipeline(id, :send_pni_signature, [recipient])

  @doc """
  Publishes this account's encrypted profile through its owner.
  Set `:given_name` after registration to avoid an unknown sender name.
  Other fields follow `SalixSignal.Profiles.set_profile/3`.
  The owner supplies the stored ACI and profile key.
  """
  def set_profile(id, fields) when is_map(fields),
    do: Accounts.call(id, {:set_profile, fields}, 15_000)

  @doc """
  Sends a text to a group (CRS-09c section 6). `group_id` is the 32-byte
  group identifier. The result also names `recipients`, `sender_key`,
  `unregistered` and `failed` members (`SalixSignal.Messaging.GroupSend`).
  """
  def send_group_text(id, <<_::binary-size(32)>> = group_id, body, opts \\ []) do
    with {:ok, body, opts} <- long_text(id, body, opts),
         do: group(id, :send_text, group_id, [body, opts])
  end

  @doc """
  Reacts to the group message `(target_author, target_timestamp)`;
  `remove: true` removes the reaction. Same result as `send_group_text/4`.
  """
  def send_group_reaction(
        id,
        <<_::binary-size(32)>> = group_id,
        emoji,
        target_author,
        target_timestamp,
        opts \\ []
      ),
      do: group(id, :send_reaction, group_id, [emoji, target_author, target_timestamp, opts])

  @doc "Edits this account's group message sent at `target_timestamp`."
  def send_group_edit(id, <<_::binary-size(32)>> = group_id, target_timestamp, body) do
    with {:ok, body, opts} <- long_text(id, body, []),
         do: group(id, :send_edit, group_id, [target_timestamp, body, opts])
  end

  @doc "Deletes this account's group message sent at `target_timestamp`."
  def send_group_remote_delete(id, <<_::binary-size(32)>> = group_id, target_timestamp),
    do: group(id, :send_remote_delete, group_id, [target_timestamp])

  @doc "Sends a typing message in the group."
  def send_group_typing(id, <<_::binary-size(32)>> = group_id, action)
      when action in [:started, :stopped],
      do: group(id, :send_typing, group_id, [action])

  @doc """
  Adds accounts (ACI strings) to a group (CRS-09b section 7). An account
  whose profile key this account knows is added with its profile key
  credential; any other is invited. Returns `{:ok, revision}`, or
  `{:error, :forbidden}` when the service refuses the change (for example,
  only administrators may add members).
  """
  def add_group_members(id, <<_::binary-size(32)>> = group_id, acis) when is_list(acis) do
    with {:ok, acis} <- member_acis(acis),
         {:ok, context} <- Accounts.call(id, {:member_profiles, group_id, acis}) do
      entries = Enum.zip(acis, presentations(context, acis))
      Accounts.call(id, {:change_members, group_id, {:add, entries}}, @change_timeout)
    end
  end

  @doc "Removes members or pending invitations from a group: `{:ok, revision}` or `{:error, reason}`."
  def remove_group_members(id, <<_::binary-size(32)>> = group_id, acis) when is_list(acis) do
    with {:ok, acis} <- member_acis(acis),
         do: Accounts.call(id, {:change_members, group_id, {:remove, acis}}, @change_timeout)
  end

  @doc """
  Leaves a group: `{:ok, revision}` or `{:error, reason}`. The last
  administrator promotes the remaining member who joined earliest first.
  """
  def leave_group(id, <<_::binary-size(32)>> = group_id),
    do: Accounts.call(id, {:change_members, group_id, :leave}, @change_timeout)

  @doc """
  Joins the call of a group this account is a member of (CRS-14) on the
  account's owner node. Option `:admit`: `fun(session_pid, %{era_id}) ->
  {:ok, call_id} | {:error, reason}`, called once the session has joined,
  on the session's node; on an error the session leaves. Returns
  `{:ok, session_pid}` or `{:error, reason}` (`:already_in_call`,
  `:unknown_group`, `:not_a_member`).
  """
  def join_group_call(id, <<_::binary-size(32)>> = group_id, opts \\ []),
    do: Accounts.call(id, {:join_group_call, group_id, opts})

  @doc """
  Encrypts and uploads an attachment for a later send (CRS-10). `opts`:
  `:content_type` (default `application/octet-stream`), `:file_name`,
  `:voice_note`, `:flags`, `:width`, `:height`, `:caption`. Returns
  `{:ok, %SalixSignalProto.Attachment.Pointer{}}` for the `:attachments`
  send option. The upload runs in the caller's process.
  """
  def upload_attachment(id, plaintext, opts \\ []) when is_binary(plaintext) do
    with {:ok, %{chat: chat, opts: base}} <- Accounts.call(id, :attachment_context) do
      opts =
        opts
        |> Keyword.take(@upload_options)
        |> Keyword.put_new(:content_type, "application/octet-stream")

      Attachments.upload(chat, plaintext, Keyword.merge(base, opts))
    end
  catch
    :exit, _reason -> {:error, :not_started}
  end

  @doc """
  The profile name of the account `aci` as this account last read it
  (CRS-08): `{:ok, name}` or `{:ok, nil}`. It reads stored contact data
  only; the owner fetches names in the background when a contact's
  profile key arrives or changes.
  """
  def profile_name(id, aci) when is_binary(aci) do
    case Storage.contact(id, String.downcase(aci)) do
      %{profile_name: name} when is_binary(name) -> {:ok, name}
      _ -> {:ok, nil}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  @doc "The account's groups from durable state: `%{group_id, title, revision, members, admin?}`."
  def groups(id) do
    case Accounts.call(id, :groups) do
      {:ok, groups} -> groups
      {:error, _} = error -> error
    end
  end

  @doc "Joins a group by invite link: `{:ok, {:joined | :requested, group_id}}`."
  def join_group(id, url), do: Accounts.call(id, {:join_group, url}, 120_000)

  @doc "Starts an outgoing 1:1 audio call (CRS-12 section 7.1)."
  def call(id, peer_aci), do: Accounts.call(id, {:call, peer_aci})

  @doc """
  The durable inbound feed after `seq`: `[{seq, %SalixSignal.Messaging.Inbound{}}]`,
  ascending, at most `limit` (at most 500) items. Reads the database from
  any node.
  """
  def inbound_after(id, seq, limit \\ 100) do
    case Storage.inbound_after(id, seq, limit) do
      {:ok, items} -> items
      {:error, _} = error -> error
    end
  end

  defp pipeline(id, function, args), do: Accounts.call(id, {:pipeline, function, args})

  defp group(id, function, group_id, args),
    do: Accounts.call(id, {:group, function, group_id, args})

  defp member_acis(acis) do
    acis = Enum.map(acis, &normalize_aci/1)

    if Enum.all?(acis, &is_binary/1) and acis != [],
      do: {:ok, Enum.uniq(acis)},
      else: {:error, :invalid_member}
  end

  # CRS-09b section 7: an account is added with a presentation of its
  # expiring profile key credential, read with its profile key (CRS-08);
  # without a stored key, or when the read fails, it is invited (nil). The
  # reads run here, concurrently, not in the owner process.
  defp presentations(context, acis) do
    acis
    |> Task.async_stream(&presentation(context, &1),
      max_concurrency: 8,
      timeout: @profile_timeout_ms + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, presentation} -> presentation
      {:exit, _reason} -> nil
    end)
  end

  defp presentation(%{profile_keys: keys} = context, aci) do
    with <<_::binary-size(32)>> = key <- Map.get(keys, aci),
         {:ok, %{credential: credential}} when is_binary(credential) <-
           Profiles.get_profile(context.chat, aci,
             profile_key: key,
             credential: %{server_params: context.server_params, now: context.now_s},
             timeout: @profile_timeout_ms
           ),
         {:ok, {presentation, _uid, _key}} <-
           ProfileKeyCredential.present(context.server_params, context.params, credential) do
      presentation
    else
      _ -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp normalize_aci(aci) when is_binary(aci) do
    case SalixSignalProto.ServiceId.aci_from_string(aci) do
      {:ok, _bytes} -> String.downcase(aci)
      :error -> nil
    end
  end

  defp normalize_aci(_aci), do: nil

  # CRS-05 section 5: the body holds at most 2,048 bytes; longer text goes
  # as a `text/x-signal-plain` attachment with a truncated body.
  defp long_text(_id, body, opts) when byte_size(body) <= @body_limit, do: {:ok, body, opts}

  defp long_text(id, body, opts) do
    case upload_attachment(id, body, content_type: @long_text_type) do
      {:ok, pointer} ->
        {:ok, utf8_prefix(body, @body_limit),
         Keyword.update(opts, :attachments, [pointer], &[pointer | &1])}

      {:error, _reason} = error ->
        error
    end
  end

  defp utf8_prefix(text, size) do
    prefix = binary_part(text, 0, min(size, byte_size(text)))
    if String.valid?(prefix), do: prefix, else: utf8_prefix(text, size - 1)
  end
end
