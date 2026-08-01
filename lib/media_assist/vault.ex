defmodule MediaAssist.Vault do
  @moduledoc """
  Cloak vault for encrypting secrets at rest (arrstack API keys, the airo
  gateway token). Key comes from the `MediaAssist.Vault` app config —
  static dev/test keys live in `config/{dev,test}.exs`; production reads
  `CLOAK_KEY` in `config/runtime.exs`.
  """
  use Cloak.Vault, otp_app: :media_assist
end

defmodule MediaAssist.Encrypted.Binary do
  @moduledoc "Ecto type for an encrypted string column (`:binary` in the DB)."
  use Cloak.Ecto.Binary, vault: MediaAssist.Vault
end
