defmodule MediaAssist.Assistant do
  @moduledoc """
  The chat brain behind the riser. Answers questions about the media
  library by retrieval over the vector index: the user's question is
  embedded, the nearest titles become context, and the gateway's chat
  model answers grounded in that context plus the user's recent watches.

  Requests for new content are acknowledged but not yet actionable —
  the requests context is the next feature. Tool-calling replaces the
  static context block when that lands.
  """

  alias MediaAssist.AI.Gateway
  alias MediaAssist.Media

  @context_items 8
  @recent_watches 10
  @transcript_window 12

  @doc """
  Produces the assistant's reply to a transcript. `transcript` is a list
  of `%{role: "user" | "assistant", content: binary}` maps, oldest
  first. Returns `{:ok, text}` or `{:error, reason}`.
  """
  def reply(user_or_nil, transcript) when is_list(transcript) do
    if Gateway.configured?() do
      question = last_user_content(transcript)

      messages =
        [%{"role" => "system", "content" => system_prompt(user_or_nil, question)}] ++
          recent_transcript(transcript)

      case Gateway.chat(messages) do
        {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _rest]}} ->
          {:ok, String.trim(content)}

        {:ok, other} ->
          {:error, {:unexpected_response, other}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  defp last_user_content(transcript) do
    transcript
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} -> content
      _other -> nil
    end)
  end

  defp recent_transcript(transcript) do
    transcript
    |> Enum.take(-@transcript_window)
    |> Enum.map(fn %{role: role, content: content} ->
      %{"role" => role, "content" => content}
    end)
  end

  defp system_prompt(user, question) do
    stats = Media.stats()

    """
    You are media_assist, the terminal assistant for a household's self-hosted \
    media server (Radarr, Sonarr, SABnzbd, Emby behind an arrstack).

    Style: plain text only — no markdown headings or bold. Be concise and \
    concrete, like good CLI output. Reference titles by name and year.

    Library: #{stats.movies} movies, #{stats.series} series, all indexed with \
    embeddings.

    #{user_block(user)}
    #{context_block(question)}
    If the user asks to add, download, or request a title, tell them requests \
    aren't wired up yet and will land under 2:requests soon.
    If the answer isn't supported by the library context above, say so rather \
    than inventing library contents.
    """
  end

  defp user_block(nil), do: "The current user is browsing as a guest.\n"

  defp user_block(user) do
    case Media.list_watched_items(user, limit: @recent_watches) do
      [] ->
        "The current user has no watch history yet.\n"

      watched ->
        titles =
          Enum.map_join(watched, "\n", fn {watch, item} ->
            markers =
              [
                watch.play_count > 1 && "×#{watch.play_count}",
                watch.favorite && "favorite",
                watch.liked == false && "disliked"
              ]
              |> Enum.filter(& &1)

            "- #{item.title} (#{item.year}, #{item.kind})" <>
              if(markers == [], do: "", else: " [#{Enum.join(markers, ", ")}]")
          end)

        "The current user's recent watches, newest first:\n#{titles}\n"
    end
  end

  defp context_block(""), do: ""

  defp context_block(question) do
    with {:ok, %{"data" => [%{"embedding" => vector} | _rest]}} <- Gateway.embed(question),
         items when items != [] <- Media.nearest_to_vector(vector, limit: @context_items) do
      lines =
        Enum.map_join(items, "\n", fn item ->
          "- #{item.title} (#{item.year}, #{item.kind}, #{item.status}, " <>
            "#{Enum.join(item.genres, "/")}) — #{snippet(item.overview)}"
        end)

      "Library titles most relevant to the question:\n#{lines}\n"
    else
      # Retrieval is best-effort: answer without context rather than fail.
      _no_context -> ""
    end
  end

  defp snippet(nil), do: "no overview"
  defp snippet(overview), do: overview |> String.slice(0, 180) |> String.replace("\n", " ")
end
