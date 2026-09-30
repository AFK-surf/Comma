defmodule BridgeForTeamsWeb.Dashboard.OnboardingController do
  @moduledoc """
  Non-LiveView onboarding actions.

    * `POST /onboarding/restart` — reopen the first-run flow from the first
      step, available to everyone regardless of whether they completed or
      skipped it before. Non-destructive by contract
      (`BridgeForTeams.UserOnboardings.restart/1`): captured capabilities and
      profile pre-fill the wizard, and nothing a previous run produced is
      touched. Finishing or skipping exits the flow again as usual.

  Owned by slice "orgs-shell".
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.UserOnboardings

  def restart(conn, _params) do
    user = conn.assigns.current_user

    with {:ok, onboarding} <- UserOnboardings.ensure_onboarding(user.id),
         {:ok, _onboarding} <- UserOnboardings.restart(onboarding) do
      conn
      |> put_flash(
        :info,
        Gettext.gettext(
          BridgeForTeamsWeb.Gettext,
          "Onboarding restarted — your existing tasks and connections are untouched."
        )
      )
      |> redirect(to: ~p"/onboarding")
    else
      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          Gettext.gettext(
            BridgeForTeamsWeb.Gettext,
            "Could not restart onboarding. Please try again."
          )
        )
        |> redirect(to: ~p"/new-home")
    end
  end
end
