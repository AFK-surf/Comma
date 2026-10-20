defmodule SystemsClock.Assertions do
  @moduledoc """
  ExUnit assertions that wait for messages by settling a manual clock instead
  of waiting real time. Use them with `SystemsClock.manual/1`; the settle
  options given there apply.
  """

  @doc """
  Settles until a message matching `pattern` is in the mailbox, then receives
  it.
  """
  defmacro settle_receive(pattern) do
    probe = SystemsClock.Assertions.blank_vars(pattern)
    message = Macro.var(:message, __MODULE__)

    # A clause that takes the matching message whole, guard and all.
    head =
      case probe do
        {:when, meta, [shape, guard]} -> {:when, meta, [{:=, [], [shape, message]}, guard]}
        shape -> {:=, [], [shape, message]}
      end

    binding =
      case pattern do
        {:when, _meta, [shape, _guard]} -> shape
        shape -> shape
      end

    take_now = [{:->, [], [[head], {:received, message}]}]

    quote do
      SystemsClock.settle(
        eager: true,
        until: fn ->
          {:messages, messages} = Process.info(self(), :messages)
          Enum.any?(messages, &match?(unquote(probe), &1))
        end
      )

      unquote(message) =
        receive do
          unquote(take_now)
        after
          0 ->
            ExUnit.Assertions.flunk(
              "no message matching #{unquote(Macro.to_string(pattern))} once settled"
            )
        end
        |> elem(1)

      unquote(binding) = unquote(message)
    end
  end

  @doc """
  Runs `ms` clock milliseconds (the window `refute_receive` waited), every
  timer in it in order, and refutes a matching message.
  """
  defmacro settle_refute_receive(pattern, ms \\ 100) do
    quote do
      SystemsClock.run_for(unquote(ms))
      ExUnit.Assertions.refute_received(unquote(pattern))
    end
  end

  @doc false
  # The probe only tests the shape; `assert_received` binds the variables.
  def blank_vars({:^, _, _} = pinned), do: pinned
  def blank_vars({:@, _, _} = attribute), do: attribute

  # A binary segment's type and size stay as written: `size(n)` reads a
  # variable the pattern binds earlier or a pinned one.
  def blank_vars({:"::", meta, [segment, spec]}), do: {:"::", meta, [blank_vars(segment), spec]}
  def blank_vars({:when, _, _} = guarded), do: guarded

  def blank_vars({name, meta, context}) when is_atom(name) and is_atom(context),
    do: if(name == :_, do: {name, meta, context}, else: {:_, meta, context})

  def blank_vars({left, meta, args}) when is_list(args),
    do: {blank_vars(left), meta, Enum.map(args, &blank_vars/1)}

  def blank_vars({left, right}), do: {blank_vars(left), blank_vars(right)}
  def blank_vars(list) when is_list(list), do: Enum.map(list, &blank_vars/1)
  def blank_vars(other), do: other
end
