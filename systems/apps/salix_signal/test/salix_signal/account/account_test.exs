defmodule SalixSignal.Account.AccountTest do
  # Layer C4 against a fake chat service written from CRS-02 and CRS-03 §9:
  # verification with an operator-solved captcha, registration, pre-key
  # publication and rotation, attributes and usernames. A peer then starts a
  # session from the published bundle and Comma decrypts it with its stored
  # keys, which checks that the published keys and the local store agree.
  use ExUnit.Case, async: true

  alias SalixSignal.Account.{
    Attributes,
    PreKeyService,
    Registration,
    Transport,
    Usernames,
    Verification
  }

  alias SalixSignal.Service.Credentials
  alias SalixSignal.Test.{FakeAccountService, FakeChat}
  alias SalixSignalProto.{AccountKeys, Address, Keys, PreKeyBundle, Session, Username}
  alias SalixSignalProto.PreKeys.Store

  @number "+15550100001"
  @access_key :binary.copy(<<0x11>>, 16)
  @now 1_758_790_000_000

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} = context do
    {:ok, fake} = FakeAccountService.start_link(locks: Map.get(context, :locks, %{}))
    server = start_supervised!({Bandit, FakeAccountService.bandit_options(fake, chain)})
    transport = {:http, "https://localhost:#{FakeChat.port(server)}", roots: [chain.root]}
    %{fake: fake, transport: transport}
  end

  defp verified_session(transport) do
    {:ok, session} = Verification.create(transport, @number)

    {:ok, session} =
      Verification.submit_captcha(transport, session.id, FakeAccountService.captcha())

    {:ok, _} = Verification.request_code(transport, session.id, :sms)

    {:ok, %{verified: true} = session} =
      Verification.submit_code(transport, session.id, FakeAccountService.code())

    session
  end

  defp register(transport, attributes \\ %{}) do
    {:ok, account} = Registration.new_account(@number, @now)
    session = verified_session(transport)
    attributes = Map.merge(%{unidentified_access_key: @access_key}, attributes)
    {Registration.register(transport, account, {:session, session.id}, attributes), account}
  end

  defp put_count(fake) do
    fake
    |> FakeAccountService.state()
    |> Map.fetch!(:requests)
    |> Enum.count(&(&1 == {"PUT", "/v2/keys"}))
  end

  test "an operator-solved captcha verifies the number step by step", %{transport: t} do
    assert {:ok, session} = Verification.create(t, @number)
    assert session.requested_information == [:captcha]
    refute session.allowed_to_request_code

    assert {:error, {:not_ready, %Verification.Session{}}} =
             Verification.request_code(t, session.id)

    assert {:error, {:captcha_rejected, _}} =
             Verification.submit_captcha(t, session.id, "signalcaptcha://bad")

    # The operator pastes the whole signalcaptcha:// URL.
    assert {:ok, ready} =
             Verification.submit_captcha(
               t,
               session.id,
               "signalcaptcha://" <> FakeAccountService.captcha()
             )

    assert ready.allowed_to_request_code and ready.requested_information == []

    assert {:ok, sent} =
             Verification.request_code(t, session.id, :voice, languages: ["en-US", "de"])

    assert sent.next_verification_attempt == 0
    assert {:ok, %{verified: false}} = Verification.submit_code(t, session.id, "000000")

    assert {:ok, %{verified: true}} =
             Verification.submit_code(t, session.id, FakeAccountService.code())

    assert Verification.fetch(t, "unknown") == {:error, :unknown_session}
    assert Verification.fetch(t, "../keys") == {:error, :invalid_session_id}
    assert {:error, {:invalid_number, _}} = Verification.create(t, "+0123")
  end

  test "registration, pre-key publication and a peer session to the published keys",
       %{transport: t, fake: fake} do
    assert {{:ok, account}, secrets} = register(t)
    refute account.reregistration
    device = Transport.with_credentials(t, Registration.credentials(account, secrets))

    # The service now holds the registration pre-keys, but no one-time keys.
    assert PreKeyService.counts(device, :aci) == {:ok, %{count: 0, kem_count: 0}}

    persist = fn store ->
      send(self(), {:persisted, store.pending != nil, put_count(fake)})
      :ok
    end

    stores =
      for kind <- [:aci, :pni], into: %{} do
        store = Map.fetch!(secrets, kind)
        assert {:ok, store} = PreKeyService.maintain(device, kind, store, @now, persist)
        # Private keys are stored before the upload, and the confirmed store after it.
        assert_received {:persisted, true, before}
        assert_received {:persisted, false, after_upload}
        assert after_upload == before + 1
        assert store.pending == nil
        {kind, store}
      end

    assert PreKeyService.counts(device, :pni) == {:ok, %{count: 100, kem_count: 100}}
    assert PreKeyService.check(device, :aci, stores.aci) == :ok

    # A second pass with a consistent service changes nothing.
    assert PreKeyService.maintain(device, :aci, stores.aci, @now + 1, persist, check: true) ==
             {:ok, stores.aci}

    refute_received {:persisted, _, _}

    # A peer fetches the ACI bundle and starts a session; Comma decrypts it
    # with its stored pre-keys and deletes the used one-time keys.
    {:ok, %{status: 200} = response} =
      Transport.request(t, "GET", "/v2/keys/#{account.aci}/1", [])

    {:ok, [bundle]} = response |> Transport.json_object() |> PreKeyBundle.from_service_response()
    assert bundle.registration_id == secrets.registration_id

    peer = Address.new("00000000-0000-4000-8000-000000000002", 1)
    me = Address.new(account.aci, 1)
    trust = fn _, _ -> true end

    peer_ctx = %{
      identity: Keys.ec_keypair(),
      registration_id: 9,
      local_address: peer,
      remote_address: me,
      trusted?: trust
    }

    {:ok, record} = Session.process_bundle(nil, bundle, peer_ctx)
    {:ok, {3, message}, _} = Session.encrypt(record, "hi Comma", peer_ctx)

    my_ctx = %{
      identity: stores.aci.identity,
      registration_id: secrets.registration_id,
      local_address: me,
      remote_address: peer,
      trusted?: trust
    }

    assert {:ok, "hi Comma", _record, effects} =
             Session.decrypt_pre_key(nil, message, my_ctx, Store.pre_key_lookup(stores.aci))

    used = Store.apply_effects(stores.aci, effects)
    assert map_size(used.one_time) == 99 and map_size(used.kem_one_time) == 99
    assert PreKeyService.counts(device, :aci) == {:ok, %{count: 99, kem_count: 99}}
  end

  test "a consistency mismatch replaces every published key", %{transport: t, fake: fake} do
    {{:ok, account}, secrets} = register(t)
    device = Transport.with_credentials(t, Registration.credentials(account, secrets))

    # The service holds another signed pre-key than the local store.
    other = Store.current_signed(Store.new(secrets.aci.identity, @now))

    FakeAccountService.update(fake, fn state ->
      put_in(
        state.accounts[@number].identities["aci"].signed,
        SalixSignalProto.PreKeys.to_json(other)
      )
    end)

    assert PreKeyService.check(device, :aci, secrets.aci) == :mismatch

    assert {:ok, store} =
             PreKeyService.maintain(device, :aci, secrets.aci, @now + 1, fn _ -> :ok end,
               check: true
             )

    refute Store.current_signed(store).id == Store.current_signed(secrets.aci).id
    assert PreKeyService.check(device, :aci, store) == :ok
    assert PreKeyService.counts(device, :aci) == {:ok, %{count: 100, kem_count: 100}}
  end

  test "a failed store write stops the pass before the upload", %{transport: t, fake: fake} do
    {{:ok, account}, secrets} = register(t)
    device = Transport.with_credentials(t, Registration.credentials(account, secrets))

    assert {:error, {:persist, :disk_full}, store} =
             PreKeyService.maintain(device, :aci, secrets.aci, @now, fn _ ->
               {:error, :disk_full}
             end)

    assert store == secrets.aci
    assert put_count(fake) == 0
  end

  # CRS-03 §9.2, §9.5 and §10.1: an upload replaces the one-time keys on the
  # service, and the service hands each one-time key out once. An upload
  # whose outcome Comma did not record can have reached the service, and peers
  # can have taken keys from it, so a retry must not publish those keys again.
  test "a retried upload does not hand a used one-time key to a second peer", %{transport: t} do
    {{:ok, account}, secrets} = register(t)
    device = Transport.with_credentials(t, Registration.credentials(account, secrets))

    # The upload reaches the service, but the confirmed store is not written.
    unconfirmed = fn store -> if store.pending, do: :ok, else: {:error, :disk_full} end

    assert {:error, {:persist, :disk_full}, pending} =
             PreKeyService.maintain(device, :aci, secrets.aci, @now, unconfirmed)

    me = Address.new(account.aci, 1)
    trust = fn _, _ -> true end

    first_message = fn peer_number ->
      {:ok, %{status: 200} = response} =
        Transport.request(t, "GET", "/v2/keys/#{account.aci}/1", [])

      {:ok, [bundle]} =
        response |> Transport.json_object() |> PreKeyBundle.from_service_response()

      peer = Address.new("00000000-0000-4000-8000-00000000000#{peer_number}", 1)

      ctx = %{
        identity: Keys.ec_keypair(),
        registration_id: 9,
        local_address: peer,
        remote_address: me,
        trusted?: trust
      }

      {:ok, record} = Session.process_bundle(nil, bundle, ctx)
      {:ok, {3, message}, _} = Session.encrypt(record, "hi from #{peer_number}", ctx)
      {peer, message}
    end

    decrypt = fn store, peer, message ->
      ctx = %{
        identity: store.identity,
        registration_id: secrets.registration_id,
        local_address: me,
        remote_address: peer,
        trusted?: trust
      }

      Session.decrypt_pre_key(nil, message, ctx, Store.pre_key_lookup(store))
    end

    # A peer takes a bundle from the uploaded batch; Comma decrypts its first
    # message and deletes the one-time keys it used.
    {peer1, message1} = first_message.(1)
    assert {:ok, "hi from 1", _, effects} = decrypt.(pending, peer1, message1)
    pending = Store.apply_effects(pending, effects)

    # The next pass sends the pending upload again. A second peer must still
    # get keys that Comma can use.
    assert {:ok, store} = PreKeyService.maintain(device, :aci, pending, @now + 1, fn _ -> :ok end)
    {peer2, message2} = first_message.(2)
    assert {:ok, "hi from 2", _, _} = decrypt.(store, peer2, message2)
  end

  # Owner decision: a pending body that the service rejects as invalid (422:
  # nothing stored, CRS-03 §9.2) is never sent again. The pass drops it and
  # falls back to the consistency check and counts, which republish valid
  # keys (CRS-03 §9.4).
  test "a rejected pending upload is dropped and the keys are republished", %{
    transport: t,
    fake: fake
  } do
    {{:ok, account}, secrets} = register(t)
    device = Transport.with_credentials(t, Registration.credentials(account, secrets))

    # A signed-key rotation whose stored body carries a bad signature.
    later = @now + 3 * 86_400_000
    {rotated, _body} = Store.refresh(secrets.aci, nil, later)
    bad = Base.encode64(:binary.copy(<<0>>, 64))
    rejected = put_in(rotated.pending["signedPreKey"]["signature"], bad)

    parent = self()
    persist = fn store -> send(parent, {:persisted, store.pending}) && :ok end

    assert {:ok, store} = PreKeyService.maintain(device, :aci, rejected, later, persist)
    assert store.pending == nil
    assert_received {:persisted, nil}
    assert PreKeyService.check(device, :aci, store) == :ok
    assert PreKeyService.counts(device, :aci) == {:ok, %{count: 100, kem_count: 100}}

    # The next pass does not send the rejected body again.
    puts = put_count(fake)
    assert {:ok, ^store} = PreKeyService.maintain(device, :aci, store, later + 1, persist)
    assert put_count(fake) == puts
  end

  @tag locks: %{@number => String.duplicate("ab", 32)}
  test "a registration lock on the number answers 423 until the lock value is sent", %{
    transport: t
  } do
    assert {{:error, {:registration_locked, lock}}, _} = register(t)
    assert lock.time_remaining_ms == 604_387_000
    assert lock.svr2_credentials == %{"username" => "u", "password" => "p"}

    assert {{:ok, _account}, _} = register(t, %{registration_lock: String.duplicate("ab", 32)})
  end

  test "attribute updates carry spqr and the lock; re-registration keeps the ACI", %{
    transport: t,
    fake: fake
  } do
    {{:ok, account}, secrets} = register(t)
    device = Transport.with_credentials(t, Registration.credentials(account, secrets))
    {:ok, svr_key} = AccountKeys.svr_key(AccountKeys.generate_entropy_pool())

    attributes = %{
      registration_id: secrets.registration_id,
      pni_registration_id: secrets.pni_registration_id,
      unidentified_access_key: @access_key,
      registration_lock: AccountKeys.registration_lock_token(svr_key)
    }

    assert Attributes.update(device, attributes) == :ok
    stored = FakeAccountService.state(fake).accounts[@number].attributes
    assert stored["capabilities"] == %{"spqr" => true}
    assert stored["registrationLock"] == AccountKeys.registration_lock_token(svr_key)

    assert {:ok, %{aci: aci}} = Attributes.whoami(device)
    assert aci == account.aci

    stale = Transport.with_credentials(t, Credentials.device(account.aci, 1, "wrong"))
    assert Attributes.whoami(stale) == {:error, :unauthorized}

    assert {{:ok, again}, _} =
             register(t, %{registration_lock: AccountKeys.registration_lock_token(svr_key)})

    assert again.aci == account.aci and again.reregistration
  end

  test "claiming a username with a link, then finding it by hash and by link", %{
    transport: t,
    fake: fake
  } do
    {{:ok, account}, secrets} = register(t)
    device = Transport.with_credentials(t, Registration.credentials(account, secrets))

    # Every two-digit discriminator is taken, so the claim needs a second round.
    taken =
      for d <- 1..99, into: MapSet.new() do
        {:ok, hash} =
          Username.hash("commabot." <> String.pad_leading(Integer.to_string(d), 2, "0"))

        hash
      end

    FakeAccountService.update(fake, &%{&1 | taken_hashes: taken})

    entropy = :crypto.strong_rand_bytes(32)
    assert {:ok, claimed} = Usernames.claim(device, "CommaBot", link_entropy: entropy)
    assert [_, discriminator] = String.split(claimed.username, ".")
    assert String.starts_with?(claimed.username, "CommaBot.") and byte_size(discriminator) == 3
    assert Username.hash(claimed.username) == {:ok, claimed.hash}

    assert Usernames.lookup(t, claimed.hash) == {:ok, account.aci}
    assert Usernames.lookup(device, claimed.hash) == {:error, :invalid_request}

    assert {:ok, encrypted} = Usernames.lookup_link(t, claimed.link_handle)
    assert Username.decrypt_link(entropy, encrypted) == {:ok, claimed.username}

    assert Usernames.claim(device, "1comma") == {:error, :username_rule_1b}
    assert Usernames.claim(device, "commabot", attempts: 1) == {:error, :taken}
  end
end
