defmodule SalixMedia.ImageInputTest do
  use ExUnit.Case, async: true
  alias SalixMedia.ImageInput

  test "large images become bounded JPEG previews without changing their source" do
    source = SalixMedia.TestImage.large_png()
    assert byte_size(source) > 3 * 1024 * 1024
    assert {:ok, preview, "image/jpeg"} = ImageInput.prepare(source, "image/png")
    assert byte_size(preview) <= 512 * 1024
    assert <<0xFF, 0xD8, _::binary>> = preview
    assert source == SalixMedia.TestImage.large_png()

    path =
      Path.join(System.tmp_dir!(), "image-preview-test-#{System.unique_integer([:positive])}.jpg")

    File.write!(path, preview)
    on_exit(fn -> File.rm(path) end)

    {dimensions, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height",
        "-of",
        "csv=p=0",
        path
      ])

    [width, height] =
      dimensions |> String.trim() |> String.split(",") |> Enum.map(&String.to_integer/1)

    assert width == 1536
    assert height <= 1536
    assert abs(width / height - 1800 / 800) < 0.01
  end

  test "small images retain their bytes and MIME type" do
    body = <<137, 80, 78, 71, 13, 10, 26, 10>>
    assert {:ok, ^body, "image/png"} = ImageInput.prepare(body, "image/png")
  end

  test "corrupt large input and oversized source never fall back to raw image bytes" do
    assert {:error, :image_preview_unavailable} =
             ImageInput.prepare(:binary.copy("not an image", 60_000), "image/png")

    assert {:error, :oversized} =
             ImageInput.prepare(:binary.copy("x", 10 * 1024 * 1024 + 1), "image/png")
  end
end
