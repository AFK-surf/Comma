defmodule Comma.LineLinks do
  @moduledoc """
  Comma-owned LINE account to Workspace binding state.

  Comma has one LINE Official Account. A Workspace owner connects LINE with a
  ten-minute claim code: Settings shows it, and the person sends `link <code>`
  to the account from LINE. One LINE user binds to at most one Workspace, and
  a Workspace to at most one LINE user. The lifecycle follows the Telegram
  binding (tla/salix/CommaTelegramBinding.tla): consume the claim, retire
  routes, prepare a disabled connect, commit the binding, then activate.
  """

  import Ecto.Query

  alias Comma.Data.{LineDMClaimCode, LineDMLink, Workspace}
  alias Comma.{Accounts, Repo, Workspaces}

  @claim_ttl_seconds 10 * 60
  @claim_bytes 6

  @doc """
  Runs `fun` while this node holds the LINE lifecycle lock. A concurrent
  lifecycle returns `{:error, :line_link_busy}` instead of waiting, as for
  Telegram (`Comma.TelegramLinks.with_lifecycle_lock/1`).
  """
  def with_lifecycle_lock(fun) do
    Repo.checkout(fn ->
      case Repo.query!("SELECT pg_try_advisory_lock(4412741, 21576)").rows do
        [[true]] ->
          try do
            fun.()
          after
            Repo.query!("SELECT pg_advisory_unlock(4412741, 21576)")
          end

        [[false]] ->
          {:error, :line_link_busy}
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
      expires_at = DateTime.add(SystemsClock.utc_now(), @claim_ttl_seconds, :second)
      create_claim(workspace, user["id"], expires_at, 0)
    end
  end

  @doc "Consumes an unexpired claim code; the binding must then use it as its proof."
  def take_claim(code) when is_binary(code) do
    now = SystemsClock.utc_now()
    normalized_code = normalize_code(code)

    Repo.transaction(fn ->
      claim =
        Repo.one(
          from(row in LineDMClaimCode,
            where:
              row.code == ^normalized_code and row.expires_at > ^now and is_nil(row.consumed_at),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:invalid_line_claim)

      claim = claim |> Ecto.Changeset.change(consumed_at: now) |> Repo.update!()

      with {:ok, user} <- Accounts.get_user(claim.owner_user_id),
           {:ok, workspace} <- Workspaces.authorize(user, %{}, claim.workspace_id) do
        %{claim: claim, user: user, workspace: workspace}
      else
        _unavailable -> Repo.rollback(:invalid_line_claim)
      end
    end)
    |> unwrap_transaction()
  end

  def take_claim(_code), do: {:error, :invalid_line_claim}

  def validate_connection_attempt(user_id, workspace_id, proof) do
    Repo.transaction(fn ->
      lock_workspace!(workspace_id)
      require_current_claim!(proof, workspace_id, user_id)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def put_link(user_id, workspace_id, line_identity, connect_id, proof) do
    with {:ok, user} <- Accounts.get_user(user_id),
         {:ok, _workspace} <- Workspaces.authorize(user, %{}, workspace_id) do
      Repo.transaction(fn ->
        lock_workspace!(workspace_id)
        require_current_claim!(proof, workspace_id, user_id)
        result = replace_link(workspace_id, user_id, line_identity, connect_id)
        clear_claims(workspace_id)
        result
      end)
      |> unwrap_transaction()
    end
  end

  def resolve_sender(line_user_id) do
    case get_link_by_sender(line_user_id) do
      nil ->
        {:error, :line_not_linked}

      link ->
        with {:ok, user} <- Accounts.get_user(link.owner_user_id),
             {:ok, workspace} <- Workspaces.authorize(user, %{}, link.workspace_id) do
          {:ok, %{link: link, user: user, workspace: workspace}}
        else
          _unavailable -> {:error, :line_not_linked}
        end
    end
  end

  def delete(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      Repo.transaction(fn ->
        lock_workspace!(workspace_id)

        {count, _} =
          Repo.delete_all(
            from(link in LineDMLink,
              where: link.workspace_id == ^workspace_id and link.owner_user_id == ^user["id"]
            )
          )

        clear_claims(workspace_id)
        count > 0
      end)
      |> case do
        {:ok, removed?} -> {:ok, workspace, removed?}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Cancels the Workspace's open claim, if any. It never removes a link."
  def cancel_claim(user, session, workspace_id) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      with_lifecycle_lock(fn ->
        Repo.transaction(fn ->
          lock_workspace!(workspace_id)
          clear_claims(workspace_id)
          :ok
        end)
        |> unwrap_transaction()
      end)
    end
  end

  def public_link(nil), do: nil

  def public_link(%LineDMLink{} = link) do
    %{
      "line_user_id" => link.line_user_id,
      "line_display_name" => link.line_display_name,
      "connection_id" => link.connect_id,
      "connected_at" => unix(link.inserted_at),
      "updated_at" => unix(link.updated_at)
    }
  end

  def public_claim(nil), do: nil

  def public_claim(%LineDMClaimCode{} = claim) do
    %{"code" => claim.code, "expires_at" => unix(claim.expires_at)}
  end

  def get_link(workspace_id), do: Repo.get(LineDMLink, workspace_id)

  def get_link_by_sender(line_user_id),
    do: Repo.get_by(LineDMLink, line_user_id: normalize_user_id(line_user_id))

  def get_active_claim(workspace_id) do
    now = SystemsClock.utc_now()

    Repo.one(
      from(claim in LineDMClaimCode,
        where:
          claim.workspace_id == ^workspace_id and claim.expires_at > ^now and
            is_nil(claim.consumed_at)
      )
    )
  end

  @doc "Whether `text` is a link command, and its code."
  def claim_command(text) when is_binary(text) do
    case String.split(String.trim(text), ~r/\s+/, parts: 3) do
      [command, code] when command in ["link", "Link", "LINK"] -> {:ok, code}
      _other -> :error
    end
  end

  def claim_command(_text), do: :error

  defp create_claim(workspace, user_id, expires_at, attempts) when attempts < 3 do
    code =
      SystemsRuntime.Proc.random_bytes(@claim_bytes)
      |> Base.encode32(padding: false)
      |> String.slice(0, 8)

    Repo.transaction(fn ->
      lock_workspace!(workspace["id"])
      clear_claims(workspace["id"])

      %LineDMClaimCode{}
      |> LineDMClaimCode.changeset(%{
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
    do: {:error, :line_claim_unavailable}

  defp lock_workspace!(workspace_id) do
    Repo.one(from(row in Workspace, where: row.id == ^workspace_id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp clear_claims(workspace_id),
    do: Repo.delete_all(from(row in LineDMClaimCode, where: row.workspace_id == ^workspace_id))

  defp require_current_claim!(%LineDMClaimCode{code: code}, workspace_id, user_id) do
    now = SystemsClock.utc_now()
    current = Repo.get(LineDMClaimCode, code)

    unless current && current.workspace_id == workspace_id && current.owner_user_id == user_id &&
             current.consumed_at && DateTime.compare(current.expires_at, now) == :gt do
      Repo.rollback(:invalid_line_connection_attempt)
    end
  end

  defp require_current_claim!(_proof, _workspace_id, _user_id),
    do: Repo.rollback(:invalid_line_connection_attempt)

  defp replace_link(workspace_id, owner_user_id, line_identity, connect_id) do
    line_user_id = normalize_user_id(line_identity["id"])

    if line_user_id == "" or not nonblank?(connect_id) do
      Repo.rollback(:invalid_line_identity)
    end

    displaced =
      Repo.all(
        from(link in LineDMLink,
          where: link.workspace_id == ^workspace_id or link.line_user_id == ^line_user_id,
          lock: "FOR UPDATE"
        )
      )

    Repo.delete_all(
      from(link in LineDMLink,
        where: link.workspace_id == ^workspace_id or link.line_user_id == ^line_user_id
      )
    )

    link =
      %LineDMLink{}
      |> LineDMLink.changeset(%{
        workspace_id: workspace_id,
        owner_user_id: owner_user_id,
        line_user_id: line_user_id,
        line_display_name: line_identity["display_name"],
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

  defp normalize_code(value), do: value |> String.trim() |> String.upcase()
  defp normalize_user_id(nil), do: ""
  defp normalize_user_id(value), do: value |> to_string() |> String.trim()
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp unix(nil), do: nil
  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
end
