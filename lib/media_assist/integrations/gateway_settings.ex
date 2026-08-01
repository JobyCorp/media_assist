defmodule MediaAssist.Integrations.GatewaySettings do
  @moduledoc """
  Singleton row: how to reach the airo AI gateway. The token is encrypted
  at rest. `chat_model` / `embedding_model` are airo aliases (or concrete
  deployment ids) — the gateway resolves both.
  """

  use MediaAssist.Schema
  import Ecto.Changeset

  schema "gateway_settings" do
    field :base_url, :string
    field :token, MediaAssist.Encrypted.Binary, redact: true
    field :chat_model, :string, default: "chat"
    field :embedding_model, :string, default: "embed"
    field :enabled, :boolean, default: false

    timestamps()
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:base_url, :token, :chat_model, :embedding_model, :enabled])
    |> validate_required([:chat_model, :embedding_model])
    |> validate_base_url()
    |> validate_enabled_requires_config()
  end

  defp validate_base_url(changeset) do
    validate_format(changeset, :base_url, ~r{^https?://\S+$},
      message: "must be an http(s) URL, e.g. http://airo.internal:4000"
    )
  end

  defp validate_enabled_requires_config(changeset) do
    if get_field(changeset, :enabled) do
      changeset
      |> validate_required([:base_url, :token],
        message: "is required before the gateway can be enabled"
      )
    else
      changeset
    end
  end
end
