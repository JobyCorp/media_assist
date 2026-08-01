defmodule MediaAssist.AI.Gateway do
  @moduledoc """
  The app's single door to the airo gateway. Wraps `AiroClient` with the
  DB-stored `Integrations.GatewaySettings` (base URL + encrypted token),
  so nothing else in the app touches airo config directly.

  Every call returns `{:error, :not_configured}` when the gateway is
  disabled or incomplete — callers degrade gracefully instead of raising.
  """

  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.GatewaySettings

  @doc """
  Chat completion through the gateway's configured chat model.

  `thinking: false` suppresses reasoning-mode generation on models that
  default to it (a llama.cpp `chat_template_kwargs`-ism; other backends
  ignore it harmlessly). Use it for extraction-shaped calls where the
  answer is short and reasoning tokens dominate latency.
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    with {:ok, settings} <- configured() do
      params = %{
        "model" => Keyword.get(opts, :model, settings.chat_model),
        "messages" => messages
      }

      params =
        if Keyword.get(opts, :thinking, true),
          do: params,
          else: Map.put(params, "chat_template_kwargs", %{"enable_thinking" => false})

      AiroClient.chat(params, client_opts(settings))
    end
  end

  @doc "Embeds a string or list of strings with the configured embedding model."
  def embed(input, opts \\ []) do
    with {:ok, settings} <- configured() do
      AiroClient.embeddings(
        %{
          "model" => Keyword.get(opts, :model, settings.embedding_model),
          "input" => input
        },
        client_opts(settings)
      )
    end
  end

  @doc "True when the gateway is enabled and fully configured."
  def configured? do
    match?({:ok, _}, configured())
  end

  defp configured do
    case Integrations.get_gateway_settings() do
      %GatewaySettings{enabled: true, base_url: url, token: token} = settings
      when is_binary(url) and is_binary(token) ->
        {:ok, settings}

      _settings ->
        {:error, :not_configured}
    end
  end

  defp client_opts(%GatewaySettings{base_url: url, token: token}) do
    [base_url: url, api_key: token]
  end
end
