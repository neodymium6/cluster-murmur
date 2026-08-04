defmodule ClusterMurmur.Config.SchemaValidatorTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Config.SchemaValidator
  alias ClusterMurmur.Config.SchemaValidator.{Compiled, LocalFormatValidator}
  alias ExJsonSchema.Schema
  alias ExJsonSchema.Schema.Root

  @draft "http://json-schema.org/draft-07/schema#"

  defmodule GlobalFormatProbe do
    def validate(format, value) do
      send(self(), {:global_format_validator_called, format, value})
      true
    end
  end

  defmodule GlobalJsonProbe do
    def decode(value) do
      send(self(), {:global_json_decoder_called, value})
      {:ok, %{}}
    end
  end

  test "compiles Draft 7 schemas and validates decoded maps" do
    assert {:ok, compiled} = SchemaValidator.compile(object_schema())

    assert SchemaValidator.validate(compiled, %{"name" => "observer"}) == :ok

    for invalid <- [
          %{},
          %{"name" => 1},
          %{"name" => "observer", "unknown" => true}
        ] do
      assert SchemaValidator.validate(compiled, invalid) == {:error, :schema_violation}
    end

    assert {:ok, _compiled} = SchemaValidator.compile(object_schema("id"))
    assert {:ok, _compiled} = SchemaValidator.compile(object_schema("default"))
    assert {:ok, _compiled} = SchemaValidator.compile(object_schema("contentMediaType"))
    assert {:ok, _compiled} = SchemaValidator.compile(object_schema("contentEncoding"))
  end

  test "rejects local references so annotations cannot become executable schemas" do
    schema = %{
      "$schema" => @draft,
      "definitions" => %{"id" => %{"type" => "string", "pattern" => "^[a-z]+$"}},
      "$ref" => "#/definitions/id"
    }

    assert SchemaValidator.compile(schema) == {:error, :unsupported_schema_reference}

    for annotation <- ["const", "default", "enum", "examples"] do
      annotated = %{
        "$schema" => @draft,
        annotation => content_schema(),
        "$ref" => "#/#{annotation}"
      }

      assert SchemaValidator.compile(annotated) ==
               {:error, :unsupported_schema_reference}
    end
  end

  test "rejects invalid schemas and versions" do
    assert SchemaValidator.compile(nil) == {:error, :invalid_schema}
    assert SchemaValidator.compile(%{"type" => "object"}) == {:error, :invalid_schema}

    assert SchemaValidator.compile(%{"$schema" => @draft, "type" => "not-a-type"}) ==
             {:error, :invalid_schema}

    assert SchemaValidator.compile(%{
             "$schema" => "http://json-schema.org/draft-04/schema#",
             "type" => "object"
           }) == {:error, :invalid_schema}
  end

  test "rejects improper lists without raising" do
    for fragment <- [
          %{"allOf" => [%{} | :tail]},
          %{"items" => [%{} | :tail]},
          %{"unknown" => [%{} | :tail]}
        ] do
      schema = Map.put(fragment, "$schema", @draft)
      assert SchemaValidator.compile(schema) == {:error, :invalid_schema}
    end
  end

  test "rejects structs at root or in resolver-traversed values without raising" do
    root_struct = Map.put(URI.parse("https://example.invalid"), "$schema", @draft)

    assert SchemaValidator.compile(root_struct) == {:error, :invalid_schema}

    for keyword <- ["dependencies", "properties", "unknown"] do
      nested_struct = %{
        "$schema" => @draft,
        keyword => URI.parse("https://example.invalid")
      }

      assert SchemaValidator.compile(nested_struct) == {:error, :invalid_schema}
    end
  end

  test "rejects non-JSON schema keys and values" do
    invalid_schemas = [
      %{"$schema" => @draft, "properties" => %{"value" => %{type: "string"}}},
      %{"$schema" => @draft, "unknown" => %{:"$ref" => "#/value"}},
      %{"$schema" => @draft, "unknown" => %{{:tuple, :key} => true}},
      %{"$schema" => @draft, "unknown" => fn -> :ok end},
      %{"$schema" => @draft, "unknown" => self()},
      %{"$schema" => @draft, "default" => fn -> :ok end},
      %{"$schema" => @draft, <<255>> => true}
    ]

    for schema <- invalid_schemas do
      assert SchemaValidator.compile(schema) == {:error, :invalid_schema}
    end
  end

  test "rejects every external reference before schema resolution" do
    for reference <- [
          "https://example.invalid/schema.json",
          "file:///etc/example",
          "other.json#/definitions/value",
          1
        ] do
      schema = %{"$schema" => @draft, "$ref" => reference}

      assert SchemaValidator.compile(schema) ==
               {:error, :unsupported_schema_reference}
    end

    nested = %{
      "$schema" => @draft,
      "allOf" => [%{"$ref" => "https://example.invalid/nested.json"}]
    }

    assert SchemaValidator.compile(nested) == {:error, :unsupported_schema_reference}

    reserved_property =
      "default"
      |> object_schema()
      |> put_in(
        ["properties", "default"],
        %{"$ref" => "https://example.invalid/property.json"}
      )

    assert SchemaValidator.compile(reserved_property) ==
             {:error, :unsupported_schema_reference}

    for identifier_key <- ["$id", "id"] do
      rebased = %{
        "$schema" => @draft,
        identifier_key => "https://example.invalid/root.json",
        "definitions" => %{"value" => %{"type" => "string"}},
        "$ref" => "#/definitions/value"
      }

      assert SchemaValidator.compile(rebased) ==
               {:error, :unsupported_schema_reference}
    end
  end

  test "does not expose schemas or rejected values through results or inspection" do
    schema =
      "private_field"
      |> object_schema()
      |> put_in(["properties", "private_field", "pattern"], "^allowed$")

    assert {:ok, compiled} = SchemaValidator.compile(schema)

    result = SchemaValidator.validate(compiled, %{"private_field" => "private-value"})

    assert result == {:error, :schema_violation}
    refute inspect(compiled) =~ "private_field"
    refute inspect(result) =~ "private-value"
  end

  test "checks every Draft 7 child-schema position" do
    content_schema = content_schema()

    schema_fragments = [
      %{"additionalItems" => content_schema},
      %{"additionalProperties" => content_schema},
      %{"allOf" => [content_schema]},
      %{"anyOf" => [content_schema]},
      %{"contains" => content_schema},
      %{"definitions" => %{"value" => content_schema}},
      %{"dependencies" => %{"value" => content_schema}},
      %{"else" => content_schema},
      %{"if" => content_schema},
      %{"items" => content_schema},
      %{"items" => [content_schema]},
      %{"not" => content_schema},
      %{"oneOf" => [content_schema]},
      %{"patternProperties" => %{"^value$" => content_schema}},
      %{"properties" => %{"value" => content_schema}},
      %{"propertyNames" => content_schema},
      %{"then" => content_schema}
    ]

    for fragment <- schema_fragments do
      schema = Map.put(fragment, "$schema", @draft)
      assert SchemaValidator.compile(schema) == {:error, :unsupported_schema_feature}
    end
  end

  test "rejects values that are not compiled validators" do
    assert SchemaValidator.validate(nil, %{}) == {:error, :invalid_schema_validator}
  end

  test "never delegates unknown formats or document values to a global callback" do
    original = Application.fetch_env(:ex_json_schema, :custom_format_validator)

    Application.put_env(
      :ex_json_schema,
      :custom_format_validator,
      {GlobalFormatProbe, :validate}
    )

    on_exit(fn -> restore_global_format_validator(original) end)

    schema = %{"$schema" => @draft, "type" => "string", "format" => "application-private"}

    assert {:ok, compiled} = SchemaValidator.compile(schema)
    assert SchemaValidator.validate(compiled, "private-value") == :ok
    refute_received {:global_format_validator_called, "application-private", "private-value"}
  end

  test "rejects content-decoding keywords without invoking a global JSON decoder" do
    original = Application.fetch_env(:ex_json_schema, :decode_json)

    Application.put_env(
      :ex_json_schema,
      :decode_json,
      fn value -> GlobalJsonProbe.decode(value) end
    )

    on_exit(fn -> restore_application_env(:decode_json, original) end)

    content_schema = content_schema()

    schemas = [
      %{
        "$schema" => @draft,
        "type" => "string",
        "contentMediaType" => "application/json"
      },
      %{
        "$schema" => @draft,
        "type" => "string",
        "contentEncoding" => "base64",
        "contentMediaType" => "application/json"
      },
      put_in(object_schema("default"), ["properties", "default"], content_schema),
      %{
        "$schema" => @draft,
        "type" => "object",
        "patternProperties" => %{"^default$" => content_schema}
      },
      %{
        "$schema" => @draft,
        "definitions" => %{"default" => content_schema}
      }
    ]

    for schema <- schemas do
      assert SchemaValidator.compile(schema) == {:error, :unsupported_schema_feature}
    end

    literal_schemas = [
      %{"$schema" => @draft, "const" => content_schema},
      %{"$schema" => @draft, "default" => content_schema},
      %{"$schema" => @draft, "enum" => [content_schema]},
      %{"$schema" => @draft, "examples" => [content_schema]}
    ]

    for schema <- literal_schemas do
      assert {:ok, compiled} = SchemaValidator.compile(schema)
      SchemaValidator.validate(compiled, "private-value")
    end

    refute_received {:global_json_decoder_called, "private-value"}
    refute_received {:global_json_decoder_called, "cHJpdmF0ZS12YWx1ZQ=="}
  end

  test "rejects forged compiled roots before any configured callback receives a value" do
    original_decoder = Application.fetch_env(:ex_json_schema, :decode_json)

    Application.put_env(
      :ex_json_schema,
      :decode_json,
      fn value -> GlobalJsonProbe.decode(value) end
    )

    on_exit(fn -> restore_application_env(:decode_json, original_decoder) end)

    content_root =
      Schema.resolve(
        %{
          "$schema" => @draft,
          "type" => "string",
          "contentMediaType" => "application/json"
        },
        custom_format_validator: {LocalFormatValidator, :validate}
      )

    format_root =
      Schema.resolve(
        %{"$schema" => @draft, "type" => "string", "format" => "application-private"},
        custom_format_validator: {GlobalFormatProbe, :validate}
      )

    for root <- [content_root, format_root] do
      assert SchemaValidator.validate(%Compiled{root: root}, "private-value") ==
               {:error, :invalid_schema_validator}
    end

    refute_received {:global_json_decoder_called, "private-value"}
    refute_received {:global_format_validator_called, "application-private", "private-value"}
  end

  test "rejects forged roots with invalid or non-canonical Draft 7 schemas" do
    schemas = [
      %{"$schema" => @draft, "minLength" => -1},
      %{"$schema" => @draft, "properties" => []},
      %{"$schema" => @draft, "allOf" => %{}},
      %{"$schema" => @draft, "type" => "object", "additionalProperties" => false}
    ]

    for schema <- schemas do
      root = %Root{
        schema: schema,
        refs: %{},
        location: :root,
        version: 7,
        custom_format_validator: {LocalFormatValidator, :validate}
      }

      assert SchemaValidator.validate(%Compiled{root: root}, %{}) ==
               {:error, :invalid_schema_validator}
    end
  end

  defp object_schema(property \\ "name") do
    %{
      "$schema" => @draft,
      "type" => "object",
      "additionalProperties" => false,
      "required" => [property],
      "properties" => %{property => %{"type" => "string"}}
    }
  end

  defp content_schema do
    %{
      "type" => "string",
      "contentEncoding" => "base64",
      "contentMediaType" => "application/json"
    }
  end

  defp restore_global_format_validator(original),
    do: restore_application_env(:custom_format_validator, original)

  defp restore_application_env(key, {:ok, value}),
    do: Application.put_env(:ex_json_schema, key, value)

  defp restore_application_env(key, :error), do: Application.delete_env(:ex_json_schema, key)
end
