defmodule SalixIM.LineFiles do
  @moduledoc """
  Downloads the file of one LINE message into Blob for provider attachment
  staging. LINE serves it from the Messaging API's data host to the channel
  access token; the download streams into Blob and stops at `max_bytes`.
  """

  alias SalixStore.Blob

  # LINE keeps a file a person sent for a limited time and takes files up to
  # 300 MB from people. Override via :salix_im, :line_file_max_bytes.
  @default_max_bytes 200 * 1024 * 1024

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: SystemsRuntime.get_env(:salix_im, :line_file_max_bytes, @default_max_bytes)

  @spec download(String.t(), map(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def download(agent_id, connect, message_id, max_bytes) do
    state_key = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    Process.put(state_key, Blob.put_stream_init(agent_id))

    try do
      result =
        Req.get(SalixIM.Provider.Line.message_content_url(message_id),
          headers: [{"authorization", "Bearer " <> to_string(connect["channel_access_token"])}],
          retry: false,
          redirect: false,
          decode_body: false,
          into: fn {:data, chunk}, {req, resp} ->
            size = (resp.private[:line_bytes] || 0) + byte_size(chunk)

            cond do
              resp.status != 200 ->
                {:halt, {req, resp}}

              size > max_bytes ->
                {:halt,
                 {req,
                  Req.Response.put_private(resp, :line_error, {:size_limit, size, max_bytes})}}

              true ->
                case Blob.put_stream_step(Process.get(state_key), chunk) do
                  {:ok, state} ->
                    Process.put(state_key, state)
                    {:cont, {req, Req.Response.put_private(resp, :line_bytes, size)}}

                  {:error, _reason, state} ->
                    Process.put(state_key, state)

                    {:halt,
                     {req,
                      Req.Response.put_private(resp, :line_error, :line_file_storage_unavailable)}}
                end
            end
          end
        )

      case result do
        {:ok, %{status: 200} = resp} ->
          if error = resp.private[:line_error] do
            Blob.put_stream_abort(Process.get(state_key))
            {:error, error}
          else
            with {:ok, ref} <- Blob.put_stream_finish(Process.get(state_key)) do
              {:ok, %{ref: ref, size: resp.private[:line_bytes] || 0}}
            end
          end

        _other ->
          Blob.put_stream_abort(Process.get(state_key))
          {:error, :line_file_unavailable}
      end
    rescue
      _error ->
        Blob.put_stream_abort(Process.get(state_key))
        {:error, :line_file_unavailable}
    after
      Process.delete(state_key)
    end
  end
end
