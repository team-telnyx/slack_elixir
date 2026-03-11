defmodule Slack.APITest do
  use ExUnit.Case, async: false
  use Mimic

  @token "xoxb-test-token"

  setup :set_mimic_global

  describe "stream/4 pagination" do
    test "halts on empty cursor" do
      Slack.API
      |> expect(:get, fn "test.list", @token, %{types: "public_channel"} ->
        {:ok,
         %{
           "channels" => [%{"id" => "C1"}],
           "response_metadata" => %{"next_cursor" => ""}
         }}
      end)

      result =
        "test.list"
        |> Slack.API.stream(@token, "channels", types: "public_channel")
        |> Enum.to_list()

      assert result == [%{"id" => "C1"}]
    end

    test "halts on nil cursor (missing response_metadata)" do
      Slack.API
      |> expect(:get, fn "test.list", @token, %{types: "public_channel"} ->
        {:ok, %{"channels" => [%{"id" => "C1"}]}}
      end)

      result =
        "test.list"
        |> Slack.API.stream(@token, "channels", types: "public_channel")
        |> Enum.to_list()

      assert result == [%{"id" => "C1"}]
    end

    test "follows cursors across multiple pages" do
      Slack.API
      |> expect(:get, fn "test.list", @token, %{types: "public_channel"} ->
        {:ok,
         %{
           "channels" => [%{"id" => "C1"}],
           "response_metadata" => %{"next_cursor" => "cursor_page2"}
         }}
      end)
      |> expect(:get, fn "test.list", @token, %{types: "public_channel", cursor: "cursor_page2"} ->
        {:ok,
         %{
           "channels" => [%{"id" => "C2"}],
           "response_metadata" => %{"next_cursor" => ""}
         }}
      end)

      result =
        "test.list"
        |> Slack.API.stream(@token, "channels", types: "public_channel")
        |> Enum.to_list()

      assert result == [%{"id" => "C1"}, %{"id" => "C2"}]
    end

    test "halts on duplicate cursor" do
      # First call returns data with a cursor
      Slack.API
      |> expect(:get, fn "test.list", @token, %{types: "public_channel"} ->
        {:ok,
         %{
           "channels" => [%{"id" => "C1"}],
           "response_metadata" => %{"next_cursor" => "stuck_cursor"}
         }}
      end)
      # Second call returns the same cursor — infinite loop detected
      |> expect(:get, fn "test.list", @token,
                         %{types: "public_channel", cursor: "stuck_cursor"} ->
        {:ok,
         %{
           "channels" => [%{"id" => "C2"}],
           "response_metadata" => %{"next_cursor" => "stuck_cursor"}
         }}
      end)

      result =
        "test.list"
        |> Slack.API.stream(@token, "channels", types: "public_channel")
        |> Enum.to_list()

      # Should get data from both pages but halt when cursor repeats
      assert result == [%{"id" => "C1"}, %{"id" => "C2"}]
    end

    test "halts on empty batch after data was fetched" do
      Slack.API
      |> expect(:get, fn "test.list", @token, %{types: "public_channel"} ->
        {:ok,
         %{
           "channels" => [%{"id" => "C1"}],
           "response_metadata" => %{"next_cursor" => "cursor_page2"}
         }}
      end)
      |> expect(:get, fn "test.list", @token, %{types: "public_channel", cursor: "cursor_page2"} ->
        {:ok,
         %{
           "channels" => [],
           "response_metadata" => %{"next_cursor" => "cursor_page3"}
         }}
      end)

      result =
        "test.list"
        |> Slack.API.stream(@token, "channels", types: "public_channel")
        |> Enum.to_list()

      # Gets page 1 data, halts on empty page 2
      assert result == [%{"id" => "C1"}]
    end

    test "returns partial data on API error instead of raising" do
      Slack.API
      |> expect(:get, fn "test.list", @token, %{types: "public_channel"} ->
        {:ok,
         %{
           "channels" => [%{"id" => "C1"}],
           "response_metadata" => %{"next_cursor" => "cursor_page2"}
         }}
      end)
      |> expect(:get, fn "test.list", @token, %{types: "public_channel", cursor: "cursor_page2"} ->
        {:error, %Req.Response{status: 500, body: "Internal Server Error"}}
      end)

      # Should NOT raise — returns data collected so far
      result =
        "test.list"
        |> Slack.API.stream(@token, "channels", types: "public_channel")
        |> Enum.to_list()

      assert result == [%{"id" => "C1"}]
    end

    test "returns empty list on immediate API error" do
      Slack.API
      |> expect(:get, fn "test.list", @token, %{types: "public_channel"} ->
        {:error, %Req.Response{status: 403, body: %{"ok" => false, "error" => "not_authed"}}}
      end)

      result =
        "test.list"
        |> Slack.API.stream(@token, "channels", types: "public_channel")
        |> Enum.to_list()

      assert result == []
    end

    test "sends cursor param (not next_cursor) to Slack API" do
      # This test verifies the fix: the API expects `cursor`, not `next_cursor`
      Slack.API
      |> expect(:get, fn "test.list", @token, params ->
        # First call should NOT have a cursor param
        refute Map.has_key?(params, :cursor)
        refute Map.has_key?(params, :next_cursor)

        {:ok,
         %{
           "channels" => [%{"id" => "C1"}],
           "response_metadata" => %{"next_cursor" => "abc123"}
         }}
      end)
      |> expect(:get, fn "test.list", @token, params ->
        # Second call must use `cursor` (not `next_cursor`)
        assert params[:cursor] == "abc123"
        refute Map.has_key?(params, :next_cursor)

        {:ok,
         %{
           "channels" => [%{"id" => "C2"}],
           "response_metadata" => %{"next_cursor" => ""}
         }}
      end)

      "test.list"
      |> Slack.API.stream(@token, "channels", types: "public_channel")
      |> Enum.to_list()
    end

    test "accepts starting cursor via :cursor arg" do
      Slack.API
      |> expect(:get, fn "test.list", @token, %{cursor: "start_here"} ->
        {:ok,
         %{
           "channels" => [%{"id" => "C5"}],
           "response_metadata" => %{"next_cursor" => ""}
         }}
      end)

      result =
        "test.list"
        |> Slack.API.stream(@token, "channels", cursor: "start_here")
        |> Enum.to_list()

      assert result == [%{"id" => "C5"}]
    end
  end

  describe "client/1" do
    test "configures retry with transient mode" do
      client = Slack.API.client(@token)
      assert client.options.retry == :transient
    end

    test "configures max_retries" do
      client = Slack.API.client(@token)
      assert client.options.max_retries == 3
    end

    test "configures jittered retry_delay" do
      client = Slack.API.client(@token)
      delay_fun = client.options.retry_delay
      assert is_function(delay_fun, 1)

      # Retry 0: base 1000 + jitter(1..1000)
      delay_0 = delay_fun.(0)
      assert delay_0 >= 1_001 and delay_0 <= 2_000

      # Retry 1: base 2000 + jitter(1..1000)
      delay_1 = delay_fun.(1)
      assert delay_1 >= 2_001 and delay_1 <= 3_000

      # Retry 2: base 4000 + jitter(1..1000)
      delay_2 = delay_fun.(2)
      assert delay_2 >= 4_001 and delay_2 <= 5_000
    end
  end
end
