defmodule SalixSignal.Test.SignalAccount do
  @moduledoc false
  # A Signal account device for pipeline tests: identity key, pre-keys
  # published to SalixSignal.Test.MockService, a store and a
  # SalixSignal.Messaging.Pipeline that talks to the mock service.
  #
  # The store is in memory by default; `store: :postgres` stores the
  # account in the Signal tables (SalixSignal.Storage), replacing any row
  # with the same ACI, and claims it (`account_id` names the row).

  alias SalixSignal.Messaging.Pipeline
  alias SalixSignal.Test.{MemoryStore, MockService}
  alias SalixSignalProto.{Keys, PreKeys}
  alias SalixSignalProto.SealedSender.AccessKey

  defstruct [
    :aci,
    :device_id,
    :identity,
    :registration_id,
    :profile_key,
    :store,
    :service,
    :pipeline,
    :account_id
  ]

  def new(service, aci, opts \\ []) do
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)
    now = clock.()
    device_id = Keyword.get(opts, :device_id, 1)
    identity = Keyword.get_lazy(opts, :identity, fn -> Keys.ec_keypair() end)
    registration_id = Keyword.get_lazy(opts, :registration_id, fn -> :rand.uniform(16_000) end)
    profile_key = Keyword.get_lazy(opts, :profile_key, fn -> :crypto.strong_rand_bytes(32) end)

    pre_keys = PreKeys.Store.new(identity, now)

    one_time =
      for id <- 1..Keyword.get(opts, :one_time_pre_keys, 4), do: PreKeys.one_time_pre_key(id, now)

    pre_keys = %{pre_keys | one_time: Map.new(one_time, &{&1.id, &1})}

    body =
      PreKeys.upload_body(
        signed_pre_key: PreKeys.Store.current_signed(pre_keys),
        last_resort_pre_key: PreKeys.Store.current_last_resort(pre_keys),
        pre_keys: one_time
      )

    MockService.register(service, aci, device_id, registration_id, identity.public, body,
      access_key: AccessKey.derive(profile_key)
    )

    pni = Keyword.get(opts, :pni)
    pni_identity = if pni, do: Keys.ec_keypair()
    pni_keys = if pni, do: PreKeys.Store.new(pni_identity, now)
    all_keys = if pni, do: %{aci: pre_keys, pni: pni_keys}, else: %{aci: pre_keys}

    account = %{
      aci: aci,
      pni: pni,
      device_id: device_id,
      identities: %{aci: identity, pni: pni_identity},
      registration_ids: %{aci: registration_id, pni: registration_id},
      profile_key: profile_key
    }

    if pni do
      pni_body =
        PreKeys.upload_body(
          signed_pre_key: PreKeys.Store.current_signed(pni_keys),
          last_resort_pre_key: PreKeys.Store.current_last_resort(pni_keys)
        )

      MockService.register(
        service,
        "PNI:" <> pni,
        device_id,
        registration_id,
        pni_identity.public,
        pni_body
      )
    end

    {store, store_ref, epoch, account_id} =
      case Keyword.get(opts, :store, :memory) do
        :memory ->
          {:ok, store} = MemoryStore.start(all_keys)
          {store, {MemoryStore, store}, Keyword.get(opts, :epoch, 1), nil}

        :postgres ->
          id = postgres_account(account, all_keys)

          {:ok, %{epoch: epoch}} = SalixSignal.Storage.claim(id, node())
          {id, {SalixSignal.Storage, id}, epoch, id}
      end

    {:ok, pipeline} =
      Pipeline.new(
        account: account,
        store: store_ref,
        epoch: epoch,
        transport: %{
          identified: MockService.transport(service, {:identified, aci, device_id}),
          unidentified: MockService.transport(service, :unidentified)
        },
        trust_roots: [MockService.trust_root(service)],
        known_server_certificates: %{},
        clock: clock,
        call_message: Keyword.get(opts, :call_message),
        config: Keyword.get(opts, :config, [])
      )

    %__MODULE__{
      aci: aci,
      device_id: device_id,
      identity: identity,
      registration_id: registration_id,
      profile_key: profile_key,
      store: store,
      service: service,
      pipeline: pipeline,
      account_id: account_id
    }
  end

  # Replaces any stored test account with this ACI by a new one.
  defp postgres_account(account, pre_keys) do
    {:ok, keys} = SalixSignal.Storage.Cipher.keys()

    SalixStore.Repo.query!("DELETE FROM signal_accounts WHERE aci_index = $1", [
      SalixSignal.Storage.Cipher.index(keys, :signal_accounts, "", {:aci, account.aci})
    ])

    {:ok, id} =
      SalixSignal.Storage.create_account(
        Map.merge(account, %{
          e164: nil,
          password: "device-password",
          pre_keys: pre_keys,
          environment: :staging
        })
      )

    id
  end

  # Rebuilds the pipeline from durable state, as a restarted owner does:
  # a new owner epoch and no process state carried over.
  def restart(%__MODULE__{account_id: id, pipeline: pipeline} = account) when is_binary(id) do
    {:ok, %{epoch: epoch, last_send_timestamp: last}} = SalixSignal.Storage.claim(id, node())
    {:ok, fresh} = Pipeline.new([last_timestamp: last] ++ pipeline_options(pipeline, epoch))
    %{account | pipeline: fresh}
  end

  defp pipeline_options(pipeline, epoch) do
    [
      account:
        Map.take(pipeline.account, [
          :aci,
          :pni,
          :device_id,
          :identities,
          :registration_ids,
          :profile_key
        ]),
      store: pipeline.store,
      epoch: epoch,
      transport: pipeline.transport,
      trust_roots: pipeline.trust_roots,
      known_server_certificates: pipeline.known_server_certificates,
      clock: pipeline.clock,
      call_message: pipeline.call_message,
      config: Map.to_list(pipeline.config)
    ]
  end

  # Delivers every queued envelope to the pipeline, oldest first, and
  # acknowledges those it says to acknowledge. Returns {events, account}.
  def deliver(%__MODULE__{} = account, opts \\ []) do
    ack? = Keyword.get(opts, :ack, true)

    account.service
    |> MockService.queued(account.aci, account.device_id)
    |> Enum.reduce({[], account}, fn {guid, bytes}, {events, account} ->
      {ack, new_events, pipeline} =
        Pipeline.receive_envelope(account.pipeline, bytes, server_delivery_ms: 1)

      if ack == :ack and ack?,
        do: MockService.ack(account.service, account.aci, account.device_id, guid)

      {events ++ new_events, %{account | pipeline: pipeline}}
    end)
  end

  # Runs a pipeline send function and keeps the new pipeline.
  def run(%__MODULE__{} = account, fun) do
    case fun.(account.pipeline) do
      {:ok, info, pipeline} -> {{:ok, info}, %{account | pipeline: pipeline}}
      {:error, reason, pipeline} -> {{:error, reason}, %{account | pipeline: pipeline}}
    end
  end

  def inbound(%__MODULE__{store: store}), do: MemoryStore.inbound(store)
end
