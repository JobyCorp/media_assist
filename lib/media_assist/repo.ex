defmodule MediaAssist.Repo do
  use Ecto.Repo,
    otp_app: :media_assist,
    adapter: Ecto.Adapters.Postgres
end
