defmodule SalixSignalProto.Session.State do
  @moduledoc """
  One session state: the EC Double Ratchet as deployed (CRS-04 §3.6, §4,
  §5), plus the data of a pending pre-key session (§8.2).

  Every function is pure. A decryption returns a new state only when the
  message is accepted; with any other outcome the caller keeps the old state
  (CRS-04 §5.3, §8.7).

  ## Post-quantum ratchet

  Every deployed session runs the post-quantum ratchet
  (`SalixSignalProto.Session.Spqr`, CRS-04 §6, CRS-04b). Each message
  carries its post-quantum message in field 5, and the post-quantum key P is
  the HKDF salt of the message keys. A state whose `pq_ratchet` is nil runs
  the EC ratchet alone: its messages carry no field 5 and its message keys
  use no salt. Deployed peers neither send nor accept such messages; they
  exist for the EC-only vectors of CRS-04 §11.

  ## Limits

  | Limit | Value |
  | --- | --- |
  | Receiving chains per session | 5, oldest dropped first |
  | Stored skipped message-key seeds per chain | 2000, oldest dropped first |
  | Forward jump in a receiving chain | 25000 message numbers |
  | Sending on a pending session | 30 days after creation |

  CRS-04 §5.4 lifts the forward-jump limit for a session between devices of
  one account. Comma keeps the limit for those sessions too: Comma registers
  primary devices only (PLAN scope), and an unlimited jump is an unbounded
  number of chain steps for one received message.
  """

  alias SalixSignalProto.Address
  alias SalixSignalProto.Crypto.AesCbc
  alias SalixSignalProto.Keys
  alias SalixSignalProto.Session.Kdf
  alias SalixSignalProto.Session.Message
  alias SalixSignalProto.Session.PreKeyMessage
  alias SalixSignalProto.Session.Spqr

  @max_receiving_chains 5
  @max_stored_seeds 2000
  @max_forward_jump 25_000
  @pending_lifetime_ms 30 * 24 * 60 * 60 * 1000
  @version 4

  @enforce_keys [:local_identity, :remote_identity, :root_key, :sender, :base_key]
  defstruct version: @version,
            local_identity: nil,
            remote_identity: nil,
            root_key: nil,
            sender: nil,
            receivers: [],
            previous_chain_length: 0,
            pending: nil,
            local_registration_id: 0,
            remote_registration_id: 0,
            base_key: nil,
            pq_ratchet: nil

  @typedoc "The sending chain."
  @type sender :: %{
          private: Keys.ec_private(),
          public: Keys.ec_public(),
          chain_key: <<_::256>>,
          index: non_neg_integer()
        }

  @typedoc "A receiving chain. `seeds` holds stored skipped seeds, newest first."
  @type receiver :: %{
          public: Keys.ec_public(),
          chain_key: <<_::256>>,
          index: non_neg_integer(),
          seeds: [{non_neg_integer(), <<_::256>>}]
        }

  @typedoc "Data that every message on a pending session repeats (CRS-04 §8.2)."
  @type pending :: %{
          one_time_pre_key_id: non_neg_integer() | nil,
          signed_pre_key_id: non_neg_integer(),
          kem_pre_key_id: non_neg_integer(),
          kem_ciphertext: Keys.kem_ciphertext(),
          created_at_ms: integer()
        }

  @type pq_ratchet :: Spqr.t() | nil

  @type t :: %__MODULE__{
          version: 4,
          local_identity: Keys.ec_public(),
          remote_identity: Keys.ec_public(),
          root_key: <<_::256>>,
          sender: sender(),
          receivers: [receiver()],
          previous_chain_length: non_neg_integer(),
          pending: pending() | nil,
          local_registration_id: non_neg_integer(),
          remote_registration_id: non_neg_integer(),
          base_key: Keys.ec_public(),
          pq_ratchet: pq_ratchet()
        }

  @type decrypt_error :: :duplicate | :invalid

  @doc false
  def pending_lifetime_ms, do: @pending_lifetime_ms

  @doc """
  The initiator state right after PQXDH (CRS-04 §3.6). `params` holds the
  PQXDH `result`, `local_identity`, `remote_identity`, `base_key`,
  `ratchet_private` (the first sending ratchet key), `signed_pre_key` (the
  responder's, which is its first ratchet key), `pending`,
  `local_registration_id`, `remote_registration_id` and `pq` (`:required`
  or `:disabled`).
  """
  @spec initiator(map()) :: {:ok, t()} | {:error, :invalid_key}
  def initiator(params) do
    ratchet = Keys.ec_keypair(params.ratchet_private)

    with {:ok, {root_key, sending_chain_key}} <-
           Kdf.root_step(params.result.root_key, ratchet.private, params.signed_pre_key) do
      {:ok,
       %__MODULE__{
         local_identity: params.local_identity,
         remote_identity: params.remote_identity,
         root_key: root_key,
         sender: sender(ratchet, sending_chain_key),
         receivers: [receiver(params.signed_pre_key, params.result.chain_key)],
         pending: params.pending,
         local_registration_id: params.local_registration_id,
         remote_registration_id: params.remote_registration_id,
         base_key: params.base_key,
         pq_ratchet: pq_ratchet(params.pq, :initiator, params.result.pq_secret)
       }}
    end
  end

  @doc """
  The responder state when it accepts the first pre-key message (CRS-04
  §3.6): the signed pre-key is the first sending ratchet key, with the first
  chain key and no receiving chain.
  """
  @spec responder(map()) :: t()
  def responder(params) do
    %__MODULE__{
      local_identity: params.local_identity,
      remote_identity: params.remote_identity,
      root_key: params.result.root_key,
      sender: sender(Keys.ec_keypair(params.signed_pre_key_private), params.result.chain_key),
      local_registration_id: params.local_registration_id,
      remote_registration_id: params.remote_registration_id,
      base_key: params.base_key,
      pq_ratchet: pq_ratchet(params.pq, :responder, params.result.pq_secret)
    }
  end

  defp pq_ratchet(:disabled, _role, _secret), do: nil
  defp pq_ratchet(:required, role, secret), do: Spqr.new(role, secret)

  defp sender(%{private: private, public: public}, chain_key),
    do: %{private: private, public: public, chain_key: chain_key, index: 0}

  defp receiver(public, chain_key),
    do: %{public: public, chain_key: chain_key, index: 0, seeds: []}

  @doc """
  True when the session is pending and older than 30 days at `now_ms`, so it
  must not be used for sending (CRS-04 §8.2 item 4).
  """
  @spec pending_expired?(t(), integer()) :: boolean()
  def pending_expired?(%__MODULE__{pending: nil}, _now_ms), do: false

  def pending_expired?(%__MODULE__{pending: %{created_at_ms: created}}, now_ms),
    do: now_ms - created > @pending_lifetime_ms

  @doc """
  Encrypts `plaintext` on the sending chain (CRS-04 §5.1). A pending session
  wraps the message in a pre-key message (type 3); otherwise the result is a
  double-ratchet message (type 2). The address binding goes into the message
  inside a pre-key message when both addresses are service IDs (§7.4).
  `pq_random` is 64 fresh random bytes for the post-quantum ratchet
  (`SalixSignalProto.Session.Spqr.send/2`).
  """
  @spec encrypt(t(), binary(), Address.t(), Address.t(), <<_::512>>) ::
          {:ok, {2 | 3, binary()}, t()} | {:error, :invalid}
  def encrypt(%__MODULE__{} = state, plaintext, local_address, remote_address, pq_random)
      when is_binary(plaintext) do
    with {:ok, pq_message, pq_key, state} <- pq_send(state, pq_random) do
      sender = state.sender
      keys = sender.chain_key |> Kdf.seed() |> Kdf.message_keys(pq_key)
      binding = if state.pending, do: Address.binding(local_address, remote_address)

      inner =
        Message.encode(
          %{
            version: state.version,
            ratchet_key: sender.public,
            message_number: sender.index,
            previous_chain_length: state.previous_chain_length,
            body: AesCbc.encrypt(keys.cipher_key, keys.iv, plaintext),
            pq_message: pq_message,
            address_binding: binding
          },
          keys.mac_key,
          state.local_identity,
          state.remote_identity
        )

      state = %{
        state
        | sender: %{sender | chain_key: Kdf.next(sender.chain_key), index: sender.index + 1}
      }

      {:ok, wrap(state, inner), state}
    end
  end

  defp wrap(%__MODULE__{pending: nil}, inner), do: {2, inner}

  defp wrap(%__MODULE__{pending: pending} = state, inner) do
    {3,
     PreKeyMessage.encode(%{
       version: state.version,
       one_time_pre_key_id: pending.one_time_pre_key_id,
       base_key: state.base_key,
       identity_key: state.local_identity,
       message: inner,
       registration_id: state.local_registration_id,
       signed_pre_key_id: pending.signed_pre_key_id,
       kem_pre_key_id: pending.kem_pre_key_id,
       kem_ciphertext: pending.kem_ciphertext
     })}
  end

  @doc """
  Decrypts a double-ratchet message with this state (CRS-04 §5.3).
  `sender_address` is the address the receiver believes sent the message and
  `local_address` its own; both check the address binding (§7.4).
  `ratchet_private` is the 32-byte private key of the new sending ratchet
  key, used only when the message starts a DH ratchet step.

  Returns `{:ok, plaintext, state}` with the pending state cleared (§8.2
  item 3), or `{:error, :duplicate | :invalid}`.
  """
  @spec decrypt(t(), Message.t(), Address.t(), Address.t(), <<_::256>>) ::
          {:ok, binary(), t()} | {:error, decrypt_error()}
  def decrypt(
        %__MODULE__{} = state,
        %Message{} = message,
        sender_address,
        local_address,
        ratchet_private
      ) do
    with :ok <- same_version(state, message),
         {:ok, state, position} <- receiving_chain(state, message.ratchet_key, ratchet_private),
         {:ok, seed, state} <- message_seed(state, position, message.message_number),
         {:ok, pq_key, state} <- pq_receive(state, message.pq_message),
         keys = Kdf.message_keys(seed, pq_key),
         :ok <- check_mac(message, keys.mac_key, state),
         :ok <- check_binding(message.address_binding, sender_address, local_address),
         {:ok, plaintext} <- decrypt_body(keys, message.body) do
      {:ok, plaintext, %{state | pending: nil}}
    end
  end

  defp same_version(%__MODULE__{version: version}, %Message{version: version}), do: :ok
  defp same_version(_state, _message), do: {:error, :invalid}

  defp receiving_chain(state, their_key, ratchet_private) do
    case Enum.find_index(state.receivers, &(&1.public == their_key)) do
      nil -> ratchet_step(state, their_key, ratchet_private)
      position -> {:ok, state, position}
    end
  end

  # DH ratchet step on receipt of a new ratchet key (CRS-04 §5.3).
  defp ratchet_step(state, their_key, ratchet_private) do
    ours = Keys.ec_keypair(ratchet_private)

    with {:ok, {root_key, receiving_chain_key}} <-
           Kdf.root_step(state.root_key, state.sender.private, their_key),
         {:ok, {root_key, sending_chain_key}} <- Kdf.root_step(root_key, ours.private, their_key) do
      receivers =
        (state.receivers ++ [receiver(their_key, receiving_chain_key)])
        |> Enum.take(-@max_receiving_chains)

      state = %{
        state
        | root_key: root_key,
          receivers: receivers,
          sender: sender(ours, sending_chain_key),
          previous_chain_length: max(state.sender.index - 1, 0)
      }

      {:ok, state, length(receivers) - 1}
    else
      {:error, _} -> {:error, :invalid}
    end
  end

  defp message_seed(state, position, number) do
    chain = Enum.at(state.receivers, position)

    cond do
      number < chain.index ->
        case List.keytake(chain.seeds, number, 0) do
          {{^number, seed}, seeds} ->
            {:ok, seed, put_chain(state, position, %{chain | seeds: seeds})}

          nil ->
            {:error, :duplicate}
        end

      number - chain.index > @max_forward_jump ->
        {:error, :invalid}

      true ->
        {seeds, chain_key} =
          skip(chain.chain_key, chain.index, number, number - @max_stored_seeds, chain.seeds)

        chain = %{
          chain
          | chain_key: Kdf.next(chain_key),
            index: number + 1,
            seeds: Enum.take(seeds, @max_stored_seeds)
        }

        {:ok, Kdf.seed(chain_key), put_chain(state, position, chain)}
    end
  end

  # Walks the chain from index `from` to `to` and returns the chain key at
  # `to`. It stores the seeds for indices from..to-1, newest first, but only
  # for indices at or above `keep_from`: the chain keeps only the newest 2000
  # seeds, so an older seed would be dropped at once. Not computing it keeps
  # the cost of a long jump, which a forged message can ask for, near one
  # HMAC per skipped index.
  defp skip(chain_key, from, to, _keep_from, seeds) when from == to, do: {seeds, chain_key}

  defp skip(chain_key, from, to, keep_from, seeds) when from < keep_from,
    do: skip(Kdf.next(chain_key), from + 1, to, keep_from, seeds)

  defp skip(chain_key, from, to, keep_from, seeds),
    do: skip(Kdf.next(chain_key), from + 1, to, keep_from, [{from, Kdf.seed(chain_key)} | seeds])

  defp put_chain(state, position, chain),
    do: %{state | receivers: List.replace_at(state.receivers, position, chain)}

  defp pq_send(%__MODULE__{pq_ratchet: nil} = state, _random), do: {:ok, nil, nil, state}

  defp pq_send(%__MODULE__{pq_ratchet: pq} = state, random) do
    with {:ok, pq_message, pq_key, pq} <- Spqr.send(pq, random),
         do: {:ok, pq_message, pq_key, %{state | pq_ratchet: pq}}
  end

  # A session with the post-quantum ratchet requires a valid field 5
  # (CRS-04 §6, CRS-04b §10.2).
  defp pq_receive(%__MODULE__{pq_ratchet: nil} = state, _pq_message), do: {:ok, nil, state}

  defp pq_receive(%__MODULE__{pq_ratchet: pq} = state, pq_message) do
    with {:ok, pq_key, pq} <- Spqr.receive(pq, pq_message),
         do: {:ok, pq_key, %{state | pq_ratchet: pq}}
  end

  defp check_mac(message, mac_key, state) do
    if Message.valid_mac?(message, mac_key, state.remote_identity, state.local_identity),
      do: :ok,
      else: {:error, :invalid}
  end

  defp check_binding(nil, _sender_address, _local_address), do: :ok

  defp check_binding(binding, sender_address, local_address) do
    if Address.binding(sender_address, local_address) == binding,
      do: :ok,
      else: {:error, :invalid}
  end

  defp decrypt_body(keys, body) do
    case AesCbc.decrypt(keys.cipher_key, keys.iv, body) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _} -> {:error, :invalid}
    end
  end
end
