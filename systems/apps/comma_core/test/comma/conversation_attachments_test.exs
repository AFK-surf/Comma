defmodule Comma.ConversationAttachmentsTest do
  use SystemsClock.Case, async: true

  alias Comma.ConversationAttachments
  test "names a download from file_name or its VFS basename, never from the display title" do
    titled = %{"title" => "Quarterly report"}

    assert %{"file_name" => "report.pdf"} =
             ConversationAttachments.describe(
               block(1, nil)
               |> Map.merge(titled)
               |> Map.put("path", "/artifacts/report.pdf")
             )

    assert %{"file_name" => "diagram.png"} =
             ConversationAttachments.describe(
               block(1, nil)
               |> Map.merge(titled)
               |> Map.merge(%{
                 "type" => "image",
                 "file_ref" => %{"environment_id" => "vfs", "path" => "/attachments/diagram.png"}
               })
             )

    assert %{"file_name" => "q3.pdf"} =
             ConversationAttachments.describe(
               block(1, "q3.pdf")
               |> Map.merge(titled)
               |> Map.put("path", "/artifacts/report.pdf")
             )

    assert %{"file_name" => "attachment"} =
             ConversationAttachments.describe(block(1, nil) |> Map.merge(titled))
  end

  for {name, attrs, expected} <- [
        {"source name with a version",
         %{
           "path" => "/artifacts/Release v2.1 - bundle.zip",
           "file_name" => "Release v2.1 - bundle.zip"
         }, "Release v2.1 - bundle.zip"},
        {"legacy dotted description",
         %{
           "path" => "/artifacts/release-bundle.zip",
           "file_name" => "release-bundle.zip — source and checksums v2.1"
         }, "release-bundle.zip"},
        {"legacy filename in description",
         %{
           "path" => "/artifacts/release-bundle.zip",
           "file_name" => "release-bundle.zip - source and README.md"
         }, "release-bundle.zip"},
        {"extensionless explicit rename",
         %{"path" => "/artifacts/archive.zip", "file_name" => "Release notes"}, "Release notes"},
        {"explicit versioned rename",
         %{"path" => "/artifacts/archive.zip", "file_name" => "Release v2.1 - bundle.zip"},
         "Release v2.1 - bundle.zip"},
        {"missing source", %{"file_name" => "release-bundle.zip — source and checksums v2.1"},
         "release-bundle.zip — source and checksums v2.1"},
        {"non-VFS source",
         %{
           "file_name" => "release-bundle.zip — source and README.md",
           "file_ref" => %{"environment_id" => "remote", "path" => "/release-bundle.zip"}
         }, "release-bundle.zip — source and README.md"},
        {"no reliable filename",
         %{"file_ref" => %{"environment_id" => "remote", "path" => "/report.pdf"}}, "attachment"},
        {"image VFS source wins over unrelated path",
         %{
           "type" => "image",
           "path" => "/other/photo.png",
           "file_ref" => %{
             "environment_id" => "vfs",
             "path" => "/artifacts/Release v2.1 - photo.png"
           },
           "file_name" => "Release v2.1 - photo.png — details v2.1"
         }, "Release v2.1 - photo.png"}
      ] do
  end

  defp block(size, file_name \\ "report.pdf") do
    %{
      "blob_ref" => %{"hash" => "sha256:abc", "size" => size, "uuid" => "blob-1"},
      "file_name" => file_name,
      "type" => "file"
    }
  end
end
