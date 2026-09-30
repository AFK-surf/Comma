defmodule SalixAgent.Tools.Drive do
  @moduledoc "The user's Comma Drive, as mounted at `/drive/...`."

  alias SalixAgent.{Drive, DriveMount}

  @wait SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  def defs do
    [
      {"drive.status",
       "Whether the user's Comma Drive is reachable from this agent right now, and whether it can be written. The Drive is mounted at /drive/... for the fs.* tools: fs.list_files(\"/drive\") browses it, fs.read_file reads, fs.write_file publishes as the Drive's hosted copy (a device's own version of the same path is kept beside it), fs.delete_file withdraws the hosted copy only. fs.glob and fs.grep over the whole tree do not include the Drive; name /drive/... explicitly. Takes no arguments.",
       &__MODULE__.status/2, @wait}
    ]
  end

  def status(_args, ctx) do
    base = %{"mount" => DriveMount.prefix()}

    case Drive.status(ctx) do
      {:ok, status} ->
        Jason.encode!(
          Map.merge(base, %{
            "available" => status.available,
            "writable" => status.writable,
            "detail" => status.detail
          })
        )

      {:error, reason} ->
        Jason.encode!(
          Map.merge(base, %{
            "available" => false,
            "writable" => false,
            "detail" => DriveMount.describe(reason)
          })
        )
    end
  end
end
