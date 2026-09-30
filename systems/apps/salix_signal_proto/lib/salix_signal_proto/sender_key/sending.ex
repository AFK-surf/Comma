defmodule SalixSignalProto.SenderKey.Sending do
  @moduledoc """
  This device's sender key for one group, and the send-side rules of
  CRS-09c section 6.

  The state holds the group's distribution ID (a random version-4 UUID that
  the device keeps for the group), this device's sender key record, and the
  set of targets (`t:target/0`) that received the current
  distribution message in a successful send (section 6.2).

  The runtime sends the distribution message to `needs_distribution/2`
  targets as ordinary 1:1 messages (content field 7 only, content hint 2,
  group ID set), calls `mark_delivered/2` after those sends succeed, then
  encrypts the group content once with `encrypt/3` and sends it with the
  sealed-sender multi-recipient format and a group send token for exactly
  the recipient accounts (`group_send_token/4`). `rotate/1` replaces the
  sender key when a member leaves or is removed (section 6.1).
  """

  alias SalixSignalProto.Group.Endorsements
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.SenderKey.Record

  @min_sender_key_accounts 2

  @enforce_keys [:distribution_id, :record]
  defstruct [:distribution_id, :record, delivered: MapSet.new()]

  @typedoc """
  A device that receives the distribution message: `{service_id,
  device_id}`, or with a third element that the caller chooses, such as a
  generation that changes when the device changes (CRS-07 §4), so that an
  earlier delivery no longer counts.
  """
  @type target ::
          {SalixSignalProto.Address.service_id(), 1..127}
          | {SalixSignalProto.Address.service_id(), 1..127, term()}
  @type t :: %__MODULE__{
          distribution_id: <<_::128>>,
          record: Record.t(),
          delivered: MapSet.t(target())
        }

  @doc "A new sender key under a new random distribution ID (or the given one)."
  @spec new(<<_::128>>) :: t()
  def new(distribution_id \\ random_uuid()) do
    %__MODULE__{distribution_id: distribution_id, record: Record.create(Record.new())}
  end

  @doc "A random version-4 UUID (RFC 4122 section 4.4)."
  @spec random_uuid() :: <<_::128>>
  def random_uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 4::4, b::12, 2::2, c::62>>
  end

  @doc """
  Replaces the sender key: a new chain under the same distribution ID. No
  target has the new distribution message yet.
  """
  @spec rotate(t()) :: t()
  def rotate(%__MODULE__{} = state),
    do: %{state | record: Record.create(Record.new()), delivered: MapSet.new()}

  @doc "The distribution message of the current sender key."
  @spec distribution_message(t()) :: binary()
  def distribution_message(%__MODULE__{record: record, distribution_id: id}) do
    {:ok, message} = Record.distribution_message(record, id)
    message
  end

  @doc "The targets that do not have the current distribution message, in the given order."
  @spec needs_distribution(t(), [target()]) :: [target()]
  def needs_distribution(%__MODULE__{delivered: delivered}, targets),
    do: Enum.reject(targets, &MapSet.member?(delivered, &1))

  @doc "Records that these targets received the distribution message."
  @spec mark_delivered(t(), [target()]) :: t()
  def mark_delivered(%__MODULE__{} = state, targets),
    do: %{state | delivered: Enum.into(targets, state.delivered)}

  @doc """
  Forgets delivery to the devices of the given targets, for example after a
  device list change (409) or a re-registered device (410), so they get the
  distribution message again. A target forgets every delivered target of
  the same service ID and device ID, whatever its third element.
  """
  @spec forget_delivered(t(), [target()]) :: t()
  def forget_delivered(%__MODULE__{} = state, targets) do
    devices = MapSet.new(targets, &device/1)
    %{state | delivered: MapSet.reject(state.delivered, &MapSet.member?(devices, device(&1)))}
  end

  defp device(target), do: {elem(target, 0), elem(target, 1)}

  @doc "Encrypts padded content into a sender key message (section 6.3 step 1)."
  @spec encrypt(t(), binary(), keyword()) :: {:ok, binary(), t()} | {:error, atom()}
  def encrypt(%__MODULE__{} = state, padded_content, opts \\ []) do
    with {:ok, message, record} <-
           Record.encrypt(state.record, state.distribution_id, padded_content, opts) do
      {:ok, message, %{state | record: record}}
    end
  end

  @doc """
  Splits recipient accounts into the sender-key path and individual sends
  (section 6.4). An account uses the sender-key path when it is a
  registered full member with an endorsement; with fewer than 2 such
  accounts, every account is sent individually.
  """
  @spec partition_recipients([SalixSignalProto.Address.service_id()], (term() -> boolean())) ::
          {sender_key :: list(), individual :: list()}
  def partition_recipients(accounts, eligible?) when is_function(eligible?, 1) do
    {sender_key, individual} = Enum.split_with(accounts, eligible?)

    if length(sender_key) >= @min_sender_key_accounts,
      do: {sender_key, individual},
      else: {[], accounts}
  end

  @doc """
  The full group send token for exactly `recipients` (section 6.3): the
  combination of their endorsements. `endorsements` maps service IDs to
  33-byte endorsements. Returns `:error` when one is missing.
  """
  @spec group_send_token(Params.t(), %{term() => binary()}, [term()], non_neg_integer()) ::
          {:ok, binary()} | :error
  def group_send_token(%Params{} = params, endorsements, recipients, expiration) do
    if Enum.all?(recipients, &Map.has_key?(endorsements, &1)) do
      combined = recipients |> Enum.map(&Map.fetch!(endorsements, &1)) |> Endorsements.combine()
      {:ok, Endorsements.full_token(params, combined, expiration)}
    else
      :error
    end
  end
end
