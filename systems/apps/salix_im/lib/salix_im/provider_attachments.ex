defmodule SalixIM.ProviderAttachments do
  @moduledoc false

  require Logger

  alias SalixIM.Ports.AgentWorkspace

  def stage(agent_id, attachments) do
    with {:ok, prepared, prepare_failures} <- prepare(agent_id, attachments),
         {:ok, staged, publish_failures} <- publish(agent_id, prepared) do
      {:ok, staged, prepare_failures ++ publish_failures}
    end
  end

  def prepare(agent_id, attachments) do
    attachments
    |> List.wrap()
    |> Enum.reduce({[], []}, fn attachment, {prepared, failed} ->
      path = trim(attachment["path"])
      to_blob = attachment["to_blob"]

      cond do
        path == "" ->
          log_stage_failed(agent_id, path, :missing_path)
          {prepared, [failed_attachment(attachment, :missing_path) | failed]}

        not is_function(to_blob, 1) ->
          log_stage_failed(agent_id, path, :missing_blob_stream)
          {prepared, [failed_attachment(attachment, :missing_blob_stream) | failed]}

        true ->
          case prepare_attachment(agent_id, attachment, path, to_blob) do
            {:ok, prepared_attachment} ->
              {[prepared_attachment | prepared], failed}

            {:error, reason} ->
              log_stage_failed(agent_id, path, reason)
              {prepared, [failed_attachment(attachment, reason) | failed]}
          end
      end
    end)
    |> then(fn {prepared, failed} ->
      {:ok, Enum.reverse(prepared), Enum.reverse(failed)}
    end)
  end

  def publish(agent_id, prepared_attachments) do
    prepared_attachments
    |> Enum.reduce({[], []}, fn prepared, {staged, failed} ->
      attachment = prepared["attachment"] || %{}
      ref = prepared["ref"] || %{}

      case AgentWorkspace.put_ref(agent_id, attachment["path"], ref) do
        {:ok, _} ->
          {[attachment | staged], failed}

        {:error, reason} ->
          log_stage_failed(agent_id, attachment["path"], reason)
          {staged, [failed_attachment(attachment, reason) | failed]}
      end
    end)
    |> then(fn {staged, failed} -> {:ok, Enum.reverse(staged), Enum.reverse(failed)} end)
  end

  defp prepare_attachment(agent_id, attachment, path, to_blob) do
    with {:ok, resource} <- to_blob.(agent_id),
         {:ok, ref, staged_attachment} <-
           staged_attachment_from_resource(attachment, path, resource) do
      {:ok, %{"attachment" => staged_attachment, "ref" => ref}}
    end
  end

  defp staged_attachment_from_resource(attachment, path, %{} = resource) do
    if Map.has_key?(resource, :ref) or Map.has_key?(resource, "ref") do
      ref = resource[:ref] || resource["ref"]

      if is_map(ref) do
        {:ok, ref,
         attachment
         |> Map.drop(["to_blob"])
         |> put_nonblank("path", resource[:path] || resource["path"] || path)
         |> put_nonblank("file_name", resource[:file_name] || resource["file_name"])
         |> put_nonblank("mime", resource[:mime_type] || resource["mime_type"])
         |> put_optional("size", resource[:size] || resource["size"])}
      else
        {:error, :invalid_blob_ref}
      end
    else
      {:ok, resource, attachment |> Map.drop(["to_blob"]) |> Map.put("path", path)}
    end
  end

  defp staged_attachment_from_resource(_attachment, _path, _resource),
    do: {:error, :invalid_blob_ref}

  defp failed_attachment(attachment, reason) do
    attachment
    |> Map.drop(["to_blob"])
    |> Map.put("stage_error", attachment_error_class(reason))
  end

  defp attachment_error_class(reason) do
    normalized = reason |> inspect() |> String.downcase()

    cond do
      reason == :missing_download_url ->
        "missing_download_url"

      reason == :missing_provider_credential ->
        "missing_permission"

      match?({:size_limit, _, _}, reason) ->
        "size_limit"

      String.contains?(normalized, ["100 mb", "100mb", "exceeds", "too large"]) ->
        "size_limit"

      String.contains?(normalized, ["permission", "scope", "403", "999916"]) ->
        "missing_permission"

      String.contains?(normalized, ["confidential", "restricted", "保密"]) ->
        "restricted_resource"

      String.contains?(normalized, ["external chat", "external_chat"]) ->
        "external_chat_restricted"

      String.contains?(normalized, ["not found", "404", "deleted"]) ->
        "resource_missing"

      reason == :missing_path ->
        "missing_path"

      reason == :missing_blob_stream ->
        "missing_blob_stream"

      true ->
        "download_failed"
    end
  end

  defp log_stage_failed(agent_id, path, reason) do
    Logger.warning(
      "failed to stage provider attachment #{path} for #{agent_id}: #{inspect(reason)}"
    )
  end

  defp put_nonblank(map, _key, value) when value in [nil, ""], do: map
  defp put_nonblank(map, key, value), do: Map.put(map, key, value)

  defp put_optional(map, _key, value) when value in [nil, ""], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
