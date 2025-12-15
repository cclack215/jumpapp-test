defmodule SocialScribe.HubSpotOAuth do
  @moduledoc """
  Handles HubSpot OAuth flow.
  """

  @authorize_url "https://app.hubspot.com/oauth/authorize"
  @token_url "https://api.hubapi.com/oauth/v1/token"

  def get_authorization_url(redirect_uri, state) do
    client_id = Application.get_env(:social_scribe, :hubspot_client_id) || 
                System.get_env("HUBSPOT_CLIENT_ID") ||
                raise "HubSpot client ID not configured"

    # HubSpot requires specific scopes: oauth (required) + crm.objects.contacts.read/write
    # Order matches HubSpot's sample URL format
    scopes = "crm.objects.contacts.write oauth crm.objects.contacts.read"

    params = %{
      client_id: client_id,
      redirect_uri: redirect_uri,
      scope: scopes,
      state: state
    }

    query_string = URI.encode_query(params)
    "#{@authorize_url}?#{query_string}"
  end

  def exchange_code_for_tokens(code, redirect_uri) do
    require Logger

    client_id = Application.get_env(:social_scribe, :hubspot_client_id) || 
                System.get_env("HUBSPOT_CLIENT_ID") ||
                raise "HubSpot client ID not configured"
    client_secret = Application.get_env(:social_scribe, :hubspot_client_secret) || 
                    System.get_env("HUBSPOT_CLIENT_SECRET") ||
                    raise "HubSpot client secret not configured"

    Logger.info("=== HubSpot Token Exchange Debug ===")
    Logger.info("Code: #{String.slice(code, 0, 20)}...")
    Logger.info("Redirect URI: #{redirect_uri}")
    Logger.info("Client ID: #{String.slice(client_id, 0, 10)}...")

    # Try approach 1: Use FormUrlencoded middleware with map body (like token_refresher)
    body_map = %{
      grant_type: "authorization_code",
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      code: code
    }

    Logger.info("Body map: #{inspect(body_map, limit: :infinity, pretty: true)}")

    # Use FormUrlencoded middleware similar to token_refresher
    client = Tesla.client([
      {Tesla.Middleware.BaseUrl, "https://api.hubapi.com"},
      {Tesla.Middleware.FormUrlencoded,
       encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1}
    ])

    Logger.info("Making POST request to /oauth/v1/token")
    Logger.info("Using FormUrlencoded middleware")

    # Try with form_urlencoded option
    case Tesla.post(client, "/oauth/v1/token", body_map, opts: [form_urlencoded: true]) do
      {:ok, %Tesla.Env{status: 200, body: response_body} = env} ->
        Logger.info("=== SUCCESS: Status 200 ===")
        Logger.info("Response body type: #{if is_map(response_body), do: "map", else: "binary"}")
        Logger.info("Response body: #{inspect(response_body, limit: :infinity)}")
        Logger.info("Response headers: #{inspect(env.headers)}")

        # HubSpot returns JSON, not form-urlencoded
        parsed_response =
          case response_body do
            body when is_binary(body) ->
              Logger.info("Response is binary (JSON), parsing with Jason")
              case Jason.decode(body) do
                {:ok, decoded} ->
                  decoded
                {:error, reason} ->
                  Logger.error("Failed to parse JSON: #{inspect(reason)}")
                  %{}
              end
            body when is_map(body) ->
              Logger.info("Response is map, using as-is")
              body
            other ->
              Logger.error("Unexpected response body type: #{inspect(other)}")
              %{}
          end

        Logger.info("Parsed response keys: #{inspect(Map.keys(parsed_response))}")
        Logger.info("Access token present: #{!is_nil(Map.get(parsed_response, "access_token"))}")
        {:ok, parsed_response}

      {:ok, %Tesla.Env{status: status, body: error_body} = env} ->
        Logger.error("=== FAILED: Status #{status} ===")
        Logger.error("Error body: #{inspect(error_body, limit: :infinity)}")
        Logger.error("Response headers: #{inspect(env.headers)}")
        Logger.error("Request URL: #{inspect(env.url)}")
        Logger.error("Request method: #{inspect(env.method)}")
        
        # If 415 error, try fallback with Finch (raw HTTP)
        if status == 415 do
          Logger.info("=== Trying fallback method with Finch ===")
          try_finch_fallback(code, redirect_uri, client_id, client_secret)
        else
          {:error, {status, error_body}}
        end

      {:error, reason} ->
        Logger.error("=== HTTP ERROR ===")
        Logger.error("Error reason: #{inspect(reason, limit: :infinity)}")
        Logger.info("=== Trying fallback method with Finch ===")
        try_finch_fallback(code, redirect_uri, client_id, client_secret)
    end
  end

  # Fallback method using Finch for raw HTTP request
  defp try_finch_fallback(code, redirect_uri, client_id, client_secret) do
    require Logger

    Logger.info("=== Using Finch Fallback ===")
    
    # Build form-urlencoded body manually
    body_params = [
      {"grant_type", "authorization_code"},
      {"client_id", client_id},
      {"client_secret", client_secret},
      {"redirect_uri", redirect_uri},
      {"code", code}
    ]
    
    form_body = URI.encode_query(body_params)
    Logger.info("Form body (first 100 chars): #{String.slice(form_body, 0, 100)}...")
    
    url = "https://api.hubapi.com/oauth/v1/token"
    
    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json"}
    ]
    
    Logger.info("Making Finch POST to: #{url}")
    Logger.info("Headers: #{inspect(headers)}")
    
    case Finch.build(:post, url, headers, form_body) |> Finch.request(SocialScribe.Finch) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        Logger.info("=== Finch SUCCESS: Status 200 ===")
        Logger.info("Response body (first 200 chars): #{String.slice(response_body, 0, 200)}")
        
        # HubSpot returns JSON, parse it
        parsed_response = 
          case Jason.decode(response_body) do
            {:ok, decoded} ->
              decoded
            {:error, reason} ->
              Logger.error("Failed to parse JSON in Finch fallback: #{inspect(reason)}")
              %{}
          end
        
        Logger.info("Parsed response keys: #{inspect(Map.keys(parsed_response))}")
        Logger.info("Access token present: #{!is_nil(Map.get(parsed_response, "access_token"))}")
        {:ok, parsed_response}
        
      {:ok, %Finch.Response{status: status, body: error_body}} ->
        Logger.error("=== Finch FAILED: Status #{status} ===")
        Logger.error("Error body: #{inspect(error_body, limit: :infinity)}")
        {:error, {status, error_body}}
        
      {:error, reason} ->
        Logger.error("=== Finch HTTP ERROR ===")
        Logger.error("Error reason: #{inspect(reason, limit: :infinity)}")
        {:error, reason}
    end
  end

  def refresh_access_token(refresh_token) do
    require Logger

    client_id = Application.get_env(:social_scribe, :hubspot_client_id) || 
                System.get_env("HUBSPOT_CLIENT_ID")
    client_secret = Application.get_env(:social_scribe, :hubspot_client_secret) || 
                    System.get_env("HUBSPOT_CLIENT_SECRET")
    
    if is_nil(client_id) || is_nil(client_secret) do
      Logger.error("HubSpot client ID or secret not configured")
      {:error, :missing_credentials}
    else
      Logger.info("=== HubSpot Token Refresh Debug ===")

      body_map = %{
        grant_type: "refresh_token",
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token
      }

      # Use FormUrlencoded middleware
      client = Tesla.client([
        {Tesla.Middleware.BaseUrl, "https://api.hubapi.com"},
        {Tesla.Middleware.FormUrlencoded,
         encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1}
      ])

      case Tesla.post(client, "/oauth/v1/token", body_map, opts: [form_urlencoded: true]) do
        {:ok, %Tesla.Env{status: 200, body: response_body}} ->
          # HubSpot returns JSON, parse it
          parsed_response =
            case response_body do
              body when is_binary(body) ->
                case Jason.decode(body) do
                  {:ok, decoded} -> decoded
                  {:error, reason} ->
                    Logger.error("Failed to parse JSON in refresh: #{inspect(reason)}")
                    %{}
                end
              body when is_map(body) ->
                body
              other ->
                Logger.error("Unexpected refresh response body type: #{inspect(other)}")
                %{}
            end

          # Log what we received - HubSpot rotates refresh tokens, so we MUST save the new one
          Logger.info("HubSpot refresh response keys: #{inspect(Map.keys(parsed_response))}")
          Logger.info("New access_token present: #{!is_nil(Map.get(parsed_response, "access_token"))}")
          Logger.info("New refresh_token present: #{!is_nil(Map.get(parsed_response, "refresh_token"))}")
          Logger.info("expires_in: #{Map.get(parsed_response, "expires_in")} seconds")

          {:ok, parsed_response}

        {:ok, %Tesla.Env{status: status, body: error_body}} ->
          Logger.error("HubSpot token refresh failed with status #{status}: #{inspect(error_body)}")
          {:error, {status, error_body}}

        {:error, reason} ->
          Logger.error("HubSpot token refresh HTTP error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end

