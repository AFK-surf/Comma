defmodule Salix.Control.GroupApiKeys do
  @moduledoc """
  Agent group inbound API keys (docs/product-features.md).

  A key belongs to one agent group and does exactly one thing: it lets an
  external service `POST` a message to that group's Router through
  `Salix.App.RouterInbox`. It is a group control-plane fact, so it lives here
  with the other `Salix.Control.*` owners rather than with IM connects or
  agent records.

  The plaintext is returned once, from `create/4`, and never stored: Postgres
  keeps the SHA-256 (`SalixStore.GroupApiKeys`), which is what `validate/1`
  looks up. Store faults read as `:unavailable`, never as `:unauthorized` — a
  cold node must not tell a caller its key is invalid.

  A key has a `kind` (docs/messaging-voice.md): `inbound` keys (`salix_gk_`)
  open the Router post-message API and Loop events; `voice` keys
  (`salix_vk_`) open only voice readiness and voice sessions. The prefix
  selects the kind before the hash lookup, and the stored kind must match.
  Every management function takes the kind as its last argument; the shorter
  arities mean `inbound`. A Router never mints a voice key: the actor
  `agent:<id>` is refused for that kind, because a voice key is a durable,
  billable credential. Disabling, deleting or re-expiring a voice key
  notifies the live calls on it through the `:pg` group `{:voice_key, key_id}`
  in `SalixVoice.PG`.
  """

  alias Salix.Control.{Groups, Store}
  alias SalixStore.GroupApiKeys, as: KeyStore

  require Logger

  @key_prefix "salix_gk_"
  @voice_key_prefix "salix_vk_"
  @kinds ~w(inbound voice)
  @voice_pg SalixVoice.PG
  @prefix_visible_chars 15
  @max_keys_per_group 20
  @max_name_chars 80
  @statuses ~w(active disabled)
  @touch_interval_s 60
  @create_retries 3

  @type key_record :: map()

  @doc "The literal every plaintext key of `kind` starts with."
  @spec key_prefix(String.t()) :: String.t()
  def key_prefix(kind \\ "inbound")
  def key_prefix("voice"), do: @voice_key_prefix
  def key_prefix(_inbound), do: @key_prefix

  @doc "The key kinds."
  def kinds, do: @kinds

  @doc "How many keys one group may hold."
  @spec max_keys_per_group() :: pos_integer()
  def max_keys_per_group, do: @max_keys_per_group

  @doc "A group's keys of `kind`, newest first. `key_hash` is never in the projection."
  @spec list(String.t(), String.t(), String.t()) ::
          {:ok, [key_record()]} | {:error, :not_found | :unavailable | {:bad_request, String.t()}}
  def list(group_id, tenant_id, kind \\ "inbound") do
    with :ok <- validate_kind(kind),
         {:ok, _group} <- Groups.get(group_id, tenant_id) do
      {:ok, group_id |> KeyStore.list_by_group(kind) |> Enum.map(&public/1)}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc """
  Mints a key. The result carries the plaintext under `"key"`, once.

  `actor` names who created it: `"comma_user:<id>"`, `"salix_admin"`,
  `"tenant_api"` or `"agent:<agent_id>"`. A key acts with its creator's
  authority under information-flow checking (§5.7), so the actor is a stored
  fact, not a log line.
  """
  @spec create(String.t(), String.t(), map(), String.t(), String.t()) ::
          {:ok, key_record()} | {:error, term()}
  def create(group_id, tenant_id, attrs, actor, kind \\ "inbound")

  def create(group_id, tenant_id, attrs, actor, kind) when is_map(attrs) and is_binary(actor) do
    with :ok <- validate_kind(kind),
         {:ok, _group} <- Groups.get(group_id, tenant_id),
         {:ok, name} <- validate_name(Map.get(attrs, "name"), required: true),
         {:ok, expires_at} <- validate_expires_at(Map.get(attrs, "expires_at")),
         :ok <- validate_actor(actor, kind) do
      insert_with_retries(group_id, tenant_id, name, expires_at, actor, kind, @create_retries)
    end
  rescue
    _exception -> {:error, {:unavailable, "group api key store unavailable"}}
  end

  def create(_group_id, _tenant_id, _attrs, _actor, _kind),
    do: {:error, {:bad_request, "invalid request body"}}

  @doc """
  Renames, disables/enables, or re-expires one key of `kind`. Disabling a
  voice key ends its live calls; a new expiry of a voice key replaces the
  expiry timer of its live calls.
  """
  @spec update(String.t(), String.t(), String.t(), map(), String.t()) ::
          {:ok, key_record()} | {:error, term()}
  def update(group_id, tenant_id, key_id, attrs, kind \\ "inbound")

  def update(group_id, tenant_id, key_id, attrs, kind) when is_map(attrs) do
    with :ok <- validate_kind(kind),
         {:ok, _group} <- Groups.get(group_id, tenant_id),
         {:ok, changes} <- validate_changes(attrs),
         {:ok, record} <- KeyStore.update(group_id, key_id, changes, kind) do
      cond do
        record["kind"] != "voice" -> :ok
        record["status"] != "active" -> revoke_voice_key(record["key_id"])
        Map.has_key?(changes, "expires_at") -> notify_voice_key_expiry(record)
        true -> :ok
      end

      {:ok, public(record)}
    end
  rescue
    _exception -> {:error, {:unavailable, "group api key store unavailable"}}
  end

  def update(_group_id, _tenant_id, _key_id, _attrs, _kind),
    do: {:error, {:bad_request, "invalid request body"}}

  @doc """
  Removes one key of `kind`. Idempotent: a key that is already gone is `:ok`.
  Deleting a voice key ends its live calls.
  """
  @spec delete(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(group_id, tenant_id, key_id, kind \\ "inbound")

  def delete(group_id, tenant_id, key_id, kind) when is_binary(key_id) do
    with :ok <- validate_kind(kind),
         {:ok, _group} <- Groups.get(group_id, tenant_id),
         :ok <- KeyStore.delete(group_id, key_id, kind) do
      if kind == "voice", do: revoke_voice_key(key_id)
      :ok
    end
  rescue
    _exception -> {:error, {:unavailable, "group api key store unavailable"}}
  end

  def delete(_group_id, _tenant_id, _key_id, _kind),
    do: {:error, {:bad_request, "invalid key_id"}}

  # Revocation and expiry changes reach live calls through `:pg`; there is no
  # polling. A node without the voice application has no calls to notify. A
  # deleted Group ends its calls through `SalixVoice.revoke_group/1`; its key
  # rows stay, and `validate/1` already refuses a key whose Group is gone.
  defp revoke_voice_key(key_id) when is_binary(key_id),
    do: notify_voice_key(key_id, {:voice_key_revoked, key_id})

  defp notify_voice_key_expiry(%{"key_id" => key_id} = record) do
    expires_at_ms = if is_integer(record["expires_at"]), do: record["expires_at"] * 1000
    notify_voice_key(key_id, {:voice_key_expiry, key_id, expires_at_ms})
  end

  defp notify_voice_key(key_id, message) do
    if Process.whereis(@voice_pg) do
      for pid <- :pg.get_members(@voice_pg, {:voice_key, key_id}), do: send(pid, message)
    end

    :ok
  end

  @doc """
  The current record of a voice key that is still usable: active, not
  expired, and of a live Group. A voice session reads it again after its call
  joined `{:voice_key, key_id}`, so a change made between the upgrade and the
  admission is not missed. A store fault reads as `:unavailable`.
  """
  @spec current_voice_key(String.t(), String.t(), String.t()) ::
          {:ok, key_record()} | {:error, :unauthorized | :unavailable}
  def current_voice_key(group_id, tenant_id, key_id) do
    case KeyStore.get(group_id, key_id, "voice") do
      {:ok, %{"tenant_id" => ^tenant_id} = record} ->
        cond do
          record["status"] != "active" or expired?(record) ->
            {:error, :unauthorized}

          true ->
            case Groups.get(group_id, tenant_id) do
              {:ok, _group} -> {:ok, public(record)}
              {:error, :not_found} -> {:error, :unauthorized}
              {:error, _fault} -> {:error, :unavailable}
            end
        end

      _other ->
        {:error, :unauthorized}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc """
  Resolves a presented plaintext key to its record.

  Disabled, expired, or belonging to a group that no longer exists all read as
  `:unauthorized`. A store fault reads as `:unavailable` so the HTTP layer can
  answer 503 instead of 401.
  """
  @spec validate(term()) :: {:ok, key_record()} | {:error, :unauthorized | :unavailable}
  def validate(@key_prefix <> _ = raw_key) when byte_size(raw_key) <= 128,
    do: validate_kind_key(raw_key, "inbound")

  def validate(@voice_key_prefix <> _ = raw_key) when byte_size(raw_key) <= 128,
    do: validate_kind_key(raw_key, "voice")

  def validate(_raw_key), do: {:error, :unauthorized}

  defp validate_kind_key(raw_key, kind) do
    case KeyStore.get_by_hash(hash(raw_key)) do
      {:ok, %{"group_id" => group_id, "tenant_id" => tenant_id} = record} ->
        cond do
          record["kind"] != kind ->
            {:error, :unauthorized}

          record["status"] != "active" ->
            {:error, :unauthorized}

          expired?(record) ->
            {:error, :unauthorized}

          true ->
            # The group record lives in S3: "gone" is unauthorized, exactly as
            # the tenant key path reads it, and a transport fault is unavailable.
            case Groups.get(group_id, tenant_id) do
              {:ok, _group} -> {:ok, record}
              {:error, :not_found} -> {:error, :unauthorized}
              {:error, _fault} -> {:error, :unavailable}
            end
        end

      {:error, :not_found} ->
        {:error, :unauthorized}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc "Records a use, at most once per minute per key. A failure is silent."
  @spec touch_last_used(String.t()) :: :ok
  def touch_last_used(key_id) when is_binary(key_id) do
    KeyStore.touch_last_used(key_id, @touch_interval_s)
  rescue
    exception ->
      Logger.debug("group api key last_used write skipped: #{Exception.message(exception)}")
      :ok
  end

  def touch_last_used(_key_id), do: :ok

  @doc """
  The information-flow principal a key's messages act as: the key wrapped
  around its creator, `{:api_key, key_id, creator}` (§5.7), in wire form.

  A key made from the Comma app carries that user's authority. A key made from
  the Salix dashboard, the tenant API, or a Router carries `system`, which
  holds no membership anywhere by default — the fail-closed reading for a key
  nobody in the workspace personally vouches for.

  A Router mints keys for the external systems it wires up to itself
  (`inbound_api.create`), so its keys are deliberately the weakest of the
  four: were an agent-made key to carry the agent's own authority, a Router
  could mint itself a principal that reads what the Router reads, and a
  prompt injection would be one `inbound_api.create` call away from a
  durable credential. `system` keeps the key's reach at or below the reach
  of the agent that made it.
  """
  @spec principal(key_record()) :: String.t() | nil
  def principal(%{"key_id" => key_id} = record) when is_binary(key_id) do
    creator =
      case record["created_by"] do
        "comma_user:" <> user_id when user_id != "" -> {:comma_user, user_id}
        "agent:" <> agent_id when agent_id != "" -> :system
        _admin_or_tenant -> :system
      end

    case SalixIFC.Codec.encode_principal({:api_key, key_id, creator}) do
      {:ok, encoded} -> encoded
      :error -> nil
    end
  end

  def principal(_record), do: nil

  @doc "The projection every reader sees: everything but the hash."
  @spec public(key_record()) :: key_record()
  def public(record) when is_map(record), do: Map.delete(record, "key_hash")

  # ---- internal ----

  defp insert_with_retries(_group_id, _tenant_id, _name, _expires_at, _actor, _kind, 0),
    do: {:error, {:unavailable, "could not allocate a unique key"}}

  defp insert_with_retries(group_id, tenant_id, name, expires_at, actor, kind, retries) do
    raw = key_prefix(kind) <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = Store.now()

    record = %{
      "key_hash" => hash(raw),
      "key_id" => "gak_" <> Store.random_id(),
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "name" => name,
      "prefix" => String.slice(raw, 0, @prefix_visible_chars),
      "status" => "active",
      "kind" => kind,
      "created_by" => actor,
      "created_at" => now,
      "updated_at" => now,
      "expires_at" => expires_at,
      "last_used_at" => nil
    }

    case KeyStore.insert(record, @max_keys_per_group) do
      {:ok, landed} ->
        {:ok, landed |> public() |> Map.put("key", raw)}

      {:error, :limit_reached} ->
        {:error, {:conflict, "a group may hold at most #{@max_keys_per_group} #{kind} API keys"}}

      {:error, :exists} ->
        insert_with_retries(group_id, tenant_id, name, expires_at, actor, kind, retries - 1)
    end
  end

  defp validate_changes(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {"name", value}, {:ok, acc} ->
        case validate_name(value, required: true) do
          {:ok, name} -> {:cont, {:ok, Map.put(acc, "name", name)}}
          error -> {:halt, error}
        end

      {"status", value}, {:ok, acc} ->
        if value in @statuses,
          do: {:cont, {:ok, Map.put(acc, "status", value)}},
          else:
            {:halt,
             {:error, {:bad_request, "status must be one of: #{Enum.join(@statuses, ", ")}"}}}

      {"expires_at", value}, {:ok, acc} ->
        case validate_expires_at(value) do
          {:ok, expires_at} -> {:cont, {:ok, Map.put(acc, "expires_at", expires_at)}}
          error -> {:halt, error}
        end

      {key, _value}, _acc ->
        {:halt, {:error, {:bad_request, "unsupported field: #{key}"}}}
    end)
    |> case do
      {:ok, changes} when map_size(changes) == 0 ->
        {:error, {:bad_request, "nothing to update"}}

      other ->
        other
    end
  end

  defp validate_name(value, required: required?) do
    name = if is_binary(value), do: String.trim(value), else: ""

    cond do
      name == "" and required? ->
        {:error, {:bad_request, "name is required"}}

      String.length(name) > @max_name_chars ->
        {:error, {:bad_request, "name must be at most #{@max_name_chars} characters"}}

      true ->
        {:ok, name}
    end
  end

  # `nil` clears the expiry. An epoch (seconds) or an ISO 8601 instant sets it;
  # either must be in the future, or the key would be born dead.
  defp validate_expires_at(nil), do: {:ok, nil}
  defp validate_expires_at(""), do: {:ok, nil}

  defp validate_expires_at(value) when is_integer(value) do
    if value > Store.now(),
      do: {:ok, value},
      else: {:error, {:bad_request, "expires_at must be in the future"}}
  end

  defp validate_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> validate_expires_at(DateTime.to_unix(dt, :second))
      _invalid -> {:error, {:bad_request, "expires_at must be an ISO 8601 instant"}}
    end
  end

  defp validate_expires_at(_value),
    do: {:error, {:bad_request, "expires_at must be an ISO 8601 instant"}}

  defp validate_kind(kind) when kind in @kinds, do: :ok
  defp validate_kind(_kind), do: {:error, {:bad_request, "kind must be inbound or voice"}}

  # A Router must not mint a voice key: a prompt injection would otherwise
  # yield a durable, billable voice credential.
  defp validate_actor("agent:" <> _id, "voice"),
    do: {:error, {:bad_request, "an agent may not create voice API keys"}}

  defp validate_actor(actor, _kind), do: validate_actor(actor)

  defp validate_actor("comma_user:" <> id) when id != "", do: :ok
  defp validate_actor("agent:" <> id) when id != "", do: :ok
  defp validate_actor(actor) when actor in ["salix_admin", "tenant_api"], do: :ok
  defp validate_actor(_actor), do: {:error, {:bad_request, "invalid actor"}}

  defp expired?(%{"expires_at" => expires_at}) when is_integer(expires_at),
    do: expires_at <= Store.now()

  defp expired?(_record), do: false

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
