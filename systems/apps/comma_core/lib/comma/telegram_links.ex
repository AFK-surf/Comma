defmodule Comma.TelegramLinks do
  @moduledoc """
  Comma-owned Telegram account to Workspace binding state.
  Modeled in tla/salix/CommaTelegramBinding.tla: intent consumption, final
  publication, revocation and the cross-store lifecycle exclusion boundary.
  """

  import Ecto.Query

  alias Comma.Data.{TelegramDMClaimCode, TelegramDMLink, TelegramOIDCAttempt, Workspace}
  alias Comma.{Accounts, Repo, Workspaces}

  @claim_ttl_seconds 10 * 60
  @claim_bytes 9
  @oidc_attempt_ttl_seconds 10 * 60

  # One shared product bot. Admission is non-blocking: a concurrent lifecycle
  # returns busy instead of holding a pool connection in an unbounded queue.
  # Session (not transaction) scope allows the binding COMMIT before activation.
  # DBConnection closes a checked-out connection when its borrower dies, so a
  # crashed coordinator releases this lock; late provider writes stay fenced by
  # immutable connect ids and terminal deletion.
  def with_lifecycle_lock(fun) do
    Repo.checkout(fn ->
      case Repo.query!("SELECT pg_try_advisory_lock(4412741, 21575)").rows do
        [[true]] ->
          try do
            fun.()
          after
            Repo.query!("SELECT pg_advisory_unlock(4412741, 21575)")
          end

        [[false]] ->
          {:error, :telegram_link_busy}
      end
    end)
  end

  def get(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      {:ok, workspace, get_link(workspace_id)}
    end
  end

  def create_claim(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      expires_at = DateTime.add(DateTime.utc_now(), @claim_ttl_seconds, :second)
      create_claim(workspace, user["id"], expires_at, 0)
    end
  end

  def create_oidc_attempt(user, session, workspace_id, attrs) when is_map(attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         true <- Enum.all?(~w(state nonce pkce_verifier), &nonblank?(attrs[&1])) do
      expires_at = DateTime.add(DateTime.utc_now(), @oidc_attempt_ttl_seconds, :second)

      Repo.transaction(fn ->
        lock_workspace!(workspace_id)
        clear_attempts(workspace_id)

        %TelegramOIDCAttempt{}
        |> TelegramOIDCAttempt.changeset(%{
          state_hash: state_hash(attrs["state"]),
          workspace_id: workspace_id,
          owner_user_id: user["id"],
          nonce: attrs["nonce"],
          pkce_verifier: attrs["pkce_verifier"],
          expires_at: expires_at
        })
        |> Repo.insert!()
      end)
      |> case do
        {:ok, attempt} -> {:ok, workspace, attempt}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_telegram_oidc_attempt}
      other -> other
    end
  end

  def take_oidc_attempt(state) when is_binary(state) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      attempt =
        Repo.one(
          from(row in TelegramOIDCAttempt,
            where:
              row.state_hash == ^state_hash(state) and row.expires_at > ^now and
                is_nil(row.consumed_at),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:invalid_telegram_oidc_attempt)

      attempt = attempt |> Ecto.Changeset.change(consumed_at: now) |> Repo.update!()

      with {:ok, user} <- Accounts.get_user(attempt.owner_user_id),
           {:ok, workspace} <- Workspaces.authorize(user, %{}, attempt.workspace_id) do
        %{attempt: attempt, user: user, workspace: workspace}
      else
        _unavailable -> Repo.rollback(:invalid_telegram_oidc_attempt)
      end
    end)
    |> unwrap_transaction()
  end

  def take_oidc_attempt(_state), do: {:error, :invalid_telegram_oidc_attempt}

  def take_claim(code) when is_binary(code) do
    now = DateTime.utc_now()
    normalized_code = normalize_code(code)

    Repo.transaction(fn ->
      claim =
        Repo.one(
          from(row in TelegramDMClaimCode,
            where:
              row.code == ^normalized_code and row.expires_at > ^now and is_nil(row.consumed_at),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:invalid_telegram_claim)

      claim = claim |> Ecto.Changeset.change(consumed_at: now) |> Repo.update!()

      with {:ok, user} <- Accounts.get_user(claim.owner_user_id),
           {:ok, workspace} <- Workspaces.authorize(user, %{}, claim.workspace_id) do
        %{claim: claim, user: user, workspace: workspace}
      else
        _unavailable -> Repo.rollback(:invalid_telegram_claim)
      end
    end)
    |> unwrap_transaction()
  end

  def take_claim(_code), do: {:error, :invalid_telegram_claim}

  def validate_connection_attempt(user_id, workspace_id, proof) do
    Repo.transaction(fn ->
      lock_workspace!(workspace_id)
      require_current_attempt!(proof, workspace_id, user_id)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def put_link(user_id, workspace_id, telegram_identity, connect_id, proof) do
    with {:ok, user} <- Accounts.get_user(user_id),
         {:ok, _workspace} <- Workspaces.authorize(user, %{}, workspace_id) do
      Repo.transaction(fn ->
        lock_workspace!(workspace_id)
        require_current_attempt!(proof, workspace_id, user_id)
        result = replace_link(workspace_id, user_id, telegram_identity, connect_id)
        clear_attempts(workspace_id)

        result
      end)
      |> unwrap_transaction()
    end
  end

  def resolve_sender(telegram_user_id) do
    case Repo.get_by(TelegramDMLink, telegram_user_id: normalize_user_id(telegram_user_id)) do
      nil ->
        {:error, :telegram_not_linked}

      link ->
        with {:ok, user} <- Accounts.get_user(link.owner_user_id),
             {:ok, workspace} <- Workspaces.authorize(user, %{}, link.workspace_id) do
          {:ok, %{link: link, user: user, workspace: workspace}}
        else
          _unavailable -> {:error, :telegram_not_linked}
        end
    end
  end

  def delete(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      Repo.transaction(fn ->
        lock_workspace!(workspace_id)

        {count, _} =
          Repo.delete_all(
            from(link in TelegramDMLink,
              where: link.workspace_id == ^workspace_id and link.owner_user_id == ^user["id"]
            )
          )

        clear_attempts(workspace_id)
        count > 0
      end)
      |> case do
        {:ok, removed?} -> {:ok, workspace, removed?}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def public_link(nil), do: nil

  def public_link(%TelegramDMLink{} = link) do
    %{
      "telegram_user_id" => link.telegram_user_id,
      "telegram_username" => link.telegram_username,
      "connection_id" => link.connect_id,
      "connected_at" => unix(link.inserted_at),
      "updated_at" => unix(link.updated_at)
    }
  end

  def public_claim(nil), do: nil

  def public_claim(%TelegramDMClaimCode{} = claim) do
    %{"code" => claim.code, "expires_at" => unix(claim.expires_at)}
  end

  def get_link(workspace_id), do: Repo.get(TelegramDMLink, workspace_id)

  # Cancel exactly the presented attempt, including an already exchanging
  # callback. A stale tab must not cancel a newer intent or disconnect a link.
  # This is the model's Expire transition, serialized with final publication.
  def cancel_attempt(user, session, workspace_id, attrs) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      with_lifecycle_lock(fn ->
        Repo.transaction(fn ->
          lock_workspace!(workspace_id)

          case attrs do
            %{"state" => state} when is_binary(state) and state != "" ->
              Repo.delete_all(
                from(row in TelegramOIDCAttempt,
                  where:
                    row.workspace_id == ^workspace_id and row.state_hash == ^state_hash(state)
                )
              )

            %{"code" => code} when is_binary(code) and code != "" ->
              Repo.delete_all(
                from(row in TelegramDMClaimCode,
                  where: row.workspace_id == ^workspace_id and row.code == ^normalize_code(code)
                )
              )

            _ ->
              Repo.rollback(:invalid_telegram_connection_attempt)
          end

          :ok
        end)
        |> unwrap_transaction()
      end)
    end
  end

  def get_link_by_sender(telegram_user_id),
    do: Repo.get_by(TelegramDMLink, telegram_user_id: normalize_user_id(telegram_user_id))

  def get_active_claim(workspace_id) do
    now = DateTime.utc_now()

    Repo.one(
      from(claim in TelegramDMClaimCode,
        where:
          claim.workspace_id == ^workspace_id and claim.expires_at > ^now and
            is_nil(claim.consumed_at)
      )
    )
  end

  defp create_claim(workspace, user_id, expires_at, attempts) when attempts < 3 do
    code = :crypto.strong_rand_bytes(@claim_bytes) |> Base.url_encode64(padding: false)

    Repo.transaction(fn ->
      lock_workspace!(workspace["id"])
      clear_attempts(workspace["id"])

      %TelegramDMClaimCode{}
      |> TelegramDMClaimCode.changeset(%{
        code: code,
        workspace_id: workspace["id"],
        owner_user_id: user_id,
        expires_at: expires_at
      })
      |> Repo.insert()
      |> case do
        {:ok, claim} -> claim
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, claim} -> {:ok, workspace, claim}
      {:error, %Ecto.Changeset{}} -> create_claim(workspace, user_id, expires_at, attempts + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_claim(_workspace, _user_id, _expires_at, _attempts),
    do: {:error, :telegram_claim_unavailable}

  defp lock_workspace!(workspace_id) do
    Repo.one(from(row in Workspace, where: row.id == ^workspace_id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp clear_attempts(workspace_id) do
    Repo.delete_all(from(row in TelegramDMClaimCode, where: row.workspace_id == ^workspace_id))
    Repo.delete_all(from(row in TelegramOIDCAttempt, where: row.workspace_id == ^workspace_id))
  end

  defp require_current_attempt!(%module{} = proof, workspace_id, user_id)
       when module in [TelegramDMClaimCode, TelegramOIDCAttempt] do
    [{key, value}] = Ecto.primary_key(proof)
    now = DateTime.utc_now()

    current = Repo.get_by(module, [{key, value}])

    unless current && current.workspace_id == workspace_id && current.owner_user_id == user_id &&
             current.consumed_at && DateTime.compare(current.expires_at, now) == :gt do
      Repo.rollback(:invalid_telegram_connection_attempt)
    end
  end

  defp replace_link(workspace_id, owner_user_id, telegram_identity, connect_id) do
    telegram_user_id = normalize_user_id(telegram_identity["id"] || telegram_identity[:id])
    telegram_username = telegram_identity["username"] || telegram_identity[:username]

    if telegram_user_id == "" or not nonblank?(connect_id) do
      Repo.rollback(:invalid_telegram_identity)
    end

    displaced =
      Repo.all(
        from(link in TelegramDMLink,
          where: link.workspace_id == ^workspace_id or link.telegram_user_id == ^telegram_user_id,
          lock: "FOR UPDATE"
        )
      )

    Repo.delete_all(
      from(link in TelegramDMLink,
        where: link.workspace_id == ^workspace_id or link.telegram_user_id == ^telegram_user_id
      )
    )

    link =
      %TelegramDMLink{}
      |> TelegramDMLink.changeset(%{
        workspace_id: workspace_id,
        owner_user_id: owner_user_id,
        telegram_user_id: telegram_user_id,
        telegram_username: telegram_username,
        connect_id: String.trim(connect_id)
      })
      |> Repo.insert()
      |> case do
        {:ok, link} -> link
        {:error, changeset} -> Repo.rollback(changeset)
      end

    %{link: link, displaced: displaced}
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp normalize_code(value) when is_binary(value),
    do: value |> String.trim() |> String.trim_leading("/link ")

  defp normalize_user_id(nil), do: ""
  defp normalize_user_id(value), do: value |> to_string() |> String.trim()
  defp state_hash(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp unix(nil), do: nil
  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
end
