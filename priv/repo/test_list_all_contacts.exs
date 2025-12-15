# Test listing ALL contacts from HubSpot
import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User
alias SocialScribe.HubSpotApi

user = Repo.one(from u in User, limit: 1)
credentials = Accounts.list_user_credentials(user, provider: "hubspot")

if not Enum.empty?(credentials) do
  credential = List.first(credentials)
  
  IO.puts("=" <> String.duplicate("=", 70))
  IO.puts("Testing HubSpot Contact Retrieval")
  IO.puts("=" <> String.duplicate("=", 70))
  IO.puts("")
  IO.puts("Token expires at: #{credential.expires_at}")
  IO.puts("Current time: #{DateTime.utc_now()}")
  IO.puts("")
  
  # First, try to refresh token if needed
  if credential.expires_at && DateTime.compare(credential.expires_at, DateTime.utc_now()) == :lt do
    IO.puts("⚠️  Token is expired, attempting refresh...")
    if credential.refresh_token do
      alias SocialScribe.HubSpotOAuth
      case HubSpotOAuth.refresh_access_token(credential.refresh_token) do
        {:ok, token_data} ->
          expires_in = Map.get(token_data, "expires_in", 3600)
          new_expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)
          
          case Accounts.update_user_credential(credential, %{
                 token: Map.get(token_data, "access_token"),
                 expires_at: new_expires_at
               }) do
            {:ok, updated} ->
              IO.puts("✅ Token refreshed successfully")
              credential = updated
            {:error, reason} ->
              IO.puts("❌ Failed to update credential: #{inspect(reason)}")
          end
        {:error, reason} ->
          IO.puts("❌ Token refresh failed: #{inspect(reason)}")
          IO.puts("   Please reconnect your HubSpot account in settings")
      end
    else
      IO.puts("❌ No refresh token available")
      IO.puts("   Please reconnect your HubSpot account in settings")
    end
  end
  
  IO.puts("")
  IO.puts("Using token: #{String.slice(credential.token, 0, 20)}...")
  IO.puts("")
  
  # Test 1: List ALL contacts using direct API call
  IO.puts("Test 1: Listing ALL contacts (direct API call)...")
  base_url = "https://api.hubapi.com"
  client = Tesla.client([
    {Tesla.Middleware.BaseUrl, base_url},
    Tesla.Middleware.JSON,
    {Tesla.Middleware.Headers,
     [
       {"Authorization", "Bearer #{credential.token}"},
       {"Content-Type", "application/json"}
     ]}
  ])
  
  case Tesla.get(client, "/crm/v3/objects/contacts?limit=100&properties=firstname,lastname,email,phone,company") do
    {:ok, %Tesla.Env{status: 200, body: response}} ->
      all_contacts = Map.get(response, :results, [])
      total = Map.get(response, :total, length(all_contacts))
      IO.puts("✅ Success! Found #{total} total contacts")
      IO.puts("   Retrieved: #{length(all_contacts)} contacts")
      IO.puts("")
      
      if Enum.empty?(all_contacts) do
        IO.puts("⚠️  No contacts found in HubSpot account")
      else
        IO.puts("Contacts:")
        Enum.each(all_contacts, fn contact ->
          props = Map.get(contact, :properties, %{})
          firstname = Map.get(props, :firstname, "") || ""
          lastname = Map.get(props, :lastname, "") || ""
          email = Map.get(props, :email, "") || ""
          name = "#{firstname} #{lastname}" |> String.trim()
          IO.puts("   • #{name} (#{email}) [ID: #{Map.get(contact, :id)}]")
        end)
      end
      
    {:ok, %Tesla.Env{status: 401}} ->
      IO.puts("❌ Authentication failed (401)")
      IO.puts("   Token is expired or invalid. Please reconnect HubSpot account.")
      
    {:ok, %Tesla.Env{status: status, body: error}} ->
      IO.puts("❌ Error (Status #{status}):")
      IO.puts("#{inspect(error, limit: :infinity, pretty: true)}")
      
    {:error, reason} ->
      IO.puts("❌ HTTP Error: #{inspect(reason)}")
  end
  
  IO.puts("")
  IO.puts("=" <> String.duplicate("=", 70))
  IO.puts("")
  
  # Test 2: Search for "Emily" using our search function
  IO.puts("Test 2: Searching for 'Emily' using search_contacts function...")
  case HubSpotApi.search_contacts(credential.token, "Emily") do
    {:ok, contacts} ->
      IO.puts("✅ Search successful! Found #{length(contacts)} contact(s)")
      if Enum.empty?(contacts) do
        IO.puts("   No contacts found matching 'Emily'")
      else
        Enum.each(contacts, fn contact ->
          name = "#{contact.firstname || ""} #{contact.lastname || ""}" |> String.trim()
          email = contact.email || ""
          IO.puts("   • #{name} (#{email}) [ID: #{contact.id}]")
        end)
      end
    {:error, reason} ->
      IO.puts("❌ Search failed: #{inspect(reason)}")
  end
  
  IO.puts("")
  IO.puts("=" <> String.duplicate("=", 70))
else
  IO.puts("❌ No HubSpot credentials found.")
end

