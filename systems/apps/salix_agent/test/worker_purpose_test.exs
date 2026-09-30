defmodule SalixAgent.WorkerPurposeTest do
  use ExUnit.Case, async: true
  alias SalixAgent.Tools.AgentManagement

  test "create rejects missing, empty, whitespace and oversized purpose or creation reason" do
    valid = %{
      "name" => "Reviewer",
      "purpose" => "Review backend changes",
      "creation_reason" => "The user requested an independent reviewer",
      "runtime" => %{"kind" => "internal"}
    }

    for field <- ~w(purpose creation_reason) do
      assert {:error, :invalid_arguments} =
               AgentManagement.normalize(:create, Map.delete(valid, field))

      for value <- [nil, "", " \n\t ", String.duplicate("x", 501)] do
        assert {:error, :invalid_arguments} =
                 AgentManagement.normalize(:create, Map.put(valid, field, value))
      end
    end

    assert {:ok, ^valid} =
             AgentManagement.normalize(
               :create,
               Map.update!(valid, "purpose", &(" " <> &1 <> " "))
             )

    assert {:ok, _} =
             AgentManagement.normalize(
               :create,
               Map.put(valid, "creation_reason", String.duplicate("x", 500))
             )
  end

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
