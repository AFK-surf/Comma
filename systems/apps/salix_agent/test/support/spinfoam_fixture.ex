defmodule SalixAgent.SpinfoamFixture do
  @moduledoc """
  Test-only helpers around the spinfoam runtime.

  `available?/0` says whether the pinned binary is on this machine; suites
  tagged `:spinfoam` skip otherwise. `compile!/1` turns a C program into an
  ELF object through the embedded compiler of the running Host, exactly the
  path `loop.build` takes, so every fixture exercises the real build service
  and no toolchain is needed on the test machine.
  """

  alias SalixAgent.Loops.Host

  @sdk_cache_key {__MODULE__, :sdk}

  def binary do
    case Application.get_env(:salix_agent, :spinfoam_cmd) do
      {exe, _args} -> exe
      _ -> Path.join(:code.priv_dir(:salix_agent), "spinfoam")
    end
  end

  def available?, do: File.exists?(binary())

  def sdk_header do
    case :persistent_term.get(@sdk_cache_key, nil) do
      nil ->
        {sdk, 0} = System.cmd(binary(), ["--dump-sdk"])
        :persistent_term.put(@sdk_cache_key, sdk)
        sdk

      sdk ->
        sdk
    end
  end

  @doc "Compile `code` (which includes \"spinfoam.h\") to ELF bytes through the Host."
  def compile!(code) when is_binary(code) do
    await_host!()

    case Host.build_compile(%{"main.c" => code}, "main.c") do
      {:ok, %{"state" => "succeeded", "result" => %{"elf" => encoded}}} ->
        Base.decode64!(encoded)

      {:ok, %{"state" => state} = status} ->
        raise "spinfoam build #{state}: #{inspect(status["result"])}"

      {:error, reason} ->
        raise "spinfoam build request failed: #{inspect(reason)}"
    end
  end

  defp await_host!(retries \\ 400) do
    cond do
      Host.status().available -> :ok
      retries == 0 -> raise "spinfoam host never became available: #{inspect(Host.status())}"
      true -> Process.sleep(25) && await_host!(retries - 1)
    end
  end

  @doc "A loop that sleeps until stopped, without a host capability call."
  def idle_program do
    """
    #include "spinfoam.h"
    SF_MAIN sf_i64 main(void) {
      for (;;) sf_sleep_ms(60000);
    }
    """
  end

  @doc "A loop that notifies once with `dedup` and then sleeps until stopped."
  def notify_once_program(dedup \\ "cond-1") do
    """
    #include "spinfoam.h"
    static const char ARGS[] = "{\\"content\\":\\"threshold crossed\\",\\"dedup_key\\":\\"#{dedup}\\"}";
    SF_MAIN sf_i64 main(void) {
      sf_handle args = sf_json_parse(ARGS, sizeof(ARGS) - 1);
      if (args < 0) return 10;
      sf_handle reply = sf_host_call("agent.notify", args, 10000);
      if (reply < 0) return reply;
      sf_drop(reply);
      sf_drop(args);
      for (;;) sf_sleep_ms(60000);
    }
    """
  end

  @doc "A loop that sleeps `delay_ms`, notifies once with `dedup`, then idles."
  def delayed_notify_program(delay_ms, dedup \\ "late") do
    """
    #include "spinfoam.h"
    static const char ARGS[] = "{\\"content\\":\\"late condition crossed\\",\\"dedup_key\\":\\"#{dedup}\\"}";
    SF_MAIN sf_i64 main(void) {
      sf_sleep_ms(#{delay_ms});
      sf_handle args = sf_json_parse(ARGS, sizeof(ARGS) - 1);
      if (args < 0) return 10;
      sf_handle reply = sf_host_call("agent.notify", args, 10000);
      if (reply < 0) return reply;
      sf_drop(reply);
      sf_drop(args);
      for (;;) sf_sleep_ms(60000);
    }
    """
  end

  @doc "A loop that returns `code` immediately."
  def exit_program(code) do
    """
    #include "spinfoam.h"
    SF_MAIN sf_i64 main(void) { sf_sleep_ms(10); return #{code}; }
    """
  end

  @doc "A loop that checkpoints config.state.counter + 1 and exits with it."
  def checkpoint_program do
    """
    #include "spinfoam.h"
    SF_MAIN sf_i64 main(void) {
      sf_handle config = sf_config();
      sf_handle state = sf_json_get(config, "state");
      sf_i64 counter = 0;
      if (state > 0) {
        sf_handle value = sf_json_get(state, "counter");
        if (value > 0) { sf_json_i64(value, &counter); sf_drop(value); }
        sf_drop(state);
      }
      counter += 1;
      sf_handle next = sf_json_object();
      sf_handle number = sf_json_number(counter);
      sf_json_set(next, "counter", number);
      sf_handle put = sf_json_object();
      sf_json_set(put, "state", next);
      sf_handle reply = sf_host_call("loop.state.put", put, 10000);
      if (reply < 0) return reply;
      sf_drop(reply);
      return counter;
    }
    """
  end

  @doc "A loop that waits for events, acks each, and notifies with a fixed key."
  def event_program do
    """
    #include "spinfoam.h"
    static const char ARGS[] = "{\\"content\\":\\"event seen\\",\\"dedup_key\\":\\"evt\\"}";
    SF_MAIN sf_i64 main(void) {
      for (;;) {
        sf_handle event = sf_event_next(60000);
        if (event == SF_TIMEOUT) continue;
        if (event < 0) return 1;
        sf_handle ack = sf_host_call("loop.ack", event, 10000);
        if (ack < 0) return 2;
        sf_drop(ack);
        sf_handle args = sf_json_parse(ARGS, sizeof(ARGS) - 1);
        sf_handle reply = sf_host_call("agent.notify", args, 10000);
        if (reply < 0) return 3;
        sf_drop(reply);
        sf_drop(args);
        sf_drop(event);
      }
    }
    """
  end

  @doc """
  A loop that runs one `env.exec` on a fixed device and environment, then
  wakes the session with the command's result text under `dedup`.
  """
  def exec_program(command, dedup \\ "exec-done") do
    """
    #include "spinfoam.h"
    static const char ARGS[] = "{\\"device_id\\":\\"dev-1\\",\\"environment\\":\\"env-1\\",\\"command\\":\\"#{command}\\",\\"description\\":\\"loop exec\\",\\"timeout\\":5}";
    SF_MAIN sf_i64 main(void) {
      sf_handle args = sf_json_parse(ARGS, sizeof(ARGS) - 1);
      if (args < 0) return 10;
      sf_handle reply = sf_host_call("env.exec", args, 30000);
      sf_drop(args);
      if (reply < 0) return reply;
      sf_handle content = sf_json_get(reply, "content");
      if (content < 0) return 11;
      sf_handle wake = sf_json_object();
      sf_handle key = sf_json_string("#{dedup}");
      sf_json_set(wake, "content", content);
      sf_json_set(wake, "dedup_key", key);
      sf_drop(key);
      sf_drop(content);
      sf_drop(reply);
      sf_handle ack = sf_host_call("agent.notify", wake, 10000);
      sf_drop(wake);
      if (ack < 0) return ack;
      sf_drop(ack);
      for (;;) sf_sleep_ms(60000);
    }
    """
  end

  @doc "A loop that calls a capability outside the loop allowlist and returns its status."
  def denied_program do
    """
    #include "spinfoam.h"
    SF_MAIN sf_i64 main(void) {
      sf_handle args = sf_json_object();
      sf_handle reply = sf_host_call("fs.write_file", args, 5000);
      if (reply < 0) return reply;
      sf_drop(reply);
      return 0;
    }
    """
  end

  # ---- script.run programs (SalixAgent.ScriptRun) ---------------------------

  @doc """
  A script that stores the parsed JSON literal `value` with `script.result`
  and returns 0.
  """
  def script_result_program(value) when is_binary(value) do
    """
    #include "spinfoam.h"
    static const char VALUE[] = #{c_literal(value)};
    SF_MAIN sf_i64 main(void) {
      sf_handle value = sf_json_parse(VALUE, sizeof(VALUE) - 1);
      if (value < 0) return 10;
      sf_handle args = sf_json_object();
      sf_json_set(args, "value", value);
      sf_drop(value);
      sf_handle stored = sf_host_call("script.result", args, 5000);
      sf_drop(args);
      if (stored < 0) return stored;
      sf_drop(stored);
      return 0;
    }
    """
  end

  @doc """
  A script that makes one `salix.call` with the JSON literal `call`
  (`{"tool": ..., "args": {...}}`) and stores the whole reply as its result.
  Options: `sleep_ms` before the call, `pick` a key of `value` to store
  instead of the whole reply, `exit_code` to return after storing (default 0),
  `capability` to call instead of `salix.call`.
  """
  def script_call_program(call, opts \\ []) when is_binary(call) do
    sleep = Keyword.get(opts, :sleep_ms, 0)
    pick = Keyword.get(opts, :pick)
    exit_code = Keyword.get(opts, :exit_code, 0)
    capability = Keyword.get(opts, :capability, "salix.call")

    select =
      if pick do
        """
          sf_handle value = sf_json_get(reply, "value");
          if (value < 0) { sf_drop(reply); return 11; }
          sf_handle picked = sf_json_get(value, #{c_literal(pick)});
          sf_drop(value);
          if (picked < 0) { sf_drop(reply); return 12; }
          sf_json_set(args, "value", picked);
          sf_drop(picked);
        """
      else
        """
          sf_json_set(args, "value", reply);
        """
      end

    sleep_line = if sleep > 0, do: "  sf_sleep_ms(#{sleep});", else: ""

    """
    #include "spinfoam.h"
    static const char CALL[] = #{c_literal(call)};
    SF_MAIN sf_i64 main(void) {
    #{sleep_line}
      sf_handle call = sf_json_parse(CALL, sizeof(CALL) - 1);
      if (call < 0) return 10;
      sf_handle reply = sf_host_call(#{c_literal(capability)}, call, 30000);
      sf_drop(call);
      if (reply < 0) return reply;
      sf_handle args = sf_json_object();
    #{select}
      sf_drop(reply);
      sf_handle stored = sf_host_call("script.result", args, 5000);
      sf_drop(args);
      if (stored < 0) return stored;
      sf_drop(stored);
      return #{exit_code};
    }
    """
  end

  @doc "A script that reads env.GREETING and env.NAME and stores \"GREETING, NAME\"."
  def script_env_program do
    """
    #include "spinfoam.h"
    static char out_buf[256];
    SF_MAIN sf_i64 main(void) {
      char *out = out_buf;
      sf_handle config = sf_config();
      sf_handle env = sf_json_get(config, "env");
      if (env < 0) return 10;
      sf_handle greeting = sf_json_get(env, "GREETING");
      sf_handle name = sf_json_get(env, "NAME");
      if (greeting < 0 || name < 0) return 11;
      sf_i64 g = sf_json_read_string(greeting, out, 100);
      if (g < 0 || g > 100) return 12;
      memcpy(out + g, ", ", 2);
      sf_i64 n = sf_json_read_string(name, out + g + 2, 100);
      if (n < 0 || n > 100) return 13;
      sf_drop(greeting); sf_drop(name); sf_drop(env); sf_drop(config);
      sf_handle text = sf_json_string_raw(out, (sf_u64)(g + 2 + n));
      sf_handle args = sf_json_object();
      sf_json_set(args, "value", text);
      sf_drop(text);
      sf_handle stored = sf_host_call("script.result", args, 5000);
      sf_drop(args);
      if (stored < 0) return stored;
      sf_drop(stored);
      return 0;
    }
    """
  end

  @doc "A script that logs two console lines, stores 7 and returns 0."
  def script_log_program do
    """
    #include "spinfoam.h"
    static const char LINE1[] = "{\\"message\\":\\"first line\\"}";
    static const char LINE2[] = "{\\"message\\":\\"second line\\"}";
    SF_MAIN sf_i64 main(void) {
      sf_handle a = sf_json_parse(LINE1, sizeof(LINE1) - 1);
      sf_handle r = sf_host_call("script.log", a, 5000);
      if (r < 0) return r;
      sf_drop(r); sf_drop(a);
      sf_handle b = sf_json_parse(LINE2, sizeof(LINE2) - 1);
      r = sf_host_call("script.log", b, 5000);
      if (r < 0) return r;
      sf_drop(r); sf_drop(b);
      sf_handle args = sf_json_object();
      sf_handle seven = sf_json_number(7);
      sf_json_set(args, "value", seven);
      sf_drop(seven);
      sf_handle stored = sf_host_call("script.result", args, 5000);
      sf_drop(args);
      if (stored < 0) return stored;
      sf_drop(stored);
      return 0;
    }
    """
  end

  @doc "A script that sleeps `ms` milliseconds and returns 0."
  def script_sleep_program(ms) do
    """
    #include "spinfoam.h"
    SF_MAIN sf_i64 main(void) { sf_sleep_ms(#{ms}); return 0; }
    """
  end

  @doc "A script that dereferences a null pointer: a guest fault."
  def script_fault_program do
    """
    #include "spinfoam.h"
    SF_MAIN sf_i64 main(void) { volatile char *p = 0; return *p; }
    """
  end

  # A C string literal for `text` (JSON or plain), escaping quotes and backslashes.
  defp c_literal(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end
end
