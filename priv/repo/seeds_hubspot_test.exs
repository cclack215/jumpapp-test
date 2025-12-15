# Script to create test meeting data for HubSpot integration testing
# Run with: mix run priv/repo/seeds_hubspot_test.exs

import Ecto.Query
alias SocialScribe.Repo
alias SocialScribe.Accounts
alias SocialScribe.Accounts.User
alias SocialScribe.Calendar.CalendarEvent
alias SocialScribe.Bots.RecallBot
alias SocialScribe.Meetings.{Meeting, MeetingTranscript, MeetingParticipant}

# Get the first user from the database
user = Repo.one(from u in User, limit: 1)

if user do
  IO.puts("Creating test meeting data for user: #{user.email}")

  # Get Google credential
  google_credential = Accounts.list_user_credentials(user, provider: "google") |> List.first()

  if is_nil(google_credential) do
    IO.puts("⚠️  Warning: No Google credential found. Creating event without credential_id.")
  end

  # Create calendar event with Google Meet link
  now = DateTime.utc_now() |> DateTime.truncate(:second)
  now_naive = DateTime.to_naive(now)
  
  calendar_event = Repo.insert!(%CalendarEvent{
    user_id: user.id,
    user_credential_id: if(google_credential, do: google_credential.id, else: nil),
    summary: "Quarterly Sales Review Meeting",
    description: "Review Q4 sales performance and discuss Q1 strategy",
    location: "https://meet.google.com/jnz-kmkt-nuz",
    hangout_link: "https://meet.google.com/jnz-kmkt-nuz",
    html_link: "https://www.google.com/calendar/event?eid=test",
    google_event_id: "test-event-#{System.unique_integer([:positive])}",
    status: "confirmed",
    start_time: DateTime.add(now, -2, :hour) |> DateTime.truncate(:second),
    end_time: DateTime.add(now, -1, :hour) |> DateTime.truncate(:second),
    record_meeting: true,
    inserted_at: now,
    updated_at: now
  })

  IO.puts("✅ Created calendar event: #{calendar_event.id}")

  # Create recall bot (marked as done) - uses :utc_datetime
  recall_bot = Repo.insert!(%RecallBot{
    user_id: user.id,
    recall_bot_id: "test-bot-#{System.unique_integer([:positive])}",
    status: "done",
    meeting_url: "https://meet.google.com/jnz-kmkt-nuz",
    calendar_event_id: calendar_event.id,
    inserted_at: now,
    updated_at: now
  })

  IO.puts("✅ Created recall bot: #{recall_bot.id}")

  # Create meeting - uses :naive_datetime for timestamps, :utc_datetime for recorded_at
  recorded_at = DateTime.add(now, -2, :hour) |> DateTime.truncate(:second)
  meeting = Repo.insert!(%Meeting{
    title: "Quarterly Sales Review Meeting",
    recorded_at: recorded_at,
    duration_seconds: 3600,  # 1 hour
    calendar_event_id: calendar_event.id,
    recall_bot_id: recall_bot.id,
    inserted_at: now_naive,
    updated_at: now_naive
  })

  IO.puts("✅ Created meeting: #{meeting.id}")

  # Create transcript with realistic data that will trigger HubSpot updates
  # This transcript includes phone numbers, emails, company names, job titles, etc.
  transcript_content = %{
    "data" => [
      %{
        "text" => "Hello everyone, welcome to our quarterly sales review. I'm John Smith, VP of Sales at Acme Corporation.",
        "start" => 0.0,
        "end" => 8.5,
        "speaker" => "John Smith"
      },
      %{
        "text" => "Thanks John. I'm Sarah Johnson, and my email is sarah.johnson@acmecorp.com. You can also reach me at 555-123-4567.",
        "start" => 9.0,
        "end" => 18.2,
        "speaker" => "Sarah Johnson"
      },
      %{
        "text" => "Great to be here. I'm Michael Chen, Director of Marketing. My phone number is 555-987-6543 and I work at Tech Solutions Inc.",
        "start" => 19.0,
        "end" => 28.5,
        "speaker" => "Michael Chen"
      },
      %{
        "text" => "Hi everyone, I'm Emily Davis. I'm the Chief Revenue Officer at Global Enterprises. My email is emily.davis@globalent.com and my mobile is 555-456-7890.",
        "start" => 29.0,
        "end" => 40.0,
        "speaker" => "Emily Davis"
      },
      %{
        "text" => "Our Q4 sales were excellent. We closed $2.5 million in revenue, which is a 30% increase from last quarter.",
        "start" => 41.0,
        "end" => 52.0,
        "speaker" => "John Smith"
      },
      %{
        "text" => "That's fantastic! I should mention that my title has changed - I'm now the Senior VP of Sales, not just VP.",
        "start" => 53.0,
        "end" => 62.5,
        "speaker" => "John Smith"
      },
      %{
        "text" => "For Q1, we're targeting $3 million. I've updated my contact info - my new email is john.smith@acmecorp.com and my direct line is 555-111-2222.",
        "start" => 63.0,
        "end" => 75.0,
        "speaker" => "John Smith"
      },
      %{
        "text" => "I've also moved to a new company. I'm now at Digital Innovations LLC as the Head of Business Development.",
        "start" => 76.0,
        "end" => 85.5,
        "speaker" => "Michael Chen"
      },
      %{
        "text" => "My new contact information is michael.chen@digitalinnovations.com and my office phone is 555-333-4444.",
        "start" => 86.0,
        "end" => 94.0,
        "speaker" => "Michael Chen"
      },
      %{
        "text" => "Perfect. Let's schedule a follow-up meeting. I'll send the calendar invite to everyone's email addresses.",
        "start" => 95.0,
        "end" => 103.0,
        "speaker" => "Emily Davis"
      }
    ]
  }

  transcript = Repo.insert!(%MeetingTranscript{
    meeting_id: meeting.id,
    content: transcript_content,
    language: "en",
    inserted_at: now_naive,
    updated_at: now_naive
  })

  IO.puts("✅ Created transcript: #{transcript.id}")

  # Create participants
  participants = [
    %{
      name: "John Smith",
      is_host: true,
      recall_participant_id: "p1"
    },
    %{
      name: "Sarah Johnson",
      is_host: false,
      recall_participant_id: "p2"
    },
    %{
      name: "Michael Chen",
      is_host: false,
      recall_participant_id: "p3"
    },
    %{
      name: "Emily Davis",
      is_host: false,
      recall_participant_id: "p4"
    }
  ]

  Enum.each(participants, fn participant_data ->
    Repo.insert!(%MeetingParticipant{
      meeting_id: meeting.id,
      name: participant_data.name,
      is_host: participant_data.is_host,
      recall_participant_id: participant_data.recall_participant_id,
      inserted_at: now_naive,
      updated_at: now_naive
    })
  end)

  IO.puts("✅ Created #{length(participants)} participants")

  IO.puts("")
  IO.puts("=" <> String.duplicate("=", 60))
  IO.puts("✅ Test meeting data created successfully!")
  IO.puts("=" <> String.duplicate("=", 60))
  IO.puts("")
  IO.puts("Meeting ID: #{meeting.id}")
  IO.puts("Title: #{meeting.title}")
  IO.puts("Recorded: #{meeting.recorded_at}")
  IO.puts("Duration: #{meeting.duration_seconds} seconds")
  IO.puts("")
  IO.puts("📋 Transcript includes:")
  IO.puts("  - Phone numbers: 555-123-4567, 555-987-6543, 555-456-7890, 555-111-2222, 555-333-4444")
  IO.puts("  - Email addresses: sarah.johnson@acmecorp.com, emily.davis@globalent.com, michael.chen@digitalinnovations.com")
  IO.puts("  - Company names: Acme Corporation, Tech Solutions Inc, Global Enterprises, Digital Innovations LLC")
  IO.puts("  - Job titles: VP of Sales, Senior VP of Sales, Director of Marketing, Head of Business Development, CRO")
  IO.puts("")
  IO.puts("🔗 View the meeting at:")
  IO.puts("   http://localhost:4000/dashboard/meetings/#{meeting.id}")
  IO.puts("")
  IO.puts("🧪 Next steps:")
  IO.puts("  1. Go to the meeting details page")
  IO.puts("  2. Click 'Update HubSpot Contact' button")
  IO.puts("  3. Search for a contact (or create one in HubSpot first)")
  IO.puts("  4. Review the AI-generated update suggestions")
  IO.puts("  5. Select updates and click 'Update HubSpot'")
  IO.puts("")
else
  IO.puts("❌ No users found. Please create a user first.")
end

