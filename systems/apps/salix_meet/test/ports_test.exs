defmodule SalixMeet.PortsTest do
  use ExUnit.Case, async: false

  alias SalixMeet.Ports.{OwnerAttribution, Summary}

  @adapter SalixMeet.Test.LazyPortAdapter

  setup do
    previous_summary = Application.get_env(:salix_meet, :summary_mod)
    previous_attribution = Application.get_env(:salix_meet, :owner_attribution_mod)

    Application.put_env(:salix_meet, :summary_mod, @adapter)
    Application.put_env(:salix_meet, :owner_attribution_mod, @adapter)

    on_exit(fn ->
      restore_env(:salix_meet, :summary_mod, previous_summary)
      restore_env(:salix_meet, :owner_attribution_mod, previous_attribution)
      Code.ensure_loaded!(@adapter)
    end)

    :ok
  end

  test "optional callbacks load a configured adapter before dispatch" do
    state = %{"test_pid" => self()}
    context = %{"source" => "test", "transcript" => "canonical"}
    summary = %{"title" => "source"}

    unload_adapter()
    refute function_exported?(@adapter, :prepare_context, 1)
    assert {:ok, %{"source" => "lazy"}} = Summary.prepare_context(state)
    assert_receive :lazy_prepare_context

    unload_adapter()
    refute function_exported?(@adapter, :summarize, 2)
    assert {:ok, %{"title" => "canonical"}} = Summary.summarize(state, context)
    assert_receive {:lazy_summarize, ^context}
    refute_receive :legacy_summarize

    unload_adapter()
    refute function_exported?(@adapter, :attribute, 3)
    assert {:ok, ^summary} = OwnerAttribution.attribute(state, summary, context)
    assert_receive {:lazy_attribute, ^context}
    refute_receive :legacy_attribute
  end

  defp unload_adapter do
    :code.purge(@adapter)
    :code.delete(@adapter)
    assert :code.is_loaded(@adapter) == false
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
