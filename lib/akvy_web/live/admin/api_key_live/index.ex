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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:api_keys}>
      <.page_header
        title="API keys"
        subtitle="Client applications authenticate with Authorization: Bearer <key>"
      />

      <div
        :if={@new_key}
        id="new-api-key"
        class="mb-6 rounded-2xl border border-success/30 bg-success/5 p-5"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <p class="font-medium">Copy the new key now — it will not be shown again.</p>
            <code
              id="new-api-key-value"
              class="mt-3 block select-all break-all rounded-lg bg-base-100 px-3 py-2 font-mono text-sm"
            >
              {@new_key}
            </code>
          </div>
          <button phx-click="dismiss_key" class="text-base-content/50 hover:text-base-content">
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
      </div>

      <.card title="Create key" class="mb-6">
        <.form
          for={@form}
          id="api-key-form"
          phx-change="validate"
          phx-submit="create"
          class="flex flex-wrap items-start gap-3 p-5"
        >
          <div class="min-w-64 flex-1">
            <.input field={@form[:name]} placeholder="Name, e.g. mobile-backend" />
          </div>
          <button
            id="create-api-key"
            type="submit"
            phx-disable-with="Creating…"
            class="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110 active:scale-[.98]"
          >
            Create key
          </button>
        </.form>
      </.card>

      <.card class="overflow-hidden">
        <.empty_state :if={@empty?} id="api-keys-empty" icon="hero-key" title="No API keys yet" />
        <table :if={!@empty?} class="w-full text-sm">
          <thead class="bg-base-200/50 text-xs text-base-content/50">
            <tr>
              <th class="px-5 py-2.5 text-left font-medium">Name</th>
              <th class="px-3 py-2.5 text-left font-medium">Key</th>
              <th class="px-3 py-2.5 text-left font-medium">Created</th>
              <th class="px-3 py-2.5 text-left font-medium">Last used</th>
              <th class="px-5 py-2.5 text-right font-medium"></th>
            </tr>
          </thead>
          <tbody id="api-keys" phx-update="stream">
            <tr
              :for={{dom_id, key} <- @streams.api_keys}
              id={dom_id}
              class={["border-t border-base-200", key.revoked_at && "opacity-50"]}
            >
              <td class="px-5 py-3 font-medium">{key.name}</td>
              <td class="px-3 py-3 font-mono text-xs">{key.prefix}…</td>
              <td class="px-3 py-3 text-base-content/60">{format_dt(key.inserted_at)}</td>
              <td class="px-3 py-3 text-base-content/60">{format_relative(key.last_used_at)}</td>
              <td class="px-5 py-3 text-right">
                <span :if={key.revoked_at} class="text-xs text-base-content/50">revoked</span>
                <button
                  :if={!key.revoked_at}
                  id={"revoke-#{key.id}"}
                  phx-click="revoke"
                  phx-value-id={key.id}
                  data-confirm="Revoke this key? Clients using it will stop working."
                  class="rounded-md px-2 py-1 text-xs font-medium text-error transition hover:bg-error/10"
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </Layouts.app>
    """
  end
end
