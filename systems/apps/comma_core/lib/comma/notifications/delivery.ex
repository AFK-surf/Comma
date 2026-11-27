defmodule Comma.Notifications.Delivery do
  @moduledoc "Shared Auth Session-owned APNs lease, authorization, and revocation primitives."
  import Ecto.Query

  alias Comma.{Accounts, Repo, Workspaces}
  alias Comma.Notifications.APNs

  @lease_seconds 120

  def with_lease(schema_mod, target_id, fun) when is_atom(schema_mod) and is_function(fun, 1) do
    case claim(schema_mod, target_id) do
      {:ok, target} ->
        try do
          fun.(target)
        after
          release(target)
        end

      error ->
        error
    end
  end

  def claim(schema_mod, target_id) when is_atom(schema_mod) do
    now = SystemsClock.utc_now()

    from(t in schema_mod,
      where:
        t.id == ^target_id and
          (is_nil(t.delivery_lease_until) or t.delivery_lease_until < ^now),
      select: t
    )
    |> Repo.update_all(set: [delivery_lease_until: DateTime.add(now, @lease_seconds, :second)])
    |> case do
      {1, [target]} ->
        {:ok, target}

      {0, _} ->
        if Repo.exists?(from(t in schema_mod, where: t.id == ^target_id)),
          do: {:error, :delivery_busy},
          else: :obsolete
    end
  end

  def release(%schema_mod{} = target) do
    leased(schema_mod, target) |> Repo.update_all(set: [delivery_lease_until: nil])
  end

  # Rotation replaces the row ID and clears the lease; an older lease then
  # writes nothing to the replacement address.
  def leased(%schema_mod{} = target), do: leased(schema_mod, target)

  def leased(schema_mod, target) when is_atom(schema_mod) do
    from(t in schema_mod,
      where: t.id == ^target.id and t.delivery_lease_until == ^target.delivery_lease_until
    )
  end

  def authority(target) do
    with true <- DateTime.compare(target.expires_at, SystemsClock.utc_now()) == :gt,
         {:ok, user, session} <- Accounts.resolve_session_id(target.auth_session_id),
         :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, target.group_id),
         true <- workspace["id"] == target.workspace_id do
      {:ok, user, session}
    else
      false -> {:error, :target_revoked}
      error -> error
    end
  end

  def send_authorized(%schema_mod{} = target, payload) do
    # An exact owner read may wait on another node. Recheck revocation and Group
    # ownership after that wait, immediately before entering the APNs transport.
    with true <- DateTime.compare(target.expires_at, SystemsClock.utc_now()) == :gt,
         {:ok, user, session} <- Accounts.resolve_session_id(target.auth_session_id),
         :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, target.group_id),
         true <- workspace["id"] == target.workspace_id,
         true <- Repo.exists?(leased(schema_mod, target)) do
      APNs.send(target, payload)
    else
      false ->
        {:error, :target_revoked}

      {:error, reason} when reason in [:not_found, :forbidden, :revoked, :expired, :disabled] ->
        {:error, :target_revoked}

      {:error, _} = error ->
        error
    end
  end

  def delivery_error(target, error, fallback \\ :invalid_projection)

  def delivery_error(target, {:error, reason}, _fallback)
      when reason in [
             :not_found,
             :forbidden,
             :revoked,
             :expired,
             :disabled,
             :invalid_token,
             :target_revoked
           ],
      do: remove(target)

  def delivery_error(_target, {:error, _} = error, _fallback), do: error
  def delivery_error(_target, _, fallback), do: {:error, fallback}

  def remove(%schema_mod{} = target) do
    Repo.delete_all(leased(schema_mod, target))
    :obsolete
  end

  def unrestricted(%{"session_source" => "user_login", "restricted" => false}), do: :ok
  def unrestricted(_), do: {:error, :forbidden}

  def normalize_locale("zh-Hans"), do: "zh-Hans"
  def normalize_locale(_), do: "en-US"
end
