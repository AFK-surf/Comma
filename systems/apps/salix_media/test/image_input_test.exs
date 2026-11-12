defmodule SalixMedia.ImageInputTest do
  use SystemsClock.Case, async: true
  alias SalixMedia.ImageInput

  @tag skip: is_nil(System.find_executable("heif-dec")) && "heif-dec is not installed"
  test "a HEIC photo of any size becomes a JPEG" do
    source = SalixMedia.TestImage.small_heic()
    assert byte_size(source) < 512 * 1024

    assert {:ok, <<0xFF, 0xD8, _::binary>>, "image/jpeg"} =
             ImageInput.prepare(source, "image/heic")
  end

  for {mime, image} <- [
        {"image/bmp", :small_bmp},
        {"image/tiff", :small_tiff},
        {"image/avif", :small_avif}
      ] do
    test "a small #{mime} becomes a JPEG" do
      source = apply(SalixMedia.TestImage, unquote(image), [])

      assert {:ok, <<0xFF, 0xD8, _::binary>>, "image/jpeg"} =
               ImageInput.prepare(source, unquote(mime))
    end
  end

  test "a HEIC file that cannot convert never passes through" do
    assert {:error, :image_preview_unavailable} = ImageInput.prepare("not a heic", "image/heic")
  end

  test "large images become bounded JPEG previews without changing their source" do
    source = SalixMedia.TestImage.large_png()
    assert byte_size(source) > 3 * 1024 * 1024
    assert {:ok, preview, "image/jpeg"} = ImageInput.prepare(source, "image/png")
    assert byte_size(preview) <= 512 * 1024
    assert <<0xFF, 0xD8, _::binary>> = preview
    assert source == SalixMedia.TestImage.large_png()

    path =
      Path.join(
        System.tmp_dir!(),
        "image-preview-test-#{SystemsRuntime.Proc.unique_integer([:positive])}.jpg"
      )

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
end
