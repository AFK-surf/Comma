defmodule SalixSignalProto.ContactDiscovery.Lookup do
  @moduledoc """
  Contact discovery lookup messages (CRS-11 §6) and the classification of
  the enclave's WebSocket close codes (§7).

  The client request is a proto3 message:

  | Field | Wire type | Content |
  | --- | --- | --- |
  | 1 | 2 | ACI and access-key pairs: 32-byte records, ACI UUID (16) then access key (16) |
  | 2 | 2 | previous numbers: 8-byte big-endian E.164 values |
  | 3 | 2 | new numbers: same encoding |
  | 6 | 2 | token from a previous lookup |
  | 7 | 0 | token acknowledgement (the second client message only) |

  The server response has field 1 (40-byte result records: E.164 (8), PNI
  (16), ACI (16)), field 3 (the rate-limit token of the first response) and
  field 4 (permits used). Later responses merge into the earlier one with
  protobuf merge rules.
  """

  alias __MODULE__.Wire

  @record_bytes 40
  @zero_uuid <<0::128>>

  @typedoc "An E.164 number as a string with a leading `+`, for example `+14155550100`."
  @type e164 :: String.t()

  @typedoc "A lookup result. `aci` is nil unless the request proved the ACI's access key."
  @type result :: %{pni: <<_::128>>, aci: <<_::128>> | nil}

  defmodule Response do
    @moduledoc "A decoded (or merged) server response."
    defstruct records: "", token: nil, permits_used: nil

    @type t :: %__MODULE__{
            records: binary(),
            token: binary() | nil,
            permits_used: integer() | nil
          }
  end

  @doc """
  Encodes an E.164 number (`+` then 1 to 15 digits, not zero) as the
  8-byte big-endian value of its digits (§6.1).
  """
  @spec encode_e164(e164()) :: {:ok, <<_::64>>} | {:error, :invalid_number}
  def encode_e164("+" <> digits) when byte_size(digits) in 1..15 do
    if digits =~ ~r/\A[0-9]+\z/ do
      case String.to_integer(digits) do
        0 -> {:error, :invalid_number}
        value -> {:ok, <<value::unsigned-big-64>>}
      end
    else
      {:error, :invalid_number}
    end
  end

  def encode_e164(_number), do: {:error, :invalid_number}

  @doc "Decodes an 8-byte E.164 value to `+<digits>`; zero is `nil`."
  @spec decode_e164(<<_::64>>) :: e164() | nil
  def decode_e164(<<0::64>>), do: nil
  def decode_e164(<<value::unsigned-big-64>>), do: "+" <> Integer.to_string(value)

  @doc """
  Encodes the first client message (§6.1).

  Options: `:new_numbers` (E.164 strings not sent before), `:previous_numbers`
  (numbers of the previous full lookup; sent only with a token), `:token`
  (the stored token, or nil) and `:aci_access_keys` (a list of
  `{aci_uuid_bytes, access_key}` pairs, 16 bytes each). A token is sent only
  together with previous numbers (§6.4).
  """
  @spec encode_request(keyword()) :: {:ok, binary()} | {:error, :invalid_number | :invalid_pair}
  def encode_request(opts) do
    token = Keyword.get(opts, :token)
    previous = if token in [nil, ""], do: [], else: Keyword.get(opts, :previous_numbers, [])
    token = if previous == [], do: nil, else: token

    with {:ok, pairs} <- encode_pairs(Keyword.get(opts, :aci_access_keys, [])),
         {:ok, previous} <- encode_numbers(previous),
         {:ok, new} <- encode_numbers(Keyword.get(opts, :new_numbers, [])) do
      {:ok,
       Wire.Request.encode(%Wire.Request{
         aci_access_keys: pairs,
         previous_numbers: previous,
         new_numbers: new,
         token: token || ""
       })}
    end
  end

  @doc "The second client message: field 7 (token acknowledgement) = true, `38 01`."
  @spec token_ack() :: binary()
  def token_ack, do: Wire.Request.encode(%Wire.Request{token_ack: true})

  defp encode_pairs(pairs) do
    if Enum.all?(pairs, &match?({<<_::binary-size(16)>>, <<_::binary-size(16)>>}, &1)),
      do: {:ok, Enum.map(pairs, fn {aci, key} -> [aci, key] end) |> IO.iodata_to_binary()},
      else: {:error, :invalid_pair}
  end

  defp encode_numbers(numbers) do
    Enum.reduce_while(numbers, {:ok, []}, fn number, {:ok, acc} ->
      case encode_e164(number) do
        {:ok, bytes} -> {:cont, {:ok, [acc, bytes]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      error -> error
    end
  end

  @doc """
  Decodes one server response. Unknown fields are skipped. Returns
  `{:error, :malformed}` for bytes that are not a valid message.
  """
  @spec decode_response(binary()) :: {:ok, Response.t()} | {:error, :malformed}
  def decode_response(bytes) when is_binary(bytes), do: merge_response(%Response{}, bytes)

  @doc """
  Decodes `bytes` as a response and merges it into `response` with protobuf
  merge rules: a later scalar or bytes field replaces the earlier value.
  """
  @spec merge_response(Response.t(), binary()) :: {:ok, Response.t()} | {:error, :malformed}
  def merge_response(%Response{} = response, bytes) when is_binary(bytes) do
    wire = Wire.Response.decode(bytes)

    {:ok,
     %Response{
       records: if(wire.records == "", do: response.records, else: wire.records),
       token: if(wire.token == "", do: response.token, else: wire.token),
       permits_used:
         if(wire.permits_used == 0, do: response.permits_used, else: wire.permits_used)
     }}
  rescue
    Protobuf.DecodeError -> {:error, :malformed}
  end

  @doc """
  The token of the first response (§6.2): it must be present and not empty.
  """
  @spec token(Response.t()) :: {:ok, binary()} | {:error, :missing_token}
  def token(%Response{token: token}) when is_binary(token) and token != "", do: {:ok, token}
  def token(%Response{}), do: {:error, :missing_token}

  @doc """
  The results of a final response (§6.2), keyed by E.164 string. The
  records field must be a multiple of 40 bytes. A record with E.164 zero is
  skipped; an all-zero PNI means "not found" (the number maps to nil); an
  all-zero ACI means the ACI was not returned.
  """
  @spec results(Response.t()) :: {:ok, %{e164() => result() | nil}} | {:error, :malformed}
  def results(%Response{records: records}) when rem(byte_size(records), @record_bytes) == 0 do
    results =
      for <<e164::binary-size(8), pni::binary-size(16), aci::binary-size(16) <- records>>,
          number = decode_e164(e164),
          number != nil,
          into: %{} do
        cond do
          pni == @zero_uuid -> {number, nil}
          aci == @zero_uuid -> {number, %{pni: pni, aci: nil}}
          true -> {number, %{pni: pni, aci: aci}}
        end
      end

    {:ok, results}
  end

  def results(%Response{}), do: {:error, :malformed}

  @doc """
  Classifies a WebSocket close from the enclave (§6.4 and §7):

    * 1000: `:done`
    * 4003: `{:error, :invalid_argument}`
    * 4008 with reason `{"retry_after": N}`: `{:error, {:rate_limited, N}}`;
      an unparsable reason is `{:error, :protocol_error}`
    * 4013, 4014: `{:error, {:unavailable, code}}`
    * 4101: `{:error, :invalid_token}`
    * any other code: `{:error, :protocol_error}`
  """
  @spec close(non_neg_integer(), binary()) ::
          :done
          | {:error,
             :invalid_argument
             | {:rate_limited, non_neg_integer()}
             | {:unavailable, 4013 | 4014}
             | :invalid_token
             | :protocol_error}
  def close(1000, _reason), do: :done
  def close(4003, _reason), do: {:error, :invalid_argument}

  def close(4008, reason) do
    case JSON.decode(reason) do
      {:ok, %{"retry_after" => seconds}} when is_integer(seconds) and seconds >= 0 ->
        {:error, {:rate_limited, seconds}}

      _ ->
        {:error, :protocol_error}
    end
  end

  def close(code, _reason) when code in [4013, 4014], do: {:error, {:unavailable, code}}
  def close(4101, _reason), do: {:error, :invalid_token}
  def close(_code, _reason), do: {:error, :protocol_error}
end
