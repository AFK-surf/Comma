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
  verification is involved. The surface stays the send call plus two read-only
  lookups an operator uses to explain a missing email (`message_events/1`,
  `suppression/1`), isolated behind this module so a library can replace it
  later without touching callers.

  Configuration (`:salix_store` app env; wired from the config.json `email`
  section by `SalixStore.ConfigJson`):

    * `:postmark_server_token` — Postmark server API token (required)
    * `:postmark_base_url` — endpoint override so tests can mock the API
      (default `https://api.postmarkapp.com`, trailing slashes trimmed)

  Requests are NOT retried: `POST /email` is not idempotent and a transient
  failure after acceptance would double-deliver. Failures return an error
  tuple that deliberately carries no message content or recipient addresses,
  so callers can surface it to an agent without leaking the recipient list.
  Lookups return only provider classifications and timestamps: never message
  content, recipient addresses, or the provider's free-text SMTP details.
  """

  @default_base_url "https://api.postmarkapp.com"
  # Postmark caps recipients per message at 50; larger recipient lists are split.
  @max_recipients_per_message 50

  @type send_error ::
          :not_configured
          | {:postmark, status :: pos_integer(), error_code :: integer() | nil}
          | {:transport, term()}

  @type message_event :: %{
          type: String.t() | nil,
          received_at: String.t() | nil,
          bounce:
            %{type: String.t() | nil, type_code: integer() | nil, inactive: boolean() | nil} | nil
        }

  @type suppression :: %{
          reason: String.t() | nil,
          origin: String.t() | nil,
          created_at: String.t() | nil
        }

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
          {:ok, _message_id} -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  @doc """
  Send one message to one recipient and return the provider's MessageID, the
  reference `message_events/1` takes.
  """
  @spec send_message(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{message_id: String.t() | nil}} | {:error, send_error()}
  def send_message(from, recipient, subject, text_body, opts \\ [])
      when is_binary(from) and is_binary(recipient) do
    token = config_string(:postmark_server_token)

    if token == "" or String.trim(from) == "" do
      {:error, :not_configured}
    else
      case post_email(token, from, [recipient], subject, text_body, opts) do
        {:ok, message_id} -> {:ok, %{message_id: message_id}}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Delivery status of one sent message: Postmark's status and its events
  (Delivered, Transient, Bounced, ...). A Bounced event carries the bounce's
  classification. Returns `{:error, {:postmark, 422, 701}}` for an unknown
  message id.
  """
  @spec message_events(String.t()) ::
          {:ok, %{status: String.t() | nil, events: [message_event()]}} | {:error, send_error()}
  def message_events(message_id) when is_binary(message_id) do
    with {:ok, resp} <- get_json("/messages/outbound/" <> path_segment(message_id) <> "/details") do
      events =
        resp
        |> Map.get("MessageEvents")
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map(&message_event/1)

      {:ok, %{status: string_or_nil(resp["Status"]), events: events}}
    end
  end

  @doc """
  The outbound stream's suppression for `email`, or `nil` when Postmark would
  send to it. Postmark rejects a send to a suppressed address with ErrorCode 406.
  """
  @spec suppression(String.t()) :: {:ok, suppression() | nil} | {:error, send_error()}
  def suppression(email) when is_binary(email) do
    query = URI.encode_query(%{"EmailAddress" => String.trim(email)})

    with {:ok, resp} <- get_json("/message-streams/outbound/suppressions/dump?" <> query) do
      suppression =
        resp
        |> Map.get("Suppressions")
        |> List.wrap()
        |> Enum.find(&is_map/1)
        |> case do
          nil ->
            nil

          row ->
            %{
              reason: string_or_nil(row["SuppressionReason"]),
              origin: string_or_nil(row["Origin"]),
              created_at: string_or_nil(row["CreatedAt"])
            }
        end

      {:ok, suppression}
    end
  end

  defp message_event(event) do
    type = string_or_nil(event["Type"])
    %{type: type, received_at: string_or_nil(event["ReceivedAt"]), bounce: bounce(type, event)}
  end

  defp bounce("Bounced", %{"Details" => %{"BounceID" => id}})
       when is_binary(id) or is_integer(id) do
    case get_json("/bounces/" <> path_segment(to_string(id))) do
      {:ok, resp} ->
        %{
          type: string_or_nil(resp["Type"]),
          type_code: if(is_integer(resp["TypeCode"]), do: resp["TypeCode"]),
          inactive: if(is_boolean(resp["Inactive"]), do: resp["Inactive"])
        }

      {:error, _} ->
        %{type: nil, type_code: nil, inactive: nil}
    end
  end

  defp bounce(_type, _event), do: nil

  defp get_json(path) do
    token = config_string(:postmark_server_token)

    if token == "" do
      {:error, :not_configured}
    else
      case Req.get(base_url() <> path,
             headers: [{"x-postmark-server-token", token}, {"accept", "application/json"}],
             receive_timeout: 20_000,
             retry: false
           ) do
        {:ok, %{status: status, body: resp}} when status in 200..299 and is_map(resp) ->
          {:ok, resp}

        {:ok, %{status: status, body: resp}} ->
          {:error, {:postmark, status, error_code(resp)}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp message_id(%{"MessageID" => id}) when is_binary(id), do: id
  defp message_id(_resp), do: nil

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
          code when code in [nil, 0] -> {:ok, message_id(resp)}
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
    |> SystemsRuntime.get_env(key)
    |> to_string()
    |> String.trim()
  end
end
