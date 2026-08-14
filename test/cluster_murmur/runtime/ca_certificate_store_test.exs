defmodule ClusterMurmur.Runtime.CACertificateStoreTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.CACertificateStore
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    root = PrivateTmpDir.create!("cluster-murmur-ca-certificate-store-test")
    bundle = Path.join(root, "ca-bundle.crt")
    File.write!(bundle, "clearly-fake-certificate-bundle")

    on_exit(fn -> File.rm_rf!(root) end)
    %{bundle: bundle, root: root}
  end

  test "loads one configured bounded bundle before verifying the store", %{bundle: bundle} do
    test_process = self()

    assert CACertificateStore.initialize(
             environment(bundle),
             fn loaded ->
               send(test_process, {:loaded, loaded})
               :ok
             end,
             fn -> [:certificate] end
           ) == :ok

    assert_receive {:loaded, ^bundle}
  end

  test "accepts a non-empty platform store when no bundle is configured" do
    assert CACertificateStore.initialize(
             fn "SSL_CERT_FILE" -> :error end,
             fn _path -> flunk("bundle loader must not be called") end,
             fn -> [:platform_certificate] end
           ) == :ok
  end

  test "rejects invalid configured paths and targets", %{bundle: bundle, root: root} do
    empty_bundle = Path.join(root, "empty.crt")
    oversized_bundle = Path.join(root, "oversized.crt")
    File.write!(empty_bundle, "")
    File.write!(oversized_bundle, :binary.copy("x", 4 * 1_024 * 1_024 + 1))

    invalid_paths = [
      "relative/ca-bundle.crt",
      bundle <> <<0>>,
      root,
      empty_bundle,
      oversized_bundle,
      Path.join(root, "missing.crt"),
      "/" <> String.duplicate("a", 4 * 1_024)
    ]

    for path <- invalid_paths do
      assert CACertificateStore.initialize(
               environment(path),
               fn _loaded -> flunk("invalid bundle must not be loaded") end,
               fn -> [:certificate] end
             ) == {:error, :invalid_ca_certificate_store}
    end
  end

  test "rejects malformed environment results and dependencies", %{bundle: bundle} do
    assert CACertificateStore.initialize(
             fn "SSL_CERT_FILE" -> {:ok, :not_a_path} end,
             fn _path -> :ok end,
             fn -> [:certificate] end
           ) == {:error, :invalid_ca_certificate_store}

    assert CACertificateStore.initialize(
             fn "SSL_CERT_FILE" -> :unexpected end,
             fn _path -> :ok end,
             fn -> [:certificate] end
           ) == {:error, :invalid_ca_certificate_store}

    for arguments <- [
          [:not_an_environment_reader, fn _path -> :ok end, fn -> [:certificate] end],
          [environment(bundle), :not_a_loader, fn -> [:certificate] end],
          [environment(bundle), fn _path -> :ok end, :not_a_reader]
        ] do
      assert apply(CACertificateStore, :initialize, arguments) ==
               {:error, :invalid_ca_certificate_store}
    end
  end

  test "fails closed for loader and certificate-store failures", %{bundle: bundle} do
    failures = [
      {fn _path -> {:error, :unreadable} end, fn -> [:certificate] end},
      {fn _path -> :unexpected end, fn -> [:certificate] end},
      {fn _path -> raise "loader details" end, fn -> [:certificate] end},
      {fn _path -> throw(:loader_details) end, fn -> [:certificate] end},
      {fn _path -> :ok end, fn -> [] end},
      {fn _path -> :ok end, fn -> :no_cacerts_found end},
      {fn _path -> :ok end, fn -> raise "reader details" end},
      {fn _path -> :ok end, fn -> throw(:reader_details) end}
    ]

    for {loader, reader} <- failures do
      result = CACertificateStore.initialize(environment(bundle), loader, reader)

      assert result == {:error, :invalid_ca_certificate_store}
      refute inspect(result) =~ bundle
      refute inspect(result) =~ "details"
    end
  end

  defp environment(path), do: fn "SSL_CERT_FILE" -> {:ok, path} end
end
