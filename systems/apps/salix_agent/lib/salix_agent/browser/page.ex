defmodule SalixAgent.Browser.Page do
  @moduledoc """
  The page-side helper script and the expressions that call it.

  `priv/browser/page.js` runs in the tab's isolated world, so website scripts
  cannot see it. It keeps the ref table (`e12` -> element) of the current
  document, builds text snapshots, resolves targets and prepares form fields.
  """

  @script_path Path.expand("../../../priv/browser/page.js", __DIR__)
  @external_resource @script_path
  @script File.read!(@script_path)

  @doc "The expression that installs the helpers and then evaluates `call`."
  def expression(call), do: @script <> "\n" <> call

  def snapshot(opts), do: expression("__salix.snapshot(#{Jason.encode!(opts)})")

  def resolve(target, opts),
    do: expression("__salix.resolve(#{Jason.encode!(target)}, #{Jason.encode!(opts)})")

  def element(ref), do: expression("__salix.element(#{Jason.encode!(ref)})")

  def check(condition), do: expression("__salix.check(#{Jason.encode!(condition)})")

  def scroll_by(x, y),
    do: expression("__salix.scrollBy(#{Jason.encode!(x)}, #{Jason.encode!(y)})")

  @doc "A function declaration for `Runtime.callFunctionOn` on an element."
  def method(name, args \\ []) do
    arguments = Enum.map_join(["this" | Enum.map(args, &Jason.encode!/1)], ", ", & &1)
    "function() { return __salix.#{name}(#{arguments}); }"
  end
end
