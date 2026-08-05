defmodule ClusterMurmur.Config.MountedSecretReaderTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.MountedSecretReader

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-secret-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf!(test_root) end)

    %{test_root: test_root}
  end

  test "reads and trims one non-empty UTF-8 secret", %{test_root: test_root} do
    path = write_fixture(test_root, "api-key", "  approved-runtime-secret\n")

    assert MountedSecretReader.read("LLM_API_KEY_FILE", environment(path)) ==
             {:ok, "approved-runtime-secret"}
  end

  test "accepts exactly 16 KiB and rejects a larger raw file", %{test_root: test_root} do
    exact = String.duplicate("a", 16 * 1_024)
    exact_path = write_fixture(test_root, "exact", exact)
    large_path = write_fixture(test_root, "large", exact <> "b")

    assert MountedSecretReader.read("SECRET_FILE", environment(exact_path)) == {:ok, exact}

    assert MountedSecretReader.read("SECRET_FILE", environment(large_path)) ==
             {:error, :secret_file_too_large}
  end

  test "rejects empty, whitespace-only, and invalid UTF-8 values", %{test_root: test_root} do
    fixtures = [
      {"empty", "", :empty_secret},
      {"whitespace", " \n\t", :empty_secret},
      {"invalid", <<255>>, :invalid_secret_encoding}
    ]

    for {name, contents, reason} <- fixtures do
      path = write_fixture(test_root, name, contents)

      assert MountedSecretReader.read("SECRET_FILE", environment(path)) ==
               {:error, reason}
    end
  end

  test "requires a valid configured environment-variable name", %{test_root: test_root} do
    path = write_fixture(test_root, "secret", "value")

    for name <- [nil, "", "1_SECRET_FILE", "SECRET-FILE", String.duplicate("A", 129)] do
      assert MountedSecretReader.read(name, environment(path)) ==
               {:error, :invalid_secret_environment_variable}
    end
  end

  test "rejects missing and malformed environment lookups" do
    assert MountedSecretReader.read("SECRET_FILE", fn _name -> :error end) ==
             {:error, :missing_secret_file_path}

    for result <- [nil, {:ok, nil}, {:error, :unavailable}] do
      assert MountedSecretReader.read("SECRET_FILE", fn _name -> result end) ==
               {:error, :invalid_secret_file_path}
    end

    assert MountedSecretReader.read("SECRET_FILE", :not_a_reader) ==
             {:error, :invalid_secret_file_path}
  end

  test "requires a bounded absolute UTF-8 path" do
    invalid_paths = [
      "",
      "relative/secret",
      <<255>>,
      "/" <> String.duplicate("a", 4 * 1_024)
    ]

    for path <- invalid_paths do
      assert MountedSecretReader.read("SECRET_FILE", environment(path)) ==
               {:error, :invalid_secret_file_path}
    end
  end

  test "rejects missing and non-regular targets", %{test_root: test_root} do
    missing = Path.join(test_root, "missing")
    directory = Path.join(test_root, "directory")
    File.mkdir_p!(directory)

    for path <- [missing, directory] do
      assert MountedSecretReader.read("SECRET_FILE", environment(path)) ==
               {:error, :secret_file_target_invalid}
    end
  end

  test "allows a mounted-file symlink whose target is regular", %{test_root: test_root} do
    target = write_fixture(test_root, ".data/api-key", "secret")
    link = Path.join(test_root, "api-key")
    File.ln_s!(target, link)

    assert MountedSecretReader.read("SECRET_FILE", environment(link)) == {:ok, "secret"}
  end

  test "errors do not expose paths or file contents", %{test_root: test_root} do
    private_path = Path.join(test_root, "private-value")

    result = MountedSecretReader.read("SECRET_FILE", environment(private_path))

    assert result == {:error, :secret_file_target_invalid}
    refute inspect(result) =~ private_path
    refute inspect(result) =~ "private-value"
  end

  defp environment(path), do: fn _name -> {:ok, path} end

  defp write_fixture(root, relative_path, contents) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Path.expand(path)
  end
end
