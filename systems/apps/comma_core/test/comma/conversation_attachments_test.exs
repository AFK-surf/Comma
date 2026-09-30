defmodule Comma.ConversationAttachmentsTest do
  use ExUnit.Case, async: true

  alias Comma.ConversationAttachments

  @max_download_bytes 10_000_000
  @max_file_name_bytes 1_024

  test "advertises the same inclusive byte range the endpoint and native leaf accept" do
    assert ConversationAttachments.downloadable?(block(0))
    assert ConversationAttachments.downloadable?(block(@max_download_bytes))
    refute ConversationAttachments.downloadable?(block(@max_download_bytes + 1))
  end

  test "bounds the UTF-8 file name before publishing a redeemable locator" do
    exact_name = String.duplicate("界", div(@max_file_name_bytes - 1, 3)) <> "a"

    assert byte_size(exact_name) == @max_file_name_bytes
    assert ConversationAttachments.downloadable?(block(1, exact_name))
    refute ConversationAttachments.downloadable?(block(1, exact_name <> "b"))
  end

  test "rejects incomplete immutable blob identities" do
    for blob_ref <- [
          %{"hash" => "sha256:abc", "size" => 1},
          %{"uuid" => "blob-1", "size" => 1},
          %{"hash" => "sha256:abc", "size" => -1, "uuid" => "blob-1"},
          %{"hash" => "sha256:abc", "size" => 1.0, "uuid" => "blob-1"}
        ] do
      refute ConversationAttachments.downloadable?(%{
               "blob_ref" => blob_ref,
               "file_name" => "report.pdf",
               "type" => "file"
             })
    end
  end

  defp block(size, file_name \\ "report.pdf") do
    %{
      "blob_ref" => %{"hash" => "sha256:abc", "size" => size, "uuid" => "blob-1"},
      "file_name" => file_name,
      "type" => "file"
    }
  end
end
