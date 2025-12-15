defmodule SocialScribeWeb.MeetingLive.Show do
  use SocialScribeWeb, :live_view

  import SocialScribeWeb.PlatformLogo
  import SocialScribeWeb.ClipboardButton

  alias SocialScribe.Meetings
  alias SocialScribe.Automations
  alias SocialScribe.Accounts

  @impl true
  def mount(%{"id" => meeting_id}, _session, socket) do
    meeting = Meetings.get_meeting_with_details(meeting_id)

    user_has_automations =
      Automations.list_active_user_automations(socket.assigns.current_user.id)
      |> length()
      |> Kernel.>(0)

    automation_results = Automations.list_automation_results_for_meeting(meeting_id)

    hubspot_connected =
      socket.assigns.current_user
      |> Accounts.list_user_credentials(provider: "hubspot")
      |> Enum.any?()

    if meeting.calendar_event.user_id != socket.assigns.current_user.id do
      socket =
        socket
        |> put_flash(:error, "You do not have permission to view this meeting.")
        |> redirect(to: ~p"/dashboard/meetings")

      {:error, socket}
    else
      socket =
        socket
        |> assign(:page_title, "Meeting Details: #{meeting.title}")
        |> assign(:meeting, meeting)
        |> assign(:automation_results, automation_results)
        |> assign(:user_has_automations, user_has_automations)
        |> assign(:hubspot_connected, hubspot_connected)
        |> assign(
          :follow_up_email_form,
          to_form(%{
            "follow_up_email" => ""
          })
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"automation_result_id" => automation_result_id}, _uri, socket) do
    automation_result = Automations.get_automation_result!(automation_result_id)
    automation = Automations.get_automation!(automation_result.automation_id)

    socket =
      socket
      |> assign(:automation_result, automation_result)
      |> assign(:automation, automation)

    {:noreply, socket}
  end

  @impl true
  def handle_params(%{"hubspot_update" => "true"}, _uri, socket) do
    {:noreply, assign(socket, :live_action, :hubspot_update)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:hubspot_updated, _contact_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "HubSpot contact updated successfully.")
     |> push_patch(to: ~p"/dashboard/meetings/#{socket.assigns.meeting.id}")}
  end

  # Forward AI update results from the background Task to the HubSpotUpdateModalComponent
  def handle_info({:hubspot_ai_updates_result, result}, socket) do
    component_id = "hubspot-update-#{socket.assigns.meeting.id}"

    send_update(SocialScribeWeb.MeetingLive.HubSpotUpdateModalComponent,
      id: component_id,
      ai_updates_result: result
    )

    {:noreply, socket}
  end

  # Forward contact loading messages to the HubSpotUpdateModalComponent
  def handle_info({:update_component, component_id, {:contacts_loaded, contacts}}, socket) do
    # Update the component with loaded contacts
    # send_update merges with existing assigns, so we only need to pass the new ones
    send_update(SocialScribeWeb.MeetingLive.HubSpotUpdateModalComponent,
      id: component_id,
      contacts_loaded: contacts
    )
    {:noreply, socket}
  end

  def handle_info({:update_component, component_id, {:contacts_load_failed, reason}}, socket) do
    # Update the component with error
    send_update(SocialScribeWeb.MeetingLive.HubSpotUpdateModalComponent,
      id: component_id,
      contacts_load_failed: reason
    )
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate-follow-up-email", params, socket) do
    socket =
      socket
      |> assign(:follow_up_email_form, to_form(params))

    {:noreply, socket}
  end

  defp format_duration(nil), do: "N/A"

  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    cond do
      minutes > 0 && remaining_seconds > 0 -> "#{minutes} min #{remaining_seconds} sec"
      minutes > 0 -> "#{minutes} min"
      seconds > 0 -> "#{seconds} sec"
      true -> "Less than a second"
    end
  end

  attr :meeting_transcript, :map, required: true

  defp transcript_content(assigns) do
    raw_segments =
      case assigns.meeting_transcript do
        nil ->
          []

        mt when is_map(mt) ->
          case mt.content do
            %{"data" => segments} when is_list(segments) -> segments
            %{"data" => segment} when is_binary(segment) -> [segment]
            _ -> []
          end

        _ ->
          []
      end

    has_transcript = Enum.any?(raw_segments)

    normalized_segments =
      Enum.map(raw_segments, fn
        %{} = segment ->
          speaker = Map.get(segment, "speaker", "Unknown Speaker")

          words =
            cond do
              is_binary(Map.get(segment, "text")) and
                  String.trim(Map.get(segment, "text")) != "" ->
                [Map.get(segment, "text")]

              is_list(Map.get(segment, "words")) ->
                Enum.map(Map.get(segment, "words", []), &Map.get(&1, "text", ""))

              true ->
                []
            end

          %{speaker: speaker, text: Enum.join(words, " ")}

        segment when is_binary(segment) ->
          %{speaker: "Transcript", text: segment}

        other ->
          %{speaker: "Transcript", text: inspect(other)}
      end)

    assigns =
      assigns
      |> assign(:has_transcript, has_transcript)
      |> assign(:normalized_segments, normalized_segments)

    ~H"""
    <div class="bg-white shadow-xl rounded-lg p-6 md:p-8">
      <h2 class="text-2xl font-semibold mb-4 text-slate-700">
        Meeting Transcript
      </h2>
      <div class="prose prose-sm sm:prose max-w-none h-96 overflow-y-auto pr-2">
        <%= if @has_transcript do %>
          <div :for={segment <- @normalized_segments} class="mb-3">
            <p>
              <span class="font-semibold text-indigo-600">
                <%= segment.speaker %>:
              </span>
              <%= segment.text %>
            </p>
          </div>
        <% else %>
          <p class="text-slate-500">
            Transcript not available for this meeting.
          </p>
        <% end %>
      </div>
    </div>
    """
  end
end
