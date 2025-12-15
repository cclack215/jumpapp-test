# Script to list ALL contacts from HubSpot
# Run with: mix run priv/repo/list_all_hubspot_contacts.exs

import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User

require Logger

# Helper function to format contact
format_contact = fn contact ->
  name = cond do
    contact["firstname"] && contact["lastname"] -> "#{contact["firstname"]} #{contact["lastname"]}"
    contact["firstname"] -> contact["firstname"]
    contact["email"] -> contact["email"]
    true -> "Contact ##{contact["id"]}"
  end
  
  email_str = if contact["email"], do: " (#{contact["email"]})", else: ""
  company_str = if contact["company"], do: " - #{contact["company"]}", else: ""
  "#{name}#{email_str}#{company_str} [ID: #{contact["id"]}]"
end

# Get the first user
user = Repo.one(from u in User, limit: 1)

if user do
  credentials = Accounts.list_user_credentials(user, provider: "hubspot")
  
  if not Enum.empty?(credentials) do
    credential = List.first(credentials)
    token = credential.token
    
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("Listing ALL Contacts from HubSpot")
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("")
    
    # Use the GET endpoint to list all contacts
    base_url = "https://api.hubapi.com"
    properties = "firstname,lastname,email,phone,company,jobtitle"
    url = "#{base_url}/crm/v3/objects/contacts?properties=#{properties}&limit=100"
    
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]
    
    IO.puts("Making GET request to: #{url}")
    IO.puts("")
    
    case Tesla.get(Tesla.client([{Tesla.Middleware.BaseUrl, base_url}, Tesla.Middleware.JSON]), 
                   "/crm/v3/objects/contacts?properties=#{properties}&limit=100",
                   headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        results = Map.get(response_body, :results, [])
        total = Map.get(response_body, :total, length(results))
        paging = Map.get(response_body, :paging, %{})
        
        IO.puts("✅ Successfully retrieved contacts")
        IO.puts("   Total contacts: #{total}")
        IO.puts("   Retrieved: #{length(results)}")
        IO.puts("")
        
        if Enum.empty?(results) do
          IO.puts("⚠️  No contacts found in your HubSpot account.")
          IO.puts("   This could mean:")
          IO.puts("   1. Your HubSpot account has no contacts")
          IO.puts("   2. The connected account is different from expected")
          IO.puts("")
        else
          IO.puts("Contacts List:")
          IO.puts("-" <> String.duplicate("-", 70))
          
          Enum.each(results, fn contact ->
            properties = Map.get(contact, :properties, %{})
            contact_map = %{
              "id" => Map.get(contact, :id),
              "firstname" => Map.get(properties, :firstname),
              "lastname" => Map.get(properties, :lastname),
              "email" => Map.get(properties, :email),
              "phone" => Map.get(properties, :phone),
              "company" => Map.get(properties, :company),
              "jobtitle" => Map.get(properties, :jobtitle)
            }
            
            IO.puts("   • #{format_contact.(contact_map)}")
          end)
          
          IO.puts("")
          IO.puts("-" <> String.duplicate("-", 70))
          
          # Check if there are more pages
          if Map.has_key?(paging, :next) do
            IO.puts("")
            IO.puts("⚠️  There are more contacts (pagination available)")
            IO.puts("   Showing first 100 contacts")
          end
        end
        
      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        IO.puts("❌ API Error (Status #{status}):")
        IO.puts("   #{inspect(error_body, limit: :infinity, pretty: true)}")
        
      {:error, reason} ->
        IO.puts("❌ HTTP Error:")
        IO.puts("   #{inspect(reason, limit: :infinity)}")
    end
    
    IO.puts("")
    IO.puts("=" <> String.duplicate("=", 70))
  else
    IO.puts("❌ No HubSpot credentials found.")
    IO.puts("   Please connect your HubSpot account in Settings first.")
  end
else
  IO.puts("❌ No users found.")
end

