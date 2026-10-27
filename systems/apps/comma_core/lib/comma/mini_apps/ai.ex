defmodule Comma.MiniApps.AI do
  @moduledoc """
  Mini App model calls: `ai.chat` for text and `ai.decide` for typed decisions.
  All AI calls use the shared `ai.chat` capability and grant.

  Chat uses the viewer Workspace's auxiliary model (its Router template's
  `analyze_config`, `SalixAgent.AnalyzeLLM`), as for chat suggestions. The
  call is admitted by the viewer Workspace's paid-work availability and
  metered to it by `SalixAgent.LLM` (entrypoint `mini_app_ai_chat`). The
  owner Workspace must be available too (`app_paused`). A guest has no
  credits and no Workspace pays for one: `signup_required`.

  A link viewer's Workspace is the first Workspace they own.
  Decisions use `SalixAgent.Decide` with app-supplied state. Billing and archive
  attribution use the viewer Workspace and its existing Router session.
  """

  require Logger

  alias Comma.Data.Workspace
  alias Comma.MiniApps.Billing
  alias SalixAgent.{AnalyzeLLM, Control, Decide, LLM}
  alias SalixStore.RuntimeIds

  @roles ~w(user assistant system)
  @max_messages 50
  @max_chars 100_000
  @max_tokens 2_048

  def chat(user, rt, messages) do
    with :ok <- not_guest(rt),
         :ok <- capability(rt),
         :ok <- granted(rt),
         {:ok, messages} <- messages(messages),
         :ok <- Comma.MiniApps.owner_available(rt.app, "ai_chat"),
         {:ok, workspace} <- viewer_workspace(user, rt),
         :ok <- viewer_admitted(workspace) do
      complete(user, rt, workspace, messages)
    end
  end

  def decide(user, rt, args) do
    with :ok <- not_guest(rt),
         :ok <- capability(rt),
         :ok <- granted(rt),
         :ok <- decision_request(args),
         :ok <- Comma.MiniApps.owner_available(rt.app, "ai_decide"),
         {:ok, workspace} <- viewer_workspace(user, rt),
         :ok <- viewer_admitted(workspace, "ai_decide"),
         {:ok, ctx} <- decision_context(user, rt, workspace) do
      case Decide.system_call(args, ctx, entrypoint: "mini_app_ai_decide", actor_type: "user") do
        {:ok, answer} -> {:ok, answer}
        {:error, "invalid_request"} -> {:error, :invalid}
        {:error, "rate_limited"} -> {:error, :rate_limited}
        {:error, "billing_unavailable"} -> {:error, {:billing_unavailable, :unavailable}}
        {:error, _} -> {:error, :unavailable}
      end
    end
  end

  defp decision_request(args) do
    case Decide.validate(args) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid}
    end
  end

  defp decision_context(user, rt, workspace) do
    # The Workspace owns the expected Group, and Control owns the Router session.
    # Refuse a mismatched reference before billing or archiving under another Workspace.
    group_id = workspace.salix_group_id

    with agent_id when is_binary(agent_id) <- workspace.salix_router_agent_id,
         {:ok, %{"role" => "router", "group_id" => ^group_id} = agent} <-
           Control.get_record(agent_id),
         {:ok, session_id} <- RuntimeIds.persisted_router_session_id(agent) do
      {:ok,
       %{
         agent_id: agent_id,
         session_id: session_id,
         tenant_id: workspace.salix_tenant_id,
         group_id: group_id,
         billing_context: metering(user, rt, workspace, "ai_decide")["billing_context"]
       }}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp not_guest(%{guest: true}), do: {:error, :signup_required}
  defp not_guest(_rt), do: :ok

  defp capability(rt) do
    if "ai.chat" in (rt.version.manifest["capabilities"] || []),
      do: :ok,
      else: {:error, :not_granted}
  end

  # Grants a Workspace stored: on the app for the owner, on the Install
  # otherwise. A link viewer's grant lives in their client.
  defp granted(%{kind: :owner, app: app}),
    do: if("ai.chat" in app.grants, do: :ok, else: {:error, :not_granted})

  defp granted(%{kind: :install, install: install}),
    do: if("ai.chat" in install.grants, do: :ok, else: {:error, :not_granted})

  defp granted(_rt), do: :ok

  defp messages(messages) when is_list(messages) and length(messages) in 1..@max_messages do
    normalized =
      Enum.map(messages, fn
        %{"role" => role, "content" => content} when role in @roles and is_binary(content) ->
          %{role: role, content: content}

        _ ->
          nil
      end)

    total =
      normalized |> Enum.reject(&is_nil/1) |> Enum.map(&String.length(&1.content)) |> Enum.sum()

    cond do
      Enum.any?(normalized, &is_nil/1) -> {:error, :invalid}
      total > @max_chars -> {:error, :invalid}
      true -> {:ok, normalized}
    end
  end

  defp messages(_messages), do: {:error, :invalid}

  defp viewer_workspace(_user, %{workspace: %Workspace{} = workspace}), do: {:ok, workspace}

  defp viewer_workspace(user, _rt) do
    case Comma.Workspaces.list_for_user(user["id"]) do
      {:ok, [%{"id" => id} | _]} ->
        case Comma.Repo.get(Workspace, id) do
          %Workspace{} = workspace -> {:ok, workspace}
          nil -> {:error, :signup_required}
        end

      _ ->
        {:error, :signup_required}
    end
  end

  defp viewer_admitted(workspace, kind \\ "ai_chat") do
    case Billing.viewer_admitted(workspace.billing_owner_id, kind) do
      :ok -> :ok
      {:error, {:billing_unavailable, reason}} -> {:error, {:billing_unavailable, reason}}
      error -> error
    end
  end

  defp complete(user, rt, workspace, messages) do
    agent_id = workspace.salix_router_agent_id

    {:ok, opts} = AnalyzeLLM.resolve(agent_id)
    opts = llm_opts(opts, metering(user, rt, workspace))

    case LLM.complete(messages, [], opts, agent_id: agent_id) do
      {:final, text} ->
        reply(text)

      {:final, text, _} ->
        reply(text)

      {:final, text, _, _} ->
        reply(text)

      {:assistant, text, _} ->
        reply(text)

      {:assistant, text, _, _} ->
        reply(text)

      {:assistant, text, _, _, _} ->
        reply(text)

      other ->
        Logger.warning("mini app ai.chat failed: #{inspect(other) |> String.slice(0, 300)}")
        {:error, :failed}
    end
  end

  defp llm_opts(opts, metering) when is_list(opts) do
    opts
    |> Keyword.put_new(:max_tokens, @max_tokens)
    |> Keyword.put(:billing_context, metering["billing_context"])
    |> Keyword.put(:entrypoint, metering["entrypoint"])
    |> Keyword.put(:actor_type, metering["actor_type"])
  end

  defp llm_opts(opts, metering) when is_map(opts),
    do: opts |> Map.put_new("max_tokens", @max_tokens) |> Map.merge(metering)

  defp llm_opts(_opts, metering), do: Map.put(metering, "max_tokens", @max_tokens)

  defp reply(text) when is_binary(text), do: {:ok, %{"role" => "assistant", "content" => text}}
  defp reply(_text), do: {:error, :failed}

  defp metering(user, rt, workspace, kind \\ "ai_chat") do
    entrypoint = "mini_app_" <> kind

    %{
      "billing_context" => %{
        "billing_account_id" => workspace.billing_owner_id,
        "surface" => "comma",
        "product_owner_type" => "workspace",
        "product_owner_id" => workspace.id,
        "salix_tenant_id" => workspace.salix_tenant_id,
        "salix_group_id" => workspace.salix_group_id,
        "salix_agent_id" => workspace.salix_router_agent_id,
        "charge_policy" => "platform_paid",
        "entrypoint" => entrypoint,
        "actor_type" => "user",
        "actor_user_id" => user["id"],
        "mini_app_id" => rt.app.id
      },
      "entrypoint" => entrypoint,
      "actor_type" => "user"
    }
  end
end
