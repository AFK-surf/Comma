defmodule SalixAgent.WorkerPurposeTest do
  use SystemsClock.Case, async: true
  alias SalixAgent.Tools.AgentManagement

  test "updates cannot erase purpose or rewrite creation provenance, but allow name-only legacy edits" do
    for value <- ["", " \n\t ", nil] do
      assert {:error, :invalid_arguments} =
               AgentManagement.normalize(:update, %{"agent_id" => "worker", "purpose" => value})
    end

    for field <- ~w(creation_reason creation_audit) do
      assert {:error, :invalid_arguments} =
               AgentManagement.normalize(:update, %{
                 "agent_id" => "worker",
                 "name" => "New",
                 field => "forged"
               })
    end

    assert {:ok, _} =
             AgentManagement.normalize(:update, %{"agent_id" => "worker", "name" => "New"})

    assert {:ok, _} =
             AgentManagement.normalize(:update, %{
               "agent_id" => "worker",
               "purpose" => "Confirmed responsibilities"
             })
  end
end
