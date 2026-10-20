defmodule SalixAgent.CondensedWorkspaceTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{CondensedWorkspace, DecideFixture, InternalSession}
  alias SalixAgent.CondensedWorkspace.Decision
  alias SalixStore.CondensedWorkspaces

  @session_id "ses1_0000000000000000981"

  setup do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    config = %{condensed_workspace_enabled: true, group_id: group_id}
    {:ok, agent_id: agent_id, group_id: group_id, config: config}
  end

  defp write!(group_id, text, session_id \\ "ses1_0000000000000000999") do
    {:ok, workspace, []} =
      CondensedWorkspaces.apply_operations(
        group_id,
        [%{"op" => "add", "text" => text}],
        %{"kind" => "agent", "agent_id" => "a", "session_id" => session_id}
      )

    workspace
  end

  describe "delivery to a Session" do
    test "content follows revisions and compaction; the latest writer is not sent a copy", %{
      group_id: group_id,
      config: config
    } do
      session = %{session_id: @session_id, compacted_through: 4}

      # A new Session receives the current content.
      write!(group_id, "Launch is Friday.")
      assert {[message], state} = CondensedWorkspace.prepare(session, config, %{})
      assert message["content"] =~ "revision 1"
      assert message["content"] =~ "- [s1] Launch is Friday."
      known = %{"condensed_workspace" => state}

      # Nothing changed: nothing is sent.
      assert {[], ^state} = CondensedWorkspace.prepare(session, config, known)

      # Another Session's write is sent in full.
      write!(group_id, "Ana owns the release.")
      assert {[message], state} = CondensedWorkspace.prepare(session, config, known)
      assert message["content"] =~ "- [s1] Launch is Friday.\n- [s2] Ana owns the release."
      known = %{"condensed_workspace" => state}

      # This Session's own write is already in its tool result.
      write!(group_id, "Docs are frozen.", @session_id)
      assert {[], state} = CondensedWorkspace.prepare(session, config, known)
      known = %{"condensed_workspace" => state}

      # Compaction may have removed that result, so the content comes again.
      compacted = %{session | compacted_through: 9}
      assert {[message], _state} = CondensedWorkspace.prepare(compacted, config, known)
      assert message["content"] =~ "- [s3] Docs are frozen."

      # Turning the feature off sends one notice, then nothing.
      off = %{config | condensed_workspace_enabled: false}
      assert {[notice], %{}} = CondensedWorkspace.prepare(session, off, known)
      assert notice["content"] =~ "now disabled"
      assert {[], %{}} = CondensedWorkspace.prepare(session, off, %{})
    end
  end

  describe "round check" do
    setup %{agent_id: agent_id} do
      DecideFixture.start_provider()

      DecideFixture.put_env(:decide_noul_probabilities, %{
        "needs_update" => 0.9,
        "off_track" => 0.1
      })

      session =
        agent_id
        |> InternalSession.new(@session_id, %{"created_at" => 1})
        |> InternalSession.apply_events([
          %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => 1,
            "role" => "user",
            "content" => "Ship the release on Friday.",
            "source_message_id" => "src-1",
            "created_at" => 2
          }
        ])

      {:ok, session: session}
    end

    defp check(session, attrs) do
      :started =
        Decision.start(%{
          enabled: true,
          session: session,
          calls: [%{name: "fs.read_file", arguments: %{"path" => "/plan.md"}}],
          agent_id: attrs.agent_id,
          session_id: @session_id,
          tenant_id: SalixStore.Ids.tenant_id_from_group!(attrs.group_id),
          group_id: attrs.group_id
        })

      {reminder, _wait} = Decision.reminder(@session_id, attrs.config)
      reminder
    end
  end
end
