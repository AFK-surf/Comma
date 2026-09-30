defmodule SalixStore.Postmark do
  @moduledoc """
  Minimal Postmark client shared by product email senders — agent owner
  notifications (`SalixAgent.Tools.OwnerEmail`) and the BridgeForTeams
  magic-link login (`BridgeForTeams.LoginLinks`). One server token, one
  endpoint; each caller supplies its own From address.

  Handwritten-adapter rationale (AGENTS.md external-integration rule): Postmark
  ships no official Elixir SDK, and the community options (Swoosh/Bamboo
  adapters) pull a full mailer framework in for what is a single JSON POST to
  `/email` with a server-token header — no signing, pagination, or webhook
  verification is involved. The surface stays this one call, isolated behind
  this module so a library can replace it later without touching callers.

  Configuration (`:salix_store` app env; wired from the config.json `email`
  section by `SalixStore.ConfigJson`):

    * `:postmark_server_token` — Postmark server API token (required)
    * `:postmark_base_url` — endpoint override so tests can mock the API
      (default `https://api.postmarkapp.com`, trailing slashes trimmed)

  Requests are NOT retried: `POST /email` is not idempotent and a transient
  failure after acceptance would double-deliver. Failures return an error
  tuple that deliberately carries no message content or recipient addresses,
  so callers can surface it to an agent without leaking the recipient list.
  """

  @default_base_url "https://api.postmarkapp.com"
  # Postmark caps recipients per message at 50; larger recipient lists are split.
  @max_recipients_per_message 50

  @type send_error ::
          :not_configured
          | {:postmark, status :: pos_integer(), error_code :: integer() | nil}
          | {:transport, term()}

  @doc "Whether the server token is configured (does not validate it)."
  @spec configured?() :: boolean()
  def configured?, do: config_string(:postmark_server_token) != ""

  @doc """
  Send email with a text body and optional `:html_body` and `:attachments`.
  Split recipients at the per-message cap. Return `:ok` only when Postmark accepts every message.
  """
  @spec send_email(String.t(), [String.t()], String.t(), String.t()) ::
          :ok | {:error, send_error()}
  @spec send_email(String.t(), [String.t()], String.t(), String.t(), keyword()) ::
          :ok | {:error, send_error()}
  def send_email(from, recipients, subject, text_body, opts \\ [])
      when is_binary(from) and is_list(recipients) do
    token = config_string(:postmark_server_token)

    if token == "" or String.trim(from) == "" do
      {:error, :not_configured}
    else
      recipients
      |> Enum.chunk_every(@max_recipients_per_message)
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        case post_email(token, from, chunk, subject, text_body, opts) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp post_email(token, from, recipients, subject, text_body, opts) do
    body = %{
      "From" => from,
      "To" => Enum.join(recipients, ","),
      "Subject" => subject,
      "TextBody" => text_body,
      "MessageStream" => "outbound"
    }

    body = if opts[:html_body], do: Map.put(body, "HtmlBody", opts[:html_body]), else: body
    body = if opts[:attachments], do: Map.put(body, "Attachments", opts[:attachments]), else: body

    case Req.post(base_url() <> "/email",
           json: body,
           headers: [{"x-postmark-server-token", token}, {"accept", "application/json"}],
           receive_timeout: 20_000,
           retry: false
         ) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        case error_code(resp) do
          code when code in [nil, 0] -> :ok
          code -> {:error, {:postmark, status, code}}
        end

      {:ok, %{status: status, body: resp}} ->
        {:error, {:postmark, status, error_code(resp)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp error_code(%{"ErrorCode" => code}) when is_integer(code), do: code
  defp error_code(_resp), do: nil

  defp base_url do
    case config_string(:postmark_base_url) do
      "" -> @default_base_url
      url -> String.trim_trailing(url, "/")
    end
  end

  defp config_string(key) do
    :salix_store
    |> Application.get_env(key)
    |> to_string()
    |> String.trim()
  end
end
