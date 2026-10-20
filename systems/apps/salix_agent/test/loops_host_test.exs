defmodule SalixAgent.Loops.HostTest do
  @moduledoc """
  The spinfoam Host without the runtime's own tests: a missing binary leaves
  the node unavailable with a bounded reason (no crash loop), and, where the
  pinned binary exists, the handshake exposes the compiler fact and answers
  control requests, and a build through the embedded compiler runs through
  `SalixAgent.Loops.build/4` and lands as a workspace file.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, Loops}
  alias SalixAgent.Loops.Host
  alias SalixAgent.SpinfoamFixture

  @tag :spinfoam
  @tag skip:
         if(File.exists?(SpinfoamFixture.binary()),
           do: false,
           else: "spinfoam binary unavailable"
         )
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

  @tag :spinfoam
  @tag skip:
         if(File.exists?(SpinfoamFixture.binary()),
           do: false,
           else: "spinfoam binary unavailable"
         )
  @tag :spinfoam
  @tag skip:
         if(File.exists?(SpinfoamFixture.binary()),
           do: false,
           else: "spinfoam binary unavailable"
         )
  defp await(fun, retries \\ 1200) do
    cond do
      fun.() -> true
      retries == 0 -> flunk("condition never held")
      true -> SystemsRuntime.Proc.sleep(25) && await(fun, retries - 1)
    end
  end
end
