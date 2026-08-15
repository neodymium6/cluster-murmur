defmodule ClusterMurmur.Config.PresentationTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Presentation

  test "defaults to canonical UTC presentation" do
    assert Presentation.default() == %Presentation{timezone: "Etc/UTC"}
    assert Presentation.validate(Presentation.default()) == :ok
  end

  test "accepts an embedded IANA timezone" do
    assert Presentation.parse(%{"timezone" => "Asia/Tokyo"}) ==
             {:ok, %Presentation{timezone: "Asia/Tokyo"}}
  end

  test "rejects invalid, unknown, and forged settings without exposing values" do
    for rejected <- [
          nil,
          %{},
          %{"timezone" => "private.invalid"},
          %{"timezone" => "Etc/UTC", "unknown" => true},
          %Presentation{timezone: "private.invalid"},
          Map.put(Presentation.default(), :unknown, true)
        ] do
      result =
        if is_struct(rejected, Presentation),
          do: Presentation.validate(rejected),
          else: Presentation.parse(rejected)

      assert result == {:error, :invalid_presentation_configuration}
      refute inspect(result) =~ "private"
    end
  end
end
