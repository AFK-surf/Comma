defmodule Comma.ProfileAvatarTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts.{User, UserAvatar}
  alias Comma.ProfileAvatar
  alias Comma.Workers.ProfileAvatarCleanup

  defmodule StorageFake do
    @behaviour Comma.ProfileAvatar.Storage

    def start_put(key, content_type) do
      session_url = "https://upload.example/#{URI.encode_www_form(key)}"
      send(test_pid(), {:avatar_start_put, key, content_type, session_url})
      Application.get_env(:comma_core, :profile_avatar_start_put_result, {:ok, session_url})
    end

    def finish_put(session_url, path, content_type, byte_size) do
      key = key_from_session(session_url)
      body = File.read!(path)
      send(test_pid(), {:avatar_put, key, File.read!(path), content_type})

      Agent.update(objects_pid(), fn state ->
        put_in(state, [:pending, session_url], {key, body, byte_size})
      end)

      case Application.get_env(:comma_core, :profile_avatar_put_result, :ok) do
        {:error_after_apply, reason} ->
          apply_pending(session_url)
          {:error, reason}

        result ->
          if result == :ok, do: apply_pending(session_url)
          result
      end
    end

    def cancel_put(session_url) do
      send(test_pid(), {:avatar_cancel_put, session_url})

      if Application.get_env(:comma_core, :profile_avatar_apply_put_during_cancel, false) do
        apply_pending(session_url)
      end

      Agent.update(objects_pid(), fn state ->
        update_in(state, [:pending], &Map.delete(&1, session_url))
      end)

      Application.get_env(:comma_core, :profile_avatar_cancel_put_result, :ok)
    end

    def get(key) do
      send(test_pid(), {:avatar_get, key})

      case Application.get_env(:comma_core, :profile_avatar_get_result, :from_objects) do
        :from_objects ->
          case Agent.get(objects_pid(), &get_in(&1, [:objects, key])) do
            nil -> {:error, :not_found}
            body -> {:ok, body}
          end

        result ->
          result
      end
    end

    def delete(key) do
      send(test_pid(), {:avatar_delete, key})

      Agent.update(objects_pid(), fn state ->
        update_in(state, [:objects], &Map.delete(&1, key))
      end)

      Application.get_env(:comma_core, :profile_avatar_delete_result, :ok)
    end

    def object?(key), do: Agent.get(objects_pid(), &Map.has_key?(&1.objects, key))

    defp apply_pending(session_url) do
      Agent.update(objects_pid(), fn state ->
        case get_in(state, [:pending, session_url]) do
          {key, body, _byte_size} ->
            state
            |> put_in([:objects, key], body)
            |> update_in([:pending], &Map.delete(&1, session_url))

          nil ->
            state
        end
      end)
    end

    defp key_from_session(session_url) do
      session_url
      |> URI.parse()
      |> Map.fetch!(:path)
      |> String.trim_leading("/")
      |> URI.decode_www_form()
    end

    defp objects_pid, do: Application.fetch_env!(:comma_core, :profile_avatar_objects_pid)
    defp test_pid, do: Application.fetch_env!(:comma_core, :profile_avatar_test_pid)
  end

  setup do
    previous = Application.get_env(:comma_core, :profile_avatar)
    {:ok, objects_pid} = Agent.start_link(fn -> %{objects: %{}, pending: %{}} end)
    Application.put_env(:comma_core, :profile_avatar, adapter: StorageFake, bucket: "test")
    Application.put_env(:comma_core, :profile_avatar_test_pid, self())
    Application.put_env(:comma_core, :profile_avatar_objects_pid, objects_pid)
    Application.put_env(:comma_core, :profile_avatar_put_result, :ok)
    Application.put_env(:comma_core, :profile_avatar_delete_result, :ok)

    on_exit(fn ->
      Application.put_env(:comma_core, :profile_avatar, previous)
      Application.delete_env(:comma_core, :profile_avatar_test_pid)
      Application.delete_env(:comma_core, :profile_avatar_objects_pid)
      Application.delete_env(:comma_core, :profile_avatar_start_put_result)
      Application.delete_env(:comma_core, :profile_avatar_put_result)
      Application.delete_env(:comma_core, :profile_avatar_get_result)
      Application.delete_env(:comma_core, :profile_avatar_cancel_put_result)
      Application.delete_env(:comma_core, :profile_avatar_apply_put_during_cancel)
      Application.delete_env(:comma_core, :profile_avatar_delete_result)
    end)

    assert {:ok, user} = Comma.Accounts.create_user(%{"email" => "profile@example.com"})
    %{user: user}
  end

  test "GCS uses finite connect and request deadlines" do
    client = Comma.ProfileAvatar.Storage.GCS.connection_for_token("test-token")

    assert {Tesla.Adapter.Httpc, options} = Tesla.Client.adapter(client)
    assert options[:connect_timeout] == 5_000
    assert options[:timeout] == 30_000
  end

  test "profile names are trimmed and bounded", %{user: user} do
    assert {:ok, profile} = ProfileAvatar.update_name(user["id"], %{"name" => "  Ada  "})
    assert profile["name"] == "Ada"

    assert {:error, :name_required} = ProfileAvatar.update_name(user["id"], %{"name" => " "})

    assert {:error, :name_too_long} =
             ProfileAvatar.update_name(user["id"], %{"name" => String.duplicate("a", 65)})
  end

  @tag :tmp_dir
  test "an immutable confirmed upload becomes current and replacement queues the old key", %{
    user: user,
    tmp_dir: tmp_dir
  } do
    first_path = Path.join(tmp_dir, "first.png")
    second_path = Path.join(tmp_dir, "second.webp")
    File.write!(first_path, <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)
    File.write!(second_path, <<"RIFF", 4::little-32, "WEBP", 0, 0, 0, 0>>)

    assert {:ok, first} = ProfileAvatar.upload(user["id"], %{path: first_path})
    assert_receive {:avatar_put, first_key, _body, "image/png"}
    assert first_key =~ "/#{first["avatar_id"]}.png"

    assert {:ok, second} = ProfileAvatar.upload(user["id"], %{path: second_path})
    assert_receive {:avatar_put, second_key, _body, "image/webp"}
    assert second_key =~ "/#{second["avatar_id"]}.webp"
    refute first["avatar_id"] == second["avatar_id"]

    assert Repo.get!(User, user["id"]).avatar_id == second["avatar_id"]
    assert Repo.get!(UserAvatar, second["avatar_id"]).status == "active"
    assert Repo.get!(UserAvatar, first["avatar_id"]).status == "cleanup"
  end

  @tag :tmp_dir
  test "an unapplied ambiguous upload keeps its leased row until cleanup is safe", %{
    user: user,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "avatar.jpg")
    File.write!(path, <<0xFF, 0xD8, 0xFF, 0, 0, 0>>)
    Application.put_env(:comma_core, :profile_avatar_put_result, {:error, :timeout})

    assert {:error, {:storage, :timeout}} = ProfileAvatar.upload(user["id"], %{path: path})
    assert_receive {:avatar_get, _key}
    assert Repo.get!(User, user["id"]).avatar_id == nil

    assert [%UserAvatar{status: "pending", upload_token: token, upload_deadline_at: deadline}] =
             Repo.all(UserAvatar)

    assert is_binary(token)
    assert DateTime.compare(deadline, DateTime.utc_now()) == :gt

    assert :ok =
             ProfileAvatarCleanup.perform(%Oban.Job{
               args: %{"avatar_id" => Repo.one!(UserAvatar).id}
             })

    refute_receive {:avatar_delete, _key}
    assert Repo.one!(UserAvatar).status == "pending"
  end

  @tag :tmp_dir
  test "an applied upload with a lost response settles by exact GET and activates", %{
    user: user,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "avatar.png")
    File.write!(path, <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)
    Application.put_env(:comma_core, :profile_avatar_put_result, {:error_after_apply, :timeout})

    assert {:ok, profile} = ProfileAvatar.upload(user["id"], %{path: path})
    assert_receive {:avatar_get, key}
    assert key =~ profile["avatar_id"]
    assert Repo.get!(User, user["id"]).avatar_id == profile["avatar_id"]
    assert Repo.get!(UserAvatar, profile["avatar_id"]).status == "active"
  end

  @tag :tmp_dir
  test "cleanup fences a timed-out PUT that applies after settlement GET", %{
    user: user,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "late.png")
    File.write!(path, <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)
    Application.put_env(:comma_core, :profile_avatar_put_result, {:error, :timeout})

    assert {:error, {:storage, :timeout}} = ProfileAvatar.upload(user["id"], %{path: path})
    assert_receive {:avatar_get, key}
    avatar = Repo.one!(UserAvatar)
    assert avatar.status == "pending"
    assert is_binary(avatar.upload_session_url)
    refute StorageFake.object?(key)

    expire_upload_lease!(avatar)
    Application.put_env(:comma_core, :profile_avatar_apply_put_during_cancel, true)

    assert :ok = ProfileAvatarCleanup.perform(%Oban.Job{args: %{"avatar_id" => avatar.id}})
    assert_receive {:avatar_cancel_put, session_url}
    assert session_url == avatar.upload_session_url
    assert_receive {:avatar_delete, ^key}
    refute StorageFake.object?(key)
    refute Repo.get(UserAvatar, avatar.id)
  end

  test "cleanup conditionally claims stale pending rows before deleting", %{user: user} do
    avatar = insert_avatar(user["id"], "pending")
    expire_upload_lease!(avatar)

    assert :ok = ProfileAvatarCleanup.perform(%Oban.Job{args: %{"avatar_id" => avatar.id}})
    assert_receive {:avatar_cancel_put, _session_url}
    assert_receive {:avatar_delete, key}
    assert key == avatar.object_key
    refute Repo.get(UserAvatar, avatar.id)
  end

  test "cleanup retains its tombstone when provider session cancellation is ambiguous", %{
    user: user
  } do
    avatar = insert_avatar(user["id"], "pending")
    expire_upload_lease!(avatar)
    Application.put_env(:comma_core, :profile_avatar_cancel_put_result, {:error, :timeout})

    assert {:error, :timeout} =
             ProfileAvatarCleanup.perform(%Oban.Job{args: %{"avatar_id" => avatar.id}})

    assert_receive {:avatar_cancel_put, _session_url}
    refute_receive {:avatar_delete, _key}
    assert Repo.get!(UserAvatar, avatar.id).status == "cleanup"
  end

  test "cleanup never claims a pending row before its upload deadline", %{user: user} do
    avatar = insert_avatar(user["id"], "pending")

    assert :ok = ProfileAvatarCleanup.perform(%Oban.Job{args: %{"avatar_id" => avatar.id}})
    refute_receive {:avatar_delete, _key}
    assert Repo.get!(UserAvatar, avatar.id).status == "pending"
  end

  test "cleanup cannot delete a row which activation already made active", %{user: user} do
    avatar = insert_avatar(user["id"], "active")
    user_row = Repo.get!(User, user["id"])
    Repo.update!(Ecto.Changeset.change(user_row, avatar_id: avatar.id))

    assert :ok = ProfileAvatarCleanup.perform(%Oban.Job{args: %{"avatar_id" => avatar.id}})
    refute_receive {:avatar_delete, _key}
    assert Repo.get!(UserAvatar, avatar.id).status == "active"
  end

  defp insert_avatar(user_id, status) do
    id = UserAvatar.new_id()

    lease =
      if status == "pending" do
        %{
          upload_token: "lease-#{id}",
          upload_deadline_at:
            DateTime.add(DateTime.utc_now(), ProfileAvatar.upload_lease_seconds(), :second),
          upload_session_url: "https://upload.example/#{id}"
        }
      else
        %{}
      end

    attrs =
      Map.merge(
        %{
          id: id,
          user_id: user_id,
          object_key: "users/#{user_id}/#{id}.png",
          content_type: "image/png",
          byte_size: 12,
          status: status
        },
        lease
      )

    %UserAvatar{}
    |> UserAvatar.changeset(attrs)
    |> Repo.insert!()
  end

  defp expire_upload_lease!(avatar) do
    Repo.update!(
      Ecto.Changeset.change(avatar,
        upload_deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)
      )
    )
  end
end
