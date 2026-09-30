defmodule SalixSignalProto.PreKeys.Store do
  @moduledoc """
  The local pre-keys of one identity (ACI or PNI) of one device, and the
  pre-key lifecycle of CRS-03 §10.

  The store is a pure value. The account owner keeps it durably and changes
  it only through these functions.

  ## Lifecycle

  1. `new/2` makes the identity's first signed EC pre-key and last-resort
     KEM pre-key. Registration sends them (CRS-02 §3.1).
  2. `refresh/3` compares the store and the service counts with the policy
     below, adds new keys and returns the upload body. The caller stores the
     new store durably first, then uploads (`PUT /v2/keys`, CRS-03 §9.2), then
     calls `uploaded/1`. Until then the store keeps the body as `pending`,
     and `refresh/3` returns it again, with new one-time batches in place of
     the earlier ones: the service can have stored the earlier upload and
     handed out its one-time keys. Private keys are therefore durable before
     the service can hand out their public keys, and no one-time key is
     published twice.
  3. `rotate_all/2` replaces every published key after the consistency
     check fails (409 on `POST /v2/keys/check`, CRS-03 §9.4).
  4. `pre_key_lookup/1` and `apply_effects/2` serve the responder side of
     the session protocol (`SalixSignalProto.Session.decrypt_pre_key/5`):
     one-time keys are deleted after use; a last-resort KEM pre-key is kept,
     and each (KEM pre-key, signed pre-key, base key) combination that
     started a session is remembered so that a repeat is refused
     (CRS-03 §10.2).

  ## Policy

  CRS-03 §10.3 lists the policies of deployed clients. Peers do not enforce
  them. This store uses values inside those ranges:

  | Policy | Value |
  | --- | --- |
  | Upload one-time EC or KEM pre-keys when the service holds fewer than | 10 |
  | Batch size | 100 |
  | Rotate the signed EC and last-resort KEM pre-keys after | 2 days |
  | Delete a replaced signed or last-resort key | 30 days after it was replaced, but always keep the newest replaced key |
  | Delete local one-time keys | older than 90 days, but keep the newest 200 of each kind |
  | Key IDs | random start, +1, 1 to 0xFFFFFF |

  One-time and last-resort KEM pre-keys share one ID space, so the owner can
  tell the kind from the ID (CRS-03 §8).
  """

  alias SalixSignalProto.PreKeys
  alias SalixSignalProto.PreKeys.{KemPreKey, OneTimePreKey, SignedPreKey}

  @day_ms 86_400_000
  @refill_below 10
  @batch 100
  @rotate_after_ms 2 * @day_ms
  @replaced_retention_ms 30 * @day_ms
  @one_time_retention_ms 90 * @day_ms
  @one_time_keep 200

  @enforce_keys [
    :identity,
    :signed,
    :last_resort,
    :next_signed_id,
    :next_one_time_id,
    :next_kem_id
  ]
  defstruct identity: nil,
            signed: [],
            last_resort: [],
            one_time: %{},
            kem_one_time: %{},
            used_last_resort: MapSet.new(),
            next_signed_id: nil,
            next_one_time_id: nil,
            next_kem_id: nil,
            pending: nil

  @type t :: %__MODULE__{
          identity: PreKeys.identity(),
          signed: [SignedPreKey.t()],
          last_resort: [KemPreKey.t()],
          one_time: %{pos_integer() => OneTimePreKey.t()},
          kem_one_time: %{pos_integer() => KemPreKey.t()},
          used_last_resort: MapSet.t({pos_integer(), pos_integer(), binary()}),
          next_signed_id: pos_integer(),
          next_one_time_id: pos_integer(),
          next_kem_id: pos_integer(),
          pending: map() | nil
        }

  @type counts :: %{count: non_neg_integer(), kem_count: non_neg_integer()}

  @doc """
  A new store for `identity` (`%{public: 33 bytes, private: 32 bytes}`) with
  its first signed EC pre-key and last-resort KEM pre-key.
  """
  @spec new(PreKeys.identity(), integer()) :: t()
  def new(
        %{public: <<5, _::binary-size(32)>>, private: <<_::binary-size(32)>>} = identity,
        now_ms
      ) do
    %__MODULE__{
      identity: identity,
      signed: [],
      last_resort: [],
      next_signed_id: PreKeys.random_id(),
      next_one_time_id: PreKeys.random_id(),
      next_kem_id: PreKeys.random_id()
    }
    |> add_signed(now_ms)
    |> add_last_resort(now_ms)
  end

  @doc "The current signed EC pre-key."
  @spec current_signed(t()) :: SignedPreKey.t()
  def current_signed(%__MODULE__{signed: [current | _]}), do: current

  @doc "The current last-resort KEM pre-key."
  @spec current_last_resort(t()) :: KemPreKey.t()
  def current_last_resort(%__MODULE__{last_resort: [current | _]}), do: current

  @doc """
  The body of `POST /v2/keys/check` for the current keys (CRS-03 §9.4).
  `kind` is `:aci` or `:pni`.
  """
  @spec check_body(t(), PreKeys.identity_kind()) :: map()
  def check_body(%__MODULE__{} = store, kind) do
    digest =
      PreKeys.check_digest(
        store.identity.public,
        current_signed(store),
        current_last_resort(store)
      )

    PreKeys.check_body(kind, digest)
  end

  # --- Refresh and rotation ---

  @doc """
  Applies the policy at `now_ms`. `counts` are the service counts from
  `GET /v2/keys`, or `nil` to skip the refill check.

  Returns `{store, body}`: the new store and the `PUT /v2/keys` body, or
  `nil` when nothing needs uploading. Store the new store before the upload.
  Old keys are pruned in the same step.
  """
  @spec refresh(t(), counts() | nil, integer()) :: {t(), map() | nil}
  def refresh(%__MODULE__{pending: pending} = store, _counts, now_ms) when pending != nil do
    # The earlier upload of `pending` can have reached the service, and the
    # service can have handed out its one-time keys (CRS-03 §9.5, §10.1).
    # The retry therefore carries new one-time batches. The earlier batches
    # stay local, so peers that took keys from them can still start sessions.
    {store, parts} =
      {store, []}
      |> rotate_when(:pre_keys, Map.has_key?(pending, "preKeys"), now_ms)
      |> rotate_when(:kem_pre_keys, Map.has_key?(pending, "pqPreKeys"), now_ms)

    with_pending(prune(store, now_ms), Map.merge(pending, PreKeys.upload_body(parts)))
  end

  def refresh(%__MODULE__{} = store, counts, now_ms) do
    {store, parts} =
      {store, []}
      |> rotate_when(:signed_pre_key, stale?(current_signed(store), now_ms), now_ms)
      |> rotate_when(:last_resort_pre_key, stale?(current_last_resort(store), now_ms), now_ms)
      |> rotate_when(:pre_keys, counts != nil and counts.count < @refill_below, now_ms)
      |> rotate_when(:kem_pre_keys, counts != nil and counts.kem_count < @refill_below, now_ms)

    store = prune(store, now_ms)

    case parts do
      [] -> {store, nil}
      parts -> with_pending(store, PreKeys.upload_body(parts))
    end
  end

  @doc """
  Replaces every published key: a new signed EC pre-key, a new last-resort
  KEM pre-key and new one-time batches. Use it after `POST /v2/keys/check`
  answers 409 (CRS-03 §9.4). Returns `{store, body}` as `refresh/3` does.
  """
  @spec rotate_all(t(), integer()) :: {t(), map()}
  def rotate_all(%__MODULE__{} = store, now_ms) do
    {store, parts} =
      Enum.reduce(
        [:signed_pre_key, :last_resort_pre_key, :pre_keys, :kem_pre_keys],
        {store, []},
        &rotate_when(&2, &1, true, now_ms)
      )

    with_pending(prune(store, now_ms), PreKeys.upload_body(parts))
  end

  defp with_pending(store, body), do: {%{store | pending: body}, body}

  @doc "Records that the pending body reached the service."
  @spec uploaded(t()) :: t()
  def uploaded(%__MODULE__{} = store), do: %{store | pending: nil}

  defp stale?(%{created_ms: created_ms}, now_ms), do: now_ms - created_ms >= @rotate_after_ms

  defp rotate_when(acc, _part, false, _now_ms), do: acc

  defp rotate_when({store, parts}, :signed_pre_key, true, now_ms) do
    store = add_signed(store, now_ms)
    {store, [{:signed_pre_key, current_signed(store)} | parts]}
  end

  defp rotate_when({store, parts}, :last_resort_pre_key, true, now_ms) do
    store = add_last_resort(store, now_ms)
    {store, [{:last_resort_pre_key, current_last_resort(store)} | parts]}
  end

  defp rotate_when({store, parts}, :pre_keys, true, now_ms) do
    {ids, next} = take_ids(store.next_one_time_id, @batch, store.one_time)
    keys = Enum.map(ids, &PreKeys.one_time_pre_key(&1, now_ms))
    one_time = Map.merge(store.one_time, Map.new(keys, &{&1.id, &1}))
    {%{store | one_time: one_time, next_one_time_id: next}, [{:pre_keys, keys} | parts]}
  end

  defp rotate_when({store, parts}, :kem_pre_keys, true, now_ms) do
    {ids, next} = take_ids(store.next_kem_id, @batch, kem_ids(store))
    keys = Enum.map(ids, &PreKeys.kem_pre_key(store.identity, &1, false, now_ms))
    kem_one_time = Map.merge(store.kem_one_time, Map.new(keys, &{&1.id, &1}))
    {%{store | kem_one_time: kem_one_time, next_kem_id: next}, [{:kem_pre_keys, keys} | parts]}
  end

  defp add_signed(store, now_ms) do
    {[id], next} = take_ids(store.next_signed_id, 1, Map.new(store.signed, &{&1.id, &1}))
    key = PreKeys.signed_pre_key(store.identity, id, now_ms)
    %{store | signed: [key | store.signed], next_signed_id: next}
  end

  defp add_last_resort(store, now_ms) do
    {[id], next} = take_ids(store.next_kem_id, 1, kem_ids(store))
    key = PreKeys.kem_pre_key(store.identity, id, true, now_ms)
    %{store | last_resort: [key | store.last_resort], next_kem_id: next}
  end

  defp kem_ids(store), do: Map.merge(store.kem_one_time, Map.new(store.last_resort, &{&1.id, &1}))

  # Takes `n` IDs from `next`, skipping IDs still in use after a wrap.
  defp take_ids(next, n, in_use), do: take_ids(next, n, in_use, [])
  defp take_ids(next, 0, _in_use, acc), do: {Enum.reverse(acc), next}

  defp take_ids(next, n, in_use, acc) do
    if Map.has_key?(in_use, next),
      do: take_ids(PreKeys.next_id(next), n, in_use, acc),
      else: take_ids(PreKeys.next_id(next), n - 1, in_use, [next | acc])
  end

  # --- Pruning ---

  @doc """
  Deletes keys that the policy no longer keeps (see the module
  documentation). `refresh/3` and `rotate_all/2` call it.
  """
  @spec prune(t(), integer()) :: t()
  def prune(%__MODULE__{} = store, now_ms) do
    last_resort = prune_replaced(store.last_resort, now_ms)
    kept_last_resort = MapSet.new(last_resort, & &1.id)

    %{
      store
      | signed: prune_replaced(store.signed, now_ms),
        last_resort: last_resort,
        used_last_resort:
          MapSet.filter(store.used_last_resort, fn {id, _, _} -> id in kept_last_resort end),
        one_time: prune_one_time(store.one_time, now_ms),
        kem_one_time: prune_one_time(store.kem_one_time, now_ms)
    }
  end

  # Keys are newest first. A replaced key was replaced when its successor was
  # made. Keep the current key and the newest replaced key.
  defp prune_replaced([current | replaced], now_ms) do
    successors = [current | replaced]

    kept =
      replaced
      |> Enum.zip(successors)
      |> Enum.with_index()
      |> Enum.filter(fn {{_key, successor}, index} ->
        index == 0 or now_ms - successor.created_ms < @replaced_retention_ms
      end)
      |> Enum.map(fn {{key, _successor}, _index} -> key end)

    [current | kept]
  end

  defp prune_one_time(keys, _now_ms) when map_size(keys) <= @one_time_keep, do: keys

  defp prune_one_time(keys, now_ms) do
    {newest, older} =
      keys
      |> Map.values()
      |> Enum.sort_by(&{&1.created_ms, &1.id}, :desc)
      |> Enum.split(@one_time_keep)

    older
    |> Enum.filter(&(now_ms - &1.created_ms < @one_time_retention_ms))
    |> Enum.concat(newest)
    |> Map.new(&{&1.id, &1})
  end

  # --- Responder side (CRS-03 §10.2) ---

  @doc """
  The pre-key lookup that `SalixSignalProto.Session.decrypt_pre_key/5`
  takes.
  """
  @spec pre_key_lookup(t()) :: (tuple() -> {:ok, binary()} | :error | boolean())
  def pre_key_lookup(%__MODULE__{} = store) do
    fn
      {:signed_pre_key, id} -> find(store.signed, id, & &1.private)
      {:one_time_pre_key, id} -> fetch(store.one_time, id, & &1.private)
      {:kem_pre_key, id} -> kem_secret(store, id)
      {:kem_pre_key_used?, id, signed_id, base} -> {id, signed_id, base} in store.used_last_resort
    end
  end

  defp kem_secret(store, id) do
    case fetch(store.kem_one_time, id, & &1.secret) do
      {:ok, secret} -> {:ok, secret}
      :error -> find(store.last_resort, id, & &1.secret)
    end
  end

  defp find(keys, id, field) do
    case Enum.find(keys, &(&1.id == id)) do
      nil -> :error
      key -> {:ok, field.(key)}
    end
  end

  defp fetch(keys, id, field) do
    case Map.fetch(keys, id) do
      {:ok, key} -> {:ok, field.(key)}
      :error -> :error
    end
  end

  @doc """
  Applies the effects of a successful pre-key message decryption: deletes
  the used one-time EC pre-key and a used one-time KEM pre-key, and records
  the combination that used a last-resort KEM pre-key. Store the result in
  the same transaction as the new session record.
  """
  @spec apply_effects(t(), map()) :: t()
  def apply_effects(%__MODULE__{} = store, effects) do
    store =
      case Map.get(effects, :used_one_time_pre_key) do
        nil -> store
        id -> %{store | one_time: Map.delete(store.one_time, id)}
      end

    case Map.get(effects, :used_kem_pre_key) do
      nil ->
        store

      %{id: id, signed_pre_key_id: signed_id, base_key: base} ->
        if Map.has_key?(store.kem_one_time, id),
          do: %{store | kem_one_time: Map.delete(store.kem_one_time, id)},
          else: %{
            store
            | used_last_resort: MapSet.put(store.used_last_resort, {id, signed_id, base})
          }
    end
  end
end
