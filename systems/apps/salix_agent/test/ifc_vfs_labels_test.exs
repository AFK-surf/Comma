defmodule SalixAgent.IFCVfsLabelsTest do
  @moduledoc """
  What a file remembers about where it came from
  (`docs/verification.md` §8, §15).

  `fs.write_file` is decided as a private write, so nothing stops the model
  putting a private channel's content into the workspace. What matters is the
  next activation: without a recorded label a read of that file is unlabelled,
  and the runtime has to treat it as agent-private — correct, but it means a
  file the agent wrote for itself can never be used again.

  So the write records the join of everything the effect drew on, and the read
  hands it back. Reading the file is then exactly as restrictive as reading its
  sources would have been, which is the whole invariant.
  """

  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, FileBackend, Tools}

  @legal "scope|cnx1|C_LEGAL"
  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous) end)

    {:ok, agent: "ifc-vfs-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  # A ctx as the dispatcher hands it to a tool: `:ifc` present means this Group
  # is labelling, and `:ifc_evidence` is what `SalixAgent.IFC.Check` established
  # for the effect that is about to run.
  defp ctx(agent, opts \\ []) do
    %{agent_id: agent}
    |> put_when(Keyword.get(opts, :labelling?, true), :ifc, %{"items" => []})
    |> put_when(
      Keyword.has_key?(opts, :sources_label),
      :ifc_evidence,
      %{"sources_label" => Keyword.get(opts, :sources_label)}
    )
  end

  defp put_when(map, false, _key, _value), do: map
  defp put_when(map, true, key, value), do: Map.put(map, key, value)

  defp write!(agent, path, content, opts) do
    {_told, events} = Tools.write_file(%{"path" => path, "content" => content}, ctx(agent, opts))
    commit!(agent, events)
  end

  defp commit!(agent, events) do
    assert {:ok, _state} =
             AgentWorkspace.seed_operation(
               agent,
               "ifc-vfs:#{SystemsRuntime.Proc.unique_integer([:positive])}",
               %{},
               events
             )

    :ok
  end

  describe "a file written while the check is on" do
    test "records what the write drew on, and hands it back on read", %{agent: agent} do
      write!(agent, "/notes/legal.md", "what #legal said", sources_label: [@legal])

      assert AgentWorkspace.label(agent, "/notes/legal.md") == [@legal]

      assert {:tool_ifc, content, [], %{"label" => [@legal]}} =
               Tools.read_file(%{"path" => "/notes/legal.md"}, ctx(agent))

      assert content =~ "what #legal said"
    end

    test "an edit keeps the audience of what it did not touch", %{agent: agent} do
      # The leak this closes: a private file holds a public TODO marker and a
      # confidential line. A later request asks only to flip the marker. The
      # tool edits in place without showing the file to the model, so the call
      # can honestly declare only that request — and the confidential line
      # survives the write untouched. Labelling the result from the new input
      # alone would hand the whole file a public audience.
      write!(agent, "/notes/plan.md", "TODO ship\nSalary: 123", sources_label: [@legal])

      {_told, events} =
        Tools.edit_file(
          %{"path" => "/notes/plan.md", "old" => "TODO", "new" => "DONE"},
          ctx(agent, sources_label: ["public"])
        )

      commit!(agent, events)

      assert AgentWorkspace.label(agent, "/notes/plan.md") == [@legal]
      assert {:ok, body} = AgentWorkspace.read(agent, "/notes/plan.md")
      assert body == "DONE ship\nSalary: 123"
    end

    test "a copy carries the label with it", %{agent: agent} do
      write!(agent, "/notes/legal.md", "what #legal said", sources_label: [@legal])

      {:ok, events, _size} =
        FileBackend.prepare_copy(ctx(agent), "/notes/legal.md", "/notes/copy.md")

      assert {:ok, _state} =
               AgentWorkspace.seed_operation(agent, "ifc-vfs:copy", %{}, events)

      assert AgentWorkspace.label(agent, "/notes/copy.md") == [@legal]
    end
  end

  describe "a file nobody labelled" do
    test "reads as agent-private rather than as public", %{agent: agent} do
      # A file written before the Group turned the check on, or while a would-be
      # denial was only being audited. The runtime cannot say where its content
      # came from, so it says the one thing that is certainly safe.
      write!(agent, "/notes/legacy.md", "from before", [])

      assert AgentWorkspace.label(agent, "/notes/legacy.md") == nil

      assert {:tool_ifc, _content, [], %{"label" => ["agent_private"]}} =
               Tools.read_file(%{"path" => "/notes/legacy.md"}, ctx(agent))
    end

    # A read of such a file already says agent-private. A write that keeps most
    # of it has to say the same thing, or the two disagree about one file and
    # the edit is a way to publish whatever the check was turned on to protect.
    test "an edit of it cannot relabel the part it kept", %{agent: agent} do
      write!(agent, "/notes/legacy.md", "TODO ship\nSalary: 123", [])

      {_told, events} =
        Tools.edit_file(
          %{"path" => "/notes/legacy.md", "old" => "TODO", "new" => "DONE"},
          ctx(agent, sources_label: ["public"])
        )

      commit!(agent, events)

      assert AgentWorkspace.label(agent, "/notes/legacy.md") == ["agent_private"]
      assert {:ok, "DONE ship\nSalary: 123"} = AgentWorkspace.read(agent, "/notes/legacy.md")
    end
  end

  describe "what the workspace can answer about a path" do
  end

  describe "memory" do
    test "a search labels each hit by the note it came from", %{agent: agent} do
      write!(agent, "/memory/index.md", "quarterly plan", sources_label: ["public"])
      write!(agent, "/memory/scoped/legal.md", "quarterly counsel", sources_label: [@legal])

      assert {:tool_ifc, content, [], %{"label" => label, "items" => items}} =
               SalixAgent.Tools.Memory.memory_search(%{"query" => "quarterly"}, ctx(agent))

      %{"matches" => matches} = Jason.decode!(content)
      paths = Enum.map(matches, & &1["path"])

      # Paths come back ascending, so the group note is first.
      assert paths == ["/memory/index.md", "/memory/scoped/legal.md"]

      assert [
               %{"index" => 0, "label" => ["public"]},
               %{"index" => 1, "label" => [@legal]}
             ] = items

      # Citing the whole page is as restrictive as its most private hit, while
      # citing the public hit by its ref stays public. Without the per-hit
      # labels one scoped note would make every later search unusable.
      assert label == [@legal]
    end
  end

  describe "a connector result" do
    alias SalixAgent.IFC.ConnectorLabels

    test "carries the Group's audience, not the round's" do
      # An MCP binding and a Composio connection are configured per Group and
      # authorized as the Group, so anyone in the Group could have made the
      # same call. That is what `{:group, id}` names.
      labelling = %{agent_id: "a", group_id: "grp_1", ifc: %{"items" => []}}

      assert {:tool_ifc, "{}", [], %{"label" => ["group|grp_1"]}} =
               ConnectorLabels.group_audience("{}", labelling)

      # Saying so is what stops the round's label — the join of whatever the
      # model declared — being stamped on content that came from outside. A
      # round that honestly declared nothing would otherwise mark a private
      # page fetched through a connector as public.
      assert {:tool_ifc, "{}", [%{"e" => 1}], %{"label" => ["group|grp_1"]}} =
               ConnectorLabels.group_audience({"{}", [%{"e" => 1}]}, labelling)
    end
  end

  describe "a Group that is not labelling" do
  end
end
