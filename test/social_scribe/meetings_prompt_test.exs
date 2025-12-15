defmodule SocialScribe.MeetingsPromptTest do
  use SocialScribe.DataCase

  import SocialScribe.MeetingsFixtures
  import SocialScribe.MeetingTranscriptExample

  alias SocialScribe.Meetings

  @mock_transcript_data %{"data" => meeting_transcript_example()}

  test "generate_prompt_for_meeting/1 returns a structured prompt with title, participants, and transcript" do
    meeting = meeting_fixture()

    # At least one participant
    meeting_participant_fixture(%{
      meeting_id: meeting.id,
      name: "Alice Example",
      is_host: true
    })

    # Transcript content
    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: @mock_transcript_data,
      language: "en-us"
    })

    meeting = Meetings.get_meeting_with_details(meeting.id)

    assert {:ok, prompt} = Meetings.generate_prompt_for_meeting(meeting)

    assert prompt =~ "## Meeting Info:"
    assert prompt =~ meeting.title
    assert prompt =~ "Alice Example (Host)"
    # Text from MeetingTranscriptExample
    assert prompt =~ "what I say later and then"
  end

  test "returns {:error, :no_participants} when there are no participants" do
    meeting = meeting_fixture()

    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: @mock_transcript_data,
      language: "en-us"
    })

    meeting =
      Meetings.get_meeting_with_details(meeting.id)
      |> Map.put(:meeting_participants, [])

    assert {:error, :no_participants} = Meetings.generate_prompt_for_meeting(meeting)
  end

  test "returns {:error, :no_transcript} when there is no transcript" do
    meeting = meeting_fixture()

    meeting_participant_fixture(%{
      meeting_id: meeting.id,
      name: "Alice Example",
      is_host: true
    })

    meeting =
      Meetings.get_meeting_with_details(meeting.id)
      |> Map.put(:meeting_transcript, nil)

    assert {:error, :no_transcript} = Meetings.generate_prompt_for_meeting(meeting)
  end
end
