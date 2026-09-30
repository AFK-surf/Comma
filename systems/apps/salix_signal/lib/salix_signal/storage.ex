defmodule SalixSignal.Storage do
  @moduledoc """
  The durable state of Signal accounts in Postgres (PLAN "Durable state"),
  through `SalixStore.Repo` and the tables of the salix_store migration
  `CreateSignalTables`.

  This module implements `SalixSignal.Messaging.Store` with the account ID
  (the `signal_accounts.id` UUID string) as the handle, and holds the
  account-record queries that `SalixSignal.Accounts` and
  `SalixSignal.Account.Server` use.

  ## Owner epoch

  `claim/2` makes the caller the account's owner: it increments
  `owner_epoch` and returns the new value. Every write (`commit/3`,
  `advance_delivered/3`, `prune/3`) runs in one transaction that first reads
  `owner_epoch` with a share lock and changes nothing unless it still
  equals the caller's epoch. A claim waits for a commit in progress, and a
  commit after a newer claim returns `{:error, :fenced}`. A session advance
  and the admission of the envelope it decrypted are therefore written
  together or not at all, and only by the current owner.

  Model mapping: this fence is the `SessionEpochFence` abstraction, and the
  admission-before-acknowledgement rule is the `RpcDeliver` durable-append
  property (see `tla/salix/README.md`, "Signal account state").

  ## Encryption at rest

  Row data is sealed with `SalixSignal.Storage.Cipher`, bound to table,
  account and row key. Remote service IDs, group identifiers, sender-key
  identities and message identities are stored only as blind indexes. The
  server GUIDs of admitted envelopes are stored as they are: the service
  chose them at random and they name no party.

  ## Retention

  `prune/3` deletes, at most `@prune_batch` rows per table per call:
  admitted envelopes and message identities older than
  `@inbound_retention_days` days (longer than the service's queue retention,
  CRS-07 §5.3, so a redelivery is still recognized) that the handler has
  seen, sent content older than `@sent_retention_days` days (CRS-07 open
  question 3; Comma's value), and received sender keys unused for
  `@sender_key_retention_days` days (a later message from such a key fails
  and gets a retry request, CRS-09c section 7).
  """

  @behaviour SalixSignal.Messaging.Store

  alias SalixSignal.Messaging.Inbound
  alias SalixSignal.Storage.Cipher
  alias SalixSignalProto.{Address, PreKeys}
  alias SalixSignalProto.SenderKey.Record, as: SenderKeyRecord
  alias SalixSignalProto.Session.Record, as: SessionRecord
  alias SalixStore.Repo

  @envelope 1
  @meta 0
  @one_time 1
  @kem_one_time 2

  @inbound_retention_days 45
  @sent_retention_days 3
  @sender_key_retention_days 180
  @prune_batch 1_000

  @states %{
    registering: "registering",
    active: "active",
    re_registering: "re_registering",
    retired: "retired"
  }

  @typedoc "A group row: see `SalixSignal.Messaging.Store` type `group`."
  @type group :: SalixSignal.Messaging.Store.group()

  # --- account records -----------------------------------------------------

  @doc """
  Inserts a registered account (see `SalixSignal.Accounts.create/1`) and
  its pre-key stores. Returns the new account ID.
  """
  @spec create_account(map()) :: {:ok, String.t()} | {:error, term()}
  def create_account(attrs) do
    with {:ok, keys} <- Cipher.keys() do
      id = Ecto.UUID.generate()
      record = account_record(attrs)
      {scope, organization_id} = scope_columns(Map.get(attrs, :scope, :platform))
      pre_keys = Map.get(attrs, :pre_keys, %{})

      Repo.transaction(fn ->
        result =
          Repo.query(
            """
            INSERT INTO signal_accounts
              (id, state, scope, organization_id, aci_index, number_index, data, inserted_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, now(), now())
            """,
            [
              dump(id),
              Map.fetch!(@states, Map.get(attrs, :state, :active)),
              scope,
              organization_id,
              record.aci && Cipher.index(keys, :signal_accounts, "", {:aci, record.aci}),
              record.e164 && Cipher.index(keys, :signal_accounts, "", {:number, record.e164}),
              Cipher.seal(keys, {:signal_accounts, id, "account"}, record)
            ]
          )

        case result do
          {:ok, _} ->
            for {kind, %PreKeys.Store{} = store} <- pre_keys,
                do: save_pre_keys(%{keys: keys, id: id}, kind, store)

            id

          {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
            Repo.rollback(:exists)

          {:error, error} ->
            Repo.rollback(error)
        end
      end)
    end
  end

  defp account_record(attrs) do
    %{
      aci: Map.get(attrs, :aci),
      pni: Map.get(attrs, :pni),
      e164: Map.get(attrs, :e164),
      device_id: Map.get(attrs, :device_id, 1),
      password: Map.fetch!(attrs, :password),
      identities: Map.fetch!(attrs, :identities),
      registration_ids: Map.fetch!(attrs, :registration_ids),
      profile_key: Map.get(attrs, :profile_key),
      environment: Map.get(attrs, :environment, :production)
    }
  end

  defp scope_columns(:platform), do: {"platform", nil}

  defp scope_columns({:organization, organization_id}) when is_binary(organization_id),
    do: {"organization", organization_id}

  @doc """
  The stored material of an account in state `registering`: the
  `SalixSignal.Account.Registration.NewAccount` its registration request
  sends, and its profile key. It was stored before the request, so a
  registration can be sent again with the same keys.
  """
  @spec registration(String.t()) ::
          {:ok, %{account: struct(), profile_key: binary() | nil}}
          | {:error, :not_found | :not_registering | term()}
  def registration(id) do
    with {:ok, keys} <- Cipher.keys(),
         {:ok, uuid} <- cast(id) do
      case Repo.query!("SELECT state, data FROM signal_accounts WHERE id = $1", [uuid]).rows do
        [["registering", data]] ->
          with {:ok, record} <- Cipher.open(keys, {:signal_accounts, id, "account"}, data) do
            {:ok,
             %{
               account: %SalixSignal.Account.Registration.NewAccount{
                 number: record.e164,
                 password: record.password,
                 aci: load_pre_keys(keys, id, :aci),
                 pni: load_pre_keys(keys, id, :pni),
                 registration_id: record.registration_ids.aci,
                 pni_registration_id: record.registration_ids.pni
               },
               profile_key: record.profile_key
             }}
          end

        [[_state, _data]] ->
          {:error, :not_registering}

        [] ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Completes a registration: records the account IDs that the service
  returned (CRS-02 §3.3) and makes the account `active`. A re-registration
  keeps the ACI (CRS-02 §3.5), so an earlier row with the same ACI is
  retired in the same transaction; its keys are no longer valid at the
  service.
  """
  @spec complete_registration(String.t(), %{aci: String.t()}) :: :ok | {:error, term()}
  def complete_registration(id, %{aci: aci} = registered) when is_binary(aci) do
    with {:ok, keys} <- Cipher.keys(),
         {:ok, uuid} <- cast(id) do
      aci_index = Cipher.index(keys, :signal_accounts, "", {:aci, aci})

      Repo.transaction(fn ->
        case Repo.query!(
               "SELECT data FROM signal_accounts WHERE id = $1 AND state = 'registering' FOR UPDATE",
               [uuid]
             ).rows do
          [[data]] ->
            {:ok, record} = Cipher.open(keys, {:signal_accounts, id, "account"}, data)
            record = %{record | aci: aci, pni: Map.get(registered, :pni)}

            Repo.query!(
              """
              UPDATE signal_accounts SET state = 'retired', aci_index = NULL, updated_at = now()
              WHERE aci_index = $1 AND id <> $2
              """,
              [aci_index, uuid]
            )

            Repo.query!(
              """
              UPDATE signal_accounts
              SET state = 'active', aci_index = $2, data = $3, updated_at = now()
              WHERE id = $1
              """,
              [uuid, aci_index, Cipher.seal(keys, {:signal_accounts, id, "account"}, record)]
            )

          [] ->
            Repo.rollback(:not_registering)
        end
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The account summary (no secrets), or `{:error, :not_found}`."
  @spec get_account(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_account(id) do
    with {:ok, keys} <- Cipher.keys(),
         {:ok, uuid} <- cast(id) do
      %{rows: rows} =
        Repo.query!(
          "SELECT id, state, scope, organization_id, data FROM signal_accounts WHERE id = $1",
          [uuid]
        )

      case rows do
        [row] -> summary(keys, row)
        [] -> {:error, :not_found}
      end
    end
  end

  @doc "The account summary for a blind-indexed `{:aci, aci}` or `{:number, e164}`."
  @spec find_account({:aci | :number, String.t()}) :: {:ok, map()} | {:error, :not_found | term()}
  def find_account({kind, value} = key) when kind in [:aci, :number] and is_binary(value) do
    with {:ok, keys} <- Cipher.keys() do
      column = if kind == :aci, do: "aci_index", else: "number_index"

      %{rows: rows} =
        Repo.query!(
          "SELECT id, state, scope, organization_id, data FROM signal_accounts " <>
            "WHERE #{column} = $1 ORDER BY (state = 'active') DESC, updated_at DESC LIMIT 1",
          [Cipher.index(keys, :signal_accounts, "", key)]
        )

      case rows do
        [row] -> summary(keys, row)
        [] -> {:error, :not_found}
      end
    end
  end

  @doc """
  The summaries of every account stored with the E.164 number `e164`, in
  any state and environment, newest first. At most `limit` rows (default
  and cap 50); a number has one row per registration attempt that kept it.
  """
  @spec accounts_by_number(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def accounts_by_number(e164, limit \\ 50) when is_binary(e164) do
    with {:ok, keys} <- Cipher.keys() do
      %{rows: rows} =
        Repo.query!(
          "SELECT id, state, scope, organization_id, data FROM signal_accounts " <>
            "WHERE number_index = $1 ORDER BY updated_at DESC LIMIT $2",
          [Cipher.index(keys, :signal_accounts, "", {:number, e164}), limit |> min(50) |> max(1)]
        )

      {:ok,
       Enum.flat_map(rows, fn row ->
         case summary(keys, row) do
           {:ok, summary} -> [summary]
           {:error, _} -> []
         end
       end)}
    end
  end

  @doc """
  One page of account summaries ordered by ID. Options: `:limit` (default
  100, at most 500), `:after` (an account ID), `:state`.
  """
  @spec list_accounts(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_accounts(opts \\ []) do
    with {:ok, keys} <- Cipher.keys() do
      limit = opts |> Keyword.get(:limit, 100) |> min(500) |> max(1)
      after_id = with id when is_binary(id) <- opts[:after], {:ok, uuid} <- cast(id), do: uuid
      state = if s = opts[:state], do: Map.fetch!(@states, s)

      %{rows: rows} =
        Repo.query!(
          """
          SELECT id, state, scope, organization_id, data FROM signal_accounts
          WHERE ($1::uuid IS NULL OR id > $1) AND ($2::text IS NULL OR state = $2)
          ORDER BY id LIMIT $3
          """,
          [if(is_binary(after_id), do: after_id), state, limit]
        )

      {:ok,
       Enum.flat_map(rows, fn row ->
         case summary(keys, row) do
           {:ok, summary} -> [summary]
           {:error, _} -> []
         end
       end)}
    end
  end

  @doc "Sets the account state."
  @spec set_state(String.t(), atom()) :: :ok | {:error, :not_found}
  def set_state(id, state) do
    with {:ok, uuid} <- cast(id) do
      %{num_rows: n} =
        Repo.query!(
          "UPDATE signal_accounts SET state = $2, updated_at = now() WHERE id = $1",
          [uuid, Map.fetch!(@states, state)]
        )

      if n == 1, do: :ok, else: {:error, :not_found}
    end
  end

  defp summary(keys, [uuid, state, scope, organization_id, data]) do
    id = load(uuid)

    with {:ok, record} <- Cipher.open(keys, {:signal_accounts, id, "account"}, data) do
      {:ok,
       %{
         id: id,
         aci: record.aci,
         pni: record.pni,
         e164: record.e164,
         device_id: record.device_id,
         environment: record.environment,
         state: state |> String.to_existing_atom(),
         scope: if(scope == "platform", do: :platform, else: {:organization, organization_id})
       }}
    end
  end

  @doc """
  Makes the caller the owner of an `active` account: increments the owner
  epoch and records `node`. Returns the new epoch, the decrypted account
  record (with secrets), the delivery cursor and the highest send timestamp
  that an earlier owner committed (`{:put_send_timestamp, ms}`), which the
  new owner's timestamps must exceed.
  """
  @spec claim(String.t(), node()) ::
          {:ok,
           %{
             epoch: pos_integer(),
             account: map(),
             delivered_seq: non_neg_integer(),
             last_send_timestamp: non_neg_integer()
           }}
          | {:error, :not_found | :not_active | :storage_key_missing | :undecryptable}
  def claim(id, node) do
    with {:ok, keys} <- Cipher.keys(),
         {:ok, uuid} <- cast(id) do
      %{rows: rows} =
        Repo.query!(
          """
          UPDATE signal_accounts
          SET owner_epoch = owner_epoch + 1, owner_node = $2, updated_at = now()
          WHERE id = $1 AND state = 'active'
          RETURNING owner_epoch, data, delivered_seq, last_send_timestamp
          """,
          [uuid, Atom.to_string(node)]
        )

      case rows do
        [[epoch, data, delivered, last_send_timestamp]] ->
          with {:ok, account} <- Cipher.open(keys, {:signal_accounts, id, "account"}, data) do
            {:ok,
             %{
               epoch: epoch,
               account: account,
               delivered_seq: delivered,
               last_send_timestamp: last_send_timestamp
             }}
          end

        [] ->
          if Repo.query!("SELECT 1 FROM signal_accounts WHERE id = $1", [uuid]).num_rows == 1,
            do: {:error, :not_active},
            else: {:error, :not_found}
      end
    end
  end

  @doc "The current owner epoch and node, or nil."
  @spec owner(String.t()) :: %{epoch: non_neg_integer(), node: String.t() | nil} | nil
  def owner(id) do
    with {:ok, uuid} <- cast(id),
         %{rows: [[epoch, node]]} <-
           Repo.query!("SELECT owner_epoch, owner_node FROM signal_accounts WHERE id = $1", [uuid]) do
      %{epoch: epoch, node: node}
    else
      _ -> nil
    end
  end

  @doc "Moves the handler delivery cursor forward to `seq`, fenced by `epoch`."
  @spec advance_delivered(String.t(), pos_integer(), non_neg_integer()) :: :ok | {:error, :fenced}
  def advance_delivered(id, epoch, seq) do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE signal_accounts SET delivered_seq = GREATEST(delivered_seq, $3)
        WHERE id = $1 AND owner_epoch = $2
        """,
        [dump(id), epoch, seq]
      )

    if n == 1, do: :ok, else: {:error, :fenced}
  end

  @doc """
  Admitted envelopes after `seq`, ascending, at most `limit` (at most
  500): `[{seq, %SalixSignal.Messaging.Inbound{}}]`.
  """
  @spec inbound_after(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [{pos_integer(), Inbound.t()}]} | {:error, term()}
  def inbound_after(id, seq, limit) do
    with {:ok, keys} <- Cipher.keys(),
         {:ok, uuid} <- cast(id) do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT seq, key, data FROM signal_inbound
          WHERE account_id = $1 AND kind = 1 AND seq > $2
          ORDER BY seq LIMIT $3
          """,
          [uuid, seq, limit |> min(500) |> max(1)]
        )

      {:ok,
       for [seq, guid, data] <- rows do
         {:ok, inbound} = Cipher.open(keys, {:signal_inbound, id, <<@envelope>> <> guid}, data)
         {seq, inbound}
       end}
    end
  end

  @doc "The account's groups, most recently changed first (at most 500)."
  @spec groups(String.t()) :: [group()]
  def groups(id) do
    with {:ok, keys} <- Cipher.keys(),
         {:ok, uuid} <- cast(id) do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT group_index, data FROM signal_groups
          WHERE account_id = $1 ORDER BY updated_at DESC LIMIT 500
          """,
          [uuid]
        )

      for [index, data] <- rows,
          {:ok, group} <- [Cipher.open(keys, {:signal_groups, id, index}, data)],
          do: group
    else
      _ -> []
    end
  end

  @doc """
  Deletes expired rows of the account (see the module documentation),
  fenced by `epoch`. Returns the number of deleted rows.
  """
  @spec prune(String.t(), pos_integer(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :fenced}
  def prune(id, epoch, now \\ DateTime.utc_now()) do
    uuid = dump(id)

    fenced(uuid, epoch, fn ->
      inbound =
        Repo.query!(
          """
          DELETE FROM signal_inbound WHERE ctid IN (
            SELECT i.ctid FROM signal_inbound i JOIN signal_accounts a ON a.id = i.account_id
            WHERE i.account_id = $1 AND i.admitted_at < $2
              AND (i.kind = 2 OR i.seq <= a.delivered_seq)
            LIMIT $3)
          """,
          [uuid, DateTime.add(now, -@inbound_retention_days, :day), @prune_batch]
        )

      sent =
        Repo.query!(
          """
          DELETE FROM signal_sent WHERE ctid IN (
            SELECT ctid FROM signal_sent WHERE account_id = $1 AND sent_at < $2 LIMIT $3)
          """,
          [uuid, DateTime.add(now, -@sent_retention_days, :day), @prune_batch]
        )

      sender_keys =
        Repo.query!(
          """
          DELETE FROM signal_sender_keys WHERE ctid IN (
            SELECT ctid FROM signal_sender_keys WHERE account_id = $1 AND updated_at < $2 LIMIT $3)
          """,
          [uuid, DateTime.add(now, -@sender_key_retention_days, :day), @prune_batch]
        )

      inbound.num_rows + sent.num_rows + sender_keys.num_rows
    end)
  end

  # --- SalixSignal.Messaging.Store: reads -------------------------------------

  @impl true
  def session(id, %Address{name: name, device_id: device}) do
    keys = keys!()
    index = Cipher.index(keys, :signal_sessions, id, name)

    case Repo.query!(
           "SELECT data FROM signal_sessions WHERE account_id = $1 AND name_index = $2 AND device_id = $3",
           [dump(id), index, device]
         ).rows do
      [[data]] ->
        {:ok, bytes} = Cipher.open(keys, {:signal_sessions, id, index <> <<device>>}, data)
        {:ok, record} = SessionRecord.decode(bytes)
        record

      [] ->
        nil
    end
  end

  @impl true
  def device_ids(id, name) do
    index = Cipher.index(keys!(), :signal_sessions, id, name)

    for [device] <-
          Repo.query!(
            "SELECT device_id FROM signal_sessions WHERE account_id = $1 AND name_index = $2 ORDER BY device_id",
            [dump(id), index]
          ).rows,
        do: device
  end

  @impl true
  def identity(id, name), do: identity_column(id, name, "identity")

  @impl true
  def contact(id, name), do: identity_column(id, name, "contact")

  defp identity_column(id, name, column) do
    keys = keys!()
    index = Cipher.index(keys, :signal_identities, id, name)

    case Repo.query!(
           "SELECT #{column} FROM signal_identities WHERE account_id = $1 AND name_index = $2",
           [dump(id), index]
         ).rows do
      [[data]] when is_binary(data) ->
        {:ok, value} = Cipher.open(keys, {:signal_identities, id, index <> column}, data)
        value

      _ ->
        nil
    end
  end

  @impl true
  def pre_keys(id, kind) do
    case load_pre_keys(keys!(), id, kind) do
      nil -> fn _ -> :error end
      store -> PreKeys.Store.pre_key_lookup(store)
    end
  end

  @doc "The stored pre-key store of identity `kind`, or nil."
  @spec pre_key_store(String.t(), :aci | :pni) :: PreKeys.Store.t() | nil
  def pre_key_store(id, kind), do: load_pre_keys(keys!(), id, kind)

  @impl true
  def admitted?(id, <<_::binary-size(16)>> = guid) do
    Repo.query!(
      "SELECT 1 FROM signal_inbound WHERE account_id = $1 AND kind = 1 AND key = $2",
      [dump(id), guid]
    ).num_rows == 1
  end

  @impl true
  def message_seen?(id, key) do
    Repo.query!(
      "SELECT 1 FROM signal_inbound WHERE account_id = $1 AND kind = 2 AND key = $2",
      [dump(id), Cipher.index(keys!(), :signal_inbound, id, key)]
    ).num_rows == 1
  end

  @impl true
  def sent(id, key) do
    keys = keys!()
    index = Cipher.index(keys, :signal_sent, id, key)

    case Repo.query!(
           "SELECT data FROM signal_sent WHERE account_id = $1 AND key_index = $2",
           [dump(id), index]
         ).rows do
      [[data]] ->
        {:ok, sent} = Cipher.open(keys, {:signal_sent, id, index}, data)
        sent

      [] ->
        nil
    end
  end

  @impl true
  def sender_key(
        id,
        %Address{name: name, device_id: device},
        <<_::binary-size(16)>> = distribution
      ) do
    keys = keys!()
    index = Cipher.index(keys, :signal_sender_keys, id, {name, device, distribution})

    case Repo.query!(
           "SELECT data FROM signal_sender_keys WHERE account_id = $1 AND key_index = $2",
           [dump(id), index]
         ).rows do
      [[data]] ->
        {:ok, bytes} = Cipher.open(keys, {:signal_sender_keys, id, index}, data)
        {:ok, record} = SenderKeyRecord.decode(bytes)
        record

      [] ->
        nil
    end
  end

  @impl true
  def group(id, <<_::binary-size(32)>> = group_id) do
    keys = keys!()
    index = Cipher.index(keys, :signal_groups, id, group_id)

    case Repo.query!(
           "SELECT data FROM signal_groups WHERE account_id = $1 AND group_index = $2",
           [dump(id), index]
         ).rows do
      [[data]] ->
        {:ok, group} = Cipher.open(keys, {:signal_groups, id, index}, data)
        group

      [] ->
        nil
    end
  end

  # --- SalixSignal.Messaging.Store: commit ------------------------------------

  @impl true
  def commit(id, epoch, ops) when is_list(ops) do
    with {:ok, keys} <- Cipher.keys() do
      context = %{keys: keys, id: id, uuid: dump(id)}

      case fenced(context.uuid, epoch, fn -> Enum.each(ops, &apply_op(context, &1)) end) do
        {:ok, :ok} -> :ok
        {:error, :fenced} -> {:error, :fenced}
      end
    end
  end

  defp fenced(uuid, epoch, fun) do
    Repo.transaction(fn ->
      case Repo.query!("SELECT owner_epoch FROM signal_accounts WHERE id = $1 FOR SHARE", [uuid]) do
        %{rows: [[^epoch]]} -> fun.()
        _ -> Repo.rollback(:fenced)
      end
    end)
  end

  defp apply_op(c, {:put_session, %Address{name: name, device_id: device}, record}) do
    index = Cipher.index(c.keys, :signal_sessions, c.id, name)

    data =
      Cipher.seal(
        c.keys,
        {:signal_sessions, c.id, index <> <<device>>},
        SessionRecord.encode(record)
      )

    Repo.query!(
      """
      INSERT INTO signal_sessions (account_id, name_index, device_id, data) VALUES ($1, $2, $3, $4)
      ON CONFLICT (account_id, name_index, device_id) DO UPDATE SET data = EXCLUDED.data
      """,
      [c.uuid, index, device, data]
    )
  end

  defp apply_op(c, {:delete_session, %Address{name: name, device_id: device}}) do
    Repo.query!(
      "DELETE FROM signal_sessions WHERE account_id = $1 AND name_index = $2 AND device_id = $3",
      [c.uuid, Cipher.index(c.keys, :signal_sessions, c.id, name), device]
    )
  end

  defp apply_op(c, {:put_identity, name, key}), do: put_identity_column(c, name, "identity", key)

  defp apply_op(c, {:put_contact, name, contact}),
    do: put_identity_column(c, name, "contact", contact)

  defp apply_op(c, {:pre_key_effects, kind, effects}) do
    case load_pre_keys(c.keys, c.id, kind) do
      nil -> :ok
      store -> save_pre_keys(c, kind, PreKeys.Store.apply_effects(store, effects))
    end
  end

  defp apply_op(c, {:put_pre_keys, kind, %PreKeys.Store{} = store}),
    do: save_pre_keys(c, kind, store)

  defp apply_op(c, {:admit, <<_::binary-size(16)>> = guid, %Inbound{} = inbound}) do
    Repo.query!(
      """
      INSERT INTO signal_inbound (account_id, kind, key, data, admitted_at)
      VALUES ($1, 1, $2, $3, now()) ON CONFLICT DO NOTHING
      """,
      [c.uuid, guid, Cipher.seal(c.keys, {:signal_inbound, c.id, <<@envelope>> <> guid}, inbound)]
    )
  end

  defp apply_op(c, {:record_message, key}) do
    Repo.query!(
      """
      INSERT INTO signal_inbound (account_id, kind, key, admitted_at)
      VALUES ($1, 2, $2, now()) ON CONFLICT DO NOTHING
      """,
      [c.uuid, Cipher.index(c.keys, :signal_inbound, c.id, key)]
    )
  end

  defp apply_op(c, {:put_sent, key, sent}) do
    index = Cipher.index(c.keys, :signal_sent, c.id, key)

    Repo.query!(
      """
      INSERT INTO signal_sent (account_id, key_index, data, sent_at) VALUES ($1, $2, $3, now())
      ON CONFLICT (account_id, key_index) DO UPDATE SET data = EXCLUDED.data, sent_at = now()
      """,
      [c.uuid, index, Cipher.seal(c.keys, {:signal_sent, c.id, index}, sent)]
    )
  end

  defp apply_op(c, {:sender_key, {%Address{name: name, device_id: device}, distribution, record}}) do
    index = Cipher.index(c.keys, :signal_sender_keys, c.id, {name, device, distribution})
    data = Cipher.seal(c.keys, {:signal_sender_keys, c.id, index}, SenderKeyRecord.encode(record))

    Repo.query!(
      """
      INSERT INTO signal_sender_keys (account_id, key_index, data, updated_at) VALUES ($1, $2, $3, now())
      ON CONFLICT (account_id, key_index) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
      """,
      [c.uuid, index, data]
    )
  end

  defp apply_op(c, {:put_group, <<_::binary-size(32)>> = group_id, group}) do
    index = Cipher.index(c.keys, :signal_groups, c.id, group_id)

    Repo.query!(
      """
      INSERT INTO signal_groups (account_id, group_index, data, updated_at) VALUES ($1, $2, $3, now())
      ON CONFLICT (account_id, group_index) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
      """,
      [c.uuid, index, Cipher.seal(c.keys, {:signal_groups, c.id, index}, group)]
    )
  end

  # A plain column: the timestamp names no party, and the service receives
  # it with every send.
  defp apply_op(c, {:put_send_timestamp, ms}) when is_integer(ms) and ms >= 0 do
    Repo.query!(
      """
      UPDATE signal_accounts SET last_send_timestamp = GREATEST(last_send_timestamp, $2)
      WHERE id = $1
      """,
      [c.uuid, ms]
    )
  end

  defp put_identity_column(c, name, column, value) do
    index = Cipher.index(c.keys, :signal_identities, c.id, name)
    data = Cipher.seal(c.keys, {:signal_identities, c.id, index <> column}, value)

    Repo.query!(
      """
      INSERT INTO signal_identities (account_id, name_index, #{column}) VALUES ($1, $2, $3)
      ON CONFLICT (account_id, name_index) DO UPDATE SET #{column} = EXCLUDED.#{column}
      """,
      [c.uuid, index, data]
    )
  end

  # --- pre-key rows -------------------------------------------------------------

  defp load_pre_keys(keys, id, kind) do
    identity = Atom.to_string(kind)

    rows =
      Repo.query!(
        "SELECT slot, key_id, data FROM signal_prekeys WHERE account_id = $1 AND identity = $2",
        [dump(id), identity]
      ).rows

    open = fn slot, key_id, data ->
      {:ok, value} =
        Cipher.open(keys, {:signal_prekeys, id, pre_key_row(identity, slot, key_id)}, data)

      value
    end

    case Enum.find(rows, &match?([@meta, 0, _], &1)) do
      nil ->
        nil

      [@meta, 0, data] ->
        meta = open.(@meta, 0, data)

        Enum.reduce(rows, meta, fn
          [@one_time, key_id, data], store ->
            %{store | one_time: Map.put(store.one_time, key_id, open.(@one_time, key_id, data))}

          [@kem_one_time, key_id, data], store ->
            %{
              store
              | kem_one_time:
                  Map.put(store.kem_one_time, key_id, open.(@kem_one_time, key_id, data))
            }

          _meta, store ->
            store
        end)
    end
  end

  # One-time keys never change once made, so only new IDs are written and
  # missing IDs deleted; the rest of the store is one row.
  defp save_pre_keys(c, kind, %PreKeys.Store{} = store) do
    identity = Atom.to_string(kind)
    uuid = dump(c.id)

    existing =
      Repo.query!(
        "SELECT slot, key_id FROM signal_prekeys WHERE account_id = $1 AND identity = $2 AND slot <> 0",
        [uuid, identity]
      ).rows
      |> MapSet.new(fn [slot, key_id] -> {slot, key_id} end)

    wanted =
      Enum.map(store.one_time, fn {key_id, key} -> {{@one_time, key_id}, key} end) ++
        Enum.map(store.kem_one_time, fn {key_id, key} -> {{@kem_one_time, key_id}, key} end)

    wanted_ids = MapSet.new(wanted, &elem(&1, 0))

    for {slot, key_id} <- MapSet.difference(existing, wanted_ids) do
      Repo.query!(
        "DELETE FROM signal_prekeys WHERE account_id = $1 AND identity = $2 AND slot = $3 AND key_id = $4",
        [uuid, identity, slot, key_id]
      )
    end

    meta = %{store | one_time: %{}, kem_one_time: %{}}

    rows =
      [{{@meta, 0}, meta}] ++
        Enum.reject(wanted, fn {row, _key} -> MapSet.member?(existing, row) end)

    for {{slot, key_id}, value} <- rows do
      data =
        Cipher.seal(c.keys, {:signal_prekeys, c.id, pre_key_row(identity, slot, key_id)}, value)

      Repo.query!(
        """
        INSERT INTO signal_prekeys (account_id, identity, slot, key_id, data) VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (account_id, identity, slot, key_id) DO UPDATE SET data = EXCLUDED.data
        """,
        [uuid, identity, slot, key_id, data]
      )
    end

    :ok
  end

  defp pre_key_row(identity, slot, key_id), do: identity <> <<slot, key_id::32>>

  # --- helpers --------------------------------------------------------------

  defp keys! do
    case Cipher.keys() do
      {:ok, keys} -> keys
      {:error, reason} -> raise ArgumentError, "signal storage unavailable: #{reason}"
    end
  end

  defp cast(id) do
    case Ecto.UUID.dump(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
  defp load(uuid), do: Ecto.UUID.load!(uuid)
end
