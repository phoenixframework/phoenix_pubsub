# Changelog

This new version of Phoenix.PubSub provides a simpler, more extensible, and more performant Phoenix.PubSub API. For users of Phoenix.PubSub, the API is the same, although frameworks and other adapters will have to migrate accordingly (which often means less code).

## 2.4.0 (Unreleased)

### Enhancements

  - Add `Phoenix.PubSub.Sender` as a successor for custom dispatchers
  - Add `Phoenix.PubSub.unsubscribe_sender/3` to selectively remove sender subscriptions

### Migrating custom dispatchers

Custom dispatchers and the `:metadata` subscription option are deprecated in favor of
per-subscription senders. Existing dispatchers continue to work, except that subscribing
with `:metadata` in the shape of `[atom | term]` now raises. That shape is reserved
for senders.

To migrate:

1. Implement the `Phoenix.PubSub.Sender` behaviour in your delivery module. Its
   `send/4` callback receives one subscriber pid, its metadata, the message, and an
   accumulator. Move the delivery logic from `dispatch/3` into this callback. PubSub
   handles iterating over subscribers and excluding the originating pid for
   `broadcast_from` calls.
2. Replace `metadata: metadata` in subscriptions with `sender: {MySender, metadata}`:

   ```elixir
   Phoenix.PubSub.subscribe(MyApp.PubSub, "topic", sender: {MySender, metadata})
   ```

3. Remove custom dispatcher arguments from broadcast calls and remove the `:dispatcher`
   option from your PubSub child specification to use the default `Phoenix.PubSub`
   dispatcher. Custom dispatchers control delivery themselves and do not automatically
   invoke senders, so changing subscriptions alone is not sufficient.
4. Replace `unsubscribe_match/3` calls for migrated subscriptions with
   `unsubscribe_sender/3`, passing the same sender tuple:

   ```elixir
   Phoenix.PubSub.unsubscribe_sender(MyApp.PubSub, "topic", {MySender, metadata})
   ```

## 2.3.0 (2026-08-25)

### Enhancements
  - Add :group_by option to choose Registry sharding strategy
  - Add configurable default dispatcher
  - Add unsubscribe function that matches on metadata

### Bug fixes
  - Properly delete objects in tracker state

## 2.2.0 (2025-10-22)

### Enhancements
  - Allow the registry size to be set separate from pool size
  - Introduce `:broadcast_pool_size` option to allow safe pool size migration

### Bug fixes
  - Only restart shards if they terminate unexpectedly

## 2.1.4 (2024-09-27)

### Enhancements
  - Add `:permdown_on_shutdown` option

## 2.1.3 (2023-06-14)

### Bug fixes
  - Fix memory leak introduced in 2.1.2

## 2.1.2 (2023-05-24)

### Bug fixes
  - Fix race condition on tracker update allowing state to become out of sync

## 2.1.1 (2022-04-05)

### Enhancements
  - Support compatibility with 2.0 nodes when pool_size is 1

## 2.1.0 (2022-04-01)

### Enhancements
  - Support `handle_info` callback on `Phoenix.Tracker`

## 2.0.0 (2020-04-14)

### Enhancements
  - Use erlang's new `:pg` module if available instead of `:pg2`

### Backwards incompatible changes
  - Frameworks and other adapters will require the use of the new child_spec API
