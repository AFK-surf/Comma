defmodule SalixAgent.Browser.Commands do
  @moduledoc """
  Finite browser operations over CDP. Page scripts run in an isolated world.

  Every action returns a receipt: the tab, its URL and title, and a viewport
  snapshot of the page after the action. Element refs (`e12`) come from
  snapshots and stay valid until the document navigates. `actions` runs a
  bounded sequence of steps in one command and returns one receipt.
  """
  alias SalixAgent.Browser.{Connection, Input, Page}

  @receipt_chars 6_000
  @snapshot_chars 12_000
  @max_snapshot_chars 40_000
  @batch_ms 30_000
  @max_steps 10
  @step_ops ~w(click fill press scroll select wait navigate)
  # Failures before any input reached the page. A batch reports them as its
  # failed step; every other failure is an unknown outcome and fails the batch.
  @local_failures ~w(target_not_found ambiguous_target stale_element invalid_input invalid_url wait_timeout dialog_open)

  def step_ops, do: @step_ops
  def local_failures, do: @local_failures

  def new(conn, timeout),
    do: %{conn: conn, timeout: timeout, tabs: %{}, refs: %{}, viewers: %{}, cookies: %{}}

  def execute(state, "storage_export", _), do: SalixAgent.Browser.Storage.export(state)

  def execute(state, "storage_restore", snapshot),
    do: SalixAgent.Browser.Storage.restore(state, snapshot)

  def execute(state, "tabs", _) do
    infos = cdp(state, "Target.getTargets")["targetInfos"] |> Enum.filter(&(&1["type"] == "page"))
    selected = Enum.take(infos, 32)
    ids = MapSet.new(selected, & &1["targetId"])
    {keep, drop} = Enum.split_with(state.tabs, fn {id, _} -> MapSet.member?(ids, id) end)

    Enum.each(drop, fn {_, session} ->
      Connection.clear_frame(state.conn, session)
      Connection.command(state.conn, "Target.detachFromTarget", %{sessionId: session})
    end)

    state = %{
      state
      | tabs: Map.new(keep),
        refs: Map.take(state.refs, MapSet.to_list(ids)),
        viewers: Map.take(state.viewers, MapSet.to_list(ids))
    }

    state = Enum.reduce(selected, state, fn info, acc -> attach(acc, info["targetId"]) end)
    {%{"tabs" => Enum.map(selected, &tab_info/1), "truncated" => length(infos) > 32}, state}
  end

  def execute(state, "new_tab", args) do
    {tabs, state} = execute(state, "tabs", args)
    if length(tabs["tabs"]) >= 32, do: fail("driver_busy")
    cdp(state, "Target.createTarget", %{url: "about:blank"})
    execute(state, "tabs", args)
  end

  def execute(%{tabs: tabs} = state, op, %{"tab_id" => _} = args) when map_size(tabs) == 0 do
    {_, state} = execute(state, "tabs", %{})
    perform(state, op, args)
  end

  def execute(state, op, args), do: perform(state, op, args)

  defp perform(state, op, %{"tab_id" => tab} = args) do
    session = state.tabs[tab] || fail("tab_not_found")
    mark = mark(state, tab, session)

    case op do
      "close_tab" ->
        cdp(state, "Target.closeTarget", %{targetId: tab})
        # CDP acknowledges the request before the target necessarily disappears.
        wait_until(state.timeout, fn ->
          not Enum.any?(cdp(state, "Target.getTargets")["targetInfos"], &(&1["targetId"] == tab))
        end)

        execute(state, "tabs", %{})

      "snapshot" ->
        observe(state, tab, session, args)

      "screenshot" ->
        shot =
          cdp(
            state,
            "Page.captureScreenshot",
            %{format: "jpeg", quality: 60, captureBeyondViewport: false},
            session
          )

        {%{"mime_type" => "image/jpeg", "data" => shot["data"]}, state}

      "dialog" ->
        dialog = Connection.dialog(state.conn, session) || fail("invalid_input")
        accept = args["action"] == "accept"
        params = %{accept: accept}

        params =
          if accept and dialog["type"] == "prompt" and is_binary(args["prompt_text"]),
            do: Map.put(params, :promptText, Input.text(args["prompt_text"], 4096)),
            else: params

        cdp(state, "Page.handleJavaScriptDialog", params, session)
        receipt(state, tab, session, mark, %{"handled_dialog" => dialog})

      "actions" ->
        batch(state, tab, session, mark, args["steps"])

      op when op in @step_ops ->
        {state, extra} = act(state, tab, session, op, args, deadline(state.timeout))
        receipt(state, tab, session, mark, extra)

      "input" ->
        Input.dispatch(state, session, args["input"])
        {%{"accepted" => true}, state}

      "release_keys" ->
        Input.release(state, session)
        {%{"released" => true}, state}

      "stream_start" ->
        viewers = Map.get(state.viewers, tab, MapSet.new())
        if MapSet.size(viewers) >= 32, do: fail("driver_busy")

        if MapSet.size(viewers) == 0 do
          Connection.clear_frame(state.conn, session)

          cdp(
            state,
            "Page.startScreencast",
            %{format: "jpeg", quality: 60, maxWidth: 1280, maxHeight: 720, everyNthFrame: 1},
            session
          )
        end

        viewers = MapSet.put(viewers, args["viewer_id"] || "default")
        {%{"streaming" => true}, %{state | viewers: Map.put(state.viewers, tab, viewers)}}

      "stream_stop" ->
        viewers =
          Map.get(state.viewers, tab, MapSet.new())
          |> MapSet.delete(args["viewer_id"] || "default")

        if MapSet.size(viewers) == 0 do
          cdp(state, "Page.stopScreencast", %{}, session)
          Connection.clear_frame(state.conn, session)
        end

        {%{"streaming" => false}, %{state | viewers: Map.put(state.viewers, tab, viewers)}}

      _ ->
        fail("unsupported_operation")
    end
  end

  defp perform(_, _, _), do: fail("invalid_input")

  # One step of a batch or a single action. Returns the state and receipt extras.
  defp act(state, tab, session, "navigate", args, deadline) do
    url = Input.text(args["url"], 4096)
    uri = URI.parse(url)

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo),
      do: fail("invalid_url")

    no_dialog!(state, session)

    # A dialog (beforeunload, or one the new document opens) holds the
    # navigation: the receipt reports it.
    try do
      result = cdp(state, "Page.navigate", %{url: url}, session)
      if result["errorText"], do: fail("browser_operation_failed")
      # The loader identity prevents a previous document's readyState from
      # completing this navigation before the new document commits.
      wait_until(remaining(deadline, state.timeout), fn ->
        tree = cdp(state, "Page.getFrameTree", %{}, session)["frameTree"]["frame"]

        (is_nil(result["loaderId"]) or tree["loaderId"] == result["loaderId"]) and
          evaluate(state, session, "document.readyState !== 'loading'") == true
      end)
    catch
      {:browser_error, "dialog_open"} -> :ok
    end

    # Refs of the old document are stale, but the counter continues so a new
    # snapshot never reuses a ref the agent may still hold.
    next = if entry = state.refs[tab], do: entry.next, else: 1
    {put_in(state.refs[tab], %{generation: :stale, next: next}), %{}}
  end

  defp act(state, tab, session, "click", args, deadline) do
    target = target_of(args)

    {x, y, state} =
      cond do
        target ->
          {object, state} = resolve(state, tab, session, target)

          point =
            wait_until(remaining(deadline, state.timeout), fn ->
              point = call_object(state, session, object, Page.method("clickPoint"))

              case point["error"] do
                "browser_operation_failed" -> false
                nil -> point
                reason -> fail(reason)
              end
            end)

          {point["x"], point["y"], state}

        is_number(args["x"]) and is_number(args["y"]) ->
          {Input.number(args["x"], 0, 1280), Input.number(args["y"], 0, 720), state}

        true ->
          fail("invalid_input")
      end

    no_dialog!(state, session)
    Input.click(state, session, x, y)
    popups(state, tab)
  end

  defp act(state, tab, session, "fill", args, _deadline) do
    text = Input.text(args["text"], 4096)
    {object, state} = resolve(state, tab, session, target_of(args) || fail("invalid_input"))
    no_dialog!(state, session)

    if reason = call_object(state, session, object, Page.method("numberFill", [text])),
      do: fail(reason)

    if reason = call_object(state, session, object, Page.method("prepareFill")), do: fail(reason)

    if text == "",
      do: Input.press(state, session, "Backspace"),
      else: cdp(state, "Input.insertText", %{text: text}, session)

    {state, %{}}
  end

  defp act(state, tab, session, "press", args, _deadline) do
    key = Input.text(args["key"], 128)

    state =
      case target_of(args) do
        nil ->
          state

        target ->
          {object, state} = resolve(state, tab, session, target)
          call_object(state, session, object, "function() { this.focus(); }")
          state
      end

    no_dialog!(state, session)
    Input.press(state, session, key)
    popups(state, tab)
  end

  defp act(state, tab, session, "scroll", args, _deadline) do
    case target_of(args) do
      nil ->
        y = Input.number(args["y"] || fail("invalid_input"), -4000, 4000)
        x = Input.number(args["x"] || 0, -4000, 4000)
        no_dialog!(state, session)
        evaluate(state, session, Page.scroll_by(x, y))
        {state, %{}}

      target ->
        {object, state} = resolve(state, tab, session, target)
        if reason = call_object(state, session, object, Page.method("scrollTo")), do: fail(reason)
        {state, %{}}
    end
  end

  defp act(state, tab, session, "select", args, _deadline) do
    value = Input.text(args["value"], 1024)
    {object, state} = resolve(state, tab, session, target_of(args) || fail("invalid_input"))
    no_dialog!(state, session)

    # A dialog opened by the change handler means the option was selected.
    try do
      if reason = call_object(state, session, object, Page.method("selectOption", [value])),
        do: fail(reason)
    catch
      {:browser_error, "dialog_open"} -> :ok
    end

    {state, %{}}
  end

  defp act(state, _tab, session, "wait", args, deadline) do
    timeout = Input.integer(args["timeout_ms"] || 5000, 1, 10_000)
    timeout = min(timeout, remaining(deadline, timeout))
    url = args["url_contains"] && Input.text(args["url_contains"], 4096)

    condition =
      cond do
        is_binary(args["text"]) -> %{text: Input.text(args["text"], 256)}
        is_binary(args["selector"]) -> %{selector: Input.text(args["selector"], 1024)}
        is_binary(url) -> nil
        true -> fail("invalid_input")
      end

    satisfied =
      poll(SystemsClock.monotonic_time(:millisecond) + timeout, fn ->
        no_dialog!(state, session)

        url_ok =
          is_nil(url) or
            String.contains?(
              cdp(state, "Page.getFrameTree", %{}, session)["frameTree"]["frame"]["url"],
              url
            )

        url_ok and
          (is_nil(condition) or
             case evaluate(state, session, Page.check(condition)) do
               true -> true
               %{"error" => reason} -> fail(reason)
               _ -> false
             end)
      end)

    unless satisfied, do: fail("wait_timeout")
    {state, %{}}
  end

  defp batch(state, tab, session, mark, steps)
       when is_list(steps) and steps != [] and length(steps) <= @max_steps do
    deadline = deadline(@batch_ms)

    {state, completed, failure, extra} =
      steps
      |> Enum.with_index()
      |> Enum.reduce_while({state, 0, nil, %{}}, fn {step, index}, {state, _, _, extra} ->
        op = if is_map(step), do: step["op"], else: nil

        try do
          unless op in @step_ops, do: fail("invalid_input")
          {state, more} = act(state, tab, session, op, step, deadline)
          {:cont, {state, index + 1, nil, merge_extra(extra, more)}}
        catch
          {:browser_error, reason} when reason in @local_failures ->
            {:halt, {state, index, %{"index" => index, "op" => op, "error" => reason}, extra}}

          {:browser_error, reason, details} when reason in @local_failures ->
            failed = Map.merge(details, %{"index" => index, "op" => op, "error" => reason})
            {:halt, {state, index, failed, extra}}

          # An ambiguous target carries the state that keeps its candidates' refs.
          {:browser_error, reason, details, state} when reason in @local_failures ->
            failed = Map.merge(details, %{"index" => index, "op" => op, "error" => reason})
            {:halt, {state, index, failed, extra}}
        end
      end)

    extra = Map.put(extra, "steps_completed", completed)
    extra = if failure, do: Map.put(extra, "failed_step", failure), else: extra
    receipt(state, tab, session, mark, extra)
  end

  defp batch(_, _, _, _, _), do: fail("invalid_input")

  defp merge_extra(extra, more) do
    Map.merge(extra, more, fn
      "new_tabs", old, new -> old ++ new
      _, _, new -> new
    end)
  end

  # Targets: `ref` or `target` ("e12", "text=Save", "role=button[name=\"Save\"]",
  # "css=.item", or a CSS selector).
  defp target_of(%{"ref" => ref}) when is_binary(ref), do: %{ref: ref_name(ref)}
  defp target_of(%{"target" => target}) when is_binary(target), do: parse_target(target)
  defp target_of(_), do: nil

  defp ref_name(ref) do
    ref = ref |> String.trim() |> String.trim_leading("@") |> String.trim("[") |> String.trim("]")
    if Regex.match?(~r/^e\d{1,9}$/, ref), do: ref, else: fail("stale_element")
  end

  defp parse_target(target) do
    target = String.trim(target)
    if target == "" or byte_size(target) > 1024, do: fail("invalid_input")

    cond do
      Regex.match?(~r/^@?\[?e\d{1,9}\]?$/, target) ->
        %{ref: ref_name(target)}

      String.starts_with?(target, "text=") ->
        value = String.trim(String.replace_prefix(target, "text=", ""))

        case Regex.run(~r/^"(.*)"$|^'(.*)'$/s, value) do
          [_, exact] -> %{text: exact, exact: true}
          [_, "", exact] -> %{text: exact, exact: true}
          _ -> %{text: value, exact: false}
        end

      String.starts_with?(target, "role=") ->
        case Regex.run(
               ~r/^role=([\w-]+)(?:\[name=(?:"([^"]*)"|'([^']*)'|([^\]]*))\])?$/,
               target
             ) do
          [_, role] -> %{role: role}
          [_, role, name] -> %{role: role, name: name}
          [_, role, "", name] -> %{role: role, name: name}
          [_, role, "", "", name] -> %{role: role, name: String.trim(name)}
          _ -> fail("invalid_input")
        end

      String.starts_with?(target, "css=") ->
        %{selector: String.replace_prefix(target, "css=", "")}

      true ->
        %{selector: target}
    end
  end

  # Resolves a target to a page object. Refs need the snapshot that issued
  # them to belong to the current document.
  defp resolve(state, tab, session, target) do
    no_dialog!(state, session)
    generation = Connection.generation(state.conn, session)
    entry = state.refs[tab]

    if Map.has_key?(target, :ref) and (is_nil(entry) or entry.generation != generation),
      do: fail("stale_element")

    opts = ref_opts(entry, generation)

    case evaluate(state, session, Page.resolve(target, opts)) do
      %{"error" => reason, "candidates" => _, "next" => next} = result ->
        # The candidates carry refs the agent may use next: keep their counter.
        state = put_in(state.refs[tab], %{generation: generation, next: next})
        throw({:browser_error, reason, Map.take(result, ["count", "candidates"]), state})

      %{"error" => reason} ->
        fail(reason)

      %{"ref" => ref, "next" => next} ->
        state = put_in(state.refs[tab], %{generation: generation, next: next})
        object = evaluate(state, session, Page.element(ref), %{returnByValue: false})
        {object || fail("stale_element"), state}

      _ ->
        fail("browser_operation_failed")
    end
  end

  defp ref_opts(nil, _), do: %{next: 1, reset: true}
  defp ref_opts(%{generation: g, next: next}, g), do: %{next: next, reset: false}
  defp ref_opts(%{next: next}, _), do: %{next: next, reset: true}

  # Tabs the action opened: every page target the driver has not attached yet.
  defp popups(state, _tab) do
    known = state.tabs

    new =
      cdp(state, "Target.getTargets")["targetInfos"]
      |> Enum.filter(&(&1["type"] == "page" and not Map.has_key?(known, &1["targetId"])))
      |> Enum.take(max(0, 32 - map_size(known)))

    state = Enum.reduce(new, state, fn info, acc -> attach(acc, info["targetId"]) end)
    extra = if new == [], do: %{}, else: %{"new_tabs" => Enum.map(new, &tab_info/1)}
    {state, extra}
  end

  defp tab_info(info) do
    %{
      "tab_id" => info["targetId"],
      "url" => String.slice(info["url"], 0, 4096),
      "title" => String.slice(info["title"], 0, 256)
    }
  end

  # The receipt of an action: tab, URL, title and a viewport snapshot. A
  # failed observation never fails the action that already happened.
  defp receipt(state, tab, session, mark, extra) do
    state = settle(state, tab, session, mark)

    {value, state} =
      cond do
        dialog = Connection.dialog(state.conn, session) ->
          {%{"tab_id" => tab, "dialog" => dialog}, state}

        # The old document answers no page command until the new one commits.
        navigating?(state, tab, session) ->
          {%{"tab_id" => tab, "loading" => true}, state}

        true ->
          try do
            observe(state, tab, session, %{"scope" => "viewport", "max_chars" => @receipt_chars})
          catch
            {:browser_error, reason} -> {%{"tab_id" => tab, "snapshot_error" => reason}, state}
            {:browser_error, reason, _} -> {%{"tab_id" => tab, "snapshot_error" => reason}, state}
          end
      end

    value =
      if Map.has_key?(value, "url"),
        do: value,
        else: Map.put(value, "url", target_url(state, tab))

    {Map.merge(value, extra), state}
  end

  # The document and load count of a tab before an action.
  defp mark(state, tab, session) do
    {starts, _} = Connection.load(state.conn, session, tab)
    %{generation: Connection.generation(state.conn, session), starts: starts}
  end

  # A navigation whose document has not committed yet.
  defp navigating?(state, tab, session),
    do: match?({_, :navigating}, Connection.load(state.conn, session, tab))

  # An action that started a navigation waits for the new document before
  # observing it: until the load ends (or is cancelled) or the new document
  # is parsed. A click's navigation starts loading before the browser
  # acknowledges the click. A page command would block while a JavaScript
  # dialog is open.
  defp settle(state, tab, session, mark) do
    try do
      wait_until(min(state.timeout, 5000), fn ->
        {starts, phase} = Connection.load(state.conn, session, tab)

        cond do
          Connection.dialog(state.conn, session) -> true
          starts == mark.starts or phase == :idle -> true
          phase == :navigating -> false
          true -> evaluate(state, session, "document.readyState !== 'loading'") == true
        end
      end)
    catch
      {:browser_error, _} -> :ok
    end

    state
  end

  # The browser answers for a tab even while a dialog blocks its page.
  defp target_url(state, tab) do
    String.slice(
      cdp(state, "Target.getTargetInfo", %{targetId: tab})["targetInfo"]["url"],
      0,
      4096
    )
  catch
    {:browser_error, _} -> ""
  end

  defp observe(state, tab, session, args) do
    no_dialog!(state, session)

    scope =
      case args["scope"] do
        nil -> "viewport"
        scope when scope in ["viewport", "full", "subtree"] -> scope
        _ -> fail("invalid_input")
      end

    max_chars = Input.integer(args["max_chars"] || @snapshot_chars, 500, @max_snapshot_chars)
    generation = Connection.generation(state.conn, session)
    entry = state.refs[tab]

    opts =
      ref_opts(entry, generation)
      |> Map.merge(%{
        scope: scope,
        maxChars: max_chars,
        interactiveOnly: args["interactive_only"] == true
      })

    opts =
      if scope == "subtree" do
        if is_nil(entry) or entry.generation != generation, do: fail("stale_element")
        Map.put(opts, :root, ref_name(args["ref"] || args["target"] || fail("invalid_input")))
      else
        opts
      end

    case evaluate(state, session, Page.snapshot(opts)) do
      %{"error" => reason} ->
        fail(reason)

      %{"text" => text, "next" => next} = result ->
        state = put_in(state.refs[tab], %{generation: generation, next: next})

        value = %{
          "tab_id" => tab,
          "url" => result["url"],
          "title" => result["title"],
          "scope" => scope,
          "snapshot" => text,
          "truncated" => result["truncated"] == true
        }

        value =
          if scope == "viewport" and result["pageHeight"] > result["viewportHeight"],
            do:
              Map.put(value, "scroll", %{
                "y" => result["scrollY"],
                "viewport_height" => result["viewportHeight"],
                "page_height" => result["pageHeight"]
              }),
            else: value

        {value, state}

      _ ->
        fail("browser_operation_failed")
    end
  end

  defp no_dialog!(state, session) do
    if dialog = Connection.dialog(state.conn, session),
      do: fail("dialog_open", %{"dialog" => dialog})
  end

  def cdp(state, method, params \\ %{}, session \\ nil) do
    case Connection.command(state.conn, method, params, session, state.timeout) do
      # A dialog opened while the page ran the command. Input reached the page.
      {:ok, %{"dialog" => true} = value} ->
        if String.starts_with?(method, "Input."), do: value, else: fail("dialog_open")

      {:ok, value} ->
        value

      {:error, reason} ->
        fail(reason)
    end
  end

  defp attach(state, tab) do
    if state.tabs[tab] do
      state
    else
      session = cdp(state, "Target.attachToTarget", %{targetId: tab, flatten: true})["sessionId"]
      cdp(state, "Page.enable", %{}, session)
      cdp(state, "Runtime.enable", %{}, session)

      cdp(
        state,
        "Emulation.setDeviceMetricsOverride",
        %{width: 1280, height: 720, deviceScaleFactor: 1, mobile: false},
        session
      )

      %{state | tabs: Map.put(state.tabs, tab, session)}
    end
  end

  defp world(state, session) do
    frame = cdp(state, "Page.getFrameTree", %{}, session)["frameTree"]["frame"]["id"]

    cdp(state, "Page.createIsolatedWorld", %{frameId: frame, worldName: "salix-browser"}, session)[
      "executionContextId"
    ]
  end

  defp evaluate(state, session, expression, extra \\ %{}) do
    params =
      Map.merge(
        %{
          expression: expression,
          contextId: world(state, session),
          returnByValue: true,
          awaitPromise: true
        },
        extra
      )

    value(cdp(state, "Runtime.evaluate", params, session), params[:returnByValue])
  end

  defp call_object(state, session, object, function, extra \\ %{}) do
    params =
      Map.merge(
        %{
          objectId: object,
          functionDeclaration: function,
          returnByValue: true,
          awaitPromise: true
        },
        extra
      )

    value(cdp(state, "Runtime.callFunctionOn", params, session), params[:returnByValue])
  end

  defp value(%{"exceptionDetails" => _}, _), do: fail("browser_operation_failed")
  defp value(%{"result" => result}, true), do: result["value"]
  defp value(%{"result" => result}, false), do: result["objectId"]

  defp deadline(ms), do: SystemsClock.monotonic_time(:millisecond) + ms

  defp remaining(deadline, cap),
    do: max(1, min(cap, deadline - SystemsClock.monotonic_time(:millisecond)))

  defp wait_until(timeout, fun) do
    poll(SystemsClock.monotonic_time(:millisecond) + timeout, fun) ||
      fail("browser_operation_failed")
  end

  # Polls until `fun` returns a truthy value or the deadline passes (then nil).
  defp poll(deadline, fun) do
    if value = fun.() do
      value
    else
      if SystemsClock.monotonic_time(:millisecond) >= deadline do
        nil
      else
        SystemsClock.sleep(100)
        poll(deadline, fun)
      end
    end
  end

  defp fail(reason), do: throw({:browser_error, reason})
  defp fail(reason, details) when details == %{}, do: throw({:browser_error, reason})
  defp fail(reason, details), do: throw({:browser_error, reason, details})
end
