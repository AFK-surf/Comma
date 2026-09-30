defmodule Comma.EmailDelivery.Postmark do
  @moduledoc """
  Production Comma login-code delivery through the shared Postmark adapter.

  Postmark does not publish an official Elixir SDK. `SalixStore.Postmark`
  isolates the provider's single JSON endpoint and intentionally disables HTTP
  retries because an interrupted response can leave message acceptance unknown.
  """

  @behaviour Comma.EmailDelivery

  # Postmark documents 422/ErrorCode 406 as an inactive/suppressed recipient.
  # Other responses are not safely recipient-scoped: for example, 401/ErrorCode
  # 10 is an invalid token and several 422 codes describe sender, account, or
  # message-stream configuration. Keep unknown failures provider-wide so a new
  # provider code cannot silently bypass the outage circuit.
  @recipient_rejection_error_codes [406]

  @impl true
  def send_login_code(email, code, opts) do
    message = Comma.EmailDelivery.render(opts[:purpose], code, opts)

    from_email()
    |> SalixStore.Postmark.send_email(
      [email],
      message.subject,
      message.text,
      html_body: message.html
    )
    |> normalize_result()
  end

  defp normalize_result(:ok), do: :ok

  defp normalize_result({:error, {:transport, _reason} = error}),
    do: {:error, error}

  defp normalize_result({:error, {:postmark, 422, error_code}})
       when error_code in @recipient_rejection_error_codes,
       do: {:error, :recipient_rejected}

  defp normalize_result({:error, _provider_or_configuration_error}),
    do: {:error, :provider_unavailable}

  defp normalize_result(_unknown_result), do: {:error, :provider_unavailable}

  defp from_email do
    :comma_core
    |> Application.get_env(:mail, [])
    |> Keyword.get(:from, "")
    |> to_string()
    |> String.trim()
  end
end
