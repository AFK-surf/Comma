defmodule SalixStore.GCSCASGate do
  @moduledoc false

  # Manual/reference probe only. Do not wire this script into pull_request CI or
  # any GitHub Actions path that grants staging/prod cloud credentials to
  # PR-controlled code.

  defmodule GateError do
    defexception [:message]
  end

  @result_prefix "GCS_CAS_GATE_RESULT="

  def main(["run"]) do
    configure_storage!()

    key = gate_key()
    marker_path = marker_path()

    result =
      try do
        {:ok, run_gate(key, marker_path)}
      rescue
        error in GateError -> {:error, error.message}
        error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    case result do
      {:ok, summary} ->
        IO.puts(
          "GCS CAS gate passed: key=#{key} initial_generation=#{summary.initial_etag} " <>
            "winner=#{summary.winner} final_generation=#{summary.final_etag}"
        )

      {:error, reason} ->
        fail_and_halt!(reason)
    end
  end

  def main(["cleanup", marker_path]) do
    if File.exists?(marker_path) do
      configure_storage!()

      case cleanup_from_marker(marker_path) do
        :ok ->
          File.rm(marker_path)
          IO.puts("GCS CAS gate cleanup completed for marker=#{marker_path}")

        {:error, reason} ->
          fail_and_halt!("cleanup failed for marker=#{marker_path}: #{inspect(reason)}")
      end
    else
      IO.puts("No GCS CAS marker found at #{marker_path}; nothing to clean up.")
    end
  end

  def main(["writer", key, etag, writer]) when writer in ["left", "right"] do
    configure_storage!()

    body = writer_body(key, writer)

    case SalixStore.S3.put(key, body, if_match: etag, content_type: "application/json") do
      {:ok, %{etag: new_etag}} ->
        emit_result(%{
          "result" => "ok",
          "writer" => writer,
          "etag" => new_etag,
          "operation_id" => operation_id(key, writer)
        })

      {:error, :precondition_failed} ->
        emit_result(%{
          "result" => "precondition_failed",
          "writer" => writer,
          "operation_id" => operation_id(key, writer)
        })

      {:error, reason} ->
        emit_result(%{
          "result" => "error",
          "writer" => writer,
          "reason" => inspect(reason)
        })

        System.halt(2)
    end
  end

  def main(["help"]) do
    IO.puts("""
    Manual/reference probe only.
    Do not wire this script into pull_request CI or GitHub Actions gates that
    grant staging/prod cloud credentials to PR-controlled code.

    Usage:
      mix run --no-start scripts/gcs_cas_gate.exs run
      mix run --no-start scripts/gcs_cas_gate.exs cleanup <marker-path>
      mix run --no-start scripts/gcs_cas_gate.exs writer <key> <etag> <left|right>
    """)
  end

  def main(argv) do
    fail_and_halt!("unexpected arguments: #{inspect(argv)}")
  end

  defp run_gate(key, marker_path) do
    write_marker!(marker_path, %{
      "key" => key,
      "stage" => "intent"
    })

    initial_body =
      Jason.encode!(%{
        "gate" => "salix-gcs-cas",
        "key" => key,
        "operation_id" => operation_id(key, "initial"),
        "value" => 0
      })

    initial_etag =
      case SalixStore.S3.put(key, initial_body,
             if_none_match: "*",
             content_type: "application/json"
           ) do
        {:ok, %{etag: etag}} -> etag
        {:error, reason} -> fail!("initial create failed: #{inspect(reason)}")
      end

    write_marker!(marker_path, %{
      "key" => key,
      "initial_etag" => initial_etag,
      "latest_etag" => initial_etag
    })

    results = run_independent_writers(key, initial_etag)
    ok_results = Enum.filter(results, &(&1["result"] == "ok"))
    precondition_results = Enum.filter(results, &(&1["result"] == "precondition_failed"))
    error_results = Enum.reject(results, &(&1["result"] in ["ok", "precondition_failed"]))

    unless error_results == [] do
      fail!("writer process returned error results: #{inspect(error_results)}")
    end

    unless length(ok_results) == 1 and length(precondition_results) == 1 do
      fail!("expected exactly one 200-equivalent success and one 412; got #{inspect(results)}")
    end

    winner = hd(ok_results)["writer"]

    {final_body, final_etag} =
      case SalixStore.S3.get(key) do
        {:ok, %{body: body, etag: etag}} -> {body, etag}
        {:error, reason} -> fail!("readback failed: #{inspect(reason)}")
      end

    final_json = Jason.decode!(final_body)

    unless final_json["writer"] == winner and
             final_json["operation_id"] == operation_id(key, winner) and
             final_json["value"] == 1 do
      fail!("readback did not match the successful writer: #{inspect(final_json)}")
    end

    write_marker!(marker_path, %{
      "key" => key,
      "initial_etag" => initial_etag,
      "latest_etag" => final_etag,
      "winner" => winner
    })

    stale_body =
      Jason.encode!(%{
        "gate" => "salix-gcs-cas",
        "key" => key,
        "operation_id" => operation_id(key, "stale"),
        "value" => 2
      })

    unless SalixStore.S3.put(key, stale_body,
             if_match: initial_etag,
             content_type: "application/json"
           ) == {:error, :precondition_failed} do
      fail!("stale generation write unexpectedly succeeded after winner=#{winner}")
    end

    %{
      initial_etag: initial_etag,
      winner: winner,
      final_etag: final_etag
    }
  end

  defp run_independent_writers(key, etag) do
    ["left", "right"]
    |> Enum.map(fn writer ->
      Task.async(fn -> run_writer_process(key, etag, writer) end)
    end)
    |> Task.await_many(90_000)
  end

  defp run_writer_process(key, etag, writer) do
    env = [{"MIX_ENV", System.get_env("MIX_ENV") || "test"}]

    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-start", "scripts/gcs_cas_gate.exs", "writer", key, etag, writer],
        env: env,
        stderr_to_stdout: true
      )

    result = parse_writer_result(output)

    if status == 0 do
      result
    else
      Map.merge(result || %{}, %{
        "result" => "error",
        "writer" => writer,
        "status" => status,
        "output" => output
      })
    end
  end

  defp parse_writer_result(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find(&String.starts_with?(&1, @result_prefix))
    |> case do
      nil ->
        %{"result" => "error", "reason" => "missing result marker", "output" => output}

      line ->
        line
        |> String.replace_prefix(@result_prefix, "")
        |> Jason.decode!()
    end
  end

  defp configure_storage! do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
    Application.put_env(:salix_store, :s3_endpoint, required_env!("SALIX_S3_ENDPOINT"))
    Application.put_env(:salix_store, :s3_region, required_env!("SALIX_S3_REGION"))
    Application.put_env(:salix_store, :s3_bucket, required_env!("SALIX_S3_BUCKET"))
    Application.put_env(:salix_store, :s3_access_key_id, required_env!("SALIX_S3_ACCESS_KEY_ID"))

    Application.put_env(
      :salix_store,
      :s3_secret_access_key,
      required_env!("SALIX_S3_SECRET_ACCESS_KEY")
    )

    Application.put_env(
      :salix_store,
      :s3_atomic_operations,
      System.get_env("SALIX_S3_ATOMIC_OPERATIONS", "gcp")
    )

    Application.put_env(
      :salix_store,
      :s3_conditional_delete,
      conditional_delete(System.get_env("SALIX_S3_CONDITIONAL_DELETE", "native"))
    )

    Application.put_env(:salix_store, :s3_addressing, :path)

    case Application.ensure_all_started(:salix_store) do
      {:ok, _apps} -> :ok
      {:error, reason} -> fail!("failed to start salix_store: #{inspect(reason)}")
    end
  end

  defp cleanup_from_marker(marker_path) do
    with {:ok, marker_body} <- File.read(marker_path),
         {:ok, marker} <- Jason.decode(marker_body),
         key when is_binary(key) <- marker["key"] do
      cleanup_key(key)
    else
      nil -> {:error, :missing_key}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_marker}
    end
  end

  defp cleanup_key(key) do
    case SalixStore.S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        if cleanup_body_matches_marker?(key, body) do
          case SalixStore.S3.delete(key, if_match: etag) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, {:unexpected_cleanup_body, key}}
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_body_matches_marker?(key, body) do
    with {:ok, json} <- Jason.decode(body),
         true <- json["gate"] == "salix-gcs-cas",
         true <- json["key"] == key,
         true <- String.starts_with?(json["operation_id"] || "", "live-gcs-cas:#{key}:") do
      true
    else
      _ -> false
    end
  end

  defp writer_body(key, writer) do
    Jason.encode!(%{
      "gate" => "salix-gcs-cas",
      "key" => key,
      "operation_id" => operation_id(key, writer),
      "value" => 1,
      "writer" => writer
    })
  end

  defp operation_id(key, writer), do: "live-gcs-cas:#{key}:#{writer}"

  defp gate_key do
    base =
      System.get_env("SALIX_GCS_CAS_PREFIX") ||
        "ci/gcs-cas/manual-#{System.system_time(:second)}"

    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    "#{String.trim_trailing(base, "/")}/#{random}/head.json"
  end

  defp marker_path do
    System.get_env("SALIX_GCS_CAS_MARKER") ||
      Path.join(System.tmp_dir!(), "salix-gcs-cas-marker.json")
  end

  defp write_marker!(marker_path, marker) do
    marker_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(marker_path, Jason.encode!(marker))
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> fail!("missing required env var #{name}")
    end
  end

  defp conditional_delete("native"), do: :native
  defp conditional_delete(_), do: :emulate

  defp emit_result(result) do
    IO.puts(@result_prefix <> Jason.encode!(result))
  end

  defp fail!(message), do: raise(GateError, message: message)

  defp fail_and_halt!(message) do
    IO.puts(:stderr, "GCS CAS gate failed: #{message}")
    System.halt(1)
  end
end

SalixStore.GCSCASGate.main(System.argv())
