defmodule ClusterMurmur.TestSupport.PrivateTmpDirTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.TestSupport.PrivateTmpDir

  test "creates isolated private directories" do
    first = PrivateTmpDir.create!("cluster-murmur-private-tmp-dir-test")
    second = PrivateTmpDir.create!("cluster-murmur-private-tmp-dir-test")

    on_exit(fn ->
      File.rm_rf!(first)
      File.rm_rf!(second)
    end)

    refute first == second
    assert File.dir?(first)
    assert File.dir?(second)
    assert Bitwise.band(File.stat!(first).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(second).mode, 0o777) == 0o700
  end
end
