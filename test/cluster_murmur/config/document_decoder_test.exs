defmodule ClusterMurmur.Config.DocumentDecoderTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.DocumentDecoder

  @max_document_bytes 256 * 1_024
  @max_scalar_bytes 16 * 1_024

  test "decodes a YAML 1.2 mapping into bounded Elixir values" do
    yaml = """
    version: 1
    enabled: true
    ratio: 0.25
    missing: null
    labels:
      - observer
      - yes
    nested:
      count: 2
    """

    assert DocumentDecoder.decode(yaml) ==
             {:ok,
              %{
                "enabled" => true,
                "labels" => ["observer", "yes"],
                "missing" => nil,
                "nested" => %{"count" => 2},
                "ratio" => 0.25,
                "version" => 1
              }}
  end

  test "accepts an explicit YAML 1.2 directive and standard string tags" do
    assert DocumentDecoder.decode("%YAML 1.2\n---\n!!str version: !!str 1\n") ==
             {:ok, %{"version" => "1"}}
  end

  test "rejects empty, multiple, and non-mapping documents" do
    for yaml <- ["", "# comment only\n", "---\n", "--- # empty\n...\n"] do
      assert DocumentDecoder.decode(yaml) == {:error, :empty_document}
    end

    assert DocumentDecoder.decode("---\na: 1\n---\nb: 2\n") ==
             {:error, :multiple_documents}

    for yaml <- ["value\n", "- value\n", "null\n"] do
      assert DocumentDecoder.decode(yaml) == {:error, :invalid_document_root}
    end
  end

  test "rejects malformed YAML and invalid Unicode without exposing input" do
    for yaml <- ["[unterminated", <<"value: ", 0xFF>>] do
      assert DocumentDecoder.decode(yaml) == {:error, :invalid_yaml}
    end
  end

  test "rejects non-string and duplicate mapping keys at any depth" do
    assert DocumentDecoder.decode("true: value\n") == {:error, :invalid_mapping_key}
    assert DocumentDecoder.decode("outer:\n  1: value\n") == {:error, :invalid_mapping_key}

    assert DocumentDecoder.decode("key: first\nkey: second\n") ==
             {:error, :duplicate_mapping_key}

    assert DocumentDecoder.decode("outer:\n  key: first\n  key: second\n") ==
             {:error, :duplicate_mapping_key}
  end

  test "rejects anchors, aliases, and tag directives before construction" do
    assert DocumentDecoder.decode("value: &shared [1]\ncopy: *shared\n") ==
             {:error, :unsupported_yaml_feature}

    assert DocumentDecoder.decode("%TAG !app! tag:example.com,2026:\n---\nvalue: text\n") ==
             {:error, :unsupported_yaml_feature}

    assert DocumentDecoder.decode("%RESERVED value\n---\nvalue: text\n") ==
             {:error, :unsupported_yaml_feature}

    assert DocumentDecoder.decode("value: !application-specific text\n") ==
             {:error, :unsupported_yaml_feature}

    assert DocumentDecoder.decode("%YAML 1.1\n---\nvalue: yes\n") ==
             {:error, :unsupported_yaml_feature}
  end

  test "rejects unsupported and non-finite scalar types" do
    for yaml <- ["value: .nan\n", "value: .inf\n", "value: !!binary SGVsbG8=\n"] do
      assert DocumentDecoder.decode(yaml) == {:error, :unsupported_scalar}
    end
  end

  test "enforces scalar, node, nesting, and document byte limits" do
    oversized_scalar = "value: " <> String.duplicate("a", @max_scalar_bytes + 1) <> "\n"
    assert DocumentDecoder.decode(oversized_scalar) == {:error, :scalar_too_large}

    too_many_nodes =
      1..4_096
      |> Enum.map_join("", fn index -> "key#{index}: null\n" end)

    assert byte_size(too_many_nodes) < @max_document_bytes
    assert DocumentDecoder.decode(too_many_nodes) == {:error, :document_too_complex}

    too_deep = "root: " <> String.duplicate("[", 16) <> "value" <> String.duplicate("]", 16)
    assert DocumentDecoder.decode(too_deep) == {:error, :document_too_deep}

    assert DocumentDecoder.decode(String.duplicate(" ", @max_document_bytes + 1)) ==
             {:error, :document_too_large}
  end

  test "reads a document through a bounded file interface" do
    path = temporary_path("valid.yaml")
    File.write!(path, "version: 1\n")

    assert DocumentDecoder.decode_file(path) == {:ok, %{"version" => 1}}
    assert DocumentDecoder.decode_file(path <> ".missing") == {:error, :unreadable_document}
    assert DocumentDecoder.decode_file(Path.dirname(path)) == {:error, :unreadable_document}
    assert DocumentDecoder.decode_file(nil) == {:error, :invalid_document_path}
  end

  test "does not read past the file byte limit" do
    path = temporary_path("oversized.yaml")
    File.write!(path, String.duplicate(" ", @max_document_bytes + 1))

    assert DocumentDecoder.decode_file(path) == {:error, :document_too_large}
  end

  defp temporary_path(name) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-document-decoder-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    Path.join(directory, name)
  end
end
