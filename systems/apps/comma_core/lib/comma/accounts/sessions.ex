defmodule Comma.Accounts.Sessions do
  @moduledoc "Creation, validation, listing, and revocation for Comma sessions."

  import Ecto.Query

  alias Comma.Accounts.{AuthSession, Repository, User}
  alias Comma.Repo

  @token_prefix "comma_sess_"
  # Older servers reject this prefix during a rolling release. A panel token
  # must never be accepted by a server without the panel route restriction.
  @task_panel_token_prefix "comma_panel_"
  @default_ttl_seconds 30 * 24 * 60 * 60
  @last_seen_interval_seconds 5 * 60
  # A desktop App reports use at most this often while its user is at the
  # computer; the owner counts as present for twice that long.
  @active_interval_seconds 60
  @present_seconds 10 * 60
  @default_page_limit 50
  @max_page_limit 100

  def create(user_id, opts \\ [])

  def create(user_id, opts) when is_binary(user_id) do
    target_repo = Keyword.get(opts, :repo, Repo)

    with {:ok, %User{status: "active"} = user} <- Repository.get_user(user_id, repo: target_repo) do
      source = Keyword.get(opts, :session_source, "user_login")
      token = session_token(source)
      now = DateTime.utc_now()

      attrs = %{
        user_id: user.id,
        token_hash: token_hash(token),
        auth_method: auth_method(source, opts),
        login_identity_id: Keyword.get(opts, :login_identity_id),
        session_source: source,
        parent_session_id: Keyword.get(opts, :parent_session_id),
        authenticated_at: Keyword.get(opts, :authenticated_at, now),
        expires_at: DateTime.add(now, Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)),
        last_seen_at: now,
        client_kind: Keyword.get(opts, :client_kind),
        client_platform: Keyword.get(opts, :client_platform),
        device_label: Keyword.get(opts, :device_label),
        channel_subject: Keyword.get(opts, :channel_subject),
        channel_connect_id: Keyword.get(opts, :channel_connect_id),
        user_auth_epoch: user.auth_epoch,
        restricted: Keyword.get(opts, :restricted, false),
        workspace_id: Keyword.get(opts, :workspace_id),
        group_id: Keyword.get(opts, :group_id),
        conversation_id: Keyword.get(opts, :conversation_id),
        interaction_budget_remaining: Keyword.get(opts, :interaction_budget_remaining),
        tool_allowlist: Keyword.get(opts, :tool_allowlist, []),
        consumed_interaction_ids: %{}
      }

      case target_repo.insert(AuthSession.changeset(%AuthSession{}, attrs)) do
        {:ok, session} -> {:ok, Map.put(public_session(session), "token", token)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:ok, %User{}} -> {:error, :disabled}
      {:error, _reason} = error -> error
    end
  end

  def create(_user_id, _opts), do: {:error, :not_found}

  def validate(token, opts \\ [])

  def validate(token, opts) when is_binary(token) do
    with {:ok, user, session} <- resolve(token, opts),
         :ok <- touch_last_seen(session, opts) do
      {:ok, user, session}
    end
  end

  def validate(_token, _opts), do: {:error, :not_found}

  def resolve(token, opts \\ [])

  def resolve(token, opts) when is_binary(token) do
    if not session_token?(token), do: {:error, :not_found}, else: resolve_known_token(token, opts)
  end

  def resolve(_token, _opts), do: {:error, :not_found}

  @doc "Recheck an authenticated Session at an owner mutation boundary without exposing its token."
  def authorize_current(user_id, session_id, opts \\ []) do
    target_repo = Keyword.get(opts, :repo, Repo)

    with {:ok, id} <- Ecto.UUID.cast(session_id),
         {%AuthSession{} = session, %User{} = user} <-
           target_repo.one(
             from(s in AuthSession,
               join: u in assoc(s, :user),
               where: s.id == ^id and s.user_id == ^user_id,
               select: {s, u}
             )
           ),
         :ok <- active_session?(session, user),
         :ok <- active_identity(session, target_repo),
         :ok <- active_pairing_parent(session, target_repo) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp resolve_known_token(token, opts) do
    target_repo = Keyword.get(opts, :repo, Repo)

    query =
      from(session in AuthSession,
        join: user in assoc(session, :user),
        where: session.token_hash == ^token_hash(token),
        select: {session, user}
      )

    case target_repo.one(query) do
      {%AuthSession{} = session, %User{} = user} ->
        with :ok <- active_session?(session, user),
             :ok <- active_identity(session, target_repo),
             :ok <- active_pairing_parent(session, target_repo) do
          {:ok, user, public_session(session)}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def resolve_id(session_id, opts \\ []) do
    target_repo = Keyword.get(opts, :repo, Repo)

    with {:ok, id} <- Ecto.UUID.cast(session_id),
         {session, user} when not is_nil(session) <-
           target_repo.one(
             from(session in AuthSession,
               join: user in assoc(session, :user),
               where: session.id == ^id,
               select: {session, user}
             )
           ),
         :ok <- active_session?(session, user),
         :ok <- active_identity(session, target_repo),
         :ok <- active_pairing_parent(session, target_repo) do
      {:ok, user, public_session(session)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  def touch_last_seen(session, opts \\ [])

  def touch_last_seen(%{"id" => session_id, "last_seen_at" => last_seen_at}, opts)
      when is_binary(session_id) and is_integer(last_seen_at) do
    cutoff = DateTime.add(DateTime.utc_now(), -@last_seen_interval_seconds)

    if last_seen_at < DateTime.to_unix(cutoff) do
      target_repo = Keyword.get(opts, :repo, Repo)
      now = DateTime.utc_now()

      target_repo.update_all(
        from(row in AuthSession,
          where: row.id == ^session_id and row.last_seen_at < ^cutoff
        ),
        set: [last_seen_at: now, updated_at: now]
      )
    end

    :ok
  end

  def touch_last_seen(_session, _opts), do: :ok

  @doc """
  Records that the person is using the desktop App of this session right now.
  Only full desktop App sessions count.
  """
  def touch_active(session, opts \\ [])

  def touch_active(
        %{"id" => session_id, "client_kind" => "electron", "restricted" => false},
        opts
      )
      when is_binary(session_id) do
    target_repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -@active_interval_seconds)

    target_repo.update_all(
      from(row in AuthSession,
        where:
          row.id == ^session_id and is_nil(row.revoked_at) and
            (is_nil(row.active_at) or row.active_at < ^cutoff)
      ),
      set: [active_at: now, updated_at: now]
    )

    :ok
  end

  def touch_active(_session, _opts), do: {:error, :not_desktop_app}

  @doc "Whether the user used a signed-in desktop App in the last ten minutes."
  def present?(user_id, opts \\ []) when is_binary(user_id) do
    target_repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -@present_seconds)

    target_repo.exists?(
      from(row in AuthSession,
        where:
          row.user_id == ^user_id and is_nil(row.revoked_at) and row.expires_at > ^now and
            row.client_kind == "electron" and row.active_at > ^since
      )
    )
  end

  def list(user_id, opts \\ [])

  def list(user_id, opts) when is_binary(user_id) do
    target_repo = Keyword.get(opts, :repo, Repo)
    limit = opts |> Keyword.get(:limit, @default_page_limit) |> clamp_limit()

    with {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)) do
      query =
        from(session in AuthSession,
          where: session.user_id == ^user_id,
          order_by: [desc: session.created_at, desc: session.id],
          limit: ^(limit + 1)
        )
        |> after_cursor(cursor)

      rows = target_repo.all(query)
      page = Enum.take(rows, limit)
      has_more = length(rows) > limit

      {:ok,
       %{
         "data" => Enum.map(page, &public_session/1),
         "has_more" => has_more,
         "next_cursor" => if(has_more, do: encode_cursor(List.last(page)))
       }}
    end
  end

  def list(_user_id, _opts), do: {:error, :not_found}

  def revoke(user_id, session_id, reason \\ "user_revoked", opts \\ [])

  def revoke(user_id, session_id, reason, opts)
      when is_binary(user_id) and is_binary(session_id) and is_binary(reason) do
    case Ecto.UUID.cast(session_id) do
      {:ok, session_id} ->
        target_repo = Keyword.get(opts, :repo, Repo)
        now = DateTime.utc_now()

        {_count, _} =
          target_repo.update_all(
            from(session in AuthSession,
              where:
                (session.id == ^session_id or session.parent_session_id == ^session_id) and
                  session.user_id == ^user_id and
                  is_nil(session.revoked_at)
            ),
            set: [revoked_at: now, revoke_reason: reason, updated_at: now]
          )

        :ok

      :error ->
        :ok
    end
  end

  def revoke(_user_id, _session_id, _reason, _opts), do: :ok

  def revoke_token(token, reason \\ "signed_out", opts \\ [])

  def revoke_token(token, reason, opts) when is_binary(token) do
    if not session_token?(token), do: :ok, else: revoke_known_token(token, reason, opts)
  end

  def revoke_token(_token, _reason, _opts), do: :ok

  defp revoke_known_token(token, reason, opts) do
    target_repo = Keyword.get(opts, :repo, Repo)
    now = DateTime.utc_now()

    parents =
      from(session in AuthSession,
        where: session.token_hash == ^token_hash(token),
        select: session.id
      )

    target_repo.update_all(
      from(session in AuthSession,
        where:
          (session.id in subquery(parents) or session.parent_session_id in subquery(parents)) and
            is_nil(session.revoked_at)
      ),
      set: [revoked_at: now, revoke_reason: reason, updated_at: now]
    )

    :ok
  end

  def revoke_all(user_id, opts \\ [])

  def revoke_all(user_id, opts) when is_binary(user_id) do
    target_repo = Keyword.get(opts, :repo, Repo)
    except_id = Keyword.get(opts, :except_session_id)
    reason = Keyword.get(opts, :reason, "user_revoked_all")
    now = DateTime.utc_now()

    query =
      from(session in AuthSession,
        where: session.user_id == ^user_id and is_nil(session.revoked_at)
      )
      |> except_session(except_id)
      |> active_only(Keyword.get(opts, :active_only, false), now)

    {count, _} =
      target_repo.update_all(query,
        set: [revoked_at: now, revoke_reason: reason, updated_at: now]
      )

    {:ok, count}
  end

  def revoke_all(_user_id, _opts), do: {:ok, 0}

  def consume_budget(session, operation_id, opts \\ [])

  def consume_budget(%{"restricted" => true, "id" => session_id}, operation_id, opts)
      when is_binary(session_id) and is_binary(operation_id) and operation_id != "" do
    target_repo = Keyword.get(opts, :repo, Repo)

    target_repo.transaction(fn ->
      session =
        target_repo.one(
          from(row in AuthSession, where: row.id == ^session_id, lock: "FOR UPDATE")
        )

      cond do
        is_nil(session) ->
          target_repo.rollback(:not_found)

        Map.has_key?(session.consumed_interaction_ids || %{}, operation_id) ->
          public_session(session)

        not is_integer(session.interaction_budget_remaining) ->
          target_repo.rollback(:invalid_budget)

        session.interaction_budget_remaining <= 0 ->
          target_repo.rollback(:budget_exhausted)

        true ->
          consumed = Map.put(session.consumed_interaction_ids || %{}, operation_id, now_iso8601())

          case target_repo.update(
                 Ecto.Changeset.change(session, %{
                   interaction_budget_remaining: session.interaction_budget_remaining - 1,
                   consumed_interaction_ids: consumed
                 })
               ) do
            {:ok, updated} -> public_session(updated)
            {:error, changeset} -> target_repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  def consume_budget(%{"restricted" => true}, _operation_id, _opts),
    do: {:error, :invalid_operation_id}

  def consume_budget(session, _operation_id, _opts), do: {:ok, session}

  def public_session(%AuthSession{} = session) do
    %{
      "id" => session.id,
      "user_id" => session.user_id,
      "auth_method" => session.auth_method,
      "session_source" => session.session_source,
      "parent_session_id" => session.parent_session_id,
      "authenticated_at" => unix(session.authenticated_at),
      "expires_at" => unix(session.expires_at),
      "last_seen_at" => unix(session.last_seen_at),
      "revoked_at" => unix(session.revoked_at),
      "client_kind" => session.client_kind,
      "client_platform" => session.client_platform,
      "device_label" => session.device_label,
      "channel_subject" => session.channel_subject,
      "channel_connect_id" => session.channel_connect_id,
      "restricted" => session.restricted,
      "workspace_id" => session.workspace_id,
      "group_id" => session.group_id,
      "conversation_id" => session.conversation_id,
      "interaction_budget_remaining" => session.interaction_budget_remaining,
      "tool_allowlist" => session.tool_allowlist || []
    }
  end

  # Pairing grants authority once; this bounded parent read preserves explicit
  # revocation during races with grant exchange, without making parent expiry
  # or phone connectivity a requirement for the Watch's independent session.
  defp active_pairing_parent(%{auth_method: "watch_pairing"} = session, repo) do
    case repo.get(AuthSession, session.parent_session_id) do
      %{user_id: user_id, revoked_at: nil, restricted: false, parent_session_id: nil} = parent
      when user_id == session.user_id ->
        active_identity(parent, repo)

      _ ->
        {:error, :revoked}
    end
  end

  defp active_pairing_parent(_session, _repo), do: :ok

  defp active_identity(%{auth_method: "apple"} = session, repo) do
    case repo.get(Comma.Accounts.Identity, session.login_identity_id) do
      %{provider: "apple", disabled_at: nil, user_id: user_id} when user_id == session.user_id ->
        :ok

      _ ->
        {:error, :revoked}
    end
  end

  defp active_identity(%{auth_method: "ssh_public_key"} = session, repo) do
    case repo.get(Comma.Accounts.Identity, session.login_identity_id) do
      %{provider: "ssh", disabled_at: nil, user_id: user_id} when user_id == session.user_id ->
        :ok

      _ ->
        {:error, :revoked}
    end
  end

  defp active_identity(_session, _repo), do: :ok

  defp active_session?(session, user) do
    now = DateTime.utc_now()

    cond do
      session.revoked_at -> {:error, :revoked}
      DateTime.compare(session.expires_at, now) != :gt -> {:error, :expired}
      user.status != "active" -> {:error, :disabled}
      session.user_auth_epoch != user.auth_epoch -> {:error, :revoked}
      true -> :ok
    end
  end

  defp session_token("channel_task_panel"),
    do:
      @task_panel_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp session_token(_source),
    do: @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp session_token?(@token_prefix <> _), do: true
  defp session_token?(@task_panel_token_prefix <> _), do: true
  defp session_token?(_), do: false

  defp token_hash(token), do: :crypto.hash(:sha256, token)

  defp auth_method("ops_api", _opts), do: nil
  defp auth_method(_source, opts), do: Keyword.get(opts, :auth_method, "email_otp")

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_page_limit)
  defp clamp_limit(_limit), do: @default_page_limit

  defp encode_cursor(%AuthSession{} = session) do
    %{created_at: DateTime.to_iso8601(session.created_at), id: session.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"created_at" => created_at, "id" => id}} <- Jason.decode(json),
         {:ok, created_at, 0} <- DateTime.from_iso8601(created_at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {created_at, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {created_at, id}) do
    from(session in query,
      where:
        session.created_at < ^created_at or
          (session.created_at == ^created_at and session.id < ^id)
    )
  end

  defp except_session(query, nil), do: query
  defp except_session(query, id), do: from(session in query, where: session.id != ^id)

  defp active_only(query, true, now),
    do: from(session in query, where: session.expires_at > ^now)

  defp active_only(query, _active_only, _now), do: query

  defp unix(nil), do: nil
  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
