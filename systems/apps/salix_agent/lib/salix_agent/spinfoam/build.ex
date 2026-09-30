defmodule SalixAgent.Spinfoam.Build do
  @moduledoc """
  One compile through the compiler embedded in this node's spinfoam child,
  shared by `loop.build` and `script.run`: validate the source bundle, send
  one `sf.build.compile` request, and return the ELF bytes with the
  compiler's facts.

  spinfoam (v0.1.2) compiles synchronously inside the request and keeps
  nothing: no build ids, no artifact store, no cache, and no admission
  limit of its own. Every request compiles afresh (about 0.2 s for a small
  program) and compile requests do not take one of the child's 48 request
  slots. Salix does not serialize builds either: a Loop stores the bytes
  as a workspace file, a script loads them right away.
  """

  alias SalixAgent.Loops.Host

  @max_files 32
  @max_source_bytes 128 * 1024
  @max_elf_bytes 64 * 1024

  @type report :: %{
          elf: binary(),
          sha256: String.t() | nil,
          toolchain: String.t() | nil,
          diagnostics: String.t(),
          diagnostics_truncated: boolean(),
          sdk_version: term()
        }

  @type failure :: %{
          state: String.t(),
          error: String.t(),
          kind: String.t(),
          diagnostics: String.t(),
          diagnostics_truncated: boolean()
        }

  def max_files, do: @max_files
  def max_source_bytes, do: @max_source_bytes
  def max_elf_bytes, do: @max_elf_bytes

  @doc """
  Check a source bundle against the limits spinfoam enforces (32 files,
  128 KiB in total, no file named `spinfoam.h`) before a request is issued.
  """
  @spec validate_sources(map(), String.t()) :: :ok | {:error, String.t()}
  def validate_sources(files, entry) when is_map(files) and is_binary(entry) do
    total = files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    cond do
      map_size(files) == 0 ->
        {:error, "at least one source file is required"}

      map_size(files) > @max_files ->
        {:error, "at most #{@max_files} source files"}

      total > @max_source_bytes ->
        {:error, "sources exceed #{@max_source_bytes} bytes"}

      not Map.has_key?(files, entry) ->
        {:error, "entry #{entry} is not among the files"}

      Enum.any?(files, fn {name, _} -> spinfoam_header?(name) end) ->
        {:error, "a source file may not be named spinfoam.h"}

      true ->
        :ok
    end
  end

  def validate_sources(_files, _entry), do: {:error, "files must be a map of name to content"}

  defp spinfoam_header?(name), do: name == "spinfoam.h" or String.ends_with?(name, "/spinfoam.h")

  @doc """
  Compile `files` with `entry` as the translation unit. Returns the ELF
  bytes with the compiler's facts, `{:error, {:build_failed, failure}}`
  with the compiler's own text, or a transport error
  (`{:host_unavailable, reason}`, `:build_timeout`).
  """
  @spec compile(map(), String.t()) ::
          {:ok, report()} | {:error, {:build_failed, failure()} | term()}
  def compile(files, entry) do
    started = System.monotonic_time()

    result =
      case Host.build_compile(files, entry) do
        {:ok, reply} -> finish(reply)
        {:error, :timeout} -> {:error, :build_timeout}
        {:error, _} = error -> error
      end

    emit(result, System.monotonic_time() - started)
    result
  end

  defp finish(%{"state" => "succeeded", "result" => result}) do
    with {:ok, elf} <- decode_elf(result["elf"]) do
      {:ok,
       %{
         elf: elf,
         sha256: result["sha256"],
         toolchain: result["toolchain"],
         diagnostics: text(result["diagnostics"]),
         diagnostics_truncated: result["diagnostics_truncated"] == true,
         sdk_version: result["sdk_version"]
       }}
    end
  end

  # A failed build carries `result.kind` (BUILD_FAILED) and `result.error`,
  # the captured compiler output; the same text is returned as diagnostics
  # so the agent can fix its program. A build the child cancelled at
  # shutdown has state `cancelled` and no result.
  defp finish(%{"state" => state} = status) when is_binary(state) do
    result = status["result"] || %{}
    message = text(result["error"] || "build #{state}")

    {:error,
     {:build_failed,
      %{
        state: state,
        error: message,
        kind: text(result["kind"]),
        diagnostics: text(result["diagnostics"] || message),
        diagnostics_truncated: result["diagnostics_truncated"] == true
      }}}
  end

  defp finish(_reply), do: {:error, :invalid_build_reply}

  defp decode_elf(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, elf} when byte_size(elf) > 0 and byte_size(elf) <= @max_elf_bytes -> {:ok, elf}
      {:ok, _} -> {:error, :elf_too_large}
      :error -> {:error, :invalid_build_reply}
    end
  end

  defp decode_elf(_), do: {:error, :invalid_build_reply}

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)

  defp emit({:ok, _}, duration), do: emit_outcome("ok", duration)
  defp emit({:error, {:build_failed, _}}, duration), do: emit_outcome("rejected", duration)
  defp emit({:error, :build_timeout}, duration), do: emit_outcome("timeout", duration)
  defp emit({:error, _}, duration), do: emit_outcome("error", duration)

  defp emit_outcome(outcome, duration) do
    Salix.Telemetry.emit_operation("salix_agent", "spinfoam_build", "loop", outcome, duration)
  end
end
