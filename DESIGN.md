# Design: Pagination & Resilience Fix

**Branch:** `fix/pagination-and-resilience`
**Status:** Design — not yet implemented
**Date:** 2026-03-11

## Problem Statement

`Slack.ChannelServer` loops infinitely when Slack returns duplicate cursors or
empty batches during pagination. Combined with:

1. **No rate limit handling** — HTTP 429 responses surface as `{:error, ...}`
   which `Slack.API.stream/4` converts to a `raise`, crashing the caller.
2. **`start_link` is synchronous and crash-fatal** — `fetch_channels/2` runs
   inside `start_link`, so any API error kills the GenServer before `init/1`
   even runs. Because this child is in the supervision tree with
   `:one_for_one`, the supervisor restarts it, hits the same error, and
   eventually reaches `max_restarts` — tearing down the entire tree including
   the working WebSocket connection.
3. **Hardcoded channel types** — the default includes `private_channel`, `mpim`,
   `im`, which require `groups:read`, `im:read`, `mpim:read` scopes. Bots that
   only have `channels:read` crash on startup.

## Design Principles

- **Minimal diff** — focused surgical changes, not a rewrite.
- **Backward compatible** — existing config and public API unchanged; new
  options are additive with safe defaults.
- **OTP-idiomatic** — errors are values, not exceptions. GenServers degrade
  gracefully. Supervision tree stays alive.

---

## 1. Pagination Fix (`Slack.API.stream/4`)

### Root Cause

The `next_fun` in `Stream.resource/3` halts only when cursor is `""`. Slack
sometimes returns a non-empty cursor that is identical to the previous one,
paired with an empty `channels` list. The stream never halts.

### Fix

Track the previous cursor. Halt on any of:

1. Cursor is `""` or `nil` (existing check, but `nil` isn't handled).
2. Cursor equals the previous cursor (duplicate — Slack is stuck).
3. The resource list in the response is empty *and* we've seen at least one
   page (Slack returned data then stopped producing, but keeps sending a
   cursor).

#### Implementation Detail

Change `Stream.resource` accumulator from a bare cursor to a tuple:
`{cursor, prev_cursor, page_count}`.

```elixir
# Accumulator: {current_cursor, previous_cursor, pages_fetched}
Stream.resource(
  fn -> {starting_cursor, nil, 0} end,

  fn
    {"", _, _} ->
      {:halt, nil}

    {nil, _, _} ->
      {:halt, nil}

    {cursor, prev_cursor, _page} when cursor == prev_cursor ->
      Logger.warning("[Slack.API] Duplicate cursor detected, stopping pagination")
      {:halt, nil}

    {cursor, _prev_cursor, page_count} ->
      case get(endpoint, token, Map.merge(args, %{cursor: cursor})) do
        {:ok, %{^resource => data} = body} ->
          next = get_in(body, ["response_metadata", "next_cursor"]) || ""

          case data do
            [] when page_count > 0 ->
              Logger.warning("[Slack.API] Empty page with cursor, stopping pagination")
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
```

**Key change in the pattern match:** The existing code matches on
`%{"ok" => true, ^resource => data}`. But `get/3` already checks for
`"ok" => true` and returns `{:ok, body}` — so the stream's `next_fun` is
double-checking. We simplify to just match `{:ok, %{^resource => data}}`.

**Error path:** Instead of `raise`, return `{:halt, nil}`. The stream produces
whatever it collected so far. Callers get partial data instead of a crash.

### Pagination Parameter Name

Slack's `users.conversations` API uses `cursor`, not `next_cursor`, as the
request parameter name. The current code sends `next_cursor` as the param,
which happens to work because Slack ignores unknown params on the first call
(cursor is nil/empty), and the subsequent calls... actually, let me check.

Looking at the code again:
```elixir
Map.merge(args, %{next_cursor: cursor})
```

But the Slack API expects the parameter to be named `cursor`. The code sends
`next_cursor` which Slack ignores — meaning **pagination never actually
advances**. This is likely the *primary* cause of the infinite loop: the API
keeps returning page 1 with the same cursor because we never send it back.

**Fix:** Change parameter name from `next_cursor` to `cursor`.

> **Note:** This needs verification against the actual Slack API docs during
> implementation. If the existing code somehow works (maybe Req or Slack
> accepts both), we should still normalize to `cursor` to match the docs.

---

## 2. Rate Limiting (`Slack.API`)

### Current Behavior

HTTP 429 responses from Slack come back as:
```
{:ok, %Req.Response{status: 429, headers: %{"retry-after" => ["30"]}, body: ...}}
```

`Req.get/2` returns `{:ok, response}` for all HTTP responses. The current code
checks `body["ok"] == true` and falls into the error branch, logging and
returning `{:error, response}`. In `stream/4`, the error branch *raises*.

### Fix

Add retry-with-backoff logic to `get/3` and `post/3` at the `Slack.API` level.
This is the choke point — all API calls flow through here.

#### Implementation

Add a private `request_with_retry/2` function that wraps the Req call:

```elixir
@max_retries 3
@base_backoff_ms 1_000

defp request_with_retry(req_fun, retries_left \\ @max_retries)

defp request_with_retry(_req_fun, 0) do
  {:error, :rate_limited}
end

defp request_with_retry(req_fun, retries_left) do
  case req_fun.() do
    {:ok, %{status: 429} = response} ->
      retry_after_s =
        response
        |> Req.Response.get_header("retry-after")
        |> List.first()
        |> parse_retry_after()

      # Jittered backoff: use Retry-After if present, else exponential
      delay_ms = retry_after_ms(retry_after_s, @max_retries - retries_left)

      Logger.warning(
        "[Slack.API] Rate limited. Retrying in #{delay_ms}ms " <>
        "(#{retries_left - 1} retries left)"
      )

      Process.sleep(delay_ms)
      request_with_retry(req_fun, retries_left - 1)

    other ->
      other
  end
end

defp parse_retry_after(nil), do: nil
defp parse_retry_after(value) do
  case Integer.parse(value) do
    {seconds, _} -> seconds
    :error -> nil
  end
end

defp retry_after_ms(nil, attempt) do
  # Exponential backoff with jitter: base * 2^attempt + random(0..base)
  base = @base_backoff_ms * Integer.pow(2, attempt)
  base + :rand.uniform(@base_backoff_ms)
end

defp retry_after_ms(seconds, _attempt) do
  # Use server-specified delay + small jitter (0-1s)
  (seconds * 1_000) + :rand.uniform(1_000)
end
```

Then wrap calls in `get/3` and `post/3`:

```elixir
def get(endpoint, token, args \\ %{}) do
  result =
    request_with_retry(fn ->
      Req.get(client(token), url: endpoint, params: args)
    end)

  case result do
    {:ok, %{body: %{"ok" => true} = body}} -> {:ok, body}
    {:error, :rate_limited} = err -> err
    {_, error} -> Logger.error(inspect(error)); {:error, error}
  end
end
```

### Why Not Use Req's Built-in Retry?

Req has `retry:` option, but:
1. It doesn't parse Slack's `Retry-After` header by default.
2. We want logging and jitter control.
3. Keeping it explicit makes the behavior visible and testable.

That said — if during implementation we find Req's retry plugin can be
configured to do exactly this, we should prefer it. Less code is better.

---

## 3. Graceful Error Handling (`Slack.ChannelServer`)

### Current Behavior

```elixir
def start_link({bot, config}) do
  channels = fetch_channels(bot.token, channel_types)  # ← can crash
  GenServer.start_link(__MODULE__, {bot, channels}, name: via_tuple(bot))
end
```

`fetch_channels/2` calls `Slack.API.stream/4` |> `Enum.map/2`. If the stream
raises (API error, rate limit), `start_link` crashes, supervisor restarts it,
same error, tree dies.

### Fix

Move channel fetching out of `start_link` and into `handle_continue`:

```elixir
def start_link({bot, config}) do
  Logger.info("[Slack.ChannelServer] starting for #{bot.module}...")

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
        "[Slack.ChannelServer] #{state.bot.module} fetched #{length(channels)} channels"
      )
      Enum.each(channels, &join(state.bot, &1))
      {:noreply, %{state | channels: channels}}

    {:error, reason} ->
      Logger.error(
        "[Slack.ChannelServer] Failed to fetch channels: #{inspect(reason)}. " <>
        "Starting with empty channel list, retrying in 30s."
      )
      Process.send_after(self(), :retry_fetch, :timer.seconds(30))
      {:noreply, state}
  end
end

@impl true
def handle_info(:retry_fetch, state) do
  {:noreply, state, {:continue, :fetch_channels}}
end
```

#### `fetch_channels/2` Change

Currently returns a list directly (or crashes). Change to return
`{:ok, list}` | `{:error, reason}`:

```elixir
defp fetch_channels(token, types) when is_binary(types) do
  channels =
    "users.conversations"
    |> Slack.API.stream(token, "channels", types: types)
    |> Enum.map(& &1["id"])

  {:ok, channels}
rescue
  e ->
    {:error, Exception.message(e)}
end
```

> **Better approach:** Once `stream/4` no longer raises (change from §1), the
> `rescue` becomes unnecessary. We can instead check if the stream produced
> anything useful. But the rescue is a safety net during the transition.

#### Retry Behavior

- First failure: retry after 30 seconds.
- Could add exponential backoff on repeated failures, but 30s fixed interval
  is fine for v1 — channel listings change rarely and we just need it to
  eventually succeed.
- The bot is fully functional via Socket Mode during this time; it just won't
  know about pre-existing channels until the fetch succeeds.

#### Removing the `:join` Continue

The current code has `{:continue, :join}` after init to iterate channels and
call `join/2` on each. In the new design, joining happens inside
`handle_continue(:fetch_channels, ...)` after a successful fetch. The separate
`:join` continue is removed.

---

## 4. Scoped Channel Types

### Current Behavior

```elixir
@default_channel_types "public_channel,private_channel,mpim,im"
```

This requires `channels:read`, `groups:read`, `im:read`, `mpim:read` scopes.
Most bots only have `channels:read` (and maybe `groups:read`). The API returns
an error for unauthorized types, which with the current code crashes the bot.

### Fix

Change the default to just `public_channel`:

```elixir
@default_channel_types "public_channel"
```

This is the only type that requires just `channels:read` — the most common
minimal scope. Users who want more can opt in:

```elixir
# In supervision tree config:
channels: [types: "public_channel,private_channel"]
# or
channels: [types: ["public_channel", "private_channel", "mpim"]]
```

### Backward Compatibility

**This is a breaking change in default behavior.** Bots that relied on the
default to get private channels, IMs, and MPIMs will now need to explicitly
configure types.

However:
1. Bots that had all four scopes and want all types → add `types:` config.
2. Bots that only had `channels:read` → were already crashing. This fixes them.
3. The explicit config path (`types: "..."`) already exists and is unchanged.

**Recommendation:** Accept this as a justified default change. Document it in
the CHANGELOG. The old default was effectively broken for minimal-scope bots.

---

## File-by-File Change Summary

### `lib/slack/api.ex`

| Change | Description |
|--------|-------------|
| Add `request_with_retry/2` | Private function wrapping Req calls with 429 retry + jittered backoff |
| Wrap `get/3` body | Use `request_with_retry` around `Req.get` |
| Wrap `post/3` body | Use `request_with_retry` around `Req.post` |
| Fix `stream/4` accumulator | Track `{cursor, prev_cursor, page_count}` instead of bare cursor |
| Fix `stream/4` error path | Return `{:halt, nil}` instead of `raise` |
| Fix cursor param name | Send `cursor` not `next_cursor` to Slack API |
| Handle `nil` cursor | Add `nil` to halt conditions |
| Add helper functions | `parse_retry_after/1`, `retry_after_ms/2` |

### `lib/slack/channel_server.ex`

| Change | Description |
|--------|-------------|
| Move fetch out of `start_link` | `start_link` only starts the GenServer; fetch happens in `handle_continue` |
| Change `init/1` | Accept `{bot, channel_types}`, start with empty channels, continue to `:fetch_channels` |
| Add `handle_continue(:fetch_channels)` | Fetch channels, join on success, schedule retry on failure |
| Add `handle_info(:retry_fetch)` | Re-trigger fetch via continue |
| Remove `handle_continue(:join)` | Joining now happens inside `:fetch_channels` handler |
| Change `fetch_channels/2` return | Return `{:ok, channels}` or `{:error, reason}` |
| Change default types | `"public_channel"` instead of all four |

### `lib/slack/supervisor.ex`

No changes needed. The child spec `{Slack.ChannelServer, {bot, channel_config}}`
remains the same — `start_link/1` signature is unchanged.

### `lib/slack/socket.ex`

No changes. Socket Mode works fine.

---

## Test Plan

### Unit Tests (`test/slack/api_test.exs` — new file)

1. **Pagination halts on empty cursor** — stream with `""` cursor returns `{:halt, _}`.
2. **Pagination halts on nil cursor** — same for `nil`.
3. **Pagination halts on duplicate cursor** — mock API returning same cursor twice.
4. **Pagination halts on empty batch** — mock API returning `[]` channels with a cursor.
5. **Pagination error returns halt, not raise** — mock API returning error.
6. **Rate limit retry** — mock 429 with `Retry-After`, verify retry happens.
7. **Rate limit exhaustion** — mock 429 three times, verify `{:error, :rate_limited}`.

### Unit Tests (`test/slack/channel_server_test.exs` — new file)

1. **Successful start** — mock API, verify channels populated.
2. **API failure on start** — mock API error, verify GenServer starts with
   empty channels and schedules retry.
3. **Retry succeeds** — mock first call fail, second succeed, verify channels populated.
4. **Custom channel types** — verify `types:` config is passed through.
5. **Default channel types** — verify only `public_channel` by default.

### Integration Consideration

These are all unit tests with Mimic mocks. No real Slack API calls. The
existing `test_helper.exs` already sets up `Mimic.copy(Slack.API)`.

---

## Migration Guide (for CHANGELOG)

```markdown
## Breaking Changes

- **Default channel types changed:** The default channel types for
  `Slack.ChannelServer` changed from `"public_channel,private_channel,mpim,im"`
  to `"public_channel"`. If your bot needs access to private channels, IMs,
  or MPIMs, add `channels: [types: "public_channel,private_channel,mpim,im"]`
  to your bot config. This change prevents crashes for bots that only have the
  `channels:read` scope.

## Bug Fixes

- Fixed infinite pagination loop when Slack returns duplicate cursors or empty
  batches.
- Fixed `Slack.API.stream/4` sending `next_cursor` instead of `cursor` as the
  pagination parameter.
- `Slack.ChannelServer` no longer crashes on API errors during startup. It
  starts with an empty channel list and retries in the background.
- Added rate limit handling (HTTP 429) with jittered backoff respecting Slack's
  `Retry-After` header. Maximum 3 retries per request.
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `cursor` vs `next_cursor` param fix changes behavior | Medium | Low | Verify against Slack API docs; the current behavior is already broken |
| Default types change breaks existing users | Low | Medium | Document in changelog; existing explicit config is unchanged |
| Retry delay blocks GenServer | Low | Low | Only affects `ChannelServer` during `handle_continue`; socket/messages unaffected |
| Partial channel list on degraded start | Medium | Low | Bot joins channels via `member_joined_channel` events anyway; initial list is convenience |

## Open Questions

1. **`cursor` vs `next_cursor`:** Need to verify the actual Slack API parameter
   name. If the current code works at all, there might be something else going
   on (Req normalization, Slack accepting both, etc.).

2. **Req retry plugin:** During implementation, check if `Req.new(retry:)` can
   handle this. If so, configure it instead of writing custom retry logic.

3. **`exclude_archived` parameter:** The upstream issue mentions
   `exclude_archived`. Worth adding as default `true` in the
   `users.conversations` call. Low risk, high value. Decide during
   implementation.
