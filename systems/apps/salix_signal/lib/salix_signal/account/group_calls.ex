defmodule SalixSignal.Account.GroupCalls do
  @moduledoc """
  The account side of a joined group call (CRS-14): what the account gives
  a `SalixSignal.GroupCall.Session` as its plug-ins.

    * `send_call_message/5` sends one encoded call message (a media key or
      a leave notice) to the accounts in the call (section 9.2): one group
      message to those members when more than one other account must get it,
      otherwise individual 1:1 call messages; then a separate 1:1 message to
      this account's other devices, never through the multi-recipient path.
    * `members/2` lists the group's full members with their UID
      ciphertexts from the stored group state (section 9.4).

  The own-account message goes to every device of this account except the
  sending one (CRS-07 §3.1). A Comma account is a primary device without
  linked devices, so that list is normally empty, and an empty list is not
  a valid send (CRS-07 §3.2, 422); nothing is sent then.
  """

  alias SalixSignal.Messaging.{GroupSend, Pipeline}
  alias SalixSignal.Storage
  alias SalixSignalProto.Message.Wire
  alias SalixSignalProto.ServiceId

  # CRS-14 section 9.2: implicit content hint for the group message.
  @implicit 2
  # CRS-06 §5.1: call messages sent 1:1 use the default hint.
  @default_hint 0

  @doc """
  Sends `call_message` (content field 3, CRS-12) to the accounts `acis` in
  group `group_id` and to this account's other devices. Returns
  `{:ok, %{recipients, failed, own_devices}, pipeline}` or
  `{:error, reason, pipeline}` (`:fenced`, `:unknown_group`,
  `:not_a_member`).
  """
  @spec send_call_message(Pipeline.t(), <<_::256>>, [String.t()], binary(), boolean()) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def send_call_message(pipeline, group_id, acis, call_message, urgent)
      when is_list(acis) and is_binary(call_message) do
    own = pipeline.account.aci
    others = acis |> Enum.map(&String.downcase/1) |> Enum.uniq() |> List.delete(own)
    content = Wire.Content.encode(%Wire.Content{call_message: call_message})

    with {:ok, _group} <- member_group(pipeline, group_id),
         {:ok, sent, pipeline} <- send_others(pipeline, group_id, others, content, urgent),
         {:ok, own_devices, pipeline} <- send_own(pipeline, content, urgent) do
      {:ok, Map.put(sent, :own_devices, own_devices), pipeline}
    end
  end

  defp member_group(pipeline, group_id) do
    case GroupSend.member_group(pipeline, group_id) do
      {:ok, group} -> {:ok, group}
      {:error, reason} -> {:error, reason, pipeline}
    end
  end

  defp send_others(pipeline, _group_id, [], _content, _urgent),
    do: {:ok, %{recipients: [], failed: []}, pipeline}

  defp send_others(pipeline, group_id, [_, _ | _] = others, content, urgent) do
    case GroupSend.send_content(pipeline, group_id, content,
           members: others,
           content_hint: @implicit,
           urgent: urgent
         ) do
      {:ok, info, pipeline} ->
        failed = info.failed ++ for(aci <- info.unregistered, do: {aci, :unregistered})
        {:ok, %{recipients: info.recipients, failed: failed}, pipeline}

      {:error, reason, pipeline} ->
        {:error, reason, pipeline}
    end
  end

  defp send_others(pipeline, _group_id, [aci], content, urgent) do
    case Pipeline.send_content(pipeline, aci, content,
           urgent: urgent,
           content_hint: @default_hint,
           keep_sent: false
         ) do
      {:ok, _info, pipeline} -> {:ok, %{recipients: [aci], failed: []}, pipeline}
      {:error, :fenced, pipeline} -> {:error, :fenced, pipeline}
      {:error, reason, pipeline} -> {:ok, %{recipients: [], failed: [{aci, reason}]}, pipeline}
    end
  end

  # CRS-14 section 9.2: a separate identified 1:1 message to the own
  # account, whose device list leaves out this device (CRS-07 §3.1).
  defp send_own(pipeline, content, urgent) do
    own = pipeline.account.aci
    devices = Pipeline.read(pipeline, :device_ids, [own]) -- [pipeline.account.device_id]

    if devices == [] do
      {:ok, [], pipeline}
    else
      case Pipeline.send_content(pipeline, own, content,
             urgent: urgent,
             sealed: false,
             content_hint: @default_hint,
             keep_sent: false
           ) do
        {:ok, info, pipeline} -> {:ok, info.devices, pipeline}
        {:error, :fenced, pipeline} -> {:error, :fenced, pipeline}
        {:error, _reason, pipeline} -> {:ok, [], pipeline}
      end
    end
  end

  @doc """
  The group's full members with their 65-byte UID ciphertexts, from the
  stored group state of account `account_id` (read from the database, not
  from the owner process): `{:ok, [%{aci, member_id}]}`.
  """
  @spec members(String.t(), <<_::256>>) :: {:ok, [map()]} | {:error, term()}
  def members(account_id, <<_::binary-size(32)>> = group_id) do
    case Storage.group(account_id, group_id) do
      %{state: %{members: members}} ->
        {:ok,
         for %{service_id: {:aci, _} = id, uid: uid} <- members do
           %{aci: ServiceId.to_string(id), member_id: uid}
         end}

      _ ->
        {:error, :unknown_group}
    end
  end
end
