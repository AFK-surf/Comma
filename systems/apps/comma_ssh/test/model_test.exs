defmodule CommaSSH.ModelTest do
  use ExUnit.Case, async: true

  test "scroll rows refresh for new messages, width changes and help without losing the draft" do
    {model, []} =
      CommaSSH.Model.update({:chat, "Test", [String.duplicate("中", 30)]}, %CommaSSH.Model{
        busy: false
      })

    {model, []} = CommaSSH.Model.update({:text, "draft"}, model)
    {model, []} = CommaSSH.Model.update({:resize, {20, 8}}, model)
    {model, []} = CommaSSH.Model.update(:page_up, model)
    {_, frame} = CommaTUI.Screen.render(CommaSSH.Model.view(model), model.size)
    assert Enum.at(frame, 2) == String.duplicate("中", 9)
    assert model.offset > 0
    {model, []} = CommaSSH.Model.update({:chat, "Test", ["replacement"]}, model)
    {_, frame} = CommaTUI.Screen.render(CommaSSH.Model.view(model), model.size)
    assert Enum.at(frame, 2) == "replacement"
    assert model.editor.text == "draft"
    {model, []} = CommaSSH.Model.update(:interrupt, model)
    {model, []} = CommaSSH.Model.update({:text, "/help"}, model)
    {model, []} = CommaSSH.Model.update(:submit, model)
    {_, frame} = CommaTUI.Screen.render(CommaSSH.Model.view(model), model.size)
    assert Enum.at(frame, 2) =~ "Commands"
    {model, []} = CommaSSH.Model.update({:text, "/help"}, model)
    {model, []} = CommaSSH.Model.update(:submit, model)
    {_, frame} = CommaTUI.Screen.render(CommaSSH.Model.view(model), model.size)
    assert Enum.at(frame, 2) == "replacement"
  end

  test "workspace task count shows lifecycle totals, partial results and unavailable reads" do
    page = %{
      "data" => [
        %{"kind" => "agent_task", "status" => "active"},
        %{"kind" => "agent_task", "status" => "active"},
        %{"kind" => "agent_task", "status" => "ready_for_review"},
        %{"kind" => "agent_task", "status" => "archived"},
        %{"kind" => "user_chat", "status" => "active"}
      ],
      "has_more" => false
    }

    model = %CommaSSH.Model{stage: :chat, busy: false}
    {model, []} = CommaSSH.Model.update({:task_count, CommaSSH.Chat.task_count(page)}, model)
    assert CommaSSH.Model.view(model).footer =~ "2 running · Enter send"

    {model, []} =
      CommaSSH.Model.update(
        {:task_count, CommaSSH.Chat.task_count(%{page | "has_more" => true})},
        model
      )

    assert CommaSSH.Model.view(model).footer =~ "≥2 running"
    {model, []} = CommaSSH.Model.update({:task_count, nil}, model)
    assert CommaSSH.Model.view(model).footer =~ "Tasks unavailable"
    {model, []} = CommaSSH.Model.update({:screen, :workspace, []}, model)
    refute CommaSSH.Model.view(model).footer =~ "running"
  end

  test "task invalidations coalesce and owner loss clears the count without closing chat" do
    state = %{
      workspace: %{"default_group_id" => "group"},
      task_owner: self(),
      tasks_dirty: false,
      refresh: nil,
      task_count: %{running: 2, partial: false},
      ui: self()
    }

    {:noreply, ^state} =
      CommaSSH.Chat.handle_info(
        {:group_conversation_list_invalidated, "other", "agent_task", "task", "1"},
        state
      )

    event = {:group_conversation_list_invalidated, "group", "agent_task", "task", "2"}
    {:noreply, next} = CommaSSH.Chat.handle_info(event, state)
    assert next.tasks_dirty
    assert is_reference(next.refresh)
    assert {:noreply, ^next} = CommaSSH.Chat.handle_info(event, next)
    Process.cancel_timer(next.refresh)

    {:noreply, lost} =
      CommaSSH.Chat.handle_info({:DOWN, make_ref(), :process, self(), :normal}, next)

    assert lost.task_count == nil
    assert_receive {:chat_ui, _, {:task_count, nil}}
    refute_receive {:chat_close, _}

    stream = spawn(fn -> :ok end)

    assert {:noreply, %{stream: nil}} =
             CommaSSH.Session.handle_info({:EXIT, stream, :normal}, %{stream: stream, ui: self()})

    assert_receive {:ui, {:task_count, nil}}
    assert_receive {:ui, {:notice, _}}
  end

  test "input history restores drafts, preserves multiline movement and allows edited resubmission" do
    model = %CommaSSH.Model{stage: :chat, busy: false}
    model = submit_input(model, "first") |> submit_input("second\nline")
    {model, []} = CommaSSH.Model.update({:text, "中\ndraft"}, model)
    {model, []} = CommaSSH.Model.update(:up, model)
    draft = model.editor
    assert draft.text == "中\ndraft"
    assert draft.cursor == 1
    {model, []} = CommaSSH.Model.update(:up, model)
    assert model.editor.text == "second\nline"
    {model, []} = CommaSSH.Model.update(:up, model)
    assert model.editor.text == "first"
    {model, []} = CommaSSH.Model.update(:up, model)
    assert model.editor.text == "first"
    {model, []} = CommaSSH.Model.update(:down, model)
    assert model.editor.text == "second\nline"
    {model, []} = CommaSSH.Model.update(:down, model)
    assert model.editor == draft
    {model, []} = CommaSSH.Model.update(:up, model)
    {model, []} = CommaSSH.Model.update({:text, "!"}, model)
    {model, [{:submit, :chat, "second\nline!"}]} = CommaSSH.Model.update(:submit, model)
    assert model.history == ["second\nline!", "second\nline", "first"]
    {model, []} = CommaSSH.Model.update(:up, model)
    {model, []} = CommaSSH.Model.update(:interrupt, model)
    {model, []} = CommaSSH.Model.update(:down, model)
    assert model.editor.text == ""
  end

  test "history is bounded and excludes enrollment fields, selections and busy submissions" do
    model = %CommaSSH.Model{stage: :code, busy: false} |> submit_input("123456")
    {model, []} = CommaSSH.Model.update({:screen, :workspace, []}, model)
    model = submit_input(model, "1")
    {model, []} = CommaSSH.Model.update({:screen, :chat, []}, model)
    assert model.history == []
    model = Enum.reduce(1..105, model, &submit_input(&2, "message #{&1}"))
    assert length(model.history) == 100
    assert List.last(model.history) == "message 6"
    {model, []} = CommaSSH.Model.update({:text, "not sent"}, %{model | busy: true})
    {model, []} = CommaSSH.Model.update(:submit, model)
    assert hd(model.history) == "message 105"
    {model, []} = CommaSSH.Model.update(:up, model)
    assert model.editor.text == "message 105"
    {model, []} = CommaSSH.Model.update(:down, model)
    assert model.editor.text == "not sent"
  end

  defp submit_input(model, text) do
    {model, []} = CommaSSH.Model.update({:text, text}, model)
    {model, [{:submit, _, ^text}]} = CommaSSH.Model.update(:submit, model)
    elem(CommaSSH.Model.update(:ready, model), 0)
  end

  test "chat shows user and Agent messages without provider routing or delivery records" do
    messages = [
      %{"actor_type" => "user", "content" => "My question"},
      %{"actor_type" => "system", "content" => "Private routing context", "agent_input" => %{}},
      %{
        "actor_type" => "system",
        "kind" => "app_event",
        "content" => "Internal status",
        "metadata" => %{"event_type" => "provider.status"}
      },
      %{"actor_type" => "agent", "content" => "The answer"}
    ]

    model = %CommaSSH.Model{stage: :chat, lines: CommaSSH.Chat.transcript(messages)}
    {output, _} = CommaTUI.Screen.render(CommaSSH.Model.view(model), model.size)
    assert output =~ "\e[36mYou\e[0m"
    assert output =~ "\e[32mComma\e[0m"
    assert output =~ "My question"
    assert output =~ "The answer"
    refute output =~ "Private routing context"
    refute output =~ "Internal status"
  end

  test "a live transcript update cannot submit or erase a follow-up while a send is pending" do
    {model, []} = CommaSSH.Model.init(%{})
    {model, []} = CommaSSH.Model.update({:screen, :chat, []}, model)
    {model, []} = CommaSSH.Model.update({:text, "first message"}, model)
    {model, [{:submit, :chat, "first message"}]} = CommaSSH.Model.update(:submit, model)
    {model, []} = CommaSSH.Model.update({:text, "follow-up"}, model)
    {model, []} = CommaSSH.Model.update({:chat, "Workspace", ["Comma is working"]}, model)
    assert {next, []} = CommaSSH.Model.update(:submit, model)
    assert next.editor.text == "follow-up"
  end

  test "authorization checks preserve typed input until the channel can accept a command" do
    state = %{
      started: true,
      pending: nil,
      backend: self(),
      render: make_ref(),
      input: %CommaTUI.Input{},
      model: %CommaSSH.Model{stage: :chat, busy: false}
    }

    {:ok, state} = CommaSSH.Channel.handle_msg(:check, state)
    assert_receive {:"$gen_cast", :check}
    {:ok, state} = CommaSSH.Channel.handle_msg({:ui, {:notice, "Connection updated"}}, state)

    {:ok, state} =
      CommaSSH.Channel.handle_ssh_msg({:ssh_cm, self(), {:data, 0, 0, "hello\r"}}, state)

    assert state.model.editor.text == "hello"
    refute_receive {:"$gen_cast", {:submit, _, _}}

    {:ok, state} = CommaSSH.Channel.handle_msg(:done, state)
    {:ok, state} = CommaSSH.Channel.handle_ssh_msg({:ssh_cm, self(), {:data, 0, 0, "\r"}}, state)
    assert_receive {:"$gen_cast", {:submit, :chat, "hello"}}
    assert state.model.editor.text == ""
    Process.cancel_timer(state.pending)
  end

  test "history offset cannot accumulate beyond the first visible page" do
    model = %CommaSSH.Model{
      stage: :chat,
      busy: false,
      lines: Enum.map(1..45, &"line #{&1}"),
      size: {40, 12}
    }

    model =
      Enum.reduce(1..20, model, fn _, model -> elem(CommaSSH.Model.update(:page_up, model), 0) end)

    assert model.offset == CommaTUI.Screen.max_offset(CommaSSH.Model.view(model), model.size)
    {down, []} = CommaSSH.Model.update(:page_down, model)
    assert down.offset == model.offset - 10
    {resized, []} = CommaSSH.Model.update({:resize, {110, 100}}, model)
    assert resized.offset == 0
  end

  test "help is scrollable content at narrow widths and does not lose chat history" do
    model = %CommaSSH.Model{
      stage: :chat,
      busy: false,
      lines: ["saved chat"],
      size: {42, 12},
      editor: %CommaTUI.Editor{text: "/help", cursor: 5}
    }

    {help, []} = CommaSSH.Model.update(:submit, model)
    assert Enum.any?(CommaSSH.Model.view(help).lines, &String.starts_with?(&1, "/quit"))
    {_, frame} = CommaTUI.Screen.render(CommaSSH.Model.view(help), help.size)
    assert Enum.all?(frame, &(CommaTUI.Text.width(&1) <= 41))
    {help, []} = CommaSSH.Model.update(:page_up, help)
    assert help.offset > 0
    {back, []} = CommaSSH.Model.update(:submit, %{help | editor: model.editor})
    assert CommaSSH.Model.view(back).lines == ["saved chat"]
  end

  test "unsupported stop and unknown commands never send chat, even while busy" do
    for busy <- [true, false], command <- ["/stop", "/helpp", "/revoke"] do
      model = %CommaSSH.Model{stage: :chat, busy: busy, editor: %CommaTUI.Editor{text: command}}
      {next, []} = CommaSSH.Model.update(:submit, model)
      assert next.notice != ""
      assert next.editor.text == ""
      assert next.busy == busy
    end
  end

  test "busy submit explains that the draft was not sent and quit still works" do
    model = %CommaSSH.Model{busy: true, editor: %CommaTUI.Editor{text: "draft"}}
    {next, []} = CommaSSH.Model.update(:submit, model)
    assert next.editor.text == "draft"
    assert CommaSSH.Model.view(next).footer =~ "Enter again"

    {:ok, ready} =
      CommaSSH.Channel.handle_msg(:done, %{pending: nil, render: make_ref(), model: next})

    assert ready.model.editor.text == "draft"
    refute ready.model.busy
    assert CommaSSH.Model.view(ready.model).footer == "Ready: Enter to send draft."

    assert {_, [:quit]} =
             CommaSSH.Model.update(:submit, %{model | editor: %CommaTUI.Editor{text: "/quit"}})
  end

  test "an expired previous operation cannot close the current channel" do
    current = make_ref()
    state = %{pending: current}

    assert {:ok, ^state} =
             CommaSSH.Channel.handle_msg({:timeout, make_ref(), :operation_timeout}, state)

    assert {:ok, %{pending: nil}} =
             CommaSSH.Channel.handle_msg({:timeout, current, :operation_timeout}, %{pending: nil})
  end
end
