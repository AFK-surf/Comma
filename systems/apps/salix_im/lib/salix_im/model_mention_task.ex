defmodule SalixIM.ModelMentionTask do
  @moduledoc """
  A person's message to the Group's Router that names a model
  (`[name](comma:model/<id>)`, or `comma:model/<id>?effort=<effort>`: the
  composer's @ model mention) starts a Task with that model and the rest of
  the message, without the Router's turn.

  `SalixIM.RouterConversationInput` commits the message delivered to no
  participant: the committed Message is the at-most-once receipt, as for a
  control command. The Task is the Group's Task agent's
  (`SalixIM.TaskPlacement.create_task_conversation/3`), delegated by the
  Router, at the Group's default place; the person who asked owns it and
  writes its first Message, their words. Naming a model chooses it as the menu
  lists it: subscriptions serve it first, and an API key when none can.

  The files the person attached reach the Task: an upload the words name
  (`(workspace file: /uploads/…)`, in the Router's VFS) is shared into the
  Task agent's VFS at the same path before the Task starts. A file kept on the
  person's computer (a `local_file` block) is bound to its one Message and is
  not; the Router's answer says so.

  The Router then answers in the chat with the Task (a `conversation_ref`
  block), or why none started, and is told what happened without a round of
  its own (`no_wake`): its next round knows the Task.
  """

  require Logger

  alias SalixIM.{ConversationMessage, ConversationServer, GroupDirectory}
  alias SalixIM.{RouterConversationInput, TaskPlacement}
  alias SalixIM.Ports.{AgentWorkspace, TaskCreate}

  @mention ~r/\[([^\]\n]{0,200})\]\(comma:model\/([A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,255}?)(?:\?effort=([a-z_]{1,32}))?\)/u
  # An attachment the composer uploaded (`Comma.GroupFiles`), as its words name it.
  @upload ~r/\(workspace file: (\/uploads\/[A-Za-z0-9_-]{22}-[A-Za-z0-9._-]{1,255})\)/
  @title_bytes 120

  @type mention :: %{
          model: String.t(),
          effort: String.t() | nil,
          name: String.t(),
          text: String.t(),
          uploads: [String.t()],
          local_files: non_neg_integer()
        }

  @doc """
  The first model a message names, its effort if it says one, its name as
  written, the text without the model mentions, the uploads the text names and
  how many files on the person's computer `content` carries. `:none` when it
  names none.
  """
  @spec parse(String.t(), term()) :: {:ok, mention()} | :none
  def parse(text, content \\ nil)

  def parse(text, content) when is_binary(text) do
    case Regex.run(@mention, text) do
      [_whole, name, model | effort] ->
        rest = text |> String.replace(@mention, "") |> String.trim()

        {:ok,
         %{
           model: model,
           effort: Enum.find(effort, &(&1 != "")),
           name: String.trim(name),
           text: rest,
           uploads: uploads_named(rest),
           local_files: length(ConversationMessage.local_file_refs(content))
         }}

      nil ->
        :none
    end
  end

  def parse(_text, _content), do: :none

  @doc """
  Starts the Task the committed message `message_id` of `user_id` asks for in
  the Router conversation `conversation`, and answers in it.
  """
  @spec start(String.t(), map(), String.t(), String.t() | nil, mention()) :: :ok
  def start(group_id, conversation, message_id, user_id, mention) do
    router = conversation["router_agent_id"]
    conversation_id = conversation["conversation_id"]

    {reply, context} =
      case create(group_id, router, conversation_id, message_id, user_id, mention) do
        {:ok, %{"conversation_id" => task_id}} ->
          {[
             text_block(
               "Started a Task with #{model_name(mention)}." <> local_files_note(mention)
             ),
             %{
               "type" => "conversation_ref",
               "conversation_id" => task_id,
               "kind" => "agent_task",
               "presentation" => "inline"
             }
           ],
           "The person started a Task directly from Home by naming a model, so you were not asked: " <>
             "\"#{title(mention.text)}\" (conversation #{task_id}) runs with #{model_name(mention)}. " <>
             "It is in your Task list; their words were its first message. This is context only, not a request."}

        {:error, {:upload, path, reason}} ->
          Logger.warning("salix model task upload share failed reason=#{inspect(reason)}")

          {[
             text_block(
               "Could not start a Task with #{model_name(mention)}: " <>
                 "#{upload_name(path)} could not be passed to it; attach it again."
             )
           ], nil}

        {:error, :empty} ->
          {[text_block("Write what the Task should do after the model.")], nil}

        {:error, reason} ->
          {[text_block("Could not start a Task with #{model_name(mention)}: #{refusal(reason)}")],
           nil}
      end

    answer(group_id, conversation_id, router, message_id, reply)
    if context, do: tell_router(group_id, "model-task:" <> message_id, context)
    :ok
  end

  @doc """
  Starts a Task from the New task window (`CommaWeb.WindowTasks`) as a model
  mention in Home does, without the message in Home: the catalog `model` (and
  its `effort`) runs it, `text` is its first Message, and the uploads `text`
  names are shared into it first. Made once per `request_id` of `user_id`.
  Answers the Task as soon as it is made, for the window to open it; the
  Router is told after, off the request and without a round of its own.
  """
  @spec start_from_window(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def start_from_window(
        group_id,
        router,
        user_id,
        request_id,
        %{model: model, text: text} = asked
      )
      when is_binary(text) and text != "" do
    mention = %{
      model: model,
      effort: asked[:effort],
      name: model,
      text: text,
      uploads: uploads_named(text),
      local_files: 0
    }

    with :ok <- share_uploads(group_id, router, mention.uploads),
         {:ok, %{"conversation_id" => task_id} = created} <-
           create_task(
             group_id,
             router,
             user_id,
             mention,
             "comma-window-task:" <> user_id <> ":" <> request_id,
             %{"origin_agent_id" => router}
           ) do
      tell_router_later(
        group_id,
        "window-task:" <> user_id <> ":" <> request_id,
        "The person started a Task from the New task window, so you were not asked: " <>
          "\"#{title(text)}\" (conversation #{task_id}) runs with #{model}. " <>
          "It is in your Task list; their words were its first message. This is context only, not a request."
      )

      {:ok, created}
    end
  end

  @doc """
  Why a Task the window asked for was refused, as the person reads it: the
  model, its effort or place, or a file it names. `:error` for a failure the
  same request may get past when tried again (the Group, its Task agent, the
  Task's create), whose Task may even have been made.
  """
  @spec refusal_message(term()) :: {:ok, String.t()} | :error
  def refusal_message({:upload, path, _reason}),
    do: {:ok, "#{upload_name(path)} could not be passed to the Task; attach it again."}

  def refusal_message({:model, _reason} = reason), do: {:ok, refusal(reason)}
  def refusal_message({:runs_on, _reason, _source} = reason), do: {:ok, refusal(reason)}

  def refusal_message(reason) when reason in [:invalid_model_configuration, :router_changed],
    do: {:ok, refusal(reason)}

  def refusal_message(_reason), do: :error

  defp create(_group_id, _router, _conversation_id, _message_id, _user_id, %{text: ""}),
    do: {:error, :empty}

  defp create(group_id, router, conversation_id, message_id, user_id, mention) do
    with :ok <- share_uploads(group_id, router, mention.uploads) do
      create_task(
        group_id,
        router,
        user_id,
        mention,
        "comma-model-task:" <> conversation_id <> ":" <> message_id,
        %{
          "origin_agent_id" => router,
          "parent_conversation_id" => conversation_id,
          "parent_message_id" => message_id
        }
      )
    end
  end

  defp create_task(group_id, router, user_id, mention, client_request_id, source_refs) do
    model =
      %{"kind" => "catalog", "model" => mention.model, "allow_paid" => true}
      |> put_present("reasoning_effort", mention.effort)

    TaskPlacement.create_task_conversation(
      group_id,
      router,
      %{
        "model" => model,
        "content" => mention.text,
        "title" => title(mention.text),
        "client_request_id" => client_request_id,
        "source_refs" => source_refs
      }
      |> owned_by(user_id)
    )
  end

  # Each upload is shared, not copied, into the Task agent's VFS where the
  # words say it is, before the Task's first Message can reach it.
  defp share_uploads(_group_id, _router, []), do: :ok

  defp share_uploads(group_id, router, paths) do
    with {:ok, worker} <- task_worker(group_id) do
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        with {:ok, ref} <- AgentWorkspace.file_ref(router, path),
             {:ok, _file} <- AgentWorkspace.put_ref(worker, path, ref) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:upload, path, reason}}}
        end
      end)
    end
  end

  defp task_worker(group_id) do
    with {:ok, group} <- group(group_id),
         {:ok, worker} <-
           TaskCreate.task_worker(%{tenant_id: group["tenant_id"], group_id: group_id}) do
      {:ok, worker}
    else
      {:error, {:group, _reason}} = error -> error
      {:error, reason} -> {:error, {:task_worker, reason}}
    end
  end

  defp group(group_id) do
    case GroupDirectory.get_group(group_id) do
      {:ok, group} -> {:ok, group}
      {:error, reason} -> {:error, {:group, reason}}
    end
  end

  defp uploads_named(text),
    do: @upload |> Regex.scan(text, capture: :all_but_first) |> List.flatten() |> Enum.uniq()

  defp upload_name(path) do
    case Regex.run(~r/\A\/uploads\/[A-Za-z0-9_-]{22}-(.+)\z/, path) do
      [_path, name] -> name
      nil -> path
    end
  end

  defp local_files_note(%{local_files: 0}), do: ""

  defp local_files_note(%{local_files: 1}),
    do: " The file from your computer stays in Home: attach it to the Task."

  defp local_files_note(%{local_files: count}),
    do: " The #{count} files from your computer stay in Home: attach them to the Task."

  # The words are the person's: they own the Task and write its first Message.
  defp owned_by(attrs, user_id) when is_binary(user_id) and user_id not in ["", "current"],
    do: Map.merge(attrs, %{"owner_user_id" => user_id, "initial_author" => "owner"})

  defp owned_by(attrs, _user_id), do: attrs

  defp title(text) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if byte_size(line) <= @title_bytes,
      do: line,
      else: String.slice(line, 0, @title_bytes - 1) <> "…"
  end

  defp model_name(%{name: "@" <> name}) when name != "", do: name
  defp model_name(%{name: name}) when name != "", do: name
  defp model_name(%{model: model}), do: model

  defp refusal({:model, _reason} = refusal), do: TaskPlacement.message(refusal)
  defp refusal({:runs_on, _reason, _source} = refusal), do: TaskPlacement.message(refusal)
  defp refusal({:group, _reason} = refusal), do: TaskPlacement.message(refusal)
  defp refusal(:router_changed), do: "the Group's Router changed; send it again"
  defp refusal(:invalid_model_configuration), do: "the model does not take that effort"
  defp refusal(reason), do: inspect(reason)

  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # The Router's line in Home, delivered to no one.
  defp answer(group_id, conversation_id, router, message_id, content) do
    case ConversationServer.append_group_conversation_agent_message(
           group_id,
           conversation_id,
           router,
           %{"content" => content, "client_request_id" => "model-task:" <> message_id}
         ) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        Logger.warning("salix model task reply failed reason=#{inspect(reason)}")
    end
  end

  # Told off the request: the window's answer does not wait for it. Over the
  # bounded pool, the Router learns of the Task from its Task list instead.
  defp tell_router_later(group_id, source_id, context) do
    case SystemsRuntime.TaskSupervisor.start_child(SalixIM.ConversationNotificationTasks, fn ->
           tell_router(group_id, source_id, context)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("salix window task context not started reason=#{inspect(reason)}")
    end
  end

  # What happened, for the Router's next round: staged without waking it.
  defp tell_router(group_id, source_id, context) do
    case RouterConversationInput.append_provider_input(
           group_id,
           source_id,
           %{content: context, name: "Comma", role: "user", no_wake: true},
           %{"provider" => "comma", "event_type" => "model_task"}
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("salix model task context failed reason=#{inspect(reason)}")
    end
  end
end
