defmodule MediaAssist.AccountsEmbyMappingTest do
  use MediaAssist.DataCase, async: true

  import MediaAssist.AccountsFixtures

  alias MediaAssist.Accounts

  test "map_emby_user/3 sets and clears the mapping" do
    user = user_fixture()

    assert {:ok, mapped} = Accounts.map_emby_user(user, "emby-guid-1", "jody")
    assert mapped.emby_user_id == "emby-guid-1"
    assert mapped.emby_user_name == "jody"

    assert {:ok, unmapped} = Accounts.map_emby_user(mapped, nil)
    refute unmapped.emby_user_id
    refute unmapped.emby_user_name
  end

  test "list_users/0 returns users ordered by email" do
    emails = for _index <- 1..3, do: user_fixture().email
    listed = Accounts.list_users() |> Enum.map(& &1.email)
    assert listed == Enum.sort(emails)
  end
end
