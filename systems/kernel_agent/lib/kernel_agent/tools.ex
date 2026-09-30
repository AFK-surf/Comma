defmodule KernelAgent.Tools do
  @moduledoc """
  The tool catalog and its execution. The model sees two tools: `call`, which
  runs one catalog operation, and `end_turn`, which the kernel classifies.

  Catalog:

    * `im_api.internal.send_message` sends to a local conversation.
    * `fs.list`, `fs.read`, `fs.write` work inside the workspace directory.

  The kernel decodes each `call` envelope (`call_envelopes`) and admits each
  call against the current source (`terminal_reply_admission`), with its
  settlement binding. This module runs admitted operations and reports each
  result.
  """

  alias KernelAgent.Store

  @send "im_api.internal.send_message"

  def send_operation, do: @send

  @doc "Tool specs for the provider request."
  def specs do
    [
      %{
        "name" => "call",
        "description" =>
          "Run one operation. Operations: " <>
            "#{@send} {connect_id: \"internal\", conversation_id, content: [{type: \"text\", text}]} sends a message to a conversation; " <>
            "fs.list {path} lists a workspace directory; fs.read {path} reads a workspace file; " <>
            "fs.write {path, content} writes a workspace file.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "tool" => %{"type" => "string", "enum" => [@send, "fs.list", "fs.read", "fs.write"]},
            "params" => %{"type" => "object"}
          },
          "required" => ["tool", "params"]
        }
      },
      %{
        "name" => "end_turn",
        "description" =>
          "Settle the turn: outcome done when the work is complete, optionally with the final reply in reply={tool,params}; outcome blocked with a reason when nothing can progress. This must be the only tool call in the response.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "outcome" => %{"type" => "string", "enum" => ["done", "blocked"]},
            "reason" => %{"type" => "string"},
            "reply" => %{
              "type" => "object",
              "properties" => %{
                "tool" => %{"type" => "string"},
                "params" => %{"type" => "object"}
              },
              "required" => ["tool", "params"]
            }
          },
          "required" => ["outcome"]
        }
      }
    ]
  end

  @doc "Runs the kernel's operations in order and returns one result for each."
  def run(operations, root) do
    Enum.map(operations, fn op ->
      started = System.system_time(:millisecond)

      outcome =
        cond do
          op["error"] -> {:guidance, op["error"]}
          op["refused"] -> {:error, "refused: #{op["refused"]}"}
          true -> execute(op["name"], op["args"], root)
        end

      op
      |> result(outcome, started)
      |> put_binding(op["binding"])
      |> Map.put(:guidance_reason, op["guidance_reason"])
      |> Map.put(:runtime_failure_reply, op["runtime_failure_reply"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end)
  end

  defp result(op, outcome, started) do
    {status, content} =
      case outcome do
        {:ok, content} -> {"completed", content}
        {:error, content} -> {"error", content}
        {:guidance, content} -> {"guidance", content}
      end

    %{
      id: op["id"],
      name: op["name"],
      status: status,
      error: status != "completed",
      content: content,
      input: JSON.encode!(op["args"] || %{}),
      duration_ms: System.system_time(:millisecond) - started
    }
  end

  defp put_binding(result, nil), do: result
  defp put_binding(result, binding), do: Map.put(result, :terminal_reply, binding)

  defp execute(@send, params, root) do
    conversation = params["conversation_id"]
    text = message_text(params)

    if is_binary(conversation) and conversation != "" and is_binary(text) and text != "" do
      Store.append_message(root, conversation, %{"role" => "assistant", "text" => text})
      {:ok, JSON.encode!(%{"status" => "delivered", "conversation_id" => conversation})}
    else
      {:error, "#{@send} needs conversation_id and text content"}
    end
  end

  defp execute("fs." <> op, params, root) do
    with {:ok, path} <- workspace_path(root, params["path"] || ".") do
      fs(op, path, params)
    end
  end

  defp execute(operation, _params, _root), do: {:error, "unknown operation #{inspect(operation)}"}

  defp fs("list", path, _params) do
    case File.ls(path) do
      {:ok, names} -> {:ok, names |> Enum.sort() |> Enum.join("\n")}
      {:error, reason} -> {:error, "fs.list: #{reason}"}
    end
  end

  defp fs("read", path, _params) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "fs.read: #{reason}"}
    end
  end

  defp fs("write", path, %{"content" => content}) when is_binary(content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, "wrote #{byte_size(content)} bytes"}
    else
      {:error, reason} -> {:error, "fs.write: #{reason}"}
    end
  end

  defp fs(op, _path, _params), do: {:error, "fs.#{op}: invalid operation or params"}

  # The path must stay in the workspace lexically, and no component below
  # the workspace may be a symbolic link: a link could lead outside it.
  defp workspace_path(root, relative) when is_binary(relative) do
    workspace = Path.expand(Store.workspace(root))
    path = Path.expand(relative, workspace)

    cond do
      path != workspace and not String.starts_with?(path, workspace <> "/") ->
        {:error, "path escapes the workspace"}

      crosses_link?(workspace, path) ->
        {:error, "path crosses a symbolic link"}

      true ->
        {:ok, path}
    end
  end

  defp workspace_path(_root, _relative), do: {:error, "path must be a string"}

  defp crosses_link?(workspace, path) do
    path
    |> Path.relative_to(workspace)
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.reduce_while(workspace, fn part, dir ->
      next = Path.join(dir, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, true}
        {:ok, _stat} -> {:cont, next}
        {:error, _missing} -> {:halt, false}
      end
    end)
    |> Kernel.==(true)
  end

  defp message_text(%{"content" => content}) when is_list(content),
    do:
      content
      |> Enum.map(&(is_map(&1) && &1["text"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

  defp message_text(%{"text" => text}), do: text
  defp message_text(%{"content" => text}) when is_binary(text), do: text
  defp message_text(_params), do: nil
end
