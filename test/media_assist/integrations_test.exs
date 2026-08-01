defmodule MediaAssist.IntegrationsTest do
  use MediaAssist.DataCase, async: true

  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.Connection
  alias MediaAssist.Integrations.GatewaySettings
  alias MediaAssist.Integrations.IndexSettings

  describe "gateway settings" do
    test "get_gateway_settings/0 returns a default struct before first save" do
      assert %GatewaySettings{enabled: false, base_url: nil} = Integrations.get_gateway_settings()
    end

    test "update_gateway_settings/1 upserts the singleton" do
      assert {:ok, saved} =
               Integrations.update_gateway_settings(%{
                 base_url: "http://airo.internal:4000",
                 token: "secret-token"
               })

      assert {:ok, updated} = Integrations.update_gateway_settings(%{enabled: true})
      assert updated.id == saved.id
      assert updated.enabled
      assert updated.token == "secret-token"
      assert MediaAssist.Repo.aggregate(GatewaySettings, :count) == 1
    end

    test "cannot enable the gateway without url and token" do
      assert {:error, changeset} = Integrations.update_gateway_settings(%{enabled: true})
      assert %{base_url: [_], token: [_]} = errors_on(changeset)
    end

    test "token is encrypted at rest" do
      {:ok, saved} = Integrations.update_gateway_settings(%{token: "secret-token"})

      %{rows: [[raw]]} =
        MediaAssist.Repo.query!("SELECT token FROM gateway_settings WHERE id = $1", [
          Ecto.UUID.dump!(saved.id)
        ])

      assert is_binary(raw)
      refute raw == "secret-token"
      assert saved.token == "secret-token"
    end
  end

  describe "connections" do
    @valid %{
      service: "radarr",
      name: "radarr-main",
      base_url: "http://192.168.1.20:7878",
      api_key: "arr-key"
    }

    test "create, list, and delete a connection" do
      assert {:ok, %Connection{} = connection} = Integrations.create_connection(@valid)
      assert connection.status == "unknown"
      assert [%Connection{name: "radarr-main"}] = Integrations.list_connections()

      assert {:ok, _} = Integrations.delete_connection(connection)
      assert Integrations.list_connections() == []
    end

    test "rejects unknown services and duplicate names" do
      assert {:error, changeset} = Integrations.create_connection(%{@valid | service: "lidarr"})
      assert %{service: [_]} = errors_on(changeset)

      assert {:ok, _} = Integrations.create_connection(@valid)
      assert {:error, changeset} = Integrations.create_connection(@valid)
      assert %{name: [_]} = errors_on(changeset)
    end

    test "list_connections/1 returns only enabled connections for a service" do
      {:ok, _} = Integrations.create_connection(@valid)

      {:ok, _} =
        Integrations.create_connection(%{
          @valid
          | name: "radarr-off",
            base_url: "http://192.168.1.21:7878"
        })
        |> then(fn {:ok, c} -> Integrations.update_connection(c, %{enabled: false}) end)

      assert [%Connection{name: "radarr-main"}] = Integrations.list_connections("radarr")
      assert Integrations.list_connections("sonarr") == []
    end
  end

  describe "index settings" do
    test "singleton upsert with interval validation" do
      assert %IndexSettings{sync_interval_minutes: 360} = Integrations.get_index_settings()

      assert {:error, changeset} =
               Integrations.update_index_settings(%{sync_interval_minutes: 42})

      assert %{sync_interval_minutes: [_]} = errors_on(changeset)

      assert {:ok, saved} = Integrations.update_index_settings(%{sync_interval_minutes: 60})
      assert {:ok, updated} = Integrations.update_index_settings(%{sync_movies: false})
      assert updated.id == saved.id
      refute updated.sync_movies
    end

    test "mark_synced/0 stamps last_synced_at" do
      assert {:ok, settings} = Integrations.mark_synced()
      assert settings.last_synced_at
    end
  end
end
