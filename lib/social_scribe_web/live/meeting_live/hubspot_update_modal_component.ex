defmodule SocialScribeWeb.MeetingLive.HubSpotUpdateModalComponent do
  use SocialScribeWeb, :live_component

  alias SocialScribe.HubSpot
  alias SocialScribe.Accounts
  alias SocialScribe.AIContentGeneratorApi

  require Logger

  # AI result arrives via parent LiveView using send_update/2 (MUST be defined
  # before the generic update/2 so these clauses match first)
  def update(%{ai_updates_result: {:ok, updates}} = assigns, socket) do
    socket = assign(socket, assigns)

    selected_updates =
      updates
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {_update, idx}, acc ->
        Map.put(acc, idx, true)
      end)

    {:ok,
     socket
     |> assign(:suggested_updates, updates)
     |> assign(:selected_updates, selected_updates)
     |> assign(:loading, false)}
  end

  def update(%{ai_updates_result: {:error, _reason}} = assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign(:loading, false)}
  end

  # Handle update when contacts are loaded via send_update (must come before general update)
  def update(%{contacts_loaded: contacts} = assigns, socket) when is_list(contacts) do
    # Merge new assigns with existing socket assigns
    socket = assign(socket, assigns)

    # Update the specific fields we care about
    socket =
      socket
      |> assign(:all_contacts, contacts)
      |> assign(:contacts_loaded, true)
      |> assign(:loading, false)
      # Show all contacts in the select/search dropdown initially
      |> assign(:search_results, contacts)

    {:ok, socket}
  end

  # Handle update when contact loading failed (must come before general update)
  def update(%{contacts_load_failed: _reason} = assigns, socket) do
    Logger.error("Failed to load contacts: #{inspect(assigns.contacts_load_failed)}")

    # Merge new assigns with existing socket assigns
    socket = assign(socket, assigns)

    # Update the specific fields we care about
    socket =
      socket
      |> assign(:all_contacts, [])
      |> assign(:contacts_loaded, true)
      |> assign(:loading, false)

    {:ok, put_flash(socket, :error, "Failed to load contacts from HubSpot.")}
  end

  # General update function (must come last)
  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:loading, fn -> false end)
      |> assign_new(:search_query, fn -> "" end)
      |> assign_new(:search_results, fn -> [] end)
      |> assign_new(:all_contacts, fn -> [] end)
      |> assign_new(:contacts_loaded, fn -> false end)
      |> assign_new(:selected_contact, fn -> nil end)
      |> assign_new(:contact_properties, fn -> %{} end)
      |> assign_new(:suggested_updates, fn -> [] end)
      |> assign_new(:selected_updates, fn -> %{} end)
      |> assign_new(:updating, fn -> false end)

    # If contacts haven't been loaded yet, fetch all contacts asynchronously
    socket = if not socket.assigns[:contacts_loaded] do
      socket = assign(socket, :loading, true)

      # Capture component ID and parent PID for sending updates
      # Safely get meeting ID - it should exist but handle gracefully if not
      component_id = socket.assigns[:id] ||
                     (if Map.has_key?(socket.assigns, :meeting) && socket.assigns.meeting do
                       "hubspot-update-#{socket.assigns.meeting.id}"
                     else
                       "hubspot-update-unknown"
                     end)
      parent_pid = self()
      current_user = socket.assigns.current_user

      # Load contacts in a Task to avoid blocking
      Task.start(fn ->
        case get_hubspot_credential(current_user) do
          {:ok, credential} ->
            case HubSpot.list_all_contacts(credential.token, 100) do
              {:ok, contacts} ->
                Logger.info("Loaded #{length(contacts)} contacts from HubSpot")
                # Send update to the component via the parent
                send(parent_pid, {:update_component, component_id, {:contacts_loaded, contacts}})

              {:error, reason} ->
                Logger.error("Failed to load contacts: #{inspect(reason)}")
                send(parent_pid, {:update_component, component_id, {:contacts_load_failed, reason}})
            end

          {:error, reason} ->
            Logger.error("HubSpot credential error when loading contacts: #{inspect(reason)}")
            send(parent_pid, {:update_component, component_id, {:contacts_load_failed, reason}})
        end
      end)

      socket
    else
      socket
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("search_contacts", %{"query" => query}, socket) do
    query = String.trim(query || "")
    Logger.info("Search contacts called with query: '#{query}' (filtering from #{length(socket.assigns.all_contacts)} loaded contacts)")

    # Filter contacts client-side from the pre-loaded list
    filtered_contacts =
      if String.length(query) >= 1 do
        query_lower = String.downcase(query)
        all_contacts = socket.assigns.all_contacts || []

        Enum.filter(all_contacts, fn contact ->
          firstname = String.downcase(contact.firstname || "")
          lastname = String.downcase(contact.lastname || "")
          email = String.downcase(contact.email || "")
          full_name = "#{firstname} #{lastname}" |> String.trim() |> String.downcase()

          String.contains?(firstname, query_lower) ||
            String.contains?(lastname, query_lower) ||
            String.contains?(email, query_lower) ||
            String.contains?(full_name, query_lower)
        end)
        |> Enum.take(10)  # Limit to 10 results for display
      else
        # When the query is empty, show all contacts so the user can pick without typing
        socket.assigns.all_contacts || []
      end

    Logger.info("Filtered to #{length(filtered_contacts)} contacts matching '#{query}'")

    {:noreply,
     socket
     |> assign(:search_results, filtered_contacts)
     |> assign(:search_query, query)}
  end

  def handle_event("search_contacts", params, socket) do
    Logger.warning("Unexpected search_contacts params: #{inspect(params)}")
    {:noreply, socket}
  end

  def handle_event("select_contact", %{"contact_id" => contact_id}, socket) do
    socket = assign(socket, :loading, true)

    case get_hubspot_credential(socket.assigns.current_user) do
      {:ok, credential} ->
        case HubSpot.get_contact(credential.token, contact_id) do
          {:ok, contact} ->
            # HubSpot.get_contact/2 returns a map like %{id: ..., properties: %{...}}
            contact_id_value =
              Map.get(contact, :id) ||
                Map.get(contact, "id")

            properties =
              Map.get(contact, :properties) ||
                Map.get(contact, "properties", %{})

            Logger.debug("HubSpot select_contact raw contact: #{inspect(contact)}")
            Logger.debug("HubSpot select_contact extracted properties: #{inspect(properties)}")

            properties_with_history =
              Map.get(contact, :properties_with_history) ||
                Map.get(contact, "properties_with_history") ||
                Map.get(contact, :propertiesWithHistory) ||
                Map.get(contact, "propertiesWithHistory") ||
                %{}

            associations =
              Map.get(contact, :associations) ||
                Map.get(contact, "associations") ||
                %{}

            companies_assoc =
              Map.get(associations, "companies") ||
                Map.get(associations, :companies) ||
                %{}

            companies_results =
              cond do
                is_list(companies_assoc) ->
                  companies_assoc

                true ->
                  Map.get(companies_assoc, "results") ||
                    Map.get(companies_assoc, :results) ||
                    []
              end

            company_ids =
              companies_results
              |> Enum.map(fn assoc_item ->
                Map.get(assoc_item, "id") || Map.get(assoc_item, :id)
              end)
              |> Enum.filter(& &1)

            associated_companies =
              case HubSpot.get_companies(credential.token, company_ids) do
                {:ok, companies} ->
                  companies

                {:error, reason} ->
                  Logger.error("HubSpot get_companies error: #{inspect(reason)}")
                  []
              end

            deals_assoc =
              Map.get(associations, "deals") ||
                Map.get(associations, :deals) ||
                %{}

            deals_results =
              cond do
                is_list(deals_assoc) ->
                  deals_assoc

                true ->
                  Map.get(deals_assoc, "results") ||
                    Map.get(deals_assoc, :results) ||
                    []
              end

            deal_ids =
              deals_results
              |> Enum.map(fn assoc_item ->
                Map.get(assoc_item, "id") || Map.get(assoc_item, :id)
              end)
              |> Enum.filter(& &1)

            associated_deals =
              case HubSpot.get_deals(credential.token, deal_ids) do
                {:ok, deals} ->
                  deals

                {:error, reason} ->
                  Logger.error("HubSpot get_deals error: #{inspect(reason)}")
                  []
              end

            primary_company =
              case HubSpot.get_primary_company(credential.token, contact_id_value) do
                {:ok, company} when not is_nil(company) ->
                  company

                {:ok, nil} ->
                  List.first(associated_companies)

                {:error, reason} ->
                  Logger.error("HubSpot get_primary_company error: #{inspect(reason)}")
                  List.first(associated_companies)
              end

            hubspot_context = %{
              "contact" => %{
                "id" => contact_id_value,
                "properties" => properties,
                "properties_with_history" => properties_with_history
              },
              "associations" => associations,
              "associated_companies" => associated_companies,
              "primary_company" => primary_company,
              "associated_deals" => associated_deals
            }

            # Flatten contact structure to match search_contacts format
            flattened_contact = %{
              id: contact_id_value,
              firstname: Map.get(properties, "firstname"),
              lastname: Map.get(properties, "lastname"),
              email: Map.get(properties, "email"),
              phone: Map.get(properties, "phone"),
              company: Map.get(properties, "company"),
              jobtitle: Map.get(properties, "jobtitle"),
              lifecyclestage: Map.get(properties, "lifecyclestage")
            }

            # Immediately show the selected contact and start AI generation in the background
            meeting = socket.assigns.meeting
            parent = self()

            Task.start(fn ->
              result = AIContentGeneratorApi.generate_hubspot_updates(meeting, hubspot_context)
              send(parent, {:hubspot_ai_updates_result, result})
            end)

            {:noreply,
             socket
             |> assign(:selected_contact, flattened_contact)
             |> assign(:contact_properties, properties)
             |> assign(:suggested_updates, [])
             |> assign(:selected_updates, %{})
             |> assign(:loading, true)}

          {:error, reason} ->
            Logger.error("HubSpot get contact error: #{inspect(reason)}")
            {:noreply,
             socket
             |> assign(:loading, false)
             |> put_flash(:error, "Failed to load contact details.")}
        end

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> put_flash(:error, "HubSpot account not connected.")}
    end
  end

  def handle_event("toggle_update", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    current_value = Map.get(socket.assigns.selected_updates, idx, false)

    selected_updates = Map.put(socket.assigns.selected_updates, idx, !current_value)

    {:noreply, assign(socket, :selected_updates, selected_updates)}
  end

  def handle_event("toggle_section", %{"section" => section}, socket) do
    # Toggle all updates in a section
    section_updates =
      socket.assigns.suggested_updates
      |> Enum.with_index()
      |> Enum.filter(fn {update, _idx} -> update["property"] == section end)
      |> Enum.map(fn {_update, idx} -> idx end)

    all_selected =
      section_updates
      |> Enum.all?(fn idx -> Map.get(socket.assigns.selected_updates, idx, false) end)

    selected_updates =
      section_updates
      |> Enum.reduce(socket.assigns.selected_updates, fn idx, acc ->
        Map.put(acc, idx, !all_selected)
      end)

    {:noreply, assign(socket, :selected_updates, selected_updates)}
  end

  def handle_event("update_hubspot", _params, socket) do
    socket = assign(socket, :updating, true)

    selected_updates_list =
      socket.assigns.suggested_updates
      |> Enum.with_index()
      |> Enum.filter(fn {_update, idx} -> Map.get(socket.assigns.selected_updates, idx, false) end)
      |> Enum.map(fn {update, _idx} -> update end)

    if Enum.empty?(selected_updates_list) do
      {:noreply,
       socket
       |> assign(:updating, false)
       |> put_flash(:error, "Please select at least one update.")}
    else
      case get_hubspot_credential(socket.assigns.current_user) do
        {:ok, credential} ->
          contact_id = Map.get(socket.assigns.selected_contact, :id)

          properties =
            selected_updates_list
            |> Enum.reduce(%{}, fn update, acc ->
              property = Map.get(update, "property")
              value = Map.get(update, "suggested_value")
              Map.put(acc, property, value)
            end)

          case HubSpot.update_contact(credential.token, contact_id, properties) do
            {:ok, _} ->
              send(self(), {:hubspot_updated, contact_id})

              {:noreply,
               socket
               |> assign(:updating, false)
               |> put_flash(:info, "HubSpot contact updated successfully.")
               |> push_patch(to: socket.assigns.patch)}

            {:error, reason} ->
              Logger.error("HubSpot update error: #{inspect(reason)}")
              {:noreply,
               socket
               |> assign(:updating, false)
               |> put_flash(:error, "Failed to update HubSpot contact.")}
          end

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:updating, false)
           |> put_flash(:error, "HubSpot account not connected.")}
      end
    end
  end

  def handle_event("change_contact", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_contact, nil)
     |> assign(:contact_properties, %{})
     |> assign(:suggested_updates, [])
     |> assign(:selected_updates, %{})
     |> assign(:loading, false)
     # Restore all contacts in the search dropdown so the user can pick again
     |> assign(:search_query, "")
     |> assign(:search_results, socket.assigns.all_contacts || [])}
  end

  defp get_hubspot_credential(user) do
    require Logger

    case Accounts.list_user_credentials(user, provider: "hubspot") do
      [credential | _] ->
        # Check if token needs refresh (expired or expiring within 5 minutes)
        now = DateTime.utc_now()
        expires_at = credential.expires_at || now

        # Refresh if expired or expiring soon (within 5 minutes)
        needs_refresh =
          DateTime.compare(expires_at, now) == :lt ||
          DateTime.diff(expires_at, now, :second) < 300

        if needs_refresh do
          Logger.info("HubSpot token expired or expiring soon, refreshing...")

          if credential.refresh_token do
            alias SocialScribe.HubSpotOAuth

            case HubSpotOAuth.refresh_access_token(credential.refresh_token) do
              {:ok, token_data} ->
                expires_in = Map.get(token_data, "expires_in", 21600) # Default to 6 hours (21600 seconds)
                new_expires_at = DateTime.add(now, expires_in, :second)
                new_access_token = Map.get(token_data, "access_token")
                new_refresh_token = Map.get(token_data, "refresh_token")

                # CRITICAL: HubSpot rotates refresh tokens - we MUST save the new refresh_token
                # If we don't save it, the old refresh_token becomes invalid and we can't refresh again
                # HubSpot ALWAYS returns a new refresh_token when refreshing, so if it's missing, that's an error
                if is_nil(new_refresh_token) or new_refresh_token == "" do
                  Logger.error("⚠️  WARNING: HubSpot refresh did NOT return a new refresh_token!")
                  Logger.error("This should not happen - HubSpot rotates refresh tokens on every refresh")
                  Logger.error("Falling back to existing refresh_token, but this may cause issues on next refresh")
                  new_refresh_token = credential.refresh_token
                end

                Logger.info("HubSpot refresh returned new tokens - saving both access_token and refresh_token")
                Logger.info("New access_token expires in #{expires_in} seconds (#{div(expires_in, 3600)} hours)")
                Logger.info("New refresh_token present: #{!is_nil(new_refresh_token)}")

                case Accounts.update_user_credential(credential, %{
                       token: new_access_token,
                       refresh_token: new_refresh_token,
                       expires_at: new_expires_at
                     }) do
                  {:ok, updated_credential} ->
                    Logger.info("HubSpot token refreshed successfully - both access_token and refresh_token saved")
                    {:ok, updated_credential}

                  {:error, reason} ->
                    Logger.error("Failed to update HubSpot credential: #{inspect(reason)}")
                    {:error, :token_refresh_failed}
                end

              {:error, reason} ->
                Logger.error("HubSpot token refresh failed: #{inspect(reason)}")
                {:error, :token_refresh_failed}
            end
          else
            Logger.error("Cannot refresh HubSpot token: refresh_token is missing")
            {:error, :no_refresh_token}
          end
        else
          {:ok, credential}
        end

      [] ->
        {:error, :no_credential}
    end
  end

  def format_contact_name(contact) do
    firstname = Map.get(contact, :firstname, "")
    lastname = Map.get(contact, :lastname, "")
    email = Map.get(contact, :email, "")

    cond do
      firstname != "" && lastname != "" -> "#{firstname} #{lastname}"
      firstname != "" -> firstname
      email != "" -> email
      true -> "Contact ##{Map.get(contact, :id)}"
    end
  end

  defp get_property_display_name(property) do
    case property do
      "firstname" -> "First name"
      "lastname" -> "Last name"
      "email" -> "Email"
      "phone" -> "Phone"
      "mobilephone" -> "Mobile phone"
      "company" -> "Company"
      "jobtitle" -> "Job title"
      "lifecyclestage" -> "Lifecycle stage"
      "address" -> "Address"
      "city" -> "City"
      "state" -> "State"
      "zip" -> "ZIP"
      "country" -> "Country"
      "website" -> "Website"
      _ -> String.replace(property, "_", " ") |> String.capitalize()
    end
  end

  defp group_updates_by_property(updates) do
    updates
    |> Enum.with_index()
    |> Enum.group_by(fn {update, _idx} -> update["property"] end)
    |> Enum.map(fn {property, items} ->
      {property, Enum.map(items, fn {update, idx} -> {update, idx} end)}
    end)
  end

  defp count_selected_updates(selected_updates, indices) do
    indices
    |> Enum.count(fn idx -> Map.get(selected_updates, idx, false) end)
  end

  defp get_total_selected_count(selected_updates, updates) do
    updates
    |> Enum.with_index()
    |> Enum.count(fn {_update, idx} -> Map.get(selected_updates, idx, false) end)
  end
end
