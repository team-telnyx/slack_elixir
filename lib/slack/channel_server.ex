defmodule Slack.ChannelServer do
  @moduledoc false
  use GenServer

  require Logger

  # Default to public_channel only — requires just `channels:read` scope.
  # Users who need private channels, IMs, or MPIMs can opt in via config:
  #   channels: [types: "public_channel,private_channel,mpim,im"]
  # For type options, see: https://api.slack.com/methods/users.conversations
  @default_channel_types "public_channel"

  @retry_interval_ms :timer.seconds(30)

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({bot, config}) do
    Logger.info("[Slack.ChannelServer] starting for #{bot.module}...")

    # This should be a comma-separated string.
    channel_types =
      case Keyword.get(config, :types) do
        nil -> @default_channel_types
        types when is_binary(types) -> types
        types when is_list(types) -> Enum.join(types, ",")
      end

    GenServer.start_link(
      __MODULE__,
      {bot, channel_types},
      name: via_tuple(bot)
    )
  end

  def join(bot, channel) do
    GenServer.cast(via_tuple(bot), {:join, channel})
  end

  def part(bot, channel) do
    GenServer.cast(via_tuple(bot), {:part, channel})
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init({bot, channel_types}) do
    state = %{
      bot: bot,
      channels: [],
      channel_types: channel_types
    }

    {:ok, state, {:continue, :fetch_channels}}
  end

  @impl true
  def handle_continue(:fetch_channels, state) do
    case fetch_channels(state.bot.token, state.channel_types) do
      {:ok, channels} ->
        Logger.info(
          "[Slack.ChannelServer] #{state.bot.module} joining #{length(channels)} channels"
        )

        Enum.each(channels, fn channel_id ->
          Logger.debug("[Slack.ChannelServer] #{state.bot.module} joining #{channel_id}")
          Slack.MessageServer.start_supervised(state.bot, channel_id)
        end)

        {:noreply, %{state | channels: channels}}

      {:error, reason} ->
        Logger.error(
          "[Slack.ChannelServer] Failed to fetch channels: #{inspect(reason)}. " <>
            "Starting with empty channel list, retrying in #{div(@retry_interval_ms, 1000)}s."
        )

        Process.send_after(self(), :retry_fetch, @retry_interval_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:join, channel}, state) do
    Logger.info("[Slack.ChannelServer] #{state.bot.module} joining #{channel}...")
    {:ok, _} = Slack.MessageServer.start_supervised(state.bot, channel)
    {:noreply, Map.update!(state, :channels, &[channel | &1])}
  end

  def handle_cast({:part, channel}, state) do
    Logger.info("[Slack.ChannelServer] #{state.bot.module} leaving #{channel}...")
    :ok = Slack.MessageServer.stop(state.bot, channel)
    {:noreply, Map.update!(state, :channels, &List.delete(&1, channel))}
  end

  @impl true
  def handle_info(:retry_fetch, state) do
    {:noreply, state, {:continue, :fetch_channels}}
  end

  # ----------------------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------------------

  defp via_tuple(%Slack.Bot{module: bot}) do
    {:via, Registry, {Slack.ChannelServerRegistry, bot}}
  end

  defp fetch_channels(token, types) when is_binary(types) do
    channels =
      "users.conversations"
      |> Slack.API.stream(token, "channels", types: types, exclude_archived: true)
      |> Enum.map(& &1["id"])

    {:ok, channels}
  rescue
    # Safety net: Stream.resource/3 can raise on network errors, malformed
    # responses, or unexpected API changes. We catch everything here so the
    # GenServer stays alive and can schedule a retry instead of crashing.
    e ->
      {:error, Exception.message(e)}
  end
end
