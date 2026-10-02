defmodule BridgeForTeamsWeb.CLIAuthController do
  @moduledoc """
  Dashboard-to-CLI login handoff endpoints.

  The CLI starts device login, the dashboard approves or cancels it (see
  `BridgeForTeamsWeb.DashboardCLILogin`), and the CLI receives a separate bearer
  session used by the `/v1/cli/*` API wrapper endpoints.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeamsWeb.{JSON, ProjectScope}

  def start_device_authorization(conn, params) do
    case CLILogin.start_device_authorization(%{
           client_name: params["client_name"],
           created_by_ip: remote_ip(conn)
         }) do
      {:ok,
       %{
         device_code: device_code,
         authorization: authorization,
         expires_in_seconds: expires_in_seconds,
         interval_seconds: interval_seconds
       }} ->
        verification_uri = dashboard_base_url(conn) <> ~p"/cli/device-login"

        verification_uri_complete =
          dashboard_base_url(conn) <> ~p"/cli/device-login/#{authorization.user_code}"

        send_ok(conn, %{
          "mode" => "auth_device_start",
          "device_code" => device_code,
          "user_code" => authorization.user_code,
          "verification_uri" => verification_uri,
          "verification_uri_complete" => verification_uri_complete,
          "expires_at" => DateTime.to_iso8601(authorization.expires_at),
          "expires_in_seconds" => expires_in_seconds,
          "interval_seconds" => interval_seconds
        })

      {:error, _reason} ->
        send_error(conn, 500, "cli_device_login_failed", "Could not start CLI device login.", %{})
    end
  end

  def poll_device_authorization(conn, %{"device_code" => device_code})
      when is_binary(device_code) and device_code != "" do
    case CLILogin.poll_device_authorization(device_code) do
      {:ok, %{status: "approved"} = result} ->
        send_ok(conn, %{
          "mode" => "auth_device_poll",
          "status" => "approved",
          "token" => Map.fetch!(result, :token),
          "token_type" => "bearer",
          "expires_at" => DateTime.to_iso8601(result.session.expires_at),
          "expires_in_seconds" => result.expires_in_seconds,
          "granted_orgs" => orgs_json(Map.get(result, :granted_orgs, []))
        })

      {:ok, %{status: status, authorization: authorization} = result} ->
        send_ok(conn, %{
          "mode" => "auth_device_poll",
          "status" => status,
          "user_code" => authorization.user_code,
          "expires_at" => DateTime.to_iso8601(authorization.expires_at),
          "interval_seconds" => Map.get(result, :interval_seconds)
        })

      {:error, :invalid_device_code} ->
        send_error(conn, 401, "invalid_device_code", "CLI device code is invalid.", %{})

      {:error, _reason} ->
        send_error(conn, 500, "cli_device_poll_failed", "Could not poll CLI device login.", %{})
    end
  end

  def poll_device_authorization(conn, _params) do
    send_error(conn, 400, "missing_device_code", "Pass a CLI device code.", %{})
  end

  def start_org_grant_authorization(conn, params) do
    session = Map.fetch!(conn.assigns, :current_cli_session)

    case CLILogin.start_session_org_grant_authorization(session, %{
           client_name: params["client_name"],
           created_by_ip: remote_ip(conn)
         }) do
      {:ok,
       %{
         device_code: device_code,
         authorization: authorization,
         expires_in_seconds: expires_in_seconds,
         interval_seconds: interval_seconds
       }} ->
        verification_uri = dashboard_base_url(conn) <> ~p"/cli/device-login"

        verification_uri_complete =
          dashboard_base_url(conn) <> ~p"/cli/device-login/#{authorization.user_code}"

        send_ok(conn, %{
          "mode" => "auth_org_grant_start",
          "device_code" => device_code,
          "user_code" => authorization.user_code,
          "verification_uri" => verification_uri,
          "verification_uri_complete" => verification_uri_complete,
          "expires_at" => DateTime.to_iso8601(authorization.expires_at),
          "expires_in_seconds" => expires_in_seconds,
          "interval_seconds" => interval_seconds
        })

      {:error, _reason} ->
        send_error(
          conn,
          500,
          "cli_org_grant_failed",
          "Could not start CLI org authorization.",
          %{}
        )
    end
  end

  def poll_org_grant_authorization(conn, %{"device_code" => device_code})
      when is_binary(device_code) and device_code != "" do
    session = Map.fetch!(conn.assigns, :current_cli_session)

    case CLILogin.poll_session_org_grant_authorization(device_code, session) do
      {:ok, %{status: "approved"} = result} ->
        send_ok(conn, %{
          "mode" => "auth_org_grant_poll",
          "status" => "approved",
          "granted_orgs" => orgs_json(Map.get(result, :granted_orgs, []))
        })

      {:ok, %{status: status, authorization: authorization} = result} ->
        send_ok(conn, %{
          "mode" => "auth_org_grant_poll",
          "status" => status,
          "user_code" => authorization.user_code,
          "expires_at" => DateTime.to_iso8601(authorization.expires_at),
          "interval_seconds" => Map.get(result, :interval_seconds)
        })

      {:error, :invalid_device_code} ->
        send_error(conn, 401, "invalid_device_code", "CLI device code is invalid.", %{})

      {:error, _reason} ->
        send_error(
          conn,
          500,
          "cli_org_grant_poll_failed",
          "Could not poll CLI org authorization.",
          %{}
        )
    end
  end

  def poll_org_grant_authorization(conn, _params) do
    send_error(conn, 400, "missing_device_code", "Pass a CLI device code.", %{})
  end

  def revoke_org_grant(conn, %{"org" => org_ref}) do
    user = Map.fetch!(conn.assigns, :current_user)
    session = Map.fetch!(conn.assigns, :current_cli_session)

    with {:ok, org} <-
           ProjectScope.require_org(org_ref, missing_message: "Pass an org id or slug."),
         {:ok, granted_orgs} <- CLILogin.revoke_cli_session_org(session, org.id, user.id) do
      send_ok(conn, %{
        "mode" => "auth_org_revoke",
        "revoked" => true,
        "org" => org_json(org),
        "granted_orgs" => orgs_json(granted_orgs)
      })
    else
      {:error, :not_found} ->
        send_error(conn, 404, "cli_org_grant_not_found", "CLI org grant not found.", %{})

      {:error, status, code, message, details} ->
        send_error(conn, status, code, message, details)
    end
  end

  def revoke_org_grant(conn, _params) do
    send_error(conn, 400, "missing_org", "Pass an org id or slug.", %{})
  end

  def logout(conn, _params) do
    token = Map.get(conn.assigns, :current_cli_token)
    :ok = CLILogin.revoke_cli_session(token)

    send_ok(conn, %{
      "mode" => "auth_logout",
      "revoked" => true
    })
  end

  def sessions(conn, _params) do
    user = Map.fetch!(conn.assigns, :current_user)

    send_ok(conn, %{
      "mode" => "auth_sessions",
      "sessions" => Enum.map(CLILogin.list_cli_sessions(user), &session_json/1)
    })
  end

  def revoke_session(conn, %{"session_id" => session_id}) do
    user = Map.fetch!(conn.assigns, :current_user)
    :ok = CLILogin.revoke_cli_session_for_user(user, session_id)

    send_ok(conn, %{
      "mode" => "auth_session_revoke",
      "session_id" => session_id,
      "revoked" => true
    })
  end

  def revoke_session(conn, _params) do
    send_error(conn, 400, "missing_session_id", "Pass a CLI session id.", %{})
  end

  defp send_ok(conn, data) do
    JSON.send_json(conn, %{"ok" => true, "data" => data})
  end

  defp send_error(conn, status, code, message, details) do
    JSON.send_json(
      conn,
      %{
        "ok" => false,
        "error" => %{
          "code" => code,
          "message" => message,
          "details" => details
        }
      },
      status
    )
  end

  defp session_json(session) do
    %{
      "id" => session.id,
      "device" => session.device,
      "client_name" => session.client_name,
      "created_at" => DateTime.to_iso8601(session.created_at),
      "last_seen_at" => iso8601_or_nil(session.last_seen_at),
      "expires_at" => DateTime.to_iso8601(session.expires_at),
      "org_grants" => session_org_grants_json(Map.get(session, :cli_org_grants, []))
    }
  end

  defp orgs_json(orgs), do: Enum.map(orgs, &org_json/1)

  defp org_json(org) do
    %{
      "id" => org.id,
      "slug" => org.slug,
      "name" => org.name
    }
  end

  defp session_org_grants_json(grants) when is_list(grants) do
    Enum.map(grants, fn grant ->
      %{
        "org" => org_json(grant.org),
        "granted_at" => iso8601_or_nil(grant.granted_at),
        "revoked_at" => iso8601_or_nil(grant.revoked_at)
      }
    end)
  end

  defp session_org_grants_json(_), do: []

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(value), do: DateTime.to_iso8601(value)

  defp remote_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp dashboard_base_url(conn) do
    case Application.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/")

      _ ->
        port_suffix =
          case {conn.scheme, conn.port} do
            {:http, 80} -> ""
            {:https, 443} -> ""
            {_scheme, port} -> ":#{port}"
          end

        "#{conn.scheme}://#{conn.host}#{port_suffix}"
    end
  end
end
