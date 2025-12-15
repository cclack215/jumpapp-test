# Script to test listing all HubSpot contacts
# Run with: mix run priv/repo/test_hubspot_list_all.exs

import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User
alias SocialScribe.HubSpotApi
alias SocialScribe.HubSpotOAuth

require Logger

# Helper function to format contact
format_contact = fn contact ->
  name = cond do
    contact.firstname && contact.lastname -> "#{contact.firstname} #{contact.lastname}"
    contact.firstname -> contact.firstname
    contact.email -> contact.email
    true -> "Contact ##{contact.id}"
  end
  
  email_str = if contact.email, do: " (#{contact.email})", else: ""
  "#{name}#{email_str} [ID: #{contact.id}]"
end

# Get the first user
user = Repo.one(from u in User, limit: 1)

if user do
  credentials = Accounts.list_user_credentials(user, provider: "hubspot")
  
  if not Enum.empty?(credentials) do
    credential = List.first(credentials)
    token = credential.token
    
    # Try searching with empty string or very broad search
    IO.puts("Trying to list all contacts (searching with '@' to match any email)...")
    IO.puts("")
    
    # Try searching for '@' which should match any email
    case HubSpotApi.search_contacts(token, "@") do
      {:ok, contacts} ->
        IO.puts("✅ Found #{length(contacts)} contact(s) with '@' in email")
        
        if Enum.empty?(contacts) do
          IO.puts("")
          IO.puts("⚠️  No contacts found. This could mean:")
          IO.puts("   1. Your HubSpot account has no contacts")
          IO.puts("   2. The contacts don't have email addresses")
          IO.puts("   3. The search operator needs adjustment")
          IO.puts("")
          IO.puts("Please check your HubSpot account to verify contacts exist.")
        else
          IO.puts("")
          Enum.each(contacts, fn contact ->
            IO.puts("   • #{format_contact.(contact)}")
          end)
        end
        
      {:error, {status, error_body}} ->
        IO.puts("❌ API Error (Status #{status}):")
        IO.puts("   #{inspect(error_body, limit: :infinity)}")
        
      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}")
    end
  else
    IO.puts("❌ No HubSpot credentials found.")
  end
else
  IO.puts("❌ No users found.")
end

