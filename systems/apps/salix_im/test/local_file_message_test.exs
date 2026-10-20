defmodule SalixIM.LocalFileMessageTest do
  use SystemsClock.Case, async: true

  alias SalixIM.ConversationMessage

  test "canonical content persists an opaque local ref without host routing facts" do
    ref = local_ref()

    assert {:ok, attrs} =
             ConversationMessage.validate(%{
               "content" => [
                 %{"type" => "text", "text" => "review this"},
                 %{
                   "type" => "local_file",
                   "local_file_ref" => ref,
                   "display_name" => "report.pdf",
                   "size" => 42,
                   "media_type" => "application/pdf"
                 }
               ]
             })

    encoded = Jason.encode!(attrs)
    assert encoded =~ ref
    refute encoded =~ "/Users/"

    for forbidden <-
          ~w(path device_id deviceId owner_user_id ownerUserId connector_run_id connectorRunId connection_generation connectionGeneration) do
      refute Map.has_key?(List.last(attrs["content"]), forbidden)
    end
  end

  test "path and routing identity fields are schema-forbidden" do
    for {field, value} <- [
          {"path", "/Users/alice/report.pdf"},
          {"device_id", "dev1_0000000000000000001"},
          {"owner_user_id", "user-1"},
          {"connector_run_id", "run-old"},
          {"connection_generation", 7}
        ] do
      assert {:error, {:bad_request, "invalid ref-only local attachment"}} =
               ConversationMessage.validate(%{
                 "content" => [
                   %{"type" => "local_file", "local_file_ref" => local_ref(), field => value}
                 ]
               })
    end
  end

  defp local_ref,
    do: "lfi1_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)
end
