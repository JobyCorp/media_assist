# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     MediaAssist.Repo.insert!(%MediaAssist.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# --- Dev admin ---------------------------------------------------------------
# Log in at /users/log-in with admin@media.assist / password.
#
# Inserted directly (not through Accounts.register_user/1) because the dev
# password is intentionally shorter than the 12-char changeset minimum.
# Never runs outside dev.

if Mix.env() == :dev do
  admin_email = "admin@media.assist"

  unless MediaAssist.Repo.get_by(MediaAssist.Accounts.User, email: admin_email) do
    MediaAssist.Repo.insert!(%MediaAssist.Accounts.User{
      email: admin_email,
      hashed_password: Bcrypt.hash_pwd_salt("password"),
      confirmed_at: DateTime.utc_now(:second)
    })

    IO.puts("Seeded dev admin: #{admin_email} / password")
  end
end
