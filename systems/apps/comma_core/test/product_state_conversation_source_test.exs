defmodule Comma.Migrations.ProductStateConversationSourceTest do
  use ExUnit.Case, async: true

  alias Comma.Migrations.ProductStateConversationSource

  test "only complete retired aggregates enter the legacy identity index" do
    legacy = legacy_row()

    binding = %{
      id: "cnv-current",
      value: %{
        "id" => "cnv-current",
        "workspace_id" => "wsp-current",
        "kind" => "user_chat",
        "internal" => %{
          "binding_version" => 1,
          "salix_group_id" => "grp-current",
          "salix_conversation_id" => "salix-current"
        }
      }
    }

    assert ProductStateConversationSource.classify(legacy.value) == :legacy_aggregate
    assert ProductStateConversationSource.classify(binding.value) == :binding_candidate
    assert ProductStateConversationSource.classify(%{"messages" => []}) == :binding_candidate

    assert ProductStateConversationSource.legacy_aggregate_index([legacy, binding]) == %{
             "cnv-legacy" => %{
               salix_conversation_id: "salix-legacy",
               workspace_id: "wsp-legacy"
             }
           }
  end

  test "a projection is legacy only when its key and aggregate identity match exactly" do
    legacy = legacy_row()
    legacy_index = ProductStateConversationSource.legacy_aggregate_index([legacy])

    projection = %{
      id: "salix-legacy",
      value: %{
        "conversation_id" => "cnv-legacy",
        "salix_conversation_id" => "salix-legacy",
        "workspace_id" => "wsp-legacy"
      }
    }

    assert ProductStateConversationSource.legacy_aggregate_projection?(
             projection,
             legacy_index
           )

    refute ProductStateConversationSource.legacy_aggregate_projection?(
             %{projection | id: "wrong-physical-key"},
             legacy_index
           )

    refute ProductStateConversationSource.legacy_aggregate_projection?(
             put_in(projection, [:value, "workspace_id"], "wsp-other"),
             legacy_index
           )

    refute ProductStateConversationSource.legacy_aggregate_projection?(
             %{id: "salix-legacy", value: %{"conversation_id" => "cnv-legacy"}},
             legacy_index
           )
  end

  defp legacy_row do
    %{
      id: "cnv-legacy",
      value: %{
        "id" => "cnv-legacy",
        "workspace_id" => "wsp-legacy",
        "kind" => "assistant",
        "snapshot_version" => 1,
        "last_event_id" => 0,
        "final_message_id" => nil,
        "messages" => [],
        "internal" => %{
          "salix_group_id" => "grp-legacy",
          "salix_conversation_id" => "salix-legacy"
        }
      }
    }
  end
end
