defmodule ClusterMurmur.Observers.ClientTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observers.{Client, MCPClient}

  test "builds a redacted adapter capability with opaque context" do
    transport = fn _request -> {:error, :not_sent, :unavailable} end

    assert {:ok, %Client{} = client} = Client.new(MCPClient, transport)
    assert client.adapter == MCPClient
    assert client.context == transport
    assert Client.validate(client) == :ok

    refute inspect(client) =~ "Function"
  end

  test "rejects missing adapter callbacks and forged client fields" do
    assert Client.new(String, :private_context) == {:error, :invalid_observer_client}
    assert Client.new("not-a-module", :private_context) == {:error, :invalid_observer_client}

    {:ok, valid} = Client.new(MCPClient, fn _request -> :unused end)

    assert Client.validate(%{valid | adapter: String}) ==
             {:error, :invalid_observer_client}

    assert Client.validate(Map.put(valid, :private, true)) ==
             {:error, :invalid_observer_client}
  end
end
