# Quick test for Emily search
import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User
alias SocialScribe.HubSpotApi

user = Repo.one(from u in User, limit: 1)
credentials = Accounts.list_user_credentials(user, provider: "hubspot")

if not Enum.empty?(credentials) do
  credential = List.first(credentials)
  token = credential.token
  
  IO.puts("Testing search for 'Emily'...")
  IO.puts("")
  
  case HubSpotApi.search_contacts(token, "Emily") do
    {:ok, contacts} ->
      IO.puts("✅ Found #{length(contacts)} contact(s)")
      Enum.each(contacts, fn c ->
        IO.puts("   • #{c.firstname} #{c.lastname} (#{c.email}) [ID: #{c.id}]")
      end)
    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end
end

