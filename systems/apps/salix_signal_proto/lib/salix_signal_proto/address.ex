defmodule SalixSignalProto.Address do
  @moduledoc """
  A protocol address: a name and a device ID. For Signal peers the name is a
  service ID string: an ACI is a UUID, and a PNI is `PNI:` followed by a UUID.

  The session protocol binds pre-key messages to the sender and recipient
  addresses (CRS-04 §7.4). The binding is 36 bytes: the sender service ID in
  fixed-width binary (kind byte `0x00` ACI or `0x01` PNI, then the 16-byte
  UUID), the sender device ID, the recipient service ID and the recipient
  device ID.
  """

  alias SalixSignalProto.Keys

  @enforce_keys [:name, :device_id]
  defstruct [:name, :device_id]

  @type t :: %__MODULE__{name: String.t(), device_id: non_neg_integer()}
  @type service_id :: {:aci | :pni, <<_::128>>}

  @doc "Builds an address."
  @spec new(String.t(), non_neg_integer()) :: t()
  def new(name, device_id) when is_binary(name) and is_integer(device_id),
    do: %__MODULE__{name: name, device_id: device_id}

  @doc """
  Parses a service ID string. Hexadecimal digits may be in either case.
  """
  @spec parse_service_id(String.t()) :: {:ok, service_id()} | :error
  def parse_service_id("PNI:" <> uuid), do: parse_uuid(uuid, :pni)
  def parse_service_id(uuid) when is_binary(uuid), do: parse_uuid(uuid, :aci)

  defp parse_uuid(
         <<a::binary-size(8), ?-, b::binary-size(4), ?-, c::binary-size(4), ?-, d::binary-size(4),
           ?-, e::binary-size(12)>>,
         kind
       ) do
    case Base.decode16(a <> b <> c <> d <> e, case: :mixed) do
      {:ok, bytes} -> {:ok, {kind, bytes}}
      :error -> :error
    end
  end

  defp parse_uuid(_other, _kind), do: :error

  @doc "The 17-byte fixed-width binary form of a service ID."
  @spec fixed_width(service_id()) :: <<_::136>>
  def fixed_width({:aci, <<_::binary-size(16)>> = uuid}), do: <<0x00>> <> uuid
  def fixed_width({:pni, <<_::binary-size(16)>> = uuid}), do: <<0x01>> <> uuid

  @doc """
  The 36-byte address binding of CRS-04 §7.4, or `nil` when either address
  is not a service ID with a valid device ID.
  """
  @spec binding(t(), t()) :: <<_::288>> | nil
  def binding(%__MODULE__{} = sender, %__MODULE__{} = recipient) do
    with {:ok, sender_part} <- binding_part(sender),
         {:ok, recipient_part} <- binding_part(recipient) do
      sender_part <> recipient_part
    else
      _ -> nil
    end
  end

  defp binding_part(%__MODULE__{name: name, device_id: device_id}) do
    with true <- Keys.valid_device_id?(device_id),
         {:ok, service_id} <- parse_service_id(name) do
      {:ok, fixed_width(service_id) <> <<device_id>>}
    else
      _ -> :error
    end
  end
end
