# Verify which HubSpot account is connected and list all contacts
import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User

user = Repo.one(from u in User, limit: 1)
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
  IO.puts("HubSpot Account Verification")
  IO.puts("=" <> String.duplicate("=", 70))
  IO.puts("")
  
  # Get account info
  IO.puts("1. Getting HubSpot account information...")
  case Tesla.get(client, "/integrations/v1/me") do
    {:ok, %Tesla.Env{status: 200, body: account_info}} ->
      IO.puts("✅ Account Info:")
      IO.puts("   Portal ID: #{Map.get(account_info, :portalId, "N/A")}")
      IO.puts("   Time Zone: #{Map.get(account_info, :timeZone, "N/A")}")
      IO.puts("   Currency: #{Map.get(account_info, :currency, "N/A")}")
    {:ok, %Tesla.Env{status: status}} ->
      IO.puts("⚠️  Could not get account info (Status: #{status})")
    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end
  
  IO.puts("")
  
  # Try to get Emily by email
  IO.puts("2. Trying to get 'Emily Davis' by email...")
  case Tesla.get(client, "/crm/v3/objects/contacts/emily.davis@globalent.com?idProperty=email&properties=firstname,lastname,email") do
    {:ok, %Tesla.Env{status: 200, body: contact}} ->
      props = Map.get(contact, :properties, %{})
      IO.puts("✅ Contact found!")
      IO.puts("   Name: #{Map.get(props, :firstname)} #{Map.get(props, :lastname)}")
      IO.puts("   Email: #{Map.get(props, :email)}")
      IO.puts("   ID: #{Map.get(contact, :id)}")
    {:ok, %Tesla.Env{status: 404}} ->
      IO.puts("❌ Contact not found (404)")
      IO.puts("   This means the contact doesn't exist in this HubSpot account")
    {:ok, %Tesla.Env{status: status, body: error}} ->
      IO.puts("❌ Error (Status #{status}): #{inspect(error)}")
    {:error, reason} ->
      IO.puts("❌ HTTP Error: #{inspect(reason)}")
  end
  
  IO.puts("")
  
  # List ALL contacts (no limit)
  IO.puts("3. Listing ALL contacts (no filters)...")
  case Tesla.get(client, "/crm/v3/objects/contacts?limit=100&properties=firstname,lastname,email") do
    {:ok, %Tesla.Env{status: 200, body: response}} ->
      all_contacts = Map.get(response, :results, [])
      total = Map.get(response, :total, length(all_contacts))
      IO.puts("✅ Total contacts in account: #{total}")
      IO.puts("   Retrieved: #{length(all_contacts)}")
      
      if Enum.empty?(all_contacts) do
        IO.puts("")
        IO.puts("⚠️  Your HubSpot account has NO contacts.")
        IO.puts("   Please add contacts via HubSpot UI:")
        IO.puts("   1. Go to https://app.hubspot.com")
        IO.puts("   2. Click Contacts → Contacts")
        IO.puts("   3. Click 'Create contact'")
        IO.puts("   4. Add: First name: Emily, Last name: Davis, Email: emily.davis@globalent.com")
      else
        IO.puts("")
        IO.puts("Contacts found:")
        Enum.each(Enum.take(all_contacts, 10), fn contact ->
          props = Map.get(contact, :properties, %{})
          name = "#{Map.get(props, :firstname, "")} #{Map.get(props, :lastname, "")}" |> String.trim()
          email = Map.get(props, :email, "")
          IO.puts("   • #{name} (#{email}) [ID: #{Map.get(contact, :id)}]")
        end)
        if length(all_contacts) > 10 do
          IO.puts("   ... and #{length(all_contacts) - 10} more")
        end
      end
    {:ok, %Tesla.Env{status: status, body: error}} ->
      IO.puts("❌ Error (Status #{status}): #{inspect(error)}")
    {:error, reason} ->
      IO.puts("❌ HTTP Error: #{inspect(reason)}")
  end
  
  IO.puts("")
  IO.puts("=" <> String.duplicate("=", 70))
else
  IO.puts("❌ No HubSpot credentials found.")
end

