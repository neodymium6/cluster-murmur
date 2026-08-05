defmodule ClusterMurmur.Discord.WebhookSettingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Routing
  alias ClusterMurmur.Discord.WebhookSettings

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-webhook-settings-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf!(test_root) end)
    %{test_root: test_root}
  end

  test "loads one webhook URL without exposing the credential", %{test_root: test_root} do
    url = webhook_url("/api/webhooks/123456789/clearly_fake_webhook_token")
    path = write_secret(test_root, url)

    assert {:ok, %WebhookSettings{} = settings} =
             WebhookSettings.load(routing(), environment(path))

    assert settings.url == url
    refute inspect(settings) =~ url
    refute inspect(settings) =~ "clearly_fake_webhook_token"
  end

  test "accepts the current versioned API path and default HTTPS port", %{
    test_root: test_root
  } do
    urls = [
      webhook_url("/api/v10/webhooks/1/fake-token"),
      webhook_url("/api/webhooks/1/fake-token", ":443")
    ]

    for url <- urls do
      path = write_secret(test_root, url)

      assert WebhookSettings.load(routing(), environment(path)) ==
               {:ok, %WebhookSettings{url: url}}
    end
  end

  test "requires one exact routing value", %{test_root: test_root} do
    path = write_secret(test_root, webhook_url("/api/webhooks/1/fake-token"))
    forged = Map.put(routing(), :extra, true)

    for value <- [nil, %{}, forged] do
      assert WebhookSettings.load(value, environment(path)) ==
               {:error, :invalid_webhook_settings}
    end

    assert WebhookSettings.load(routing(), :not_an_environment_reader) ==
             {:error, :invalid_webhook_settings}
  end

  test "uses the bounded mounted-secret reader", %{test_root: test_root} do
    assert WebhookSettings.load(routing(), fn _name -> :error end) ==
             {:error, {:webhook, :missing_secret_file_path}}

    empty_path = write_secret(test_root, "\n")

    assert WebhookSettings.load(routing(), environment(empty_path)) ==
             {:error, {:webhook, :empty_secret}}

    invalid_path = write_secret(test_root, <<255>>)

    assert WebhookSettings.load(routing(), environment(invalid_path)) ==
             {:error, {:webhook, :invalid_secret_encoding}}
  end

  test "rejects URLs outside the fixed Discord incoming-webhook boundary", %{
    test_root: test_root
  } do
    long_token = String.duplicate("a", 513)

    invalid_urls = [
      build_url("http", "discord.com", "", "/api/webhooks/1/fake-token"),
      build_url("https", "canary.discord.com", "", "/api/webhooks/1/fake-token"),
      build_url("https", "discord.com.example.invalid", "", "/api/webhooks/1/fake-token"),
      "https://user@" <> host() <> "/api/webhooks/1/fake-token",
      webhook_url("/api/webhooks/1/fake-token", ":444"),
      webhook_url("/api/webhooks/not-a-snowflake/fake-token"),
      webhook_url("/api/webhooks/1/fake%2Ftoken"),
      webhook_url("/api/webhooks/1/#{long_token}"),
      webhook_url("/api/v9/webhooks/1/fake-token"),
      webhook_url("/api/webhooks/1/fake-token/messages/2"),
      webhook_url("/api/webhooks/1/fake-token") <> "?wait=true",
      webhook_url("/api/webhooks/1/fake-token") <> "#fragment"
    ]

    for url <- invalid_urls do
      path = write_secret(test_root, url)

      assert WebhookSettings.load(routing(), environment(path)) ==
               {:error, :invalid_webhook_url}
    end
  end

  test "errors do not expose the webhook credential", %{test_root: test_root} do
    private_value = webhook_url("/api/webhooks/1/private_fake_token") <> "?private=true"
    path = write_secret(test_root, private_value)

    result = WebhookSettings.load(routing(), environment(path))

    assert result == {:error, :invalid_webhook_url}
    refute inspect(result) =~ private_value
    refute inspect(result) =~ "private_fake_token"
  end

  test "fails closed when an injected environment reader raises" do
    assert WebhookSettings.load(routing(), fn _name -> raise "private diagnostic" end) ==
             {:error, :invalid_webhook_settings}
  end

  defp routing do
    %Routing{webhook_secret_file_env: "DISCORD_WEBHOOK_SECRET_FILE"}
  end

  defp host, do: Enum.join(["discord", ".", "com"])

  defp webhook_url(path, port \\ ""), do: build_url("https", host(), port, path)

  defp build_url(scheme, host, port, path), do: scheme <> "://" <> host <> port <> path

  defp environment(path), do: fn _name -> {:ok, path} end

  defp write_secret(root, contents) do
    path = Path.join(root, "secret-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end
end
