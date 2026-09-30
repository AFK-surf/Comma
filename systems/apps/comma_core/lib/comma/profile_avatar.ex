defmodule Comma.ProfileAvatar do
  @moduledoc "User-owned profile name and immutable private avatar lifecycle."

  import Ecto.Query

  alias Comma.Accounts.{User, UserAvatar}
  alias Comma.ProfileAvatar.Storage
  alias Comma.Repo

  @max_bytes 102_400
  @max_name_length 64
  @upload_lease_seconds 90

  def get(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, public_profile(user)}
    end
  end

  def update_name(user_id, attrs) when is_map(attrs) do
    with {:ok, name} <- normalize_name(attrs["name"] || attrs[:name]),
         {:ok, user} <- Comma.Accounts.update_user(user_id, %{"name" => name}) do
      {:ok, profile_from_public_user(user)}
    end
  end

  def update_name(_user_id, _attrs), do: {:error, :invalid_profile}

  def upload(user_id, %{path: path}) when is_binary(path) do
    with true <- Storage.configured?() || {:error, :avatar_storage_unavailable},
         {:ok, content_type, byte_size} <- inspect_file(path),
         {:ok, avatar} <- insert_pending(user_id, content_type, byte_size),
         {:ok, avatar} <- start_pending_upload(avatar),
         :ok <- upload_pending(avatar, path),
         {:ok, profile, old_avatar_id} <- activate(avatar),
         :ok <- enqueue_cleanup(old_avatar_id) do
      {:ok, profile}
    end
  end

  def upload(_user_id, _upload), do: {:error, :avatar_required}

  def fetch(user_id, avatar_id) do
    query =
      from(avatar in UserAvatar,
        join: user in User,
        on: user.avatar_id == avatar.id,
        where: user.id == ^user_id and avatar.id == ^avatar_id and avatar.status == "active",
        select: avatar
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      avatar ->
        case Storage.get(avatar.object_key) do
          {:ok, body} -> {:ok, avatar.content_type, body}
          {:error, :not_found} -> {:error, :not_found}
          {:error, reason} -> {:error, {:storage, reason}}
        end
    end
  end

  def delete(user_id) do
    Repo.transaction(fn ->
      user = Repo.one(from(row in User, where: row.id == ^user_id, lock: "FOR UPDATE"))
      if is_nil(user), do: Repo.rollback(:not_found)

      old_avatar_id = user.avatar_id

      if is_binary(old_avatar_id) do
        from(avatar in UserAvatar,
          where: avatar.id == ^old_avatar_id and avatar.user_id == ^user_id
        )
        |> Repo.update_all(set: [status: "cleanup", updated_at: DateTime.utc_now()])
      end

      case Repo.update(Ecto.Changeset.change(user, avatar_id: nil)) do
        {:ok, updated} -> {public_profile(updated), old_avatar_id}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {profile, old_avatar_id}} ->
        :ok = enqueue_cleanup(old_avatar_id)
        {:ok, profile}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def inspect_file(path) do
    with {:ok, %{size: size}} when size > 0 and size <= @max_bytes <- File.stat(path),
         {:ok, header} <- read_header(path),
         {:ok, content_type} <- infer_content_type(header) do
      {:ok, content_type, size}
    else
      {:ok, %{size: size}} when size > @max_bytes -> {:error, :avatar_too_large}
      {:ok, _stat} -> {:error, :invalid_avatar}
      {:error, reason} when reason in [:enoent, :eacces] -> {:error, :invalid_avatar}
      {:error, reason} -> {:error, reason}
    end
  end

  def upload_lease_seconds, do: @upload_lease_seconds

  defp normalize_name(value) when is_binary(value) do
    name = String.trim(value)

    cond do
      name == "" -> {:error, :name_required}
      String.length(name) > @max_name_length -> {:error, :name_too_long}
      true -> {:ok, name}
    end
  end

  defp normalize_name(_value), do: {:error, :name_required}

  defp insert_pending(user_id, content_type, byte_size) do
    if Repo.exists?(from(user in User, where: user.id == ^user_id)) do
      id = UserAvatar.new_id()
      upload_token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      extension = extension(content_type)

      %UserAvatar{}
      |> UserAvatar.changeset(%{
        id: id,
        user_id: user_id,
        object_key: "users/#{user_id}/#{id}.#{extension}",
        content_type: content_type,
        byte_size: byte_size,
        status: "pending",
        upload_token: upload_token,
        upload_deadline_at: DateTime.add(DateTime.utc_now(), @upload_lease_seconds, :second)
      })
      |> Repo.insert()
    else
      {:error, :not_found}
    end
  end

  defp start_pending_upload(avatar) do
    case Storage.start_put(avatar.object_key, avatar.content_type) do
      {:ok, session_url} ->
        persisted =
          from(row in UserAvatar,
            where:
              row.id == ^avatar.id and row.status == "pending" and
                row.upload_token == ^avatar.upload_token
          )
          |> Repo.update_all(
            set: [upload_session_url: session_url, updated_at: DateTime.utc_now()]
          )

        case persisted do
          {1, _rows} ->
            {:ok, Repo.get!(UserAvatar, avatar.id)}

          _conflict ->
            _result = Storage.cancel_put(session_url)
            mark_cleanup(avatar.id)
            :ok = enqueue_cleanup(avatar.id)
            {:error, :avatar_upload_conflict}
        end

      {:error, reason} ->
        mark_cleanup(avatar.id)
        :ok = enqueue_cleanup(avatar.id)
        {:error, {:storage, reason}}
    end
  end

  defp upload_pending(avatar, path) do
    case Storage.finish_put(
           avatar.upload_session_url,
           path,
           avatar.content_type,
           avatar.byte_size
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        case Storage.get(avatar.object_key) do
          {:ok, _body} ->
            :ok

          {:error, _settlement_reason} ->
            # The resumable session is durably discoverable on this row.
            # Cleanup must cancel that provider session before it may remove
            # the immutable object or its metadata tombstone.
            :ok = enqueue_cleanup(avatar.id, schedule_in: @upload_lease_seconds)
            {:error, {:storage, reason}}
        end
    end
  end

  defp activate(avatar) do
    # Modeled by Activate in tla/profile_avatar/ProfileAvatar.tla. The locked
    # pending row is the fence against stale-pending cleanup claiming the key.
    Repo.transaction(fn ->
      user = Repo.one(from(row in User, where: row.id == ^avatar.user_id, lock: "FOR UPDATE"))
      pending = Repo.one(from(row in UserAvatar, where: row.id == ^avatar.id, lock: "FOR UPDATE"))

      if is_nil(user) or is_nil(pending) or pending.status != "pending" or
           pending.upload_token != avatar.upload_token or
           DateTime.compare(pending.upload_deadline_at, DateTime.utc_now()) != :gt do
        Repo.rollback(:avatar_activation_conflict)
      end

      old_avatar_id = user.avatar_id

      if is_binary(old_avatar_id) do
        from(row in UserAvatar, where: row.id == ^old_avatar_id and row.user_id == ^user.id)
        |> Repo.update_all(set: [status: "cleanup", updated_at: DateTime.utc_now()])
      end

      with {:ok, _active} <-
             Repo.update(
               Ecto.Changeset.change(pending,
                 status: "active",
                 upload_token: nil,
                 upload_deadline_at: nil,
                 upload_session_url: nil
               )
             ),
           {:ok, updated_user} <-
             Repo.update(Ecto.Changeset.change(user, avatar_id: avatar.id)) do
        {public_profile(updated_user), old_avatar_id}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {profile, old_avatar_id}} ->
        {:ok, profile, old_avatar_id}

      {:error, reason} ->
        mark_cleanup(avatar.id)
        :ok = enqueue_cleanup(avatar.id)
        {:error, reason}
    end
  end

  defp mark_cleanup(avatar_id) do
    from(avatar in UserAvatar, where: avatar.id == ^avatar_id and avatar.status != "active")
    |> Repo.update_all(
      set: [
        status: "cleanup",
        upload_token: nil,
        upload_deadline_at: nil,
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  defp enqueue_cleanup(avatar_id, opts \\ [])

  defp enqueue_cleanup(nil, _opts), do: :ok

  defp enqueue_cleanup(avatar_id, opts) do
    try do
      case Oban.insert(
             Comma.Oban,
             Comma.Workers.ProfileAvatarCleanup.new(%{"avatar_id" => avatar_id}, opts)
           ) do
        {:ok, _job} -> :ok
        {:error, _reason} -> :ok
      end
    rescue
      RuntimeError -> :ok
    catch
      :exit, _reason -> :ok
    end
  end

  defp public_profile(%User{} = user) do
    %{
      "id" => user.id,
      "email" => user.email,
      "name" => user.name,
      "avatar_id" => user.avatar_id
    }
  end

  defp profile_from_public_user(user) do
    Map.take(user, ["id", "email", "name", "avatar_id"])
  end

  defp read_header(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      result = IO.binread(file, 16)
      File.close(file)

      case result do
        data when is_binary(data) -> {:ok, data}
        _ -> {:error, :invalid_avatar}
      end
    end
  end

  defp infer_content_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, "image/jpeg"}

  defp infer_content_type(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>),
    do: {:ok, "image/png"}

  defp infer_content_type(<<"RIFF", _size::little-32, "WEBP", _rest::binary>>),
    do: {:ok, "image/webp"}

  defp infer_content_type(_header), do: {:error, :unsupported_avatar_type}

  defp extension("image/jpeg"), do: "jpg"
  defp extension("image/png"), do: "png"
  defp extension("image/webp"), do: "webp"
end
