defmodule BridgeForTeamsWeb.Dashboard.SchedulePresentationTest do
  use ExUnit.Case, async: true

  alias BridgeForTeamsWeb.Dashboard.SchedulePresentation

  test "describes common fixed-time Cron expressions and duration schedules" do
    assert SchedulePresentation.recurrence(%{
             "cron" => "0 17 * * *",
             "timezone" => "Asia/Shanghai"
           }) ==
             "Every day at 5 PM (Asia/Shanghai)"

    assert SchedulePresentation.recurrence(%{
             "cron" => "30 18 * * 3",
             "timezone" => "Asia/Shanghai"
           }) == "Every Wednesday at 6:30 PM (Asia/Shanghai)"

    assert SchedulePresentation.recurrence(%{"interval_minutes" => 5}) == "Every 5 minutes"
    assert SchedulePresentation.recurrence(%{"interval_minutes" => 60}) == "Every hour"
    assert SchedulePresentation.recurrence(%{"interval_minutes" => 10_080}) == "Every 7 days"
  end

  test "uses Chinese time language for fixed-time Cron expressions" do
    previous_locale = Gettext.get_locale(BridgeForTeamsWeb.Gettext)
    Gettext.put_locale(BridgeForTeamsWeb.Gettext, "zh_Hans")

    on_exit(fn -> Gettext.put_locale(BridgeForTeamsWeb.Gettext, previous_locale) end)

    assert SchedulePresentation.recurrence(%{
             "cron" => "0 17 * * *",
             "timezone" => "Asia/Shanghai"
           }) ==
             "每天下午 5 点（Asia/Shanghai）"

    assert SchedulePresentation.recurrence(%{
             "cron" => "30 18 * * 3",
             "timezone" => "Asia/Shanghai"
           }) == "每周三下午 6 点 30 分（Asia/Shanghai）"
  end

  test "converts a duration form to the canonical minute value" do
    assert {:ok, %{"interval_minutes" => 10_080}} =
             SchedulePresentation.to_recurrence(%{
               "mode" => "interval",
               "interval_value" => "7",
               "interval_unit" => "days"
             })
  end
end
