defmodule SocialScribe.AIContentGeneratorApiTest do
  use ExUnit.Case, async: true

  import Mox

  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.AIContentGeneratorMock

  # Ensure Mox expectations are verified per test
  setup :set_mox_from_context
  setup :verify_on_exit!

  test "generate_hubspot_updates delegates to configured implementation" do
    meeting = %{"id" => 123}
    hubspot_context = %{
      "contact" => %{
        "id" => "456",
        "properties" => %{"email" => "old@example.com"},
        "properties_with_history" => %{}
      },
      "associations" => %{},
      "associated_companies" => [],
      "primary_company" => nil,
      "associated_deals" => []
    }

    expected_updates = [
      %{
        "property" => "email",
        "current_value" => "old@example.com",
        "suggested_value" => "new@example.com",
        "reason" => "Email updated in meeting",
        "timestamp" => "01:23"
      }
    ]

    expect(AIContentGeneratorMock, :generate_hubspot_updates, fn ^meeting, ^hubspot_context ->
      {:ok, expected_updates}
    end)

    assert {:ok, ^expected_updates} =
             AIContentGeneratorApi.generate_hubspot_updates(meeting, hubspot_context)
  end
end
