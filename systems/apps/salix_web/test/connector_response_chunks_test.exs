defmodule SalixWeb.ConnectorResponseChunksTest do
  @moduledoc """
  A gateway HTTP body sent in `response_chunk` frames, through the connector
  socket's own frame handling: the pending request collects the frames and
  answers its caller once, on the final frame.
  """
  use SystemsClock.Case, async: true

  alias SalixWeb.{ConnectorResponseChunks, ConnectorSocket}

  @id "req_chunked"
  # The T-Circle sends 8 KiB per frame, less than the 32 KiB it advertises.
  @frame_bytes 8 * 1024

  defp start(params \\ %{}) do
    ref = SystemsRuntime.Proc.make_ref()

    request = %{
      "id" => @id,
      "type" => "request",
      "method" => "http_request",
      "params" =>
        Map.merge(
          %{
            "method" => "GET",
            "url" => "http://192.168.5.33/snapshot",
            "response_mode" => "chunks"
          },
          params
        )
    }

    {:push, {:text, _encoded}, state} =
      ConnectorSocket.handle_info(
        {:env_rpc, ref, SystemsRuntime.Proc.self(), request},
        %ConnectorSocket.State{}
      )

    {ref, state}
  end

  defp frame(state, frame) do
    {:ok, state} = ConnectorSocket.handle_in({Jason.encode!(frame), [opcode: :text]}, state)
    state
  end

  defp chunks(state, body, seqs \\ nil) do
    parts = for <<part::binary-size(@frame_bytes) <- body>>, do: part
    rest = binary_part(body, length(parts) * @frame_bytes, rem(byte_size(body), @frame_bytes))
    parts = if rest == "", do: parts, else: parts ++ [rest]
    seqs = seqs || Enum.to_list(0..(length(parts) - 1))

    Enum.reduce(seqs, state, fn seq, state ->
      frame(state, %{
        "id" => @id,
        "type" => "response_chunk",
        "seq" => seq,
        "data_b64" => Base.encode64(Enum.at(parts, seq))
      })
    end)
  end

  defp final(state, body, overrides \\ %{}) do
    frames = div(byte_size(body) + @frame_bytes - 1, @frame_bytes)

    frame(state, %{
      "id" => @id,
      "type" => "response",
      "result" =>
        Map.merge(
          %{
            "status" => 200,
            "headers" => %{"Content-Type" => ["image/jpeg"]},
            "body_encoding" => "chunks",
            "chunks" => frames,
            "body_bytes" => byte_size(body),
            "sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
            "truncated" => false,
            "final_url" => "http://192.168.5.33/snapshot",
            "method" => "GET"
          },
          overrides
        )
    })
  end

  test "frames of any size reassemble into the source bytes, checked by sha256" do
    body = SystemsRuntime.Proc.random_bytes(100 * @frame_bytes + 123)
    {ref, state} = start()

    state = state |> chunks(body) |> final(body)

    assert_receive {:env_rpc_reply, ^ref, {:ok, result}}
    assert result["body_binary"] == body
    assert result["body_encoding"] == "binary"
    assert result["body_bytes"] == byte_size(body)
    assert result["status"] == 200
    refute Map.has_key?(result, "sha256")
    assert state.pending == %{}
  end
end
