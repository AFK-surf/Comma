defmodule SalixIFC.PurityBoundaryTest do
  @moduledoc """
  The facade may call pure data helpers and the single Lean transport.
  Domain code cannot read clocks, processes, files, application config, or ETS.
  The static Lean kernel is its only runtime dependency.
  """

  use ExUnit.Case, async: true

  test "the only runtime dependency is the static Lean kernel" do
    deps = Mix.Project.config()[:deps]

    for dep <- deps do
      {name, _version, opts} =
        case dep do
          {name, version, opts} -> {name, version, opts}
          {name, opts} when is_list(opts) -> {name, nil, opts}
        end

      assert name == :salix_verified_kernel or
               Enum.sort(Keyword.get(opts, :only, [])) == [:dev, :test],
             "#{name} is not part of the pure IFC boundary"
    end
  end
end
