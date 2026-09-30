defmodule SalixSignal.StorageTest do
  # The Postgres store of Signal accounts (PLAN "Durable state"): owner
  # epoch fencing, all-or-nothing commits, per-row pre-keys, encryption at
  # rest and the durable inbound feed.
  use ExUnit.Case, async: false

  alias SalixSignal.Messaging.Inbound
  alias SalixSignal.Storage
  alias SalixSignal.Storage.Cipher
  alias SalixSignalProto.{Address, Keys, PreKeys}
  alias SalixSignalProto.Session.Record
  alias SalixStore.Repo

  @aci "00000000-0000-4000-8000-000000000071"
  @peer "00000000-0000-4000-8000-000000000072"
  @number "+15550100071"

  setup do
    {:ok, keys} = Cipher.keys()

    Repo.query!("DELETE FROM signal_accounts WHERE aci_index = $1", [
      Cipher.index(keys, :signal_accounts, "", {:aci, @aci})
    ])

    identity = Keys.ec_keypair()
    now = System.system_time(:millisecond)
    pre_keys = PreKeys.Store.new(identity, now)
    one_time = for id <- 1..3, do: PreKeys.one_time_pre_key(id, now)
    pre_keys = %{pre_keys | one_time: Map.new(one_time, &{&1.id, &1})}

    {:ok, id} =
      Storage.create_account(%{
        aci: @aci,
        pni: nil,
        e164: @number,
        device_id: 1,
        password: "device-password",
        identities: %{aci: identity, pni: nil},
        registration_ids: %{aci: 1234, pni: 0},
        profile_key: :binary.copy(<<7>>, 32),
        pre_keys: %{aci: pre_keys},
        scope: {:organization, "org-71"},
        environment: :staging
      })

    %{id: id, identity: identity, pre_keys: pre_keys, keys: keys}
  end

  defp record, do: %Record{current: nil, previous: []}

  test "a registered account is found by ACI and number without its secrets", %{id: id} do
    assert {:ok, summary} = Storage.get_account(id)

    assert %{
             id: ^id,
             aci: @aci,
             e164: @number,
             device_id: 1,
             state: :active,
             scope: {:organization, "org-71"},
             environment: :staging
           } = summary

    refute Map.has_key?(summary, :password)
    assert {:ok, %{id: ^id}} = Storage.find_account({:aci, @aci})
    assert {:ok, %{id: ^id}} = Storage.find_account({:number, @number})

    assert {:error, :exists} =
             Storage.create_account(%{
               aci: @aci,
               password: "x",
               identities: %{aci: Keys.ec_keypair(), pni: nil},
               registration_ids: %{aci: 1, pni: 0}
             })
  end

  test "a newer claim fences every write of the earlier owner", %{id: id} do
    {:ok, %{epoch: first, account: account}} = Storage.claim(id, node())
    assert account.password == "device-password"
    address = Address.new(@peer, 1)

    assert :ok = Storage.commit(id, first, [{:put_session, address, record()}])

    {:ok, %{epoch: second}} = Storage.claim(id, node())
    assert second == first + 1

    assert {:error, :fenced} =
             Storage.commit(id, first, [
               {:delete_session, address},
               {:put_identity, @peer, <<5, 1::256>>}
             ])

    assert Storage.session(id, address) == record()
    assert Storage.identity(id, @peer) == nil
    assert {:error, :fenced} = Storage.advance_delivered(id, first, 10)
    assert {:error, :fenced} = Storage.prune(id, first)
    assert :ok = Storage.commit(id, second, [{:delete_session, address}])
    assert Storage.session(id, address) == nil

    # A retired account cannot be claimed.
    :ok = Storage.set_state(id, :retired)
    assert {:error, :not_active} = Storage.claim(id, node())
  end

  test "a commit that fails part way changes nothing", %{id: id} do
    {:ok, %{epoch: epoch}} = Storage.claim(id, node())
    guid = :crypto.strong_rand_bytes(16)

    assert_raise FunctionClauseError, fn ->
      Storage.commit(id, epoch, [
        {:put_session, Address.new(@peer, 2), record()},
        {:admit, guid, %Inbound{guid: guid, outcome: :message}},
        {:no_such_operation}
      ])
    end

    assert Storage.session(id, Address.new(@peer, 2)) == nil
    refute Storage.admitted?(id, guid)
  end

  test "one-time pre-keys are rows: using one deletes only that row", %{
    id: id,
    pre_keys: pre_keys
  } do
    {:ok, %{epoch: epoch}} = Storage.claim(id, node())
    assert Storage.pre_key_store(id, :aci) == pre_keys

    count = fn ->
      Repo.query!("SELECT count(*) FROM signal_prekeys WHERE account_id = $1", [
        Ecto.UUID.dump!(id)
      ]).rows
    end

    assert count.() == [[4]]
    lookup = Storage.pre_keys(id, :aci)
    assert {:ok, _private} = lookup.({:one_time_pre_key, 2})

    :ok =
      Storage.commit(id, epoch, [
        {:pre_key_effects, :aci, %{used_one_time_pre_key: 2, used_kem_pre_key: nil}}
      ])

    assert count.() == [[3]]
    assert :error = Storage.pre_keys(id, :aci).({:one_time_pre_key, 2})

    assert Storage.pre_key_store(id, :aci) == %{
             pre_keys
             | one_time: Map.delete(pre_keys.one_time, 2)
           }

    assert Storage.pre_key_store(id, :pni) == nil
  end

  test "rows are sealed: no peer ID or key in plain text, and they do not open under another key",
       %{id: id, keys: keys} do
    {:ok, %{epoch: epoch}} = Storage.claim(id, node())
    peer_key = Keys.ec_keypair().public
    profile_key = :crypto.strong_rand_bytes(32)
    contact = %{profile_key: profile_key, expire_timer: nil, unregistered?: false}

    :ok =
      Storage.commit(id, epoch, [
        {:put_identity, @peer, peer_key},
        {:put_contact, @peer, contact},
        {:record_message, {@peer, 1_758_000_000_000, {:direct, @peer}}}
      ])

    assert Storage.identity(id, @peer) == peer_key
    assert Storage.contact(id, @peer) == contact
    assert Storage.message_seen?(id, {@peer, 1_758_000_000_000, {:direct, @peer}})
    refute Storage.message_seen?(id, {@peer, 1_758_000_000_001, {:direct, @peer}})

    dump =
      for table <- ~w(signal_accounts signal_identities signal_inbound signal_prekeys),
          row <-
            Repo.query!(
              "SELECT * FROM #{table} WHERE #{if table == "signal_accounts", do: "id", else: "account_id"} = $1",
              [Ecto.UUID.dump!(id)]
            ).rows,
          value <- row,
          is_binary(value),
          into: <<>>,
          do: value

    {:ok, raw_peer} = SalixSignalProto.ServiceId.aci_from_string(@peer)

    for secret <- [@peer, raw_peer, peer_key, profile_key, @number, "device-password"] do
      refute :binary.match(dump, secret) != :nomatch, "found #{inspect(secret)} in plain text"
    end

    [[data]] =
      Repo.query!("SELECT identity FROM signal_identities WHERE account_id = $1", [
        Ecto.UUID.dump!(id)
      ]).rows

    index = Cipher.index(keys, :signal_identities, id, @peer)

    assert {:ok, ^peer_key} =
             Cipher.open(keys, {:signal_identities, id, index <> "identity"}, data)

    other = %{keys | data: :crypto.strong_rand_bytes(32)}

    assert {:error, :undecryptable} =
             Cipher.open(other, {:signal_identities, id, index <> "identity"}, data)

    # Bound to its row: the same bytes do not open as another row.
    assert {:error, :undecryptable} =
             Cipher.open(keys, {:signal_identities, id, index <> "contact"}, data)
  end

  test "without the storage key nothing is read or written", %{id: id} do
    key = Application.get_env(:salix_agent, :subscription_storage_key)
    Application.delete_env(:salix_agent, :subscription_storage_key)
    on_exit(fn -> Application.put_env(:salix_agent, :subscription_storage_key, key) end)

    assert {:error, :storage_key_missing} = Storage.claim(id, node())
    assert {:error, :storage_key_missing} = Storage.commit(id, 1, [])
    assert {:error, :storage_key_missing} = Storage.get_account(id)
  end

  test "the inbound feed lists admitted envelopes in order after a cursor", %{id: id} do
    {:ok, %{epoch: epoch, delivered_seq: 0}} = Storage.claim(id, node())

    guids = for _ <- 1..3, do: :crypto.strong_rand_bytes(16)

    for guid <- guids do
      :ok = Storage.commit(id, epoch, [{:admit, guid, %Inbound{guid: guid, outcome: :message}}])
    end

    assert {:ok, items} = Storage.inbound_after(id, 0, 10)
    assert Enum.map(items, fn {_seq, inbound} -> inbound.guid end) == guids
    [{first, _}, {second, _}, _] = items
    assert {:ok, [_, _]} = Storage.inbound_after(id, first, 10)

    :ok = Storage.advance_delivered(id, epoch, second)
    # The cursor never moves back.
    :ok = Storage.advance_delivered(id, epoch, first)
    assert {:ok, %{delivered_seq: ^second}} = Storage.claim(id, node())
  end
end
