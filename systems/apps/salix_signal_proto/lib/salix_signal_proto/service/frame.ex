defmodule SalixSignalProto.Service.Frame do
  @moduledoc """
  Codec for the frames of the Signal chat WebSocket (CRS-01 sections 7, 8
  and 10).

  Every data frame on the chat socket is a binary WebSocket frame that holds
  one serialized frame message. A frame message carries either a request or
  a response. Both sides send requests and responses, and each side chooses
  the request ids of the requests that it sends.

  Header lines are `name:value` strings on the wire. This module keeps
  decoded headers as `{name, value}` pairs with the name in lowercase and the
  value trimmed of white space; the first `:` separates the name from the
  value (CRS-01 section 7.2, client rules). In a request, a line without `:`
  is dropped. A response must satisfy the client rules of CRS-01 section
  7.3.1, or `decode/1` reports it as invalid for its request id.

  All string fields are decoded as bytes, so a field that is not valid UTF-8
  does not make the whole frame unreadable.
  """

  defmodule RequestMessage do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:verb, 1, optional: true, type: :bytes)
    field(:path, 2, optional: true, type: :bytes)
    field(:body, 3, optional: true, type: :bytes)
    field(:id, 4, optional: true, type: :uint64)
    field(:headers, 5, repeated: true, type: :bytes)
  end

  defmodule ResponseMessage do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:id, 1, optional: true, type: :uint64)
    field(:status, 2, optional: true, type: :uint32)
    field(:message, 3, optional: true, type: :bytes)
    field(:body, 4, optional: true, type: :bytes)
    field(:headers, 5, repeated: true, type: :bytes)
  end

  defmodule FrameMessage do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:type, 1, optional: true, type: :int32)
    field(:request, 2, optional: true, type: SalixSignalProto.Service.Frame.RequestMessage)
    field(:response, 3, optional: true, type: SalixSignalProto.Service.Frame.ResponseMessage)
  end

  defmodule Request do
    @moduledoc """
    A request on the chat socket, in either direction. A decoded request can
    lack its verb, path or id; such a server request is unknown or dropped
    (CRS-01 section 7.2, client rules).
    """
    @enforce_keys [:verb, :path, :id]
    defstruct [:verb, :path, :id, body: nil, headers: []]

    @type t :: %__MODULE__{
            verb: binary() | nil,
            path: binary() | nil,
            id: non_neg_integer() | nil,
            body: binary() | nil,
            headers: [{binary(), binary()}]
          }
  end

  defmodule Response do
    @moduledoc "A response on the chat socket, in either direction."
    @enforce_keys [:id, :status]
    defstruct [:id, :status, message: nil, body: nil, headers: []]

    @type t :: %__MODULE__{
            id: non_neg_integer(),
            status: non_neg_integer(),
            message: binary() | nil,
            body: binary() | nil,
            headers: [{binary(), binary()}]
          }
  end

  @type server_event ::
          {:incoming_message, envelope :: binary(), server_delivery_ms :: non_neg_integer()}
          | :queue_empty
          | :ignore

  @kind_request 1
  @kind_response 2
  @max_u64 0xFFFF_FFFF_FFFF_FFFF
  @max_request_id @max_u64

  @reasons %{
    200 => "OK",
    204 => "No Content",
    400 => "Bad Request",
    404 => "Not Found",
    500 => "Internal Server Error"
  }

  @doc "The largest request id. Ids wrap to 0 after it (CRS-01 section 8)."
  def max_request_id, do: @max_request_id

  @doc "The request id that follows `id` on one connection."
  def next_request_id(@max_request_id), do: 0
  def next_request_id(id) when is_integer(id) and id >= 0, do: id + 1

  @doc """
  Encodes a request as a complete frame message (kind 1).

  Header pairs are written as `name:value`, in the order given. The body is
  left out when it is `nil`.
  """
  @spec encode_request(Request.t()) :: binary()
  def encode_request(%Request{} = request) do
    inner = %RequestMessage{
      verb: request.verb,
      path: request.path,
      body: request.body,
      id: request.id,
      headers: Enum.map(request.headers, &header_line/1)
    }

    FrameMessage.encode(%FrameMessage{type: @kind_request, request: inner})
  end

  @doc """
  Encodes a response as a complete frame message (kind 2).

  The reason phrase is required on the wire when the server receives a
  response (CRS-01 section 7.3, rule 1). When `message` is `nil`, the
  canonical phrase of the status is used.
  """
  @spec encode_response(Response.t()) :: binary()
  def encode_response(%Response{} = response) do
    inner = %ResponseMessage{
      id: response.id,
      status: response.status,
      message: response.message || reason_phrase(response.status),
      body: response.body,
      headers: Enum.map(response.headers, &header_line/1)
    }

    FrameMessage.encode(%FrameMessage{type: @kind_response, response: inner})
  end

  @doc """
  Decodes one frame message.

  A frame is a request only if its kind is 1 and it has a request and no
  response; it is a response only if its kind is 2 and it has a response and
  no request (CRS-01 section 7.1). Anything else, and a response without a
  request id, is `{:error, :malformed}`: the client drops it and keeps the
  socket open.

  A response with a request id but a missing status, a status outside 100 to
  999, or a header line that breaks the client rules of CRS-01 section 7.3.1
  is `{:error, {:invalid_response, id}}`: it fails the matched request. A
  request is returned whatever its verb, path or id; `server_event/1`
  classifies it.
  """
  @spec decode(binary()) ::
          {:ok, Request.t() | Response.t()}
          | {:error, :malformed | {:invalid_response, non_neg_integer()}}
  def decode(bytes) when is_binary(bytes) do
    bytes |> safe_decode() |> classify()
  end

  defp safe_decode(bytes) do
    {:ok, FrameMessage.decode(bytes)}
  rescue
    _ -> :error
  end

  defp classify({:ok, %FrameMessage{type: @kind_request, request: %RequestMessage{} = r} = f})
       when is_nil(f.response) do
    {:ok,
     %Request{
       verb: r.verb,
       path: r.path,
       id: r.id,
       body: r.body,
       headers: parse_header_lines(r.headers)
     }}
  end

  defp classify({:ok, %FrameMessage{type: @kind_response, response: %ResponseMessage{} = r} = f})
       when is_nil(f.request) and is_integer(r.id) do
    with true <- is_integer(r.status) and r.status in 100..999,
         {:ok, headers} <- response_headers(r.headers) do
      {:ok,
       %Response{id: r.id, status: r.status, message: r.message, body: r.body, headers: headers}}
    else
      _ -> {:error, {:invalid_response, r.id}}
    end
  end

  defp classify(_), do: {:error, :malformed}

  @doc """
  Classifies a request that the server sent on an authenticated chat socket
  (CRS-01 sections 7.2 and 10).

  Only a request with a request id and exactly `PUT /api/v1/message` or
  `PUT /api/v1/queue/empty` is recognized; anything else is `:ignore`. A
  pushed message carries one envelope (empty when the body is absent); its
  delivery time is the last `x-signal-timestamp` header whose value is a
  decimal unsigned 64-bit integer, and 0 when none is.
  """
  @spec server_event(Request.t()) :: server_event()
  def server_event(%Request{id: nil}), do: :ignore

  def server_event(%Request{verb: "PUT", path: "/api/v1/message"} = request) do
    {:incoming_message, request.body || <<>>, delivery_timestamp(request.headers)}
  end

  def server_event(%Request{verb: "PUT", path: "/api/v1/queue/empty"}), do: :queue_empty
  def server_event(%Request{}), do: :ignore

  @doc "Returns the value of the first header named `name` (lowercase), or `nil`."
  @spec header([{binary(), binary()}], binary()) :: binary() | nil
  def header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  @doc """
  Parses one `name:value` header line: the first `:` separates them, the
  name is lowercased (ASCII) and white space around the value is removed.
  """
  @spec parse_header_line(binary()) :: {:ok, {binary(), binary()}} | :error
  def parse_header_line(line) do
    case :binary.split(line, ":") do
      [name, value] -> {:ok, {ascii_downcase(name), String.trim(value)}}
      [_] -> :error
    end
  end

  @doc "The canonical HTTP reason phrase used when answering server requests."
  @spec reason_phrase(non_neg_integer()) :: binary()
  def reason_phrase(status), do: Map.get(@reasons, status, "Unknown")

  defp parse_header_lines(lines) do
    for line <- lines, {:ok, pair} <- [parse_header_line(line)], do: pair
  end

  # CRS-01 section 7.3.1: every header line of a response needs `:`, a name
  # that is an HTTP token, and a value without control bytes other than
  # horizontal tab once the white space around it is removed.
  defp response_headers(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      with {:ok, {name, value}} <- parse_header_line(line),
           true <- token?(name) and not control_byte?(value) do
        {:cont, {:ok, [{name, value} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      :error -> :error
    end
  end

  defp token?(name), do: name != "" and Enum.all?(:binary.bin_to_list(name), &tchar?/1)

  defp tchar?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9, do: true
  defp tchar?(c), do: c in ~c"!#$%&'*+-.^_`|~"

  defp control_byte?(value),
    do: Enum.any?(:binary.bin_to_list(value), &((&1 < 0x20 and &1 != ?\t) or &1 == 0x7F))

  defp ascii_downcase(name),
    do: for(<<c <- name>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

  defp header_line({name, value}), do: name <> ":" <> value

  defp delivery_timestamp(headers) do
    parsed =
      for {"x-signal-timestamp", value} <- headers, ms <- List.wrap(parse_u64(value)), do: ms

    List.last(parsed, 0)
  end

  # A decimal unsigned 64-bit integer, optionally with a leading `+`.
  defp parse_u64("+" <> digits), do: parse_digits(digits)
  defp parse_u64(digits), do: parse_digits(digits)

  defp parse_digits(digits) do
    if digits != "" and Enum.all?(:binary.bin_to_list(digits), &(&1 in ?0..?9)) do
      value = String.to_integer(digits)
      if value <= @max_u64, do: value
    end
  end
end
