defmodule Slack.API do
  @moduledoc """
  Slack Web API.
  """

  require Logger

  @base_url "https://slack.com/api"
  @max_retries 3

  @doc """
  Req client for Slack API.

  Includes automatic retry with jittered backoff for transient errors (429, 5xx).
  Respects Slack's `Retry-After` header on 429 responses.
  """
  @spec client(String.t()) :: Req.Request.t()
  def client(token) do
    Req.new(
      base_url: @base_url,
      auth: {:bearer, token},
      retry: :transient,
      max_retries: @max_retries,
      retry_delay: &jittered_backoff/1
    )
  end

  @doc """
  GET from Slack API.
  """
  @spec get(String.t(), String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def get(endpoint, token, args \\ %{}) do
    result =
      Req.get(client(token),
        url: endpoint,
        params: args
      )

    case result do
      {:ok, %{body: %{"ok" => true} = body}} ->
        {:ok, body}

      {_, error} ->
        Logger.error(inspect(error))
        {:error, error}
    end
  end

  @doc """
  POST to Slack API.
  """
  @spec post(String.t(), String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def post(endpoint, token, args \\ %{}) do
    result =
      Req.post(client(token),
        url: endpoint,
        form: args
      )

    case result do
      {:ok, %{body: %{"ok" => true} = body}} ->
        {:ok, body}

      {_, error} ->
        Logger.error(inspect(error))
        {:error, error}
    end
  end

  @doc """
  GET pages from Slack API as a `Stream`.

  Paginates using cursor-based pagination. The stream halts when:
  - The cursor is empty (`""`) or `nil`
  - A duplicate cursor is detected (Slack returned the same cursor twice)
  - An empty page is returned after data has been fetched
  - An API error occurs (returns partial data collected so far instead of raising)

  You can start at a cursor if you pass in `:cursor` as one of the `args`.
  """
  @spec stream(String.t(), String.t(), String.t(), map() | keyword()) :: Enumerable.t()
  def stream(endpoint, token, resource, args \\ %{}) do
    {starting_cursor, args} =
      args
      |> Map.new()
      |> Map.pop(:cursor, nil)

    # Accumulator: {current_cursor, previous_cursor, pages_fetched}
    Stream.resource(
      fn -> {starting_cursor, nil, 0} end,
      fn
        {"", _, _} ->
          {:halt, nil}

        {nil, _, page} when page > 0 ->
          {:halt, nil}

        {cursor, prev_cursor, _page} when cursor == prev_cursor and cursor != nil ->
          Logger.warning("[Slack.API] Duplicate cursor detected, stopping pagination")
          {:halt, nil}

        {cursor, _prev_cursor, page_count} ->
          params = if cursor, do: Map.put(args, :cursor, cursor), else: args

          case __MODULE__.get(endpoint, token, params) do
            {:ok, %{^resource => data} = body} ->
              next = get_in(body, ["response_metadata", "next_cursor"]) || ""

              case data do
                [] when page_count > 0 ->
                  Logger.warning(
                    "[Slack.API] Empty page with cursor, stopping pagination"
                  )

                  {:halt, nil}

                _ ->
                  {data, {next, cursor, page_count + 1}}
              end

            {:error, reason} ->
              Logger.error("[Slack.API] Pagination error: #{inspect(reason)}")
              {:halt, nil}
          end
      end,
      fn _ -> :ok end
    )
  end

  # Exponential backoff with jitter: base * 2^n + random(0..1000)ms
  defp jittered_backoff(retry_count) do
    base = Integer.pow(2, retry_count) * 1_000
    base + :rand.uniform(1_000)
  end
end
