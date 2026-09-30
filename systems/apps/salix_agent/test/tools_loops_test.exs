defmodule SalixAgent.Tools.LoopsTest do
  @moduledoc """
  The `loop.*` tool surface: registration, schemas, the read/write
  classification, and the error paths a model sees without a spinfoam child.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.Tools
  alias SalixAgent.Tools.Loops, as: LoopTools
  alias SalixStore.S3.Fake

  @names ~w(loop.sdk loop.build loop.create loop.list loop.get loop.pause loop.resume loop.delete loop.webhook loop.send)

  setup do
    prev_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    if Process.whereis(Fake), do: Fake.reset(), else: start_supervised!(Fake)
    SalixStore.Repo.query!("TRUNCATE agent_loops, agent_loop_acks")

    on_exit(fn ->
      if prev_store,
        do: Application.put_env(:salix_store, :s3_backend, prev_store),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "worker"})
    {:ok, ctx: %{agent_id: agent_id, session_id: SalixStore.Ids.new_session_id(), role: "worker"}}
  end

  test "every loop tool is registered after the schedule tools with a schema" do
    names = Enum.map(Tools.registry(), &Tools.entry_name/1)
    assert Enum.all?(@names, &(&1 in names))

    assert Enum.find_index(names, &(&1 == "schedule.delete")) <
             Enum.find_index(names, &(&1 == "loop.build"))

    for entry <- LoopTools.defs() do
      schema = Tools.entry_schema(entry)
      assert schema["type"] == "object"
      assert is_list(schema["required"])
      assert Enum.all?(schema["required"], &Map.has_key?(schema["properties"], &1))
    end

    assert Tools.entry_safety(Tools.find_entry("loop.sdk")) == "read"
    assert Tools.entry_safety(Tools.find_entry("loop.list")) == "read"
    assert Tools.entry_safety(Tools.find_entry("loop.get")) == "read"

    for name <-
          ~w(loop.build loop.create loop.pause loop.resume loop.delete loop.webhook loop.send) do
      assert Tools.entry_safety(Tools.find_entry(name)) == "write"
    end
  end

  @tag :spinfoam
  @tag skip:
         if(File.exists?(SalixAgent.SpinfoamFixture.binary()),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "loop.sdk returns the guide followed by the binary's own header", %{ctx: ctx} do
    document = LoopTools.sdk(%{}, ctx)
    assert document =~ "#ifndef SPINFOAM_H"
    assert document =~ "extern sf_handle sf_host_call_raw("
    assert document =~ "extern sf_handle sf_event_next("
    assert {:ok, header} = SalixAgent.Loops.Sdk.header()
    assert header == SalixAgent.SpinfoamFixture.sdk_header()
  end

  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "the guide's example compiles for the BPF target" do
    program = SalixAgent.Loops.Sdk.example_program()
    assert program =~ "#include \"spinfoam.h\""
    assert program =~ "SF_MAIN sf_i64 main(void)"
    elf = SalixAgent.SpinfoamFixture.compile!(program)
    assert binary_part(elf, 0, 4) == <<0x7F, "ELF">>
  end

  test "loop.build validates its sources before touching the compiler", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/'source' is required/, fn -> LoopTools.build(%{}, ctx) end

    assert_raise RuntimeError, ~r/files' must be an object/, fn ->
      LoopTools.build(%{"source" => "int x;", "files" => "no"}, ctx)
    end

    big = String.duplicate("/", 129 * 1024)

    assert_raise RuntimeError, ~r/sources exceed/, fn ->
      LoopTools.build(%{"source" => big}, ctx)
    end
  end

  defp put_file!(agent_id, path, content) do
    {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, path, content)

    {:ok, _} =
      SalixAgent.AgentWorkspace.seed_operation(
        agent_id,
        "tools-loops-test:#{System.unique_integer([:positive])}",
        %{},
        [event]
      )

    :ok
  end

  test "loop.create explains a missing file and manages an owned loop", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/no file at \/loops\/missing.elf/, fn ->
      LoopTools.create(%{"path" => "/loops/missing.elf"}, ctx)
    end

    :ok = put_file!(ctx.agent_id, "/loops/main.elf", <<0x7F, ?E, ?L, ?F>>)

    created =
      Jason.decode!(
        LoopTools.create(
          %{"path" => "/loops/main.elf", "name" => "n"},
          ctx
        )
      )

    assert created["status"] == "active"

    listed = Jason.decode!(LoopTools.list(%{}, ctx))
    assert [%{"loop_id" => loop_id}] = listed

    shown = Jason.decode!(LoopTools.get(%{"loop_id" => loop_id}, ctx))
    assert shown["name"] == "n"

    assert_raise RuntimeError, ~r/loop not found/, fn ->
      LoopTools.get(%{"loop_id" => "lop1_0"}, ctx)
    end

    assert_raise RuntimeError, ~r/'loop_id' is required/, fn -> LoopTools.pause(%{}, ctx) end

    paused = Jason.decode!(LoopTools.pause(%{"loop_id" => loop_id}, ctx))
    assert paused["paused_by"] == "user"

    assert_raise RuntimeError, ~r/loop is paused/, fn ->
      LoopTools.send_event(%{"loop_id" => loop_id, "topic" => "t"}, ctx)
    end

    deleted = Jason.decode!(LoopTools.delete(%{"loop_id" => loop_id}, ctx))
    assert deleted["status"] == "deleted"
    assert Jason.decode!(LoopTools.list(%{}, ctx)) == []
  end

  test "another agent's loop is indistinguishable from a missing one", %{ctx: ctx} do
    :ok = put_file!(ctx.agent_id, "/loops/main.elf", <<0x7F, ?E, ?L, ?F>>)
    %{"loop_id" => loop_id} = Jason.decode!(LoopTools.create(%{"path" => "/loops/main.elf"}, ctx))

    other = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(other, %{"role" => "worker"})
    other_ctx = %{agent_id: other, session_id: SalixStore.Ids.new_session_id(), role: "worker"}

    assert_raise RuntimeError, ~r/loop not found/, fn ->
      LoopTools.get(%{"loop_id" => loop_id}, other_ctx)
    end

    assert_raise RuntimeError, ~r/loop not found/, fn ->
      LoopTools.delete(%{"loop_id" => loop_id}, other_ctx)
    end

    assert [_] = Jason.decode!(LoopTools.list(%{}, ctx))
  end
end
