defmodule Comma.ProfileAvatar.Storage do
  @moduledoc "Comma-owned object-storage boundary for private profile avatars."

  @callback start_put(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback finish_put(String.t(), Path.t(), String.t(), pos_integer()) ::
              :ok | {:error, term()}
  @callback cancel_put(String.t()) :: :ok | {:error, term()}
  @callback get(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback delete(String.t()) :: :ok | {:error, term()}

  def start_put(key, content_type),
    do: timed(:put_start, fn -> adapter().start_put(key, content_type) end)

  def finish_put(session_url, path, content_type, byte_size),
    do:
      timed(:put_finish, fn ->
        adapter().finish_put(session_url, path, content_type, byte_size)
      end)

  def cancel_put(session_url),
    do: timed(:put_cancel, fn -> adapter().cancel_put(session_url) end)

  def get(key), do: timed(:get, fn -> adapter().get(key) end)
  def delete(key), do: timed(:delete, fn -> adapter().delete(key) end)

  def configured? do
    case config()[:bucket] do
      bucket when is_binary(bucket) -> String.trim(bucket) != ""
      _other -> false
    end
  end

  def config, do: Application.get_env(:comma_core, :profile_avatar, [])

  defp adapter, do: config()[:adapter] || Comma.ProfileAvatar.Storage.GCS

  defp timed(operation, fun) do
    started = System.monotonic_time()
    result = fun.()

    CommaProduct.Telemetry.emit_operation(
      profile_operation(operation),
      result_tag(result),
      System.monotonic_time() - started
    )

    result
  end

  defp result_tag(:ok), do: :ok
  defp result_tag({:ok, _value}), do: :ok
  defp result_tag({:error, :not_found}), do: :not_found
  defp result_tag({:error, :timeout}), do: :timeout
  defp result_tag({:error, _reason}), do: :error

  defp profile_operation(:put_start), do: :profile_avatar_put_start
  defp profile_operation(:put_finish), do: :profile_avatar_put_finish
  defp profile_operation(:put_cancel), do: :profile_avatar_put_cancel
  defp profile_operation(:get), do: :profile_avatar_get
  defp profile_operation(:delete), do: :profile_avatar_delete
end
