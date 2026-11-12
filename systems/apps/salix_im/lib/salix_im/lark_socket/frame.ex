defmodule SalixIM.LarkSocket.Frame do
  @moduledoc """
  A frame of the Lark long connection: protobuf `pbbp2.Frame`, as the Lark
  SDKs define it (`SalixIM.LarkSocket.Frame.Pbbp2`).

      message Header { required string key = 1; required string value = 2; }
      message Frame {
        required uint64 SeqID = 1; required uint64 LogID = 2;
        required int32 service = 3; required int32 method = 4;
        repeated Header headers = 5;
        optional string payload_encoding = 6; optional string payload_type = 7;
        optional bytes payload = 8; optional string LogIDNew = 9;
      }

  `method` 0 is a control frame (ping, pong), 1 a data frame (an event or a
  card callback). The header `type` says which.
  """

  alias __MODULE__.{Header, Pbbp2}

  defmodule Header do
    @moduledoc false
    use Protobuf, syntax: :proto2

    field(:key, 1, required: true, type: :string)
    field(:value, 2, required: true, type: :string)
  end

  defmodule Pbbp2 do
    @moduledoc false
    use Protobuf, syntax: :proto2

    field(:seq_id, 1, required: true, type: :uint64, json_name: "SeqID")
    field(:log_id, 2, required: true, type: :uint64, json_name: "LogID")
    field(:service, 3, required: true, type: :int32)
    field(:method, 4, required: true, type: :int32)
    field(:headers, 5, repeated: true, type: SalixIM.LarkSocket.Frame.Header)
    field(:payload_encoding, 6, optional: true, type: :string)
    field(:payload_type, 7, optional: true, type: :string)
    field(:payload, 8, optional: true, type: :bytes)
    field(:log_id_new, 9, optional: true, type: :string, json_name: "LogIDNew")
  end

  @type t :: %Pbbp2{}

  @control 0
  @data 1

  def control, do: @control
  def data, do: @data

  @doc "The value of the header `key`, or nil."
  def header(%Pbbp2{headers: headers}, key),
    do: Enum.find_value(headers, fn %Header{key: k, value: v} -> if k == key, do: v end)

  @doc "A frame with `headers` given as `{key, value}` pairs."
  def new(fields) do
    {headers, fields} = Keyword.pop(fields, :headers, [])

    struct!(
      Pbbp2,
      [seq_id: 0, log_id: 0, service: 0, method: @data]
      |> Keyword.merge(fields)
      |> Keyword.put(:headers, Enum.map(headers, fn {k, v} -> %Header{key: k, value: v} end))
    )
  end

  @doc "A ping on the connection of `service`."
  def ping(service), do: new(service: service, method: @control, headers: [{"type", "ping"}])

  @doc "The answer to the data frame `frame`: the same frame with `payload`."
  def answer(%Pbbp2{} = frame, payload) when is_binary(payload),
    do: %{
      frame
      | headers: frame.headers ++ [%Header{key: "biz_rt", value: "0"}],
        payload: payload
    }

  @doc "Decodes one binary frame."
  def decode(bytes) when is_binary(bytes) do
    {:ok, Pbbp2.decode(bytes)}
  rescue
    _malformed -> :error
  end

  @doc "Encodes one frame."
  def encode(%Pbbp2{} = frame), do: Pbbp2.encode(frame)
end
