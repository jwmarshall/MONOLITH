defmodule Lovelace.HTTPTest do
  use ExUnit.Case, async: false

  test "Req.Test intercepts provider calls without using the network" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/probe"
      Req.Test.json(conn, %{connected: false})
    end)

    response = Req.get!("https://lovelace.invalid/probe", plug: {Req.Test, __MODULE__})

    assert response.status == 200
    assert response.body == %{"connected" => false}
  end
end
