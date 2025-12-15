defmodule SocialScribeWeb.AuthController do
  use SocialScribeWeb, :controller

  alias SocialScribe.FacebookApi
  alias SocialScribe.Accounts
  alias SocialScribeWeb.UserAuth
  alias SocialScribe.HubSpotOAuth
  plug Ueberauth

  require Logger

  @doc """
  Handles the initial request to the provider (e.g., Google).
  Ueberauth's plug will redirect the user to the provider's consent page.
  """
  def request(conn, %{"provider" => "hubspot"}) do
    current_user = conn.assigns[:current_user]

    if current_user do
      redirect_uri = Application.get_env(:social_scribe, :hubspot_redirect_uri) ||
                      "#{get_scheme(conn)}://#{get_host(conn)}/auth/hubspot/callback"
      state = :crypto.strong_rand_bytes(16) |> Base.encode64()
      auth_url = HubSpotOAuth.get_authorization_url(redirect_uri, state)

      conn
      |> put_session("hubspot_oauth_state", state)
      |> redirect(external: auth_url)
    else
      conn
      |> put_flash(:error, "You must be logged in to connect HubSpot.")
      |> redirect(to: ~p"/")
    end
  end

  def request(conn, _params) do
    render(conn, :request)
  end

  @doc """
  Handles the callback from the provider after the user has granted consent.
  """
  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "google"
      })
      when not is_nil(user) do
    Logger.info("Google OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, _credential} ->
        conn
        |> put_flash(:info, "Google account added successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not add Google account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "linkedin"
      }) do
    Logger.info("LinkedIn OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, credential} ->
        Logger.info("credential")
        Logger.info(credential)

        conn
        |> put_flash(:info, "LinkedIn account added successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, reason} ->
        Logger.error(reason)

        conn
        |> put_flash(:error, "Could not add LinkedIn account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "facebook"
      })
      when not is_nil(user) do
    Logger.info("Facebook OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, credential} ->
        case FacebookApi.fetch_user_pages(credential.uid, credential.token) do
          {:ok, facebook_pages} ->
            facebook_pages
            |> Enum.each(fn page ->
              Accounts.link_facebook_page(user, credential, page)
            end)

          _ ->
            :ok
        end

        conn
        |> put_flash(
          :info,
          "Facebook account added successfully. Please select a page to connect."
        )
        |> redirect(to: ~p"/dashboard/settings/facebook_pages")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not add Facebook account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(conn, %{"provider" => "hubspot"} = params) do
    Logger.info("=== HubSpot Callback Received ===")
    Logger.info("Full params: #{inspect(params)}")
    Logger.info("Query params: #{inspect(conn.query_params)}")
    
    code = params["code"]
    state = params["state"]
    error = params["error"]
    error_description = params["error_description"]
    
    current_user = conn.assigns[:current_user]
    stored_state = get_session(conn, "hubspot_oauth_state")
    
    Logger.info("Code present: #{!is_nil(code)}")
    Logger.info("State received: #{state}")
    Logger.info("State stored: #{stored_state}")
    Logger.info("State match: #{state == stored_state}")
    Logger.info("Current user present: #{!is_nil(current_user)}")
    
    if error do
      Logger.error("HubSpot OAuth error: #{error}")
      Logger.error("Error description: #{error_description}")
      conn
      |> delete_session("hubspot_oauth_state")
      |> put_flash(:error, "HubSpot authentication failed: #{error_description || error}")
      |> redirect(to: ~p"/dashboard/settings")
    else
      if current_user && state == stored_state do
      redirect_uri = Application.get_env(:social_scribe, :hubspot_redirect_uri) ||
                      "#{get_scheme(conn)}://#{get_host(conn)}/auth/hubspot/callback"

      case HubSpotOAuth.exchange_code_for_tokens(code, redirect_uri) do
        {:ok, token_data} ->
          Logger.info("HubSpot token data received. Keys: #{inspect(Map.keys(token_data))}")
          Logger.info("Full token data: #{inspect(token_data, limit: :infinity)}")
          
          # HubSpot returns JSON with string keys: access_token, refresh_token, expires_in
          # Access tokens expire in ~6 hours (21600 seconds)
          access_token = Map.get(token_data, "access_token")
          refresh_token = Map.get(token_data, "refresh_token")
          expires_in_str = Map.get(token_data, "expires_in") || "21600"
            
          expires_in = 
            try do
              String.to_integer(to_string(expires_in_str))
            rescue
              _ -> 21600  # Default to 6 hours if parsing fails
            end
          expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)
          
          Logger.info("HubSpot OAuth: access_token expires in #{expires_in} seconds (#{div(expires_in, 3600)} hours)")
          Logger.info("HubSpot OAuth: refresh_token present: #{!is_nil(refresh_token)}")

          if is_nil(access_token) or access_token == "" do
            Logger.error("Missing or empty access_token in HubSpot response")
            Logger.error("Token data structure: #{inspect(token_data)}")
            conn
            |> delete_session("hubspot_oauth_state")
            |> put_flash(:error, "Invalid response from HubSpot. Please check server logs for details.")
            |> redirect(to: ~p"/dashboard/settings")
          else
            credential_attrs = %{
              provider: "hubspot",
              uid: "hubspot_user", # HubSpot doesn't provide a user ID in token response
              token: access_token,
              refresh_token: refresh_token,
              expires_at: expires_at,
              email: current_user.email || "hubspot@connected.com"
            }

            credential_attrs_with_user = Map.put(credential_attrs, :user_id, current_user.id)
          
            case Accounts.find_or_create_user_credential(current_user, credential_attrs_with_user) do
              {:ok, _credential} ->
                conn
                |> delete_session("hubspot_oauth_state")
                |> put_flash(:info, "HubSpot account connected successfully.")
                |> redirect(to: ~p"/dashboard/settings")

              {:error, reason} ->
                Logger.error("Failed to save HubSpot credential: #{inspect(reason)}")
                conn
                |> delete_session("hubspot_oauth_state")
                |> put_flash(:error, "Could not connect HubSpot account.")
                |> redirect(to: ~p"/dashboard/settings")
            end
          end

        {:error, reason} ->
          Logger.error("=== HubSpot Token Exchange Failed ===")
          Logger.error("Error reason: #{inspect(reason)}")
          Logger.error("Error type: #{inspect(elem(reason, 0))}")
          if tuple_size(reason) > 1 do
            Logger.error("Status code: #{inspect(elem(reason, 0))}")
            Logger.error("Error body: #{inspect(elem(reason, 1))}")
          end
          conn
          |> delete_session("hubspot_oauth_state")
          |> put_flash(:error, "Failed to authenticate with HubSpot. Check server logs for details.")
          |> redirect(to: ~p"/dashboard/settings")
      end
      else
        Logger.error("=== HubSpot Callback Validation Failed ===")
        Logger.error("Missing user: #{is_nil(current_user)}")
        Logger.error("State mismatch: received=#{state}, stored=#{stored_state}")
        conn
        |> delete_session("hubspot_oauth_state")
        |> put_flash(:error, "Invalid OAuth state or session. Please try again.")
        |> redirect(to: ~p"/dashboard/settings")
      end
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    Logger.info("Google OAuth Login")
    Logger.info(auth)

    case Accounts.find_or_create_user_from_oauth(auth) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)

      {:error, reason} ->
        Logger.info("error")
        Logger.info(reason)

        conn
        |> put_flash(:error, "There was an error signing you in.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    Logger.error("OAuth Login")
    Logger.error(conn)

    conn
    |> put_flash(:error, "There was an error signing you in. Please try again.")
    |> redirect(to: ~p"/")
  end

  defp get_scheme(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [scheme] -> scheme
      _ -> if conn.scheme == :https, do: "https", else: "http"
    end
  end

  defp get_host(conn) do
    case get_req_header(conn, "host") do
      [host] -> host
      _ -> "localhost:4000"
    end
  end
end
