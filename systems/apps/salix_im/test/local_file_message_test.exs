defmodule SalixIM.LocalFileMessageTest do
  use ExUnit.Case, async: true

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

  test "malformed duplicate and over-limit refs fail before append" do
    assert {:error, {:bad_request, "invalid ref-only local attachment"}} =
             ConversationMessage.validate(%{
               "content" => [%{"type" => "local_file", "local_file_ref" => "lfi1_short"}]
             })

    ref = local_ref()

    assert {:error, {:bad_request, "local attachment refs must be unique"}} =
             ConversationMessage.validate(%{
               "content" => [
                 %{"type" => "local_file", "local_file_ref" => ref},
                 %{"type" => "local_file", "local_file_ref" => ref}
               ]
             })

    assert {:error, {:bad_request, "content exceeds the local attachment limit"}} =
             ConversationMessage.validate(%{
               "content" =>
                 for(
                   _ <- 1..51,
                   do: %{"type" => "local_file", "local_file_ref" => local_ref()}
                 )
             })

    assert {:error, {:bad_request, "content exceeds the local attachment byte limit"}} =
             ConversationMessage.validate(%{
               "content" =>
                 for _ <- 1..3 do
                   %{
                     "type" => "local_file",
                     "local_file_ref" => local_ref(),
                     "size" => 400 * 1024 * 1024
                   }
                 end
             })

    assert {:error, {:bad_request, "invalid ref-only local attachment"}} =
             ConversationMessage.validate(%{
               "content" => [
                 %{
                   "type" => "local_file",
                   "local_file_ref" => local_ref(),
                   "size" => 512 * 1024 * 1024 + 1
                 }
               ]
             })
  end

  defp local_ref,
    do: "lfi1_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
