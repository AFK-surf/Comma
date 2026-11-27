defmodule SalixIM.Provider.Slack.WorkspaceMember do
  @moduledoc """
  Whether one Slack user is a full member of a connect's own workspace, and
  who they are: the Slack counterpart of
  `SalixIM.Provider.Feishu.AppAvailability.member/2`.

  `CommaWeb.Stations` asks it on every station tool call of a person who has
  no account in the product (`SalixStore.StationMembers.app_member_role/2`)
  when the connect's member scope is `"organization"`
  (`SalixIM.ProviderConnects.Members`), so a change in Slack applies to the
  next call. It reads `users.info` each time and keeps nothing.

  A member is a user of the connect's workspace (`team_id` is the connect's
  `workspace_id`, or, on Enterprise Grid, the user's `enterprise_user` is of
  the connect's `enterprise_id`) who is not a bot or app user, not
  deactivated, not a guest (`is_restricted`, `is_ultra_restricted`) and not
  a stranger (`is_stranger`, a Slack Connect person from another
  organization) and not still invited (`is_invited_user`). The email needs
  the bot scope `users:read.email`.
  """

  alias SalixIM.Provider.Slack.API

  @email_scope "users:read.email"

  @type failure :: :not_available | :no_email | {:missing_scope, String.t()} | String.t()

  @doc """
  The Slack user `user_id` as `%{"name", "email"}` when they are a full member
  of the connect's workspace, else `{:error, :not_available}`. A member
  without an email is `{:missing_scope, "users:read.email"}` when the connect's
  granted bot scopes are known and lack it, else `:no_email`.
  """
  @spec member(map(), String.t()) :: {:ok, map()} | {:error, failure()}
  def member(connect, user_id) when is_map(connect) and is_binary(user_id) and user_id != "" do
    with {:ok, user} <- user(connect, user_id),
         true <- user["id"] == user_id and full_member?(connect, user) do
      profile = if is_map(user["profile"]), do: user["profile"], else: %{}

      case present(profile["email"]) do
        nil ->
          {:error, no_email(connect)}

        email ->
          {:ok,
           %{
             "name" =>
               Enum.find_value(
                 [profile["real_name"], user["real_name"], profile["display_name"], user["name"]],
                 &present/1
               ),
             "email" => email
           }}
      end
    else
      false -> {:error, :not_available}
      {:error, _reason} = error -> error
    end
  end

  def member(_connect, _user_id), do: {:error, :not_available}

  defp user(connect, user_id) do
    case API.request_form(API.installation(connect), "users.info", user: user_id) do
      %{"user" => %{} = user} -> {:ok, user}
      _other -> {:error, :not_available}
    end
  rescue
    error in API.Error ->
      case error.message do
        reason when reason in ["user_not_found", "user_not_visible", "account_inactive"] ->
          {:error, :not_available}

        "missing_scope" ->
          needed = if is_map(error.body), do: present(error.body["needed"])
          {:error, {:missing_scope, needed || "users:read"}}

        reason ->
          {:error, to_string(reason)}
      end

    _error in ArgumentError ->
      {:error, "Slack connect is not OAuth-complete"}
  end

  @doc """
  Whether the Slack user record `user` (from `users.info`, `users.list` or
  `users.lookupByEmail`) is a full member of the connect's own workspace.
  """
  @spec full_member?(map(), map()) :: boolean()
  def full_member?(connect, user) when is_map(connect) and is_map(user) do
    is_binary(user["id"]) and user["id"] != "USLACKBOT" and
      not Enum.any?(
        ~w(deleted is_bot is_app_user is_restricted is_ultra_restricted is_stranger
           is_invited_user),
        &(user[&1] == true)
      ) and own_workspace?(connect, user)
  end

  def full_member?(_connect, _user), do: false

  defp own_workspace?(connect, user) do
    workspace = present(connect["workspace_id"])
    enterprise = present(connect["enterprise_id"])
    enterprise_user = if is_map(user["enterprise_user"]), do: user["enterprise_user"], else: %{}

    (workspace != nil and user["team_id"] == workspace) or
      (enterprise != nil and enterprise_user["enterprise_id"] == enterprise)
  end

  # Slack gives no email both to a token without `users:read.email` and to a
  # user without one; the scopes the install granted tell which, when known.
  defp no_email(connect) do
    scopes = connect["granted_bot_scopes"]

    known? =
      is_list(scopes) and present(connect["connect_generation"]) != nil and
        connect["granted_bot_scopes_generation"] == connect["connect_generation"]

    if known? and @email_scope not in scopes, do: {:missing_scope, @email_scope}, else: :no_email
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_value), do: nil
end
