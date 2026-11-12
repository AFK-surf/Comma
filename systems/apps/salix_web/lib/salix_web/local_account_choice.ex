defmodule SalixWeb.LocalAccountChoice do
  @moduledoc """
  A computer's own login of a runtime chosen for its Workspace from a Comma
  conversation (the Agent account source in
  `docs/architecture/DOMAIN_CONCEPTS.md`).

  The person chooses, as on the computer itself. `card/5` writes the question
  card: its wording and choices are the server's, naming the computer and the
  runtime, and the Message carries the server-only binding `local_account
  {device_id, runtime}` (`SalixIM.Provider.Internal`), which no Agent
  parameter can set. `choose/4` acts only when the turn's sealed input is the
  computer owner's answer to that card picking `use_local_account`, and only
  for the bound computer and runtime. Then the computer's desktop connection
  is asked (`account_source`, systems/station) to set the source to `local`;
  no other source is set this way, and a computer whose station does not say
  it takes the request is refused before it is asked.
  """

  alias SalixEnv.Control
  alias SalixIM.ConversationQuestion

  @choice "use_local_account"
  @runtimes ~w(claude codex)

  @doc "The question choice id whose answer, by the computer's owner, allows the change."
  def choice_id, do: @choice

  @labels %{
    "en" => %{
      prompt:
        "Run this Task with the %{runtime} signed in on %{device}? Its login becomes the account %{runtime} uses for this workspace on that computer.",
      yes: "Use this computer's login",
      no: "No, drive the computer remotely"
    },
    "zh-CN" => %{
      prompt: "用 %{device} 上已登录的 %{runtime} 运行这个任务吗？这台电脑上的这个登录会成为这个工作区在这台电脑上使用 %{runtime} 的账号。",
      yes: "用这台电脑的登录",
      no: "不用，远程操作这台电脑"
    }
  }

  @doc """
  The question card to ask the computer's owner, and its binding: only for
  the owner asking now, on a connected computer whose station takes
  `account_source`.
  """
  @spec card(String.t(), String.t(), String.t(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def card(agent_id, device_id, runtime, locale, %{trusted_origin: %{} = origin})
      when is_binary(agent_id) and is_binary(device_id) and runtime in @runtimes do
    labels = Map.get(@labels, locale, @labels["en"])

    with {:ok, %{"tenant_id" => tenant_id, "group_id" => group_id}} <-
           SalixAgent.Control.get_record(agent_id),
         conversation when is_binary(conversation) <-
           origin["conversation_id"] || {:error, :confirmation_required},
         {:comma_user, owner} <- SalixAgent.IFC.principal(origin) || {:error, :not_owner},
         {:ok, device} <- owned_device(device_id, group_id, tenant_id, owner),
         :ok <- takes_request(device) do
      words = %{device: device["name"] || device_id, runtime: runtime_name(runtime)}

      {:ok,
       %{
         conversation_id: conversation,
         binding: %{"device_id" => device_id, "runtime" => runtime},
         content: [
           %{
             "type" => "question",
             "prompt" => fill(labels.prompt, words),
             "choices" => [
               %{"id" => @choice, "label" => labels.yes, "recommended" => true},
               %{"id" => "drive_remotely", "label" => labels.no}
             ],
             "multi_select" => false,
             "allow_other" => false
           }
         ]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_owner}
    end
  end

  def card(_agent_id, _device_id, runtime, _locale, _requester) when runtime not in @runtimes,
    do: {:error, :unknown_runtime}

  def card(_agent_id, _device_id, _runtime, _locale, _requester),
    do: {:error, :confirmation_required}

  defp runtime_name("claude"), do: "Claude Code"
  defp runtime_name("codex"), do: "Codex"

  defp fill(text, words),
    do:
      Enum.reduce(words, text, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", value) end)

  @spec choose(String.t(), String.t(), String.t(), map() | nil) :: {:ok, map()} | {:error, term()}
  def choose(agent_id, device_id, runtime, requester)

  def choose(agent_id, device_id, runtime, %{trusted_origin: %{} = origin} = requester)
      when is_binary(agent_id) and is_binary(device_id) and runtime in @runtimes do
    with {:ok, %{"tenant_id" => tenant_id, "group_id" => group_id}} <-
           SalixAgent.Control.get_record(agent_id),
         true <- requester[:group_id] in [nil, group_id] || {:error, :forbidden},
         {:ok, owner} <- answering_owner(group_id, agent_id, origin, device_id, runtime),
         {:ok, device} <- owned_device(device_id, group_id, tenant_id, owner),
         :ok <- takes_request(device),
         {:ok, result} <- ask(device, runtime, owner) do
      {:ok, Map.take(result, ~w(runtime source signed_in))}
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def choose(_agent_id, _device_id, runtime, _requester) when runtime not in @runtimes,
    do: {:error, :unknown_runtime}

  def choose(_agent_id, _device_id, _runtime, _requester), do: {:error, :confirmation_required}

  # The turn's input, as the server sealed it: a user's answer in this Group's
  # conversation to this Agent's server-written card for exactly this computer
  # and runtime (its `local_account` binding), picking yes.
  defp answering_owner(group_id, agent_id, origin, device_id, runtime) do
    with conversation when is_binary(conversation) <- origin["conversation_id"],
         message when is_binary(message) <- origin["message_id"],
         {:ok, %{"actor_type" => "user", "user_id" => user} = answer}
         when is_binary(user) and user != "" <-
           SalixIM.Conversations.get_group_conversation_message(group_id, conversation, message),
         %{"question_message_id" => question_id, "choice_ids" => choice_ids} = picked
         when is_binary(question_id) and is_list(choice_ids) <-
           ConversationQuestion.answer_block(answer["content"]),
         true <- picked["skipped"] != true and @choice in choice_ids,
         {:ok, %{"actor_type" => "agent", "agent_id" => ^agent_id} = asked} <-
           SalixIM.Conversations.get_group_conversation_message(
             group_id,
             conversation,
             question_id
           ),
         %{"device_id" => ^device_id, "runtime" => ^runtime} <-
           get_in(asked, ["metadata", "local_account"]) do
      {:ok, user}
    else
      _ -> {:error, :confirmation_required}
    end
  end

  defp owned_device(device_id, group_id, tenant_id, owner) do
    case Control.get_owned_environment(device_id, group_id, tenant_id, owner) do
      {:ok, %{"status" => "connected", "connector_run_id" => run} = device}
      when is_binary(run) and run != "" ->
        {:ok, device}

      {:ok, _offline} ->
        {:error, :device_offline}

      {:error, :forbidden} ->
        {:error, :not_owner}

      {:error, _} ->
        {:error, :device_not_found}
    end
  end

  defp ask(device, runtime, owner) do
    case SalixEnv.Connector.Live.request(device["connector_run_id"], "account_source", %{
           "runtime" => runtime,
           "source" => "local",
           "by" => owner
         }) do
      {:ok, %{} = result} -> {:ok, result}
      {:error, message} when is_binary(message) -> {:error, {:remote_error, message}}
      {:error, _} = error -> error
      _ -> {:error, :account_source_failed}
    end
  end

  defp takes_request(device) do
    if get_in(device, ["capabilities", "account_source"]) == 1,
      do: :ok,
      else: {:error, :station_outdated}
  end
end
