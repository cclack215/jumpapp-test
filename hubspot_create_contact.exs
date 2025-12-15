#!/usr/bin/env elixir

# Run from the project root with:
#   HUBSPOT_ACCESS_TOKEN="your-token" mix run hubspot_create_contact.exs

access_token = System.get_env("HUBSPOT_ACCESS_TOKEN") || raise "Set HUBSPOT_ACCESS_TOKEN env var"

# Basic example contact data – edit these before running if you like
email = System.get_env("HUBSPOT_CONTACT_EMAIL") || "test+socialscribe@example.com"
firstname = System.get_env("HUBSPOT_CONTACT_FIRSTNAME") || "Test"
lastname = System.get_env("HUBSPOT_CONTACT_LASTNAME") || "User"
phone = System.get_env("HUBSPOT_CONTACT_PHONE") || "8885550000"
company = System.get_env("HUBSPOT_CONTACT_COMPANY") || "Social Scribe Test"

client =
  Tesla.client([
    {Tesla.Middleware.BaseUrl, "https://api.hubapi.com"},
    Tesla.Middleware.JSON,
    {Tesla.Middleware.Headers,
     [
       {"Authorization", "Bearer #{access_token}"},
       {"Content-Type", "application/json"}
     ]}
  ])

body = %{
  properties: %{
    email: email,
    firstname: firstname,
    lastname: lastname,
    phone: phone,
    company: company
  }
}

IO.puts("Creating HubSpot contact with email=#{email} ...")

case Tesla.post(client, "/crm/v3/objects/contacts", body) do
  {:ok, %Tesla.Env{status: status, body: resp_body}} when status in 200..299 ->
    IO.puts("Created contact successfully. Status: #{status}")
    IO.inspect(resp_body, label: "Response")

  {:ok, %Tesla.Env{status: status, body: error_body}} ->
    IO.puts("HubSpot API returned error status: #{status}")
    IO.inspect(error_body, label: "Error body")

  {:error, reason} ->
    IO.puts("HTTP error calling HubSpot:")
    IO.inspect(reason)
end
