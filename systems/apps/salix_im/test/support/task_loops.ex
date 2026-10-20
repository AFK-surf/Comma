defmodule SalixIM.TestSupport.TaskLoops do
  @moduledoc """
  The Task Loops port in place of the Loop runtime: each request, end and
  delete is sent to the test as `{:task_loops, operation, conversation_id}`
  (an end also carries its reason), and a request writes the Task's view
  `pending`. The views are the ones requests wrote or the test set: by Task
  id, or `{:all, view}` for every Task.
  """

  @behaviour SalixIM.Ports.TaskLoops

  @key {__MODULE__, :state}

  @doc "Bind this fake for the calling test, with `views` by Task id."
  def install(views \\ %{}) do
    previous = SystemsRuntime.get_env(:salix_im, :task_loops_mod)
    SystemsRuntime.PersistentTerm.put(@key, %{test: SystemsRuntime.Proc.self(), views: views})
    SystemsRuntime.put_env(:salix_im, :task_loops_mod, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase(@key)

      if previous,
        do: SystemsRuntime.put_env(:salix_im, :task_loops_mod, previous),
        else: SystemsRuntime.delete_env(:salix_im, :task_loops_mod)
    end)
  end

  def put_views(views),
    do: SystemsRuntime.PersistentTerm.put(@key, %{state() | views: views})

  @impl true
  def request_task_loop(%{"task_conversation_id" => id, "trigger" => trigger} = attrs) do
    tell({:task_loops, :request, id})

    view =
      attrs
      |> Map.take(~w(max_runs ends_at stop_condition))
      |> Map.merge(%{
        "loop_id" => "lop_" <> id,
        "status" => "pending",
        "trigger" => trigger,
        "run_count" => 0
      })

    case state().views do
      {:all, _view} -> :ok
      views -> put_views(Map.put(views, id, view))
    end

    {:ok, view}
  end

  @impl true
  def task_loops(_group_id, ids) do
    case state().views do
      {:all, view} -> {:ok, Map.new(ids, &{&1, view})}
      by_task -> {:ok, Map.take(by_task, ids)}
    end
  end

  @impl true
  def end_task_loops(_group_id, id, reason) do
    tell({:task_loops, :end, id, reason})
    :ok
  end

  @impl true
  def delete_task_loops(_group_id, id) do
    tell({:task_loops, :delete, id})
    {:ok, 1}
  end

  # An owner that outlives its test finds no test to tell.
  defp tell(message) do
    if test = state().test, do: SystemsRuntime.Proc.send(test, message)
  end

  defp state, do: SystemsRuntime.PersistentTerm.get(@key, %{test: nil, views: %{}})
end
