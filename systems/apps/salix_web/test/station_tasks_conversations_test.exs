defmodule SalixWeb.StationTasks.ConversationsTest do
  @moduledoc """
  The Task store `SalixWeb.StationTasks` reads in production
  (`SalixWeb.StationTasks.Conversations`), on a real Task: a coding
  sandbox's wake decides on the Task's last Message and its `metadata`.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixWeb.StationTasks.Conversations

  test "the last Message of a Task is its newest, with its metadata" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Coding"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Coding"}, tenant["tenant_id"])
    gid = group["group_id"]
    cid = SalixStore.Ids.new_conversation_id()

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => gid, "name" => "Router", "role" => "router"},
        tenant["tenant_id"]
      )

    {:ok, _} = Salix.Control.Groups.update(gid, %{"router_agent_id" => router["agent_id"]})

    {:ok, seed} =
      SalixIM.ConversationSeedInput.prepare(gid, cid, %{
        "messages" => [],
        "conversation" => %{
          "kind" => "agent_task",
          "runs_on" => %{
            "kind" => "sandbox",
            "device_id" => SalixStore.CodingSandboxes.device_id(cid)
          },
          "repo" => %{
            "owner" => "acme",
            "name" => "api",
            "base_ref" => "main",
            "branch" => "comma/code"
          },
          "participants" => [
            %{"actor_type" => "agent", "agent_id" => router["agent_id"], "role_label" => "router"}
          ]
        }
      })

    {:ok, _} = SalixIM.ConversationServer.seed_group_conversation_transcript(gid, cid, seed)
    assert {:error, :not_found} = Conversations.last(gid, cid)

    append = fn n, attrs ->
      {:ok, _} =
        Conversations.append(
          gid,
          cid,
          router["agent_id"],
          Map.merge(
            %{
              "kind" => "message",
              "actor_type" => "agent",
              "agent_id" => router["agent_id"],
              "client_request_id" => "last-#{n}"
            },
            attrs
          )
        )
    end

    append.(1, %{"content" => "Fix the build"})

    append.(2, %{
      "content" => "The sandbox could not run. Reply to try again.",
      "metadata" => %{"kind" => "sandbox_notice"}
    })

    assert {:ok, %{"seq" => 2, "metadata" => %{"kind" => "sandbox_notice"}}} =
             Conversations.last(gid, cid)

    assert {:ok, [%{"seq" => 1}, %{"seq" => 2}]} =
             with(
               {:ok, messages} <- Conversations.recent(gid, cid, 50),
               do: {:ok, Enum.sort_by(messages, & &1["seq"])}
             )
  end
end
