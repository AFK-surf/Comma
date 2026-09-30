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

  use ExUnit.Case, async: false

  alias SalixAgent.{AgentWorkspace, FileBackend, Tools}

  @legal "scope|cnx1|C_LEGAL"
  @space "space|cnx1"

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)

    {:ok, agent: "ifc-vfs-#{System.unique_integer([:positive])}"}
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
               "ifc-vfs:#{System.unique_integer([:positive])}",
               %{},
               events
             )

    :ok
  end

  describe "a file written while the check is on" do
    test "a generated UI retains the source audience through its immutable artifact", %{
      agent: agent
    } do
      {result, events} =
        SalixAgent.Tools.DynamicUI.create(
          %{
            "html" => "<p>Private report</p>",
            "script" => "",
            "data" => %{},
            "summary" => "Private report"
          },
          ctx(agent, sources_label: [@legal])
        )

      assert [%{"type" => "vfs_write", "ifc_label" => [@legal]}] = events
      commit!(agent, events)
      block = Jason.decode!(result)["content"]
      assert AgentWorkspace.label(agent, block["path"]) == [@legal]

      assert {:tool_ifc, _content, [], %{"label" => [@legal]}} =
               Tools.read_file(%{"path" => block["path"]}, ctx(agent))
    end

    test "records what the write drew on, and hands it back on read", %{agent: agent} do
      write!(agent, "/notes/legal.md", "what #legal said", sources_label: [@legal])

      assert AgentWorkspace.label(agent, "/notes/legal.md") == [@legal]

      assert {:tool_ifc, content, [], %{"label" => [@legal]}} =
               Tools.read_file(%{"path" => "/notes/legal.md"}, ctx(agent))

      assert content =~ "what #legal said"
    end

    test "keeps the join when the write drew on more than one place", %{agent: agent} do
      write!(agent, "/notes/both.md", "two sources", sources_label: [@legal, @space])

      assert {:tool_ifc, _content, [], %{"label" => label}} =
               Tools.read_file(%{"path" => "/notes/both.md"}, ctx(agent))

      assert Enum.sort(label) == Enum.sort([@legal, @space])
    end

    test "a write that drew on nothing is readable by anyone", %{agent: agent} do
      # `sources: []` is an honest declaration, not an absent one: the file
      # carries no confidential content, so reading it is bottom of the lattice.
      write!(agent, "/notes/scratch.md", "just arithmetic", sources_label: ["public"])

      assert {:tool_ifc, _content, [], %{"label" => ["public"]}} =
               Tools.read_file(%{"path" => "/notes/scratch.md"}, ctx(agent))
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

    test "an append to memory keeps it too, joined with what the append drew on", %{agent: agent} do
      today = SalixAgent.Tools.Memory.today_episode_path()
      write!(agent, today, "yesterday, from #legal", sources_label: [@legal])

      {_told, events} =
        SalixAgent.Tools.Memory.memory_write(
          %{"path" => today, "content" => "and today, from the space", "mode" => "append"},
          ctx(agent, sources_label: [@space])
        )

      commit!(agent, events)

      # The appended note and the day's earlier entries are now one file, so it
      # belongs to both.
      assert Enum.sort(AgentWorkspace.label(agent, today)) == Enum.sort([@legal, @space])
    end

    test "a full replacement does not inherit what it overwrote", %{agent: agent} do
      write!(agent, "/notes/legal.md", "what #legal said", sources_label: [@legal])
      write!(agent, "/notes/legal.md", "unrelated public note", sources_label: ["public"])

      # Nothing of the private file survives, so keeping its audience would
      # make an ordinary note permanently unusable for no reason.
      assert AgentWorkspace.label(agent, "/notes/legal.md") == ["public"]
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

    test "and drags a listing that contains it down with it", %{agent: agent} do
      write!(agent, "/notes/legal.md", "labelled", sources_label: [@legal])
      write!(agent, "/notes/legacy.md", "unlabelled", [])

      assert {:tool_ifc, listing, [], %{"label" => label}} =
               Tools.list_files(%{"prefix" => "/notes"}, ctx(agent))

      assert listing =~ "/notes/legacy.md"
      # Not `[@legal]`: the answer was derived from a file whose audience is
      # unknown, and an unknown audience must not be quietly dropped from a join.
      assert "agent_private" in label
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

    test "an append to it cannot either", %{agent: agent} do
      today = SalixAgent.Tools.Memory.today_episode_path()
      write!(agent, today, "from before the check", [])

      {_told, events} =
        SalixAgent.Tools.Memory.memory_write(
          %{"path" => today, "content" => "and today, from the space", "mode" => "append"},
          ctx(agent, sources_label: [@space])
        )

      commit!(agent, events)

      assert Enum.sort(AgentWorkspace.label(agent, today)) ==
               Enum.sort(["agent_private", @space])
    end

    test "but replacing it wholesale inherits nothing", %{agent: agent} do
      write!(agent, "/notes/legacy.md", "Salary: 123", [])
      write!(agent, "/notes/legacy.md", "an unrelated public note", sources_label: ["public"])

      # Nothing of the old file survives, so an ordinary note is not stranded.
      assert AgentWorkspace.label(agent, "/notes/legacy.md") == ["public"]
    end

    test "and a first write to a path is absence, not unknown retention", %{agent: agent} do
      write!(agent, "/notes/fresh.md", "brand new", sources_label: ["public"])

      # The distinction the seam exists to draw: nothing was kept, so there is
      # nothing whose audience is unknown, and the note stays usable.
      assert AgentWorkspace.label(agent, "/notes/fresh.md") == ["public"]
    end
  end

  describe "what the workspace can answer about a path" do
    test "tells apart a labelled file, an unlabelled one, and an absent one", %{agent: agent} do
      write!(agent, "/notes/legal.md", "what #legal said", sources_label: [@legal])
      write!(agent, "/notes/legacy.md", "from before", [])

      assert AgentWorkspace.retained(agent, "/notes/legal.md") == {:labelled, [@legal]}
      assert AgentWorkspace.retained(agent, "/notes/legacy.md") == :unlabelled
      assert AgentWorkspace.retained(agent, "/notes/never-written.md") == :absent
    end

    test "a stored label whose atoms do not decode still fails closed", %{agent: agent} do
      # `apply_workspace_event` only lets a list into the manifest, so an
      # unreadable label is a list of atoms nobody can decode rather than a
      # bad shape. It must not be joined as if it named an audience.
      {_told, events} =
        Tools.write_file(
          %{"path" => "/notes/corrupt.md", "content" => "Salary: 123"},
          ctx(agent, sources_label: [@legal])
        )

      commit!(agent, Enum.map(events, &Map.put(&1, "ifc_label", ["not-a-real-atom"])))

      {_told, edited} =
        Tools.edit_file(
          %{"path" => "/notes/corrupt.md", "old" => "Salary", "new" => "Pay"},
          ctx(agent, sources_label: ["public"])
        )

      commit!(agent, edited)

      # Not `["public"]`, and not `["not-a-real-atom", "public"]` either.
      assert AgentWorkspace.label(agent, "/notes/corrupt.md") == ["agent_private"]
    end
  end

  describe "memory" do
    test "a scoped note reads back with the audience it was written from", %{agent: agent} do
      write!(agent, "/memory/scoped/legal.md", "what #legal decided", sources_label: [@legal])

      assert {:tool_ifc, content, [], %{"label" => [@legal]}} =
               SalixAgent.Tools.Memory.memory_get(
                 %{"path" => "/memory/scoped/legal.md"},
                 ctx(agent)
               )

      assert content =~ "what #legal decided"
    end

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

    test "fails closed when there is no Group to name" do
      assert {:tool_ifc, "{}", [], %{"label" => ["agent_private"]}} =
               ConnectorLabels.group_audience("{}", %{agent_id: "a", ifc: %{"items" => []}})
    end

    test "is silent for a session that is not labelling" do
      assert ConnectorLabels.group_audience("{}", %{agent_id: "a", group_id: "grp_1"}) == "{}"
    end

    test "leaves a result that is not plain content alone" do
      labelling = %{agent_id: "a", group_id: "grp_1", ifc: %{"items" => []}}
      status = {:tool_status, "cancelled", "{}", []}
      assert ConnectorLabels.group_audience(status, labelling) == status
    end
  end

  describe "a Group that is not labelling" do
    test "records nothing, because nothing was decided", %{agent: agent} do
      # A Group that is `off` never reaches `SalixAgent.IFC.Check`, so no
      # effect ever carries evidence and no file ever carries a label.
      write!(agent, "/notes/plain.md", "hello", labelling?: false)

      assert AgentWorkspace.label(agent, "/notes/plain.md") == nil
    end

    test "and reads come back as plain content", %{agent: agent} do
      write!(agent, "/notes/legal.md", "what #legal said", sources_label: [@legal])

      # Stamping the fail-closed label here would put it on results that
      # predate the decision to have one, and every file the Group wrote while
      # it was off would flow nowhere the day it turns the check on.
      content = Tools.read_file(%{"path" => "/notes/legal.md"}, ctx(agent, labelling?: false))

      assert is_binary(content)
      assert content =~ "what #legal said"
    end
  end
end
