# Script to verify contacts exist and test different search methods
# Run with: mix run priv/repo/verify_contacts_exist.exs

import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User

require Logger

# Get the first user
user = Repo.one(from u in User, limit: 1)

if user do
  credentials = Accounts.list_user_credentials(user, provider: "hubspot")
  
  if not Enum.empty?(credentials) do
    credential = List.first(credentials)
    token = credential.token
    
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
    
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("Verifying Contacts and Testing Search")
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("")
    
    # Method 1: Try to get contact by email directly
    IO.puts("Method 1: Getting contact by email 'emily.davis@globalent.com'...")
    case Tesla.get(client, "/crm/v3/objects/contacts/emily.davis@globalent.com?idProperty=email&properties=firstname,lastname,email") do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        IO.puts("✅ Contact found by email!")
        IO.puts("   #{inspect(response_body, limit: :infinity, pretty: true)}")
      {:ok, %Tesla.Env{status: 404}} ->
        IO.puts("❌ Contact not found (404)")
      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        IO.puts("❌ Error (Status #{status}): #{inspect(error_body)}")
      {:error, reason} ->
        IO.puts("❌ HTTP Error: #{inspect(reason)}")
    end
    
    IO.puts("")
    
    # Method 2: Try search with different operators
    IO.puts("Method 2: Testing search with 'CONTAINS' operator...")
    body = %{
      filterGroups: [
        %{
          filters: [
            %{
              propertyName: "email",
              operator: "CONTAINS",
              value: "emily"
            }
          ]
        }
      ],
      properties: ["firstname", "lastname", "email"],
      limit: 10
    }
    
    case Tesla.post(client, "/crm/v3/objects/contacts/search", body) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        results = Map.get(response_body, :results, [])
        IO.puts("✅ Found #{length(results)} contact(s) with CONTAINS operator")
        Enum.each(results, fn contact ->
          props = Map.get(contact, :properties, %{})
          IO.puts("   • #{Map.get(props, :firstname)} #{Map.get(props, :lastname)} (#{Map.get(props, :email)})")
        end)
      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        IO.puts("❌ Error (Status #{status}): #{inspect(error_body, limit: :infinity)}")
      {:error, reason} ->
        IO.puts("❌ HTTP Error: #{inspect(reason)}")
    end
    
    IO.puts("")
    
    # Method 3: Try search with EQ operator (exact match on firstname)
    IO.puts("Method 3: Testing search with 'EQ' operator on firstname...")
    body = %{
      filterGroups: [
        %{
          filters: [
            %{
              propertyName: "firstname",
              operator: "EQ",
              value: "Emily"
            }
          ]
        }
      ],
      properties: ["firstname", "lastname", "email"],
      limit: 10
    }
    
    case Tesla.post(client, "/crm/v3/objects/contacts/search", body) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        results = Map.get(response_body, :results, [])
        IO.puts("✅ Found #{length(results)} contact(s) with EQ operator")
        Enum.each(results, fn contact ->
          props = Map.get(contact, :properties, %{})
          IO.puts("   • #{Map.get(props, :firstname)} #{Map.get(props, :lastname)} (#{Map.get(props, :email)})")
        end)
      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        IO.puts("❌ Error (Status #{status}): #{inspect(error_body, limit: :infinity)}")
      {:error, reason} ->
        IO.puts("❌ HTTP Error: #{inspect(reason)}")
    end
    
    IO.puts("")
    IO.puts("=" <> String.duplicate("=", 70))
  else
    IO.puts("❌ No HubSpot credentials found.")
  end
else
  IO.puts("❌ No users found.")
end

