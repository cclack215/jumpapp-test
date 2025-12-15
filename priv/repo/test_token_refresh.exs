# Test token refresh
import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User
alias SocialScribe.HubSpotOAuth

user = Repo.one(from u in User, limit: 1)
credentials = Accounts.list_user_credentials(user, provider: "hubspot")

if not Enum.empty?(credentials) do
  credential = List.first(credentials)
  
  IO.puts("Current token expires at: #{credential.expires_at}")
  IO.puts("Has refresh token: #{!is_nil(credential.refresh_token)}")
  IO.puts("")
  
  if credential.refresh_token do
    IO.puts("Attempting to refresh token...")
    case HubSpotOAuth.refresh_access_token(credential.refresh_token) do
      {:ok, token_data} ->
        IO.puts("✅ Token refresh successful!")
        IO.puts("   New access token: #{String.slice(Map.get(token_data, "access_token", ""), 0, 20)}...")
        IO.puts("   Expires in: #{Map.get(token_data, "expires_in")} seconds")
        
        # Update the credential
        expires_in = Map.get(token_data, "expires_in", 3600)
        new_expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)
        
        case Accounts.update_user_credential(credential, %{
               token: Map.get(token_data, "access_token"),
               expires_at: new_expires_at
             }) do
          {:ok, updated} ->
            IO.puts("✅ Credential updated in database")
            IO.puts("   New expires at: #{updated.expires_at}")
          {:error, reason} ->
            IO.puts("❌ Failed to update credential: #{inspect(reason)}")
        end
      {:error, reason} ->
        IO.puts("❌ Token refresh failed: #{inspect(reason)}")
    end
  else
    IO.puts("❌ No refresh token available")
  end
end

