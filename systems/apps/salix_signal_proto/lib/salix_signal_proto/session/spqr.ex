defmodule SalixSignalProto.Session.Spqr do
  @moduledoc """
  The sparse post-quantum ratchet as deployed (CRS-04b): a key agreement in
  epochs over ML-KEM-768, an authenticator, and symmetric chains that give
  one 32-byte post-quantum message key P for each message. P is the HKDF salt
  of the message keys (CRS-04 §4.3).

  Every function is pure. `send/2` and `receive/2` return the new state; the
  session keeps it only when the whole message is accepted (CRS-04b §10.2).

  ## Key agreement states (CRS-04b §9)

  | State | Role | Meaning |
  | --- | --- | --- |
  | `:o1` | key owner | no key pair yet |
  | `:o2` | key owner | sending header chunks |
  | `:o3` | key owner | ciphertext 1 arriving; sending key-part chunks |
  | `:o4` | key owner | ciphertext 1 complete; sending key-part chunks with acknowledgement |
  | `:o5` | key owner | ciphertext 2 arriving |
  | `:n1` | encapsulator | header arriving |
  | `:n2` | encapsulator | header complete and verified |
  | `:n3` | encapsulator | sending ciphertext-1 chunks; key part arriving |
  | `:n4` | encapsulator | key part complete; sending ciphertext-1 chunks |
  | `:n5` | encapsulator | ciphertext 1 acknowledged; key part arriving |
  | `:n6` | encapsulator | sending ciphertext-2 chunks |

  ## Limits

  Chunk indices on the wire wrap modulo 65536 for every payload
  (CRS-04b §5.3), so a one-way stream never sends an index that receivers
  reject.

  A receiving chain accepts an index at most 25000 above the highest index
  used, and keeps skipped keys for 2000 indices. CRS-04 §5.4 lifts the
  forward limit for sessions between devices of one account; Comma keeps it
  (see `SalixSignalProto.Session.State`).
  """

  alias SalixSignalProto.Crypto.Hkdf
  alias SalixSignalProto.Crypto.Hmac
  alias SalixSignalProto.Crypto.MlKem768
  alias SalixSignalProto.Session.Spqr.ErasureCode
  alias SalixSignalProto.Session.Spqr.Message

  @auth_update "Signal_PQCKA_V1_MLKEM768:Authenticator Update"
  @header_mac "Signal_PQCKA_V1_MLKEM768:ekheader"
  @ciphertext_mac "Signal_PQCKA_V1_MLKEM768:ciphertext"
  @scka_key "Signal_PQCKA_V1_MLKEM768:SCKA Key"
  @chain_start "Signal PQ Ratchet V1 Chain  Start"
  @chain_add "Signal PQ Ratchet V1 Chain Add Epoch"
  @chain_next "Signal PQ Ratchet V1 Chain Next"

  @header_bytes 96
  @key_part_bytes 1152
  @ciphertext1_bytes 960
  @ciphertext2_bytes 160
  @max_forward_jump 25_000
  @window 2000
  @chunk_numbers 65_536

  defstruct role: nil,
            negotiating: true,
            epoch: 1,
            agreement: %{name: :o1},
            auth: nil,
            chains: %{},
            top_chain_epoch: 0,
            next_root: nil,
            last_send_chain_epoch: nil

  @type role :: :initiator | :responder
  @type t :: %__MODULE__{}

  @doc """
  Starts the ratchet from the start secret PQA (CRS-04b §6, §7.1, §9.1):
  the initiator is key owner of epoch 1, the responder is encapsulator.
  """
  @spec new(role(), <<_::256>>) :: t()
  def new(role, <<_::binary-size(32)>> = start_secret) when role in [:initiator, :responder] do
    {next_root, i2r, r2i} = chain_start(start_secret)

    %__MODULE__{
      role: role,
      agreement: if(role == :initiator, do: %{name: :o1}, else: %{name: :n1, chunks: %{}}),
      auth: auth_update(%{root: <<0::256>>, mac: nil}, 1, start_secret),
      chains: %{0 => chain(role, i2r, r2i)},
      next_root: next_root
    }
  end

  # --- Sending (CRS-04b §9.2, §10.1) ---

  @doc """
  Makes the post-quantum message for the next sent message. `random` is 64
  fresh random bytes; state O1 passes them to `MlKem768.keypair/1`, and
  state N2 uses the first 32 as the encapsulation input m. Returns
  `{:ok, message_bytes, key, state}` or `{:error, :invalid}` when the chain
  epoch to send on does not exist.
  """
  @spec send(t(), <<_::512>>) :: {:ok, binary(), <<_::256>>, t()} | {:error, :invalid}
  def send(%__MODULE__{} = state, <<_::binary-size(64)>> = random) do
    {state, type, chunk} = send_action(state, random)
    chain_epoch = state.epoch - 1

    with {:ok, chain} <- Map.fetch(state.chains, chain_epoch) do
      index = chain.send.index + 1
      {chain_key, key} = chain_next(chain.send.chain_key, index)

      chains =
        Map.put(state.chains, chain_epoch, %{chain | send: %{chain_key: chain_key, index: index}})

      state = retain(%{state | chains: chains}, chain_epoch)

      message =
        case chunk do
          nil ->
            %Message{epoch: state.epoch, index: index, type: type}

          {chunk_index, data} ->
            %Message{
              epoch: state.epoch,
              index: index,
              type: type,
              chunk_index: chunk_index,
              chunk: data
            }
        end

      {:ok, Message.encode(message), key, state}
    else
      :error -> {:error, :invalid}
    end
  end

  defp send_action(%{agreement: %{name: :o1}} = state, random) do
    {ek, dk} = MlKem768.keypair(random)
    <<key_part::binary-size(@key_part_bytes), rho::binary-size(32)>> = ek
    header = rho <> sha3(ek)
    payload = header <> header_mac(state.auth.mac, state.epoch, header)
    agreement = %{name: :o2, dk: dk, key_part: key_part, payload: payload, sent: 1}
    {%{state | agreement: agreement}, 1, {0, ErasureCode.chunk(payload, 0)}}
  end

  defp send_action(%{agreement: %{name: name} = agreement} = state, _random)
       when name in [:o2, :o3, :o4] do
    {type, payload} =
      case name do
        :o2 -> {1, agreement.payload}
        :o3 -> {2, agreement.key_part}
        :o4 -> {3, agreement.key_part}
      end

    {agreement, chunk} = next_chunk(agreement, payload)
    {%{state | agreement: agreement}, type, chunk}
  end

  defp send_action(%{agreement: %{name: :o5}} = state, _random), do: {state, 4, nil}

  defp send_action(%{agreement: %{name: name}} = state, _random) when name in [:n1, :n5],
    do: {state, 0, nil}

  defp send_action(
         %{agreement: %{name: :n2, header: header}} = state,
         <<m::binary-size(32), _::binary>>
       ) do
    <<rho::binary-size(32), ek_hash::binary-size(32)>> = header
    {shared, ciphertext1, r} = MlKem768.encapsulate_first(rho, ek_hash, m)
    epoch_secret = epoch_secret(shared, state.epoch)
    state = %{state | auth: auth_update(state.auth, state.epoch, epoch_secret)}
    state = add_chain_epoch(state, state.epoch, epoch_secret)

    agreement = %{
      name: :n3,
      header: header,
      m: m,
      r: r,
      ciphertext1: ciphertext1,
      sent: 1,
      chunks: %{}
    }

    {%{state | agreement: agreement}, 5, {0, ErasureCode.chunk(ciphertext1, 0)}}
  end

  defp send_action(%{agreement: %{name: name} = agreement} = state, _random)
       when name in [:n3, :n4] do
    {agreement, chunk} = next_chunk(agreement, agreement.ciphertext1)
    {%{state | agreement: agreement}, 5, chunk}
  end

  defp send_action(%{agreement: %{name: :n6} = agreement} = state, _random) do
    {agreement, chunk} = next_chunk(agreement, agreement.payload)
    {%{state | agreement: agreement}, 6, chunk}
  end

  # The next chunk of a payload. `sent` is the chunk count modulo 65536: the
  # index on the wire wraps to 0 after 65535, and chunk 65536 repeats chunk
  # 0 byte for byte (CRS-04b §5.3).
  defp next_chunk(%{sent: sent} = agreement, payload) do
    {%{agreement | sent: rem(sent + 1, @chunk_numbers)}, {sent, ErasureCode.chunk(payload, sent)}}
  end

  # When a party first sends on chain epoch s, it deletes chain epochs
  # before s - 1 (CRS-04b §7.4).
  defp retain(%{last_send_chain_epoch: s} = state, s), do: state

  defp retain(state, s) do
    chains = Map.reject(state.chains, fn {epoch, _chain} -> epoch < s - 1 end)
    %{state | chains: chains, last_send_chain_epoch: s}
  end

  # --- Receiving (CRS-04b §9.3, §10.2, §11) ---

  @doc """
  Processes the post-quantum message of a received message. Returns
  `{:ok, key, state}`, where key is nil for epoch 1 with index 0, or
  `{:error, :invalid}`.
  """
  @spec receive(t(), binary() | nil) :: {:ok, <<_::256>> | nil, t()} | {:error, :invalid}
  def receive(%__MODULE__{} = state, bytes) do
    case Message.decode(bytes) do
      {:ok, %Message{version: 1} = message} ->
        with {:ok, state} <- agree(state, message) do
          receive_key(%{state | negotiating: false}, message.epoch - 1, message)
        end

      {:ok, %Message{} = message} when state.negotiating ->
        receive_key(state, 0, message)

      _ ->
        {:error, :invalid}
    end
  end

  # Epoch 1 with index 0 gives no key (CRS-04b §7.3, Comma decision D1).
  defp receive_key(state, _chain_epoch, %Message{epoch: 1, index: 0}), do: {:ok, nil, state}

  defp receive_key(state, chain_epoch, %Message{index: index}) do
    with {:ok, chain} <- Map.fetch(state.chains, chain_epoch),
         {:ok, key, receiving} <- take_key(chain.receive, index) do
      {:ok, key,
       %{state | chains: Map.put(state.chains, chain_epoch, %{chain | receive: receiving})}}
    else
      _ -> {:error, :invalid}
    end
  end

  # Receive limits and retention of one chain (CRS-04b §7.4).
  defp take_key(%{index: c} = receiving, i) do
    cond do
      i > c + @max_forward_jump ->
        :error

      i == c ->
        :error

      i < c ->
        case Map.pop(receiving.skipped, i) do
          {nil, _skipped} -> :error
          {key, skipped} when i + @window >= c -> {:ok, key, %{receiving | skipped: skipped}}
          {_key, _skipped} -> :error
        end

      true ->
        {chain_key, key, skipped} = advance(receiving.chain_key, c + 1, i, receiving.skipped)
        skipped = Map.reject(skipped, fn {index, _key} -> index + @window < i end)
        {:ok, key, %{receiving | chain_key: chain_key, index: i, skipped: skipped}}
    end
  end

  defp advance(chain_key, index, target, skipped) do
    {chain_key, key} = chain_next(chain_key, index)

    if index == target,
      do: {chain_key, key, skipped},
      else: advance(chain_key, index + 1, target, maybe_keep(skipped, index, key, target))
  end

  defp maybe_keep(skipped, index, key, target) when index + @window >= target,
    do: Map.put(skipped, index, key)

  defp maybe_keep(skipped, _index, _key, _target), do: skipped

  # The key-agreement part of a version-1 message (CRS-04b §9.3).
  defp agree(%{epoch: e} = state, %Message{epoch: epoch}) when epoch < e, do: {:ok, state}

  defp agree(%{epoch: e, agreement: %{name: :n6}} = state, %Message{epoch: epoch})
       when epoch == e + 1,
       do: {:ok, %{state | epoch: epoch, agreement: %{name: :o1}}}

  defp agree(%{epoch: e}, %Message{epoch: epoch}) when epoch > e, do: {:error, :invalid}

  defp agree(%{agreement: agreement} = state, %Message{type: type} = message) do
    case {agreement.name, type} do
      {:o2, 5} ->
        {:ok,
         put_agreement(state, %{
           name: :o3,
           dk: agreement.dk,
           key_part: agreement.key_part,
           sent: 0,
           chunks: add_chunk(%{}, message)
         })}

      {:o3, 5} ->
        chunks = add_chunk(agreement.chunks, message)

        case ErasureCode.decode(chunks, @ciphertext1_bytes) do
          {:ok, ciphertext1} ->
            {:ok,
             put_agreement(state, %{
               name: :o4,
               dk: agreement.dk,
               key_part: agreement.key_part,
               sent: agreement.sent,
               ciphertext1: ciphertext1
             })}

          :incomplete ->
            {:ok, put_agreement(state, %{agreement | chunks: chunks})}
        end

      {:o4, 6} ->
        {:ok,
         put_agreement(state, %{
           name: :o5,
           dk: agreement.dk,
           ciphertext1: agreement.ciphertext1,
           chunks: add_chunk(%{}, message)
         })}

      {:o5, 6} ->
        chunks = add_chunk(agreement.chunks, message)

        case ErasureCode.decode(chunks, @ciphertext2_bytes) do
          {:ok, payload} -> finish_epoch(state, agreement, payload)
          :incomplete -> {:ok, put_agreement(state, %{agreement | chunks: chunks})}
        end

      {:n1, 1} ->
        chunks = add_chunk(agreement.chunks, message)

        case ErasureCode.decode(chunks, @header_bytes) do
          {:ok, <<header::binary-size(64), mac::binary-size(32)>>} ->
            if Hmac.equal?(mac, header_mac(state.auth.mac, state.epoch, header)),
              do: {:ok, put_agreement(state, %{name: :n2, header: header})},
              else: {:error, :invalid}

          :incomplete ->
            {:ok, put_agreement(state, %{agreement | chunks: chunks})}
        end

      {name, type} when name in [:n3, :n5] and type in [2, 3] ->
        receive_key_part(state, agreement, message)

      {:n4, type} when type in [3, 4] ->
        {:ok, encapsulate_second(state, agreement, agreement.key_part)}

      _ ->
        {:ok, state}
    end
  end

  defp receive_key_part(state, agreement, message) do
    chunks = add_chunk(agreement.chunks, message)

    case ErasureCode.decode(chunks, @key_part_bytes) do
      {:ok, key_part} ->
        cond do
          not valid_key_part?(agreement.header, key_part) ->
            {:error, :invalid}

          agreement.name == :n5 or message.type == 3 ->
            {:ok, encapsulate_second(state, agreement, key_part)}

          true ->
            {:ok,
             put_agreement(
               state,
               agreement |> Map.put(:name, :n4) |> Map.put(:key_part, key_part)
             )}
        end

      :incomplete ->
        name = if message.type == 3, do: :n5, else: agreement.name
        {:ok, put_agreement(state, %{agreement | name: name, chunks: chunks})}
    end
  end

  # The key part must match the header hash and pass the FIPS 203 modulus
  # check (CRS-04b §8.3).
  defp valid_key_part?(<<rho::binary-size(32), ek_hash::binary-size(32)>>, key_part) do
    ek = key_part <> rho
    Hmac.equal?(sha3(ek), ek_hash) and MlKem768.valid_encapsulation_key?(ek)
  end

  defp encapsulate_second(state, agreement, key_part) do
    ciphertext2 = MlKem768.encapsulate_second(key_part, agreement.r, agreement.m)
    mac = ciphertext_mac(state.auth.mac, state.epoch, agreement.ciphertext1, ciphertext2)
    put_agreement(state, %{name: :n6, payload: ciphertext2 <> mac, sent: 0})
  end

  # A decapsulation that fails (for example, a stored decapsulation key that
  # OpenSSL refuses) makes the message invalid like any other SPQR error
  # (CRS-04b §12), so the caller keeps the old state and the writer goes on.
  defp finish_epoch(state, agreement, <<ciphertext2::binary-size(128), mac::binary-size(32)>>) do
    with {:ok, shared} <-
           MlKem768.decapsulate(agreement.dk, agreement.ciphertext1 <> ciphertext2),
         epoch_secret = epoch_secret(shared, state.epoch),
         auth = auth_update(state.auth, state.epoch, epoch_secret),
         true <-
           Hmac.equal?(
             mac,
             ciphertext_mac(auth.mac, state.epoch, agreement.ciphertext1, ciphertext2)
           ) do
      state = add_chain_epoch(%{state | auth: auth}, state.epoch, epoch_secret)
      {:ok, %{state | epoch: state.epoch + 1, agreement: %{name: :n1, chunks: %{}}}}
    else
      _failure -> {:error, :invalid}
    end
  end

  defp put_agreement(state, agreement), do: %{state | agreement: agreement}

  # A chunk with an index already held replaces the held value, as the
  # deployed decoder does (CRS-04b §5.4). For an honest sender both values
  # are the same.
  defp add_chunk(chunks, %Message{chunk_index: index, chunk: chunk}),
    do: Map.put(chunks, index, chunk)

  # --- Authenticator (CRS-04b §6) ---

  @doc false
  def auth_update(%{root: root}, epoch, key) do
    <<root::binary-size(32), mac::binary-size(32)>> =
      Hkdf.derive(root <> key, "", [@auth_update, <<epoch::64>>], 64)

    %{root: root, mac: mac}
  end

  @doc false
  def header_mac(mac_key, epoch, header),
    do: Hmac.sha256(mac_key, [@header_mac, <<epoch::64>>, header])

  @doc false
  def ciphertext_mac(mac_key, epoch, ciphertext1, ciphertext2),
    do: Hmac.sha256(mac_key, [@ciphertext_mac, <<epoch::64>>, ciphertext1, ciphertext2])

  @doc false
  def epoch_secret(shared, epoch), do: Hkdf.derive(shared, "", [@scka_key, <<epoch::64>>], 32)

  # --- Chains (CRS-04b §7) ---

  defp add_chain_epoch(%{top_chain_epoch: top} = state, epoch, epoch_secret)
       when epoch == top + 1 do
    {next_root, i2r, r2i} = chain_epoch(state.next_root, epoch_secret)

    %{
      state
      | chains: Map.put(state.chains, epoch, chain(state.role, i2r, r2i)),
        top_chain_epoch: epoch,
        next_root: next_root
    }
  end

  @doc false
  # Chain epoch 0: `{next_root, initiator_to_responder, responder_to_initiator}`.
  def chain_start(start_secret), do: chain_keys(Hkdf.derive(start_secret, "", @chain_start, 96))

  @doc false
  # Chain epoch e >= 1 from the next root of epoch e - 1 and S_e.
  def chain_epoch(next_root, epoch_secret),
    do: chain_keys(Hkdf.derive(epoch_secret, next_root, @chain_add, 96))

  defp chain_keys(<<next_root::binary-size(32), i2r::binary-size(32), r2i::binary-size(32)>>),
    do: {next_root, i2r, r2i}

  defp chain(:initiator, i2r, r2i), do: new_chain(i2r, r2i)
  defp chain(:responder, i2r, r2i), do: new_chain(r2i, i2r)

  defp new_chain(send_key, receive_key) do
    %{
      send: %{chain_key: send_key, index: 0},
      receive: %{chain_key: receive_key, index: 0, skipped: %{}}
    }
  end

  @doc false
  # Key i of a chain from CK_(i-1): returns {CK_i, key_i}.
  def chain_next(chain_key, index) do
    <<next::binary-size(32), key::binary-size(32)>> =
      Hkdf.derive(chain_key, "", [<<index::32>>, @chain_next], 64)

    {next, key}
  end

  defp sha3(bytes), do: :crypto.hash(:sha3_256, bytes)
end
