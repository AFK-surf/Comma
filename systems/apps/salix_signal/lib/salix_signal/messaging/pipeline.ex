defmodule SalixSignal.Messaging.Pipeline do
  @moduledoc """
  The receive and send pipelines of one Signal account (layer C5: CRS-05,
  CRS-06, CRS-07).

  The pipeline is a value that the account's owner process keeps and passes
  back in. It does its network requests through the account transports and
  its durable writes through `SalixSignal.Messaging.Store` commits fenced by
  the owner epoch. It holds no process of its own.

  ## Receiving

  The owner calls `receive_envelope/2` for each envelope that the chat
  socket pushes, then acknowledges the envelope only when the result is
  `:ack` (`handle_chat_message/4` does both). For each envelope the pipeline:

  1. skips an envelope whose server GUID was already admitted (a redelivery
     after a lost acknowledgement or a crash, CRS-07 §5.4);
  2. opens it with `SalixSignalProto.Receive.open/2`;
  3. commits, in one store commit, the session advance, identity and
     pre-key changes, the sender-key state that decrypted the message or
     that a received sender key distribution message changed (CRS-09c
     sections 5 and 7), contact changes (profile key, 1:1 timer) and the
     admission of the envelope with its outcome;
  4. then sends what the outcome needs: a delivery receipt for a stored data
     message or edit (CRS-07 §7.2), a retry request for a message that did
     not decrypt (CRS-07 §6), or the answer to a received retry request
     (CRS-07 §6.3);
  5. and returns `:ack`. Every envelope that reaches step 3 is acknowledged,
     including invalid and undecryptable ones (CRS-07 §5.3).

  A fenced commit (a newer owner exists) returns `:no_ack`; the service then
  keeps the envelope for the current owner.

  ## Bounded receive work (owner decision, availability)

  A forged message can make the receiver walk long chains before it
  fails. Two limits bound what one sender can cost the account's single
  writer:

    * Failure budget: after `failure_limit` decryption failures from one
      sender within `failure_window_ms`, further envelopes from that sender
      are dropped without decryption for `cooling_ms`. They are admitted
      (outcome `:drop`, reason `:sender_cooling`) and acknowledged like any
      dropped envelope, and no retry request is sent.
    * Work budget: opening one envelope (`SalixSignalProto.Receive.open/2`
      reads state and changes nothing) runs in a separate process for at
      most `decrypt_budget_ms`. An envelope that exceeds it is admitted as
      dropped (`:decryption_budget_exceeded`), acknowledged, and counts as a
      failure of its sender when the envelope names one. The commit stays in
      the owner process, so the commit-then-acknowledge order is unchanged.

  Both are recorded by `SalixSignal.Telemetry`.

  ## Sending

  `send_content/4` sends one serialized content container to every device
  of a recipient account, sealed when the pipeline has a sender certificate
  and the recipient's access key (CRS-06 §10.1), identified otherwise. The
  new session states are committed before the request, so a crash never
  reuses a message key. It corrects the device list after 409 and 410 and
  sends again with the same timestamp, at most `max_send_attempts` times in
  total (CRS-07 §4). The helpers `send_text/4`, `send_reaction/6`,
  `send_remote_delete/4`, `send_edit/5`, `send_typing/4`, `send_receipt/5`,
  `set_expire_timer/4` and `send_profile_key/3` build the content
  containers of CRS-05 with the flags of CRS-07 §9.

  ## Trust

  Comma trusts a peer identity key on first use and accepts a later change in
  both directions without blocking (CRS-04 §8.6 item 3, owner decision). A
  change is stored and reported as an `{:identity_changed, name}` event.

  ## Events

  Results carry events for the owner, for example
  `{:message, %SalixSignal.Messaging.Inbound{}}`, `{:dropped, reason}`,
  `{:decryption_failed, sender, notice}` (`notice` is `:now` or
  `:unless_resent`, CRS-06 §5.1), `{:identity_changed, name}`,
  `{:profile_key_changed, name}`, `{:expire_timer_changed, name, timer}`,
  `{:pni_signature_needed, name}` (CRS-05 §3.1),
  `{:rotate_pre_keys, :aci | :pni}` (CRS-07 §6.1, §6.2, for the account's
  pre-key owner), `{:sender_key_reset, name, device, group_id}` (layer C7),
  `{:sender_key_received, name, device, distribution_id}`,
  `{:sender_key_rejected, name, device, reason}`, `{:group_seen,
  master_key, revision, signed_change | nil}` (a group message names a group
  this account does not know, or a newer revision than the stored one;
  CRS-09b section 9), `{:retry_limited, sender}` and
  `{:retry_answer_limited, sender}` (a retry request not sent, or not
  answered, because of the per-sender bound) and
  `{:send_failed, what, reason}`.
  """

  require Logger

  alias SalixSignal.Account.KemSupport
  alias SalixSignal.Account.Transport
  alias SalixSignal.Messaging.{Api, Inbound}
  alias SalixSignal.Service.{Chat, Response}
  alias SalixSignalProto.{Address, PreKeyBundle, Receive, SealedSender, ServiceId, Session}
  alias SalixSignalProto.Message.{Content, DecryptionError, Envelope, ExpireTimer, Padding}
  alias SalixSignalProto.SenderKey
  alias SalixSignalProto.SealedSender.{AccessKey, Certificate, Inner}
  alias SalixSignalProto.Session.State

  @implicit 2
  @resendable 1

  @default_config %{
    max_send_attempts: 4,
    certificate_margin_ms: 24 * 60 * 60 * 1000,
    retry_request_limit: 5,
    retry_request_quiet_ms: 60 * 60 * 1000,
    sealed_fallback: :identified,
    failure_limit: 20,
    failure_window_ms: 10 * 60 * 1000,
    cooling_ms: 10 * 60 * 1000,
    decrypt_budget_ms: 5_000
  }

  @enforce_keys [
    :account,
    :store,
    :epoch,
    :transport,
    :trust_roots,
    :known_server_certificates,
    :clock
  ]
  defstruct [
    :account,
    :store,
    :epoch,
    :transport,
    :trust_roots,
    :known_server_certificates,
    :clock,
    sender_key: nil,
    rotate_pre_keys: nil,
    call_message: nil,
    sender_certificate: nil,
    certificate_refresh_at: nil,
    last_timestamp: 0,
    retry_counts: %{},
    retry_answers: %{},
    failures: %{},
    config: @default_config
  ]

  @type transport ::
          Transport.t()
          | (String.t(), String.t(), keyword() -> {:ok, Response.t()} | {:error, term()})
  @type t :: %__MODULE__{}
  @type event :: tuple()

  @doc """
  A pipeline for one account. Refuses to start when this node lacks the
  constant-time KEM support that decapsulating pre-key messages needs
  (owner KEM decision, `SalixSignal.Account.KemSupport`).

  Options:

    * `:account` (required): `%{aci: uuid string, pni: uuid string | nil,
      device_id: 1..127, identities: %{aci: key_pair, pni: key_pair | nil},
      registration_ids: %{aci: n, pni: n}, profile_key: 32 bytes | nil}`,
      and optionally `e164` (the account's number, for the self-send check
      of CRS-06 §9);
    * `:store` (required): `{module, handle}` of a `SalixSignal.Messaging.Store`;
    * `:epoch` (required): the owner epoch that fences commits;
    * `:transport` (required): `%{identified: t, unidentified: t}`, each a
      `SalixSignal.Account.Transport` or a function
      `(method, path, opts) -> {:ok, response} | {:error, reason}`;
    * `:environment`: `:production` (default) or `:staging`, which selects
      the trust roots and known server certificates (CRS-06 §3.4, §3.5);
    * `:trust_roots`, `:known_server_certificates`: explicit values instead;
    * `:clock`: `(-> ms)`, default the system clock;
    * `:sender_key`: a replacement for the sender-key decryption
      (`SalixSignalProto.Receive` context `:sender_key`); by default the
      pipeline decrypts with the sender keys in the store;
    * `:rotate_pre_keys`: `(:aci | :pni -> any)`, called before a retry
      request for a failed pre-key message (CRS-07 §6.2);
    * `:last_timestamp`: the highest send timestamp of an earlier owner
      (`SalixSignal.Storage.claim/2`); new timestamps are greater;
    * `:call_message`: `(map -> any)`, receives each call message (content
      field 3) after its envelope is committed, as the input of
      `SalixSignal.CallSignaling.receive_message/2`: `%{sender_aci,
      sender_device_id, call_message, server_timestamp_ms,
      delivery_timestamp_ms}`;
    * `:config`: overrides of `max_send_attempts`, `certificate_margin_ms`
      (see `sender_certificate/1`), `retry_request_limit` and
      `retry_request_quiet_ms` (they bound both the retry requests sent to
      and the retry requests answered for one sender), `sealed_fallback`
      (`:identified` or `:fail`, CRS-07 open question 7), `failure_limit`,
      `failure_window_ms`, `cooling_ms` and `decrypt_budget_ms` (see
      "Bounded receive work").
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, :kem_unsupported}
  def new(opts) do
    with :ok <- KemSupport.check() do
      environment = Keyword.get(opts, :environment, :production)

      {:ok,
       %__MODULE__{
         account: account(Keyword.fetch!(opts, :account)),
         store: Keyword.fetch!(opts, :store),
         epoch: Keyword.fetch!(opts, :epoch),
         transport: Keyword.fetch!(opts, :transport),
         trust_roots:
           Keyword.get_lazy(opts, :trust_roots, fn -> Certificate.trust_roots(environment) end),
         known_server_certificates:
           Keyword.get_lazy(opts, :known_server_certificates, fn ->
             Certificate.known_server_certificates(environment)
           end),
         clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
         sender_key: Keyword.get(opts, :sender_key),
         rotate_pre_keys: Keyword.get(opts, :rotate_pre_keys),
         call_message: Keyword.get(opts, :call_message),
         last_timestamp: Keyword.get(opts, :last_timestamp, 0),
         config: Map.merge(@default_config, Map.new(Keyword.get(opts, :config, [])))
       }}
    end
  end

  defp account(%{aci: aci, device_id: device_id} = account) do
    {:ok, aci_uuid} = ServiceId.aci_from_string(aci)

    pni_uuid =
      case Map.get(account, :pni) do
        nil -> nil
        pni -> pni |> ServiceId.aci_from_string() |> elem(1)
      end

    Map.merge(account, %{
      aci_uuid: aci_uuid,
      pni_uuid: pni_uuid,
      address: Address.new(aci, device_id)
    })
  end

  # --- receiving ------------------------------------------------------------

  @doc """
  Handles one envelope pushed by `SalixSignal.Service.Chat` (the event
  `{:message, envelope, server_delivery_ms, ack_token}`) and acknowledges
  it on `chat` when the pipeline says so. Returns the events and the new
  pipeline.
  """
  @spec handle_chat_message(
          t(),
          GenServer.server(),
          binary(),
          non_neg_integer() | nil,
          Chat.ack_token()
        ) ::
          {[event()], t()}
  def handle_chat_message(pipeline, chat, envelope, server_delivery_ms, ack_token) do
    {ack, events, pipeline} =
      receive_envelope(pipeline, envelope, server_delivery_ms: server_delivery_ms)

    if ack == :ack, do: Chat.ack(chat, ack_token, 200)
    {events, pipeline}
  end

  @doc """
  Processes one serialized server envelope (see the module documentation).
  Option `:server_delivery_ms`: the `X-Signal-Timestamp` of the push
  (CRS-07 §5.2). Returns `{:ack | :no_ack, events, pipeline}`.
  """
  @spec receive_envelope(t(), binary(), keyword()) :: {:ack | :no_ack, [event()], t()}
  def receive_envelope(%__MODULE__{} = pipeline, bytes, opts \\ []) when is_binary(bytes) do
    case Envelope.decode(bytes) do
      {:error, :malformed} ->
        # One client answers 500 here, which returns the envelope on every
        # connection; Comma acknowledges it (CRS-07 §5.3).
        {:ack, [{:dropped, :malformed_envelope}], pipeline}

      {:ok, %Envelope{server_guid: guid} = envelope} ->
        if guid != nil and store(pipeline, :admitted?, [guid]) do
          {:ack, [{:redelivered, guid}], pipeline}
        else
          process(pipeline, envelope, Keyword.get(opts, :server_delivery_ms))
        end
    end
  end

  defp process(pipeline, envelope, delivery_ms) do
    result = open_bounded(pipeline, envelope)
    pipeline = count_failure(pipeline, result)
    {pipeline, plan} = plan(pipeline, result, delivery_ms)

    case commit(pipeline, plan.ops) do
      :ok ->
        {pipeline, later_events} = run_actions(pipeline, plan.actions)
        {:ack, plan.events ++ later_events, pipeline}

      {:error, :fenced} ->
        {:no_ack, [:fenced], pipeline}
    end
  end

  # Opening reads state only; it runs in a task under the work budget.
  defp open_bounded(pipeline, envelope) do
    context = receive_context(pipeline)
    task = Task.async(fn -> Receive.open(envelope, context) end)

    case Task.yield(task, pipeline.config.decrypt_budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, %Receive.Result{} = result} ->
        if result.reason == :sender_cooling,
          do: SalixSignal.Telemetry.receive_guard(:sender_cooling)

        result

      {:exit, reason} ->
        exit(reason)

      nil ->
        SalixSignal.Telemetry.receive_guard(:budget_exceeded)

        sender =
          case envelope.source do
            {:aci, <<_::binary-size(16)>> = uuid} -> uuid
            _ -> nil
          end

        %Receive.Result{
          outcome: :drop,
          reason: :decryption_budget_exceeded,
          envelope: envelope,
          sender: sender,
          sender_device: envelope.source_device
        }
    end
  end

  # The failure budget of one sender (see "Bounded receive work"). Entries
  # whose window and cooling period have both passed are forgotten, so the
  # map holds only senders that failed recently.
  defp count_failure(pipeline, %Receive.Result{sender: <<_::binary-size(16)>> = sender} = result)
       when result.outcome == :failed or result.reason == :decryption_budget_exceeded do
    now = now(pipeline)
    config = pipeline.config

    recent =
      Map.reject(pipeline.failures, fn {_sender, {_count, first, until}} ->
        now - first >= config.failure_window_ms and until <= now
      end)

    {count, first, until} =
      case Map.get(recent, sender) do
        {count, first, until} when now - first < config.failure_window_ms -> {count, first, until}
        {_count, _first, until} -> {0, now, until}
        nil -> {0, now, 0}
      end

    entry =
      if count + 1 >= config.failure_limit do
        SalixSignal.Telemetry.receive_guard(:cooling_started)
        {0, now, now + config.cooling_ms}
      else
        {count + 1, first, until}
      end

    %{pipeline | failures: Map.put(recent, sender, entry)}
  end

  defp count_failure(pipeline, _result), do: pipeline

  defp sender_allowed?(failures, now) do
    fn sender ->
      case Map.get(failures, sender) do
        {_count, _first, until} when until > now -> false
        _ -> true
      end
    end
  end

  defp receive_context(pipeline) do
    account = pipeline.account

    %{
      aci: account.aci_uuid,
      pni: account.pni_uuid,
      e164: Map.get(account, :e164),
      device_id: account.device_id,
      identities: account.identities,
      registration_ids: account.registration_ids,
      trust_roots: pipeline.trust_roots,
      known_server_certificates: pipeline.known_server_certificates,
      now_ms: now(pipeline),
      session: fn address -> store(pipeline, :session, [address]) end,
      pre_keys: fn kind -> store(pipeline, :pre_keys, [kind]) end,
      trusted?: fn _key, _direction -> true end,
      sender_allowed?: sender_allowed?(pipeline.failures, now(pipeline)),
      sender_key:
        pipeline.sender_key ||
          fn address, bytes, _group_id -> decrypt_sender_key(pipeline, address, bytes) end
    }
  end

  # CRS-09c section 5: the sender key of (sender address, distribution ID).
  # The update to commit is the record after this message.
  defp decrypt_sender_key(pipeline, address, bytes) do
    with {:ok, %{distribution_id: distribution}} <- SenderKey.Message.decode_message(bytes),
         %SenderKey.Record{} = record <-
           store(pipeline, :sender_key, [address, distribution]) || {:error, :no_sender_key},
         {:ok, plaintext, record} <- SenderKey.Record.decrypt(record, bytes) do
      {:ok, plaintext, {address, distribution, record}}
    end
  end

  # CRS-09c section 7 step 4: a content message with field 7 carries a
  # sender key distribution message for the sender of that 1:1 message.
  defp distribution(
         pipeline,
         %Receive.Result{
           outcome: :message,
           sender: <<_::binary-size(16)>> = sender,
           sender_device: device,
           content: %{sender_key_distribution: bytes}
         }
       )
       when is_binary(bytes) do
    address = Address.new(ServiceId.to_string({:aci, sender}), device)

    with {:ok, %{distribution_id: distribution}} <- SenderKey.Message.decode_distribution(bytes),
         record = store(pipeline, :sender_key, [address, distribution]) || SenderKey.Record.new(),
         {:ok, record, ^distribution} <- SenderKey.Record.process_distribution(record, bytes) do
      {[{:sender_key, {address, distribution, record}}],
       [{:sender_key_received, address.name, device, distribution}]}
    else
      {:error, reason} -> {[], [{:sender_key_rejected, address.name, device, reason}]}
    end
  end

  defp distribution(_pipeline, _result), do: {[], []}

  # The commit and the actions after it for one Receive result.
  defp plan(pipeline, %Receive.Result{} = result, delivery_ms) do
    {session_ops, session_events} = session_changes(pipeline, result.session, result.destination)
    sender_key_ops = if result.sender_key != nil, do: [{:sender_key, result.sender_key}], else: []
    {distribution_ops, distribution_events} = distribution(pipeline, result)

    # A known sender that wrote to the PNI must later get a PNI signature
    # (CRS-05 §3.1, CRS-02); the account's owner sends it.
    pni_events =
      if result.needs_pni_signature? and result.sender != nil,
        do: [{:pni_signature_needed, ServiceId.to_string({:aci, result.sender})}],
        else: []

    base = %{
      ops: session_ops ++ sender_key_ops ++ distribution_ops,
      events: session_events ++ pni_events ++ distribution_events,
      actions: [],
      delivery_ms: delivery_ms
    }

    inbound = inbound(result)
    {pipeline, plan} = outcome(pipeline, result, inbound, base)
    {pipeline, %{plan | ops: plan.ops ++ admit(result, plan.inbound)}}
  end

  defp inbound(result) do
    envelope = result.envelope

    %Inbound{
      guid: envelope && envelope.server_guid,
      outcome: result.outcome,
      reason: result.reason,
      sender: result.sender && ServiceId.to_string({:aci, result.sender}),
      sender_device: result.sender_device,
      destination: result.destination,
      sealed?: result.sealed?,
      timestamp: envelope && envelope.client_timestamp,
      server_timestamp: envelope && envelope.server_timestamp,
      content_kind: result.content_kind,
      content: result.content && SalixSignalProto.Message.Wire.Content.encode(result.content),
      content_hint: result.content_hint,
      group_id: result.group_id
    }
  end

  defp admit(
         %Receive.Result{envelope: %Envelope{server_guid: <<_::binary-size(16)>> = guid}},
         inbound
       ),
       do: [{:admit, guid, inbound}]

  defp admit(_result, _inbound), do: []

  defp session_changes(_pipeline, nil, _destination), do: {[], []}

  defp session_changes(
         pipeline,
         %{address: address, record: record, effects: effects},
         destination
       ) do
    {identity_ops, identity_events} =
      identity_changes(pipeline, address.name, effects.identity_key)

    pre_key_ops =
      if effects.used_one_time_pre_key != nil or effects.used_kem_pre_key != nil,
        do: [{:pre_key_effects, destination, effects}],
        else: []

    {[{:put_session, address, record}] ++ identity_ops ++ pre_key_ops, identity_events}
  end

  # Trust on first use; a later change is accepted and reported (CRS-04
  # §8.6 item 3).
  defp identity_changes(pipeline, name, key) do
    case store(pipeline, :identity, [name]) do
      ^key -> {[], []}
      nil -> {[{:put_identity, name, key}], []}
      _other -> {[{:put_identity, name, key}], [{:identity_changed, name}]}
    end
  end

  defp outcome(pipeline, %Receive.Result{outcome: :message} = result, inbound, plan) do
    message(pipeline, result.content_kind, result, inbound, plan)
  end

  defp outcome(pipeline, %Receive.Result{outcome: :failed} = result, inbound, plan) do
    failed(pipeline, result, inbound, plan)
  end

  defp outcome(pipeline, %Receive.Result{outcome: :server_receipt} = result, inbound, plan) do
    event = {:server_receipt, inbound.sender, result.sender_device, inbound.timestamp}
    {pipeline, Map.put(%{plan | events: plan.events ++ [event]}, :inbound, inbound)}
  end

  defp outcome(pipeline, %Receive.Result{outcome: :unsupported} = result, inbound, plan) do
    event = {:unsupported, inbound.sender, result.reason}
    {pipeline, Map.put(%{plan | events: plan.events ++ [event]}, :inbound, inbound)}
  end

  defp outcome(pipeline, %Receive.Result{outcome: :drop} = result, inbound, plan) do
    {pipeline,
     Map.put(%{plan | events: plan.events ++ [{:dropped, result.reason}]}, :inbound, inbound)}
  end

  defp message(pipeline, kind, result, inbound, plan) when kind in [:data, :edit] do
    data =
      case kind do
        :data -> result.content.data_message
        :edit -> result.content.edit_message.data_message
      end

    conversation =
      if data.group_v2, do: {:group, data.group_v2.master_key}, else: {:direct, inbound.sender}

    key = {inbound.sender, data.timestamp, conversation}

    if store(pipeline, :message_seen?, [key]) do
      # The same author and timestamp in the same conversation: a duplicate,
      # for example a resend after a retry request (CRS-07 §5.4).
      inbound = %{inbound | outcome: :drop, reason: :duplicate_message, content: nil}

      {pipeline,
       Map.put(
         %{plan | events: plan.events ++ [{:dropped, :duplicate_message}]},
         :inbound,
         inbound
       )}
    else
      {contact_ops, contact_events} =
        if kind == :data, do: contact_changes(pipeline, inbound.sender, data), else: {[], []}

      plan = %{
        plan
        | ops: plan.ops ++ [{:record_message, key}] ++ contact_ops,
          events:
            plan.events ++ contact_events ++ [{:message, inbound}] ++ group_events(pipeline, data),
          actions: plan.actions ++ [{:receipt, inbound.sender, data.timestamp}]
      }

      {pipeline, Map.put(plan, :inbound, inbound)}
    end
  end

  defp message(pipeline, :decryption_error, result, inbound, plan) do
    {:ok, request} = DecryptionError.decode(result.content.decryption_error)
    requester = Address.new(inbound.sender, result.sender_device)
    record = store(pipeline, :session, [requester])
    action = Receive.handle_retry_request(request, pipeline.account.device_id, record)

    ops =
      case action do
        {:reset_session, record} -> [{:put_session, requester, record}]
        _ -> []
      end

    # Owner decision: at most `retry_request_limit` answers (resends or null
    # messages) per sender without a quiet period of
    # `retry_request_quiet_ms`, the bound on sending retry requests. The
    # session and sender-key state still change; only the send is skipped.
    {pipeline, allowed?} =
      if action == :ignore,
        do: {pipeline, true},
        else: count_recent(pipeline, :retry_answers, inbound.sender)

    {events, actions} =
      if allowed? do
        {[], [{:answer_retry, requester, request, action, result.group_id}]}
      else
        SalixSignal.Telemetry.receive_guard(:retry_answer_limited)

        reset =
          if action == :sender_key,
            do: [{:sender_key_reset, requester.name, requester.device_id, result.group_id}],
            else: []

        {reset ++ [{:retry_answer_limited, inbound.sender}], []}
      end

    plan = %{
      plan
      | ops: plan.ops ++ ops,
        events: plan.events ++ [{:message, inbound}] ++ events,
        actions: plan.actions ++ actions
    }

    {pipeline, Map.put(plan, :inbound, inbound)}
  end

  # Call messages go to call signaling after the commit (CRS-12; layer C9).
  defp message(pipeline, :call, result, inbound, plan) do
    call = %{
      sender_aci: inbound.sender,
      sender_device_id: result.sender_device,
      call_message: result.content.call_message,
      server_timestamp_ms: inbound.server_timestamp,
      delivery_timestamp_ms: plan.delivery_ms
    }

    plan = %{
      plan
      | events: plan.events ++ [{:message, inbound}],
        actions: plan.actions ++ [{:call_message, call}]
    }

    {pipeline, Map.put(plan, :inbound, inbound)}
  end

  defp message(pipeline, _kind, _result, inbound, plan) do
    {pipeline, Map.put(%{plan | events: plan.events ++ [{:message, inbound}]}, :inbound, inbound)}
  end

  # CRS-09b section 9: a group message names the sender's revision; the
  # owner fetches the group when it is unknown or newer than the stored one.
  defp group_events(pipeline, %{group_v2: %{master_key: key, revision: revision} = context})
       when is_binary(key) and is_integer(revision) do
    group_id = SalixSignalProto.Group.Params.from_master_key(key).group_id

    case store(pipeline, :group, [group_id]) do
      %{revision: stored, state: %{invited: invited}} when stored >= revision ->
        own = [{:aci, pipeline.account.aci_uuid}, {:pni, pipeline.account.pni_uuid}]

        if Enum.any?(invited, &(&1.service_id in own)),
          do: [{:group_seen, key, revision, context.group_change}],
          else: []

      _ ->
        [{:group_seen, key, revision, context.group_change}]
    end
  end

  defp group_events(_pipeline, _data), do: []

  # Profile key (CRS-05 §5.2) and 1:1 timer (CRS-05 §5.2) of a data message.
  defp contact_changes(pipeline, sender, data) do
    contact = contact(pipeline, sender)

    {contact, events} =
      case data.profile_key do
        <<_::binary-size(32)>> = key when key != contact.profile_key ->
          {%{contact | profile_key: key}, [{:profile_key_changed, sender}]}

        _ ->
          {contact, []}
      end

    {contact, events} =
      case ExpireTimer.apply_received(contact.expire_timer, data) do
        {:changed, timer} ->
          {%{contact | expire_timer: timer}, events ++ [{:expire_timer_changed, sender, timer}]}

        :unchanged ->
          {contact, events}
      end

    if events == [], do: {[], []}, else: {[{:put_contact, sender, contact}], events}
  end

  defp failed(pipeline, result, inbound, plan) do
    sender = inbound.sender
    prekey? = result.failed.type == :prekey

    notice =
      case result.content_hint do
        @implicit -> []
        @resendable -> [{:decryption_failed, sender, :unless_resent}]
        _default -> [{:decryption_failed, sender, :now}]
      end

    cond do
      # No retry request for a message to the PNI; a failed pre-key message
      # there rotates the PNI pre-keys instead (CRS-07 §6.1).
      result.destination == :pni ->
        rotate = if prekey?, do: [{:rotate_pre_keys, :pni}], else: []
        {pipeline, Map.put(%{plan | events: plan.events ++ rotate ++ notice}, :inbound, inbound)}

      true ->
        {pipeline, allowed?} = count_recent(pipeline, :retry_counts, sender)

        actions =
          case {allowed?, Receive.retry_request(result)} do
            {true, {:ok, message}} ->
              [
                {:retry_request, Address.new(sender, result.sender_device), message,
                 result.group_id, prekey?}
              ]

            _ ->
              []
          end

        events = if allowed?, do: notice, else: [{:retry_limited, sender} | notice]

        {pipeline,
         Map.put(
           %{plan | events: plan.events ++ events, actions: plan.actions ++ actions},
           :inbound,
           inbound
         )}
    end
  end

  # Retry requests to one sender (`:retry_counts`) and answers to one
  # sender's retry requests (`:retry_answers`) are limited: after
  # `retry_request_limit` of them without a quiet period of
  # `retry_request_quiet_ms`, no more are sent (CRS-07 §6.1; the limits are
  # Comma's, open question 4). Senders whose quiet period has passed are
  # forgotten, so each map holds only senders seen recently.
  defp count_recent(pipeline, field, sender) do
    now = now(pipeline)
    quiet = pipeline.config.retry_request_quiet_ms

    recent =
      pipeline
      |> Map.fetch!(field)
      |> Map.reject(fn {_sender, {_count, last}} -> now - last >= quiet end)

    count =
      case Map.get(recent, sender) do
        {count, _last} -> count + 1
        nil -> 1
      end

    pipeline = Map.put(pipeline, field, Map.put(recent, sender, {count, now}))
    {pipeline, count <= pipeline.config.retry_request_limit}
  end

  defp run_actions(pipeline, actions) do
    Enum.reduce(actions, {pipeline, []}, fn action, {pipeline, events} ->
      {pipeline, new_events} = run_action(pipeline, action)
      {pipeline, events ++ new_events}
    end)
  end

  # Comma sends a delivery receipt for every stored data message and edit
  # (CRS-07 §7.2).
  defp run_action(pipeline, {:receipt, author, timestamp}) do
    case send_receipt(pipeline, author, :delivery, [timestamp]) do
      {:ok, info, pipeline} -> {pipeline, info.events}
      {:error, reason, pipeline} -> {pipeline, [{:send_failed, :receipt, reason}]}
    end
  end

  defp run_action(pipeline, {:retry_request, address, message, group_id, prekey?}) do
    rotate_events =
      if prekey? do
        if pipeline.rotate_pre_keys, do: pipeline.rotate_pre_keys.(:aci)
        [{:rotate_pre_keys, :aci}]
      else
        []
      end

    case send_retry_request(pipeline, address, message, group_id) do
      {:ok, info, pipeline} ->
        {pipeline, rotate_events ++ info.events}

      {:error, reason, pipeline} ->
        {pipeline, rotate_events ++ [{:send_failed, :retry_request, reason}]}
    end
  end

  defp run_action(pipeline, {:call_message, call}) do
    if pipeline.call_message, do: pipeline.call_message.(call)
    {pipeline, []}
  end

  defp run_action(pipeline, {:answer_retry, requester, request, action, group_id}) do
    answer_retry(pipeline, requester, request, action, group_id)
  end

  # CRS-07 §6.3: resend the original content, or after a session reset send
  # a null message to start a new session. Both are ordinary sends to the
  # requester's whole account (CRS-07 §4 has no one-device form): the other
  # devices drop a resend as a duplicate, and only the device whose session
  # ended gets a pre-key message.
  defp answer_retry(pipeline, _requester, _request, :ignore, _group_id), do: {pipeline, []}

  defp answer_retry(pipeline, requester, request, action, group_id) do
    events =
      if action == :sender_key,
        do: [{:sender_key_reset, requester.name, requester.device_id, group_id}],
        else: []

    sent = store(pipeline, :sent, [{requester.name, requester.device_id, request.timestamp}])

    result =
      cond do
        sent != nil ->
          send_content(pipeline, requester.name, sent.content,
            timestamp: request.timestamp,
            content_hint: sent.content_hint,
            urgent: sent.urgent,
            group_id: sent.group_id,
            keep_sent: false
          )

        match?({:reset_session, _}, action) ->
          send_content(pipeline, requester.name, Content.null_message(),
            content_hint: @implicit,
            urgent: false,
            keep_sent: false
          )

        true ->
          :nothing
      end

    case result do
      :nothing -> {pipeline, events}
      {:ok, info, pipeline} -> {pipeline, events ++ info.events}
      {:error, reason, pipeline} -> {pipeline, events ++ [{:send_failed, :retry_answer, reason}]}
    end
  end

  # --- sending --------------------------------------------------------------

  @doc """
  Sends the serialized content container `content` to the account
  `recipient` (an ACI string).

  Options:

    * `:timestamp`: the message timestamp (default now; a resend reuses the
      original, CRS-07 §2);
    * `:online` (default false) and `:urgent` (default true), CRS-07 §9;
    * `:content_hint`: 0 default, 1 resendable, 2 implicit (CRS-06 §5.1),
      default 1;
    * `:group_id`: the 32-byte group ID of a group message sent 1:1;
    * `:sealed` (default true): seal when possible;
    * `:keep_sent`: keep the content to answer retry requests (default:
      true unless the hint is implicit).

  Returns `{:ok, %{timestamp, devices, sealed?, events}, pipeline}` or
  `{:error, reason, pipeline}`.
  """
  @spec send_content(t(), String.t(), binary(), keyword()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_content(%__MODULE__{} = pipeline, recipient, content, opts \\ [])
      when is_binary(content) do
    hint = Keyword.get(opts, :content_hint, @resendable)

    {timestamp, pipeline} =
      case Keyword.fetch(opts, :timestamp) do
        {:ok, timestamp} -> {timestamp, pipeline}
        :error -> next_timestamp(pipeline)
      end

    options = %{
      timestamp: timestamp,
      online: Keyword.get(opts, :online, false),
      urgent: Keyword.get(opts, :urgent, true),
      hint: hint,
      group_id: Keyword.get(opts, :group_id),
      sealed: Keyword.get(opts, :sealed, true),
      keep_sent: Keyword.get(opts, :keep_sent, hint != @implicit),
      # Internal: `content` is a plaintext wrapper (CRS-05 §7), sent without
      # session encryption (envelope kind 8, or sealed inner type 8).
      plaintext: Keyword.get(opts, :plaintext, false)
    }

    attempt(pipeline, recipient, content, options, 1, [])
  end

  defp attempt(pipeline, _recipient, _content, options, number, _events)
       when number > pipeline.config.max_send_attempts,
       do: {:error, {:too_many_attempts, options.timestamp}, pipeline}

  defp attempt(pipeline, recipient, content, options, number, events) do
    with {:ok, pipeline, session_events} <- ensure_sessions(pipeline, recipient, nil),
         {pipeline, sealing} = sealing(pipeline, recipient, options.sealed),
         {:ok, messages, ops} <- encrypt_all(pipeline, recipient, content, options, sealing),
         {:commit, :ok} <-
           {:commit, commit(pipeline, ops ++ [{:put_send_timestamp, options.timestamp}])},
         events = events ++ session_events,
         {:ok, response} <- post(pipeline, recipient, messages, options, sealing) do
      handle_send_result(
        Api.send_result(response),
        pipeline,
        recipient,
        content,
        options,
        sealing,
        messages,
        number,
        events
      )
    else
      {:commit, {:error, :fenced}} -> {:error, :fenced, pipeline}
      {:error, reason, pipeline} -> {:error, reason, pipeline}
      {:error, reason} -> {:error, {:transport, reason}, pipeline}
    end
  end

  defp handle_send_result(
         :ok,
         pipeline,
         recipient,
         content,
         options,
         sealing,
         messages,
         _number,
         events
       ) do
    devices = Enum.map(messages, & &1.device_id)

    ops =
      if options.keep_sent do
        sent = %{
          content: content,
          content_hint: options.hint,
          urgent: options.urgent,
          group_id: options.group_id,
          sent_at_ms: now(pipeline)
        }

        for device <- devices, do: {:put_sent, {recipient, device, options.timestamp}, sent}
      else
        []
      end

    case commit(pipeline, ops) do
      :ok ->
        {:ok,
         %{
           timestamp: options.timestamp,
           devices: devices,
           sealed?: sealing != nil,
           events: events
         }, pipeline}

      {:error, :fenced} ->
        {:error, :fenced, pipeline}
    end
  end

  # CRS-07 §4: extra devices are no longer sent to, missing devices get a
  # session from their pre-key bundle, and the message is sent again with
  # the same timestamp.
  defp handle_send_result(
         {:mismatch, %{missing: missing, extra: extra}},
         pipeline,
         recipient,
         content,
         options,
         _sealing,
         _messages,
         number,
         events
       ) do
    forget =
      for(device <- extra, do: {:delete_session, Address.new(recipient, device)}) ++
        device_changes(pipeline, recipient, missing ++ extra)

    with :ok <- commit(pipeline, forget),
         {:ok, pipeline, fetch_events} <- fetch_devices(pipeline, recipient, missing) do
      changed = {:devices_changed, recipient, %{missing: missing, extra: extra}}

      attempt(
        pipeline,
        recipient,
        content,
        options,
        number + 1,
        events ++ fetch_events ++ [changed]
      )
    else
      {:error, :fenced} -> {:error, :fenced, pipeline}
      {:error, reason, pipeline} -> {:error, reason, pipeline}
    end
  end

  # CRS-07 §4: the old session of a stale device is not used again; a new
  # one comes from a new pre-key bundle.
  defp handle_send_result(
         {:stale, stale},
         pipeline,
         recipient,
         content,
         options,
         _sealing,
         _messages,
         number,
         events
       ) do
    forget =
      for(device <- stale, do: {:delete_session, Address.new(recipient, device)}) ++
        device_changes(pipeline, recipient, stale)

    with :ok <- commit(pipeline, forget),
         {:ok, pipeline, fetch_events} <- fetch_devices(pipeline, recipient, stale) do
      changed = {:devices_changed, recipient, %{stale: stale}}

      attempt(
        pipeline,
        recipient,
        content,
        options,
        number + 1,
        events ++ fetch_events ++ [changed]
      )
    else
      {:error, :fenced} -> {:error, :fenced, pipeline}
      {:error, reason, pipeline} -> {:error, reason, pipeline}
    end
  end

  # A sealed send refused with 401: the official clients send identified
  # once instead (CRS-07 §3.2; open question 7).
  defp handle_send_result(
         :unauthorized,
         pipeline,
         recipient,
         content,
         options,
         sealing,
         _messages,
         number,
         events
       )
       when sealing != nil do
    if pipeline.config.sealed_fallback == :identified,
      do: attempt(pipeline, recipient, content, %{options | sealed: false}, number + 1, events),
      else: {:error, :unauthorized, pipeline}
  end

  defp handle_send_result(
         :not_found,
         pipeline,
         recipient,
         _content,
         _options,
         _sealing,
         _messages,
         _number,
         _events
       ),
       do: unregistered(pipeline, recipient)

  defp handle_send_result(
         other,
         pipeline,
         _recipient,
         _content,
         _options,
         _sealing,
         _messages,
         _number,
         _events
       ),
       do: {:error, other, pipeline}

  # CRS-07 §3.2: 404 marks the recipient unregistered; no retry.
  defp unregistered(pipeline, recipient) do
    contact = %{contact(pipeline, recipient) | unregistered?: true}

    case commit(pipeline, [{:put_contact, recipient, contact}]) do
      :ok -> {:error, :unregistered, pipeline}
      {:error, :fenced} -> {:error, :fenced, pipeline}
    end
  end

  # Every device to send to has a usable session: a current session that is
  # not a pending session past its lifetime (CRS-04 §8.2). Without a known
  # device, the bundles of all devices are fetched (CRS-07 §4).
  defp ensure_sessions(pipeline, recipient, devices) do
    devices = devices || store(pipeline, :device_ids, [recipient])

    if devices == [] do
      fetch_bundles(pipeline, recipient, :all)
    else
      now = now(pipeline)

      missing =
        Enum.reject(devices, fn device ->
          case store(pipeline, :session, [Address.new(recipient, device)]) do
            %Session.Record{current: %State{} = state} ->
              # Outbound messages identify this account by ACI. A received
              # PNI session cannot authenticate that sender identity. Use
              # the account's stored ACI key as the expected local identity,
              # and obtain a new session before sending on a mismatch.
              state.local_identity == pipeline.account.identities.aci.public and
                not State.pending_expired?(state, now)

            _ ->
              false
          end
        end)

      fetch_devices(pipeline, recipient, missing)
    end
  end

  defp fetch_devices(pipeline, recipient, devices) do
    Enum.reduce_while(devices, {:ok, pipeline, []}, fn device, {:ok, pipeline, events} ->
      case fetch_bundles(pipeline, recipient, device) do
        {:ok, pipeline, new_events} -> {:cont, {:ok, pipeline, events ++ new_events}}
        {:error, reason, pipeline} -> {:halt, {:error, reason, pipeline}}
      end
    end)
  end

  # GET /v2/keys (CRS-03 §9.5), then a new session per bundle (CRS-04 §8.2).
  # The fetch uses the recipient's access key when Comma has it; a refused
  # key (401) falls back to the account's own credentials.
  defp fetch_bundles(pipeline, recipient, device) do
    path = Api.keys_path(recipient, device)

    fetched =
      case access_key(pipeline, recipient) do
        nil ->
          request(pipeline.transport.identified, "GET", path, [])

        key ->
          headers = [{"unidentified-access-key", AccessKey.header(key)}]

          case request(pipeline.transport.unidentified, "GET", path, headers: headers) do
            {:ok, %Response{status: 401}} ->
              request(pipeline.transport.identified, "GET", path, [])

            other ->
              other
          end
      end

    with {:ok, response} <- fetched,
         {:status, 200, _} <- {:status, response.status, response},
         {:ok, json} <- Response.json(response),
         {:ok, bundles} <- PreKeyBundle.from_service_response(json) do
      start_sessions(pipeline, recipient, bundles)
    else
      # No bundle for any device: the account is not registered (CRS-03 §9.5).
      {:status, 404, _} when device == :all -> unregistered(pipeline, recipient)
      {:status, 404, _} -> {:error, {:no_bundle, device}, pipeline}
      {:status, _status, response} -> {:error, {:keys, Api.send_result(response)}, pipeline}
      {:error, :invalid_json} -> {:error, {:keys, :malformed}, pipeline}
      {:error, :malformed} -> {:error, {:keys, :malformed}, pipeline}
      {:error, reason} -> {:error, {:transport, reason}, pipeline}
    end
  end

  defp start_sessions(pipeline, recipient, bundles) do
    now = now(pipeline)

    {ops, events} =
      Enum.reduce(bundles, {[], []}, fn bundle, {ops, events} ->
        address = Address.new(recipient, bundle.device_id)
        record = store(pipeline, :session, [address])

        case Session.process_bundle(record, bundle, send_context(pipeline, address), now_ms: now) do
          {:ok, record} ->
            {ops ++ [{:put_session, address, record}], events}

          {:error, reason} ->
            {ops, events ++ [{:bundle_rejected, recipient, bundle.device_id, reason}]}
        end
      end)

    {identity_ops, identity_events} =
      case bundles do
        [bundle | _] -> identity_changes(pipeline, recipient, bundle.identity_key)
        [] -> {[], []}
      end

    case commit(pipeline, ops ++ identity_ops) do
      :ok -> {:ok, pipeline, events ++ identity_events}
      {:error, :fenced} -> {:error, :fenced, pipeline}
    end
  end

  # A sender certificate valid long enough, and the recipient's access key
  # (CRS-06 §3.6, §4). Without both the send is identified.
  defp sealing(pipeline, _recipient, false), do: {pipeline, nil}

  defp sealing(pipeline, recipient, true) do
    with key when is_binary(key) <- access_key(pipeline, recipient),
         {pipeline, %Certificate.Sender{} = certificate} <- sender_certificate(pipeline) do
      {pipeline, %{certificate: certificate, access_key: key}}
    else
      {pipeline, nil} -> {pipeline, nil}
      nil -> {pipeline, nil}
    end
  end

  defp access_key(pipeline, recipient) do
    case contact(pipeline, recipient) do
      %{profile_key: <<_::binary-size(32)>> = key} -> AccessKey.derive(key)
      _ -> nil
    end
  end

  @doc """
  The account's sender certificate. It is fetched again before it expires
  (CRS-06 §3.6, open question 2): when the time left falls below the
  smaller of `certificate_margin_ms` (24 hours) and half the time it had
  left when it was fetched (owner decision). A short-lived certificate is
  therefore used for half its life, not fetched again for every send.
  Returns `{pipeline, certificate | nil}`.
  """
  @spec sender_certificate(t()) :: {t(), Certificate.Sender.t() | nil}
  def sender_certificate(pipeline) do
    now = now(pipeline)

    case pipeline.sender_certificate do
      %Certificate.Sender{} = certificate when now < pipeline.certificate_refresh_at ->
        {pipeline, certificate}

      _ ->
        with {:ok, response} <-
               request(pipeline.transport.identified, "GET", Api.certificate_path(), []),
             {:ok, bytes} <- Api.certificate(response),
             {:ok, certificate} <- Certificate.decode_sender(bytes),
             :ok <-
               Certificate.validate(
                 certificate,
                 pipeline.trust_roots,
                 now,
                 pipeline.known_server_certificates
               ),
             :ok <- own_certificate(pipeline, certificate) do
          margin =
            min(pipeline.config.certificate_margin_ms, div(certificate.expiration - now, 2))

          {%{
             pipeline
             | sender_certificate: certificate,
               certificate_refresh_at: certificate.expiration - margin
           }, certificate}
        else
          other ->
            Logger.warning(
              "signal sender certificate unavailable: #{inspect(elem_reason(other))}"
            )

            {pipeline, nil}
        end
    end
  end

  # Recipients check that the certificate's identity key is the key that
  # sealed the message (CRS-06 §7.4); a certificate for another key or
  # device is useless.
  defp own_certificate(%__MODULE__{account: account}, certificate) do
    if certificate.aci == account.aci_uuid and certificate.device_id == account.device_id and
         certificate.identity_key == account.identities.aci.public,
       do: :ok,
       else: {:error, :not_this_device}
  end

  defp elem_reason({:error, reason}), do: reason
  defp elem_reason(other), do: other

  # One entry per device of the recipient account (CRS-07 §4). A plaintext
  # wrapper is not session-encrypted, but its entries still need the
  # device's registration ID and identity key from a session (CRS-07 §3.1).
  defp encrypt_all(pipeline, recipient, content, options, sealing) do
    padded = if options.plaintext, do: content, else: Padding.pad(content)
    devices = store(pipeline, :device_ids, [recipient])
    now = now(pipeline)

    Enum.reduce_while(devices, {:ok, [], []}, fn device, {:ok, messages, ops} ->
      address = Address.new(recipient, device)
      record = store(pipeline, :session, [address])

      encrypted =
        cond do
          not options.plaintext ->
            Session.encrypt(record, padded, send_context(pipeline, address), now_ms: now)

          match?(%Session.Record{current: %State{}}, record) ->
            {:ok, {:plaintext, padded}, record}

          true ->
            {:error, :no_session}
        end

      case encrypted do
        {:ok, {:plaintext, _}, record} ->
          message = %{
            type: nil,
            device_id: device,
            registration_id: record.current.remote_registration_id,
            content: padded
          }

          message =
            seal_message(
              pipeline,
              message,
              :plaintext,
              record.current.remote_identity,
              options,
              sealing
            )

          {:cont, {:ok, messages ++ [message], ops}}

        {:ok, {type, ciphertext}, record} ->
          message = %{
            type: nil,
            device_id: device,
            registration_id: record.current.remote_registration_id,
            content: ciphertext
          }

          message =
            seal_message(
              pipeline,
              message,
              type,
              record.current.remote_identity,
              options,
              sealing
            )

          {:cont, {:ok, messages ++ [message], ops ++ [{:put_session, address, record}]}}

        {:error, reason} ->
          {:halt, {:error, {:encrypt, device, reason}, pipeline}}
      end
    end)
  end

  # Envelope kinds (CRS-05 §3.2): 1 for a 1:1 message, 3 for a pre-key
  # message, 8 for a plaintext wrapper, 6 for anything sealed.
  defp seal_message(_pipeline, message, type, _identity, _options, nil) do
    kind =
      case type do
        :plaintext -> 8
        2 -> 1
        3 -> 3
      end

    %{message | type: kind}
  end

  defp seal_message(pipeline, message, type, identity, options, sealing) do
    inner =
      Inner.encode(%Inner{
        type: if(type == :plaintext, do: :plaintext, else: Inner.from_session_type(type)),
        certificate: sealing.certificate,
        content: message.content,
        content_hint: options.hint,
        group_id: options.group_id
      })

    %{
      message
      | type: 6,
        content: SealedSender.seal(inner, pipeline.account.identities.aci, identity)
    }
  end

  defp post(pipeline, recipient, messages, options, sealing) do
    body = Api.send_body(messages, options.timestamp, options.online, options.urgent)

    case sealing do
      nil ->
        request(pipeline.transport.identified, "PUT", Api.send_path(recipient), json: body)

      %{access_key: key} ->
        headers = [{"unidentified-access-key", AccessKey.header(key)}]

        request(pipeline.transport.unidentified, "PUT", Api.send_path(recipient),
          json: body,
          headers: headers
        )
    end
  end

  defp send_context(pipeline, remote) do
    account = pipeline.account

    %{
      identity: account.identities.aci,
      registration_id: account.registration_ids.aci,
      local_address: account.address,
      remote_address: remote,
      trusted?: fn _key, _direction -> true end
    }
  end

  @doc """
  Sends a retry request (CRS-07 §6.2): the decryption error message
  `message`, which names the failed device of `address`, in the plaintext
  wrapper, as an ordinary single-recipient send to the sender's whole
  account. Each entry is sealed with inner type 8, the implicit hint and
  `group_id` when possible, otherwise envelope kind 8; `online` and
  `urgent` are false and the current time is its timestamp. A device
  without a session, the failed one included, gets one from its pre-key
  bundle first (CRS-07 §3.1), and 409 and 410 correct the device list as
  for any send (CRS-07 §4).
  """
  @spec send_retry_request(t(), Address.t(), binary(), binary() | nil) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_retry_request(pipeline, %Address{name: sender} = address, message, group_id) do
    with {:ok, pipeline, events} <- retry_sessions(pipeline, address) do
      case send_content(pipeline, sender, DecryptionError.wrap(message),
             plaintext: true,
             content_hint: @implicit,
             group_id: group_id,
             online: false,
             urgent: false,
             keep_sent: false
           ) do
        {:ok, info, pipeline} -> {:ok, %{info | events: events ++ info.events}, pipeline}
        {:error, reason, pipeline} -> {:error, reason, pipeline}
      end
    end
  end

  # The known devices of the sender plus the failed device. With no known
  # device, one fetch returns the bundles of all devices.
  defp retry_sessions(pipeline, %Address{name: sender, device_id: device}) do
    case store(pipeline, :device_ids, [sender]) do
      [] -> ensure_sessions(pipeline, sender, nil)
      known -> ensure_sessions(pipeline, sender, Enum.uniq(known ++ [device]))
    end
  end

  # --- message helpers (CRS-05, CRS-07 §9) -------------------------------------

  @doc """
  Sends a 1:1 text message with the account's profile key and the
  conversation timer. `opts` takes the `SalixSignalProto.Message.Content`
  data options (`:quote`, `:mentions`, `:styles`, `:attachments`) and
  `:timestamp`.
  """
  @spec send_text(t(), String.t(), String.t(), keyword()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_text(pipeline, recipient, body, opts \\ []) do
    {timestamp, opts} = Keyword.pop(opts, :timestamp)

    {timestamp, pipeline} =
      if timestamp, do: {timestamp, pipeline}, else: next_timestamp(pipeline)

    content = Content.text(timestamp, body, direct_options(pipeline, recipient) ++ opts)
    send_content(pipeline, recipient, content, timestamp: timestamp, content_hint: @resendable)
  end

  @doc """
  Sends a reaction to the message `(target_author, target_timestamp)`;
  `remove: true` removes it. A target author that is not an ACI string is
  `{:error, :invalid_author}`.
  """
  @spec send_reaction(t(), String.t(), String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_reaction(pipeline, recipient, emoji, target_author, target_timestamp, opts \\ []) do
    case reaction_author(target_author) do
      {:ok, author} ->
        {timestamp, pipeline} = next_timestamp(pipeline)

        content =
          Content.reaction(
            timestamp,
            emoji,
            author,
            target_timestamp,
            [remove: Keyword.get(opts, :remove, false)] ++ direct_options(pipeline, recipient)
          )

        send_content(pipeline, recipient, content,
          timestamp: timestamp,
          content_hint: @resendable
        )

      :error ->
        {:error, :invalid_author, pipeline}
    end
  end

  @doc false
  # The 16-byte ACI of a reaction's target author (CRS-05 §5.5), or :error.
  def reaction_author(author) when is_binary(author), do: ServiceId.aci_from_string(author)
  def reaction_author(_author), do: :error

  @doc "Deletes this account's message sent at `target_timestamp` for the recipient."
  @spec send_remote_delete(t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_remote_delete(pipeline, recipient, target_timestamp, _opts \\ []) do
    {timestamp, pipeline} = next_timestamp(pipeline)

    content =
      Content.remote_delete(timestamp, target_timestamp, direct_options(pipeline, recipient))

    send_content(pipeline, recipient, content, timestamp: timestamp, content_hint: @resendable)
  end

  @doc """
  Replaces the text of this account's message sent at `target_timestamp`.
  `opts`: `:attachments` (a long-text attachment, CRS-05 section 5.8).
  """
  @spec send_edit(t(), String.t(), non_neg_integer(), String.t(), keyword()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_edit(pipeline, recipient, target_timestamp, body, opts \\ []) do
    {timestamp, pipeline} = next_timestamp(pipeline)

    content =
      Content.edit(
        timestamp,
        target_timestamp,
        body,
        direct_options(pipeline, recipient) ++ Keyword.take(opts, [:attachments])
      )

    send_content(pipeline, recipient, content, timestamp: timestamp, content_hint: @resendable)
  end

  @doc "Sends a typing message: online true, urgent false, implicit hint (CRS-07 §8)."
  @spec send_typing(t(), String.t(), :started | :stopped, keyword()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_typing(pipeline, recipient, action, _opts \\ []) do
    {timestamp, pipeline} = next_timestamp(pipeline)

    send_content(pipeline, recipient, Content.typing(timestamp, action),
      timestamp: timestamp,
      online: true,
      urgent: false,
      content_hint: @implicit
    )
  end

  @doc """
  Sends a receipt of `kind` (`:delivery`, `:read`, `:viewed`) for messages
  of `author` sent at `timestamps`: urgent false, implicit hint (CRS-07 §7.2).
  """
  @spec send_receipt(t(), String.t(), :delivery | :read | :viewed, [non_neg_integer()], keyword()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_receipt(pipeline, author, kind, timestamps, _opts \\ []) do
    send_content(pipeline, author, Content.receipt(kind, timestamps),
      urgent: false,
      content_hint: @implicit
    )
  end

  @doc """
  Changes the 1:1 disappearing-message timer to `seconds` (0 = off) and
  tells the recipient (CRS-05 §5.2).
  """
  @spec set_expire_timer(t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def set_expire_timer(pipeline, recipient, seconds, _opts \\ []) do
    contact = contact(pipeline, recipient)
    timer = ExpireTimer.change(contact.expire_timer, seconds)

    case commit(pipeline, [{:put_contact, recipient, %{contact | expire_timer: timer}}]) do
      :ok ->
        {timestamp, pipeline} = next_timestamp(pipeline)

        opts =
          case pipeline.account[:profile_key] do
            nil -> []
            key -> [profile_key: key]
          end

        content = Content.expire_timer_update(timestamp, timer.seconds, timer.version, opts)

        send_content(pipeline, recipient, content,
          timestamp: timestamp,
          content_hint: @resendable
        )

      {:error, :fenced} ->
        {:error, :fenced, pipeline}
    end
  end

  @doc """
  Sends an encoded call message (content field 3, CRS-12) to every device of
  `recipient`, as `SalixSignal.CallSignaling` asks: default hint (CRS-06
  §5.1), online false, and `urgent` per call message kind (CRS-07 §9).
  """
  @spec send_call_message(t(), String.t(), binary(), %{urgent: boolean()}) ::
          {:ok, map(), t()} | {:error, term(), t()}
  def send_call_message(pipeline, recipient, call_message, %{urgent: urgent})
      when is_binary(call_message) do
    content =
      SalixSignalProto.Message.Wire.Content.encode(%SalixSignalProto.Message.Wire.Content{
        call_message: call_message
      })

    send_content(pipeline, recipient, content, urgent: urgent, content_hint: 0, keep_sent: false)
  end

  @doc "Sends the account's profile key (flags bit 4, CRS-05 §5.2)."
  @spec send_profile_key(t(), String.t(), keyword()) :: {:ok, map(), t()} | {:error, term(), t()}
  def send_profile_key(pipeline, recipient, _opts \\ []) do
    {timestamp, pipeline} = next_timestamp(pipeline)
    content = Content.profile_key_update(timestamp, Map.fetch!(pipeline.account, :profile_key))
    send_content(pipeline, recipient, content, timestamp: timestamp, content_hint: @implicit)
  end

  @doc """
  Sends the PNI-signed ACI identity to a peer that contacted this account's phone number.

  Without this proof, a peer can show separate phone-number and account chats.
  The account's PNI key signs its ACI key with the existing Signal protocol.
  The peer verifies the proof with the PNI public key obtained from Signal.
  An invalid proof must leave the peer's identities separate.
  This protocol reply grants no access to a Comma Group.
  """
  def send_pni_signature(pipeline, recipient) do
    alias SalixSignalProto.{Keys, Message.Wire}
    alias SalixSignalProto.Crypto.XEdDSA

    case pipeline.account do
      %{pni_uuid: <<_::128>> = pni, identities: %{aci: aci, pni: %{private: private}}} ->
        signature = XEdDSA.sign(private, Keys.alternate_identity_message(aci.public))

        content =
          Wire.Content.encode(%Wire.Content{
            pni_signature: %Wire.PniSignatureMessage{pni: pni, signature: signature}
          })

        send_content(pipeline, recipient, content, content_hint: @implicit)

      _ ->
        {:error, :no_pni_identity, pipeline}
    end
  end

  # Every outgoing 1:1 data message carries the profile key and the timer
  # with its version (CRS-05 §5.2).
  defp direct_options(pipeline, recipient) do
    timer = contact(pipeline, recipient).expire_timer
    profile = if key = pipeline.account[:profile_key], do: [profile_key: key], else: []
    profile ++ [expire_timer: timer.seconds, expire_timer_version: timer.version]
  end

  # --- shared with SalixSignal.Messaging.GroupSend ------------------------------

  @doc false
  # Every current device of `recipient` has a usable session afterwards.
  def prepare_sessions(pipeline, recipient), do: ensure_sessions(pipeline, recipient, nil)

  @doc false
  # CRS-07 §4 after a device-list error: forget the sessions of `forget`,
  # then build new sessions for `fetch` from their pre-key bundles.
  def correct_devices(pipeline, recipient, forget, fetch) do
    ops =
      for(device <- forget, do: {:delete_session, Address.new(recipient, device)}) ++
        device_changes(pipeline, recipient, Enum.uniq(forget ++ fetch))

    case commit(pipeline, ops) do
      :ok -> fetch_devices(pipeline, recipient, fetch)
      {:error, :fenced} -> {:error, :fenced, pipeline}
    end
  end

  @doc false
  def mark_unregistered(pipeline, recipient) do
    case unregistered(pipeline, recipient) do
      {:error, :unregistered, pipeline} -> {:ok, pipeline}
      {:error, :fenced, pipeline} -> {:error, :fenced, pipeline}
    end
  end

  @doc false
  def read(pipeline, function, args), do: store(pipeline, function, args)

  @doc false
  def write(pipeline, ops), do: commit(pipeline, ops)

  @doc false
  def timestamp(pipeline), do: next_timestamp(pipeline)

  @doc false
  def clock(pipeline), do: now(pipeline)

  @doc false
  def unidentified_request(pipeline, method, path, opts),
    do: request(pipeline.transport.unidentified, method, path, opts)

  @doc false
  def contact_state(pipeline, name), do: contact(pipeline, name)

  @doc false
  # The sender-key targets of `devices` of `recipient` (CRS-09c section
  # 6.2): `{service_id, device_id, generation}`. A device gets a new
  # generation when a device-list correction names it (CRS-07 §4), so a
  # distribution message it received before no longer counts, in every
  # group.
  def sender_key_targets(pipeline, recipient, devices) do
    {:ok, id} = ServiceId.parse(recipient)
    generations = Map.get(contact(pipeline, recipient), :device_changes, %{})
    for device <- devices, do: {id, device, Map.get(generations, device, 0)}
  end

  # CRS-07 §4: after 409 or 410 every device in the lists is treated as not
  # holding this account's sender key. The next generation of each device
  # is stored with the contact, in the commit that corrects its sessions.
  defp device_changes(_pipeline, _recipient, []), do: []

  defp device_changes(pipeline, recipient, devices) do
    contact = contact(pipeline, recipient)
    generations = Map.get(contact, :device_changes, %{})
    next = Enum.max(Map.values(generations), fn -> 0 end) + 1
    generations = Enum.reduce(devices, generations, &Map.put(&2, &1, next))
    [{:put_contact, recipient, Map.put(contact, :device_changes, generations)}]
  end

  # --- helpers ----------------------------------------------------------------

  defp contact(pipeline, name) do
    store(pipeline, :contact, [name]) ||
      %{profile_key: nil, expire_timer: ExpireTimer.initial(), unregistered?: false}
  end

  defp store(%__MODULE__{store: {module, handle}}, function, args),
    do: apply(module, function, [handle | args])

  defp commit(_pipeline, []), do: :ok

  defp commit(%__MODULE__{store: {module, handle}, epoch: epoch}, ops),
    do: module.commit(handle, epoch, ops)

  defp now(%__MODULE__{clock: clock}), do: clock.()

  # One timestamp per logical message (CRS-07 §2). Receivers drop a second
  # message with the same author and timestamp as a duplicate (§5.4), so the
  # timestamps of this account's messages strictly increase (owner
  # decision), also across owners: every send commits its timestamp
  # (`{:put_send_timestamp, ms}`) before the request, and a new owner starts
  # above the highest one (option `:last_timestamp`).
  defp next_timestamp(%__MODULE__{last_timestamp: last} = pipeline) do
    timestamp = max(now(pipeline), last + 1)
    {timestamp, %{pipeline | last_timestamp: timestamp}}
  end

  defp request(transport, method, path, opts) when is_function(transport, 3),
    do: transport.(method, path, opts)

  defp request(transport, method, path, opts),
    do: Transport.request(transport, method, path, opts)
end
