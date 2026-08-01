defmodule MediaAssist.Integrations do
  @moduledoc """
  Backend service configuration: the airo AI gateway, arrstack
  connections (Radarr / Sonarr / SABnzbd), and media index settings.

  Gateway and index settings are singletons — `get_*` returns the row or
  a default struct, `update_*` upserts it.
  """

  import Ecto.Query, warn: false

  alias MediaAssist.Integrations.ArrClient
  alias MediaAssist.Integrations.Connection
  alias MediaAssist.Integrations.GatewaySettings
  alias MediaAssist.Integrations.IndexSettings
  alias MediaAssist.Repo

  ## AI gateway

  def get_gateway_settings do
    Repo.one(GatewaySettings) || %GatewaySettings{}
  end

  def change_gateway_settings(%GatewaySettings{} = settings, attrs \\ %{}) do
    GatewaySettings.changeset(settings, attrs)
  end

  def update_gateway_settings(attrs) do
    get_gateway_settings()
    |> GatewaySettings.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Lists the gateway's models as a connectivity check. Returns
  `{:ok, model_ids}`, `{:error, :not_configured}`, or the AiroClient
  error tuple.
  """
  def test_gateway(%GatewaySettings{base_url: url, token: token})
      when is_binary(url) and is_binary(token) do
    AiroClient.models(base_url: url, api_key: token, receive_timeout: 10_000)
  end

  def test_gateway(_settings), do: {:error, :not_configured}

  @doc """
  Fetches the gateway's model catalog and buckets ids by capability, for
  the model selects on the settings page. Returns
  `{:ok, %{chat: [...], embeddings: [...]}}`, `{:error, :not_configured}`,
  or the AiroClient error tuple.
  """
  def list_gateway_models(%GatewaySettings{base_url: url, token: token})
      when is_binary(url) and is_binary(token) do
    case AiroClient.model_catalog(base_url: url, api_key: token, receive_timeout: 10_000) do
      {:ok, catalog} ->
        {:ok,
         %{
           chat: ids_with_capability(catalog, "chat"),
           embeddings: ids_with_capability(catalog, "embeddings")
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_gateway_models(_settings), do: {:error, :not_configured}

  defp ids_with_capability(catalog, capability) do
    for %{"id" => id, "capabilities" => capabilities} <- catalog,
        capability in capabilities,
        do: id
  end

  ## Arrstack connections

  def list_connections do
    Repo.all(from c in Connection, order_by: [asc: c.service, asc: c.name])
  end

  def list_connections(service) when is_binary(service) do
    Repo.all(from c in Connection, where: c.service == ^service and c.enabled, order_by: c.name)
  end

  def get_connection!(id), do: Repo.get!(Connection, id)

  def change_connection(%Connection{} = connection, attrs \\ %{}) do
    Connection.changeset(connection, attrs)
  end

  def create_connection(attrs) do
    %Connection{}
    |> Connection.changeset(attrs)
    |> Repo.insert()
  end

  def update_connection(%Connection{} = connection, attrs) do
    connection
    |> Connection.changeset(attrs)
    |> Repo.update()
  end

  def delete_connection(%Connection{} = connection), do: Repo.delete(connection)

  @doc """
  Pings the service behind a connection and records the result on the
  row. Returns `{:ok, connection}` or `{:error, connection, reason}` —
  the connection is updated with the new status either way.
  """
  def check_connection(%Connection{} = connection) do
    case ArrClient.ping(connection) do
      :ok ->
        {:ok, Repo.update!(Connection.status_changeset(connection, "ok"))}

      {:error, reason} ->
        {:error, Repo.update!(Connection.status_changeset(connection, "error")), reason}
    end
  end

  @doc """
  The Emby server's users, from the first enabled emby connection.
  Returns `{:ok, [%{id, name}]}`, `{:error, :no_emby_connection}`, or
  the transport error.
  """
  def list_emby_users do
    case list_connections("emby") do
      [] -> {:error, :no_emby_connection}
      [connection | _rest] -> ArrClient.fetch_emby_users(connection)
    end
  end

  @doc """
  The active SABnzbd download queue, from the first enabled sabnzbd
  connection. `{:ok, slots}`, `{:error, :no_sabnzbd_connection}`, or the
  transport error.
  """
  def sab_queue do
    case list_connections("sabnzbd") do
      [] -> {:error, :no_sabnzbd_connection}
      [connection | _rest] -> ArrClient.fetch_sab_queue(connection)
    end
  end

  ## Index settings

  def get_index_settings do
    Repo.one(IndexSettings) || %IndexSettings{}
  end

  def change_index_settings(%IndexSettings{} = settings, attrs \\ %{}) do
    IndexSettings.changeset(settings, attrs)
  end

  def update_index_settings(attrs) do
    get_index_settings()
    |> IndexSettings.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def mark_synced do
    get_index_settings()
    |> Ecto.Changeset.change(last_synced_at: DateTime.utc_now(:second))
    |> Repo.insert_or_update()
  end
end
