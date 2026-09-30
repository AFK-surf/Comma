defmodule SalixSignalProto.Test.SessionFixtures do
  @moduledoc false
  # Helpers for session tests: contexts, pre-key lookups, bundles, and
  # conversion of CRS vector state to session states.

  alias SalixSignalProto.{Address, Keys, PreKeyBundle}
  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.Session.{Record, State}
  alias SalixSignalProto.Test.Vectors

  def trust_all(_key, _direction), do: true

  def context(identity_private, registration_id, local, remote, trusted? \\ &trust_all/2) do
    %{
      identity: Keys.ec_keypair(identity_private),
      registration_id: registration_id,
      local_address: local,
      remote_address: remote,
      trusted?: trusted?
    }
  end

  def address(%{"service_id" => service_id, "device_id" => device_id}),
    do: Address.new(service_id, device_id)

  @doc "Reads the sender and recipient addresses back from a 36-byte binding."
  def addresses(
        <<sender::binary-size(17), sender_device, recipient::binary-size(17), recipient_device>>
      ),
      do:
        {Address.new(service_id(sender), sender_device),
         Address.new(service_id(recipient), recipient_device)}

  defp service_id(<<kind, a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    uuid = Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
    if kind == 1, do: "PNI:" <> uuid, else: uuid
  end

  @doc """
  A pre-key lookup over maps of ID to key: `%{signed: %{}, one_time: %{},
  kem: %{}}`. `used` lists `{kem_id, signed_id, base_key}` combinations
  already accepted.
  """
  def pre_keys(keys, used \\ []) do
    fn
      {:signed_pre_key, id} -> Map.fetch(keys[:signed] || %{}, id)
      {:one_time_pre_key, id} -> Map.fetch(keys[:one_time] || %{}, id)
      {:kem_pre_key, id} -> Map.fetch(keys[:kem] || %{}, id)
      {:kem_pre_key_used?, id, signed_id, base_key} -> {id, signed_id, base_key} in used
    end
  end

  @doc """
  A responder with fresh keys: `%{identity, signed, one_time, kem, bundle,
  pre_keys}`. Pass `one_time: false` for a bundle without a one-time pre-key.
  """
  def responder(opts \\ []) do
    identity = Keys.ec_keypair()
    signed = Keys.ec_keypair()
    one_time = if Keyword.get(opts, :one_time, true), do: Keys.ec_keypair()
    kem = Keys.kem_keypair()

    bundle = %PreKeyBundle{
      registration_id: Keyword.get(opts, :registration_id, 4321),
      device_id: 1,
      identity_key: identity.public,
      one_time_pre_key_id: one_time && 7,
      one_time_pre_key: one_time && one_time.public,
      signed_pre_key_id: 11,
      signed_pre_key: signed.public,
      signed_pre_key_signature: XEdDSA.sign(identity.private, signed.public),
      kem_pre_key_id: 13,
      kem_pre_key: kem.public,
      kem_pre_key_signature: XEdDSA.sign(identity.private, kem.public)
    }

    keys = %{
      signed: %{11 => signed.private},
      one_time: if(one_time, do: %{7 => one_time.private}, else: %{}),
      kem: %{13 => kem.secret}
    }

    %{identity: identity, bundle: bundle, keys: keys, pre_keys: pre_keys(keys)}
  end

  @doc "A session state from the vector form of CRS-04 (`initial_state`, `*_state_after`)."
  def state_from_vector(vector, fields) do
    hex = &Vectors.hex!/1
    sending = vector["sending_chain"]

    struct!(
      State,
      Map.merge(
        %{
          root_key: hex.(vector["root_key"]),
          previous_chain_length: vector["previous_chain_length"],
          sender: %{
            private: sending["ratchet_private"] && hex.(sending["ratchet_private"]),
            public: hex.(sending["ratchet_public"]),
            chain_key: hex.(sending["chain_key"]),
            index: sending["chain_index"]
          },
          receivers:
            Enum.map(vector["receiving_chains"], fn chain ->
              %{
                public: hex.(chain["ratchet_public"]),
                chain_key: hex.(chain["chain_key"]),
                index: chain["chain_index"],
                seeds: seeds(chain)
              }
            end)
        },
        fields
      )
    )
  end

  defp seeds(chain) do
    for seed <- chain["stored_message_key_seeds"] || [],
        do: {seed["index"], Vectors.hex!(seed["seed"])}
  end

  @doc """
  Asserts that the EC ratchet part of `state` equals a vector state. The
  sending ratchet private key is compared only when the vector gives it.
  """
  def assert_ec_state(%State{} = state, vector, label \\ "") do
    expected =
      state_from_vector(vector, %{local_identity: nil, remote_identity: nil, base_key: nil})

    sender = if expected.sender.private, do: state.sender, else: %{state.sender | private: nil}

    ExUnit.Assertions.assert(
      {state.root_key, state.previous_chain_length, sender, state.receivers} ==
        {expected.root_key, expected.previous_chain_length, expected.sender, expected.receivers},
      "EC state differs #{label}"
    )
  end

  def record(state), do: Record.promote(Record.new(), state)
end
