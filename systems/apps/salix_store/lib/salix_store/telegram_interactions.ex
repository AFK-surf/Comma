defmodule SalixStore.TelegramInteractions do
  @moduledoc """
  Postgres authority for Telegram interaction records and exact prompt lookup.

  One row owns the send claim, prompt receipt and immutable decision. Domain
  reducers run under its row lock; provider HTTP and Router delivery run outside
  transactions. Modeled in tla/salix/TelegramInteractions.tla.
  """

  import Ecto.Query
  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "telegram_interactions" do
      field(:group_id, :string, primary_key: true)
      field(:request_id, :string, primary_key: true)
      field(:connect_id, :string)
      field(:message_id, :integer)
      field(:body, :map)
    end
  end

  def create(record) do
    scope = record["scope"]

    case Repo.insert_all(
           Row,
           [
             %{
               group_id: scope["group_id"],
               request_id: record["id"],
               connect_id: scope["connect_id"],
               message_id: record["message_id"],
               body: record
             }
           ],
           on_conflict: :nothing,
           conflict_target: [:group_id, :request_id],
           log: false
         ) do
      {1, _} -> {:ok, record}
      {0, _} -> {:error, :exists}
    end
  rescue
    error in Postgrex.Error -> database_error(error)
    _error in DBConnection.ConnectionError -> {:error, :unavailable}
  end

  def get(group_id, request_id) do
    case Repo.get_by(Row, [group_id: group_id, request_id: request_id], log: false) do
      nil -> {:error, :not_found}
      row -> {:ok, row.body}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  end

  def get_by_reply(group_id, connect_id, message_id) do
    case Repo.get_by(
           Row,
           [group_id: group_id, connect_id: connect_id, message_id: message_id],
           log: false
         ) do
      nil -> {:error, :not_found}
      row -> {:ok, row.body}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  end

  # A second candidate is an ambiguity, never "latest wins".
  def get_location_response(group_id, connect_id, chat_id, thread_id, epoch, message_id, now) do
    base =
      Row
      |> where([r], r.group_id == ^group_id and r.connect_id == ^connect_id)
      |> where([r], fragment("?->>'type' = 'location'", r.body))
      |> where([r], fragment("?->'scope'->>'chat_id' = ?", r.body, ^chat_id))
      |> where(
        [r],
        fragment("COALESCE(?->'scope'->>'message_thread_id', '') = ?", r.body, ^thread_id)
      )
      |> where([r], fragment("?->'connect_epoch' = ?::jsonb", r.body, ^epoch))

    replay =
      base
      |> where([r], fragment("?->>'response_message_id' = ?", r.body, ^to_string(message_id)))
      |> limit(2)
      |> Repo.all(log: false)

    candidates =
      if replay == [] do
        base
        |> where([r], fragment("(?->>'expires_at')::bigint > ?", r.body, ^now))
        |> where([r], fragment("?->>'status' IN ('pending', 'decided')", r.body))
        |> where([r], r.message_id < ^message_id)
        |> limit(2)
        |> Repo.all(log: false)
      else
        replay
      end

    case candidates do
      [row] -> {:ok, row.body}
      [] -> {:error, :not_found}
      _ -> {:error, :ambiguous_location_request}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  end

  def newer_location_prompt?(record) do
    scope = record["scope"]

    exists =
      Row
      |> where([r], r.group_id == ^scope["group_id"] and r.connect_id == ^scope["connect_id"])
      |> where([r], r.message_id > ^record["message_id"])
      |> where([r], fragment("?->>'type' = 'location'", r.body))
      |> where([r], fragment("?->'scope'->>'chat_id' = ?", r.body, ^scope["chat_id"]))
      |> Repo.exists?(log: false)

    {:ok, exists}
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  end

  def update(group_id, request_id, reducer) do
    Repo.transaction(
      fn ->
        row =
          Row
          |> where([r], r.group_id == ^group_id and r.request_id == ^request_id)
          |> lock("FOR UPDATE")
          |> Repo.one(log: false)

        if is_nil(row), do: Repo.rollback(:not_found)

        case reducer.(row.body) do
          {:error, reason} ->
            Repo.rollback(reason)

          {:unchanged, record} ->
            record

          record when is_map(record) ->
            Row
            |> where([r], r.group_id == ^group_id and r.request_id == ^request_id)
            |> Repo.update_all([set: [body: record, message_id: record["message_id"]]],
              log: false
            )

            record
        end
      end,
      log: false
    )
  rescue
    error in Postgrex.Error -> database_error(error)
    _error in DBConnection.ConnectionError -> {:error, :unavailable}
  end

  defp database_error(%Postgrex.Error{
         postgres: %{code: :unique_violation, constraint: "telegram_interactions_prompt_index"}
       }),
       do: {:error, :prompt_index_conflict}

  defp database_error(_error), do: {:error, :unavailable}
end
