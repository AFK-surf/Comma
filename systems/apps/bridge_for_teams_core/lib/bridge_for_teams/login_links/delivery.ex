defmodule BridgeForTeams.LoginLinks.Delivery do
  @moduledoc """
  Email delivery seam for magic-link login (`BridgeForTeams.LoginLinks`).

  The default implementation sends through `BridgeForTeams.TeamsMail`, the
  Comma for Teams Postmark server and sender. Delivery lookups use the same
  server.

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

  @doc """
  Deliver a consolidated workspace sign-in email listing all matching organizations
  (magic links for SSO-less organizations and SSO sign-in links for SSO organizations).
  """
  @callback deliver_workspace_links(email :: String.t(), entries :: [map()]) ::
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
    def configured?, do: BridgeForTeams.TeamsMail.configured?()

    @impl true
    def deliver_login_link(email, org_name, url) do
      subject = "Sign in to #{org_name} on Comma for Teams"

      body = """
      Someone requested a sign-in link for #{org_name} on Comma for Teams using
      this email address.

      Sign in by opening this link (valid for 15 minutes, single use):

      #{url}

      If you did not request this, you can ignore this email — nobody can sign
      in without the link above.
      """

      case BridgeForTeams.TeamsMail.send_message(email, subject, body) do
        {:ok, %{message_id: message_id}} -> {:ok, %{provider_message_id: message_id}}
        {:error, _reason} = error -> error
      end
    end

    @impl true
    def deliver_workspace_links(email, entries) do
      subject = "Sign in to Comma for Teams"

      lines =
        Enum.map_join(entries, "\n\n", fn entry ->
          case entry.kind do
            :sso ->
              "#{entry.org_name} (#{entry.org_slug}) — Sign in with SSO:\n#{entry.url}"

            :magic_link ->
              "#{entry.org_name} (#{entry.org_slug}) — One-time sign-in link (valid for 15 minutes):\n#{entry.url}"
          end
        end)

      body = """
      Someone requested sign-in links for your Comma for Teams organizations using
      this email address.

      #{lines}

      If you did not request this, you can ignore this email.
      """

      case BridgeForTeams.TeamsMail.send_message(email, subject, body) do
        {:ok, %{message_id: message_id}} -> {:ok, %{provider_message_id: message_id}}
        {:error, _reason} = error -> error
      end
    end

    @impl true
    def message_events(provider_message_id),
      do: BridgeForTeams.TeamsMail.message_events(provider_message_id)

    @impl true
    def recipient_suppression(email), do: BridgeForTeams.TeamsMail.suppression(email)
  end
end
