defmodule SalixSignalProto.ServiceId do
  @moduledoc """
  Service IDs in their wire forms (CRS-05 §2, CRS-06 §2).

  A service ID is `{:aci, uuid}` or `{:pni, uuid}` with `uuid` the 16 UUID
  bytes in RFC 4122 order.

  | Form | ACI | PNI |
  | --- | --- | --- |
  | binary | 16 UUID bytes | `0x01` then 16 UUID bytes |
  | fixed-width binary | `0x00` then 16 UUID bytes | `0x01` then 16 UUID bytes |
  | string | lowercase hyphenated UUID | `PNI:` then the hyphenated UUID |
  """

  alias SalixSignalProto.Address

  @type t :: Address.service_id()

  @doc "Parses the binary form: 16 bytes for an ACI, `0x01` and 16 bytes for a PNI."
  @spec from_binary(binary()) :: {:ok, t()} | :error
  def from_binary(<<uuid::binary-size(16)>>), do: {:ok, {:aci, uuid}}
  def from_binary(<<0x01, uuid::binary-size(16)>>), do: {:ok, {:pni, uuid}}
  def from_binary(_bytes), do: :error

  @doc "The binary form."
  @spec to_binary(t()) :: binary()
  def to_binary({:aci, <<_::binary-size(16)>> = uuid}), do: uuid
  def to_binary({:pni, <<_::binary-size(16)>> = uuid}), do: <<0x01>> <> uuid

  @doc "Parses the 17-byte fixed-width form."
  @spec from_fixed_width(binary()) :: {:ok, t()} | :error
  def from_fixed_width(<<0x00, uuid::binary-size(16)>>), do: {:ok, {:aci, uuid}}
  def from_fixed_width(<<0x01, uuid::binary-size(16)>>), do: {:ok, {:pni, uuid}}
  def from_fixed_width(_bytes), do: :error

  @doc "The 17-byte fixed-width form."
  @spec fixed_width(t()) :: <<_::136>>
  defdelegate fixed_width(service_id), to: Address

  @doc "Parses a service ID string. Hexadecimal digits may be in either case."
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(string) when is_binary(string), do: Address.parse_service_id(string)
  def parse(_other), do: :error

  @doc "The service ID string."
  @spec to_string(t()) :: String.t()
  def to_string({:aci, uuid}), do: uuid_string(uuid)
  def to_string({:pni, uuid}), do: "PNI:" <> uuid_string(uuid)

  @doc "The lowercase hyphenated string of 16 UUID bytes."
  @spec uuid_string(<<_::128>>) :: String.t()
  def uuid_string(
        <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
          e::binary-size(6)>>
      ) do
    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  @doc "Parses an ACI given as 16 bytes; any other length is an error."
  @spec aci_from_binary(binary()) :: {:ok, <<_::128>>} | :error
  def aci_from_binary(<<uuid::binary-size(16)>>), do: {:ok, uuid}
  def aci_from_binary(_bytes), do: :error

  @doc "Parses an ACI given as a UUID string (no `PNI:` prefix)."
  @spec aci_from_string(binary()) :: {:ok, <<_::128>>} | :error
  def aci_from_string(string) when is_binary(string) do
    case parse(string) do
      {:ok, {:aci, uuid}} -> {:ok, uuid}
      _ -> :error
    end
  end
end
