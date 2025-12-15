#!/usr/bin/env elixir

# Simple Gemini connectivity test.
# Run from the project root with:
#   mix run gemini_test.exs

# Ensure app config (including GEMINI_API_KEY from runtime.exs) is loaded
Application.ensure_all_started(:social_scribe)

api_key =
  Application.get_env(:social_scribe, :gemini_api_key) ||
    System.get_env("GEMINI_API_KEY") ||
    raise "GEMINI_API_KEY not configured in env or application config"

model = "gemini-2.0-flash-lite"
base_url = "https://generativelanguage.googleapis.com/v1beta/models"
url = base_url <> "/" <> model <> ":generateContent?key=" <> api_key

payload = %{
  contents: [
    %{
      parts: [%{text: "Say 'Gemini test OK' and nothing else."}]
    }
  ]
}

client =
  Tesla.client([
    {Tesla.Middleware.BaseUrl, base_url},
    Tesla.Middleware.JSON
  ])

IO.puts("Calling Gemini model #{model}...")

case Tesla.post(client, url, payload) do
  {:ok, %Tesla.Env{status: 200, body: body}} ->
    text_path = [
      "candidates",
      Access.at(0),
      "content",
      "parts",
      Access.at(0),
      "text"
    ]

    case get_in(body, text_path) do
      nil ->
        IO.puts("Gemini response did not contain text at expected path.")
        IO.inspect(body, label: "Full response body")

      text ->
        IO.puts("Gemini response text:")
        IO.puts("---")
        IO.puts(text)
        IO.puts("---")
    end

  {:ok, %Tesla.Env{status: status, body: error_body}} ->
    IO.puts("Gemini API returned error status: #{status}")
    IO.inspect(error_body, label: "Error body")

  {:error, reason} ->
    IO.puts("HTTP error calling Gemini:")
    IO.inspect(reason)
end
