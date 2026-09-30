defmodule SalixMeet.Test.LazyPortAdapter do
  @moduledoc false

  @behaviour SalixMeet.Ports.OwnerAttribution
  @behaviour SalixMeet.Ports.Summary

  @impl true
  def prepare_context(state) do
    send(state["test_pid"], :lazy_prepare_context)
    {:ok, %{"source" => "lazy", "transcript" => "canonical"}}
  end

  @impl true
  def summarize(state) do
    send(state["test_pid"], :legacy_summarize)
    {:ok, %{"title" => "legacy"}}
  end

  @impl true
  def summarize(state, context) do
    send(state["test_pid"], {:lazy_summarize, context})
    {:ok, %{"title" => "canonical"}}
  end

  @impl true
  def attribute(state, summary) do
    send(state["test_pid"], :legacy_attribute)
    {:ok, summary}
  end

  @impl true
  def attribute(state, summary, context) do
    send(state["test_pid"], {:lazy_attribute, context})
    {:ok, summary}
  end
end
