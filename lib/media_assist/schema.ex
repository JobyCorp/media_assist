defmodule MediaAssist.Schema do
  @moduledoc """
  Base schema for every MediaAssist context. Enforces the app-wide data
  conventions: binary_id primary keys, binary_id foreign keys, and UTC
  timestamps.

  New schemas must use this module instead of `Ecto.Schema` directly:

      defmodule MediaAssist.Library.Movie do
        use MediaAssist.Schema

        schema "movies" do
          field :title, :string
          timestamps()
        end
      end

  Generators are configured with `binary_id: true`, so `mix phx.gen.*`
  output already matches — but hand-written schemas go through here.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
