# Changelog

This new version of Phoenix.PubSub provides a simpler, more extensible, and more performant Phoenix.PubSub API. For users of Phoenix.PubSub, the API is the same, although frameworks and other adapters will have to migrate accordingly (which often means less code).

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
