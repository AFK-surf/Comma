defmodule SalixIM.SourceRefProtectionTest do
  use ExUnit.Case, async: true

  alias SalixIM.SourceRefProtection

  @key "meeting_activation_refs"
  @value %{"meeting_id" => "meeting-1"}

  test "generic updates may preserve but cannot add, remove, or replace protected refs" do
    assert :ok =
             SourceRefProtection.validate_update(
               %{@key => @value, "calendar_event" => "event-1"},
               %{@key => @value, "calendar_event" => "event-2"}
             )

    assert {:error, {:bad_request, "meeting_activation_refs are product-owned"}} =
             SourceRefProtection.validate_update(%{}, %{@key => @value})

    assert {:error, {:bad_request, "meeting_activation_refs are product-owned"}} =
             SourceRefProtection.validate_update(%{@key => @value}, %{})

    assert {:error, {:bad_request, "meeting_activation_refs are product-owned"}} =
             SourceRefProtection.validate_update(
               %{@key => @value},
               %{@key => %{"meeting_id" => "meeting-2"}}
             )
  end

  test "generic create cannot introduce protected refs" do
    assert :ok = SourceRefProtection.validate_create(%{"calendar_event" => "event-1"})

    assert {:error, {:bad_request, "meeting_activation_refs are product-owned"}} =
             SourceRefProtection.validate_create(%{@key => @value})

    assert {:error, {:bad_request, "meeting_activation_refs are product-owned"}} =
             SourceRefProtection.validate_create(%{meeting_activation_refs: @value})
  end

  test "Triage source ownership uses the same generic boundary without protecting ordinary refs" do
    for key <- ~w(triage_obligation_id triage_delegation_index triage_source_refs) do
      assert {:error, {:bad_request, message}} =
               SourceRefProtection.validate_create(%{key => "forged"})

      assert message == "#{key} are product-owned"

      assert {:error, {:bad_request, ^message}} =
               SourceRefProtection.validate_update(%{}, %{key => "forged"})

      assert :ok =
               SourceRefProtection.validate_update(
                 %{key => "original", "ordinary" => "before"},
                 %{key => "original", "ordinary" => "after"}
               )
    end

    assert :ok = SourceRefProtection.validate_create(%{"ordinary" => "value"})
    assert :ok = SourceRefProtection.validate_update(%{"ordinary" => "before"}, %{})
  end
end
