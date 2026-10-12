defmodule Akvy.ApiKeysTest do
  use Akvy.DataCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.ApiKeys

  test "create_api_key/1 returns the raw key once and stores only its hash" do
    {api_key, raw_key} = api_key_fixture()

    assert "akvy_" <> _ = raw_key
    assert String.starts_with?(raw_key, api_key.prefix)
    refute api_key.key_hash == raw_key
  end

  test "authenticate/1" do
    {api_key, raw_key} = api_key_fixture()

    assert %{id: id, last_used_at: %DateTime{}} = ApiKeys.authenticate(raw_key)
    assert id == api_key.id
    assert ApiKeys.authenticate("akvy_wrong") == nil
    assert ApiKeys.authenticate(nil) == nil
  end

  test "revoked keys do not authenticate" do
    {api_key, raw_key} = api_key_fixture()
    {:ok, _} = ApiKeys.revoke_api_key(api_key)
    assert ApiKeys.authenticate(raw_key) == nil
  end
end
