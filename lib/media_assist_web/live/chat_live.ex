defmodule MediaAssistWeb.ChatLive do
  @moduledoc """
  The chat riser's LiveView, rendered sticky from `Layouts.app` so the
  transcript survives live navigation. Owns the conversation state and
  calls `MediaAssist.Assistant` off the render path via `start_async`.

  Transcript lives in process state — per browser session, not
  persisted. A chat-history context can replace that later.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Accounts
  alias MediaAssist.Assistant

  @impl true
  def mount(:not_mounted_at_router, session, socket) do
    user = session_user(session)

    {:ok,
     assign(socket,
       user: user,
       handle: handle(user),
       messages: [%{role: "system", content: greeting()}],
       busy: false
     )}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    if text == "" or socket.assigns.busy do
      {:noreply, socket}
    else
      messages = socket.assigns.messages ++ [%{role: "user", content: text}]
      transcript = Enum.reject(messages, &(&1.role == "system"))
      user = socket.assigns.user

      {:noreply,
       socket
       |> assign(messages: messages, busy: true)
       |> start_async(:reply, fn -> Assistant.reply(user, transcript) end)}
    end
  end

  @impl true
  def handle_async(:reply, {:ok, result}, socket) do
    message =
      case result do
        {:ok, text} ->
          %{role: "assistant", content: text}

        {:error, :not_configured} ->
          %{
            role: "system",
            content: "gateway offline — configure and enable it under settings/ai-gateway"
          }

        {:error, reason} ->
          %{role: "system", content: "error: #{inspect(reason)}"}
      end

    {:noreply, assign(socket, messages: socket.assigns.messages ++ [message], busy: false)}
  end

  def handle_async(:reply, {:exit, reason}, socket) do
    message = %{role: "system", content: "error: assistant crashed (#{inspect(reason)})"}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [message], busy: false)}
  end

  defp greeting do
    if MediaAssist.AI.Gateway.configured?() do
      "session started — ask about the library, or ask for something to watch"
    else
      "gateway offline — configure it under settings/ai-gateway to chat"
    end
  end

  defp session_user(session) do
    with token when is_binary(token) <- session["user_token"],
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      user
    else
      _guest -> nil
    end
  end

  defp handle(nil), do: "guest"
  defp handle(user), do: user.email |> String.split("@") |> hd()

  @impl true
  def render(assigns) do
    ~H"""
    <MediaAssistWeb.ChatComponents.chat_riser id="chat-riser" handle={@handle} busy={@busy}>
      <:message :for={msg <- @messages} role={msg.role}>{msg.content}</:message>
    </MediaAssistWeb.ChatComponents.chat_riser>
    """
  end
end
