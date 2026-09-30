defmodule SalixSignal.Messaging.Store do
  @moduledoc """
  The durable state that the messaging pipeline (`SalixSignal.Messaging.Pipeline`)
  reads and changes for one Signal account.

  Only the account's owner process writes, so reads outside a commit see the
  state that the next commit changes (PLAN "Durable state", one writer per
  account). Every write goes through `c:commit/3`: the operations of one
  commit take effect together or not at all, and only while `epoch` is the
  account's current owner epoch. A stale owner gets `{:error, :fenced}` and
  changes nothing.

  The receive invariant: a session advance and the admission of the envelope
  it decrypted are in the same commit, and the pipeline acknowledges the
  envelope to the service only after that commit (CRS-07 §5.3). A crash
  before the commit replays the envelope; a crash after it finds the
  envelope admitted and acknowledges it without processing it again.

  ## Operations

  | Operation | Effect |
  | --- | --- |
  | `{:put_session, address, record}` | stores the session record of a remote device |
  | `{:delete_session, address}` | forgets the session record of a remote device |
  | `{:put_identity, name, key}` | stores the identity key of a remote account (by service ID string) |
  | `{:pre_key_effects, :aci | :pni, effects}` | applies `SalixSignalProto.Session` effects to the local pre-keys (CRS-03 §10.2) |
  | `{:admit, guid, inbound}` | records that the envelope with server GUID `guid` was processed, with its outcome |
  | `{:record_message, key}` | records a received message identity `{author, sent_timestamp, conversation}` (CRS-07 §5.4) |
  | `{:put_contact, name, contact}` | stores the per-contact state (profile key, 1:1 timer) |
  | `{:put_sent, key, sent}` | keeps sent content for answering retry requests, key `{recipient, device, timestamp}` |
  | `{:sender_key, {address, distribution_id, record}}` | stores the received sender key of a remote device for one distribution ID (CRS-09c section 5) |
  | `{:put_group, group_id, group}` | stores a group: master key, revision, state, endorsements and this device's own sender key (CRS-09b, CRS-09c section 6) |
  | `{:put_pre_keys, :aci | :pni, store}` | replaces the local pre-key store of an identity after maintenance (CRS-03 §10) |
  | `{:put_send_timestamp, ms}` | records a send timestamp before it is used; the store keeps the highest, which the next owner starts above (CRS-07 §2) |

  The store encrypts this state at rest; that is the implementation's
  concern, not the pipeline's.
  """

  alias SalixSignalProto.{Address, Keys, Session}

  @type handle :: term()
  @type epoch :: non_neg_integer()
  @type message_key ::
          {author :: String.t(), sent_timestamp :: non_neg_integer(), conversation :: term()}
  @type sent_key :: {recipient :: String.t(), device_id :: 1..127, timestamp :: non_neg_integer()}

  @typedoc """
  Per-contact state: the contact's profile key (CRS-05 §5.2, needed for its
  access key, CRS-06 §4), the 1:1 disappearing-message timer
  (`SalixSignalProto.Message.ExpireTimer`) and, once a device-list
  correction named one of its devices, `device_changes`: the generation of
  each such device, part of its sender-key target (CRS-07 §4, CRS-09c
  section 6.2).
  """
  @type contact :: %{
          required(:profile_key) => <<_::256>> | nil,
          required(:expire_timer) => SalixSignalProto.Message.ExpireTimer.t(),
          required(:unregistered?) => boolean(),
          optional(:device_changes) => %{optional(1..127) => pos_integer()}
        }

  @typedoc """
  A group of the account (CRS-09b): the master key, the revision and
  decrypted state as last fetched, the group send endorsements
  (`%{expiration, by_member: %{service_id => endorsement}}`, CRS-09a
  section 15), and this device's sender key for the group
  (`SalixSignalProto.SenderKey.Sending`, CRS-09c section 6). `state` and
  `endorsements` are nil until the first fetch.
  """
  @type group :: %{
          master_key: <<_::256>>,
          revision: non_neg_integer(),
          state: SalixSignalProto.Group.State.t() | nil,
          endorsements: map() | nil,
          sending: SalixSignalProto.SenderKey.Sending.t() | nil
        }

  @typedoc "Content kept for a resend after a retry request (CRS-07 §6.3)."
  @type sent :: %{
          content: binary(),
          content_hint: non_neg_integer(),
          urgent: boolean(),
          group_id: binary() | nil,
          sent_at_ms: non_neg_integer()
        }

  @type op ::
          {:put_session, Address.t(), Session.Record.t()}
          | {:delete_session, Address.t()}
          | {:put_identity, String.t(), Keys.ec_public()}
          | {:pre_key_effects, :aci | :pni, Session.effects()}
          | {:admit, <<_::128>>, SalixSignal.Messaging.Inbound.t()}
          | {:record_message, message_key()}
          | {:put_contact, String.t(), contact()}
          | {:put_sent, sent_key(), sent()}
          | {:sender_key, {Address.t(), <<_::128>>, SalixSignalProto.SenderKey.Record.t()}}
          | {:put_group, <<_::256>>, group()}
          | {:put_pre_keys, :aci | :pni, SalixSignalProto.PreKeys.Store.t()}
          | {:put_send_timestamp, non_neg_integer()}

  @doc "The session record of a remote device, or nil."
  @callback session(handle(), Address.t()) :: Session.Record.t() | nil

  @doc "The device IDs of a remote account that have a session record."
  @callback device_ids(handle(), name :: String.t()) :: [1..127]

  @doc "The stored identity key of a remote account, or nil."
  @callback identity(handle(), name :: String.t()) :: Keys.ec_public() | nil

  @doc "The pre-key lookup of the local identity `kind` (see `t:SalixSignalProto.Session.pre_keys/0`)."
  @callback pre_keys(handle(), :aci | :pni) :: Session.pre_keys()

  @doc "True when the envelope with this server GUID was admitted."
  @callback admitted?(handle(), <<_::128>>) :: boolean()

  @doc "True when a message with this identity was recorded."
  @callback message_seen?(handle(), message_key()) :: boolean()

  @doc "The per-contact state, or nil."
  @callback contact(handle(), name :: String.t()) :: contact() | nil

  @doc "Sent content kept for retry requests, or nil."
  @callback sent(handle(), sent_key()) :: sent() | nil

  @doc "The received sender key of `address` for `distribution_id`, or nil."
  @callback sender_key(handle(), Address.t(), distribution_id :: <<_::128>>) ::
              SalixSignalProto.SenderKey.Record.t() | nil

  @doc "The stored group with this 32-byte group identifier, or nil."
  @callback group(handle(), group_id :: <<_::256>>) :: group() | nil

  @doc "Applies `ops` atomically while `epoch` is current."
  @callback commit(handle(), epoch(), [op()]) :: :ok | {:error, :fenced}
end
