defmodule SalixSignal.Account.Verification do
  @moduledoc """
  Verification sessions: proof of control of a phone number before
  registration (CRS-02 §2).

  Comma has no push token, so a new session always asks for a captcha
  (CRS-15 §5). An operator solves it once on the registration captcha page
  (`captcha_page/1`) and gives Comma the `signalcaptcha://` text. The flow of a
  captcha-only client (CRS-02 §2.7):

  1. `create/2`: the session asks for `captcha`.
  2. `submit_captcha/3`: a valid captcha empties `requested_information`, and
     `allowed_to_request_code` becomes true.
  3. `request_code/4`: the service sends a code by SMS or voice call.
  4. `submit_code/3`: a correct code sets `verified`.
  5. `SalixSignal.Account.Registration.register/4` with the session ID.

  The session requests need no account, so the transport carries no
  credentials. Each function returns the session object on success and a
  classified error otherwise; errors that come with a session object carry
  it, because it tells when the next attempt is allowed.
  """

  alias SalixSignal.Account.Transport
  alias SalixSignal.Service.{Challenge, Response}

  @captcha_page %{
    production: "https://signalcaptchas.org/registration/generate.html",
    staging: "https://signalcaptchas.org/staging/registration/generate.html"
  }

  defmodule Session do
    @moduledoc """
    The verification session object (CRS-02 §2.2). Times are seconds from
    the response; `nil` means the action is not allowed now.
    """
    @enforce_keys [:id]
    defstruct id: nil,
              next_sms: nil,
              next_call: nil,
              next_verification_attempt: nil,
              allowed_to_request_code: false,
              requested_information: [],
              verified: false

    @type t :: %__MODULE__{
            id: String.t(),
            next_sms: non_neg_integer() | nil,
            next_call: non_neg_integer() | nil,
            next_verification_attempt: non_neg_integer() | nil,
            allowed_to_request_code: boolean(),
            requested_information: [:captcha | :push_challenge],
            verified: boolean()
          }
  end

  @type error ::
          {:invalid_number, normalized :: String.t() | nil}
          | :obsolete_number_format
          | :invalid_request
          | :invalid_session_id
          | :unknown_session
          | {:captcha_rejected, Session.t() | nil}
          | {:not_ready, Session.t() | nil}
          | {:transport_unavailable, Session.t() | nil}
          | {:provider_refused, %{reason: String.t() | nil, permanent: boolean()}}
          | {:rate_limited, non_neg_integer() | nil, Session.t() | nil}
          | {:unavailable, non_neg_integer()}
          | {:http_error, non_neg_integer()}
          | {:transport, term()}

  @type result :: {:ok, Session.t()} | {:error, error()}

  @doc "The page where a human solves the registration captcha (CRS-01 §2)."
  @spec captcha_page(:production | :staging) :: String.t()
  def captcha_page(environment), do: Map.fetch!(@captcha_page, environment)

  @doc """
  Creates a session for an E.164 `number` (CRS-02 §2.3). A number that is
  not in normalized form gives `{:invalid_number, normalized}`.
  """
  @spec create(Transport.t(), String.t()) :: result()
  def create(transport, "+" <> _ = number) do
    transport
    |> Transport.request("POST", "/v1/verification/session", json: %{"number" => number})
    |> handle(fn
      %Response{status: 400} = response ->
        {:invalid_number, (Transport.json_object(response) || %{})["normalizedNumber"]}

      %Response{status: 499} ->
        :obsolete_number_format

      _other ->
        nil
    end)
  end

  @doc "Reads a session (CRS-02 §2.1)."
  @spec fetch(Transport.t(), String.t()) :: result()
  def fetch(transport, session_id) do
    with_session_path(session_id, "", fn path ->
      transport |> Transport.request("GET", path, []) |> handle(fn _ -> nil end)
    end)
  end

  @doc """
  Submits a solved captcha (CRS-02 §2.4). `captcha` is the
  `signalcaptcha://` URL or the text after that prefix.
  """
  @spec submit_captcha(Transport.t(), String.t(), String.t()) :: result()
  def submit_captcha(transport, session_id, captcha) when is_binary(captcha) do
    with_session_path(session_id, "", fn path ->
      transport
      |> Transport.request("PATCH", path, json: %{"captcha" => Challenge.captcha_value(captcha)})
      |> handle(fn
        %Response{status: 400} -> :invalid_request
        %Response{status: 403} = response -> {:captcha_rejected, session(response)}
        _other -> nil
      end)
    end)
  end

  @doc """
  Asks for a code by `:sms` or `:voice` (CRS-02 §2.5).

  Options: `:client` (default `"comma-signal"`; any value that is not `ios` and does
  not start with `android` selects the "unknown" SMS format) and
  `:languages` (list sent as `Accept-Language`).
  """
  @spec request_code(Transport.t(), String.t(), :sms | :voice, keyword()) :: result()
  def request_code(transport, session_id, channel \\ :sms, opts \\ [])
      when channel in [:sms, :voice] do
    headers =
      case Keyword.get(opts, :languages, []) do
        [] -> []
        languages -> [{"accept-language", Enum.join(languages, ",")}]
      end

    body = %{
      "transport" => Atom.to_string(channel),
      "client" => Keyword.get(opts, :client, "comma-signal")
    }

    with_session_path(session_id, "/code", fn path ->
      transport
      |> Transport.request("POST", path, json: body, headers: headers)
      |> handle(fn
        %Response{status: 400} -> :invalid_session_id
        %Response{status: 409} = response -> {:not_ready, session(response)}
        %Response{status: 418} = response -> {:transport_unavailable, session(response)}
        %Response{status: 440} = response -> provider_refused(response)
        _other -> nil
      end)
    end)
  end

  @doc """
  Submits the received code (CRS-02 §2.6). A wrong code still answers 200;
  check `verified` in the returned session.
  """
  @spec submit_code(Transport.t(), String.t(), String.t()) :: result()
  def submit_code(transport, session_id, code) when is_binary(code) do
    with_session_path(session_id, "/code", fn path ->
      transport
      |> Transport.request("PUT", path, json: %{"code" => code})
      |> handle(fn
        %Response{status: 400} -> :invalid_request
        %Response{status: 409} = response -> {:not_ready, session(response)}
        _other -> nil
      end)
    end)
  end

  # --- Responses ---

  # The session ID is base64url with padding, used in the path as returned.
  defp with_session_path(session_id, suffix, fun) do
    if is_binary(session_id) and session_id != "" and
         String.match?(session_id, ~r/\A[A-Za-z0-9_\-=]+\z/) do
      fun.("/v1/verification/session/" <> session_id <> suffix)
    else
      {:error, :invalid_session_id}
    end
  end

  defp handle({:error, reason}, _specific), do: {:error, {:transport, reason}}

  defp handle({:ok, %Response{status: 200} = response}, _specific) do
    case session(response) do
      nil -> {:error, {:http_error, 200}}
      session -> {:ok, session}
    end
  end

  defp handle({:ok, %Response{} = response}, specific) do
    {:error, specific.(response) || common_error(response)}
  end

  defp common_error(%Response{status: 404}), do: :unknown_session
  defp common_error(%Response{status: 422}), do: :invalid_request

  defp common_error(%Response{status: 429} = response),
    do: {:rate_limited, Response.retry_after(response), session(response)}

  defp common_error(response), do: Transport.error(response)

  defp provider_refused(response) do
    body = Transport.json_object(response) || %{}
    reason = if is_binary(body["reason"]), do: body["reason"]
    {:provider_refused, %{reason: reason, permanent: body["permanentFailure"] == true}}
  end

  @doc false
  # Parses a session object, or returns nil.
  @spec session(Response.t()) :: Session.t() | nil
  def session(%Response{} = response) do
    case Transport.json_object(response) do
      %{"id" => id} = body when is_binary(id) ->
        %Session{
          id: id,
          next_sms: seconds(body["nextSms"]),
          next_call: seconds(body["nextCall"]),
          next_verification_attempt: seconds(body["nextVerificationAttempt"]),
          allowed_to_request_code: body["allowedToRequestCode"] == true,
          requested_information: requested(body["requestedInformation"]),
          verified: body["verified"] == true
        }

      _ ->
        nil
    end
  end

  defp seconds(value) when is_integer(value) and value >= 0, do: value
  defp seconds(_value), do: nil

  defp requested(values) when is_list(values), do: Enum.flat_map(values, &requested_item/1)

  defp requested(_values), do: []

  defp requested_item("captcha"), do: [:captcha]
  defp requested_item("pushChallenge"), do: [:push_challenge]
  defp requested_item(_other), do: []
end
