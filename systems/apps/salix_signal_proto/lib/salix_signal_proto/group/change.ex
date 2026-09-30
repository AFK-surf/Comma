defmodule SalixSignalProto.Group.Change do
  @moduledoc """
  Group changes (CRS-09b sections 4.6, 5.2, 6, 7 and 9).

  * `verify_signed/4` checks a signed change that a group message carries
    (section 9): the notary signature over the exact action bytes, and the
    group identifier in actions field 25.
  * `apply_actions/4` applies decoded actions to a decrypted
    `SalixSignalProto.Group.State` (section 6). An inconsistency, such as
    changing the role of an unknown member, returns an error; the caller
    then fetches the full state (section 5.3).
  * `build/2` encodes the actions of a change request (section 7).

  Comma understands change epochs up to 7 (`max_epoch/0`). A change with a
  higher epoch only advances the revision (section 4.6).
  """

  alias SalixSignalProto.Group.Notary
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.ServerParams
  alias SalixSignalProto.Group.State
  alias SalixSignalProto.Group.Uid
  alias SalixSignalProto.Group.Wire
  alias SalixSignalProto.Group.Wire.Actions, as: A

  @max_epoch 7

  @doc "The highest change epoch Comma understands; sent as `maxSupportedChangeEpoch`."
  def max_epoch, do: @max_epoch

  @doc """
  Decodes a signed change (the protobuf bytes). Returns the change epoch,
  the decoded actions and the exact action bytes.
  """
  @spec decode_signed(binary()) ::
          {:ok,
           %{
             epoch: non_neg_integer(),
             actions: struct(),
             actions_bytes: binary(),
             signature: binary()
           }}
          | {:error, :invalid}
  def decode_signed(bytes) when is_binary(bytes) do
    with {:ok, %Wire.SignedChange{} = signed} <- State.decode(Wire.SignedChange, bytes),
         {:ok, actions} <- State.decode(A, signed.actions) do
      {:ok,
       %{
         epoch: signed.change_epoch,
         actions: actions,
         actions_bytes: signed.actions,
         signature: signed.server_signature
       }}
    end
  end

  @doc """
  Verifies a signed change carried in a group message (CRS-09b section 9):
  the notary signature over the action bytes as received, and the group
  identifier in actions field 25.
  """
  @spec verify_signed(ServerParams.Public.t(), Params.t(), binary()) ::
          {:ok, map()} | {:error, :invalid}
  def verify_signed(%ServerParams.Public{} = server, %Params{group_id: group_id}, bytes) do
    with {:ok, change} <- decode_signed(bytes),
         true <- Notary.verify(server, change.actions_bytes, change.signature),
         true <- change.actions.group_id == group_id do
      {:ok, change}
    else
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Applies a decoded change to the state (CRS-09b section 6). `epoch` is the
  change epoch; above `max_epoch/0` only the revision changes.
  """
  @spec apply_actions(State.t(), Params.t(), struct(), non_neg_integer()) ::
          {:ok, State.t()} | {:error, atom()}
  def apply_actions(%State{} = state, %Params{} = params, %A{} = actions, epoch \\ 0) do
    state = %{state | revision: actions.revision}

    if epoch > @max_epoch do
      {:ok, state}
    else
      steps = [
        &add_members/3,
        &remove_members/3,
        &change_roles/3,
        &update_profile_keys/3,
        &add_invited/3,
        &remove_invited/3,
        &accept_invitations/3,
        &attributes/3,
        &add_requesting/3,
        &remove_requesting/3,
        &approve_requesting/3,
        &link_and_flags/3,
        &ban/3,
        &unban/3,
        &accept_pni_invitations/3,
        &member_labels/3,
        &terminate/3
      ]

      Enum.reduce_while(steps, {:ok, state}, fn step, {:ok, acc} ->
        case step.(acc, params, actions) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "The editor (actions field 1) decrypted, or nil."
  @spec editor(Params.t(), struct()) :: Uid.service_id() | nil
  def editor(%Params{} = params, %A{editor: editor}) when editor != "",
    do: State.decrypt_uid(params, editor)

  def editor(_params, _actions), do: nil

  # --- section 6, in field-number order ---

  defp add_members(state, params, actions) do
    Enum.reduce_while(actions.add_members, {:ok, state}, fn %A.AddMember{added: record},
                                                            {:ok, s} ->
      case record && State.member(params, record, actions.revision) do
        nil ->
          {:halt, {:error, :invalid_member}}

        member ->
          if member?(s, member.uid) do
            {:cont, {:ok, s}}
          else
            s = drop_pending(s, member.uid)
            {:cont, {:ok, %{s | members: s.members ++ [member]}}}
          end
      end
    end)
  end

  defp remove_members(state, _params, actions) do
    uids = for %A.UserId{user_id: uid} <- actions.remove_members, do: uid
    {:ok, %{state | members: Enum.reject(state.members, &(&1.uid in uids))}}
  end

  defp change_roles(state, _params, actions) do
    Enum.reduce_while(actions.change_roles, {:ok, state}, fn %A.ChangeRole{
                                                               user_id: uid,
                                                               role: role
                                                             },
                                                             {:ok, s} ->
      if member?(s, uid),
        do: {:cont, {:ok, update_member(s, uid, &%{&1 | role: role})}},
        else: {:halt, {:error, :unknown_member}}
    end)
  end

  defp update_profile_keys(state, params, actions) do
    Enum.reduce_while(actions.update_profile_keys, {:ok, state}, fn update, {:ok, s} ->
      case State.ciphertexts(update.user_id, update.profile_key, update.presentation) do
        {:ok, uid, pk} ->
          {:cont,
           {:ok,
            update_member(s, uid, fn m ->
              %{
                m
                | profile_key:
                    State.decrypt_profile_key(params, pk, m.service_id) || m.profile_key
              }
            end)}}

        :error ->
          {:halt, {:error, :invalid_member}}
      end
    end)
  end

  defp add_invited(state, params, actions) do
    invited =
      for %A.AddInvitedMember{added: record} <- actions.add_invited_members,
          entry <- [State.invited(params, record)],
          entry != nil,
          do: entry

    {:ok,
     Enum.reduce(invited, state, fn entry, s ->
       if member?(s, entry.uid) or Enum.any?(s.invited, &(&1.uid == entry.uid)),
         do: s,
         else: %{s | invited: s.invited ++ [entry]}
     end)}
  end

  defp remove_invited(state, _params, actions) do
    uids = for %A.UserId{user_id: uid} <- actions.remove_invited_members, do: uid
    {:ok, %{state | invited: Enum.reject(state.invited, &(&1.uid in uids))}}
  end

  defp accept_invitations(state, params, actions) do
    Enum.reduce_while(actions.accept_invitations, {:ok, state}, fn update, {:ok, s} ->
      case State.ciphertexts(update.user_id, update.profile_key, update.presentation) do
        {:ok, uid, pk} ->
          {role, s} = take_invite(s, uid)
          {:cont, {:ok, add_full_member(s, params, uid, pk, role, actions.revision)}}

        :error ->
          {:halt, {:error, :invalid_member}}
      end
    end)
  end

  defp accept_pni_invitations(state, params, actions) do
    Enum.reduce_while(actions.accept_pni_invitations, {:ok, state}, fn update, {:ok, s} ->
      case State.ciphertexts(update.aci_user_id, update.profile_key, update.presentation) do
        {:ok, aci_uid, pk} ->
          {role, s} = take_invite(s, update.pni_user_id)
          {:cont, {:ok, add_full_member(s, params, aci_uid, pk, role, actions.revision)}}

        :error ->
          {:halt, {:error, :invalid_member}}
      end
    end)
  end

  defp take_invite(state, uid) do
    case Enum.split_with(state.invited, &(&1.uid == uid)) do
      {[invite | _], rest} -> {invite.role, %{state | invited: rest}}
      {[], _} -> {State.role_member(), state}
    end
  end

  defp add_full_member(state, params, uid, profile_key_ciphertext, role, revision) do
    if member?(state, uid) do
      state
    else
      service_id = State.decrypt_uid(params, uid)

      member = %{
        uid: uid,
        service_id: service_id,
        role: if(role == 0, do: State.role_member(), else: role),
        profile_key: State.decrypt_profile_key(params, profile_key_ciphertext, service_id),
        joined_at_revision: revision,
        label_emoji: nil,
        label_text: nil
      }

      state |> drop_pending(uid) |> Map.update!(:members, &(&1 ++ [member]))
    end
  end

  defp attributes(state, params, actions) do
    state =
      state
      |> put_attribute(actions.change_title, :title, params)
      |> then(fn s ->
        case actions.change_avatar do
          %A.StringValue{value: key} -> %{s | avatar_key: if(key == "", do: nil, else: key)}
          nil -> s
        end
      end)
      |> put_attribute(actions.change_timer, :disappearing_timer, params)
      |> put_access(:attributes, actions.change_attributes_access)
      |> put_access(:membership, actions.change_membership_access)
      |> put_access(:join_by_link, actions.change_join_by_link_access)

    {:ok, state}
  end

  defp put_attribute(state, nil, _field, _params), do: state

  defp put_attribute(state, %A.BytesValue{value: blob}, field, params),
    do: Map.put(state, field, State.attribute(params, blob, field))

  defp put_access(state, _key, nil), do: state

  defp put_access(state, key, %A.AccessValue{value: level}),
    do: %{state | access: Map.put(state.access, key, level)}

  defp add_requesting(state, params, actions) do
    requesting =
      for %A.AddRequestingMember{added: record} <- actions.add_requesting_members,
          record != nil,
          entry <- [State.requesting(params, record)],
          entry != nil,
          do: entry

    {:ok,
     Enum.reduce(requesting, state, fn entry, s ->
       if member?(s, entry.uid) or Enum.any?(s.invited ++ s.requesting, &(&1.uid == entry.uid)),
         do: s,
         else: %{s | requesting: s.requesting ++ [entry]}
     end)}
  end

  defp remove_requesting(state, _params, actions) do
    uids = for %A.UserId{user_id: uid} <- actions.remove_requesting_members, do: uid
    {:ok, %{state | requesting: Enum.reject(state.requesting, &(&1.uid in uids))}}
  end

  # An approval adds the member even when this state does not list the
  # request (section 6); its profile key is then unknown until an update.
  defp approve_requesting(state, params, actions) do
    {:ok,
     Enum.reduce(actions.approve_requesting_members, state, fn %A.ChangeRole{
                                                                 user_id: uid,
                                                                 role: role
                                                               },
                                                               s ->
       {request, rest} =
         case Enum.split_with(s.requesting, &(&1.uid == uid)) do
           {[request | _], rest} -> {request, rest}
           {[], rest} -> {%{service_id: State.decrypt_uid(params, uid), profile_key: nil}, rest}
         end

       member = %{
         uid: uid,
         service_id: request.service_id,
         role: role,
         profile_key: request.profile_key,
         joined_at_revision: actions.revision,
         label_emoji: nil,
         label_text: nil
       }

       s = %{s | requesting: rest}
       if member?(s, uid), do: s, else: %{s | members: s.members ++ [member]}
     end)}
  end

  defp link_and_flags(state, params, actions) do
    state =
      case actions.change_link_password do
        %A.BytesValue{value: password} ->
          %{state | invite_link_password: if(password == "", do: nil, else: password)}

        nil ->
          state
      end

    state = put_attribute(state, actions.change_description, :description, params)

    state =
      case actions.change_announcements_only do
        %A.BoolValue{value: flag} -> %{state | announcements_only: flag}
        nil -> state
      end

    {:ok, state}
  end

  defp ban(state, params, actions) do
    banned =
      for %A.AddBannedMember{added: %Wire.BannedMember{} = record} <- actions.ban_members,
          do: State.banned(params, record)

    {:ok,
     Enum.reduce(banned, state, fn entry, s ->
       if Enum.any?(s.banned, &(&1.uid == entry.uid)),
         do: s,
         else: %{s | banned: s.banned ++ [entry]}
     end)}
  end

  defp unban(state, _params, actions) do
    uids = for %A.UserId{user_id: uid} <- actions.unban_members, do: uid
    {:ok, %{state | banned: Enum.reject(state.banned, &(&1.uid in uids))}}
  end

  defp member_labels(state, params, actions) do
    state =
      Enum.reduce(actions.change_member_labels, state, fn change, s ->
        update_member(s, change.user_id, fn m ->
          %{
            m
            | label_emoji: State.label(params, change.label_emoji),
              label_text: State.label(params, change.label_text)
          }
        end)
      end)

    {:ok, put_access(state, :member_labels, actions.change_member_label_access)}
  end

  defp terminate(state, _params, %A{terminate_group: nil}), do: {:ok, state}
  defp terminate(state, _params, _actions), do: {:ok, %{state | terminated: true}}

  defp member?(state, uid), do: Enum.any?(state.members, &(&1.uid == uid))

  defp update_member(state, uid, fun),
    do: %{state | members: Enum.map(state.members, &if(&1.uid == uid, do: fun.(&1), else: &1))}

  defp drop_pending(state, uid) do
    %{
      state
      | invited: Enum.reject(state.invited, &(&1.uid == uid)),
        requesting: Enum.reject(state.requesting, &(&1.uid == uid))
    }
  end

  # --- change requests (section 7) ---

  @typedoc """
  One requested action. Presentations are expiring profile key credential
  presentations (`SalixSignalProto.Group.ProfileKeyCredential.present/4`);
  UIDs are 65-byte UID ciphertexts; blobs come from
  `SalixSignalProto.Group.State.encrypt_attribute/4`.
  """
  @type operation ::
          {:add_member, presentation :: binary(), role :: integer()}
          | {:add_invited_member, uid :: binary(), role :: integer(), added_by :: binary()}
          | {:add_requesting_member, presentation :: binary()}
          | {:remove_member, uid :: binary()}
          | {:change_role, uid :: binary(), role :: integer()}
          | {:update_profile_key, presentation :: binary()}
          | {:remove_invited_member, uid :: binary()}
          | {:accept_invitation, presentation :: binary()}
          | {:accept_pni_invitation, presentation :: binary()}
          | {:remove_requesting_member, uid :: binary()}
          | {:approve_requesting_member, uid :: binary(), role :: integer()}
          | {:ban, uid :: binary()}
          | {:unban, uid :: binary()}
          | {:change_title, blob :: binary()}
          | {:change_description, blob :: binary()}
          | {:change_timer, blob :: binary()}
          | {:change_attributes_access | :change_membership_access | :change_join_by_link_access,
             level :: integer()}
          | {:change_link_password, binary()}
          | {:change_announcements_only, boolean()}

  @doc """
  Encodes change actions for `revision` (the known revision plus 1) with the
  given operations (CRS-09b section 7). The editor and group identifier are
  left for the server.
  """
  @spec build(non_neg_integer(), [operation()]) :: binary()
  def build(revision, operations) when is_integer(revision) and revision >= 0 do
    operations
    |> Enum.reduce(%A{revision: revision}, &put_operation/2)
    |> Protobuf.encode()
  end

  defp put_operation({:add_member, presentation, role}, a),
    do:
      append(a, :add_members, %A.AddMember{
        added: %Wire.Member{role: role, presentation: presentation}
      })

  defp put_operation({:add_invited_member, uid, role, added_by}, a) do
    record = %Wire.InvitedMember{
      member: %Wire.Member{user_id: uid, role: role},
      added_by: added_by
    }

    append(a, :add_invited_members, %A.AddInvitedMember{added: record})
  end

  defp put_operation({:add_requesting_member, presentation}, a),
    do:
      append(a, :add_requesting_members, %A.AddRequestingMember{
        added: %Wire.RequestingMember{presentation: presentation}
      })

  defp put_operation({:remove_member, uid}, a),
    do: append(a, :remove_members, %A.UserId{user_id: uid})

  defp put_operation({:change_role, uid, role}, a),
    do: append(a, :change_roles, %A.ChangeRole{user_id: uid, role: role})

  defp put_operation({:update_profile_key, presentation}, a),
    do: append(a, :update_profile_keys, %A.PresentationUpdate{presentation: presentation})

  defp put_operation({:remove_invited_member, uid}, a),
    do: append(a, :remove_invited_members, %A.UserId{user_id: uid})

  defp put_operation({:accept_invitation, presentation}, a),
    do: append(a, :accept_invitations, %A.PresentationUpdate{presentation: presentation})

  defp put_operation({:accept_pni_invitation, presentation}, a),
    do: append(a, :accept_pni_invitations, %A.AcceptPniInvitation{presentation: presentation})

  defp put_operation({:remove_requesting_member, uid}, a),
    do: append(a, :remove_requesting_members, %A.UserId{user_id: uid})

  defp put_operation({:approve_requesting_member, uid, role}, a),
    do: append(a, :approve_requesting_members, %A.ChangeRole{user_id: uid, role: role})

  defp put_operation({:ban, uid}, a),
    do: append(a, :ban_members, %A.AddBannedMember{added: %Wire.BannedMember{user_id: uid}})

  defp put_operation({:unban, uid}, a), do: append(a, :unban_members, %A.UserId{user_id: uid})

  defp put_operation({:change_title, blob}, a),
    do: %{a | change_title: %A.BytesValue{value: blob}}

  defp put_operation({:change_description, blob}, a),
    do: %{a | change_description: %A.BytesValue{value: blob}}

  defp put_operation({:change_timer, blob}, a),
    do: %{a | change_timer: %A.BytesValue{value: blob}}

  defp put_operation({:change_attributes_access, level}, a),
    do: %{a | change_attributes_access: %A.AccessValue{value: level}}

  defp put_operation({:change_membership_access, level}, a),
    do: %{a | change_membership_access: %A.AccessValue{value: level}}

  defp put_operation({:change_join_by_link_access, level}, a),
    do: %{a | change_join_by_link_access: %A.AccessValue{value: level}}

  defp put_operation({:change_link_password, password}, a),
    do: %{a | change_link_password: %A.BytesValue{value: password}}

  defp put_operation({:change_announcements_only, flag}, a),
    do: %{a | change_announcements_only: %A.BoolValue{value: flag}}

  defp append(actions, key, value), do: Map.update!(actions, key, &(&1 ++ [value]))
end
