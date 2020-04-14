# Changelog

This new version of Phoenix.PubSub provides a simpler, more extensible, and more performant Phoenix.PubSub API. For users of Phoenix.PubSub, the API is the same, although frameworks and other adapters will have to migrate accordingly (which often means less code).

## 2.0.0 (2020-04-14)

### Enhancements
  - Use erlang's new `:pg` module if available instead of `:pg2`

### Backwards incompatible changes
  - Frameworks and other adapters will require the use of the new child_spec API
