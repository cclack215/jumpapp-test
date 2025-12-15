# Script to test HubSpot contact search
# Run with: mix run priv/repo/test_hubspot_contacts.exs

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
  IO.puts("=" <> String.duplicate("=", 60))
  IO.puts("Testing HubSpot Contact Search")
  IO.puts("=" <> String.duplicate("=", 60))
  IO.puts("User: #{user.email}")
  IO.puts("")

  # Get HubSpot credential
  credentials = Accounts.list_user_credentials(user, provider: "hubspot")
  
  if Enum.empty?(credentials) do
    IO.puts("❌ No HubSpot credentials found for this user.")
    IO.puts("   Please connect your HubSpot account in Settings first.")
  else
    credential = List.first(credentials)
    IO.puts("✅ Found HubSpot credential (ID: #{credential.id})")
    IO.puts("   Token expires at: #{credential.expires_at}")
    IO.puts("   Has refresh token: #{!is_nil(credential.refresh_token)}")
    IO.puts("")

    # Check if token needs refresh
    token = credential.token
    if credential.expires_at && DateTime.compare(credential.expires_at, DateTime.utc_now()) == :lt do
      IO.puts("⚠️  Token expired. Attempting to refresh...")
      
      if credential.refresh_token do
        case HubSpotOAuth.refresh_access_token(credential.refresh_token) do
          {:ok, token_data} ->
            expires_in = Map.get(token_data, "expires_in", 3600)
            expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)
            new_token = Map.get(token_data, "access_token")
            
            case Accounts.update_user_credential(credential, %{
                   token: new_token,
                   expires_at: expires_at
                 }) do
              {:ok, updated_credential} ->
                IO.puts("✅ Token refreshed successfully")
                token = updated_credential.token
              {:error, reason} ->
                IO.puts("❌ Failed to update credential: #{inspect(reason)}")
                System.halt(1)
            end
          {:error, reason} ->
            IO.puts("❌ Failed to refresh token: #{inspect(reason)}")
            System.halt(1)
        end
      else
        IO.puts("❌ No refresh token available. Please reconnect HubSpot account.")
        System.halt(1)
      end
    else
      IO.puts("✅ Token is valid")
    end

    IO.puts("")
    IO.puts("Testing contact search...")
    IO.puts("")

    # Test search with "test"
    test_queries = ["test", "test1", "gmail", "hubspot"]
    
    Enum.each(test_queries, fn query ->
      IO.puts("Searching for: '#{query}'")
      IO.puts("-" <> String.duplicate("-", 60))
      
      case HubSpotApi.search_contacts(token, query) do
        {:ok, contacts} ->
          IO.puts("✅ Found #{length(contacts)} contact(s)")
          
          if Enum.empty?(contacts) do
            IO.puts("   No contacts found matching '#{query}'")
          else
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
      
      IO.puts("")
    end)
    
    IO.puts("=" <> String.duplicate("=", 60))
    IO.puts("Test complete!")
    IO.puts("=" <> String.duplicate("=", 60))
  end
else
  IO.puts("❌ No users found in database.")
end
