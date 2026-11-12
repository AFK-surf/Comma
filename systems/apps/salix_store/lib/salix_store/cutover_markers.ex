defmodule SalixStore.CutoverMarkers do
  @moduledoc """
  Pages of a pass that runs once after a rollout, recorded by a marker in
  `salix_cutover_markers`: a run cut off resumes after its last finished
  page, and once the pass is done, running it again does nothing.
  """

  alias SalixStore.Repo

  @doc """
  One page of the pass under marker `name`. `step` takes the position the
  marker recorded (nil: the start) and answers `{:ok, %{processed: n, next:
  position}}`, where position is any JSON value and nil means the pass is
  done, with `failed: n` for records it left as they were (the marker adds
  them up), or `{:error, reason}`, which leaves the marker as it was so the
  same page runs again. The marker then takes the next position unless another run
  moved it meanwhile (the pages give the same result when they run again);
  then the answer is not done, and the next call reads the marker again. Once
  the marker is `complete`, `step` is not called. Answers
  `{:ok, %{processed: n, done: boolean}}`.

  No transaction is held while `step` runs: its pages write through their own.
  """
  def page(name, step) when is_binary(name) and is_function(step, 1) do
    Repo.query!(
      "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, now(), $2) ON CONFLICT (name) DO NOTHING",
      [name, %{"phase" => "running", "position" => nil, "processed" => 0}]
    )

    %{rows: [[evidence]]} =
      Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name = $1", [name])

    if evidence["phase"] == "complete" do
      {:ok, %{processed: 0, done: true}}
    else
      with {:ok, %{processed: processed, next: next} = result} <- step.(evidence["position"]) do
        %{num_rows: recorded} =
          Repo.query!(
            "UPDATE salix_cutover_markers SET evidence = $2, completed_at = now() WHERE name = $1 AND evidence = $3",
            [
              name,
              %{
                "phase" => if(is_nil(next), do: "complete", else: "running"),
                "position" => next,
                "processed" => (evidence["processed"] || 0) + processed,
                "failed" => (evidence["failed"] || 0) + Map.get(result, :failed, 0)
              },
              evidence
            ]
          )

        {:ok, %{processed: processed, done: recorded == 1 and is_nil(next)}}
      end
    end
  end
end
