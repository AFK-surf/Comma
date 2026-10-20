defmodule SalixSignal.Account.AccountTest do
  # Layer C4 against a fake chat service written from CRS-02 and CRS-03 §9:
  # verification with an operator-solved captcha, registration, pre-key
  # publication and rotation, attributes and usernames. A peer then starts a
  # session from the published bundle and Comma decrypts it with its stored
  # keys, which checks that the published keys and the local store agree.
  use SystemsClock.Case, async: true

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

  test "registration, pre-key publication and a peer session to the published keys",
       %{transport: t, fake: fake} do
    assert {{:ok, account}, secrets} = register(t)
    refute account.reregistration
    device = Transport.with_credentials(t, Registration.credentials(account, secrets))

    # The service now holds the registration pre-keys, but no one-time keys.
    assert PreKeyService.counts(device, :aci) == {:ok, %{count: 0, kem_count: 0}}

    persist = fn store ->
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:persisted, store.pending != nil, put_count(fake)}
      )

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

    entropy = SystemsRuntime.Proc.random_bytes(32)
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
