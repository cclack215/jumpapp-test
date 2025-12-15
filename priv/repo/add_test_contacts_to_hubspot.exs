# Script to add test contacts to HubSpot
# Run with: mix run priv/repo/add_test_contacts_to_hubspot.exs

import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User

require Logger

# Test contacts to add
test_contacts = [
  %{
    firstname: "test",
    lastname: "1",
    email: "test1@gmail.com",
    phone: "555-000-0001"
  },
  %{
    firstname: "John",
    lastname: "Smith",
    email: "john.smith@acmecorp.com",
    phone: "555-111-2222",
    company: "Acme Corporation",
    jobtitle: "VP of Sales"
  },
  %{
    firstname: "Sarah",
    lastname: "Johnson",
    email: "sarah.johnson@acmecorp.com",
    phone: "555-123-4567",
    company: "Acme Corporation"
  },
  %{
    firstname: "Michael",
    lastname: "Chen",
    email: "michael.chen@digitalinnovations.com",
    phone: "555-333-4444",
    company: "Digital Innovations LLC",
    jobtitle: "Head of Business Development"
  },
  %{
    firstname: "Emily",
    lastname: "Davis",
    email: "emily.davis@globalent.com",
    phone: "555-456-7890",
    company: "Global Enterprises",
    jobtitle: "Chief Revenue Officer"
  }
]

# Get the first user
user = Repo.one(from u in User, limit: 1)

if user do
  credentials = Accounts.list_user_credentials(user, provider: "hubspot")
  
  if not Enum.empty?(credentials) do
    credential = List.first(credentials)
    token = credential.token
    
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("Adding Test Contacts to HubSpot")
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("")
    
    base_url = "https://api.hubapi.com"
    client = Tesla.client([
      {Tesla.Middleware.BaseUrl, base_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Bearer #{token}"},
         {"Content-Type", "application/json"}
       ]}
    ])
    
    Enum.each(test_contacts, fn contact_data ->
      name = "#{contact_data.firstname} #{contact_data.lastname}"
      IO.puts("Adding: #{name} (#{contact_data.email})")
      
      # Prepare properties for HubSpot API
      properties = %{
        "firstname" => contact_data.firstname,
        "lastname" => contact_data.lastname,
        "email" => contact_data.email
      }
      
      # Add optional fields if present
      if Map.has_key?(contact_data, :phone) && contact_data.phone do
        properties = Map.put(properties, "phone", contact_data.phone)
      end
      
      if Map.has_key?(contact_data, :company) && contact_data.company do
        properties = Map.put(properties, "company", contact_data.company)
      end
      
      if Map.has_key?(contact_data, :jobtitle) && contact_data.jobtitle do
        properties = Map.put(properties, "jobtitle", contact_data.jobtitle)
      end
      
      body = %{properties: properties}
      
      case Tesla.post(client, "/crm/v3/objects/contacts", body) do
        {:ok, %Tesla.Env{status: 201, body: response_body}} ->
          contact_id = Map.get(response_body, :id)
          IO.puts("  ✅ Created successfully (ID: #{contact_id})")
          
        {:ok, %Tesla.Env{status: 409, body: response_body}} ->
          # Contact already exists (409 Conflict)
          message = Map.get(response_body, :message, "Contact already exists")
          IO.puts("  ⚠️  Already exists: #{message}")
          
        {:ok, %Tesla.Env{status: status, body: error_body}} ->
          IO.puts("  ❌ Error (Status #{status}):")
          IO.puts("     #{inspect(error_body, limit: :infinity, pretty: true)}")
          
        {:error, reason} ->
          IO.puts("  ❌ HTTP Error:")
          IO.puts("     #{inspect(reason, limit: :infinity)}")
      end
      
      IO.puts("")
    end)
    
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("Done! You can now search for these contacts in the app.")
    IO.puts("=" <> String.duplicate("=", 70))
  else
    IO.puts("❌ No HubSpot credentials found.")
    IO.puts("   Please connect your HubSpot account in Settings first.")
  end
else
  IO.puts("❌ No users found.")
end

