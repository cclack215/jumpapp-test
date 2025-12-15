# Comprehensive test to retrieve contacts from HubSpot
import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User
alias SocialScribe.HubSpotApi
alias SocialScribe.HubSpotOAuth

user = Repo.one(from u in User, limit: 1)
credentials = Accounts.list_user_credentials(user, provider: "hubspot")

if not Enum.empty?(credentials) do
  credential = List.first(credentials)
  
  IO.puts("=" <> String.duplicate("=", 70))
  IO.puts("HubSpot Contact Retrieval Test")
  IO.puts("=" <> String.duplicate("=", 70))
  IO.puts("")
  
  # Check token expiration
  now = DateTime.utc_now()
  expires_at = credential.expires_at || now
  is_expired = DateTime.compare(expires_at, now) == :lt
  seconds_until_expiry = DateTime.diff(expires_at, now, :second)
  
  IO.puts("1. Token Status:")
  IO.puts("   Expires at: #{expires_at}")
  IO.puts("   Current time: #{now}")
  IO.puts("   Is expired: #{is_expired}")
  IO.puts("   Seconds until expiry: #{seconds_until_expiry}")
  IO.puts("")
  
  # Refresh token if expired or expiring soon
  final_credential = if is_expired || seconds_until_expiry < 300 do
    IO.puts("2. Token needs refresh, attempting refresh...")
    if credential.refresh_token do
      case HubSpotOAuth.refresh_access_token(credential.refresh_token) do
        {:ok, token_data} ->
          expires_in = Map.get(token_data, "expires_in", 3600)
          new_expires_at = DateTime.add(now, expires_in, :second)
          new_token = Map.get(token_data, "access_token")
          
          case Accounts.update_user_credential(credential, %{
                 token: new_token,
                 expires_at: new_expires_at
               }) do
            {:ok, updated} ->
              IO.puts("   ✅ Token refreshed successfully!")
              IO.puts("   New expires at: #{updated.expires_at}")
              updated
            {:error, reason} ->
              IO.puts("   ❌ Failed to update credential: #{inspect(reason)}")
              credential
          end
        {:error, reason} ->
          IO.puts("   ❌ Token refresh failed: #{inspect(reason)}")
          IO.puts("   Will try with existing token anyway...")
          credential
      end
    else
      IO.puts("   ⚠️  No refresh token available")
      credential
    end
  else
    IO.puts("2. Token is still valid, using existing token")
    credential
  end
  
  IO.puts("")
  
  # Test 1: List ALL contacts
  IO.puts("3. Test: List ALL contacts from HubSpot...")
  base_url = "https://api.hubapi.com"
  client = Tesla.client([
    {Tesla.Middleware.BaseUrl, base_url},
    Tesla.Middleware.JSON,
    {Tesla.Middleware.Headers,
     [
       {"Authorization", "Bearer #{final_credential.token}"},
       {"Content-Type", "application/json"}
     ]}
  ])
  
  case Tesla.get(client, "/crm/v3/objects/contacts?limit=100&properties=firstname,lastname,email,phone,company") do
    {:ok, %Tesla.Env{status: 200, body: response}} ->
      all_contacts = Map.get(response, :results, [])
      total = Map.get(response, :total, length(all_contacts))
      IO.puts("   ✅ Success! Total contacts: #{total}")
      IO.puts("   Retrieved: #{length(all_contacts)} contacts")
      IO.puts("")
      
      if Enum.empty?(all_contacts) do
        IO.puts("   ⚠️  No contacts found in HubSpot account")
      else
        IO.puts("   Contacts:")
        Enum.each(all_contacts, fn contact ->
          props = Map.get(contact, :properties, %{})
          firstname = Map.get(props, :firstname, "") || ""
          lastname = Map.get(props, :lastname, "") || ""
          email = Map.get(props, :email, "") || ""
          name = "#{firstname} #{lastname}" |> String.trim()
          if name == "", do: name = email
          IO.puts("      • #{name} (#{email}) [ID: #{Map.get(contact, :id)}]")
        end)
      end
      
    {:ok, %Tesla.Env{status: 401}} ->
      IO.puts("   ❌ Authentication failed (401) - Token is invalid or expired")
      IO.puts("   Please reconnect your HubSpot account")
      
    {:ok, %Tesla.Env{status: status, body: error}} ->
      IO.puts("   ❌ Error (Status #{status}): #{inspect(error, limit: :infinity)}")
      
    {:error, reason} ->
      IO.puts("   ❌ HTTP Error: #{inspect(reason)}")
  end
  
  IO.puts("")
  
  # Test 2: Search for "Emily" using our search function
  IO.puts("4. Test: Search for contacts starting with 'Emily'...")
  case HubSpotApi.search_contacts(final_credential.token, "Emily") do
    {:ok, contacts} ->
      IO.puts("   ✅ Search successful! Found #{length(contacts)} contact(s)")
      if Enum.empty?(contacts) do
        IO.puts("   ⚠️  No contacts found matching 'Emily'")
      else
        IO.puts("   Results:")
        Enum.each(contacts, fn contact ->
          name = "#{contact.firstname || ""} #{contact.lastname || ""}" |> String.trim()
          if name == "", do: name = contact.email || "No name"
          IO.puts("      • #{name} (#{contact.email}) [ID: #{contact.id}]")
        end)
      end
      
    {:error, reason} ->
      IO.puts("   ❌ Search failed: #{inspect(reason)}")
  end
  
  IO.puts("")
  
  # Test 3: Try direct search via API
  IO.puts("5. Test: Direct API search for 'Emily'...")
  search_body = %{
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
  
  case Tesla.post(client, "/crm/v3/objects/contacts/search", search_body) do
    {:ok, %Tesla.Env{status: 200, body: response}} ->
      results = Map.get(response, :results, [])
      IO.puts("   ✅ Direct API search returned #{length(results)} result(s)")
      Enum.each(results, fn contact ->
        props = Map.get(contact, :properties, %{})
        name = "#{Map.get(props, :firstname, "")} #{Map.get(props, :lastname, "")}" |> String.trim()
        email = Map.get(props, :email, "")
        IO.puts("      • #{name} (#{email}) [ID: #{Map.get(contact, :id)}]")
      end)
      
    {:ok, %Tesla.Env{status: 401}} ->
      IO.puts("   ❌ Authentication failed (401)")
      
    {:ok, %Tesla.Env{status: status, body: error}} ->
      IO.puts("   ❌ Error (Status #{status}): #{inspect(error, limit: :infinity)}")
      
    {:error, reason} ->
      IO.puts("   ❌ HTTP Error: #{inspect(reason)}")
  end
  
  IO.puts("")
  IO.puts("=" <> String.duplicate("=", 70))
else
  IO.puts("❌ No HubSpot credentials found.")
end

