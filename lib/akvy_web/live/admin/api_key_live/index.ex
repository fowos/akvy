defmodule AkvyWeb.Admin.ApiKeyLive.Index do
  @moduledoc """
  API key management (`/admin/api-keys`): create, list and revoke keys. The raw key
  is shown once, right after creation.
  """
  use AkvyWeb, :live_view

  alias Akvy.ApiKeys
  alias Akvy.ApiKeys.ApiKey

  @impl true
  def mount(_params, _session, socket) do
    keys = ApiKeys.list_api_keys()

    {:ok,
     socket
     |> assign(page_title: "API keys", new_key: nil, empty?: keys == [])
     |> assign(form: to_form(ApiKeys.change_api_key(%ApiKey{})))
     |> stream(:api_keys, keys)}
  end

  @impl true
  def handle_event("validate", %{"api_key" => params}, socket) do
    changeset = ApiKeys.change_api_key(%ApiKey{}, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("create", %{"api_key" => params}, socket) do
    case ApiKeys.create_api_key(params) do
      {:ok, api_key, raw_key} ->
        {:noreply,
         socket
         |> assign(new_key: raw_key, empty?: false)
         |> assign(form: to_form(ApiKeys.change_api_key(%ApiKey{})))
         |> stream_insert(:api_keys, api_key, at: 0)}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("dismiss_key", _params, socket), do: {:noreply, assign(socket, new_key: nil)}

  def handle_event("revoke", %{"id" => id}, socket) do
    {:ok, api_key} = id |> ApiKeys.get_api_key!() |> ApiKeys.revoke_api_key()
    {:noreply, socket |> put_flash(:info, "Key revoked") |> stream_insert(:api_keys, api_key)}
  end
end
