defmodule SalixAgent.IFC.FileLabels do
  @moduledoc """
  The audience a workspace read returned
  (`docs/verification.md` §3.3, §8).

  The counterpart of `SalixIM.IFC.ReadLabels`, for the agent's own files
  instead of a provider's conversations. A read is never filtered — the model
  sees every file it is allowed to see (§7) — so what makes a file usable is
  that the result says where its content came from.

  The answer is already on the file: every visible write records the join of
  what the effect that caused it drew on
  (`SalixAgent.StorageAuthorization.prepare_write/4`). This reads it back in
  the three shapes a result comes in:

    * **one file** — `fs.read_file`, `fs.stat_file`, `memory.get`.
    * **many files, indivisibly** — a listing, a grep. The label is the join,
      so the answer is as restrictive as its most private input. An absence of
      matches in a private file is still something learned from it, so a grep
      joins every file it *scanned*, not only the ones that matched.
    * **many files, per hit** — `memory.search`, whose matches each name their
      own file. Citing one hit by its ref is then exactly as restrictive as
      that file, which is what keeps a search over mixed audiences usable at
      all: without it one scoped note would drag every search down with it.

  A file nobody labelled — written before the check was on, or while audit
  mode was letting a would-be denial through — contributes the fail-closed
  label rather than being skipped: an unknown audience must never quietly make
  an aggregate looser.

  Silent for a Group that is not labelling. Stamping there would put the
  fail-closed label on results that predate the decision to have one, and
  every file the Group wrote while it was `off` would flow nowhere the day it
  turns the check on.
  """

  alias SalixAgent.FileBackend
  alias SalixIFC.{Codec, Label}

  @doc "Attaches the audience of one file to a tool result."
  @spec one(term(), String.t(), map()) :: term()
  def one(result, path, ctx), do: join(result, [path], ctx)

  @doc "Attaches the join of several files' audiences to a tool result."
  @spec join(term(), [String.t()], map()) :: term()
  def join(result, paths, ctx) when is_list(paths) do
    if labelling?(ctx) do
      attach(result, %{"label" => joined(paths, ctx)})
    else
      result
    end
  end

  def join(result, _paths, _ctx), do: result

  @doc """
  Attaches a per-hit audience to a tool result.

  `paths` is one path per hit, in the order the hits are rendered, so a hit's
  index here is the index the model can cite.
  """
  @spec per_hit(term(), [String.t()], map()) :: term()
  def per_hit(result, paths, ctx) when is_list(paths) do
    if labelling?(ctx) do
      labels = Map.new(Enum.uniq(paths), &{&1, encoded(&1, ctx)})

      items =
        paths
        |> Enum.with_index()
        |> Enum.map(fn {path, index} ->
          %{"index" => index, "label" => Map.fetch!(labels, path)}
        end)

      attach(result, %{"label" => joined(paths, ctx), "items" => items})
    else
      result
    end
  end

  def per_hit(result, _paths, _ctx), do: result

  @doc "The audience of one file, as encoded atoms, fail-closed when unknown."
  @spec encoded(String.t(), map()) :: [String.t()]
  def encoded(path, ctx), do: path |> label_of(ctx) |> Codec.encode_label()

  @doc """
  The join of two encoded labels.

  Used where a write keeps content it did not author: the file ends up
  carrying both what the write drew on and what it retained
  (`SalixAgent.StorageAuthorization.prepare_write/4`). An atom set that cannot
  be decoded contributes the fail-closed label rather than nothing, so a
  corrupt stored label can only make a file more restrictive.
  """
  @spec join_encoded([String.t()], [String.t()]) :: [String.t()]
  def join_encoded(left, right) when is_list(left) and is_list(right) do
    [left, right]
    |> Enum.map(&Codec.decode_label(&1, private()))
    |> Label.join_all()
    |> Codec.encode_label()
  end

  @doc """
  The join of an encoded label with the fail-closed one.

  For a write that keeps content whose audience nobody recorded. `join_encoded/2`
  cannot express this: the unknown side has no atoms to pass, and an empty list
  decodes to ⊥, which joins to nothing. The answer has to be the same one a
  read of that content gives — agent-private — or a write and a read of the
  same file would disagree about who may see it.
  """
  @spec join_private([String.t()]) :: [String.t()]
  def join_private(label) when is_list(label) do
    label
    |> Codec.decode_label(private())
    |> Label.join(private())
    |> Codec.encode_label()
  end

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  # `ctx.ifc` is the wire context the dispatcher stages for a labelled session;
  # its absence is exactly the condition `SalixAgent.IFC.Check.stamp_results/3`
  # uses to leave a transcript alone.
  defp labelling?(ctx) when is_map(ctx), do: is_map(Map.get(ctx, :ifc))
  defp labelling?(_ctx), do: false

  defp joined(paths, ctx) do
    paths
    |> Enum.uniq()
    |> Enum.map(&label_of(&1, ctx))
    |> Label.join_all()
    |> Codec.encode_label()
  end

  defp label_of(path, ctx) do
    case FileBackend.label(ctx, path) do
      label when is_list(label) -> Codec.decode_label(label, private())
      _unlabelled -> private()
    end
  end

  defp private, do: Label.new([:agent_private])

  defp attach({content, events}, ifc) when is_binary(content) and is_list(events),
    do: {:tool_ifc, content, events, ifc}

  defp attach(content, ifc) when is_binary(content), do: {:tool_ifc, content, [], ifc}

  # An image read, a failure, or anything else that is not plain content keeps
  # its own shape; the dispatcher's fail-closed default covers it.
  defp attach(result, _ifc), do: result
end
