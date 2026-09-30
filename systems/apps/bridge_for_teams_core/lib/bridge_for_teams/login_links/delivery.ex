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

  @doc "Deliver the sign-in link to one recipient."
  @callback deliver_login_link(email :: String.t(), org_name :: String.t(), url :: String.t()) ::
              :ok | {:error, term()}

  @spec impl() :: module()
  def impl do
    Application.get_env(:bridge_for_teams_core, :login_link_delivery, __MODULE__.Postmark)
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

      SalixStore.Postmark.send_email(from_email(), [email], subject, body)
    end

    defp from_email do
      :bridge_for_teams_core
      |> Application.get_env(:magic_link_from_email)
      |> to_string()
      |> String.trim()
    end
  end
end
