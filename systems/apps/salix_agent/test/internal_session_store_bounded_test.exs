defmodule SalixAgent.InternalSessionStoreBoundedTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalSession, InternalSessionStore, TestSupport}
  alias SalixAgent.TestSupport.SessionFixture

  test "bounded Session folds stop at the row budget and report an incomplete prefix" do
    agent_id = TestSupport.new_agent_id()
    TestSupport.create_control_agent!(agent_id)
    sessions = for _ <- 1..3, do: SalixStore.Ids.new_session_id()
    for session <- sessions, do: assert({:ok, _} = SessionFixture.create(agent_id, session))

    fold = fn session, acc -> {:cont, [InternalSession.session_id(session) | acc]} end

    assert {:ok, loaded, false} =
             InternalSessionStore.reduce_sessions_bounded(agent_id, [], fold,
               page_size: 1,
               max_objects: 2,
               max_pages: 2
             )

    assert Enum.sort(loaded) == sessions |> Enum.sort() |> Enum.take(2)

    assert {:ok, all, true} =
             InternalSessionStore.reduce_sessions_bounded(agent_id, [], fold,
               page_size: 2,
               max_objects: 4,
               max_pages: 2
             )

    assert Enum.sort(all) == Enum.sort(sessions)
  end
end
