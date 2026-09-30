defmodule SalixSignal.Account.GroupSync do
  @moduledoc """
  Keeps the durable group state of an account current (CRS-09b sections 5.3,
  9 and 10; CRS-09c section 6.1).

  A group message names the sender's revision and may carry the signed
  change that produced it (CRS-09b section 9). `apply_change/5` applies
  that change only when its revision is exactly the stored revision plus 1,
  the notary signature verifies over the received action bytes, and the
  group identifier in the actions matches. In every other case (an unknown
  group, a gap, no change, a change that fails a check) the owner re-fetches
  the full state with `refresh/4` (section 5.3, recommendation) instead of
  reading change logs.

  `refresh/4` fetches the state and the endorsement response, receives the
  endorsements for the full members (the account must be one of them;
  otherwise they are ignored), and commits the group row. When a member
  left or was removed since the stored state, this device's sender key for
  the group is replaced, so the next group send distributes a new one
  (CRS-09c section 6.1). Stored endorsements are kept only while the member
  set is unchanged.

  `join/5` joins by invite link (CRS-09b section 7), stores the group and
  sends the group update message with the signed change to the other
  members (section 9).

  `change_members/5` adds or removes members, or leaves the group (section
  7), with the conflict retry of section 5.2; it stores the resulting state
  and sends the group update message to the members of that state.
  """

  alias SalixSignal.Groups
  alias SalixSignal.Messaging.{GroupSend, Pipeline}
  alias SalixSignalProto.Group.{Change, Endorsements, Params, ServerParams, State, Uid}
  alias SalixSignalProto.Message.Wire
  alias SalixSignalProto.SenderKey.Sending

  @doc """
  Fetches the group of `master_key` and stores it. Returns the stored group
  and `{:group_updated, group_id, revision}`.
  """
  @spec refresh(Pipeline.t(), Groups.client(), ServerParams.Public.t(), <<_::256>>) ::
          {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def refresh(
        pipeline,
        client,
        %ServerParams.Public{} = server,
        <<_::binary-size(32)>> = master_key
      ) do
    params = Params.from_master_key(master_key)

    case Groups.get_group(client, params) do
      {:ok, %{state: %State{} = state, endorsements: response}} ->
        store(pipeline, server, params, master_key, state, response)

      {:error, reason} ->
        {:error, reason, pipeline}
    end
  end

  @doc "Returns the invitation type for this account, or nil."
  def invitation(pipeline, state) do
    aci = {:aci, pipeline.account.aci_uuid}
    pni = {:pni, pipeline.account.pni_uuid}

    cond do
      aci in State.member_service_ids(state) -> nil
      Enum.any?(state.invited, &(&1.service_id == aci)) -> :accept_invitation
      Enum.any?(state.invited, &(&1.service_id == pni)) -> :accept_pni_invitation
      true -> nil
    end
  end

  @doc "Accepts this account's pending invitation and publishes the membership change."
  def accept_invitation(pipeline, client, server, group, presentation) do
    params = Params.from_master_key(group.master_key)

    build = fn state ->
      case invitation(pipeline, state) do
        nil -> []
        kind -> [{kind, presentation.(params)}]
      end
    end

    with {:ok, changed} <- Groups.change(client, params, group.state, build),
         {:ok, group, pipeline} <-
           store(pipeline, server, params, group.master_key, changed.state, changed.endorsements) do
      case changed.change do
        nil ->
          {:ok, group, pipeline}

        signed ->
          case send_update(pipeline, params, group.revision, signed) do
            {:ok, pipeline} -> {:ok, group, pipeline}
            {:error, reason, pipeline} -> {:error, reason, pipeline}
          end
      end
    else
      {:error, reason} -> {:error, reason, pipeline}
      {:error, reason, pipeline} -> {:error, reason, pipeline}
    end
  end

  @doc """
  Applies the signed change of a group message (CRS-09b section 9) when
  `revision` is exactly the stored revision plus 1 and the change verifies.
  Returns `:not_applicable` when the owner must re-fetch the state instead.
  """
  @spec apply_change(
          Pipeline.t(),
          ServerParams.Public.t(),
          <<_::256>>,
          non_neg_integer(),
          binary() | nil
        ) :: {:ok, map(), Pipeline.t()} | {:error, term(), Pipeline.t()} | :not_applicable
  def apply_change(pipeline, server, master_key, revision, signed)
      when is_binary(signed) and signed != "" do
    params = Params.from_master_key(master_key)

    with %{state: %State{} = state, revision: stored} when revision == stored + 1 <-
           Pipeline.read(pipeline, :group, [params.group_id]),
         {:ok, %{actions: actions, epoch: epoch}} <- Change.verify_signed(server, params, signed),
         true <- actions.revision == revision,
         {:ok, state} <- Change.apply_actions(state, params, actions, epoch) do
      store(pipeline, server, params, master_key, state, nil)
    else
      _ -> :not_applicable
    end
  end

  def apply_change(_pipeline, _server, _master_key, _revision, _signed), do: :not_applicable

  defp store(pipeline, server, params, master_key, state, response) do
    old = Pipeline.read(pipeline, :group, [params.group_id])
    members = State.member_service_ids(state)
    old_members = if old && old.state, do: State.member_service_ids(old.state), else: members
    removed? = old_members -- members != []

    endorsements =
      case receive_endorsements(pipeline, server, params, members, response) do
        nil when old != nil and old_members == members -> old.endorsements
        other -> other
      end

    sending =
      case old && old.sending do
        nil -> nil
        sending when removed? -> Sending.rotate(sending)
        sending -> sending
      end

    group = %{
      master_key: master_key,
      revision: state.revision,
      state: state,
      endorsements: endorsements,
      sending: sending
    }

    case Pipeline.write(pipeline, [{:put_group, params.group_id, group}]) do
      :ok -> {:ok, group, pipeline}
      {:error, :fenced} -> {:error, :fenced, pipeline}
    end
  end

  # CRS-09b section 10, CRS-09a section 15.4.
  defp receive_endorsements(_pipeline, _server, _params, _members, ""), do: nil
  defp receive_endorsements(_pipeline, _server, _params, _members, nil), do: nil

  defp receive_endorsements(pipeline, server, params, members, response) do
    local = {:aci, pipeline.account.aci_uuid}
    now = div(Pipeline.clock(pipeline), 1000)

    if local in members do
      case Endorsements.receive(server, params, response, members, local, now) do
        {:ok, %{endorsements: list, expiration: expiration}} ->
          %{expiration: expiration, by_member: Map.new(Enum.zip(members, list))}

        {:error, _} ->
          nil
      end
    end
  end

  @doc """
  Joins the group of an invite link. `presentation` returns a fresh
  expiring profile key credential presentation of this account for given
  group params (CRS-09a section 14.4). After a direct join the group is
  fetched and stored, and the group update message goes to the other
  members. Returns `{:joined, group_id}` or `{:requested, group_id}`.
  """
  @spec join(Pipeline.t(), Groups.client(), ServerParams.Public.t(), String.t(), (Params.t() ->
                                                                                    binary())) ::
          {:ok, {:joined | :requested, <<_::256>>}, Pipeline.t()} | {:error, term(), Pipeline.t()}
  def join(pipeline, client, server, url, presentation) do
    case Groups.join_by_link(client, url, presentation) do
      {:ok, {:joined, params, _state, signed}} ->
        with {:ok, group, pipeline} <- refresh(pipeline, client, server, params.master_key),
             {:ok, pipeline} <- send_update(pipeline, params, group.revision, signed) do
          {:ok, {:joined, params.group_id}, pipeline}
        end

      {:ok, {:requested, params, _signed}} ->
        {:ok, {:requested, params.group_id}, pipeline}

      {:error, reason} ->
        {:error, reason, pipeline}
    end
  end

  @typedoc """
  A membership change: `{:add, [{aci, presentation | nil}]}` adds each
  account with its expiring profile key credential presentation for this
  group, or invites it when the presentation is nil (CRS-09b section 7);
  `{:remove, [aci]}` removes full members and pending invitations;
  `:leave` removes this account.
  """
  @type member_change :: {:add, [{String.t(), binary() | nil}]} | {:remove, [String.t()]} | :leave

  @doc """
  Changes the membership of a stored group that this account is a full
  member of (CRS-09b section 7), retrying after a revision conflict
  (section 5.2). Parts that are already done (a member who is already
  there, a removal of a non-member) are dropped; when nothing is left, no
  request is sent. After an accepted change the resulting state is stored
  and the group update message with the signed change goes to the members
  of that state (section 9).

  Leaving as the last administrator first promotes the remaining full
  member who joined earliest, in the same change (section 7: the last
  administrator promotes others before leaving).

  Returns `{:ok, revision, pipeline}`. A change the service refuses (403)
  is `{:error, :forbidden, pipeline}`.
  """
  @spec change_members(
          Pipeline.t(),
          Groups.client(),
          ServerParams.Public.t(),
          <<_::256>>,
          member_change()
        ) :: {:ok, non_neg_integer(), Pipeline.t()} | {:error, term(), Pipeline.t()}
  def change_members(pipeline, client, %ServerParams.Public{} = server, group_id, change) do
    with {:ok, group} <- GroupSend.member_group(pipeline, group_id),
         params = Params.from_master_key(group.master_key),
         own = Uid.encrypt(params, {:aci, pipeline.account.aci_uuid}),
         {:ok, result} <-
           Groups.change(client, params, group.state, &operations(&1, params, own, change)) do
      case result do
        %{change: nil} ->
          {:ok, group.revision, pipeline}

        %{change: signed, state: state, endorsements: endorsements} ->
          with {:ok, stored, pipeline} <-
                 store(pipeline, server, params, group.master_key, state, endorsements),
               {:ok, pipeline} <- send_update(pipeline, params, stored.revision, signed) do
            {:ok, stored.revision, pipeline}
          end
      end
    else
      {:error, {:forbidden, _reason}} -> {:error, :forbidden, pipeline}
      {:error, reason} -> {:error, reason, pipeline}
      {:error, reason, pipeline} -> {:error, reason, pipeline}
    end
  end

  defp operations(state, params, own, {:add, entries}) do
    for {aci, presentation} <- entries,
        {:ok, uuid} <- [SalixSignalProto.ServiceId.aci_from_string(aci)],
        uid = Uid.encrypt(params, {:aci, uuid}),
        not member?(state, uid),
        presentation != nil or not Enum.any?(state.invited, &(&1.uid == uid)) do
      if presentation,
        do: {:add_member, presentation, State.role_member()},
        else: {:add_invited_member, uid, State.role_member(), own}
    end
  end

  defp operations(state, params, _own, {:remove, acis}) do
    for aci <- acis,
        {:ok, uuid} <- [SalixSignalProto.ServiceId.aci_from_string(aci)],
        uid = Uid.encrypt(params, {:aci, uuid}),
        operation <- removal(state, uid),
        do: operation
  end

  defp operations(state, _params, own, :leave) do
    case Enum.find(state.members, &(&1.uid == own)) do
      nil -> []
      me -> promotion(state, me) ++ [{:remove_member, own}]
    end
  end

  defp removal(state, uid) do
    cond do
      member?(state, uid) -> [{:remove_member, uid}]
      Enum.any?(state.invited, &(&1.uid == uid)) -> [{:remove_invited_member, uid}]
      true -> []
    end
  end

  defp promotion(state, %{role: role} = me) do
    admin = State.role_admin()
    others = Enum.reject(state.members, &(&1.uid == me.uid))

    if role == admin and others != [] and not Enum.any?(others, &(&1.role == admin)) do
      successor = Enum.min_by(others, & &1.joined_at_revision)
      [{:change_role, successor.uid, admin}]
    else
      []
    end
  end

  defp member?(state, uid), do: Enum.any?(state.members, &(&1.uid == uid))

  # CRS-09b section 9: the author of an accepted change sends a group
  # message with the signed change to the members. A failed send leaves
  # the change in place; members also learn it from later messages.
  defp send_update(pipeline, params, revision, signed) do
    {timestamp, pipeline} = Pipeline.timestamp(pipeline)

    update =
      Wire.Content.encode(%Wire.Content{
        data_message: %Wire.DataMessage{
          timestamp: timestamp,
          group_v2: %Wire.GroupContext{
            master_key: params.master_key,
            revision: revision,
            group_change: signed
          }
        }
      })

    case GroupSend.send_content(pipeline, params.group_id, update, timestamp: timestamp) do
      {:ok, _info, pipeline} -> {:ok, pipeline}
      {:error, :fenced, pipeline} -> {:error, :fenced, pipeline}
      {:error, _reason, pipeline} -> {:ok, pipeline}
    end
  end
end
