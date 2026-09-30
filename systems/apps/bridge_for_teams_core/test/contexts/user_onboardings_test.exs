defmodule BridgeForTeams.UserOnboardingsTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Accounts, UserOnboardings}

  describe "ensure_onboarding/1" do
    test "creates the initial in_progress record once and returns it thereafter" do
      user = user_fixture()

      assert {:ok, onboarding} = UserOnboardings.ensure_onboarding(user.id)
      assert onboarding.status == "in_progress"
      assert onboarding.current_step == "capabilities"

      assert {:ok, same} = UserOnboardings.ensure_onboarding(user.id)
      assert same.id == onboarding.id
    end
  end

  describe "onboarded?/1" do
    test "is false without a record, false in progress, true when completed or skipped" do
      user = user_fixture()
      refute UserOnboardings.onboarded?(user.id)

      {:ok, onboarding} = UserOnboardings.ensure_onboarding(user.id)
      refute UserOnboardings.onboarded?(user.id)

      {:ok, _completed} = UserOnboardings.complete(onboarding)
      assert UserOnboardings.onboarded?(user.id)

      other = user_fixture()
      {:ok, other_onboarding} = UserOnboardings.ensure_onboarding(other.id)
      {:ok, _skipped} = UserOnboardings.skip(other_onboarding)
      assert UserOnboardings.onboarded?(other.id)
    end
  end

  describe "step + payload updates" do
    test "advance, put_capabilities, and put_profile persist" do
      user = user_fixture()
      {:ok, onboarding} = UserOnboardings.ensure_onboarding(user.id)

      assert {:ok, onboarding} = UserOnboardings.advance(onboarding, "integrations")
      assert onboarding.current_step == "integrations"

      assert {:error, _changeset} = UserOnboardings.advance(onboarding, "not-a-step")

      assert {:ok, onboarding} =
               UserOnboardings.put_capabilities(onboarding, %{"inbox.draft_replies" => true})

      assert onboarding.capabilities == %{"inbox.draft_replies" => true}

      assert {:ok, onboarding} =
               UserOnboardings.put_profile(onboarding, %{"identity" => %{"name" => "A"}})

      assert onboarding.profile["identity"]["name"] == "A"

      assert {:ok, completed} = UserOnboardings.complete(onboarding)
      assert completed.status == "completed"
      assert completed.completed_at
    end
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "onboarding-#{System.unique_integer([:positive])}@example.com",
        "name" => "Onboarding User"
      })

    user
  end
end
