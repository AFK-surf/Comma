defmodule SalixAgent.PresentationBoundaryTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.{InternalSession, VisibleReplyPolicy}

  defmodule UnavailableAuthority do
    def authorize(_agent_id, _scope), do: raise("authority unavailable")
  end

  test "pending results preserve repair, successful results complete it, and failures spend the configured budget" do
    previous = SystemsRuntime.get_env(:salix_agent, :visible_reply_repair_budget)
    SystemsRuntime.put_env(:salix_agent, :visible_reply_repair_budget, 2)

    on_exit(fn ->
      if previous == nil,
        do: SystemsRuntime.delete_env(:salix_agent, :visible_reply_repair_budget),
        else: SystemsRuntime.put_env(:salix_agent, :visible_reply_repair_budget, previous)
    end)

    assert VisibleReplyPolicy.transition(:clean, [%{diagnostic_visibility: "model_only"}]) ==
             {:required, 0}

    assert VisibleReplyPolicy.transition({:repair_required, 1}, [%{status: "async_running"}]) ==
             {:required, 1}

    assert VisibleReplyPolicy.transition({:repair_required, 1}, [%{status: "completed"}]) ==
             :completed

    assert VisibleReplyPolicy.transition({:repair_required, 1}, [%{status: "error"}]) ==
             {:exhausted, 2}
  end
end
