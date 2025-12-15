defmodule SocialScribe.HubSpot do
  @moduledoc """
  HubSpot API implementation.
  """
  @behaviour SocialScribe.HubSpotApi

  @base_url "https://api.hubapi.com"

  defp client(token) do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @base_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Bearer #{token}"},
         {"Content-Type", "application/json"}
       ]}
    ])
  end

  @impl SocialScribe.HubSpotApi
  def search_contacts(token, query) do
    require Logger

    # Normalize query
    normalized_query = String.trim(query)
    capitalized_query =
      if String.length(normalized_query) > 0 do
        # Capitalize first letter, keep rest as-is
        String.capitalize(normalized_query)
      else
        normalized_query
      end

    # If query looks like an email, try to get contact directly first (more reliable)
    if String.contains?(normalized_query, "@") do
      case get_contact_by_email(token, normalized_query) do
        {:ok, contact} ->
          # Convert to search result format
          properties = Map.get(contact, :properties, %{})
          formatted_contact = %{
            id: Map.get(contact, :id),
            firstname: Map.get(properties, :firstname),
            lastname: Map.get(properties, :lastname),
            email: Map.get(properties, :email),
            phone: Map.get(properties, :phone),
            company: Map.get(properties, :company),
            jobtitle: Map.get(properties, :jobtitle),
            lifecyclestage: Map.get(properties, :lifecyclestage)
          }
          Logger.info("Found contact by direct email lookup: #{formatted_contact.email}")
          {:ok, [formatted_contact]}
        {:error, _} ->
          # Fall through to search API
          search_with_api(token, normalized_query, capitalized_query)
      end
    else
      search_with_api(token, normalized_query, capitalized_query)
    end
  end

  # Helper function for API search
  defp search_with_api(token, normalized_query, capitalized_query) do
    require Logger

    # HubSpot allows max 5 filterGroups - use most effective combinations
    # Each filterGroup is ORed together
    body = %{
      filterGroups: [
        # 1. Email search (CONTAINS_TOKEN works for emails)
        %{
          filters: [
            %{
              propertyName: "email",
              operator: "CONTAINS_TOKEN",
              value: normalized_query
            }
          ]
        },
        # 2. Exact match on firstname (capitalized)
        %{
          filters: [
            %{
              propertyName: "firstname",
              operator: "EQ",
              value: capitalized_query
            }
          ]
        },
        # 3. Exact match on firstname (as typed)
        %{
          filters: [
            %{
              propertyName: "firstname",
              operator: "EQ",
              value: normalized_query
            }
          ]
        },
        # 4. Exact match on lastname (capitalized)
        %{
          filters: [
            %{
              propertyName: "lastname",
              operator: "EQ",
              value: capitalized_query
            }
          ]
        },
        # 5. CONTAINS_TOKEN on firstname (for partial matches)
        %{
          filters: [
            %{
              propertyName: "firstname",
              operator: "CONTAINS_TOKEN",
              value: normalized_query
            }
          ]
        }
      ],
      properties: [
        "firstname",
        "lastname",
        "email",
        "phone",
        "company",
        "jobtitle",
        "lifecyclestage",
        "hubspot_owner_id"
      ],
      limit: 10
    }

    Logger.info("Searching HubSpot contacts with query: '#{normalized_query}'")
    Logger.debug("Search request body: #{inspect(body)}")

    case Tesla.post(client(token), "/crm/v3/objects/contacts/search", body) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        # HubSpot JSON keys are strings ("results", "properties", etc.)
        results = Map.get(response_body, "results", [])
        Logger.info("HubSpot search API returned #{length(results)} results")

        contacts =
          results
          |> Enum.map(fn contact ->
            properties = Map.get(contact, "properties", %{})
            %{
              id: Map.get(contact, "id"),
              firstname: Map.get(properties, "firstname"),
              lastname: Map.get(properties, "lastname"),
              email: Map.get(properties, "email"),
              phone: Map.get(properties, "phone"),
              company: Map.get(properties, "company"),
              jobtitle: Map.get(properties, "jobtitle"),
              lifecyclestage: Map.get(properties, "lifecyclestage")
            }
          end)

        Logger.debug("Processed contacts: #{inspect(Enum.map(contacts, fn c -> %{id: c.id, email: c.email} end))}")

        # If search returns 0 results, ALWAYS try fallback: list all contacts and filter client-side
        # HubSpot search API can be unreliable, so this ensures we find contacts
        if Enum.empty?(contacts) && String.length(normalized_query) >= 2 do
          Logger.info("Search returned 0 results, using fallback: list all contacts and filter client-side")
          try_list_and_filter(token, normalized_query, capitalized_query)
        else
          {:ok, contacts}
        end

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("HubSpot API error: status #{status}, body: #{inspect(error_body)}")
        {:error, {status, error_body}}

      {:error, reason} ->
        Logger.error("HubSpot API request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Fallback: List recent contacts and filter client-side
  # This helps when HubSpot search indexing is delayed
  defp try_list_and_filter(token, normalized_query, _capitalized_query) do
    require Logger

    # Get recent contacts (last 100)
    properties = "firstname,lastname,email,phone,company,jobtitle,lifecyclestage"

    case Tesla.get(client(token), "/crm/v3/objects/contacts?properties=#{properties}&limit=100") do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        # HubSpot JSON keys are strings ("results", "properties", etc.)
        all_contacts = Map.get(response_body, "results", [])
        Logger.info("Retrieved #{length(all_contacts)} contacts for client-side filtering")
        Logger.debug("Raw contacts response (first contact): #{inspect(List.first(all_contacts))}")

        # Filter contacts client-side
        query_lower = String.downcase(normalized_query)
        matching_contacts =
          all_contacts
          |> Enum.filter(fn contact ->
            props = Map.get(contact, "properties", %{})
            firstname = String.downcase(Map.get(props, "firstname", "") || "")
            lastname = String.downcase(Map.get(props, "lastname", "") || "")
            email = String.downcase(Map.get(props, "email", "") || "")

            String.contains?(firstname, query_lower) ||
              String.contains?(lastname, query_lower) ||
              String.contains?(email, query_lower)
          end)
          |> Enum.take(10)  # Limit to 10 results
          |> Enum.map(fn contact ->
            properties = Map.get(contact, "properties", %{})
            %{
              id: Map.get(contact, "id"),
              firstname: Map.get(properties, "firstname"),
              lastname: Map.get(properties, "lastname"),
              email: Map.get(properties, "email"),
              phone: Map.get(properties, "phone"),
              company: Map.get(properties, "company"),
              jobtitle: Map.get(properties, "jobtitle"),
              lifecyclestage: Map.get(properties, "lifecyclestage")
            }
          end)

        Logger.info("Found #{length(matching_contacts)} matching contacts via client-side filtering")
        {:ok, matching_contacts}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("Fallback list contacts error: status #{status}, body: #{inspect(error_body)}")
        {:ok, []}  # Return empty list instead of error

      {:error, reason} ->
        Logger.error("Fallback list contacts HTTP error: #{inspect(reason)}")
        {:ok, []}  # Return empty list instead of error
    end
  end

  # Helper to get contact by email directly (more reliable than search)
  defp get_contact_by_email(token, email) do
    properties = [
      "firstname",
      "lastname",
      "email",
      "phone",
      "company",
      "jobtitle",
      "lifecyclestage"
    ]

    query_string = "properties=#{Enum.join(properties, ",")}"
    encoded_email = URI.encode(email)

    case Tesla.get(client(token), "/crm/v3/objects/contacts/#{encoded_email}?idProperty=email&#{query_string}") do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        properties = Map.get(response_body, :properties, %{})
        contact = %{
          id: Map.get(response_body, :id),
          properties: properties
        }
        {:ok, contact}

      {:ok, %Tesla.Env{status: 404}} ->
        {:error, :not_found}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {status, error_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl SocialScribe.HubSpotApi
  def get_contact(token, contact_id) do
    # Request a broad set of standard contact properties so the AI can
    # reason about more than just basic name/phone/email. Custom
    # properties will also flow through when present in the response.
    properties = [
      # Identity & basic
      "firstname",
      "lastname",
      "email",
      "phone",
      "mobilephone",
      "fax",

      # Company / job
      "company",
      "jobtitle",
      "industry",

      # Address
      "address",
      "city",
      "state",
      "zip",
      "country",

      # Web / misc
      "website",
      "timezone",

      # Lifecycle & CRM metadata
      "lifecyclestage",
      "hs_lead_status",
      "hubspot_owner_id"
    ]

    properties_with_history = [
      "lifecyclestage",
      "hs_lead_status"
    ]

    associations = [
      "companies",
      "deals"
    ]

    query_params = [
      "properties=#{Enum.join(properties, ",")}",
      "propertiesWithHistory=#{Enum.join(properties_with_history, ",")}",
      "associations=#{Enum.join(associations, ",")}"
    ]

    query_string = Enum.join(query_params, "&")

    case Tesla.get(client(token), "/crm/v3/objects/contacts/#{contact_id}?#{query_string}") do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        # HubSpot JSON keys are typically strings, but be robust to atoms as well
        require Logger

        Logger.debug("HubSpot get_contact raw response: #{inspect(response_body)}")

        properties =
          Map.get(response_body, "properties") ||
            Map.get(response_body, :properties, %{})

        id =
          Map.get(response_body, "id") ||
            Map.get(response_body, :id)

        properties_with_history_response =
          Map.get(response_body, "propertiesWithHistory") ||
            Map.get(response_body, :propertiesWithHistory) ||
            %{}

        associations_response =
          Map.get(response_body, "associations") ||
            Map.get(response_body, :associations) ||
            %{}

        Logger.debug("HubSpot get_contact extracted properties: #{inspect(properties)}")

        contact = %{
          id: id,
          properties: properties,
          properties_with_history: properties_with_history_response,
          associations: associations_response
        }

        {:ok, contact}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {status, error_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl SocialScribe.HubSpotApi
  def update_contact(token, contact_id, properties) do
    body = %{
      properties: properties
    }

    case Tesla.patch(client(token), "/crm/v3/objects/contacts/#{contact_id}", body) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {status, error_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_companies(token, company_ids) when is_list(company_ids) do
    require Logger

    properties = [
      "name",
      "domain",
      "industry",
      "address",
      "city",
      "state",
      "zip",
      "country",
      "hs_num_employees",
      "numberofemployees",
      "annualrevenue"
    ]

    if Enum.empty?(company_ids) do
      {:ok, []}
    else
      properties_string = Enum.join(properties, ",")

      companies =
        company_ids
        |> Enum.uniq()
        |> Enum.map(fn company_id ->
          case Tesla.get(client(token), "/crm/v3/objects/companies/#{company_id}?properties=#{properties_string}") do
            {:ok, %Tesla.Env{status: 200, body: response_body}} ->
              props =
                Map.get(response_body, "properties") ||
                  Map.get(response_body, :properties, %{})

              id =
                Map.get(response_body, "id") ||
                  Map.get(response_body, :id)

              %{
                "id" => id,
                "properties" => props
              }

            {:ok, %Tesla.Env{status: status, body: error_body}} ->
              Logger.error("HubSpot get_companies error for #{company_id}: status=#{status}, body=#{inspect(error_body)}")
              nil

            {:error, reason} ->
              Logger.error("HubSpot get_companies HTTP error for #{company_id}: #{inspect(reason)}")
              nil
          end
        end)
        |> Enum.filter(& &1)

      {:ok, companies}
    end
  end

  def get_deals(token, deal_ids) when is_list(deal_ids) do
    properties = [
      "dealname",
      "amount",
      "dealstage",
      "pipeline",
      "closedate",
      "hs_lastmodifieddate",
      "hubspot_owner_id",
      "dealtype"
    ]

    if Enum.empty?(deal_ids) do
      {:ok, []}
    else
      properties_string = Enum.join(properties, ",")

      deals =
        deal_ids
        |> Enum.uniq()
        |> Enum.map(fn deal_id ->
          case Tesla.get(client(token), "/crm/v3/objects/deals/#{deal_id}?properties=#{properties_string}") do
            {:ok, %Tesla.Env{status: 200, body: response_body}} ->
              props =
                Map.get(response_body, "properties") ||
                  Map.get(response_body, :properties, %{})

              id =
                Map.get(response_body, "id") ||
                  Map.get(response_body, :id)

              %{
                "id" => id,
                "properties" => props
              }

            _ ->
              nil
          end
        end)
        |> Enum.filter(& &1)

      {:ok, deals}
    end
  end

  def get_primary_company(token, contact_id) do
    require Logger

    case Tesla.get(client(token), "/crm/v4/objects/contacts/#{contact_id}/associations/companies") do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        results =
          Map.get(body, "results") ||
            Map.get(body, :results) ||
            []

        primary_id =
          results
          |> Enum.find_value(fn assoc ->
            assoc_types =
              Map.get(assoc, "associationTypes") ||
                Map.get(assoc, :associationTypes) ||
                []

            has_primary_label =
              Enum.any?(assoc_types, fn t ->
                type_id = Map.get(t, "typeId") || Map.get(t, :typeId)
                label = Map.get(t, "label") || Map.get(t, :label) || ""

                type_id == 1 || String.downcase(to_string(label)) == "primary"
              end)

            if has_primary_label do
              Map.get(assoc, "toObjectId") || Map.get(assoc, :toObjectId)
            else
              nil
            end
          end)

        case primary_id do
          nil ->
            {:ok, nil}

          id ->
            id_str = to_string(id)

            case get_companies(token, [id_str]) do
              {:ok, [company | _]} -> {:ok, company}
              {:ok, []} -> {:ok, nil}
            end
        end

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("HubSpot get_primary_company associations error for contact #{contact_id}: status=#{status}, body=#{inspect(error_body)}")
        {:error, {status, error_body}}

      {:error, reason} ->
        Logger.error("HubSpot get_primary_company HTTP error for contact #{contact_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl SocialScribe.HubSpotApi
  def list_all_contacts(token, limit \\ 100) do
    require Logger

    properties = [
      "firstname",
      "lastname",
      "email",
      "phone",
      "company",
      "jobtitle",
      "lifecyclestage"
    ]

    properties_string = Enum.join(properties, ",")

    Logger.info("Fetching all HubSpot contacts (limit: #{limit})")

    case Tesla.get(client(token), "/crm/v3/objects/contacts?properties=#{properties_string}&limit=#{limit}") do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        # HubSpot JSON keys are strings
        all_contacts = Map.get(response_body, "results", [])
        total = Map.get(response_body, "total", length(all_contacts))

        Logger.info("Retrieved #{length(all_contacts)} contacts (total in account: #{total})")
        Logger.debug("Raw list_all_contacts first contact: #{inspect(List.first(all_contacts))}")

        contacts =
          all_contacts
          |> Enum.map(fn contact ->
            properties = Map.get(contact, "properties", %{})
            %{
              id: Map.get(contact, "id"),
              firstname: Map.get(properties, "firstname"),
              lastname: Map.get(properties, "lastname"),
              email: Map.get(properties, "email"),
              phone: Map.get(properties, "phone"),
              company: Map.get(properties, "company"),
              jobtitle: Map.get(properties, "jobtitle"),
              lifecyclestage: Map.get(properties, "lifecyclestage")
            }
          end)

        {:ok, contacts}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("HubSpot list contacts error: status #{status}, body: #{inspect(error_body)}")
        {:error, {status, error_body}}

      {:error, reason} ->
        Logger.error("HubSpot list contacts HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
