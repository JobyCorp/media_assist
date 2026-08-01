defmodule MediaAssistWeb.Router do
  use MediaAssistWeb, :router

  import MediaAssistWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MediaAssistWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug MediaAssistWeb.McpAuth
  end

  scope "/", MediaAssistWeb do
    pipe_through :browser

    live "/design", DesignSystemLive, :index
    live "/custom-designs", CustomDesignsLive, :index
  end

  scope "/" do
    pipe_through :api

    get "/design.json", JobyKit.ManifestController, :show,
      private: %{joby_kit_manifest: MediaAssistWeb.DesignManifest}
  end

  scope "/", MediaAssistWeb do
    pipe_through :mcp

    post "/mcp", McpController, :handle
    get "/mcp", McpController, :method_not_allowed
  end

  if Application.compile_env(:media_assist, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MediaAssistWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", MediaAssistWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{MediaAssistWeb.UserAuth, :require_authenticated}] do
      live "/discover", DiscoverLive, :index
      live "/requests", RequestsLive, :index
      live "/settings", SettingsLive.AiGateway, :index
      live "/settings/ai-gateway", SettingsLive.AiGateway, :index
      live "/settings/connections", SettingsLive.Connections, :index
      live "/settings/index", SettingsLive.Index, :index
      live "/settings/tokens", SettingsLive.Tokens, :index
      live "/users/settings", UserLive.Settings, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", MediaAssistWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{MediaAssistWeb.UserAuth, :mount_current_scope}] do
      live "/", HomeLive, :index
      live "/library", LibraryLive, :index
      live "/library/:id", LibraryItemLive, :show
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
