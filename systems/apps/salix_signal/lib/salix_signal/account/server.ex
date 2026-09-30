defmodule SalixSignal.Account.Server do
  @moduledoc """
  The `SignalAccount` actor: the one writer of one Signal account's durable
  state (PLAN "Design rules", "Durable state").

  It runs on the `SalixCluster.Ring` owner node of the account ID
  (`SalixSignal.Accounts`). On start it claims the account
  (`SalixSignal.Storage.claim/2`), which increments the owner epoch, so
  every commit of an earlier owner is refused from then on. A commit
  refused as fenced stops this process with `{:shutdown, :fenced}`; the
  newer owner has the account.

  The process joins the layers of one account:

    * the chat socket (`SalixSignal.Service.Chat`, C3), authenticated with
      the device credentials, as the identified transport and the source of
      pushed envelopes; unidentified requests use plain HTTPS
      (`SalixSignal.Account.Transport`);
    * the receive and send pipeline (`SalixSignal.Messaging.Pipeline`, C5)
      over the Postgres store (`SalixSignal.Storage`): each pushed envelope
      is committed, then acknowledged (the pipeline does both), so a crash
      replays it and never loses it;
    * pre-key maintenance (`SalixSignal.Account.PreKeyService`, C4) after
      the first connection and then every `maintenance_interval_ms`, and a
      rotation of the signed and last-resort pre-keys before a retry request
      for a failed pre-key message (CRS-07 §6.2);
    * groups (C7): sender-key decryption and distribution in the pipeline,
      group state refresh when a group message shows an unknown group or a
      newer revision (`SalixSignal.Account.GroupSync`), group sends
      (`SalixSignal.Messaging.GroupSend`), and sender-key redistribution
      after a sender-key retry request;
    * 1:1 call signaling (`SalixSignal.CallSignaling`, C9): received call
      messages go to its dispatcher after their envelope is committed, and
      its outgoing call messages are sent by this process. The owner fetches
      authenticated TURN credentials with a 10-second timeout. One response
      per account is cached until its shortest service TTL expires. A failed
      lookup ends the call attempt without reuse of expired credentials;
    * group calls (`SalixSignal.GroupCall`, C11): opaque call payloads go
      to the account's session for their group (media keys, leave notices)
      or become ring events for the handler, and offers are answered busy
      while the account is in a group call (CRS-12 section 8);
    * the product handler (`SalixSignal.Account.Handler`): admitted
      messages from the durable inbound feed, at least once, behind a
      durable cursor, handed over by a linked delivery process
      (`SalixSignal.Account.Delivery`) so that a slow or re-entrant handler
      never blocks this process; call decisions; notifications;
    * profile names (CRS-08): when a contact's profile key is new, or a
      sender's stored name was read with an older key, the profile is
      fetched off this process and the name is stored with the contact, so
      `SalixSignal.Account.profile_name/2` reads it without a request;
    * group membership changes (CRS-09b section 7) and joined group calls
      (`SalixSignal.GroupCall`, CRS-14) with this account's plug-ins
      (`SalixSignal.Account.GroupCalls`).

  Expired rows are pruned every `prune_interval_ms` (`SalixSignal.Storage.prune/3`).

  ## Options

    * `:account_id` (required);
    * `:handler`: the handler module (default `config :salix_signal,
      :handler`, else `SalixSignal.Account.NullHandler`);
    * `:chat`: extra `SalixSignal.Service.Chat` options (`:host`, `:port`,
      `:roots`, `:backoff`, ...);
    * `:transport`: `%{identified: t, unidentified: t}` in place of the
      chat socket and HTTPS transports (tests);
    * `:pipeline`: extra `SalixSignal.Messaging.Pipeline.new/1` options
      (`:trust_roots`, `:known_server_certificates`, `:clock`, `:config`);
    * `:groups`: `SalixSignal.Groups` options (`:storage_url`, `:http`,
      `:now`) and `:server_params` (`ServerParams.Public`, default
      production);
    * `:call_signaling`: extra `SalixSignal.CallSignaling` options;
    * `:attachments`: extra `SalixSignal.Attachments.upload/3` options
      (`:http`, ...);
    * `:group_call`: extra `SalixSignal.GroupCall.Session` options
      (`:sfu_url`, `:http`, `:ice_opts`, timers);
    * `:maintenance_interval_ms` (default 6 h), `:prune_interval_ms`
      (default 1 h), `:delivery_retry_ms` (default 30 s).
  """

  use GenServer, restart: :transient

  require Logger

  alias SalixSignal.Account.{
    Delivery,
    GroupCalls,
    GroupSync,
    KemSupport,
    PreKeyService,
    Transport
  }

  alias SalixSignal.{CallSignaling, GroupCall, Groups, Profiles, Storage}
  alias SalixSignal.CallMedia.Relays
  alias SalixSignal.Messaging.{GroupSend, Inbound, Pipeline}
  alias SalixSignal.Service.{Chat, Credentials}
  alias SalixSignal.Storage.Cipher
  alias SalixSignalProto.Group.{Params, ProfileKeyCredential, ServerParams}
  alias SalixSignalProto.PreKeys
  alias SalixSignalProto.SenderKey.Sending
  alias SalixSignalProto.ServiceId

  @registry SalixSignal.Account.Registry
  @hour_ms 3_600_000
  # Profile fetches for names run at most this many at a time; senders seen
  # by this process are remembered up to `@max_profile_checked`.
  @max_profile_fetches 4
  @max_profile_checked 10_000
  @profile_timeout_ms 15_000

  @pipeline_calls [
    :send_text,
    :send_reaction,
    :send_edit,
    :send_remote_delete,
    :send_typing,
    :send_receipt,
    :set_expire_timer,
    :send_profile_key,
    :send_pni_signature
  ]

  # `{:group, name, group_id, args}` requests: `SalixSignal.Messaging.GroupSend` functions.
  @group_sends [:send_text, :send_reaction, :send_edit, :send_remote_delete, :send_typing]

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :account_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 10_000
    }
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :account_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, id}})
  end

  @doc "The pipeline functions that `{:pipeline, name, args}` requests may call."
  def pipeline_calls, do: @pipeline_calls

  # --- init -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :account_id)

    with :ok <- KemSupport.check(),
         {:ok, _keys} <- Cipher.keys(),
         {:ok, %{epoch: epoch, account: account, delivered_seq: delivered} = claimed} <-
           Storage.claim(id, node()) do
      Logger.metadata(signal_account: id)
      opts = Keyword.put(opts, :last_send_timestamp, claimed.last_send_timestamp)
      state = start_runtime(id, epoch, account, delivered, opts)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_runtime(id, epoch, account, delivered, opts) do
    handler =
      Keyword.get_lazy(opts, :handler, fn ->
        Application.get_env(:salix_signal, :handler, SalixSignal.Account.NullHandler)
      end)

    environment = account.environment
    credentials = Credentials.device(account.aci, account.device_id, account.password)

    {:ok, chat} =
      Chat.start_link(
        [owner: self(), credentials: credentials, environment: environment] ++
          Keyword.get(opts, :chat, [])
      )

    transport =
      Keyword.get_lazy(opts, :transport, fn ->
        %{identified: {:chat, chat}, unidentified: Transport.http(environment)}
      end)

    server_params =
      Keyword.get_lazy(opts, :server_params, fn ->
        {:ok, params} = ServerParams.decode_public(ServerParams.production())
        params
      end)

    me = self()
    {:ok, calls} = start_call_signaling(id, account, handler, me, opts)

    {:ok, delivery} =
      Delivery.start_link(
        account_id: id,
        epoch: epoch,
        handler: handler,
        delivered: delivered,
        retry_ms: Keyword.get(opts, :delivery_retry_ms, 30_000)
      )

    {:ok, pipeline} =
      Pipeline.new(
        [
          account: %{
            aci: account.aci,
            pni: account.pni,
            e164: Map.get(account, :e164),
            device_id: account.device_id,
            identities: account.identities,
            registration_ids: account.registration_ids,
            profile_key: account.profile_key
          },
          store: {Storage, id},
          epoch: epoch,
          transport: transport,
          environment: environment,
          rotate_pre_keys: fn kind -> rotate_pre_keys(id, epoch, transport, kind) end,
          call_message: fn call -> CallSignaling.receive_message(calls, call) end,
          last_timestamp: Keyword.fetch!(opts, :last_send_timestamp)
        ] ++ Keyword.get(opts, :pipeline, [])
      )

    %{
      id: id,
      epoch: epoch,
      account: account,
      handler: handler,
      chat: chat,
      calls: calls,
      delivery: delivery,
      transport: transport,
      pipeline: pipeline,
      server_params: server_params,
      groups_opts: Keyword.get(opts, :groups, []) ++ [environment: environment],
      attachments_opts: [environment: environment] ++ Keyword.get(opts, :attachments, []),
      group_call_opts: Keyword.get(opts, :group_call, []),
      group_client: nil,
      call_relays: nil,
      profile_credential: nil,
      profile_fetches: %{},
      profile_checked: MapSet.new(),
      group_calls: %{},
      maintained?: false,
      maintenance_interval_ms: Keyword.get(opts, :maintenance_interval_ms, 6 * @hour_ms),
      prune_interval_ms: Keyword.get(opts, :prune_interval_ms, @hour_ms)
    }
    |> tap(fn state -> Process.send_after(self(), :prune, state.prune_interval_ms) end)
  end

  defp start_call_signaling(id, account, handler, me, opts) do
    CallSignaling.start_link(
      [
        aci: account.aci,
        device_id: account.device_id,
        identity_key: account.identities.aci.public,
        ice_servers: fn -> GenServer.call(me, :call_ice_servers, 15_000) end,
        peer_identity_key: fn aci ->
          case Storage.identity(id, aci) do
            nil -> :error
            key -> {:ok, key}
          end
        end,
        send: fn recipient, message, %{urgent: urgent} ->
          GenServer.call(me, {:send_call_message, recipient, message, urgent}, 20_000)
        end,
        incoming_call: fn info -> incoming_call(id, account.aci, handler, info) end,
        admit: fn info, connection -> handler.admit_call(id, info, connection) end,
        opaque: fn inbound -> group_call_opaque(id, account.aci, handler, inbound) end
      ] ++ Keyword.get(opts, :call_signaling, [])
    )
  end

  # CRS-12 section 8: an offer to a device that is in a group call is
  # answered busy. The account's group-call sessions run on this node
  # (`SalixSignal.GroupCall`), like its 1:1 calls.
  defp incoming_call(id, aci, handler, info) do
    if GroupCall.active?(aci), do: :busy, else: handler.incoming_call(id, info)
  end

  # Opaque call payloads carry group-call material (CRS-12 section 5.4):
  # media keys and leave notices go to the account's session for their
  # group, and rings younger than 60 seconds become `{:group_call_ring,
  # group_id, ring_id, :ring | :cancelled, sender_aci}` handler events
  # (CRS-14 sections 9.4 and 11). This runs in the call-signaling process.
  defp group_call_opaque(id, aci, handler, inbound) do
    on_ring = fn %{group_id: group_id, ring_id: ring_id, type: type, sender_aci: sender} ->
      if type in [:ring, :cancelled],
        do: notify_handler(handler, id, {:group_call_ring, group_id, ring_id, type, sender})
    end

    GroupCall.handle_opaque(aci, inbound, on_ring: on_ring)
  end

  # --- requests -------------------------------------------------------------

  @impl true
  def handle_call({:pipeline, function, args}, _from, state) when function in @pipeline_calls do
    apply(Pipeline, function, [state.pipeline | args])
    |> reply_send(state)
  end

  def handle_call({:send_call_message, recipient, message, urgent}, _from, state) do
    case Pipeline.send_call_message(state.pipeline, recipient, message, %{urgent: urgent}) do
      {:ok, info, pipeline} -> reply(:ok, info.events, %{state | pipeline: pipeline})
      {:error, reason, pipeline} -> reply({:error, reason}, [], %{state | pipeline: pipeline})
    end
  end

  def handle_call(:call_ice_servers, _from, state) do
    now = System.system_time(:millisecond)

    case state.call_relays do
      %{expires_at_ms: expires, relays: relays} when expires > now ->
        {:reply, {:ok, Relays.ice_servers(relays)}, state}

      _ ->
        request = fn path ->
          case Transport.request(state.transport.identified, "GET", path, timeout: 10_000) do
            {:ok, response} -> {:ok, response.status, response.body}
            {:error, reason} -> {:error, reason}
          end
        end

        case Relays.fetch(request, now) do
          {:ok, cache} ->
            case Relays.ice_servers(cache.relays) do
              [] -> {:reply, {:error, :no_usable_call_relays}, state}
              servers -> {:reply, {:ok, servers}, %{state | call_relays: cache}}
            end

          {:error, reason} ->
            Logger.warning("signal call relay request failed")
            {:reply, {:error, {:call_relays, reason}}, state}
        end
    end
  end

  def handle_call({:set_profile, fields}, _from, state) do
    fields = Map.merge(fields, %{aci: state.account.aci, profile_key: state.account.profile_key})
    {:reply, Profiles.set_profile(state.chat, fields, timeout: 10_000), state}
  end

  def handle_call({:group, function, group_id, args}, _from, state)
      when function in @group_sends do
    apply(GroupSend, function, [state.pipeline, group_id | args])
    |> reply_send(state)
  end

  # Groups this account is a full member of (a left group stays stored).
  def handle_call(:groups, _from, state) do
    groups =
      for group <- Storage.groups(state.id),
          summary = group_summary(state, group),
          summary.member?,
          do: Map.delete(summary, :member?)

    {:reply, {:ok, groups}, state}
  end

  # The chat socket and upload options for `SalixSignal.Account.upload_attachment/3`,
  # which uploads in the caller's process.
  def handle_call(:attachment_context, _from, state),
    do: {:reply, {:ok, %{chat: state.chat, opts: state.attachments_opts}}, state}

  # A storage-service client with today's group credentials, for work that
  # runs outside this process (the group-call membership token).
  def handle_call(:group_client, _from, state) do
    case group_client(state) do
      {:ok, client, state} -> {:reply, {:ok, client}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  # What `SalixSignal.Account.add_group_members/3` needs to build the new
  # members' presentations in the caller's process: the chat socket, the
  # group params and each account's stored profile key (CRS-09b section 7).
  def handle_call({:member_profiles, group_id, acis}, _from, state) do
    case GroupSend.member_group(state.pipeline, group_id) do
      {:ok, group} ->
        keys =
          Map.new(acis, fn aci ->
            case Pipeline.read(state.pipeline, :contact, [aci]) do
              %{profile_key: <<_::binary-size(32)>> = key} -> {aci, key}
              _ -> {aci, nil}
            end
          end)

        {:reply,
         {:ok,
          %{
            chat: state.chat,
            server_params: state.server_params,
            params: Params.from_master_key(group.master_key),
            now_s: div(now(state), 1000),
            profile_keys: keys
          }}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:change_members, group_id, change}, _from, state) do
    with {:ok, client, state} <- group_client(state) do
      case GroupSync.change_members(
             state.pipeline,
             client,
             state.server_params,
             group_id,
             change
           ) do
        {:ok, revision, pipeline} ->
          notify(state, {:group_updated, group_id, revision})
          reply({:ok, revision}, [], %{state | pipeline: pipeline})

        {:error, reason, pipeline} ->
          reply({:error, reason}, [], %{state | pipeline: pipeline})
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:join_group_call, group_id, opts}, _from, state) do
    {result, state} = join_group_call(state, group_id, opts)
    {:reply, result, state}
  end

  def handle_call({:group_call_message, group_id, acis, message, urgent}, _from, state) do
    GroupCalls.send_call_message(state.pipeline, group_id, acis, message, urgent)
    |> reply_send(state)
  end

  def handle_call({:group_call_update, group_id, era_id}, _from, state) do
    GroupSend.send_call_update(state.pipeline, group_id, era_id)
    |> reply_send(state)
  end

  def handle_call({:join_group, url}, _from, state) do
    with {:ok, client, state} <- group_client(state),
         {:ok, presentation, state} <- presentation(state) do
      case GroupSync.join(state.pipeline, client, state.server_params, url, presentation) do
        {:ok, joined, pipeline} -> reply({:ok, joined}, [], %{state | pipeline: pipeline})
        {:error, reason, pipeline} -> reply({:error, reason}, [], %{state | pipeline: pipeline})
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, peer_aci}, _from, state) do
    {:reply, CallSignaling.call(state.calls, peer_aci), state}
  end

  def handle_call(:epoch, _from, state), do: {:reply, state.epoch, state}

  defp reply_send({:ok, info, pipeline}, state),
    do:
      reply({:ok, Map.delete(info, :events)}, Map.get(info, :events, []), %{
        state
        | pipeline: pipeline
      })

  defp reply_send({:error, reason, pipeline}, state),
    do: reply({:error, reason}, [], %{state | pipeline: pipeline})

  defp reply({:error, :fenced} = result, _events, state),
    do: {:stop, {:shutdown, :fenced}, result, state}

  defp reply(result, events, state) do
    case handle_events(events, state) do
      {:ok, state} -> {:reply, result, state}
      {:stop, reason, state} -> {:stop, reason, result, state}
    end
  end

  # Status and crash reports never show key material, session state,
  # profile keys, the device password or message content: the state keeps
  # only its identifiers, and requests only their name.
  @impl true
  def format_status(status) do
    status
    |> Map.update(:state, nil, fn
      %{id: id, epoch: epoch} ->
        %{id: id, epoch: epoch, redacted: true}

      other ->
        other
    end)
    |> Map.update(:message, nil, &redact_message/1)
  end

  defp redact_message(message) when is_tuple(message) and tuple_size(message) > 0,
    do: {elem(message, 0), :redacted}

  defp redact_message(message), do: message

  # --- chat events ------------------------------------------------------------

  @impl true
  def handle_info(
        {:signal_chat, chat, {:message, envelope, delivery_ms, token}},
        %{chat: chat} = state
      ) do
    {events, pipeline} =
      Pipeline.handle_chat_message(state.pipeline, chat, envelope, delivery_ms, token)

    case handle_events(events, %{state | pipeline: pipeline}) do
      {:ok, state} ->
        Delivery.notify(state.delivery)
        {:noreply, state}

      {:stop, reason, state} ->
        {:stop, reason, state}
    end
  end

  def handle_info({:signal_chat, chat, {:connected, _info}}, %{chat: chat} = state) do
    unless state.maintained?, do: send(self(), {:maintain, true})
    {:noreply, %{state | maintained?: true}}
  end

  def handle_info({:signal_chat, chat, {:stopped, reason}}, %{chat: chat} = state) do
    Logger.warning("signal account chat stopped: #{inspect(reason)}")
    notify(state, {:account_stopped, reason})

    if reason in [:unauthorized, :reauthentication_required],
      do: Storage.set_state(state.id, :re_registering)

    {:stop, {:shutdown, reason}, state}
  end

  def handle_info({:signal_chat, _chat, _event}, state), do: {:noreply, state}

  def handle_info({:maintain, check?}, state) do
    state = maintain(state, check?)
    Process.send_after(self(), {:maintain, false}, state.maintenance_interval_ms)
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    Process.send_after(self(), :prune, state.prune_interval_ms)

    case Storage.prune(state.id, state.epoch) do
      {:ok, _count} -> {:noreply, state}
      {:error, :fenced} -> {:stop, {:shutdown, :fenced}, state}
    end
  end

  def handle_info({:EXIT, pid, {:shutdown, :fenced}}, %{delivery: pid} = state),
    do: {:stop, {:shutdown, :fenced}, state}

  def handle_info({:EXIT, pid, reason}, state)
      when pid in [state.chat, state.calls, state.delivery],
      do: {:stop, {:linked_exit, reason}, state}

  def handle_info({:DOWN, ref, :process, _pid, {:profile, aci, key, result}}, state)
      when is_map_key(state.profile_fetches, ref),
      do:
        profile_fetched(
          %{state | profile_fetches: Map.delete(state.profile_fetches, ref)},
          aci,
          key,
          result
        )

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.profile_fetches, ref),
      do: {:noreply, %{state | profile_fetches: Map.delete(state.profile_fetches, ref)}}

  def handle_info({:signal_group_call, session, event}, state),
    do: {:noreply, group_call_event(state, session, event)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when is_map_key(state.group_calls, pid),
      do: {:noreply, %{state | group_calls: Map.delete(state.group_calls, pid)}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_map(state) do
      for pid <- [state[:delivery], state[:calls], state[:chat]],
          is_pid(pid),
          Process.alive?(pid),
          do: Process.exit(pid, :shutdown)
    end

    :ok
  end

  # --- pipeline events ----------------------------------------------------------

  defp handle_events(events, state) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case handle_event(event, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:stop, reason, state} -> {:halt, {:stop, reason, state}}
      end
    end)
  end

  defp handle_event(:fenced, state), do: {:stop, {:shutdown, :fenced}, state}

  # CRS-09b section 9: apply the carried change when it is the next
  # revision and verifies, otherwise fetch the full state.
  defp handle_event({:group_seen, master_key, revision, change}, state) do
    case GroupSync.apply_change(state.pipeline, state.server_params, master_key, revision, change) do
      :not_applicable -> refresh_group(state, master_key)
      result -> group_result(state, master_key, result)
    end
  end

  # CRS-07 §6.3: after a sender-key failure the requester's device gets
  # the distribution message again with the next group send.
  defp handle_event({:sender_key_reset, name, device, <<_::binary-size(32)>> = group_id}, state) do
    with %{sending: %Sending{} = sending} = group <-
           Pipeline.read(state.pipeline, :group, [group_id]),
         {:ok, id} <- ServiceId.parse(name) do
      sending = Sending.forget_delivered(sending, [{id, device}])

      case Pipeline.write(state.pipeline, [{:put_group, group_id, %{group | sending: sending}}]) do
        :ok -> {:ok, state}
        {:error, :fenced} -> {:stop, {:shutdown, :fenced}, state}
      end
    else
      _ -> {:ok, state}
    end
  end

  defp handle_event({:message, %Inbound{sender: sender}}, state) when is_binary(sender),
    do: {:ok, check_profile_name(state, sender)}

  defp handle_event({:message, _inbound}, state), do: {:ok, state}

  defp handle_event({:pni_signature_needed, recipient}, state) do
    case Pipeline.send_pni_signature(state.pipeline, recipient) do
      {:ok, info, pipeline} ->
        handle_events(info.events, %{state | pipeline: pipeline})

      {:error, :fenced, pipeline} ->
        {:stop, {:shutdown, :fenced}, %{state | pipeline: pipeline}}

      {:error, _reason, pipeline} ->
        Logger.warning("signal phone-number identity reply failed")
        {:ok, %{state | pipeline: pipeline}}
    end
  end

  defp handle_event({:profile_key_changed, aci} = event, state) do
    notify(state, event)
    state = %{state | profile_checked: MapSet.delete(state.profile_checked, aci)}
    {:ok, check_profile_name(state, aci)}
  end

  defp handle_event(event, state) when is_tuple(event) do
    if elem(event, 0) in [
         :identity_changed,
         :profile_key_changed,
         :expire_timer_changed,
         :decryption_failed
       ],
       do: notify(state, event)

    {:ok, state}
  end

  defp handle_event(_event, state), do: {:ok, state}

  defp refresh_group(state, master_key) do
    case group_client(state) do
      {:ok, client, state} ->
        result = GroupSync.refresh(state.pipeline, client, state.server_params, master_key)
        group_result(state, master_key, result)

      {:error, reason, state} ->
        Logger.info("signal group credentials unavailable: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp group_result(state, master_key, result) do
    case result do
      {:ok, group, pipeline} ->
        state = %{state | pipeline: pipeline}

        if GroupSync.invitation(pipeline, group.state) do
          with {:ok, client, state} <- group_client(state),
               {:ok, presentation, state} <- presentation(state) do
            result =
              GroupSync.accept_invitation(
                pipeline,
                client,
                state.server_params,
                group,
                presentation
              )

            case result do
              {:ok, accepted, pipeline} ->
                group_updated(%{state | pipeline: pipeline}, master_key, accepted)

              error ->
                group_result(state, master_key, error)
            end
          else
            {:error, reason, state} ->
              group_result(state, master_key, {:error, reason, state.pipeline})
          end
        else
          group_updated(state, master_key, group)
        end

      {:error, :fenced, pipeline} ->
        {:stop, {:shutdown, :fenced}, %{state | pipeline: pipeline}}

      {:error, reason, pipeline} ->
        Logger.info("signal group refresh failed: #{inspect(reason)}")
        {:ok, %{state | pipeline: pipeline}}
    end
  end

  defp group_updated(state, master_key, group) do
    group_id = SalixSignalProto.Group.Params.from_master_key(master_key).group_id
    notify(state, {:group_updated, group_id, group.revision})
    {:ok, state}
  end

  defp notify(state, event), do: notify_handler(state.handler, state.id, event)

  defp notify_handler(handler, id, event) do
    if function_exported?(handler, :handle_event, 2) do
      try do
        handler.handle_event(id, event)
      rescue
        error -> Logger.warning("signal handler event failed: #{Exception.message(error)}")
      end
    end

    :ok
  end

  # --- pre-keys ---------------------------------------------------------------------

  defp maintain(state, check?) do
    maintain_kinds(state, check?)
    state
  rescue
    error ->
      Logger.warning("signal pre-key maintenance failed: #{Exception.message(error)}")
      state
  end

  defp maintain_kinds(state, check?) do
    for kind <- [:aci, :pni],
        store = Storage.pre_key_store(state.id, kind),
        store != nil do
      persist = fn store -> commit_pre_keys(state.id, state.epoch, kind, store) end

      case PreKeyService.maintain(state.transport.identified, kind, store, now(state), persist,
             check: check?
           ) do
        {:ok, _store} -> :ok
        {:error, reason, _store} -> Logger.info("signal pre-key maintenance: #{inspect(reason)}")
      end
    end
  end

  # CRS-07 §6.2: before a retry request for a failed pre-key message, the
  # receiver replaces its signed and last-resort pre-keys.
  defp rotate_pre_keys(id, epoch, transport, kind) do
    with %PreKeys.Store{} = store <- Storage.pre_key_store(id, kind),
         {planned, body} = PreKeys.Store.rotate_all(store, System.system_time(:millisecond)),
         :ok <- commit_pre_keys(id, epoch, kind, planned),
         :ok <- PreKeyService.upload(identified(transport), kind, body) do
      commit_pre_keys(id, epoch, kind, PreKeys.Store.uploaded(planned))
    else
      other -> Logger.info("signal pre-key rotation: #{inspect(other)}")
    end
  end

  defp identified(%{identified: transport}), do: transport

  defp commit_pre_keys(id, epoch, kind, store),
    do: Storage.commit(id, epoch, [{:put_pre_keys, kind, store}])

  # --- groups -------------------------------------------------------------------------

  # Group auth credentials for today to today + 7 days (CRS-09b section 2),
  # fetched again when today's is missing.
  defp group_client(state) do
    today = div(div(now(state), 1000), 86_400) * 86_400

    case state.group_client do
      %{credentials: credentials} = client when is_map_key(credentials, today) ->
        {:ok, client, state}

      _ ->
        {:ok, aci} = ServiceId.aci_from_string(state.account.aci)

        case Groups.fetch_credentials(state.chat, state.server_params, aci, state.groups_opts) do
          {:ok, credentials} ->
            client = Groups.client(state.server_params, credentials, state.groups_opts)
            {:ok, client, %{state | group_client: client}}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  # The account's own expiring profile key credential (CRS-08, CRS-09a
  # section 14), kept until it expires.
  defp presentation(state) do
    now_s = div(now(state), 1000)

    credential =
      case state.profile_credential do
        {credential, expiration} when expiration > now_s -> {:ok, credential, expiration}
        _ -> fetch_credential(state, now_s)
      end

    case credential do
      {:ok, credential, expiration} ->
        present = fn params ->
          {:ok, {presentation, _uid, _key}} =
            ProfileKeyCredential.present(state.server_params, params, credential)

          presentation
        end

        {:ok, present, %{state | profile_credential: {credential, expiration}}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp fetch_credential(state, now_s, initialize? \\ true) do
    case Profiles.get_profile(state.chat, state.account.aci,
           profile_key: state.account.profile_key,
           credential: %{server_params: state.server_params, now: now_s}
         ) do
      {:ok, %{credential: credential, credential_expiration: expiration}}
      when is_binary(credential) ->
        {:ok, credential, expiration}

      {:ok,
       %{
         credential: nil,
         name: nil,
         about: nil,
         about_emoji: nil,
         avatar: nil,
         key_mismatch: false
       }}
      when initialize? ->
        fields = %{
          aci: state.account.aci,
          profile_key: state.account.profile_key,
          given_name: "Comma",
          avatar: :keep
        }

        case Profiles.set_profile(state.chat, fields, timeout: 10_000) do
          {:ok, _} -> fetch_credential(state, now_s, false)
          {:error, reason} -> {:error, reason}
        end

      {:ok, _profile} ->
        {:error, :no_profile_credential}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp group_summary(state, group) do
    params = SalixSignalProto.Group.Params.from_master_key(group.master_key)
    own = {:aci, elem(ServiceId.aci_from_string(state.account.aci), 1)}

    {title, members, admin?} =
      case group.state do
        nil ->
          {nil, [], false}

        group_state ->
          members = for {:aci, _} = id <- group_state.members |> Enum.map(& &1.service_id), do: id
          me = Enum.find(group_state.members, &(&1.service_id == own))

          {group_state.title, Enum.map(members, &ServiceId.to_string/1),
           me != nil and me.role == SalixSignalProto.Group.State.role_admin()}
      end

    %{
      group_id: params.group_id,
      title: title,
      revision: group.revision,
      members: members,
      admin?: admin?,
      member?: group.state == nil or state.account.aci in members
    }
  end

  # --- group calls ----------------------------------------------------------------------

  # Starts a group-call session on this node (the account's owner node,
  # where its 1:1 busy rule and opaque payloads find it) with this
  # account's plug-ins. The session leaves when this process exits. `admit`
  # runs once the session has joined; an error makes the session leave.
  defp join_group_call(state, group_id, opts) do
    aci = state.account.aci

    with {:ok, group} <- GroupSend.member_group(state.pipeline, group_id),
         nil <- GroupCall.whereis(aci, group_id) do
      me = self()
      id = state.id
      params = Params.from_master_key(group.master_key)

      session_opts =
        [
          group_id: group_id,
          aci: aci,
          owner: me,
          token: fn -> group_call_token(me, params) end,
          members: fn -> GroupCalls.members(id, group_id) end,
          send: fn acis, message, %{urgent: urgent} ->
            call_owner(me, {:group_call_message, group_id, acis, message, urgent})
          end,
          announce: fn era_id -> call_owner(me, {:group_call_update, group_id, era_id}) end
        ] ++ state.group_call_opts

      case GroupCall.join(session_opts) do
        {:ok, session} ->
          Process.monitor(session)
          entry = %{group_id: group_id, admit: Keyword.get(opts, :admit)}
          {{:ok, session}, %{state | group_calls: Map.put(state.group_calls, session, entry)}}

        {:error, {:shutdown, :already_in_call}} ->
          {{:error, :already_in_call}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
      session when is_pid(session) -> {{:error, :already_in_call}, state}
    end
  end

  # The membership token (CRS-14 section 4.1), fetched in the session's
  # process with this account's storage-service client.
  defp group_call_token(owner, params) do
    with {:ok, client} <- call_owner(owner, :group_client) do
      SalixSignal.GroupCall.Sfu.fetch_token(client, params)
    end
  end

  defp call_owner(owner, request) do
    GenServer.call(owner, request, 30_000)
  catch
    :exit, reason -> {:error, {:owner, reason}}
  end

  defp group_call_event(state, session, {:joined, %{era_id: era_id}}) do
    case state.group_calls do
      %{^session => %{admit: admit}} when is_function(admit, 2) ->
        admit_group_call(session, admit, era_id)
        state

      _ ->
        state
    end
  end

  defp group_call_event(state, session, {:left, _reason}),
    do: %{state | group_calls: Map.delete(state.group_calls, session)}

  defp group_call_event(state, _session, _event), do: state

  defp admit_group_call(session, admit, era_id) do
    Task.start(fn ->
      result =
        try do
          admit.(session, %{era_id: era_id})
        rescue
          error -> {:error, {:raised, Exception.message(error)}}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end

      case result do
        {:ok, _call_id} ->
          :ok

        other ->
          Logger.info("signal group call not admitted: #{inspect(other)}")
          GroupCall.leave(session)
      end
    end)
  end

  # --- profile names --------------------------------------------------------------------

  # Fetches the profile of a contact whose stored profile key has no name
  # read with it yet (CRS-08), at most `@max_profile_fetches` at a time.
  # A sender is checked once per process unless its profile key changes.
  defp check_profile_name(state, aci) do
    cond do
      MapSet.member?(state.profile_checked, aci) -> state
      aci in Map.values(state.profile_fetches) -> state
      map_size(state.profile_fetches) >= @max_profile_fetches -> state
      true -> fetch_profile_name(remember_checked(state, aci), aci)
    end
  end

  defp remember_checked(state, aci) do
    checked =
      if MapSet.size(state.profile_checked) >= @max_profile_checked,
        do: MapSet.new(),
        else: state.profile_checked

    %{state | profile_checked: MapSet.put(checked, aci)}
  end

  defp fetch_profile_name(state, aci) do
    case Pipeline.read(state.pipeline, :contact, [aci]) do
      %{profile_key: <<_::binary-size(32)>> = key} = contact ->
        if Map.get(contact, :profile_name_key) == key do
          state
        else
          chat = state.chat

          {_pid, ref} =
            spawn_monitor(fn ->
              result =
                Profiles.get_profile(chat, aci, profile_key: key, timeout: @profile_timeout_ms)

              exit({:profile, aci, key, result})
            end)

          %{state | profile_fetches: Map.put(state.profile_fetches, ref, aci)}
        end

      _ ->
        state
    end
  end

  defp profile_fetched(state, aci, key, {:ok, profile}) do
    case Pipeline.read(state.pipeline, :contact, [aci]) do
      %{profile_key: ^key} = contact ->
        contact =
          Map.merge(contact, %{profile_name: display_name(profile[:name]), profile_name_key: key})

        case Pipeline.write(state.pipeline, [{:put_contact, aci, contact}]) do
          :ok -> {:noreply, state}
          {:error, :fenced} -> {:stop, {:shutdown, :fenced}, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp profile_fetched(state, _aci, _key, result) do
    Logger.info("signal profile name unavailable: #{inspect(elem_reason(result))}")
    {:noreply, state}
  end

  defp elem_reason({:error, reason}), do: reason
  defp elem_reason(other), do: other

  @doc false
  # The profile name as people see it: given name, then family name.
  def display_name({given, family}) do
    [given, family]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map_join(" ", &String.trim/1)
    |> case do
      "" -> nil
      name -> name
    end
  end

  def display_name(_name), do: nil

  defp now(state), do: Pipeline.clock(state.pipeline)
end
