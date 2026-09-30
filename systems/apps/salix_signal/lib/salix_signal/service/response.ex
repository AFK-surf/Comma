defmodule SalixSignal.Service.Response do
  @moduledoc """
  A response from a Signal service, from the chat socket or plain HTTP, and
  its classification (CRS-01 sections 12 to 14, CRS-15 sections 2, 5 and 6).

  Header names are lowercase. `body` is `""` when the response has none.
  """

  @max_retry_after_s 3_600

  @enforce_keys [:status]
  defstruct [:status, message: nil, headers: [], body: ""]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          message: String.t() | nil,
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type challenge :: %{
          token: String.t() | nil,
          options: [:captcha | :push_challenge],
          retry_after: non_neg_integer() | nil
        }

  @type outcome ::
          :ok
          | {:challenge_required, challenge()}
          | {:rate_limited, retry_after_seconds :: non_neg_integer() | nil}
          | :unauthorized
          | :forbidden
          | :client_deprecated
          | :use_websocket
          | :rejected
          | {:server_error, non_neg_integer()}
          | {:http_error, non_neg_integer()}

  @doc """
  Classifies a response.

    * 2xx: `:ok`.
    * 428: the anti-abuse system wants a captcha or push proof before it
      accepts more requests. The body gives a token and the allowed proofs;
      unknown proofs are dropped.
    * 429: rate limited, with `Retry-After` seconds when the server knows
      when a retry can succeed.
    * 499: the client is too old or lacks a required capability.
    * 498: the request must be sent over the chat socket.
    * 508: the server rejected the request; do not retry it as is.
    * other 5xx: a server or dependency failure that a later retry can fix.

  Endpoint-specific meanings of 4xx statuses (409, 410, 423 and others) are
  left to the caller as `{:http_error, status}`.
  """
  @spec outcome(t()) :: outcome()
  def outcome(%__MODULE__{status: status}) when status in 200..299, do: :ok

  def outcome(%__MODULE__{status: 428} = response),
    do: {:challenge_required, challenge(response)}

  def outcome(%__MODULE__{status: 429} = response), do: {:rate_limited, retry_after(response)}
  def outcome(%__MODULE__{status: 401}), do: :unauthorized
  def outcome(%__MODULE__{status: 403}), do: :forbidden
  def outcome(%__MODULE__{status: 498}), do: :use_websocket
  def outcome(%__MODULE__{status: 499}), do: :client_deprecated
  def outcome(%__MODULE__{status: 508}), do: :rejected
  def outcome(%__MODULE__{status: status}) when status in 500..599, do: {:server_error, status}
  def outcome(%__MODULE__{status: status}), do: {:http_error, status}

  @doc "The value of the first header named `name` (lowercase), or `nil`."
  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: headers}, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  @doc """
  `Retry-After` in whole seconds. Only a non-negative decimal integer is
  accepted (CRS-01 section 12); any other form gives `nil`.

  A larger value than `max_retry_after_s/0` (one hour) is capped to it
  (owner decision): a wrong or hostile header cannot stop the account's
  connection or sends for longer than that. A request that the service
  still refuses after the capped wait gets a new 429 and a new wait.
  """
  @spec retry_after(t()) :: non_neg_integer() | nil
  def retry_after(response) do
    with value when is_binary(value) <- header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      min(seconds, @max_retry_after_s)
    else
      _ -> nil
    end
  end

  @doc "The longest `Retry-After` wait that Comma honours, in seconds (one hour)."
  @spec max_retry_after_s() :: pos_integer()
  def max_retry_after_s, do: @max_retry_after_s

  @doc """
  The server clock in milliseconds from `X-Signal-Timestamp`, or `nil`.

  A response without this header came from infrastructure in front of the
  service, not from the service itself (CRS-01 section 5.2).
  """
  @spec server_time_ms(t()) :: non_neg_integer() | nil
  def server_time_ms(response) do
    with value when is_binary(value) <- header(response, "x-signal-timestamp"),
         {ms, ""} when ms >= 0 <- Integer.parse(value) do
      ms
    else
      _ -> nil
    end
  end

  @doc "Decodes a JSON body."
  @spec json(t()) :: {:ok, term()} | {:error, :invalid_json}
  def json(%__MODULE__{body: body}) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp challenge(response) do
    body =
      case json(response) do
        {:ok, %{} = map} -> map
        _ -> %{}
      end

    options =
      for option <- List.wrap(body["options"]),
          atom = challenge_option(option),
          atom != nil,
          do: atom

    token = if is_binary(body["token"]), do: body["token"]
    %{token: token, options: Enum.uniq(options), retry_after: retry_after(response)}
  end

  defp challenge_option("captcha"), do: :captcha
  defp challenge_option("pushChallenge"), do: :push_challenge
  defp challenge_option(_), do: nil
end
