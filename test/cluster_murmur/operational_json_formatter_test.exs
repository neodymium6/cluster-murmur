defmodule ClusterMurmur.OperationalJSONFormatterTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.OperationalJSONFormatter

  test "emits one allowlisted JSON object for an operational event" do
    event = %{
      level: :warning,
      msg: {:string, "external request completed"},
      meta: %{
        time: 1_723_456_789,
        component: :model_provider,
        outcome: :rejected,
        error_class: :authentication_failed,
        endpoint: "https://private.example.invalid",
        request: "must-not-appear"
      }
    }

    encoded = event |> OperationalJSONFormatter.format(%{}) |> IO.iodata_to_binary()

    assert Jason.decode!(encoded) == %{
             "time" => 1_723_456_789,
             "level" => "warning",
             "message" => "external request completed",
             "component" => "model_provider",
             "outcome" => "rejected",
             "error_class" => "authentication_failed"
           }

    refute encoded =~ "private.example.invalid"
    refute encoded =~ "must-not-appear"
  end

  test "replaces arbitrary reports and drops caller-selected metadata" do
    secret = "must-not-appear"

    encoded =
      %{
        level: :caller_selected,
        msg: {:report, %{exception: secret}},
        meta: %{
          time: -1,
          component: :caller_selected,
          outcome: secret,
          error_class: :caller_selected
        }
      }
      |> OperationalJSONFormatter.format(%{})
      |> IO.iodata_to_binary()

    assert Jason.decode!(encoded) == %{
             "time" => 0,
             "level" => "unknown",
             "message" => "application event"
           }

    refute encoded =~ secret
  end

  test "allows the fixed token-exhaustion error class" do
    encoded =
      %{
        level: :warning,
        msg: {:string, "external request completed"},
        meta: %{
          time: 1_723_456_789,
          component: :model_provider,
          outcome: :error,
          error_class: :token_exhausted
        }
      }
      |> OperationalJSONFormatter.format(%{})
      |> IO.iodata_to_binary()

    assert Jason.decode!(encoded)["error_class"] == "token_exhausted"
  end

  test "allows the fixed generation fallback dimensions" do
    encoded =
      %{
        level: :warning,
        msg: {:string, "generation decision completed"},
        meta: %{
          time: 1_723_456_789,
          component: :model_generation,
          outcome: :fallback,
          error_class: :unsafe_output_form,
          content: "must-not-appear"
        }
      }
      |> OperationalJSONFormatter.format(%{})
      |> IO.iodata_to_binary()

    assert Jason.decode!(encoded) == %{
             "time" => 1_723_456_789,
             "level" => "warning",
             "message" => "generation decision completed",
             "component" => "model_generation",
             "outcome" => "fallback",
             "error_class" => "unsafe_output_form"
           }

    refute encoded =~ "must-not-appear"
  end

  test "accepts no formatter configuration or malformed event shape" do
    assert OperationalJSONFormatter.check_config(%{}) == :ok

    assert OperationalJSONFormatter.check_config(%{private: true}) ==
             {:error, :invalid_operational_json_formatter}

    assert nil
           |> OperationalJSONFormatter.format(%{})
           |> IO.iodata_to_binary()
           |> Jason.decode!() == %{
             "time" => 0,
             "level" => "error",
             "message" => "logging failure"
           }
  end
end
