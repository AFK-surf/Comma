defmodule BridgeForTeams.TeamsMail do
  @moduledoc """
  The Comma for Teams system email sender: its own Postmark server and From
  address, and an optional Reply-To (config.json `email` section:
  `teams_postmark_server_token`, `teams_from_email`, `teams_reply_to_email`,
  wired to the `:bridge_for_teams_core` app env of the same names).

  Only fixed product templates go through it. No agent writes its subject or
  body or picks its recipients.
  """

  @doc "Whether the server token and From address are configured."
  @spec configured?() :: boolean()
  def configured?, do: env(:teams_postmark_server_token) != "" and env(:teams_from_email) != ""

  @doc "Send one message to one recipient; returns the provider's MessageID."
  @spec send_message(String.t(), String.t(), String.t()) ::
          {:ok, %{message_id: String.t() | nil}} | {:error, SalixStore.Postmark.send_error()}
  def send_message(recipient, subject, body),
    do:
      SalixStore.Postmark.send_message(
        env(:teams_from_email),
        recipient,
        subject,
        body,
        send_opts()
      )

  @doc "Send one message to several recipients (all of them in To)."
  @spec send_email([String.t()], String.t(), String.t()) ::
          :ok | {:error, SalixStore.Postmark.send_error()}
  def send_email(recipients, subject, body),
    do:
      SalixStore.Postmark.send_email(
        env(:teams_from_email),
        recipients,
        subject,
        body,
        send_opts()
      )

  @doc "Postmark's delivery status and events of one message this server sent."
  def message_events(message_id), do: SalixStore.Postmark.message_events(message_id, server())

  @doc "This server's suppression of a recipient, or `nil`."
  def suppression(email), do: SalixStore.Postmark.suppression(email, server())

  defp send_opts do
    case env(:teams_reply_to_email) do
      "" -> server()
      reply_to -> [reply_to: reply_to] ++ server()
    end
  end

  defp server, do: [server_token: env(:teams_postmark_server_token)]

  defp env(key) do
    :bridge_for_teams_core
    |> SystemsRuntime.get_env(key)
    |> to_string()
    |> String.trim()
  end
end
