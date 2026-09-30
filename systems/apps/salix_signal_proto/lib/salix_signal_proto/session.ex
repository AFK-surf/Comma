defmodule SalixSignalProto.Session do
  @moduledoc """
  The 1:1 session protocol as deployed (CRS-04, CRS-04b): session start from
  a pre-key bundle, encryption, and decryption of double-ratchet (type 2)
  and pre-key (type 3) messages over a session record (Sesame, CRS-04 §8).

  Every function is pure. It takes the record for one remote address and
  returns the new record; the caller stores it. A decryption that does not
  succeed returns no record, and the caller keeps the old one (CRS-04 §8.7).
  Randomness is an option with a secure default, so tests and the oracle
  harness can inject it.

  ## Context

  Every call takes a context map:

  | Key | Value |
  | --- | --- |
  | `:identity` | `%{public: 33 bytes, private: 32 bytes}`, the local identity key pair |
  | `:registration_id` | the local registration ID of that identity |
  | `:local_address` | `SalixSignalProto.Address` of the local identity and device |
  | `:remote_address` | `SalixSignalProto.Address` of the peer device |
  | `:trusted?` | `(identity_key, :sending | :receiving) -> boolean`, the local trust policy (CRS-04 §8.6) |

  ## Outcomes

  Decryption errors are the outcome classes of CRS-04 §9: `:duplicate`,
  `:invalid`, `:untrusted_identity`, `:no_session` and `:missing_pre_key`.
  CRS-07 maps them to actions on the wire.
  """

  alias SalixSignalProto.Keys
  alias SalixSignalProto.PreKeyBundle
  alias SalixSignalProto.Session.Message
  alias SalixSignalProto.Session.PreKeyMessage
  alias SalixSignalProto.Session.Pqxdh
  alias SalixSignalProto.Session.Record
  alias SalixSignalProto.Session.State

  @type context :: %{
          required(:identity) => %{public: Keys.ec_public(), private: Keys.ec_private()},
          required(:registration_id) => non_neg_integer(),
          required(:local_address) => SalixSignalProto.Address.t(),
          required(:remote_address) => SalixSignalProto.Address.t(),
          required(:trusted?) => (Keys.ec_public(), :sending | :receiving -> boolean())
        }

  @typedoc """
  Effects of a successful decryption that the caller applies with the new
  record, in one transaction:

  * `identity_key`: the peer identity key to save for the address;
  * `used_one_time_pre_key`: the one-time EC pre-key ID to delete, or nil;
  * `used_kem_pre_key`: `%{id, signed_pre_key_id, base_key}` to record, or
    nil (CRS-03 §10.2).
  """
  @type effects :: %{
          identity_key: Keys.ec_public(),
          used_one_time_pre_key: non_neg_integer() | nil,
          used_kem_pre_key:
            %{
              id: non_neg_integer(),
              signed_pre_key_id: non_neg_integer(),
              base_key: Keys.ec_public()
            }
            | nil
        }

  @typedoc """
  Looks up the responder's pre-keys:

  * `{:signed_pre_key, id}` and `{:one_time_pre_key, id}` return
    `{:ok, private_key}` or `:error`;
  * `{:kem_pre_key, id}` returns `{:ok, serialized_secret_key}` or `:error`;
  * `{:kem_pre_key_used?, id, signed_pre_key_id, base_key}` returns true
    when a last-resort KEM pre-key already started a session with this
    combination (CRS-03 §10.2 item 3).
  """
  @type pre_keys :: (tuple() -> {:ok, binary()} | :error | boolean())

  @type decrypt_error ::
          :duplicate | :invalid | :untrusted_identity | :no_session | :missing_pre_key

  @doc """
  Starts a session from a pre-key bundle (CRS-04 §3, §8.2). The new session
  is pending and becomes current; the old current session becomes the newest
  previous session.

  Options: `:now_ms` (creation time, default now), `:ephemeral_private`,
  `:ratchet_private` and `:kem_random` (32 bytes each, default random), and
  `:pq_ratchet` (`:required` by default; `:disabled` makes an EC-only session
  that deployed peers reject).
  """
  @spec process_bundle(Record.t() | nil, PreKeyBundle.t(), context(), keyword()) ::
          {:ok, Record.t()}
          | {:error,
             :invalid_signature | :missing_kem_pre_key | :untrusted_identity | :invalid_key}
  def process_bundle(record, %PreKeyBundle{} = bundle, context, opts \\ []) do
    ephemeral = Keys.ec_keypair(Keyword.get_lazy(opts, :ephemeral_private, &random32/0))

    with :ok <- PreKeyBundle.verify(bundle),
         :ok <- trust(context, bundle.identity_key, :sending),
         {:ok, result, kem_ciphertext} <-
           Pqxdh.initiate(
             %{
               identity_private: context.identity.private,
               ephemeral_private: ephemeral.private,
               identity_key: bundle.identity_key,
               signed_pre_key: bundle.signed_pre_key,
               one_time_pre_key: bundle.one_time_pre_key,
               kem_pre_key: bundle.kem_pre_key
             },
             Keyword.get_lazy(opts, :kem_random, &random32/0)
           ),
         {:ok, state} <-
           State.initiator(%{
             result: result,
             local_identity: context.identity.public,
             remote_identity: bundle.identity_key,
             base_key: ephemeral.public,
             ratchet_private: Keyword.get_lazy(opts, :ratchet_private, &random32/0),
             signed_pre_key: bundle.signed_pre_key,
             pending: %{
               one_time_pre_key_id: bundle.one_time_pre_key && bundle.one_time_pre_key_id,
               signed_pre_key_id: bundle.signed_pre_key_id,
               kem_pre_key_id: bundle.kem_pre_key_id,
               kem_ciphertext: kem_ciphertext,
               created_at_ms: Keyword.get_lazy(opts, :now_ms, &now_ms/0)
             },
             local_registration_id: context.registration_id,
             remote_registration_id: bundle.registration_id,
             pq: Keyword.get(opts, :pq_ratchet, :required)
           }) do
      {:ok, Record.promote(record || Record.new(), state)}
    end
  end

  @doc """
  Encrypts with the current session (CRS-04 §8.5). Returns
  `{:ok, {type, message}, record}` with type 2 or 3.

  Options: `:now_ms` (default now) and `:pq_random` (64 bytes, default
  random).
  """
  @spec encrypt(Record.t() | nil, binary(), context(), keyword()) ::
          {:ok, {2 | 3, binary()}, Record.t()}
          | {:error, :no_session | :untrusted_identity | :invalid}
  def encrypt(record, plaintext, context, opts \\ [])

  def encrypt(%Record{current: %State{} = state} = record, plaintext, context, opts)
      when is_binary(plaintext) do
    with :ok <- not_expired(state, Keyword.get_lazy(opts, :now_ms, &now_ms/0)),
         :ok <- trust(context, state.remote_identity, :sending),
         {:ok, message, state} <-
           State.encrypt(
             state,
             plaintext,
             context.local_address,
             context.remote_address,
             Keyword.get_lazy(opts, :pq_random, fn -> :crypto.strong_rand_bytes(64) end)
           ) do
      {:ok, message, %{record | current: state}}
    end
  end

  def encrypt(_record, plaintext, _context, _opts) when is_binary(plaintext),
    do: {:error, :no_session}

  defp not_expired(state, now_ms),
    do: if(State.pending_expired?(state, now_ms), do: {:error, :no_session}, else: :ok)

  @doc """
  Decrypts a double-ratchet message (type 2) by the rules of CRS-04 §8.4:
  the current session first, then previous sessions newest first; the first
  that decrypts becomes current. A duplicate ends the search.

  Option: `:ratchet_private` (32 bytes, default random), the new sending
  ratchet key if the message starts a DH ratchet step.
  """
  @spec decrypt(Record.t() | nil, binary(), context(), keyword()) ::
          {:ok, binary(), Record.t(), effects()} | {:error, decrypt_error()}
  def decrypt(record, bytes, context, opts \\ [])

  def decrypt(nil, bytes, _context, _opts) when is_binary(bytes), do: {:error, :no_session}

  def decrypt(%Record{} = record, bytes, context, opts) when is_binary(bytes) do
    ratchet_private = Keyword.get_lazy(opts, :ratchet_private, &random32/0)

    with {:ok, message} <- decode(Message, bytes),
         {:ok, plaintext, position, state} <-
           first_success(Record.sessions(record), message, context, ratchet_private),
         :ok <- trust(context, state.remote_identity, :receiving) do
      {:ok, plaintext, Record.accept(record, position, state), effects(state.remote_identity)}
    end
  end

  defp first_success(sessions, message, context, ratchet_private) do
    sessions
    |> Enum.with_index()
    |> Enum.reduce_while({:error, :invalid}, fn {state, position}, acc ->
      case State.decrypt(
             state,
             message,
             context.remote_address,
             context.local_address,
             ratchet_private
           ) do
        {:ok, plaintext, state} -> {:halt, {:ok, plaintext, position, state}}
        {:error, :duplicate} -> {:halt, {:error, :duplicate}}
        {:error, _other} -> {:cont, acc}
      end
    end)
  end

  @doc """
  Decrypts a pre-key message (type 3) by the rules of CRS-04 §8.3: trust
  first, then an existing session with the same initiator ephemeral key, else
  a new session from PQXDH as responder. `pre_keys` looks up the responder's
  pre-keys (see `t:pre_keys/0`).

  Options: `:ratchet_private` (32 bytes, default random) and `:pq_ratchet`
  for a new session (`:required` by default).
  """
  @spec decrypt_pre_key(Record.t() | nil, binary(), context(), pre_keys(), keyword()) ::
          {:ok, binary(), Record.t(), effects()} | {:error, decrypt_error()}
  def decrypt_pre_key(record, bytes, context, pre_keys, opts \\ []) when is_binary(bytes) do
    record = record || Record.new()
    ratchet_private = Keyword.get_lazy(opts, :ratchet_private, &random32/0)

    with {:ok, message} <- decode(PreKeyMessage, bytes),
         :ok <- trust(context, message.identity_key, :receiving) do
      case find_session(record, message) do
        {:ok, position, state} ->
          decrypt_existing(record, position, state, message, context, ratchet_private)

        :none ->
          decrypt_new(record, message, context, pre_keys, ratchet_private, opts)
      end
    end
  end

  defp find_session(record, message) do
    record
    |> Record.sessions()
    |> Enum.with_index()
    |> Enum.find_value(:none, fn {state, position} ->
      if state.version == message.version and state.base_key == message.base_key,
        do: {:ok, position, state}
    end)
  end

  # CRS-04 §8.3 rule 2.
  defp decrypt_existing(record, position, state, message, context, ratchet_private) do
    with :ok <- same_identity(state, message),
         {:ok, plaintext, state} <-
           State.decrypt(
             state,
             message.message,
             context.remote_address,
             context.local_address,
             ratchet_private
           ) do
      {:ok, plaintext, Record.accept(record, position, state), effects(message.identity_key)}
    end
  end

  defp same_identity(%State{remote_identity: key}, %PreKeyMessage{identity_key: key}), do: :ok
  defp same_identity(_state, _message), do: {:error, :invalid}

  # CRS-04 §8.3 rule 3.
  defp decrypt_new(record, message, context, pre_keys, ratchet_private, opts) do
    with :ok <- new_session_version(message),
         :ok <- canonical_base_key(message),
         {:ok, keys} <- responder_keys(message, pre_keys),
         {:ok, result} <-
           Pqxdh.respond(%{
             identity_private: context.identity.private,
             signed_pre_key_private: keys.signed,
             one_time_pre_key_private: keys.one_time,
             kem_secret: keys.kem,
             identity_key: message.identity_key,
             base_key: message.base_key,
             kem_ciphertext: message.kem_ciphertext
           })
           |> invalid_on_error(),
         state =
           State.responder(%{
             result: result,
             local_identity: context.identity.public,
             remote_identity: message.identity_key,
             base_key: message.base_key,
             signed_pre_key_private: keys.signed,
             local_registration_id: context.registration_id,
             remote_registration_id: message.registration_id,
             pq: Keyword.get(opts, :pq_ratchet, :required)
           }),
         {:ok, plaintext, state} <-
           State.decrypt(
             state,
             message.message,
             context.remote_address,
             context.local_address,
             ratchet_private
           ) do
      effects = %{
        effects(message.identity_key)
        | used_one_time_pre_key: message.one_time_pre_key_id,
          used_kem_pre_key: %{
            id: message.kem_pre_key_id,
            signed_pre_key_id: message.signed_pre_key_id,
            base_key: message.base_key
          }
      }

      {:ok, plaintext, Record.promote(record, state), effects}
    end
  end

  # Only version 4 starts a session, with both KEM fields (CRS-04 §7.3).
  defp new_session_version(%PreKeyMessage{version: 4, kem_ciphertext: ciphertext})
       when is_binary(ciphertext),
       do: :ok

  defp new_session_version(_message), do: {:error, :invalid}

  defp canonical_base_key(message) do
    if Keys.canonical_public?(message.base_key), do: :ok, else: {:error, :invalid}
  end

  defp responder_keys(message, pre_keys) do
    with {:ok, signed} <- lookup(pre_keys, {:signed_pre_key, message.signed_pre_key_id}),
         {:ok, kem} <- lookup(pre_keys, {:kem_pre_key, message.kem_pre_key_id}),
         {:ok, one_time} <- optional_one_time(pre_keys, message.one_time_pre_key_id),
         :ok <- not_replayed(pre_keys, message) do
      {:ok, %{signed: signed, kem: kem, one_time: one_time}}
    end
  end

  # A last-resort KEM pre-key must not start a second session from the same
  # combination (CRS-03 §10.2 item 3).
  defp not_replayed(pre_keys, message) do
    request =
      {:kem_pre_key_used?, message.kem_pre_key_id, message.signed_pre_key_id, message.base_key}

    if pre_keys.(request) == true, do: {:error, :invalid}, else: :ok
  end

  defp optional_one_time(_pre_keys, nil), do: {:ok, nil}
  defp optional_one_time(pre_keys, id), do: lookup(pre_keys, {:one_time_pre_key, id})

  defp lookup(pre_keys, request) do
    case pre_keys.(request) do
      {:ok, key} when is_binary(key) -> {:ok, key}
      _ -> {:error, :missing_pre_key}
    end
  end

  defp invalid_on_error({:ok, _} = ok), do: ok
  defp invalid_on_error({:error, _}), do: {:error, :invalid}

  defp decode(module, bytes) do
    case module.decode(bytes) do
      {:ok, message} -> {:ok, message}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp trust(context, identity_key, direction) do
    if context.trusted?.(identity_key, direction), do: :ok, else: {:error, :untrusted_identity}
  end

  defp effects(identity_key),
    do: %{identity_key: identity_key, used_one_time_pre_key: nil, used_kem_pre_key: nil}

  defp random32, do: :crypto.strong_rand_bytes(32)
  defp now_ms, do: System.system_time(:millisecond)
end
