defmodule SalixAgent.Loops.HostTest do
  @moduledoc """
  The spinfoam Host without the runtime's own tests: a missing binary leaves
  the node unavailable with a bounded reason (no crash loop), and, where the
  pinned binary exists, the handshake exposes the compiler fact and answers
  control requests, and a build through the embedded compiler runs through
  `SalixAgent.Loops.build/4` and lands as a workspace file.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentWorkspace, Loops}
  alias SalixAgent.Loops.Host
  alias SalixAgent.SpinfoamFixture

  test "a missing binary leaves the host unavailable with a reason and no restart loop" do
    prev = Application.get_env(:salix_agent, :spinfoam_cmd)
    Application.put_env(:salix_agent, :spinfoam_cmd, {"/nonexistent/spinfoam", []})

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :spinfoam_cmd, prev),
        else: Application.delete_env(:salix_agent, :spinfoam_cmd)
    end)

    {:ok, pid} = Host.start_link(name: :loops_host_missing_test, reconciler: nil)

    assert %{available: false, reason: {:missing_binary, "/nonexistent/spinfoam"}, restarts: 0} =
             Host.status(:loops_host_missing_test)

    assert Host.objects(:loops_host_missing_test) == %{}
    GenServer.stop(pid)
  end

  @tag :spinfoam
  @tag skip:
         if(File.exists?(SpinfoamFixture.binary()),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "the application host initializes, reports the compiler fact and answers control requests" do
    status = Host.status()
    assert status.available
    assert is_binary(status.session_id)
    assert is_map(status.compiler)
    assert {:ok, %{"objects" => objects}} = Host.object_list(nil, 10)
    assert is_list(objects)
    assert {:ok, %{"execution_threads" => _}} = Host.stats()
    assert {:error, %{"kind" => "OBJECT_NOT_FOUND"}} = Host.object_get("o-none")
    assert {:error, :not_found} = Host.event_deliver("o-none", "e", "t", %{})
  end

  @tag :spinfoam
  @tag skip:
         if(File.exists?(SpinfoamFixture.binary()),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "a build stages the ELF as a workspace file for loop.create" do
    await(fn -> Host.status().available end)
    assert %{compiler: %{"available" => true, "embedded" => true} = compiler} = Host.status()
    assert is_binary(compiler["fingerprint"])

    ctx = %{agent_id: SalixAgent.TestSupport.new_agent_id()}
    files = %{"main.c" => SpinfoamFixture.exit_program(42)}

    assert {:ok, report, event} = Loops.build(ctx, files, "main.c", "/loops/exit.elf")
    assert report["state"] == "succeeded"
    assert report["path"] == "/loops/exit.elf"
    assert report["elf_bytes"] > 0
    assert event["type"] == "vfs_write" and event["path"] == "/loops/exit.elf"

    # the round commits the event like any file write; the file then reads
    # back as exactly the bytes the report hashed
    {:ok, _} = AgentWorkspace.seed_operation(ctx.agent_id, "host-test:build", %{}, [event])
    assert {:ok, elf} = AgentWorkspace.read(ctx.agent_id, "/loops/exit.elf")
    assert :crypto.hash(:sha256, elf) |> Base.encode16(case: :lower) == report["artifact_sha256"]
    assert binary_part(elf, 0, 4) == <<0x7F, "ELF">>

    assert {:error, {:invalid, "path"}} = Loops.build(ctx, files, "main.c", "/.runtime/x.elf")

    # a broken program is a bounded report with diagnostics, not a crash
    assert {:ok, failed, nil} =
             Loops.build(
               ctx,
               %{"main.c" => "int main(void) { return missing; }"},
               "main.c",
               "/loops/broken.elf"
             )

    assert failed["state"] == "failed"
    assert failed["diagnostics"] =~ "missing"
  end

  defp await(fun, retries \\ 200) do
    cond do
      fun.() -> true
      retries == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && await(fun, retries - 1)
    end
  end
end
