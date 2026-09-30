defmodule SalixSignalProto.Test.Party do
  @moduledoc false
  # A Signal account device for protocol tests: identity key, registration
  # ID, one signed EC pre-key, one KEM pre-key and one one-time EC pre-key,
  # with a pre-key bundle and the lookups that SalixSignalProto.Session and
  # SalixSignalProto.Receive take. Sessions live in the `sessions` map, keyed
  # by the remote address.

  alias SalixSignalProto.{Address, Keys, PreKeyBundle, ServiceId}
  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.SealedSender.Certificate

  defstruct [
    :aci,
    :device_id,
    :identity,
    :registration_id,
    :signed,
    :kem,
    :one_time,
    sessions: %{}
  ]

  def new(opts \\ []) do
    identity = Keys.ec_keypair(:crypto.strong_rand_bytes(32))

    %__MODULE__{
      aci: Keyword.get_lazy(opts, :aci, fn -> :crypto.strong_rand_bytes(16) end),
      device_id: Keyword.get(opts, :device_id, 1),
      identity: identity,
      registration_id: Keyword.get(opts, :registration_id, :rand.uniform(16_380)),
      signed: Keys.ec_keypair(:crypto.strong_rand_bytes(32)),
      kem: Keys.kem_keypair(),
      one_time: Keys.ec_keypair(:crypto.strong_rand_bytes(32))
    }
  end

  def name(%__MODULE__{aci: aci}), do: ServiceId.to_string({:aci, aci})
  def address(%__MODULE__{} = party), do: Address.new(name(party), party.device_id)

  def bundle(%__MODULE__{} = party, opts \\ []) do
    %PreKeyBundle{
      registration_id: party.registration_id,
      device_id: party.device_id,
      identity_key: party.identity.public,
      one_time_pre_key_id: if(Keyword.get(opts, :one_time, true), do: 11),
      one_time_pre_key: if(Keyword.get(opts, :one_time, true), do: party.one_time.public),
      signed_pre_key_id: 7,
      signed_pre_key: party.signed.public,
      signed_pre_key_signature: XEdDSA.sign(party.identity.private, party.signed.public),
      kem_pre_key_id: 13,
      kem_pre_key: party.kem.public,
      kem_pre_key_signature: XEdDSA.sign(party.identity.private, party.kem.public)
    }
  end

  def pre_keys(%__MODULE__{} = party) do
    fn
      {:signed_pre_key, 7} -> {:ok, party.signed.private}
      {:one_time_pre_key, 11} -> {:ok, party.one_time.private}
      {:kem_pre_key, 13} -> {:ok, party.kem.secret}
      {:kem_pre_key_used?, _id, _signed, _base} -> false
      _other -> :error
    end
  end

  # The SalixSignalProto.Session context of `party` talking to `remote`.
  def session_context(%__MODULE__{} = party, %__MODULE__{} = remote) do
    %{
      identity: party.identity,
      registration_id: party.registration_id,
      local_address: address(party),
      remote_address: address(remote),
      trusted?: fn _key, _direction -> true end
    }
  end

  # The SalixSignalProto.Receive context of `party`.
  def receive_context(%__MODULE__{} = party, trust_roots, now_ms) do
    %{
      aci: party.aci,
      pni: nil,
      device_id: party.device_id,
      identities: %{aci: party.identity, pni: nil},
      registration_ids: %{aci: party.registration_id, pni: 0},
      trust_roots: trust_roots,
      known_server_certificates: %{},
      now_ms: now_ms,
      session: fn address -> Map.get(party.sessions, address) end,
      pre_keys: fn :aci -> pre_keys(party) end
    }
  end

  def put_session(%__MODULE__{} = party, address, record),
    do: %{party | sessions: Map.put(party.sessions, address, record)}

  # A test trust root and server key, and a sender certificate for `party`.
  def certificate_authority do
    root = Keys.ec_keypair(:crypto.strong_rand_bytes(32))
    server = Keys.ec_keypair(:crypto.strong_rand_bytes(32))

    %{
      root: root,
      server: server,
      server_certificate: Certificate.issue_server(1, server.public, root.private)
    }
  end

  def sender_certificate(%__MODULE__{} = party, authority, expiration, e164 \\ nil) do
    bytes =
      Certificate.issue_sender(
        %{
          e164: e164,
          device_id: party.device_id,
          expiration: expiration,
          identity_key: party.identity.public,
          aci: party.aci,
          signer: {:embedded, authority.server_certificate}
        },
        authority.server.private
      )

    {:ok, certificate} = Certificate.decode_sender(bytes)
    certificate
  end
end
