defmodule SalixAgent.Migrations.GroupCloudVMSwitch do
  @moduledoc """
  Move Cloud VM access from Agents to their Group: the Group's switch
  (`cloud_vm_enabled` on the Group record) alone decides it
  (`SalixAgent.CloudVM.allowed?/1`).

  It runs twice in the release that moves the switch, and gives the same
  result whenever it runs again:

    * Before the rollout (`run/0`, release migration
      `20261019120001_group_cloud_vm_switch`): a Group gets its switch on when
      one of its live Agents has VM access (`vm.enabled`) or is a Worker bound
      to the Group's Cloud VM (`SalixAgent.StationBinding.cloud_vm?/1`), so
      every Agent that could use the Group's Cloud VM keeps it while new nodes
      replace old ones. A Comma Workspace's or BFT Project's Group counts only
      `vm.enabled`, the copy of the product's own switch its products wrote
      onto every Agent. Agent records keep their `vm`, which old nodes still
      read.
    * After the rollout (`page/2` with `after_rollout: true`, from the release's
      post-rollout job `Comma.Release.transfer_agent_configuration_page/1`):
      no server of the release before is left to write an Agent's `vm`. The
      pass turns on the switch of each Group no product owns from its Agents
      once more, then removes `vm` from every Agent record. A Comma Workspace's
      Group and a BFT Project's Group take their switch from the product
      (`Comma.Workspaces.converge_group_cloud_vm_page/1`,
      `BridgeForTeams.Projects.converge_group_cloud_vm_page/1`), which runs
      after this pass.

  The pages after the rollout run once: `after_rollout_page/1` records how far
  they got in the marker `group_cloud_vm_switch_v1` (`salix_cutover_markers`),
  so a run cut off resumes after its last finished page, and once they are
  done, running them again does nothing.

  Each page reads at most 100 Agent records. The pass never turns a switch off.
  Conditional writes skip an Agent record changed or deleted after the read. It
  asks no VM provider anything, so it runs the same in a release job as on a
  node.
  """

  alias SalixAgent.StationBinding
  alias SalixStore.{CasRecord, Keys, Repo, S3}

  @marker "group_cloud_vm_switch_v1"

  # Billing surfaces whose product decides its Groups' switch after the rollout.
  @product_surfaces ~w(comma bridge)

  @doc "The whole pass before the rollout."
  def run(opts \\ []), do: run(nil, opts, %{groups: 0, agents: 0})

  defp run(cursor, opts, counts) do
    with {:ok, page} <- page(cursor, opts) do
      counts = %{groups: counts.groups + page.groups, agents: counts.agents + page.agents}
      if page.next_cursor, do: run(page.next_cursor, opts, counts), else: {:ok, counts}
    end
  end

  @doc """
  One page of at most 100 Agent records, from `cursor` (nil: the first).
  Answers how many Groups it turned on and Agent records it changed, and the
  cursor of the next page (nil: done).
  """
  def page(cursor, opts \\ []) do
    after_rollout? = Keyword.get(opts, :after_rollout, false)

    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix(), max_keys: 100, continuation_token: cursor),
         {:ok, counts} <-
           Enum.reduce_while(objects, {:ok, %{groups: 0, agents: 0}}, fn object, {:ok, counts} ->
             case migrate_object(object.key, after_rollout?) do
               {:ok, counted} -> {:cont, {:ok, count(counts, counted)}}
               error -> {:halt, error}
             end
           end) do
      {:ok, Map.merge(counts, %{processed: length(objects), next_cursor: next})}
    end
  end

  @doc """
  One page of the passes after the rollout, under the marker
  `group_cloud_vm_switch_v1`. `step` takes the position the marker recorded
  (nil: the start) and answers `{:ok, %{processed: n, next: position}}`, where
  position is any JSON value and nil means the passes are done, or
  `{:error, reason}`, which leaves the marker as it was so the same page runs
  again. The marker then takes the next position unless another run moved it
  meanwhile (the pages give the same result when they run again); then the
  answer is not done, and the next call reads the marker again. Once the
  marker is `complete`, `step` is not called. Answers
  `{:ok, %{processed: n, done: boolean}}`.

  No transaction is held while `step` runs: its pages write through their own.
  """
  def after_rollout_page(step) when is_function(step, 1) do
    Repo.query!(
      "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, now(), $2) ON CONFLICT (name) DO NOTHING",
      [@marker, %{"phase" => "running", "position" => nil, "processed" => 0}]
    )

    %{rows: [[evidence]]} =
      Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name = $1", [@marker])

    if evidence["phase"] == "complete" do
      {:ok, %{processed: 0, done: true}}
    else
      with {:ok, %{processed: processed, next: next}} <- step.(evidence["position"]) do
        %{num_rows: recorded} =
          Repo.query!(
            "UPDATE salix_cutover_markers SET evidence = $2, completed_at = now() WHERE name = $1 AND evidence = $3",
            [
              @marker,
              %{
                "phase" => if(is_nil(next), do: "complete", else: "running"),
                "position" => next,
                "processed" => (evidence["processed"] || 0) + processed
              },
              evidence
            ]
          )

        {:ok, %{processed: processed, done: recorded == 1 and is_nil(next)}}
      end
    end
  end

  defp count(counts, counted),
    do: Enum.reduce(counted, counts, fn kind, counts -> Map.update!(counts, kind, &(&1 + 1)) end)

  defp migrate_object(key, after_rollout?) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, %{} = agent} <- Jason.decode(body),
         true <- Map.has_key?(agent, "vm") or StationBinding.cloud_vm?(agent),
         {:ok, group} <- enable_group(agent, after_rollout?),
         {:ok, agent_counted} <-
           if(after_rollout?, do: remove_vm(key, agent, etag), else: {:ok, []}) do
      {:ok, group ++ agent_counted}
    else
      false -> {:ok, []}
      {:ok, _not_an_agent} -> {:ok, []}
      {:error, :not_found} -> {:ok, []}
      error -> error
    end
  end

  defp enable_group(%{"group_id" => group_id} = agent, after_rollout?) when is_binary(group_id) do
    key = Keys.ctl_group(group_id)

    with true <- used_cloud_vm?(agent),
         {:ok, %{} = group} <- CasRecord.get(key),
         true <- group["cloud_vm_enabled"] != true,
         true <- not product_group?(group) or (not after_rollout? and vm_enabled?(agent)),
         {:ok, _group} <-
           CasRecord.update(key, &Map.put(&1, "cloud_vm_enabled", true), create: false) do
      {:ok, [:groups]}
    else
      false -> {:ok, []}
      {:error, :not_found} -> {:ok, []}
      error -> error
    end
  end

  defp enable_group(_agent, _after_rollout?), do: {:ok, []}

  defp product_group?(group), do: get_in(group, ["billing_owner", "surface"]) in @product_surfaces

  defp used_cloud_vm?(agent) do
    live? = not Map.has_key?(agent, "archived_at") and agent["permanent_archive"] != true
    live? and (vm_enabled?(agent) or StationBinding.cloud_vm?(agent))
  end

  defp vm_enabled?(agent), do: match?(%{"enabled" => true}, agent["vm"])

  defp remove_vm(key, agent, etag) do
    if Map.has_key?(agent, "vm") do
      case S3.put(key, Jason.encode!(Map.delete(agent, "vm")), if_match: etag) do
        {:ok, _} -> {:ok, [:agents]}
        {:error, :precondition_failed} -> {:ok, []}
        {:error, :not_found} -> {:ok, []}
        error -> error
      end
    else
      {:ok, []}
    end
  end
end
