defmodule SalixWeb.ConnectorResponseChunks do
  @moduledoc """
  Reassembles a gateway HTTP body sent in `response_chunk` frames.

  A connector request with `"response_mode": "chunks"` (`http_request` or
  `lan_http_request` on a gateway that advertises
  `capabilities.lan_gateway.response_chunks`) answers with frames

      {"id": id, "type": "response_chunk", "seq": n, "data_b64": "…"}

  for `n` = 0, 1, … in order, then one `response` frame whose result has
  `"body_encoding": "chunks"`, `"chunks"`, `"body_bytes"` and `"sha256"`, or one
  `error` frame. A frame may hold fewer bytes than the advertised
  `chunk_bytes` (the T-Circle sends 8 KiB), so only the frame count and the
  byte total are checked. `SalixWeb.ConnectorSocket` keeps one of these per
  pending request and times out each gap between frames.

  The parts are kept as a list of binaries. Each decoded part is a reference
  counted binary outside the socket process heap; the list is joined once, on
  the final frame. The result returns the body as raw bytes in `"body_binary"`,
  never as text, so a JSON encoder cannot meet it by accident.
  """

  defstruct parts: [], count: 0, bytes: 0, max_bytes: 0

  # Each frame is a list entry whatever its size, so the count is bounded as
  # well as the bytes: 4 MiB in 8 KiB frames (the T-Circle) is 512 frames, in
  # 32 KiB frames (salix-connect) 128. An empty frame carries nothing and is
  # refused.
  @max_frames 1024

  @type t :: %__MODULE__{}

  @doc "An empty body that accepts at most `max_bytes`."
  @spec new(pos_integer()) :: t()
  def new(max_bytes) when is_integer(max_bytes) and max_bytes > 0,
    do: %__MODULE__{max_bytes: max_bytes}

  @doc "Add frame `seq`. Frames must arrive in order, each once."
  @spec add(t(), term(), term()) :: {:ok, t()} | {:error, String.t()}
  def add(%__MODULE__{count: count}, seq, _data) when seq == count and count >= @max_frames,
    do: {:error, "chunked response exceeds #{@max_frames} frames"}

  def add(%__MODULE__{count: count}, seq, "") when seq == count,
    do: {:error, "chunked response frame #{seq} is empty"}

  def add(%__MODULE__{count: count} = acc, seq, data) when seq == count and is_binary(data) do
    case Base.decode64(data) do
      {:ok, ""} ->
        {:error, "chunked response frame #{seq} is empty"}

      {:ok, part} when acc.bytes + byte_size(part) <= acc.max_bytes ->
        {:ok,
         %{acc | parts: [part | acc.parts], count: count + 1, bytes: acc.bytes + byte_size(part)}}

      {:ok, _part} ->
        {:error, "chunked response exceeds #{acc.max_bytes} bytes"}

      :error ->
        {:error, "chunked response frame #{count} is not base64"}
    end
  end

  def add(%__MODULE__{count: count}, seq, data) when is_integer(seq) and is_binary(data),
    do: {:error, "chunked response frame #{seq} arrived where frame #{count} was expected"}

  def add(%__MODULE__{}, _seq, _data), do: {:error, "chunked response frame is malformed"}

  @doc """
  The final `result` with the reassembled body in `"body_binary"`, after its
  frame count, byte count and SHA-256 match what arrived.
  """
  @spec finish(t(), map()) :: {:ok, map()} | {:error, String.t()}
  def finish(%__MODULE__{} = acc, %{"body_encoding" => "chunks"} = result) do
    body = acc.parts |> Enum.reverse() |> IO.iodata_to_binary()

    cond do
      result["chunks"] != acc.count ->
        {:error,
         "chunked response announced #{inspect(result["chunks"])} frames, #{acc.count} arrived"}

      result["body_bytes"] != acc.bytes ->
        {:error,
         "chunked response announced #{inspect(result["body_bytes"])} bytes, #{acc.bytes} arrived"}

      not sha256?(result["sha256"], body) ->
        {:error, "chunked response failed its sha256 check"}

      true ->
        {:ok,
         result
         |> Map.drop(["chunks", "body", "sha256"])
         |> Map.merge(%{"body_encoding" => "binary", "body_binary" => body})}
    end
  end

  # A gateway that answered in one frame after all, such as an error status
  # with a short text body.
  def finish(%__MODULE__{count: 0}, result) when is_map(result), do: {:ok, result}

  def finish(%__MODULE__{count: count}, _result),
    do: {:error, "chunked response sent #{count} frames without a chunked final frame"}

  defp sha256?(expected, body) when is_binary(expected) do
    actual = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    String.downcase(expected) == actual
  end

  defp sha256?(_expected, _body), do: false
end
