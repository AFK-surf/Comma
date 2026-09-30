defmodule SalixIM.Provider.Voice do
  @moduledoc """
  Router operations on a live voice call (`voice.say`, `voice.note`,
  `voice.hang_up`). Contract: `docs/messaging-voice.md`.

  The call is owned by one CallActor in `salix_voice`. This module finds it
  through the `:pg` group `{:call, call_id}` in the `SalixVoice.PG` scope and
  sends it one `{:voice_provider, op, request}` call. `salix_im` does not
  depend on `salix_voice`: the scope is only an atom here, and a node that
  does not run the voice application answers `voice_call_ended`.

  The CallActor checks that the request's Group and connect equal its own. A
  missing or dead call process is `voice_call_ended`; the tool never retries.
  """

  alias SalixIM.Provider.Util

  @pg_scope SalixVoice.PG
  @call_timeout_ms 5_000
  @max_text_bytes 16_000
  @ops %{"voice.say" => :say, "voice.note" => :note, "voice.hang_up" => :hang_up}

  @doc "The `:pg` scope that holds CallActor groups."
  def pg_scope, do: @pg_scope

  def call(agent_id, connect, api, params) when is_map(connect) do
    params = if is_map(params), do: params, else: %{}

    with {:ok, op} <- operation(api),
         :ok <- Util.ensure_connected(connect),
         {:ok, text} <- text(op, params["text"]),
         {:ok, call_id} <- call_id(params) do
      request = %{
        "group_id" => connect["group_id"],
        "connect_id" => connect["connect_id"],
        "agent_id" => agent_id,
        "delegation_id" => if(op == :hang_up, do: nil, else: delegation_id(params, call_id)),
        "text" => text
      }

      dispatch(call_id, op, request)
    end
  end

  defp operation(api) do
    case Map.fetch(@ops, api) do
      {:ok, op} -> {:ok, op}
      :error -> {:error, "Unsupported voice operation"}
    end
  end

  defp text(:hang_up, nil), do: {:ok, nil}

  defp text(:hang_up, text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      text -> bounded_text(text)
    end
  end

  defp text(_op, text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, "text is required"}
      text -> bounded_text(text)
    end
  end

  defp text(:hang_up, _text), do: {:error, "text must be a string"}
  defp text(_op, _text), do: {:error, "text is required"}

  defp bounded_text(text) do
    if byte_size(text) <= @max_text_bytes and String.valid?(text),
      do: {:ok, text},
      else: {:error, "text must be valid UTF-8 of at most #{@max_text_bytes} bytes"}
  end

  # The trusted origin is the source this Router round answers. Its chat_id
  # is the call and its message_id the delegation (the delegation bridge sets
  # both). Only a voice origin supplies defaults.
  defp call_id(params) do
    case param(params, "call_id") do
      "" ->
        case origin_context()["chat_id"] do
          id when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:error, "call_id is required outside a voice call source"}
        end

      id ->
        {:ok, id}
    end
  end

  defp delegation_id(params, call_id) do
    case param(params, "delegation_id") do
      "" ->
        context = origin_context()

        if context["chat_id"] == call_id and is_binary(context["message_id"]) and
             context["message_id"] != "",
           do: context["message_id"],
           else: nil

      id ->
        id
    end
  end

  defp origin_context do
    case SalixIM.Provider.current_tool_context()["trusted_origin"] do
      %{"provider" => "voice", "provider_context" => context} when is_map(context) -> context
      _ -> %{}
    end
  end

  defp dispatch(call_id, op, request) do
    case call_pid(call_id) do
      {:ok, pid} ->
        try do
          pid
          |> GenServer.call({:voice_provider, op, request}, @call_timeout_ms)
          |> result(call_id)
        catch
          :exit, {:timeout, _} ->
            {:error,
             %{
               "error_class" => "voice_outcome_unknown",
               "message" =>
                 "voice call did not answer in time; the outcome is unknown. Do not repeat the text."
             }}

          :exit, _reason ->
            call_ended()
        end

      :none ->
        call_ended()
    end
  end

  # Hangup is public call state, not a private diagnostic to repair. Keep
  # this terminal outcome visible after another tool succeeds, so the Router
  # does not retry delivery or wait for an ended call to resume.
  defp call_ended do
    {:error,
     %{
       "error_class" => "voice_call_ended",
       "message" => "voice_call_ended",
       "public_summary" =>
         "The voice call has ended. The caller cannot hear further replies. Do not retry voice delivery or wait for this call to resume."
     }}
  end

  @doc false
  def call_pid(call_id) when is_binary(call_id) and call_id != "" do
    case :pg.get_members(@pg_scope, {:call, call_id}) do
      [pid | _] -> {:ok, pid}
      [] -> :none
    end
  rescue
    # The scope's ETS table does not exist: the voice application is not
    # running on this node, so no call can be live here.
    ArgumentError -> :none
  end

  def call_pid(_call_id), do: :none

  defp result({:ok, reply}, call_id) when is_map(reply),
    do: {:ok, Map.put(reply, "call_id", call_id)}

  defp result({:error, :voice_call_ended}, _call_id), do: call_ended()
  defp result({:error, :not_found}, _call_id), do: {:error, "voice delegation not found"}

  defp result({:error, :forbidden}, _call_id),
    do: {:error, "this voice call belongs to another connect"}

  defp result({:error, {:bad_request, message}}, _call_id) when is_binary(message),
    do: {:error, message}

  defp result(_other, _call_id), do: {:error, "voice call rejected the request"}

  defp param(params, key) do
    case params[key] do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end
end
