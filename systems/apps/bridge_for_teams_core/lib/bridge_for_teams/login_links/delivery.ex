defmodule BridgeForTeams.LoginLinks.Delivery do
  @moduledoc """
  Email delivery seam for magic-link login (`BridgeForTeams.LoginLinks`).

  The default implementation sends through the shared Postmark client
  (`SalixStore.Postmark`) from the dedicated magic-link From address
  (config.json `email.magic_link_from_email` →
  `:bridge_for_teams_core, :magic_link_from_email`) — the same Postmark
  server token as agent owner notifications, a different sender.

  Tests inject `BridgeForTeams.LoginLinks.Delivery.Fake` via

      config :bridge_for_teams_core, :login_link_delivery, BridgeForTeams.LoginLinks.Delivery.Fake
  """

  @doc "Whether magic-link email can be sent at all (token + From configured)."
  @callback configured?() :: boolean()

  @doc """
  Deliver the sign-in link to one recipient. On acceptance return the
  provider's message reference, which `message_events/1` looks up later.
  """
  @callback deliver_login_link(email :: String.t(), org_name :: String.t(), url :: String.t()) ::
              {:ok, %{provider_message_id: String.t() | nil}} | {:error, term()}

  @doc "Provider delivery status and events (delivered, bounced, ...) of one accepted message."
  @callback message_events(provider_message_id :: String.t()) ::
              {:ok, %{status: String.t() | nil, events: [map()]}} | {:error, term()}

  @doc "The provider's suppression of a recipient (`nil` when not suppressed)."
  @callback recipient_suppression(email :: String.t()) :: {:ok, map() | nil} | {:error, term()}

  @spec impl() :: module()
  def impl do
    SystemsRuntime.get_env(:bridge_for_teams_core, :login_link_delivery, __MODULE__.Postmark)
  end

  defmodule Postmark do
    @moduledoc false
    @behaviour BridgeForTeams.LoginLinks.Delivery

    @impl true
    def configured?, do: SalixStore.Postmark.configured?() and from_email() != ""

    @impl true
    def deliver_login_link(email, org_name, url) do
      subject = "Sign in to #{org_name} on Bridge For Teams"

      body = """
      Someone requested a sign-in link for #{org_name} on Bridge For Teams using
      this email address.

      Sign in by opening this link (valid for 15 minutes, single use):

      #{url}

      If you did not request this, you can ignore this email — nobody can sign
      in without the link above.
      """

      case SalixStore.Postmark.send_message(from_email(), email, subject, body) do
        {:ok, %{message_id: message_id}} -> {:ok, %{provider_message_id: message_id}}
        {:error, _reason} = error -> error
      end
    end

    @impl true
    def message_events(provider_message_id),
      do: SalixStore.Postmark.message_events(provider_message_id)

    @impl true
    def recipient_suppression(email), do: SalixStore.Postmark.suppression(email)

    defp from_email do
      :bridge_for_teams_core
      |> SystemsRuntime.get_env(:magic_link_from_email)
      |> to_string()
      |> String.trim()
    end
  end
end
