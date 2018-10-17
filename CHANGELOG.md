# Changelog

## v1.1.1 (2018-10-17)

* Bug fixes
  * Fix issue causing empty deltas to be chosen for replication
  * Improve replication over netsplit 

## v1.1.0 (2018-08-10)

* Enhancements
  * Optimize Tracker CRDT operations for increased performance
  * Shard tracker internally to use pool of trackers for increased performance under load
  * [Tracker] Add `get_by_key/3` to lookup a single presence entry for a given topic and key

## v1.0.2 (2017-06-14)

* Enhancements
  * Support `child_spec` in `PG2` adapter

* Bug fixes
  * Fix presence "zombies" / "ghosts" caused by replicas receiving downed pids for remote replicas they never observe

## v1.0.1 (2016-09-29)

* Enhancements
  * Support passing a function to `Tracker.update` for partial metadata updates
  * Prevent duplicate track registrations when calling `Tracker.track`

* Bug fixes
  * [PG2] - Fix multinode broadcasts requiring the same pool_size to properly broker messages

## v1.0.0 (2016-06-23)

* Enhancements
  * Extract `Phoenix.PubSub` into self-contained application
  * Add `Phoenix.Tracker` for distributed presence tracking for processes
