defmodule BridgeForTeamsWeb.Dashboard.ImpersonationController do
  @moduledoc """
  Dashboard-only user impersonation. Access is limited to owner/admin members of
  the org configured by `:bridge_for_teams_web, :impersonator_org_slug`.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  require Logger

  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs}
  alias BridgeForTeams.Auth
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeamsWeb.Dashboard.Auth, as: DashAuth

  @impersonation_action "user.impersonation.started"

  @doc "GET /impersonate — render the impersonation form."
  def new(conn, params) do
    with {:ok, _org} <- authorize_impersonator(conn.assigns[:current_user]) do
      render(conn, :new,
        layout: {BridgeForTeamsWeb.Dashboard.Layouts, :root},
        error: nil,
        query: params["q"] || ""
      )
    else
      {:error, :not_configured} ->
        conn |> send_resp(404, "not found") |> halt()

      {:error, :forbidden, _org} ->
        conn
        |> put_flash(
          :error,
          Gettext.gettext(BridgeForTeamsWeb.Gettext, "You are not allowed to impersonate users.")
        )
        |> redirect(to: "/")
    end
  end

  @doc "POST /impersonate — switch the signed dashboard session to the target user."
  def create(conn, %{"impersonate" => params}) do
    case authorize_impersonator(conn.assigns[:current_user]) do
      {:ok, org} ->
        create_authorized(conn, org, params)

      {:error, :not_configured} ->
        conn |> send_resp(404, "not found") |> halt()

      {:error, :forbidden, org} ->
        record_impersonation_attempt(
          org,
          conn.assigns[:current_user],
          params,
          "denied",
          :forbidden
        )

        conn
        |> put_flash(
          :error,
          Gettext.gettext(BridgeForTeamsWeb.Gettext, "You are not allowed to impersonate users.")
        )
        |> redirect(to: "/")
    end
  end

  def create(conn, _params), do: create(conn, %{"impersonate" => %{}})

  defp create_authorized(conn, org, params) do
    case find_target_user(params) do
      {:ok, target} ->
        case Sessions.create(target, device: "dashboard impersonation") do
          {:ok, %{token: token}} ->
            record_impersonation_started(org, conn.assigns.current_user, target, params)

            if current = get_session(conn, DashAuth.session_token_key()), do: Auth.logout(current)

            conn
            |> DashAuth.put_token_in_session(token)
            |> put_flash(
              :info,
              Gettext.gettext(BridgeForTeamsWeb.Gettext, "Now impersonating %{email}.",
                email: target.email
              )
            )
            |> redirect(to: params["to"] || "/")

          {:error, reason} ->
            record_impersonation_attempt(org, conn.assigns.current_user, params, "failed", reason)

            render(conn, :new,
              layout: {BridgeForTeamsWeb.Dashboard.Layouts, :root},
              error: Gettext.gettext(BridgeForTeamsWeb.Gettext, "Could not start impersonation."),
              query: target_query(params)
            )
        end

      {:error, :not_found} ->
        record_impersonation_attempt(org, conn.assigns.current_user, params, "failed", :not_found)

        render(conn, :new,
          layout: {BridgeForTeamsWeb.Dashboard.Layouts, :root},
          error: Gettext.gettext(BridgeForTeamsWeb.Gettext, "User not found."),
          query: target_query(params)
        )
    end
  end

  defp authorize_impersonator(nil), do: {:error, :forbidden, nil}

  defp authorize_impersonator(%{id: user_id}) do
    with slug when is_binary(slug) and slug != "" <- impersonator_org_slug(),
         {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, role} <- Memberships.org_role(org.id, user_id) do
      if role in ["owner", "admin"] do
        {:ok, org}
      else
        {:error, :forbidden, org}
      end
    else
      nil -> {:error, :not_configured}
      "" -> {:error, :not_configured}
      _ -> {:error, :forbidden, nil}
    end
  end

  defp impersonator_org_slug do
    :bridge_for_teams_web
    |> Application.get_env(:impersonator_org_slug)
    |> case do
      slug when is_binary(slug) -> String.trim(slug)
      _ -> nil
    end
  end

  defp find_target_user(params) do
    case target_query(params) do
      "" ->
        {:error, :not_found}

      query ->
        if String.contains?(query, "@") do
          Accounts.get_user_by_email(query)
        else
          Accounts.get_user(query)
        end
    end
  end

  defp target_query(params) when is_map(params) do
    (params["target"] || params["email"] || params["user_id"] || "")
    |> to_string()
    |> String.trim()
  end

  defp target_query(_), do: ""

  defp record_impersonation_started(org, user, target, params) do
    case Observability.record_audit(%{
           org_id: org.id,
           actor_user_id: user.id,
           actor_label: audit_actor_label(user),
           action: @impersonation_action,
           resource_type: "user",
           resource_id: target.id,
           resource_label: "Impersonated user",
           result: "ok",
           request_id: request_id(),
           metadata:
             params
             |> impersonation_metadata()
             |> Map.put("target_found", true)
         }) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("impersonation_audit_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp record_impersonation_attempt(nil, _user, _params, _result, _reason), do: :ok
  defp record_impersonation_attempt(_org, nil, _params, _result, _reason), do: :ok

  defp record_impersonation_attempt(org, user, params, result, reason) do
    case Observability.record_write_attempt(%{
           org_id: org.id,
           actor_user_id: user.id,
           actor_label: audit_actor_label(user),
           action: @impersonation_action,
           resource_type: "user",
           resource_label: "Impersonation target",
           result: result,
           reason: reason,
           request_id: request_id(),
           surface: "impersonation",
           metadata: impersonation_metadata(params)
         }) do
      {:ok, _audit} ->
        :ok

      {:error, audit_reason} ->
        Logger.warning("impersonation_write_attempt_audit_failed reason=#{inspect(audit_reason)}")
        :ok
    end
  end

  defp impersonation_metadata(params) do
    %{
      "target_configured" => target_query(params) != "",
      "target_lookup" => target_lookup(params),
      "return_to_configured" => configured?(params["to"])
    }
  end

  defp configured?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured?(_value), do: false

  defp target_lookup(params) do
    query = target_query(params)

    cond do
      query == "" -> "missing"
      String.contains?(query, "@") -> "email"
      true -> "user_id"
    end
  end

  defp audit_actor_label(user) do
    cond do
      is_binary(user.email) and user.email != "" -> user.email
      is_binary(user.name) and user.name != "" -> user.name
      true -> user.id
    end
  end

  defp request_id do
    case Logger.metadata()[:request_id] do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      _ -> Ecto.UUID.generate()
    end
  end
end
