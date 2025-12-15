defmodule SocialScribe.AIContentGenerator do
  @moduledoc "Generates content using AI providers (OpenAI first, fallback to Google Gemini)."

  @behaviour SocialScribe.AIContentGeneratorApi

  alias SocialScribe.Meetings
  alias SocialScribe.Automations

  require Logger

  # OpenAI configuration (preferred when OPENAI_API_KEY is present)
  @openai_model "gpt-4o-mini"
  @openai_api_base_url "https://api.openai.com/v1"

  # Gemini configuration (kept as original implementation and used as fallback)
  # NOTE: The following model/base URL are for Google Gemini.
  @gemini_model "gemini-2.0-flash-lite"
  @gemini_api_base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @impl SocialScribe.AIContentGeneratorApi
  def generate_follow_up_email(meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        Based on the following meeting transcript, please draft a concise and professional follow-up email.
        The email should summarize the key discussion points and clearly list any action items assigned, including who is responsible if mentioned.
        Keep the tone friendly and action-oriented.

        #{meeting_prompt}
        """

        call_ai(prompt)
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_automation(automation, meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        #{Automations.generate_prompt_for_automation(automation)}

        #{meeting_prompt}
        """

        call_ai(prompt)
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_hubspot_updates(meeting, hubspot_context) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        context_json = Jason.encode!(hubspot_context, pretty: true)

        prompt = """
        You are helping update a single HubSpot contact record.

        Analyze the following meeting transcript and the CURRENT HubSpot contact context from HubSpot.
        The JSON context includes:
        - contact.properties: the current contact properties
        - contact.properties_with_history: history for selected fields (for example lifecyclestage and hs_lead_status)
        - associations: related objects such as companies and deals (by ID and metadata)
        - associated_companies: full details for each associated company (id and properties)
        - primary_company: the primary associated company (id and properties, typically the first associated company)
        - associated_deals: full details for each associated deal (id and properties)

        Identify any information mentioned in the meeting that should update THIS SPECIFIC contact's properties in HubSpot.

        IMPORTANT:
        - Focus ONLY on the person whose email matches the HubSpot contact email (if present in the transcript).
        - Ignore other people mentioned in the transcript whose email does NOT match the HubSpot contact email.
        - You may suggest updates for ANY contact property that appears in the JSON context below (including custom properties), not just name, title, phone, or email.
        - Pay special attention to changes in phone numbers, email addresses, job titles, company names, address details, lifecycle stage, and any other clearly-mentioned fields.
        - If the transcript clearly states a new phone number or email that is different from the current HubSpot value, you MUST suggest an update.
        - When a phone number change is mentioned and the contact already has a non-empty "phone" value in HubSpot, TREAT THIS AS AN UPDATE TO "phone" (not "mobilephone") unless the transcript clearly says it is a separate mobile number.

        Current HubSpot Contact Context (this is the record you are updating):
        #{context_json}

        Meeting Transcript:
        #{meeting_prompt}

        Please analyze the transcript and suggest updates to the HubSpot contact properties.
        For each suggested update, provide:
        1. The property name (use the exact HubSpot property name as shown in the CURRENT HubSpot Contact Properties JSON above, e.g. firstname, lastname, email, phone, lifecyclestage, or any custom property keys)
        2. The current value in HubSpot (or "No existing value" ONLY if that property is null or missing in the CURRENT HubSpot Contact Properties JSON above)
        3. The suggested new value from the transcript
        4. A brief reason/context from the transcript (include timestamp if possible)

        Return your response as a JSON array of objects with this exact structure:
        [
          {
            "property": "property_name",
            "current_value": "current value or 'No existing value'",
            "suggested_value": "suggested new value",
            "reason": "brief explanation from transcript",
            "timestamp": "MM:SS format if mentioned"
          }
        ]

        Only suggest updates where ALL of the following are true:
        - The information is clearly stated in the transcript.
        - The suggested value is different from the CURRENT value in the HubSpot properties above.
        - The update makes sense for a CRM contact record.
        - The information refers to the SAME person as the HubSpot contact (by matching email or clearly by name).

        Return ONLY valid JSON, no additional text or explanation.
        """

        # Log a truncated version of the prompt for debugging
        Logger.debug("AI generate_hubspot_updates prompt (truncated): #{String.slice(prompt, 1000, 10000)}...")

        case call_ai(prompt) do
          {:ok, response_text} ->
            Logger.debug("AI generate_hubspot_updates raw response (truncated): #{String.slice(response_text, 0, 500)}...")
            # Try to extract JSON from the response
            json_text =
              response_text
              |> String.replace(~r/```json\s*/, "")
              |> String.replace(~r/```\s*/, "")
              |> String.trim()

            case Jason.decode(json_text) do
              {:ok, updates} when is_list(updates) ->
                # Enrich updates with timestamps based on the meeting transcript, if available
                {:ok, add_timestamps_from_transcript(updates, meeting)}

              {:ok, _} ->
                {:error, :invalid_json_format}

              {:error, _} ->
                {:error, :json_parse_error}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Unified entry point: try OpenAI first (if configured), then fall back to Gemini
  defp call_ai(prompt_text) do
    case call_openai(prompt_text) do
      {:ok, _} = ok ->
        Logger.info("AIContentGenerator: using OpenAI successfully")
        ok

      # If OpenAI is not configured or returns an error, fall back to Gemini
      {:error, :no_openai_api_key} ->
        Logger.info("AIContentGenerator: OPENAI_API_KEY not set, falling back to Gemini")
        call_gemini(prompt_text)

      {:error, reason} ->
        Logger.warning("AIContentGenerator: OpenAI error #{inspect(reason)}, falling back to Gemini")
        call_gemini(prompt_text)
    end
  end

  defp call_openai(prompt_text) do
    api_key =
      System.get_env("OPENAI_API_KEY") ||
        Application.get_env(:social_scribe, :openai_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :no_openai_api_key}
    else
      Logger.info("AIContentGenerator: calling OpenAI #{@openai_model}")
      url = @openai_api_base_url <> "/chat/completions"

      body = %{
        model: @openai_model,
        messages: [
          %{role: "system", content: "You are a helpful assistant."},
          %{role: "user", content: prompt_text}
        ],
        temperature: 0.2
      }

      client =
        Tesla.client([
          {Tesla.Middleware.BaseUrl, @openai_api_base_url},
          Tesla.Middleware.JSON,
          {Tesla.Middleware.Headers,
           [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/json"}
           ]}
        ])

      # Use shorter timeouts so we don't block the HTTP request until Bandit times out
      opts = [recv_timeout: 15_000, timeout: 5_000]

      case Tesla.post(client, "/chat/completions", body, opts: opts) do
        {:ok, %Tesla.Env{status: 200, body: %{"choices" => choices}}} ->
          text =
            choices
            |> List.first()
            |> get_in(["message", "content"])

          if is_binary(text) do
            {:ok, text}
          else
            {:error, {:parsing_error, "No text content found in OpenAI response", choices}}
          end

        {:ok, %Tesla.Env{status: status, body: error_body}} ->
          {:error, {:api_error, status, error_body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  # Original Gemini-specific implementation (kept as-is for compatibility and fallback)
  defp call_gemini(prompt_text) do
    api_key = Application.fetch_env!(:social_scribe, :gemini_api_key)
    url = "#{@gemini_api_base_url}/#{@gemini_model}:generateContent?key=#{api_key}"

    payload = %{
      contents: [
        %{
          parts: [%{text: prompt_text}]
        }
      ]
    }

    case Tesla.post(client(), url, payload) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        # Safely extract the text content
        # The response structure is typically: body.candidates[0].content.parts[0].text

        text_path = [
          "candidates",
          Access.at(0),
          "content",
          "parts",
          Access.at(0),
          "text"
        ]

        case get_in(body, text_path) do
          nil -> {:error, {:parsing_error, "No text content found in Gemini response", body}}
          text_content -> {:ok, text_content}
        end

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {:api_error, status, error_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp client do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @gemini_api_base_url},
      Tesla.Middleware.JSON
    ])
  end

  # Try to attach accurate MM:SS timestamps to each update based on where the suggested value
  # appears in the meeting transcript segments stored on the meeting.
  defp add_timestamps_from_transcript(updates, %{
         meeting_transcript: %{content: %{"data" => segments}}
       })
       when is_list(segments) do
    Enum.map(updates, fn update ->
      # If the AI already provided a timestamp, keep it
      case Map.get(update, "timestamp") do
        # Treat empty or obviously dummy timestamps as missing so we recompute
        ts when is_binary(ts) and ts not in ["", "00:00", "0:00"] ->
          update

        _ ->
          suggested_value = Map.get(update, "suggested_value", "")

          timestamp =
            case find_segment_timestamp(segments, suggested_value) do
              nil -> ""
              seconds -> format_seconds_to_mmss(seconds)
            end

          Map.put(update, "timestamp", timestamp)
      end
    end)
  end

  defp add_timestamps_from_transcript(updates, _), do: updates

  # Find the start time (in seconds) of the first transcript segment whose text contains
  # the suggested value. This works well for things like phone numbers and emails that
  # should appear verbatim in the transcript.
  defp find_segment_timestamp(segments, suggested_value) when is_binary(suggested_value) and suggested_value != "" do
    segments
    |> Enum.find_value(fn segment ->
      text = Map.get(segment, "text", "") || ""

      if String.contains?(text, suggested_value) do
        Map.get(segment, "start") || Map.get(segment, "end")
      else
        nil
      end
    end)
  end

  defp find_segment_timestamp(_segments, _suggested_value), do: nil

  defp format_seconds_to_mmss(seconds) when is_number(seconds) do
    total = trunc(seconds)
    minutes = div(total, 60)
    secs = rem(total, 60)

    :io_lib.format("~2..0B:~2..0B", [minutes, secs])
    |> to_string()
  end

  defp format_seconds_to_mmss(_), do: ""
end
