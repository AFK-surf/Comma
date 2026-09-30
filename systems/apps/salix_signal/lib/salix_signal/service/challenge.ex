defmodule SalixSignal.Service.Challenge do
  @moduledoc """
  Answers to abuse challenges (CRS-01 section 13, CRS-15 section 5).

  A request that gets 428 carries a token and the proofs the server accepts
  (`SalixSignal.Service.Response.outcome/1`). A device that fetches its
  messages over the socket and has no push token cannot receive push
  challenges, so its only proof is a captcha that a human solves on the
  challenge page. The captcha page ends at a `signalcaptcha://` URL; the
  value to submit is the text after that prefix.

  `submit/3` sends the answer with `PUT /v1/challenge`. It retries after a
  5xx other than 508, and after a lost or missing socket, with exponential
  backoff, at most `:retries` times, as the service's API description
  allows. It sleeps between attempts, so call
  it from a task, not from the account actor.
  """

  alias SalixSignal.Service.{Backoff, Chat, Response}

  @captcha_url_prefix "signalcaptcha://"
  @transient [:not_connected, :disconnected, :timeout]
  @challenge_page %{
    production: "https://signalcaptchas.org/challenge/generate.html",
    staging: "https://signalcaptchas.org/staging/challenge/generate.html"
  }

  @type answer :: %{required(String.t()) => String.t()}
  @type result ::
          :ok
          | {:error,
             :invalid
             | :not_accepted
             | :rejected
             | {:rate_limited, non_neg_integer() | nil}
             | {:unavailable, term()}
             | {:http_error, non_neg_integer()}}

  @doc "The page where a human solves a rate-limit captcha (CRS-01 section 2)."
  @spec challenge_page(:production | :staging) :: String.t()
  def challenge_page(environment), do: Map.fetch!(@challenge_page, environment)

  @doc "The answer to a captcha challenge with `token` from the 428 body."
  @spec captcha_answer(String.t(), String.t()) :: answer()
  def captcha_answer(token, captcha) when is_binary(token) and is_binary(captcha) do
    %{"type" => "captcha", "token" => token, "captcha" => captcha_value(captcha)}
  end

  @doc "The answer to a push challenge with the value the push delivered."
  @spec push_answer(String.t()) :: answer()
  def push_answer(challenge) when is_binary(challenge) do
    %{"type" => "rateLimitPushChallenge", "challenge" => challenge}
  end

  @doc "The captcha value: the text after `signalcaptcha://`, or the input when it lacks that prefix."
  @spec captcha_value(String.t()) :: String.t()
  def captcha_value(@captcha_url_prefix <> value), do: String.trim(value)
  def captcha_value(value), do: String.trim(value)

  @doc """
  Sends `answer` with `PUT /v1/challenge` on `chat`.

  `:ok` means the proof was accepted and the original operation may be
  retried. `:invalid` is a malformed request (400); `:not_accepted` is a
  captcha the server did not accept (428).
  """
  @spec submit(GenServer.server(), answer(), keyword()) :: result()
  def submit(chat, answer, opts \\ []) do
    retries = Keyword.get(opts, :retries, 3)
    backoff = Keyword.get(opts, :backoff, [])
    attempt(chat, answer, 0, retries, backoff)
  end

  @doc """
  Asks the server to send a push challenge to the account's primary device
  (`POST /v1/challenge/push`). `{:error, :no_push_token}` means the primary
  device has no push token.
  """
  @spec request_push(GenServer.server()) ::
          :ok
          | {:error,
             :no_push_token
             | {:rate_limited, non_neg_integer() | nil}
             | {:http_error, non_neg_integer()}
             | term()}
  def request_push(chat) do
    case Chat.request(chat, "POST", "/v1/challenge/push") do
      {:ok, %Response{status: 404}} ->
        {:error, :no_push_token}

      {:ok, response} ->
        case Response.outcome(response) do
          :ok -> :ok
          {:rate_limited, seconds} -> {:error, {:rate_limited, seconds}}
          _ -> {:error, {:http_error, response.status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempt(chat, answer, n, retries, backoff) do
    result =
      case Chat.request(chat, "PUT", "/v1/challenge", json: answer) do
        {:ok, %Response{status: 400}} -> {:error, :invalid}
        {:ok, %Response{status: 428}} -> {:error, :not_accepted}
        {:ok, response} -> classify(Response.outcome(response), response)
        {:error, reason} when reason in @transient -> {:retry, reason}
        {:error, reason} -> {:error, {:unavailable, reason}}
      end

    case result do
      {:retry, _reason} when n < retries ->
        Process.sleep(Backoff.delay_ms(n, backoff))
        attempt(chat, answer, n + 1, retries, backoff)

      {:retry, reason} ->
        {:error, {:unavailable, reason}}

      final ->
        final
    end
  end

  defp classify(:ok, _response), do: :ok
  defp classify({:rate_limited, seconds}, _response), do: {:error, {:rate_limited, seconds}}
  defp classify(:rejected, _response), do: {:error, :rejected}
  defp classify({:server_error, status}, _response), do: {:retry, {:status, status}}
  defp classify(_outcome, response), do: {:error, {:http_error, response.status}}
end
