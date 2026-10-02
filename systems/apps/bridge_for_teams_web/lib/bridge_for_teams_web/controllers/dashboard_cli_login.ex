defmodule BridgeForTeamsWeb.DashboardCLILogin do
  @moduledoc """
  The BFT CLI device-login approval page (`/cli/device-login/:user_code`) for
  `DashboardAPIController`.

  Only a user who owns or administers at least one organization may read,
  approve or deny a request, and an approval may grant only organizations that
  user manages (`BridgeForTeams.CLI.Login` checks the list again). A request
  that has passed its expiry is marked expired when it is read or changed.
  Every call makes a fixed number of queries.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.CLI.Login
  alias BridgeForTeams.Orgs

  @doc """
  The request (nil when no request has this code) and the orgs the user may
  grant. The key is `request` because the response sanitizer redacts any
  `authorization` key.
  """
  def show(user, user_code) do
    with {:ok, orgs} <- manageable_orgs(user) do
      {:ok, payload(load(user_code), orgs)}
    end
  end

  def approve(user, user_code, params) do
    with {:ok, orgs} <- manageable_orgs(user),
         {:ok, org_ids} <- org_ids(params) do
      user_code
      |> Login.approve_device_authorization(user, org_ids)
      |> result(orgs)
    end
  end

  def deny(user, user_code) do
    with {:ok, orgs} <- manageable_orgs(user) do
      user_code
      |> Login.cancel_device_authorization(user)
      |> result(orgs)
    end
  end

  @doc "The refusal for a user who manages no organization."
  def forbidden,
    do:
      {:error, 403, "forbidden",
       gettext("You do not have permission to approve CLI login requests."), %{}}

  defp manageable_orgs(user) do
    case Orgs.list_manageable_orgs_for_user(user.id) do
      [] -> forbidden()
      orgs -> {:ok, orgs}
    end
  end

  defp org_ids(%{"org_ids" => [_ | _] = ids}) do
    if Enum.all?(ids, &is_binary/1), do: {:ok, ids}, else: org_ids(%{})
  end

  defp org_ids(_params),
    do: {:error, 422, "missing_org_grants", gettext("Select at least one organization."), %{}}

  defp load(user_code) do
    case Login.get_device_authorization(user_code) do
      {:ok, authorization} -> authorization
      {:error, :not_found} -> nil
    end
  end

  defp result({:ok, authorization}, orgs), do: {:ok, payload(authorization, orgs)}
  defp result({:error, :forbidden}, _orgs), do: forbidden()

  defp result({:error, :not_found}, _orgs),
    do:
      {:error, 404, "cli_login_not_found", gettext("This CLI login request was not found."), %{}}

  defp result({:error, :missing_org_grants}, _orgs), do: org_ids(%{})

  defp result({:error, status}, _orgs) when status in ~w(cancelled consumed expired),
    do: {:error, 409, "cli_login_#{status}", status_message(status), %{}}

  defp result(_error, _orgs),
    do:
      {:error, 409, "cli_login_not_pending", gettext("Could not update this CLI login request."),
       %{}}

  defp status_message("cancelled"), do: gettext("This CLI login was already cancelled.")
  defp status_message("consumed"), do: gettext("This CLI login was already completed.")
  defp status_message("expired"), do: gettext("This CLI login has expired.")

  defp payload(authorization, orgs) do
    %{"request" => public_request(authorization), "orgs" => Enum.map(orgs, &org/1)}
  end

  defp public_request(nil), do: nil

  defp public_request(authorization) do
    %{
      "user_code" => authorization.user_code,
      "status" => authorization.status,
      "client_name" => authorization.client_name,
      "created_at" => authorization.created_at,
      "expires_at" => authorization.expires_at,
      "granted_orgs" => for(%{org: %{} = org} <- authorization.org_grants || [], do: org(org))
    }
  end

  defp org(org), do: %{"id" => org.id, "slug" => org.slug, "name" => org.name}
end
