defmodule SalixIM.ConversationLimits do
  @moduledoc false

  @participant_limit 200
  @participant_page_limit 100
  @delivery_filter_limit 100
  @inline_task_ref_limit 16

  def participant_limit, do: @participant_limit
  def participant_page_limit, do: @participant_page_limit
  def delivery_filter_limit, do: @delivery_filter_limit
  def inline_task_ref_limit, do: @inline_task_ref_limit
end
