defmodule SalixAgent.Stations.Env do
  @moduledoc """
  Station targets for the remote environment tools in `SalixAgent.Tools.Peers`.

  A target whose `device_id` is `"station:<id>"` is a still.fail station, not a
  connector device. `env.exec`, `env.process_list`, `env.process_write`,
  `env.process_tail` and `env.copy` route here instead of
  `SalixAgent.EnvDispatch` and become `comma/tools/1` ops (contract §8):

    * exec → `exec {command, cwd, env, timeout_ms}`
    * process list/write/tail → `process.list`, `process.write
      {process_id, data_base64}`, `process.tail {process_id, since}`; the
      process name is the `process_id` from `station.process` start
    * copy source → `fs.read {path, offset, length}` in chunks until `eof`
    * copy destination → `fs.write {path, content_base64, append}` in chunks

  The environment id is not used: a station has one command environment.
  Every function returns `{:ok, ...}` or raises with a tool-facing message,
  except `read_stream/3`, which returns `{:error, :not_found}` for a missing
  file as the copy tool expects.
  """

  alias SalixAgent.Stations

  # Contract limit for one fs.read; writes use the same chunk size.
  @chunk_bytes 4 * 1024 * 1024

  def exec(ctx, target, command, opts) do
    args =
      %{"command" => command}
      |> put_present("cwd", opts["working_dir"])
      |> put_present("env", opts["env"])
      |> put_present("timeout_ms", timeout_ms(opts["timeout"]))
      |> put_present("shell", opts["shell"])

    {:ok, call!(ctx, target, "exec", args)}
  end

  def process_list(ctx, target), do: {:ok, call!(ctx, target, "process.list", %{})}

  def process_write(ctx, target, process_id, data, opts) do
    data = if opts["append_newline"] == true, do: data <> "\n", else: data

    {:ok,
     call!(ctx, target, "process.write", %{
       "process_id" => process_id,
       "data_base64" => Base.encode64(data)
     })}
  end

  def process_tail(ctx, target, process_id, opts) do
    args = put_present(%{"process_id" => process_id}, "since", opts["from_offset"])
    result = call!(ctx, target, "process.tail", args)
    data = decode64!(result["data_base64"] || "")
    data = tail(data, opts["tail_bytes"] || opts["max_bytes"])

    output =
      if String.valid?(data),
        do: %{"output" => data},
        else: %{"output_base64" => Base.encode64(data)}

    {:ok,
     output
     |> Map.put("next_offset", result["next"])
     |> Map.put("exited", result["exited"] == true)
     |> put_present("exit_code", result["exit_code"])}
  end

  def read_stream(ctx, target, path) do
    case call(ctx, target, "fs.read", %{"path" => path, "offset" => 0, "length" => @chunk_bytes}) do
      {:ok, first} ->
        chunk = decode64!(first["content_base64"] || "")
        size = if is_integer(first["size"]), do: first["size"], else: nil

        rest =
          Stream.unfold({byte_size(chunk), first["eof"] == true}, fn
            {_offset, true} ->
              nil

            {offset, false} ->
              result =
                call!(ctx, target, "fs.read", %{
                  "path" => path,
                  "offset" => offset,
                  "length" => @chunk_bytes
                })

              data = decode64!(result["content_base64"] || "")
              eof = result["eof"] == true or data == ""
              {data, {offset + byte_size(data), eof}}
          end)

        {:ok, Stream.concat([chunk], rest), size}

      {:error, {:tool, %{"code" => code}}} when code in ["not_found", "ENOENT"] ->
        {:error, :not_found}

      {:error, reason} ->
        raise Stations.describe_error(reason)
    end
  end

  def write_stream(ctx, target, path, stream) do
    {written, chunks} =
      stream
      |> Stream.map(&IO.iodata_to_binary/1)
      |> Stream.flat_map(&split/1)
      |> Enum.reduce({0, 0}, fn chunk, {written, count} ->
        write_chunk!(ctx, target, path, chunk, count > 0)
        {written + byte_size(chunk), count + 1}
      end)

    if chunks == 0, do: write_chunk!(ctx, target, path, "", false)
    {:ok, %{"size" => written}}
  end

  def computer_use(_ctx, _target, _action), do: raise(unsupported("env.computer_use"))
  def android(_ctx, _target, _action), do: raise(unsupported("env.android"))

  defp write_chunk!(ctx, target, path, chunk, append?) do
    call!(ctx, target, "fs.write", %{
      "path" => path,
      "content_base64" => Base.encode64(chunk),
      "append" => append?
    })
  end

  # Chunks never exceed the per-call limit, whatever size the source yields.
  defp split(binary) when byte_size(binary) <= @chunk_bytes, do: [binary]

  defp split(binary) do
    <<head::binary-size(@chunk_bytes), rest::binary>> = binary
    [head | split(rest)]
  end

  defp call!(ctx, target, op, args) do
    case call(ctx, target, op, args) do
      {:ok, result} -> result
      {:error, reason} -> raise Stations.describe_error(reason)
    end
  end

  defp call(ctx, target, op, args), do: Stations.call(ctx, Stations.station_id(target), op, args)

  defp decode64!(encoded) do
    case Base.decode64(encoded) do
      {:ok, data} -> data
      :error -> raise "station returned invalid base64 data"
    end
  end

  defp tail(data, limit) when is_integer(limit) and limit > 0 and byte_size(data) > limit,
    do: binary_part(data, byte_size(data) - limit, limit)

  defp tail(data, _limit), do: data

  defp timeout_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1_000
  defp timeout_ms(_seconds), do: nil

  defp unsupported(tool), do: "#{tool} is not available on stations"

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
