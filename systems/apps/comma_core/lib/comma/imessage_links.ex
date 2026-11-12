defmodule Comma.IMessageLinks do
  @moduledoc """
  Comma-owned iMessage account to Workspace binding state.
  Owns temporary claim intent, binding publication and revocation.
  Provider connection IDs reference the Salix-owned messaging connection.
  """

  import Ecto.Query

  alias Comma.Data.{IMessageDMClaimCode, IMessageDMLink, Workspace}
  alias Comma.{Accounts, Repo, Workspaces}

  @claim_ttl_seconds 10 * 60
  @binding_seconds 60
  @claim_bytes 9
  @guidance_interval_seconds 24 * 60 * 60

  # One shared product bot. Admission is non-blocking: a concurrent lifecycle
  # returns busy instead of holding a pool connection in an unbounded queue.
  # Session (not transaction) scope allows the binding COMMIT before activation.
  # DBConnection closes a checked-out connection when its borrower dies, so a
  # crashed coordinator releases this lock; late provider writes stay fenced by
  # immutable connect ids and terminal deletion.
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
          {:error, :imessage_link_busy}
      end
    end)
  end

  @doc "Bounded expiry cleanup on the shared receiver pass; active intents are never pruned."
  def prune_expired_claims do
    Repo.query!(
      "DELETE FROM comma_imessage_dm_claim_codes WHERE code IN (SELECT code FROM comma_imessage_dm_claim_codes WHERE expires_at < timezone('utc', now()) ORDER BY expires_at LIMIT 1000 FOR UPDATE SKIP LOCKED)"
    )

    Repo.query!(
      "DELETE FROM comma_imessage_guidance_replies WHERE sender_handle IN (SELECT sender_handle FROM comma_imessage_guidance_replies WHERE replied_at < $1 ORDER BY replied_at LIMIT 1000 FOR UPDATE SKIP LOCKED)",
      [guidance_cutoff()]
    )

    :ok
  end

  @doc """
  Takes today's guidance reply for a sender with no binding, at most one a day.
  Anyone can message a dedicated line, so repeated messages must not spend its
  daily send limit.
  """
  def take_guidance_reply(sender_handle) do
    now = SystemsClock.utc_now() |> DateTime.to_naive()

    Repo.query!(
      "INSERT INTO comma_imessage_guidance_replies AS row (sender_handle, replied_at) VALUES ($1, $2) ON CONFLICT (sender_handle) DO UPDATE SET replied_at = EXCLUDED.replied_at WHERE row.replied_at < $3",
      [normalize_user_id(sender_handle), now, guidance_cutoff()]
    ).num_rows == 1
  end

  # A person who connects or disconnects can need guidance again at once.
  defp clear_guidance_reply(sender_handle) do
    Repo.query!("DELETE FROM comma_imessage_guidance_replies WHERE sender_handle = $1", [
      sender_handle
    ])
  end

  defp guidance_cutoff do
    SystemsClock.utc_now()
    |> DateTime.add(-@guidance_interval_seconds, :second)
    |> DateTime.to_naive()
  end

  def get(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      {:ok, workspace, get_link(workspace_id)}
    end
  end

  @doc """
  Creates the Workspace's one connection attempt. A Photon attempt also names
  its line and assignment ID, and the handle that must answer it, if any.
  """
  def create_claim(user, session, workspace_id, attrs \\ %{}) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      expires_at = DateTime.add(SystemsClock.utc_now(), @claim_ttl_seconds, :second)
      create_claim(workspace, user["id"], expires_at, Map.new(attrs), 0)
    end
  end

  @doc """
  Consumes an attempt. The attempt must belong to the event's transport.
  A Photon attempt that names a handle also requires that handle.
  A mismatch leaves the attempt unconsumed.
  """
  def take_claim(code, transport \\ "relay", sender_handle \\ nil)

  def take_claim(code, transport, sender_handle) when is_binary(code) do
    now = SystemsClock.utc_now()
    normalized_code = normalize_code(code)

    Repo.transaction(fn ->
      claim =
        Repo.one(
          from(row in IMessageDMClaimCode,
            where:
              row.code == ^normalized_code and row.expires_at > ^now and is_nil(row.consumed_at),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:invalid_imessage_claim)

      unless claim.transport == transport and
               (transport != "photon" or is_nil(claim.sender_handle) or
                  claim.sender_handle == normalize_user_id(sender_handle)) do
        Repo.rollback(:invalid_imessage_claim)
      end

      claim = claim |> Ecto.Changeset.change(consumed_at: now) |> Repo.update!()

      with {:ok, user} <- Accounts.get_user(claim.owner_user_id),
           {:ok, workspace} <- Workspaces.authorize(user, %{}, claim.workspace_id) do
        %{claim: claim, user: user, workspace: workspace}
      else
        _unavailable -> Repo.rollback(:invalid_imessage_claim)
      end
    end)
    |> unwrap_transaction()
  end

  def take_claim(_code, _transport, _sender_handle), do: {:error, :invalid_imessage_claim}

  @doc "Whether `text` is the code of an open Photon attempt that this handle can answer."
  def photon_claim_code?(sender_handle, text) when is_binary(text) do
    now = SystemsClock.utc_now()
    code = normalize_code(text)
    sender = normalize_user_id(sender_handle)

    code != "" and sender != "" and
      Repo.exists?(
        from(row in IMessageDMClaimCode,
          where:
            row.code == ^code and row.transport == "photon" and
              (is_nil(row.sender_handle) or row.sender_handle == ^sender) and
              row.expires_at > ^now and is_nil(row.consumed_at)
        )
      )
  end

  def photon_claim_code?(_sender_handle, _text), do: false

  @doc "Whether `text` is the code of any open Photon attempt, for any handle."
  def open_photon_code?(text) when is_binary(text) do
    now = SystemsClock.utc_now()
    code = normalize_code(text)

    code != "" and
      Repo.exists?(
        from(row in IMessageDMClaimCode,
          where:
            row.code == ^code and row.transport == "photon" and row.expires_at > ^now and
              is_nil(row.consumed_at)
        )
      )
  end

  def open_photon_code?(_text), do: false

  @doc "Handles that a Photon binding or an open Photon attempt uses."
  def photon_handles_in_use do
    now = SystemsClock.utc_now()

    links =
      Repo.all(
        from(link in IMessageDMLink,
          where: link.transport == "photon",
          select: link.sender_handle
        )
      )

    claims =
      Repo.all(
        from(row in IMessageDMClaimCode,
          where:
            row.transport == "photon" and row.expires_at > ^now and
              not is_nil(row.sender_handle),
          select: row.sender_handle
        )
      )

    MapSet.new(links ++ claims)
  end

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

  def put_link(user_id, workspace_id, identity, connect_id, proof) do
    with {:ok, user} <- Accounts.get_user(user_id),
         {:ok, _workspace} <- Workspaces.authorize(user, %{}, workspace_id) do
      Repo.transaction(fn ->
        lock_workspace!(workspace_id)
        require_current_attempt!(proof, workspace_id, user_id)
        result = replace_link(workspace_id, user_id, identity, connect_id)
        clear_attempts(workspace_id)

        result
      end)
      |> unwrap_transaction()
    end
  end

  def resolve_sender(sender_handle) do
    case Repo.get_by(IMessageDMLink, sender_handle: normalize_user_id(sender_handle)) do
      nil ->
        {:error, :imessage_not_linked}

      link ->
        with {:ok, user} <- Accounts.get_user(link.owner_user_id),
             {:ok, workspace} <- Workspaces.authorize(user, %{}, link.workspace_id) do
          {:ok, %{link: link, user: user, workspace: workspace}}
        else
          _unavailable -> {:error, :imessage_not_linked}
        end
    end
  end

  def delete(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      Repo.transaction(fn ->
        lock_workspace!(workspace_id)

        {count, senders} =
          Repo.delete_all(
            from(link in IMessageDMLink,
              where: link.workspace_id == ^workspace_id and link.owner_user_id == ^user["id"],
              select: link.sender_handle
            )
          )

        Enum.each(senders, &clear_guidance_reply/1)
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

  def public_link(%IMessageDMLink{} = link) do
    %{
      "sender_handle" => link.sender_handle,
      "sender_label" => link.sender_label,
      "transport" => link.transport,
      "connection_id" => link.connect_id,
      "connected_at" => unix(link.inserted_at),
      "updated_at" => unix(link.updated_at)
    }
  end

  def public_claim(nil), do: nil

  def public_claim(%IMessageDMClaimCode{} = claim) do
    %{
      "code" => claim.code,
      "expires_at" => unix(claim.expires_at),
      "transport" => claim.transport
    }
    |> then(fn public ->
      if claim.transport == "photon",
        do:
          Map.merge(public, %{
            "sender_handle" => claim.sender_handle,
            "line_handle" => claim.line_handle
          }),
        else: public
    end)
  end

  def get_link(workspace_id), do: Repo.get(IMessageDMLink, workspace_id)

  # Cancel exactly the presented attempt, including an already exchanging
  # callback. A stale tab must not cancel a newer intent or disconnect a link.
  # This is the model's Expire transition, serialized with final publication.
  def cancel_attempt(user, session, workspace_id, attrs) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      with_lifecycle_lock(fn ->
        Repo.transaction(fn ->
          lock_workspace!(workspace_id)

          case attrs do
            %{"code" => code} when is_binary(code) and code != "" ->
              Repo.delete_all(
                from(row in IMessageDMClaimCode,
                  where: row.workspace_id == ^workspace_id and row.code == ^normalize_code(code)
                )
              )

            _ ->
              Repo.rollback(:invalid_imessage_connection_attempt)
          end

          :ok
        end)
        |> unwrap_transaction()
      end)
    end
  end

  def get_link_by_sender(sender_handle),
    do: Repo.get_by(IMessageDMLink, sender_handle: normalize_user_id(sender_handle))

  # An attempt stays active while its binding is made: `consumed_at` is set before
  # the link exists, and a reader that sees neither stops waiting for the link.
  # A binding that fails leaves the row, so the wait is bounded.
  def get_active_claim(workspace_id) do
    now = SystemsClock.utc_now()
    binding_since = DateTime.add(now, -@binding_seconds, :second)

    Repo.one(
      from(claim in IMessageDMClaimCode,
        where:
          claim.workspace_id == ^workspace_id and claim.expires_at > ^now and
            (is_nil(claim.consumed_at) or claim.consumed_at > ^binding_since)
      )
    )
  end

  defp create_claim(workspace, user_id, expires_at, attrs, attempts) when attempts < 3 do
    code = SystemsRuntime.Proc.random_bytes(@claim_bytes) |> Base.url_encode64(padding: false)

    Repo.transaction(fn ->
      lock_workspace!(workspace["id"])
      clear_attempts(workspace["id"])

      %IMessageDMClaimCode{}
      |> IMessageDMClaimCode.changeset(
        Map.merge(attrs, %{
          code: code,
          workspace_id: workspace["id"],
          owner_user_id: user_id,
          expires_at: expires_at
        })
      )
      |> Repo.insert()
      |> case do
        {:ok, claim} -> claim
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, claim} ->
        {:ok, workspace, claim}

      {:error, %Ecto.Changeset{}} ->
        create_claim(workspace, user_id, expires_at, attrs, attempts + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_claim(_workspace, _user_id, _expires_at, _attrs, _attempts),
    do: {:error, :imessage_claim_unavailable}

  defp lock_workspace!(workspace_id) do
    Repo.one(from(row in Workspace, where: row.id == ^workspace_id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp clear_attempts(workspace_id) do
    Repo.delete_all(from(row in IMessageDMClaimCode, where: row.workspace_id == ^workspace_id))
  end

  defp require_current_attempt!(%module{} = proof, workspace_id, user_id)
       when module == IMessageDMClaimCode do
    [{key, value}] = Ecto.primary_key(proof)
    now = SystemsClock.utc_now()

    current = Repo.get_by(module, [{key, value}])

    unless current && current.workspace_id == workspace_id && current.owner_user_id == user_id &&
             current.consumed_at && DateTime.compare(current.expires_at, now) == :gt do
      Repo.rollback(:invalid_imessage_connection_attempt)
    end
  end

  defp replace_link(workspace_id, owner_user_id, identity, connect_id) do
    sender_handle = normalize_user_id(identity["sender_handle"])
    sender_label = identity["sender_display_name"]

    if sender_handle == "" or not nonblank?(connect_id) do
      Repo.rollback(:invalid_identity)
    end

    displaced =
      Repo.all(
        from(link in IMessageDMLink,
          where: link.workspace_id == ^workspace_id or link.sender_handle == ^sender_handle,
          lock: "FOR UPDATE"
        )
      )

    Repo.delete_all(
      from(link in IMessageDMLink,
        where: link.workspace_id == ^workspace_id or link.sender_handle == ^sender_handle
      )
    )

    clear_guidance_reply(sender_handle)

    link =
      %IMessageDMLink{}
      |> IMessageDMLink.changeset(%{
        workspace_id: workspace_id,
        owner_user_id: owner_user_id,
        sender_handle: sender_handle,
        sender_label: sender_label,
        chat_guid: identity["chat_guid"],
        connect_id: String.trim(connect_id),
        transport: identity["transport"] || "relay",
        assignment_id: identity["assignment_id"]
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
    do: String.trim(value)

  defp normalize_user_id(nil), do: ""
  defp normalize_user_id(value), do: value |> to_string() |> String.trim()
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp unix(nil), do: nil
  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
end
