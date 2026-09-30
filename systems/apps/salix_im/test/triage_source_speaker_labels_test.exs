defmodule SalixIM.Triage.SourceSpeakerLabelsTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.SourceSpeakerLabels

  test "resolves each distinct bounded Slack user once and keeps ids private" do
    owner = self()

    payload = %{
      "target" => %{
        "connect_id" => "connect-1",
        "connect_generation" => "channel-authority-generation-1",
        "workspace_id" => "T1"
      },
      "product_identity" => %{"project_salix_group_id" => "group-1"},
      "source_messages" => [
        %{"actor_id" => "U12345678", "actor_kind" => "human"},
        %{"actor_id" => "U12345678", "actor_kind" => "human"},
        %{"actor_id" => "W87654321", "actor_kind" => "agent"}
      ]
    }

    labels =
      SourceSpeakerLabels.resolve(payload,
        cache: false,
        connect_fun: fn group_id, connect_id, provider ->
          assert {group_id, connect_id, provider} == {"group-1", "connect-1", "slack"}

          {:ok,
           %{
             "connect_id" => "connect-1",
             "connect_generation" => "installation-generation-1",
             "workspace_id" => "T1",
             "bot_token" => "xoxb-test"
           }}
        end,
        credential_fun: fn _connect -> :credential end,
        user_info_fun: fn :credential, actor_id ->
          send(owner, {:lookup, actor_id})

          case actor_id do
            "U12345678" ->
              %{
                "name" => "peng",
                "profile" => %{"display_name" => "Peng Xiao", "real_name" => "Peng"}
              }

            "W87654321" ->
              %{"name" => "release-bot", "profile" => %{"display_name" => "Release Bot"}}
          end
        end
      )

    assert labels == ["Peng Xiao", "Peng Xiao", "Release Bot"]
    assert_receive {:lookup, "U12345678"}
    assert_receive {:lookup, "W87654321"}
    refute_receive {:lookup, _duplicate}
    refute inspect(labels) =~ "U12345678"
  end

  test "a different workspace fails open to anonymous presentation labels" do
    payload = %{
      "target" => %{
        "connect_id" => "connect-1",
        "connect_generation" => "generation-1",
        "workspace_id" => "T1"
      },
      "product_identity" => %{"project_salix_group_id" => "group-1"},
      "source_messages" => [
        %{"actor_id" => "U12345678", "actor_kind" => "human"}
      ]
    }

    assert SourceSpeakerLabels.resolve(payload,
             cache: false,
             connect_fun: fn _group_id, _connect_id, _provider ->
               {:ok,
                %{
                  "connect_id" => "connect-1",
                  "connect_generation" => "new-generation",
                  "workspace_id" => "T2",
                  "bot_token" => "xoxb-test"
                }}
             end,
             user_info_fun: fn _credential, _actor_id -> flunk("must not read Slack") end
           ) == [nil]
  end
end
