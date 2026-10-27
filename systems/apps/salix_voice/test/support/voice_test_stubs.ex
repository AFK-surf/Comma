defmodule SalixVoice.TestStubs do
  require SystemsRuntime.Proc

  @moduledoc false
  # Boundary stubs for CallActor tests. Each reports to the pid stored in
  # `SystemsRuntime.get_env(:salix_voice, :test_pid)`.

  defmodule Ingress do
    @moduledoc false
    def enqueue_group_router_im_provider_message(group_id, content, metadata, source_id, opts) do
      delays = SystemsRuntime.get_env(:salix_voice, :test_ingress_delays, %{})
      if delay = delays[metadata["event_type"]], do: SystemsClock.sleep(delay)

      report({:ingress, group_id, content, metadata, source_id, opts})

      SystemsRuntime.get_env(:salix_voice, :test_ingress_result, {:ok, :queued})
    end

    defp report(message),
      do: SystemsRuntime.Proc.send(SystemsRuntime.fetch_env!(:salix_voice, :test_pid), message)
  end

  defmodule ProfileDecider do
    @moduledoc false
    # Stands in for `SalixAgent.RouterDecision`: reports the request and
    # returns `:test_profile_decision`, optionally after `{:sleep, ms, result}`.
    def decide(group_id, _purpose, questions, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_voice, :test_pid),
        {:profile_decide, group_id, questions, opts}
      )

      case SystemsRuntime.get_env(
             :salix_voice,
             :test_profile_decision,
             {:error, "not_configured"}
           ) do
        {:sleep, ms, result} ->
          SystemsClock.sleep(ms)
          result

        result ->
          result
      end
    end
  end

  defmodule Preferences do
    @moduledoc false
    # Stands in for `SalixIM.VoiceConnects`: returns `:test_preferences`.
    def voice_preferences(_group_id, _connect_id),
      do:
        SystemsRuntime.get_env(:salix_voice, :test_preferences, %{
          "voice" => nil,
          "custom_voice" => nil,
          "router_calls" => false
        })
  end

  defmodule Persona do
    @moduledoc false
    # Stands in for `SalixVoice.RouterPersona.resolve/2`: reports the request
    # and returns `:test_persona`.
    def resolve(group_id, audience) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_voice, :test_pid),
        {:persona_resolve, group_id, audience}
      )

      SystemsRuntime.get_env(:salix_voice, :test_persona, {:error, "router_unavailable"})
    end
  end

  defmodule GroupDirectory do
    @moduledoc false
    def get_group(group_id) do
      {:ok,
       %{
         "group_id" => group_id,
         "billing_owner" => %{
           "billing_account_id" => "ba_voice",
           "surface" => "comma",
           "product_owner_type" => "workspace",
           "product_owner_id" => "ws_1"
         }
       }}
    end
  end

  defmodule Metering do
    @moduledoc false
    def authorize(_attrs), do: SystemsRuntime.get_env(:salix_voice, :test_admission, :ok)

    def charge(attrs) do
      case SystemsRuntime.get_env(:salix_voice, :test_pid) do
        pid when SystemsRuntime.Proc.is_process(pid) ->
          SystemsRuntime.Proc.send(pid, {:metered, attrs})

        _ ->
          :ok
      end

      {:ok, %{}}
    end
  end
end
