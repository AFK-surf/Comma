defmodule SalixAgent.SandboxesGatingTest do
  @moduledoc """
  What changes for the agents where sandboxes are set up (`SalixAgent.Sandboxes`):
  the Cloud VM's tool is retired and not offered, a Worker is offered the
  creation of one sandbox Task, and the Router's prompt sends machine work
  to a sandbox Task instead of the Cloud VM. Elsewhere nothing changes.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{ToolDisclosure, ToolPolicy}

  defmodule SandboxesOn do
    @moduledoc false
    def enabled?, do: true
  end

  @task_create "im_api.internal.task.create"

  # A Worker's dynamic entry for the Task creation, as the IM router discloses it.
  @task_create_entry %{
    "name" => @task_create,
    "summary" => "Create one distinct durable Task.",
    "manual" => "Create one distinct durable Task.",
    "input_schema" => %{"type" => "object"},
    "manual_available" => true,
    "helpable" => true,
    "callable" => true,
    "safety" => "write"
  }

  setup do
    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)
      SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)
    end)

    :ok
  end

  defp sandboxes_on!, do: SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SandboxesOn)

  defp cloud_vm_retired! do
    sandboxes_on!()
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_retired, true)
  end

  defp names(role, im_entries \\ []) do
    ctx = SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "gating-agent"})

    role
    |> ToolDisclosure.materialize_prepared(:internal, ctx, im_entries, [])
    |> Map.fetch!("tools")
    |> Enum.map(& &1["name"])
  end

  test "the Cloud VM's tool is offered only where the Cloud VM is a place" do
    assert "cloud_vm.start" in names("router")
    assert "cloud_vm.start" in names("worker")

    # Sandboxes set up alone retire nothing.
    sandboxes_on!()
    assert "cloud_vm.start" in names("router")

    assert {:tool_failure, _, code, _, _, _} =
             SalixAgent.Tools.CloudVM.start(%{}, %{agent_id: "gating-agent"})

    refute code == "cloud_vm_retired"

    cloud_vm_retired!()
    refute "cloud_vm.start" in names("router")
    refute "cloud_vm.start" in names("worker")

    assert {:tool_failure, encoded, "cloud_vm_retired", "user_reportable", message, []} =
             SalixAgent.Tools.CloudVM.start(%{}, %{agent_id: "gating-agent"})

    assert %{"code" => "cloud_vm_retired", "steps" => []} = Jason.decode!(encoded)
    assert message =~ "sandbox Task"
  end

  test "retirement still refuses Cloud VM tools when the sandbox provider is unavailable" do
    cloud_vm_retired!()
    SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)

    refute SalixAgent.Sandboxes.enabled?()
    assert SalixAgent.Sandboxes.cloud_vm_retired?(nil)
    refute "cloud_vm.start" in names("router")

    assert {:tool_failure, _, "cloud_vm_retired", _, _, []} =
             SalixAgent.Tools.CloudVM.start(%{}, %{agent_id: "gating-agent"})

    SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)
    assert SalixAgent.Sandboxes.cloud_vm_retired?(%{"cloud_vm_retired" => true})
  end

  test "a Worker is offered the creation of a sandbox Task only where the Cloud VM is retired" do
    refute @task_create in names("worker", [@task_create_entry])
    refute @task_create in names(nil, [@task_create_entry])
    assert @task_create in names("router", [@task_create_entry])

    # Sandboxes set up alone: the Worker still reaches the Cloud VM with env.exec.
    sandboxes_on!()
    refute @task_create in names("worker", [@task_create_entry])

    cloud_vm_retired!()
    assert @task_create in names("worker", [@task_create_entry])
    assert @task_create in names("router", [@task_create_entry])
  end

  test "the Router's prompt sends machine work to the Cloud VM or to a sandbox Task, with no placeholder left" do
    cloud_vm = session_prompt("router")
    refute cloud_vm =~ "{{"
    assert cloud_vm =~ ~s({"kind":"cloud_vm"})
    refute session_prompt("worker") =~ "A Task created by a Worker creates no Task."

    # Sandboxes set up, the Cloud VM not retired: both prompts keep the Cloud VM.
    sandboxes_on!()
    assert session_prompt("router") =~ ~s({"kind":"cloud_vm"})
    refute session_prompt("worker") =~ "A Task created by a Worker creates no Task."

    cloud_vm_retired!()
    sandbox = session_prompt("router")
    refute sandbox =~ "{{"
    refute sandbox =~ "Cloud VM images include"
    assert sandbox =~ "retired here"
    assert session_prompt("worker") =~ "A Task created by a Worker creates no Task."
  end

  test "a Group created where sandboxes are set up gets the sandbox tools and prompt; an older Group keeps the Cloud VM" do
    start_supervised!(SalixStore.S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    created = SalixStore.Ids.new_group_id(tenant)
    older = SalixStore.Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(created, %{"cloud_vm_retired" => true})
    SalixAgent.TestSupport.create_control_group!(older)
    sandboxes_on!()

    group_names = fn role, group ->
      ctx =
        SalixAgent.TestSupport.with_plugin_projection(%{
          agent_id: "gating-agent",
          group_id: group
        })

      role
      |> ToolDisclosure.materialize_prepared(:internal, ctx, [@task_create_entry], [])
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])
    end

    refute "cloud_vm.start" in group_names.("router", created)
    assert @task_create in group_names.("worker", created)
    assert "cloud_vm.start" in group_names.("router", older)
    refute @task_create in group_names.("worker", older)

    # A round reads the Group once and its disclosure carries the answer
    # (`SalixAgent.RoundConfig`).
    prompt = fn role, retired ->
      ctx = SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "gating-agent"})

      disclosure =
        role
        |> ToolDisclosure.materialize(:internal, ctx)
        |> Map.put("cloud_vm_retired", retired)

      ToolPolicy.session_prompt(role, %{}, nil, :internal, disclosure)
    end

    assert prompt.("router", true) =~ "retired here"
    refute prompt.("router", true) =~ "Cloud VM images include"
    assert prompt.("worker", true) =~ "A Task created by a Worker creates no Task."
    assert prompt.("router", false) =~ ~s({"kind":"cloud_vm"})
    refute prompt.("worker", false) =~ "A Task created by a Worker creates no Task."
  end

  defp session_prompt(role) do
    ctx = SalixAgent.TestSupport.with_plugin_projection(%{agent_id: "gating-agent"})
    disclosure = ToolDisclosure.materialize(role, :internal, ctx)
    ToolPolicy.session_prompt(role, %{}, nil, :internal, disclosure)
  end
end
