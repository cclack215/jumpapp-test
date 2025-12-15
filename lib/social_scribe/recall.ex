defmodule SocialScribe.Recall do
  @moduledoc "The real implementation for the Recall.ai API client."
  @behaviour SocialScribe.RecallApi

  defp client do
    api_key = Application.fetch_env!(:social_scribe, :recall_api_key)
    recall_region = Application.fetch_env!(:social_scribe, :recall_region)

    Tesla.client([
      {Tesla.Middleware.BaseUrl, "https://#{recall_region}.recall.ai/api/v1"},
      {Tesla.Middleware.JSON, engine_opts: [keys: :atoms]},
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Token #{api_key}"},
         {"Content-Type", "application/json"},
         {"Accept", "application/json"}
       ]}
    ])
  end

  defp download_client do
    Tesla.client([
      {Tesla.Middleware.JSON, engine_opts: [keys: :atoms]}
    ])
  end

  @impl SocialScribe.RecallApi
  def create_bot(meeting_url, join_at) do
    join_at_iso = Timex.format!(join_at, "{ISO:Extended}")

    body = %{
      meeting_url: meeting_url,
      join_at: join_at_iso,
      bot_name: "Meeting Notetaker",
      recording_config: %{
        # Enable transcript generation using meeting captions, per Recall Quickstart
        transcript: %{
          provider: %{
            "meeting_captions": %{}
          }
        },
        # Request participant events & meeting metadata so the API populates meeting_participants
        participant_events: %{
          metadata: %{}
        },
        meeting_metadata: %{
          metadata: %{}
        }
      }
    }

    Tesla.post(client(), "/bot", body)
  end

  @impl SocialScribe.RecallApi
  def update_bot(recall_bot_id, meeting_url, join_at) do
    body = %{
      meeting_url: meeting_url,
      join_at: Timex.format!(join_at, "{ISO:Extended}")
    }

    Tesla.patch(client(), "/bot/#{recall_bot_id}", body)
  end

  @impl SocialScribe.RecallApi
  def delete_bot(recall_bot_id) do
    Tesla.delete(client(), "/bot/#{recall_bot_id}")
  end

  @impl SocialScribe.RecallApi
  def get_bot(recall_bot_id) do
    Tesla.get(client(), "/bot/#{recall_bot_id}")
  end

  @impl SocialScribe.RecallApi
  def get_bot_transcript(recall_bot_id) do
    case Tesla.get(client(), "/bot/#{recall_bot_id}") do
      {:ok, %Tesla.Env{status: 200, body: bot_info}} ->
        case extract_transcript_download_url(bot_info) do
          {:ok, download_url} ->
            request_transcript_from_download_url(download_url)

          {:error, :no_transcript_shortcut} ->
            fetch_transcript_legacy(bot_info, recall_bot_id)
        end

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, {:bot_info_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_transcript_from_download_url(download_url) do
    case Tesla.get(download_client(), download_url) do
      {:ok, %Tesla.Env{status: status} = env} when status in 200..299 ->
        {:ok, env}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_transcript_legacy(bot_info, recall_bot_id) do
    recording_id = extract_recording_id(bot_info)

    path =
      if is_binary(recording_id) do
        "/recordings/#{recording_id}/transcript"
      else
        "/bot/#{recall_bot_id}/transcript"
      end

    request_transcript(path)
  end

  defp request_transcript(path) do
    case Tesla.get(client(), path) do
      {:ok, %Tesla.Env{status: status} = env} when status in 200..299 ->
        {:ok, env}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_transcript_download_url(%{recordings: recordings}) when is_list(recordings) do
    recording = List.first(recordings) || %{}

    media_shortcuts =
      Map.get(recording, :media_shortcuts) || Map.get(recording, "media_shortcuts") || %{}

    transcript =
      Map.get(media_shortcuts, :transcript) || Map.get(media_shortcuts, "transcript")

    with %{} = transcript <- transcript,
         data <- Map.get(transcript, :data) || Map.get(transcript, "data"),
         download_url when is_binary(download_url) <-
           Map.get(data, :download_url) || Map.get(data, "download_url") do
      {:ok, download_url}
    else
      _ ->
        {:error, :no_transcript_shortcut}
    end
  end

  defp extract_transcript_download_url(_), do: {:error, :no_transcript_shortcut}

  defp extract_recording_id(%{recording: rec}) when is_binary(rec), do: rec

  defp extract_recording_id(%{recordings: [first | _]}) when is_map(first) do
    Map.get(first, :id) || Map.get(first, "id")
  end

  defp extract_recording_id(_), do: nil
end
