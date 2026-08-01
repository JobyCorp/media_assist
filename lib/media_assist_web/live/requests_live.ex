defmodule MediaAssistWeb.RequestsLive do
  @moduledoc """
  `/requests` — the household request queue. Every request row shows who
  asked, when, and where it is in the pipeline (`pending → added |
  failed`); statuses flip live via PubSub as the add worker runs. Failed
  requests can be retried, any row removed (removal never undoes an arr
  add).

  Below the queue, the SABnzbd download queue closes the loop —
  requested titles visibly downloading — polled every 10s while the page
  is open.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Integrations
  alias MediaAssist.Requests
  alias MediaAssistWeb.CompositeComponents

  @sab_poll_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Requests.subscribe()
      send(self(), :poll_sab)
    end

    {:ok,
     assign(socket,
       page_title: "requests",
       requests: Requests.list_recent_requests(50),
       sab_queue: nil,
       sab_state: :loading
     )}
  end

  @impl true
  def handle_info({:request_updated, _request}, socket) do
    {:noreply, assign(socket, :requests, Requests.list_recent_requests(50))}
  end

  def handle_info(:poll_sab, socket) do
    if connected?(socket), do: Process.send_after(self(), :poll_sab, @sab_poll_ms)

    case Integrations.sab_queue() do
      {:ok, slots} -> {:noreply, assign(socket, sab_queue: slots, sab_state: :ok)}
      {:error, reason} -> {:noreply, assign(socket, sab_state: {:error, reason})}
    end
  end

  @impl true
  def handle_event("retry", %{"id" => id}, socket) do
    request = Requests.get_request!(id)

    case Requests.retry_request(request) do
      {:ok, request} ->
        {:noreply, put_flash(socket, :info, "Retrying #{request.title}.")}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    {:ok, request} = Requests.delete_request(Requests.get_request!(id))
    {:noreply, put_flash(socket, :info, "Removed request for #{request.title}.")}
  end

  defp requester(request) do
    case request.user do
      nil -> "removed user"
      user -> user.emby_user_name || user.email |> String.split("@") |> hd()
    end
  end

  defp status_class("pending"), do: "text-base-content/50"
  defp status_class("added"), do: "text-primary"
  defp status_class("failed"), do: "text-error"

  defp status_glyph("pending"), do: "◌"
  defp status_glyph("added"), do: "✓"
  defp status_glyph("failed"), do: "✗"

  defp sab_comment(:loading), do: "querying sabnzbd…"
  defp sab_comment(:ok), do: "live from sabnzbd, refreshed every 10s"

  defp sab_comment({:error, :no_sabnzbd_connection}),
    do: "add a sabnzbd connection in settings to see downloads here"

  defp sab_comment({:error, reason}), do: "sabnzbd unavailable (#{inspect(reason)})"

  defp meter(percentage) do
    filled = round(percentage / 10)
    String.duplicate("▓", filled) <> String.duplicate("░", 10 - filled)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="requests">
      <main class="mx-auto w-full max-w-5xl space-y-10 px-4 py-8 sm:px-6">
        <header class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
          <h1 class="text-lg font-semibold">~/requests</h1>
          <p class="text-xs text-base-content/40">
            find something new under
            <.link navigate={~p"/discover"} class="text-primary/80 hover:text-primary">
              3:discover
            </.link>
          </p>
        </header>

        <section class="space-y-4">
          <CompositeComponents.command_header command="requests --all-users" tone="accent">
            <:comment>auto-approved for now — statuses update live as the add worker runs</:comment>
          </CompositeComponents.command_header>

          <CompositeComponents.empty_state
            :if={@requests == []}
            icon="hero-inbox"
            title="No requests yet"
          >
            Request anything from the discover page — it lands here with a live status.
          </CompositeComponents.empty_state>

          <ul
            :if={@requests != []}
            class="divide-y divide-base-content/10 border border-base-content/10 bg-base-200 text-sm"
          >
            <li
              :for={request <- @requests}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2.5"
            >
              <span class={["select-none", status_class(request.status)]}>
                {status_glyph(request.status)}
              </span>
              <span class="min-w-0 flex-1 truncate">
                <span class="font-medium">{request.title}</span>
                <span :if={request.year} class="text-base-content/50"> ({request.year})</span>
                <span class="bg-base-300 px-1.5 py-0.5 text-xs text-base-content/70">
                  {request.kind}
                </span>
              </span>
              <span class="text-xs text-base-content/50">
                by <span class="text-accent">{requester(request)}</span>
              </span>
              <span class="text-xs text-base-content/40">
                {Calendar.strftime(request.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
              <span class={["text-xs", status_class(request.status)]}>{request.status}</span>
              <span
                :if={request.status == "failed" && request.error}
                class="w-full truncate pl-8 text-xs text-error/70"
                title={request.error}
              >
                {request.error}
              </span>
              <.button
                :if={request.status == "failed"}
                size="sm"
                phx-click="retry"
                phx-value-id={request.id}
                phx-disable-with="…"
              >
                retry
              </.button>
              <.button
                size="sm"
                phx-click="remove"
                phx-value-id={request.id}
                data-confirm={"Remove the request for #{request.title}?" <>
                  if(request.status == "added", do: " The title stays in the arr.", else: "")}
              >
                remove
              </.button>
            </li>
          </ul>
        </section>

        <section class="space-y-4">
          <CompositeComponents.command_header command="sabnzbd queue">
            <:comment>{sab_comment(@sab_state)}</:comment>
          </CompositeComponents.command_header>

          <p :if={@sab_state == :ok && @sab_queue == []} class="text-sm text-base-content/40">
            # queue empty — nothing downloading right now
          </p>

          <ul
            :if={@sab_queue not in [nil, []]}
            class="divide-y divide-base-content/10 border border-base-content/10 bg-base-200 text-sm"
          >
            <li
              :for={slot <- @sab_queue}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2.5"
            >
              <span class="min-w-0 flex-1 truncate font-medium">{slot.name}</span>
              <span class="text-xs text-primary/80">
                {meter(slot.percentage)} {round(slot.percentage)}%
              </span>
              <span class="text-xs text-base-content/50">{slot.status}</span>
              <span :if={slot.timeleft} class="text-xs text-base-content/40">
                eta {slot.timeleft}
              </span>
            </li>
          </ul>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
