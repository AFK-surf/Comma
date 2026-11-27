defmodule SalixAgent.ImageRefs.ScreenshotCacheTest do
  @moduledoc """
  The node-local cache of inlined device screenshots: what it keeps, and that
  it stays within its byte budget by dropping the least recently used entry.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.ImageRefs.ScreenshotCache

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :screenshot_cache_max_bytes)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :screenshot_cache_max_bytes, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :screenshot_cache_max_bytes)
    end)

    %{session: "ses1_cache_#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  defp key(session, path), do: {"agt1_cache", session, "dev", "env", path}
  defp image(bytes), do: {:ok, [%{"type" => "image_url", "image_url" => %{"url" => bytes}}]}

  defp counted(result) do
    fn ->
      Process.put(:resolves, Process.get(:resolves, 0) + 1)
      result
    end
  end

  test "keeps a prepared image and an expired note, not a failure that can pass", %{
    session: session
  } do
    Process.put(:resolves, 0)

    for {path, result} <- [
          {"capture-a.png", image("data:image/png;base64,AAAA")},
          {"capture-b.png", {:error, :screenshot_expired}}
        ] do
      assert ScreenshotCache.fetch(key(session, path), counted(result)) == result

      assert ScreenshotCache.fetch(key(session, path), counted({:error, :device_offline})) ==
               result
    end

    assert Process.get(:resolves) == 2

    # An offline device is asked again on the next build.
    offline = key(session, "capture-c.png")

    assert ScreenshotCache.fetch(offline, counted({:error, :device_offline})) ==
             {:error, :device_offline}

    assert ScreenshotCache.fetch(offline, counted(image("data:x"))) == image("data:x")
    assert Process.get(:resolves) == 4
  end

  test "a caller that names no session keeps nothing" do
    Process.put(:resolves, 0)
    ScreenshotCache.fetch(nil, counted(image("data:x")))
    ScreenshotCache.fetch(nil, counted(image("data:x")))
    assert Process.get(:resolves) == 2
  end

  test "past its budget the least recently used entry goes first", %{session: session} do
    SystemsRuntime.put_env(:salix_agent, :screenshot_cache_max_bytes, 8_000)
    big = String.duplicate("x", 1_500)

    for path <- ~w(capture-1.png capture-2.png capture-3.png) do
      ScreenshotCache.fetch(key(session, path), fn -> image(big) end)
    end

    # The oldest is used again, so the second is now the least recently used.
    Process.put(:resolves, 0)
    ScreenshotCache.fetch(key(session, "capture-1.png"), counted(image(big)))
    assert Process.get(:resolves) == 0

    # Two more entries pass the budget: the cache drops entries until it fits.
    for path <- ~w(capture-4.png capture-5.png) do
      ScreenshotCache.fetch(key(session, path), fn -> image(big) end)
    end

    kept =
      Enum.filter(
        ~w(capture-1.png capture-2.png capture-3.png capture-4.png capture-5.png),
        fn path ->
          Process.put(:resolves, 0)
          ScreenshotCache.fetch(key(session, path), counted({:error, :device_offline}))
          Process.get(:resolves) == 0
        end
      )

    assert "capture-1.png" in kept
    refute "capture-2.png" in kept
    assert "capture-5.png" in kept
  end
end
