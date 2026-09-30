defmodule SalixIM.Triage.RehearsalSlackReaction do
  @moduledoc """
  Set-like, process-local Slack reaction port for a zero-write rehearsal.

  One obligation id is bound to one exact workspace/channel/message/emoji
  tuple. Replaying that tuple is idempotent; trying to reuse the id for a
  different reaction fails closed.
  """

  @table __MODULE__

  alias SalixIM.Triage.SlackEffectAdapter

  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _table -> :ets.delete(@table)
    end

    _table = ensure_table()
    :ok
  end

  @spec records() :: [map()]
  def records do
    @table
    |> ensure_table()
    |> :ets.tab2list()
    |> Enum.map(fn {_obligation_id, record} -> record end)
    |> Enum.sort_by(& &1["obligation_id"])
  end

  @spec add(map(), String.t(), String.t(), keyword()) ::
          {:ok, %{already_reacted: boolean()}}
          | {:error, :invalid_product_obligation | :reaction_idempotency_conflict, false}
  def add(
        %{
          obligation_id: obligation_id,
          payload: %{
            "communication" => communication
          }
        } = claim,
        timestamp,
        emoji,
        _opts
      )
      when is_binary(obligation_id) and obligation_id != "" and is_binary(timestamp) and
             is_binary(emoji) and is_map(communication) do
    with :ok <- SlackEffectAdapter.validate_reaction_authority(claim.payload, emoji),
         {:ok, ^timestamp} <- SlackEffectAdapter.reaction_target(claim.payload) do
      target = claim.payload["target"]

      record = %{
        "obligation_id" => obligation_id,
        "workspace_id" => target["workspace_id"],
        "channel_id" => target["channel_id"],
        "timestamp" => timestamp,
        "emoji" => emoji
      }

      table = ensure_table()

      if :ets.insert_new(table, {obligation_id, record}) do
        {:ok, %{already_reacted: false}}
      else
        case :ets.lookup(table, obligation_id) do
          [{^obligation_id, ^record}] -> {:ok, %{already_reacted: true}}
          _conflict -> {:error, :reaction_idempotency_conflict, false}
        end
      end
    else
      _invalid ->
        {:error, :invalid_product_obligation, false}
    end
  end

  def add(_claim, _timestamp, _emoji, _opts),
    do: {:error, :invalid_product_obligation, false}

  defp ensure_table(_ignored \\ nil) do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end
end
