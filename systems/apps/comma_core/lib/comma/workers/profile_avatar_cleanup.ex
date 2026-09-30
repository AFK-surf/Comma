defmodule Comma.Workers.ProfileAvatarCleanup do
  @moduledoc "Bounded, idempotent cleanup for replaced or ambiguous avatar objects."

  use Oban.Worker, queue: :comma_external, max_attempts: 10

  import Ecto.Query

  alias Comma.Accounts.UserAvatar
  alias Comma.ProfileAvatar.Storage
  alias Comma.Repo

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"avatar_id" => avatar_id}}) do
    cleanup_ids([avatar_id], DateTime.utc_now())
  end

  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    ids =
      from(avatar in UserAvatar,
        where:
          avatar.status == "cleanup" or
            (avatar.status == "pending" and avatar.upload_deadline_at < ^now),
        order_by: [asc: avatar.updated_at, asc: avatar.id],
        limit: @batch_size,
        select: avatar.id
      )
      |> Repo.all()

    cleanup_ids(ids, now)
  end

  defp cleanup_ids(ids, now) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Repo.get(UserAvatar, id) do
        nil ->
          {:cont, :ok}

        %UserAvatar{status: "active"} ->
          {:cont, :ok}

        %UserAvatar{status: "pending", upload_deadline_at: deadline} = avatar
        when not is_nil(deadline) ->
          if DateTime.compare(deadline, now) == :lt do
            claim_pending(avatar, now)
          else
            {:cont, :ok}
          end

        %UserAvatar{status: "pending"} ->
          {:halt, {:error, :invalid_upload_lease}}

        avatar ->
          delete_claimed(avatar)
      end
    end)
  end

  defp claim_pending(avatar, now) do
    {claimed, _rows} =
      from(row in UserAvatar,
        where:
          row.id == ^avatar.id and row.status == "pending" and
            row.upload_token == ^avatar.upload_token and row.upload_deadline_at < ^now
      )
      |> Repo.update_all(
        set: [
          status: "cleanup",
          upload_token: nil,
          upload_deadline_at: nil,
          updated_at: now
        ]
      )

    if claimed == 1, do: delete_claimed(avatar), else: {:cont, :ok}
  end

  # Modeled by ClaimGarbage/DeleteGarbage in tla/profile_avatar/ProfileAvatar.tla.
  # The conditional pending -> cleanup claim fences an activation transaction:
  # whichever DB transition wins determines whether this worker may delete.
  defp delete_claimed(avatar) do
    with :ok <- cancel_session(avatar),
         :ok <- Storage.delete(avatar.object_key) do
      from(row in UserAvatar, where: row.id == ^avatar.id and row.status == "cleanup")
      |> Repo.delete_all()

      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp cancel_session(%UserAvatar{upload_session_url: nil}), do: :ok

  defp cancel_session(%UserAvatar{upload_session_url: session_url}) do
    case Storage.cancel_put(session_url) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
