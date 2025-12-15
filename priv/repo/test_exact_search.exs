# Test exact search
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
  
  IO.puts("Testing exact EQ search for 'Emily'...")
  
  # Simple single filterGroup with EQ
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
      IO.puts("✅ Found #{length(results)} contact(s)")
      Enum.each(results, fn contact ->
        props = Map.get(contact, :properties, %{})
        IO.puts("   • #{Map.get(props, :firstname)} #{Map.get(props, :lastname)} (#{Map.get(props, :email)})")
      end)
    {:ok, %Tesla.Env{status: status, body: error_body}} ->
      IO.puts("❌ Error (Status #{status}):")
      IO.puts("#{inspect(error_body, limit: :infinity, pretty: true)}")
    {:error, reason} ->
      IO.puts("❌ HTTP Error: #{inspect(reason)}")
  end
end

