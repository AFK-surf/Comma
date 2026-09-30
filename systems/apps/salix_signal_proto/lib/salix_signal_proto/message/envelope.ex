defmodule SalixSignalProto.Message.Envelope do
  @moduledoc """
  The server envelope that the service delivers to a device (CRS-05 §3).

  `decode/1` keeps the fields a receiver uses and prefers the binary service
  ID and GUID fields (19 to 22) over the legacy strings (9, 11, 13, 15).
  Urgent is true when field 14 is absent. `encode/1` writes fields in
  ascending order, as the service does; Comma uses it only for test servers.

  Envelope kinds (§3.2):

  | Kind | Payload |
  | --- | --- |
  | 1 | double-ratchet message (CRS-04), identified |
  | 3 | pre-key message (CRS-04), identified |
  | 5 | none: server delivery receipt, identified |
  | 6 | sealed sender (CRS-06) |
  | 8 | plaintext wrapper (§7), identified |
  """

  alias SalixSignalProto.Message.Wire
  alias SalixSignalProto.ServiceId

  @identified [1, 3, 5, 8]
  @valid_kinds [1, 3, 5, 6, 8]

  defstruct kind: 0,
            client_timestamp: nil,
            source_device: nil,
            payload: nil,
            server_timestamp: nil,
            urgent: true,
            story: false,
            spam_report_token: nil,
            source: nil,
            destination: nil,
            server_guid: nil,
            updated_pni: nil

  @type t :: %__MODULE__{
          kind: non_neg_integer(),
          client_timestamp: non_neg_integer() | nil,
          source_device: non_neg_integer() | nil,
          payload: binary() | nil,
          server_timestamp: non_neg_integer() | nil,
          urgent: boolean(),
          story: boolean(),
          spam_report_token: binary() | nil,
          source: ServiceId.t() | nil,
          destination: ServiceId.t() | nil,
          server_guid: <<_::128>> | nil,
          updated_pni: <<_::128>> | nil
        }

  @doc "Decodes a serialized server envelope."
  @spec decode(binary()) :: {:ok, t()} | {:error, :malformed}
  def decode(bytes) when is_binary(bytes) do
    wire = Wire.Envelope.decode(bytes)

    {:ok,
     %__MODULE__{
       kind: wire.kind || 0,
       client_timestamp: wire.client_timestamp,
       source_device: wire.source_device,
       payload: wire.payload,
       server_timestamp: wire.server_timestamp,
       urgent: if(is_nil(wire.urgent), do: true, else: wire.urgent),
       story: wire.story == true,
       spam_report_token: wire.spam_report_token,
       source: service_id(wire.source_service_id, wire.source_service_id_string),
       destination: service_id(wire.destination_service_id, wire.destination_service_id_string),
       server_guid: uuid(wire.server_guid, wire.server_guid_string),
       updated_pni: uuid(wire.updated_pni, wire.updated_pni_string)
     }}
  rescue
    # The protobuf decoder raises on malformed input.
    _error -> {:error, :malformed}
  end

  defp service_id(binary, string) do
    with bytes when is_binary(bytes) <- binary,
         {:ok, id} <- ServiceId.from_binary(bytes) do
      id
    else
      _ -> legacy_service_id(string)
    end
  end

  defp legacy_service_id(string) when is_binary(string) do
    case ServiceId.parse(string) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp legacy_service_id(nil), do: nil

  defp uuid(<<uuid::binary-size(16)>>, _string), do: uuid

  defp uuid(_binary, string) when is_binary(string) do
    case ServiceId.aci_from_string(string) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_binary, nil), do: nil

  @doc "Encodes an envelope with the binary service ID fields."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = envelope) do
    Wire.Envelope.encode(%Wire.Envelope{
      kind: envelope.kind,
      client_timestamp: envelope.client_timestamp,
      source_device: envelope.source_device,
      payload: envelope.payload,
      server_timestamp: envelope.server_timestamp,
      urgent: envelope.urgent,
      story: if(envelope.story, do: true),
      spam_report_token: envelope.spam_report_token,
      source_service_id: envelope.source && ServiceId.to_binary(envelope.source),
      destination_service_id: envelope.destination && ServiceId.to_binary(envelope.destination),
      server_guid: envelope.server_guid,
      updated_pni: envelope.updated_pni
    })
  end

  @doc "True for the kinds that carry the sender's identity (1, 3, 5, 8)."
  @spec identified?(t()) :: boolean()
  def identified?(%__MODULE__{kind: kind}), do: kind in @identified

  @doc """
  The receiver checks of CRS-05 §3.1 and §6.6 for the account with ACI `aci`
  and PNI `pni` (16 UUID bytes each; `pni` may be nil).

  Returns `{:ok, :aci | :pni}`, the identity the envelope is addressed to, or
  `{:drop, reason}` for an envelope that the receiver acknowledges without
  processing:

    * `:unknown_kind`: kind 0, a reserved kind, or an unknown kind;
    * `:wrong_destination`: the destination is absent or is neither the ACI
      nor the PNI;
    * `:story`: the story flag is set (Comma ignores stories);
    * `:sealed_to_pni`: a sealed-sender envelope addressed to the PNI;
    * `:missing_source`: an identified envelope without a valid source ACI
      and device;
    * `:pni_source`: an identified envelope whose source is a PNI, other
      than a server delivery receipt;
    * `:missing_payload`: kinds 1, 3, 6 and 8 without a payload.
  """
  @spec check(t(), <<_::128>>, <<_::128>> | nil) ::
          {:ok, :aci | :pni} | {:drop, atom()}
  def check(%__MODULE__{} = envelope, aci, pni) do
    with :ok <- known_kind(envelope),
         {:ok, destination} <- destination(envelope, aci, pni),
         :ok <- not_story(envelope),
         :ok <- sealed_destination(envelope, destination),
         :ok <- source(envelope),
         :ok <- payload(envelope) do
      {:ok, destination}
    end
  end

  defp known_kind(%{kind: kind}) when kind in @valid_kinds, do: :ok
  defp known_kind(_envelope), do: {:drop, :unknown_kind}

  defp destination(%{destination: {:aci, aci}}, aci, _pni), do: {:ok, :aci}
  defp destination(%{destination: {:pni, pni}}, _aci, pni) when is_binary(pni), do: {:ok, :pni}
  defp destination(_envelope, _aci, _pni), do: {:drop, :wrong_destination}

  defp not_story(%{story: true}), do: {:drop, :story}
  defp not_story(_envelope), do: :ok

  defp sealed_destination(%{kind: 6}, :pni), do: {:drop, :sealed_to_pni}
  defp sealed_destination(_envelope, _destination), do: :ok

  defp source(%{kind: 6}), do: :ok

  defp source(%{kind: 5, source: {_kind, _uuid}, source_device: device})
       when is_integer(device) and device in 1..127,
       do: :ok

  defp source(%{source: {:aci, _uuid}, source_device: device})
       when is_integer(device) and device in 1..127,
       do: :ok

  defp source(%{kind: kind, source: {:pni, _uuid}}) when kind != 5, do: {:drop, :pni_source}
  defp source(_envelope), do: {:drop, :missing_source}

  defp payload(%{kind: 5}), do: :ok
  defp payload(%{payload: payload}) when is_binary(payload) and payload != "", do: :ok
  defp payload(_envelope), do: {:drop, :missing_payload}
end
