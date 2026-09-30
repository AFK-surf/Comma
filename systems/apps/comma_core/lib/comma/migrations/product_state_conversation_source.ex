defmodule Comma.Migrations.ProductStateConversationSource do
  @moduledoc false

  @legacy_aggregate_fields [
    "snapshot_version",
    "last_event_id",
    "final_message_id",
    "messages"
  ]

  @doc """
  Classifies physical rows from the historical `comma/conversations/` prefix.

  The prefix once held Comma-local transcript aggregates and now holds only thin
  product bindings. A complete aggregate signature is retired migration input;
  every other row remains a binding candidate and must pass the strict binding
  decoder instead of being silently excluded.
  """
  def classify(value) when is_map(value) do
    if legacy_aggregate?(value), do: :legacy_aggregate, else: :binding_candidate
  end

  def classify(_value), do: :binding_candidate

  @doc """
  Builds the exact legacy aggregate identity set used to classify rows in the
  former `comma/salix_conversation_projections/` prefix.

  Unknown and current binding rows are intentionally omitted so a malformed
  projection still reaches the strict importer/inventory checks.
  """
  def legacy_aggregate_index(rows) when is_list(rows) do
    rows
    |> Enum.filter(&(classify(&1.value) == :legacy_aggregate))
    |> Map.new(fn row ->
      {row.id,
       %{
         salix_conversation_id: get_in(row.value, ["internal", "salix_conversation_id"]),
         workspace_id: row.value["workspace_id"]
       }}
    end)
  end

  @doc """
  Returns true only for the physical projection row that exactly belongs to a
  previously classified legacy aggregate.
  """
  def legacy_aggregate_projection?(
        %{
          id: physical_id,
          value: %{
            "conversation_id" => conversation_id,
            "salix_conversation_id" => salix_conversation_id,
            "workspace_id" => workspace_id
          }
        },
        legacy_aggregates
      )
      when is_map(legacy_aggregates) do
    physical_id == salix_conversation_id and
      Map.get(legacy_aggregates, conversation_id) == %{
        salix_conversation_id: salix_conversation_id,
        workspace_id: workspace_id
      }
  end

  def legacy_aggregate_projection?(_row, _legacy_aggregates), do: false

  defp legacy_aggregate?(value) do
    internal = value["internal"]

    Enum.all?(@legacy_aggregate_fields, &Map.has_key?(value, &1)) and
      is_integer(value["snapshot_version"]) and
      is_integer(value["last_event_id"]) and
      (is_nil(value["final_message_id"]) or is_binary(value["final_message_id"])) and
      is_list(value["messages"]) and
      is_map(internal) and
      is_binary(internal["salix_group_id"]) and
      is_binary(internal["salix_conversation_id"]) and
      value["kind"] not in ["user_chat", "agent_task"] and
      not Map.has_key?(internal, "binding_version")
  end
end
