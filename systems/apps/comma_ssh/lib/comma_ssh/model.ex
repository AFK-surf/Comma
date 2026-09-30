defmodule CommaSSH.Model do
  @moduledoc "Comma terminal screens and commands, independent of the SSH transport."
  @behaviour CommaTUI
  defstruct stage: :connecting,
            editor: %CommaTUI.Editor{},
            lines: ["Connecting…"],
            workspaces: [],
            title: "Comma",
            offset: 0,
            busy: true,
            notice: "",
            size: {80, 24},
            help: false,
            history: [],
            history_index: nil,
            history_draft: nil,
            task_count: nil,
            viewport: nil

  @history_limit 100

  def init(_context), do: {prepare(%__MODULE__{}), []}

  def update(event, model) do
    {model, effects} = do_update(event, model)
    {prepare(model), effects}
  end

  defp do_update({:screen, stage, lines}, model),
    do:
      {%{
         reset_history(model)
         | stage: stage,
           lines: lines,
           editor: %CommaTUI.Editor{},
           busy: false,
           offset: 0,
           task_count: nil
       }, []}

  defp do_update({:workspaces, workspaces}, model) do
    lines =
      (["Select a workspace:"] ++ Enum.with_index(workspaces, 1))
      |> Enum.map(fn
        {workspace, n} -> "#{n}. #{workspace["name"] || workspace["id"]}"
        text -> text
      end)

    {%{
       reset_history(model)
       | stage: :workspace,
         workspaces: workspaces,
         lines: lines,
         task_count: nil,
         busy: false,
         editor: %CommaTUI.Editor{}
     }, []}
  end

  defp do_update({:chat, title, lines}, model),
    do: {%{model | title: "Comma / " <> title, stage: :chat, lines: lines}, []}

  defp do_update({:task_count, count}, model), do: {%{model | task_count: count}, []}

  defp do_update({:notice, text}, model), do: {%{model | notice: text, busy: false}, []}

  defp do_update(:ready, model) do
    notice =
      if model.notice == "Busy: wait, then Enter again.",
        do: "Ready: Enter to send draft.",
        else: model.notice

    {%{model | busy: false, notice: notice}, []}
  end

  defp do_update(:quit, model), do: {model, [:quit]}

  defp do_update(:interrupt, model),
    do: {%{reset_history(model) | editor: %CommaTUI.Editor{}}, []}

  defp do_update({:resize, size}, model), do: {clamp(%{model | size: size}), []}
  defp do_update(:page_up, model), do: {clamp(%{model | offset: clamp(model).offset + 10}), []}

  defp do_update(:page_down, model),
    do: {clamp(%{model | offset: max(clamp(model).offset - 10, 0)}), []}

  defp do_update(:scroll_up, model), do: {clamp(%{model | offset: clamp(model).offset + 3}), []}

  defp do_update(:scroll_down, model),
    do: {clamp(%{model | offset: max(clamp(model).offset - 3, 0)}), []}

  defp do_update(direction, %{stage: :chat} = model) when direction in [:up, :down] do
    editor = CommaTUI.Editor.update(model.editor, direction)

    if model.history_index != nil or editor.cursor == model.editor.cursor do
      {navigate_history(model, direction), []}
    else
      {%{model | editor: editor}, []}
    end
  end

  defp do_update(:submit, model) do
    text = String.trim(model.editor.text)

    cond do
      text == "/quit" ->
        {model, [:quit]}

      text == "/help" ->
        next = %{
          reset_history(model)
          | help: not model.help,
            offset: 0,
            notice: "",
            editor: %CommaTUI.Editor{}
        }

        offset = if next.help, do: CommaTUI.Screen.max_offset(view(next), next.size), else: 0
        {%{next | offset: offset}, []}

      text == "/stop" ->
        {%{
           reset_history(model)
           | notice: "Stop is not supported. /help",
             editor: %CommaTUI.Editor{}
         }, []}

      String.starts_with?(text, "/") and not known_command?(text, model.stage) ->
        {%{reset_history(model) | notice: "Unknown command. /help", editor: %CommaTUI.Editor{}},
         []}

      model.busy ->
        {%{model | notice: "Busy: wait, then Enter again."}, []}

      text == "" ->
        {model, []}

      true ->
        {%{
           remember(model, text)
           | busy: true,
             help: false,
             notice: "",
             editor: %CommaTUI.Editor{},
             offset: 0
         }, [{:submit, model.stage, text}]}
    end
  end

  defp do_update(event, model) do
    editor = CommaTUI.Editor.update(model.editor, event)
    model = if editor.text != model.editor.text, do: reset_history(model), else: model
    {%{model | editor: editor}, []}
  end

  def view(model) do
    %{
      title: model.title,
      lines: if(model.help, do: help_lines(), else: model.lines),
      editor: model.editor,
      secret: model.stage == :code,
      offset: model.offset,
      viewport: model.viewport,
      footer: task_footer(model) <> instructions(model)
    }
  end

  defp task_footer(%{stage: :chat, task_count: %{running: count, partial: partial}}),
    do: "#{if partial, do: "≥", else: ""}#{count} running · "

  defp task_footer(%{stage: :chat}), do: "Tasks unavailable · "
  defp task_footer(_), do: ""

  defp instructions(model) do
    cond do
      model.notice != "" ->
        model.notice

      model.help ->
        "/help back · Wheel/PgUp/PgDn scroll"

      model.busy ->
        "Working…"

      true ->
        "Enter send · Alt+Enter line · ↑↓ history · Wheel scroll · /help"
    end
  end

  defp reset_history(model), do: %{model | history_index: nil, history_draft: nil}

  defp remember(model, text) do
    history =
      if model.stage == :chat,
        do: Enum.take([text | model.history], @history_limit),
        else: model.history

    %{reset_history(model) | history: history}
  end

  defp navigate_history(%{history: []} = model, _), do: model
  defp navigate_history(%{history_index: nil} = model, :down), do: model

  defp navigate_history(%{history_index: 0} = model, :down),
    do: %{reset_history(model) | editor: model.history_draft}

  defp navigate_history(model, direction) do
    index =
      if direction == :up,
        do: min((model.history_index || -1) + 1, length(model.history) - 1),
        else: model.history_index - 1

    text = Enum.at(model.history, index)

    %{
      model
      | history_index: index,
        history_draft: model.history_draft || model.editor,
        editor: %CommaTUI.Editor{text: text, cursor: String.length(text)}
    }
  end

  defp clamp(model) do
    model = prepare(model)
    %{model | offset: min(model.offset, CommaTUI.Screen.max_offset(view(model), model.size))}
  end

  defp prepare(model) do
    lines = if model.help, do: help_lines(), else: model.lines
    viewport = CommaTUI.Layout.prepare_viewport(lines, elem(model.size, 0) - 1, model.viewport)
    %{model | viewport: viewport}
  end

  defp known_command?(text, stage) do
    text in ["/workspace", "/keys"] or String.starts_with?(text, "/revoke ") or
      (stage == :code and text == "/resend")
  end

  defp help_lines do
    [
      "Commands (PgUp/PgDn to scroll)",
      "/help - show or close this help",
      "/workspace - choose a workspace",
      "/keys - list your SSH keys",
      "/revoke KEY_ID - revoke a key",
      "/quit - disconnect (Ctrl+D)",
      "/resend - resend enrollment code",
      "",
      "Enter sends. Alt+Enter adds a line.",
      "Up/Down move between input lines.",
      "At the first/last line, Up/Down recall sent input.",
      "Down past newest restores the draft.",
      "Ctrl+C clears the unsent draft.",
      "Mouse wheel or PgUp/PgDn scroll chat or help.",
      "Stopping generation is not supported.",
      "Disconnect does not stop accepted work."
    ]
  end
end
