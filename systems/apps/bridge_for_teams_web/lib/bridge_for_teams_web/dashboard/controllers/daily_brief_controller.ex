defmodule BridgeForTeamsWeb.Dashboard.DailyBriefController do
  @moduledoc """
  The member's own browser step to let their daily brief read their direct
  messages, and to stop it.

  `connect` starts the member's Slack authorization and keeps its state in the
  session. Slack returns to `connected`, which enables direct messages only
  for that same state, member, and Slack account.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.{DailyBrief, Memberships, Orgs, Repo}
  alias BridgeForTeams.DailyBrief.DirectMessages
  alias BridgeForTeams.Schema.DailyBriefMember
  alias BridgeForTeamsWeb.MacMiniRelease

  @session_key "daily_brief_dm_state"

  def connect(conn, %{"org" => slug}) do
    with {:ok, org, settings, member} <- context(conn, slug),
         {:ok, %{authorization_url: url, state: state}} <-
           DirectMessages.start_connect(settings, member, return_url(slug)) do
      conn
      |> put_session(@session_key, %{"org_id" => org.id, "state" => state})
      |> redirect(external: url)
    else
      {:error, reason} -> page(conn, error_status(reason), message(reason))
    end
  end

  def connected(conn, %{"org" => slug} = params) do
    pending = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)

    with {:ok, org, settings, member} <- context(conn, slug),
         %{"org_id" => org_id, "state" => state} when org_id == org.id <- pending,
         nil <- params["oauth_error"],
         {:ok, _member} <- DirectMessages.complete_connect(settings, member, state) do
      page(
        conn,
        200,
        "已开启：你的每日简报会读你的私信和群私信，原文不保存，简报只发给你本人。要关掉，打开 " <>
          return_base(slug) <> "/direct-messages/disconnect 。"
      )
    else
      {:error, reason} -> page(conn, error_status(reason), message(reason))
      _no_pending -> page(conn, 400, "授权没有完成，请回到每日简报页重新开启。")
    end
  end

  @doc "Asks before turning direct messages off; the form posts back here."
  def disconnect_form(conn, %{"org" => slug}) do
    with {:ok, _org, _settings, member} <- context(conn, slug) do
      if member.dm_status == "on" do
        html(conn, """
        <!doctype html><meta charset="utf-8"><title>停止读取私信</title>
        <form method="post" style="max-width:40em;margin:2em auto;font-family:sans-serif">
          <h2>停止读取私信</h2>
          <p>关闭后，每日简报立即停止读取你的私信，并撤销这次 Slack 授权。私信原文本来就不保存。</p>
          <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}">
          <button type="submit">关闭</button>
        </form>
        """)
      else
        page(conn, 200, "每日简报没有在读你的私信。")
      end
    else
      {:error, reason} -> page(conn, error_status(reason), message(reason))
    end
  end

  def disconnect(conn, %{"org" => slug}) do
    with {:ok, _org, settings, member} <- context(conn, slug),
         {:ok, _member} <- DirectMessages.disconnect(settings, member) do
      page(conn, 200, "已停止读取你的私信，Slack 授权已撤销。")
    else
      {:error, reason} -> page(conn, error_status(reason), message(reason))
    end
  end

  defp context(conn, slug) do
    user = conn.assigns.current_user

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         :ok <- Memberships.authorize(user.id, :read, %{org_id: org.id, min_org_role: "member"}),
         %{enabled: true} = settings <- DailyBrief.get_settings(org.id),
         %DailyBriefMember{enabled: true} = member <-
           Repo.get_by(DailyBriefMember, org_id: org.id, user_id: user.id) do
      {:ok, org, settings, member}
    else
      {:error, reason} -> {:error, reason}
      _not_set_up -> {:error, :not_set_up}
    end
  end

  defp return_url(slug), do: return_base(slug) <> "/direct-messages/connected"

  defp return_base(slug), do: MacMiniRelease.api_base_url() <> "/orgs/#{slug}/daily-brief"

  defp page(conn, status, text) do
    conn
    |> put_status(status)
    |> put_resp_content_type("text/plain")
    |> send_resp(status, text)
  end

  defp error_status(:not_found), do: 404
  defp error_status(:forbidden), do: 403
  defp error_status(:not_set_up), do: 404
  defp error_status(_reason), do: 400

  defp message(:slack_account_mismatch),
    do: "授权的 Slack 账号不是你在这个组织里的账号，已撤销这次授权。请用自己的账号重新授权。"

  defp message(:shared_slack_app),
    do: "这个 Swarm 的 Slack bot 和组织的 Slack 连接用的是同一个 app，私信授权会和 agent 的授权混在一起。请管理员给 bot 单独建一个 app。"

  defp message(:dm_enabled), do: "每日简报已经在读你的私信了。"
  defp message(:not_set_up), do: "这个组织还没有为你开启每日简报。"
  defp message(_reason), do: "没能开启，请稍后再试。"
end
