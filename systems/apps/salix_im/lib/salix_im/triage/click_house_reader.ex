defmodule SalixIM.Triage.ClickHouseReader do
  @moduledoc false

  @callback list_changes(map(), map(), pos_integer()) ::
              {:ok, %{rows: [map()], next_cursor: map() | nil, has_more?: boolean()}}
              | {:error, term()}
  @callback tail(map()) :: {:ok, map()} | {:error, term()}
  @callback latest_states(map(), [non_neg_integer()]) ::
              {:ok, %{optional(non_neg_integer()) => map()}} | {:error, term()}
  @callback read_thread(map(), String.t(), keyword()) ::
              {:ok,
               %{
                 messages: [map()],
                 reactions: [map()],
                 complete?: boolean(),
                 truncated_reason: :count | :bytes | nil
               }}
              | {:error, term()}

  @callback history(map(), keyword()) ::
              {:ok, %{messages: [map()], next_cursor: String.t() | nil, has_more?: boolean()}}
              | {:error, term()}

  @callback replies(map(), String.t(), keyword()) ::
              {:ok, %{messages: [map()], next_cursor: String.t() | nil, has_more?: boolean()}}
              | {:error, term()}

  @callback search(map(), keyword()) ::
              {:ok,
               %{
                 messages: [map()],
                 next_cursor: {non_neg_integer(), String.t()} | nil,
                 has_more?: boolean()
               }}
              | {:error, term()}

  @callback read_channel(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks history: 2, replies: 3, search: 2, read_channel: 3

  def impl do
    Application.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)
  end
end
