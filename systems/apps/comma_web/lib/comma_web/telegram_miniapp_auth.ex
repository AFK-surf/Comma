defmodule CommaWeb.TelegramMiniAppAuth do
  @moduledoc """
  Exchanges a signed Telegram Mini App launch for a short, Task-only Comma session.

  Telegram signs the launch data. The active Comma product binding identifies the
  User and Group. The URL parameters only select a view inside that Group.

  This adapter follows Telegram's Mini App HMAC format. `tgappex` collapses
  duplicate fields and does not check age or compare hashes in constant time.
  `telega_webapp` requires the Telega bot stack, which Comma does not use.
  Existing Erlang crypto and Plug primitives cover this small verifier.
  """

  alias Comma.{Accounts, TelegramLinks}
  alias Comma.Accounts.SessionIssuer
  alias CommaWeb.TelegramBot
  alias SalixIM.ProviderConnects

  @max_init_data_bytes 16_384
  @max_fields 32
  @max_age_seconds 120
  @future_skew_seconds 30
  @session_ttl_seconds 15 * 60

  def complete(%{"init_data" => init_data, "group_id" => group_id}, cookie_token)
      when is_binary(init_data) and is_binary(group_id) do
    with true <- TelegramBot.configured?(),
         {:ok, telegram_id} <- verify_launch_data(init_data, TelegramBot.bot_token()),
         {:ok, %{link: link, user: user, workspace: workspace}} <-
           TelegramLinks.resolve_sender(telegram_id),
         true <- workspace["default_group_id"] == group_id,
         :ok <- active_link(link, workspace, telegram_id) do
      use_or_issue_session(cookie_token, user, workspace, group_id, telegram_id, link.connect_id)
    else
      _ -> {:error, :invalid_telegram_miniapp_login}
    end
  end

  def complete(_params, _cookie_token), do: {:error, :invalid_telegram_miniapp_login}

  @doc false
  def verify_launch_data(init_data, bot_token, now \\ System.system_time(:second))

  def verify_launch_data(init_data, bot_token, now)
      when is_binary(init_data) and is_binary(bot_token) and is_integer(now) and
             byte_size(init_data) <= @max_init_data_bytes and byte_size(init_data) > 0 do
    with {:ok, fields} <- decode_fields(init_data),
         {:ok, hash} <- signed_hash(fields),
         true <- valid_hash?(fields, hash, bot_token),
         {:ok, auth_date} <- auth_date(fields),
         true <- auth_date >= now - @max_age_seconds and auth_date <= now + @future_skew_seconds,
         {:ok, telegram_id} <- telegram_user_id(fields) do
      {:ok, telegram_id}
    else
      _ -> {:error, :invalid_telegram_miniapp_login}
    end
  end

  def verify_launch_data(_init_data, _bot_token, _now),
    do: {:error, :invalid_telegram_miniapp_login}

  def authorize_panel_request(conn, user, %{"session_source" => "channel_task_panel"} = session) do
    with true <- panel_path?(conn.method, conn.request_path, session["group_id"]),
         {:ok, %{link: link, user: owner, workspace: workspace}} <-
           TelegramLinks.resolve_sender(session["channel_subject"]),
         true <- owner["id"] == user["id"] and workspace["id"] == session["workspace_id"],
         true <- workspace["default_group_id"] == session["group_id"],
         true <- link.connect_id == session["channel_connect_id"],
         :ok <- active_link(link, workspace, session["channel_subject"]) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_panel_request(_conn, _user, _session), do: :ok

  defp use_or_issue_session(cookie_token, user, workspace, group_id, telegram_id, connect_id) do
    case Accounts.resolve_session(cookie_token) do
      {:ok, existing_user, session} ->
        cond do
          existing_user["id"] != user["id"] ->
            {:error, :account_mismatch}

          session["session_source"] == "user_login" or
              (session["session_source"] == "channel_task_panel" and
                 session["workspace_id"] == workspace["id"] and
                 session["group_id"] == group_id and
                 session["channel_subject"] == telegram_id and
                 session["channel_connect_id"] == connect_id) ->
            {:ok, :existing,
             %{
               "session_id" => session["id"],
               "expires_at" => session["expires_at"],
               "user" => Map.take(user, ["id", "email", "name", "status"])
             }}

          session["session_source"] == "channel_task_panel" ->
            issue_session(user, workspace, group_id, telegram_id, connect_id)

          true ->
            {:error, :account_mismatch}
        end

      {:error, _reason} ->
        issue_session(user, workspace, group_id, telegram_id, connect_id)
    end
  end

  defp issue_session(user, workspace, group_id, telegram_id, connect_id) do
    SessionIssuer.issue(user,
      auth_method: "telegram_miniapp",
      session_source: "channel_task_panel",
      client_kind: "web",
      restricted: true,
      workspace_id: workspace["id"],
      group_id: group_id,
      channel_subject: telegram_id,
      channel_connect_id: connect_id,
      ttl_seconds: @session_ttl_seconds
    )
    |> case do
      {:ok, session} -> {:ok, :issued, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_link(link, workspace, telegram_id) do
    case ProviderConnects.get_active_connect_by_id(
           workspace["default_group_id"],
           link.connect_id,
           "telegram"
         ) do
      {:ok, connect} ->
        if connect["managed_by"] == "comma_product" and
             connect["runtime_mode"] == "webhook" and
             connect["tenant_id"] == workspace["salix_tenant_id"] and
             connect["group_id"] == workspace["default_group_id"] and
             to_string(connect["managed_peer_id"]) == telegram_id and
             connect["bot_token"] == TelegramBot.bot_token(),
           do: :ok,
           else: {:error, :inactive_link}

      _ ->
        {:error, :inactive_link}
    end
  end

  defp panel_path?("GET", "/v1/comma/auth/session", _group_id), do: true
  defp panel_path?("POST", "/v1/comma/auth/logout", _group_id), do: true
  defp panel_path?("GET", "/v1/comma/me/profile", _group_id), do: true

  defp panel_path?("GET", path, group_id) when is_binary(group_id) do
    case String.split(path, "/", trim: true) do
      ["v1", "comma", "groups", ^group_id, "task-labels"] ->
        true

      ["v1", "comma", "groups", ^group_id, "conversations"] ->
        true

      ["v1", "comma", "groups", ^group_id, "conversations", conversation_id] ->
        SalixStore.Ids.valid_conversation_id?(conversation_id)

      ["v1", "comma", "groups", ^group_id, "conversations", conversation_id, "preview"] ->
        SalixStore.Ids.valid_conversation_id?(conversation_id)

      [
        "v1",
        "comma",
        "groups",
        ^group_id,
        "conversations",
        conversation_id,
        "messages",
        _message_id,
        "attachments",
        _index
      ] ->
        SalixStore.Ids.valid_conversation_id?(conversation_id)

      _ ->
        false
    end
  end

  defp panel_path?(_method, _path, _group_id), do: false

  defp decode_fields(data) do
    fields = URI.query_decoder(data) |> Enum.to_list()
    keys = Enum.map(fields, &elem(&1, 0))

    if length(fields) <= @max_fields and length(fields) == length(Enum.uniq(keys)) and
         Enum.all?(fields, fn {key, value} ->
           String.match?(key, ~r/\A[a-z_]+\z/) and is_binary(value)
         end) do
      {:ok, fields}
    else
      {:error, :invalid_fields}
    end
  rescue
    _ -> {:error, :invalid_fields}
  end

  defp signed_hash(fields) do
    case List.keyfind(fields, "hash", 0) do
      {"hash", hash} when byte_size(hash) == 64 ->
        case Base.decode16(hash, case: :mixed) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, :invalid_hash}
        end

      _ ->
        {:error, :invalid_hash}
    end
  end

  defp valid_hash?(fields, hash, bot_token) do
    check_string =
      fields
      |> Enum.reject(fn {key, _value} -> key == "hash" end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {key, value} -> key <> "=" <> value end)

    secret = :crypto.mac(:hmac, :sha256, "WebAppData", bot_token)
    expected = :crypto.mac(:hmac, :sha256, secret, check_string)
    Plug.Crypto.secure_compare(hash, expected)
  end

  defp auth_date(fields) do
    case List.keyfind(fields, "auth_date", 0) do
      {"auth_date", value} ->
        case Integer.parse(value) do
          {date, ""} -> {:ok, date}
          _ -> {:error, :invalid_auth_date}
        end

      _ ->
        {:error, :invalid_auth_date}
    end
  end

  defp telegram_user_id(fields) do
    with {"user", json} <- List.keyfind(fields, "user", 0),
         {:ok, %{"id" => id}} <- Jason.decode(json),
         true <- is_integer(id) and id > 0 and id <= 4_503_599_627_370_495 do
      {:ok, Integer.to_string(id)}
    else
      _ -> {:error, :invalid_user}
    end
  end
end
