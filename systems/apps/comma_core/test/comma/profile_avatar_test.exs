defmodule Comma.ProfileAvatarTest do
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]

  alias Comma.Accounts.{User, UserAvatar}
  alias Comma.ProfileAvatar
  alias Comma.Workers.ProfileAvatarCleanup

  defmodule StorageFake do
    @behaviour Comma.ProfileAvatar.Storage

    def start_put(key, content_type) do
      session_url = "https://upload.example/#{URI.encode_www_form(key)}"
      SystemsRuntime.Proc.send(test_pid(), {:avatar_start_put, key, content_type, session_url})
      SystemsRuntime.get_env(:comma_core, :profile_avatar_start_put_result, {:ok, session_url})
    end

    def finish_put(session_url, path, content_type, byte_size) do
      key = key_from_session(session_url)
      body = File.read!(path)
      SystemsRuntime.Proc.send(test_pid(), {:avatar_put, key, File.read!(path), content_type})

      Agent.update(objects_pid(), fn state ->
        put_in(state, [:pending, session_url], {key, body, byte_size})
      end)

      case SystemsRuntime.get_env(:comma_core, :profile_avatar_put_result, :ok) do
        {:error_after_apply, reason} ->
          apply_pending(session_url)
          {:error, reason}

        result ->
          if result == :ok, do: apply_pending(session_url)
          result
      end
    end

    def cancel_put(session_url) do
      SystemsRuntime.Proc.send(test_pid(), {:avatar_cancel_put, session_url})

      if SystemsRuntime.get_env(:comma_core, :profile_avatar_apply_put_during_cancel, false) do
        apply_pending(session_url)
      end

      Agent.update(objects_pid(), fn state ->
        update_in(state, [:pending], &Map.delete(&1, session_url))
      end)

      SystemsRuntime.get_env(:comma_core, :profile_avatar_cancel_put_result, :ok)
    end

    def get(key) do
      SystemsRuntime.Proc.send(test_pid(), {:avatar_get, key})

      case SystemsRuntime.get_env(:comma_core, :profile_avatar_get_result, :from_objects) do
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
      SystemsRuntime.Proc.send(test_pid(), {:avatar_delete, key})

      Agent.update(objects_pid(), fn state ->
        update_in(state, [:objects], &Map.delete(&1, key))
      end)

      SystemsRuntime.get_env(:comma_core, :profile_avatar_delete_result, :ok)
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

    defp objects_pid, do: SystemsRuntime.fetch_env!(:comma_core, :profile_avatar_objects_pid)
    defp test_pid, do: SystemsRuntime.fetch_env!(:comma_core, :profile_avatar_test_pid)
  end

  setup do
    previous = SystemsRuntime.get_env(:comma_core, :profile_avatar)
    {:ok, objects_pid} = Agent.start_link(fn -> %{objects: %{}, pending: %{}} end)
    SystemsRuntime.put_env(:comma_core, :profile_avatar, adapter: StorageFake, bucket: "test")
    SystemsRuntime.put_env(:comma_core, :profile_avatar_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:comma_core, :profile_avatar_objects_pid, objects_pid)
    SystemsRuntime.put_env(:comma_core, :profile_avatar_put_result, :ok)
    SystemsRuntime.put_env(:comma_core, :profile_avatar_delete_result, :ok)

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_core, :profile_avatar, previous)
      SystemsRuntime.delete_env(:comma_core, :profile_avatar_test_pid)
      SystemsRuntime.delete_env(:comma_core, :profile_avatar_objects_pid)
      SystemsRuntime.delete_env(:comma_core, :profile_avatar_start_put_result)
      SystemsRuntime.delete_env(:comma_core, :profile_avatar_put_result)
      SystemsRuntime.delete_env(:comma_core, :profile_avatar_get_result)
      SystemsRuntime.delete_env(:comma_core, :profile_avatar_cancel_put_result)
      SystemsRuntime.delete_env(:comma_core, :profile_avatar_apply_put_during_cancel)
      SystemsRuntime.delete_env(:comma_core, :profile_avatar_delete_result)
    end)

    assert {:ok, user} = Comma.Accounts.create_user(%{"email" => "profile@example.com"})
    %{user: user}
  end

  @tag :tmp_dir
  test "avatars up to 2 MiB are stored and larger files are rejected", %{
    user: user,
    tmp_dir: tmp_dir
  } do
    png_header = <<0x89, "PNG\r\n", 0x1A, "\n">>
    at_limit = Path.join(tmp_dir, "at-limit.png")
    over_limit = Path.join(tmp_dir, "over-limit.png")
    File.write!(at_limit, [png_header, :binary.copy(<<0>>, 2_097_152 - 8)])
    File.write!(over_limit, [png_header, :binary.copy(<<0>>, 2_097_152 - 7)])

    assert {:ok, profile} = ProfileAvatar.upload(user["id"], %{path: at_limit})
    assert Repo.get!(UserAvatar, profile["avatar_id"]).byte_size == 2_097_152

    assert {:error, :avatar_too_large} = ProfileAvatar.upload(user["id"], %{path: over_limit})
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
    settle_receive({:avatar_put, first_key, _body, "image/png"})
    assert first_key =~ "/#{first["avatar_id"]}.png"

    assert {:ok, second} = ProfileAvatar.upload(user["id"], %{path: second_path})
    settle_receive({:avatar_put, second_key, _body, "image/webp"})
    assert second_key =~ "/#{second["avatar_id"]}.webp"
    refute first["avatar_id"] == second["avatar_id"]

    assert Repo.get!(User, user["id"]).avatar_id == second["avatar_id"]
    assert Repo.get!(UserAvatar, second["avatar_id"]).status == "active"
    assert Repo.get!(UserAvatar, first["avatar_id"]).status == "cleanup"
  end

  test "cleanup conditionally claims stale pending rows before deleting", %{user: user} do
    avatar = insert_avatar(user["id"], "pending")
    expire_upload_lease!(avatar)

    assert :ok = ProfileAvatarCleanup.perform(%Oban.Job{args: %{"avatar_id" => avatar.id}})
    settle_receive({:avatar_cancel_put, _session_url})
    settle_receive({:avatar_delete, key})
    assert key == avatar.object_key
    refute Repo.get(UserAvatar, avatar.id)
  end

  defp insert_avatar(user_id, status) do
    id = UserAvatar.new_id()

    lease =
      if status == "pending" do
        %{
          upload_token: "lease-#{id}",
          upload_deadline_at:
            DateTime.add(SystemsClock.utc_now(), ProfileAvatar.upload_lease_seconds(), :second),
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
        upload_deadline_at: DateTime.add(SystemsClock.utc_now(), -1, :second)
      )
    )
  end
end
