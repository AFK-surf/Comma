defmodule SalixSignal.Test.FakeStorage do
  @moduledoc false
  # A fake Signal storage service for group tests, written from CRS-09b
  # sections 3 to 7 and the server side of CRS-09a. It serves TLS with the
  # FakeChat test chain and keeps groups in an Agent.
  #
  # Every request must carry a valid group auth presentation for the group
  # (CRS-09a section 13.5). Implemented endpoints:
  #
  #   * GET /v2/groups/: full and invited members (403 otherwise).
  #   * GET /v2/groups/token: a group-call membership token, full members
  #     only (CRS-14 section 4.1).
  #   * GET /v2/groups/join/<pw>: join info while the link is enabled.
  #   * PATCH /v2/groups/[?inviteLinkPassword=<pw>]: the revision must be the
  #     current one plus 1 (409 otherwise). Members may change the title;
  #     with the link password a caller adds itself as a member or requester,
  #     with a profile key presentation for its own ACI. Members change
  #     membership (CRS-09b section 7): add members (a verified profile key
  #     presentation) and invite accounts when the membership access level
  #     allows them (3 = administrators), remove members, remove invitations
  #     and change roles as administrators, and remove themselves (leave).
  #     The server fills the ciphertexts, the editor and the group
  #     identifier, and signs the actions with the notary key.
  #
  # `bump/2` makes another member's title change first, so the next PATCH
  # meets a revision conflict. Every request is sent to the test process as
  # `{:fake_storage, method, path}`.

  use Agent

  alias SalixSignalProto.Group.{AuthCredential, Notary, Params, ProfileKeyCredential, State, Wire}
  alias SalixSignalProto.Group.Wire.Actions, as: A

  def start_link({test_pid, secret, now}) do
    Agent.start_link(fn -> %{test: test_pid, secret: secret, now: now, groups: %{}} end)
  end

  @doc "Stores a group: its wire state (revision set) keyed by public params."
  def put_group(storage, %Params{} = params, %Wire.Group{} = group) do
    group = %{group | public_key: Params.public_params(params)}

    Agent.update(
      storage,
      &put_in(&1, [:groups, group.public_key], %{group: group, params: params})
    )
  end

  def group(storage, %Params{} = params),
    do: Agent.get(storage, &get_in(&1, [:groups, Params.public_params(params), :group]))

  @doc "Another member changes the title, advancing the revision by one."
  def bump(storage, %Params{} = params) do
    Agent.update(storage, fn state ->
      update_in(state, [:groups, Params.public_params(params), :group], fn group ->
        %{
          group
          | revision: group.revision + 1,
            title: State.encrypt_attribute(params, :title, "Bumped")
        }
      end)
    end)
  end

  def bandit_options(storage, chain) do
    [
      plug: {__MODULE__.Router, storage},
      scheme: :https,
      ip: :loopback,
      port: 0,
      thousand_island_options: [transport_options: chain.server]
    ]
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    alias SalixSignal.Test.FakeStorage

    @impl true
    def init(storage), do: storage

    @impl true
    def call(conn, storage) do
      {:ok, body, conn} = read_body(conn, length: 8_000_000)
      conn = fetch_query_params(conn)
      state = Agent.get(storage, & &1)
      send(state.test, {:fake_storage, conn.method, conn.request_path})
      conn = put_resp_header(conn, "x-signal-timestamp", Integer.to_string(state.now * 1000))

      case authenticate(conn, state) do
        {:ok, entry, caller, pni} ->
          conn = assign(conn, :pni, pni)
          route(conn, conn.method, conn.path_info, body, entry, caller, storage)

        :error ->
          send_resp(conn, 401, "")
      end
    end

    # CRS-09b section 3: Basic base64(hex(public params) ":" hex(presentation)).
    defp authenticate(conn, state) do
      with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
           {:ok, decoded} <- Base.decode64(encoded),
           [public_hex, presentation_hex] <- String.split(decoded, ":"),
           {:ok, public} <- Base.decode16(public_hex, case: :lower),
           {:ok, presentation} <- Base.decode16(presentation_hex, case: :lower),
           %{} = entry <- state.groups[public],
           true <- AuthCredential.verify(state.secret, public, presentation, state.now),
           {:ok, %{aci_ciphertext: caller, pni_ciphertext: pni}} <-
             AuthCredential.decode_presentation(presentation) do
        {:ok, entry, caller, pni}
      else
        _ -> :error
      end
    end

    defp route(conn, "GET", ["v2", "groups"], _body, entry, caller, _storage) do
      if member?(entry.group, caller) or invited?(entry.group, caller) or
           invited?(entry.group, conn.assigns.pni),
         do: protobuf(conn, %Wire.GroupResponse{group: entry.group}),
         else: send_resp(conn, 403, "")
    end

    # CRS-14 section 4.1: the group-call membership token, for full members.
    # The token is opaque to clients; this one names the caller's ciphertext.
    defp route(conn, "GET", ["v2", "groups", "token"], _body, entry, caller, _storage) do
      if member?(entry.group, caller) do
        token = "fake:" <> Base.encode16(:crypto.hash(:sha256, caller), case: :lower)
        protobuf(conn, %SalixSignalProto.GroupCall.Wire.TokenResponse{token: token})
      else
        send_resp(conn, 403, "")
      end
    end

    defp route(conn, "GET", ["v2", "groups", "join", password], _body, entry, _caller, _storage) do
      group = entry.group
      access = (group.access_control || %Wire.AccessControl{}).join_by_link

      if link_password?(group, password) and access in [1, 3] do
        protobuf(conn, %Wire.JoinInfo{
          public_key: group.public_key,
          title: group.title,
          member_count: length(group.members),
          join_by_link: access,
          revision: group.revision
        })
      else
        send_resp(conn, 403, "")
      end
    end

    defp route(conn, "PATCH", ["v2", "groups"], body, entry, caller, storage) do
      state = Agent.get(storage, & &1)
      group = entry.group
      {:ok, actions} = State.decode(A, body)
      via_link = link_password?(group, conn.query_params["inviteLinkPassword"])

      cond do
        actions.revision != group.revision + 1 ->
          send_resp(conn, 409, "")

        actions.accept_invitations != [] or actions.accept_pni_invitations != [] ->
          accept_invite(conn, state, entry, actions, caller, storage)

        via_link ->
          join(conn, state, entry, actions, caller, storage)

        member?(group, caller) and actions.change_title != nil ->
          group = %{group | revision: actions.revision, title: actions.change_title.value}
          accept(conn, state, entry.params, group, %{actions | editor: caller}, storage)

        member?(group, caller) ->
          case membership(state, group, actions, caller) do
            {:ok, group, filled} ->
              group = %{group | revision: actions.revision}
              accept(conn, state, entry.params, group, %{filled | editor: caller}, storage)

            {:error, status} ->
              send_resp(conn, status, "")
          end

        true ->
          send_resp(conn, 403, "")
      end
    end

    defp route(conn, _method, _path, _body, _entry, _caller, _storage),
      do: send_resp(conn, 404, "")

    defp accept_invite(conn, state, entry, actions, caller, storage) do
      {updates, invited_uid, kind} =
        case {actions.accept_invitations, actions.accept_pni_invitations} do
          {[_] = updates, []} -> {updates, caller, :aci}
          {[], [_] = updates} -> {updates, conn.assigns.pni, :pni}
          _ -> {[], nil, nil}
        end

      with [update] <- updates,
           invite when not is_nil(invite) <-
             Enum.find(entry.group.invited_members, &(&1.member.user_id == invited_uid)),
           true <-
             ProfileKeyCredential.verify(
               state.secret,
               Params.public_params(entry.params),
               update.presentation,
               state.now
             ),
           {:ok, {^caller, key}} <- ProfileKeyCredential.ciphertexts(update.presentation) do
        member = %Wire.Member{
          user_id: caller,
          profile_key: key,
          role: invite.member.role,
          joined_at_revision: actions.revision
        }

        group = %{
          entry.group
          | revision: actions.revision,
            members: entry.group.members ++ [member],
            invited_members: Enum.reject(entry.group.invited_members, &(&1 == invite))
        }

        filled =
          case kind do
            :aci ->
              %{
                actions
                | accept_invitations: [
                    %{update | user_id: caller, profile_key: key, presentation: ""}
                  ]
              }

            :pni ->
              %{
                actions
                | accept_pni_invitations: [
                    %{
                      update
                      | aci_user_id: caller,
                        pni_user_id: invited_uid,
                        profile_key: key,
                        presentation: ""
                    }
                  ]
              }
          end

        accept(conn, state, entry.params, group, %{filled | editor: caller}, storage)
      else
        _ -> send_resp(conn, 403, "")
      end
    end

    defp invited?(group, uid), do: Enum.any?(group.invited_members, &(&1.member.user_id == uid))

    defp membership(state, group, actions, caller) do
      admin? = Enum.any?(group.members, &(&1.user_id == caller and &1.role == 2))
      access = (group.access_control || %Wire.AccessControl{}).membership
      may_add? = admin? or access != 3
      removes = Enum.map(actions.remove_members, & &1.user_id)
      only_self? = removes == [caller]

      cond do
        (actions.add_members != [] or actions.add_invited_members != []) and not may_add? ->
          {:error, 403}

        removes != [] and not admin? and not only_self? ->
          {:error, 403}

        (actions.remove_invited_members != [] or actions.change_roles != []) and not admin? ->
          {:error, 403}

        true ->
          with {:ok, added} <- added_members(state, group, actions) do
            invited =
              for %A.AddInvitedMember{added: record} <- actions.add_invited_members,
                  do: %{record | added_by: caller, timestamp: state.now * 1000}

            removed_invites = Enum.map(actions.remove_invited_members, & &1.user_id)
            roles = Map.new(actions.change_roles, &{&1.user_id, &1.role})

            members =
              (group.members ++ added)
              |> Enum.reject(&(&1.user_id in removes))
              |> Enum.map(&%{&1 | role: Map.get(roles, &1.user_id, &1.role)})

            group = %{
              group
              | members: members,
                invited_members:
                  Enum.reject(group.invited_members, &(&1.member.user_id in removed_invites)) ++
                    invited
            }

            filled = %{
              actions
              | add_members: Enum.map(added, &%A.AddMember{added: &1}),
                add_invited_members: Enum.map(invited, &%A.AddInvitedMember{added: &1})
            }

            {:ok, group, filled}
          end
      end
    end

    defp added_members(state, group, actions) do
      Enum.reduce_while(actions.add_members, {:ok, []}, fn %A.AddMember{added: member},
                                                           {:ok, acc} ->
        with true <-
               ProfileKeyCredential.verify(
                 state.secret,
                 group.public_key,
                 member.presentation,
                 state.now
               ),
             {:ok, {uid, profile_key}} <- ProfileKeyCredential.ciphertexts(member.presentation) do
          added = %Wire.Member{
            user_id: uid,
            role: member.role,
            profile_key: profile_key,
            joined_at_revision: actions.revision
          }

          {:cont, {:ok, acc ++ [added]}}
        else
          _ -> {:halt, {:error, 400}}
        end
      end)
    end

    defp join(conn, state, entry, actions, caller, storage) do
      group = entry.group
      public = group.public_key
      access = group.access_control.join_by_link

      with {presentation, kind} <- link_join(actions, access),
           true <- ProfileKeyCredential.verify(state.secret, public, presentation, state.now),
           {:ok, {^caller, profile_key}} <- ProfileKeyCredential.ciphertexts(presentation) do
        {group, filled} =
          case kind do
            :member ->
              member = %Wire.Member{
                user_id: caller,
                role: 1,
                profile_key: profile_key,
                joined_at_revision: actions.revision
              }

              {%{group | members: group.members ++ [member]},
               %{actions | add_members: [%A.AddMember{added: member, joined_by_link: true}]}}

            :requesting ->
              request = %Wire.RequestingMember{
                user_id: caller,
                profile_key: profile_key,
                timestamp: state.now * 1000
              }

              {%{group | requesting_members: group.requesting_members ++ [request]},
               %{actions | add_requesting_members: [%A.AddRequestingMember{added: request}]}}
          end

        accept(
          conn,
          state,
          entry.params,
          %{group | revision: actions.revision},
          %{filled | editor: caller},
          storage
        )
      else
        _ -> send_resp(conn, 400, "")
      end
    end

    defp link_join(%A{add_members: [%A.AddMember{added: %Wire.Member{presentation: p}}]}, 1),
      do: {p, :member}

    defp link_join(
           %A{
             add_requesting_members: [
               %A.AddRequestingMember{added: %Wire.RequestingMember{presentation: p}}
             ]
           },
           3
         ),
         do: {p, :requesting}

    defp link_join(_actions, _access), do: nil

    defp accept(conn, state, params, group, actions, storage) do
      bytes = Protobuf.encode(%{actions | group_id: params.group_id})

      signed = %Wire.SignedChange{
        actions: bytes,
        server_signature: Notary.sign(state.secret, bytes)
      }

      FakeStorage.put_group(storage, params, group)
      protobuf(conn, %Wire.ChangeResponse{change: signed})
    end

    defp member?(group, uid), do: Enum.any?(group.members, &(&1.user_id == uid))

    defp link_password?(%Wire.Group{invite_link_password: password}, encoded)
         when is_binary(encoded) and password != "",
         do: Base.url_decode64(encoded, padding: false) == {:ok, password}

    defp link_password?(_group, _encoded), do: false

    defp protobuf(conn, message) do
      conn
      |> put_resp_content_type("application/x-protobuf")
      |> send_resp(200, Protobuf.encode(message))
    end
  end
end
