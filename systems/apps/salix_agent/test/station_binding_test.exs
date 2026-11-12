defmodule SalixAgent.StationBindingTest do
  @moduledoc """
  The places a Worker can be bound to (`SalixAgent.StationBinding.runs_on/2`):
  where the Group's Cloud VM is retired, a sandbox takes its place.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.StationBinding

  defmodule SandboxesOn do
    @moduledoc false
    def enabled?, do: true
  end

  test "a Worker binds to a station, a sandbox, or the Cloud VM where it is not retired" do
    assert StationBinding.runs_on(%{"kind" => "sandbox"}, nil) == {:ok, %{"kind" => "sandbox"}}
    assert StationBinding.runs_on(%{"kind" => "cloud_vm"}, nil) == {:ok, %{"kind" => "cloud_vm"}}

    assert StationBinding.runs_on(%{"kind" => "station", "device_id" => " dev-1 "}, nil) ==
             {:ok, %{"kind" => "station", "device_id" => "dev-1"}}

    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SandboxesOn)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)
      SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)
    end)

    # Sandboxes set up alone retire nothing.
    assert StationBinding.runs_on(%{"kind" => "cloud_vm"}, nil) == {:ok, %{"kind" => "cloud_vm"}}

    SystemsRuntime.put_env(:salix_agent, :cloud_vm_retired, true)

    assert {:error, {:bad_request, message}} =
             StationBinding.runs_on(%{"kind" => "cloud_vm"}, nil)

    assert message =~ "retired here: bind the Worker with runs_on {kind: sandbox}"
    assert StationBinding.runs_on(%{"kind" => "sandbox"}, nil) == {:ok, %{"kind" => "sandbox"}}
  end

  test "a Worker of a Group created where sandboxes are set up binds to no Cloud VM" do
    start_supervised!(SalixStore.S3.Fake)
    group = SalixStore.Ids.new_group_id(SalixAgent.TestSupport.new_tenant_id())
    SalixAgent.TestSupport.create_control_group!(group, %{"cloud_vm_retired" => true})
    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SandboxesOn)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod) end)

    assert {:error, {:bad_request, _message}} =
             StationBinding.runs_on(%{"kind" => "cloud_vm"}, group)

    assert StationBinding.runs_on(%{"kind" => "cloud_vm"}, nil) == {:ok, %{"kind" => "cloud_vm"}}
  end
end
