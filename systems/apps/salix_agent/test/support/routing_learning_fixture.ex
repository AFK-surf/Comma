defmodule SalixAgent.RoutingLearningFixture do
  @moduledoc false

  def resources do
    %{
      "seconds" => 10,
      "input_tokens" => 1000,
      "output_tokens" => 100,
      "cache_read_input_tokens" => 200,
      "cache_write_input_tokens" => 100
    }
  end

  def observation(arm, outcome \\ "completed"),
    do: %{"arm" => arm, "outcome" => outcome, "resources" => resources(), "quality" => nil}
end
