# Classic Queue Message Store GC Lag

## Summary

Under sustained publish load with a long-timeout consumer queue in the same vhost,
the classic queue shared message store fails to reclaim segment files fast enough.
Disk usage grows continuously until the consumer acks its messages or the broker is
restarted. This behavior is a regression introduced after RabbitMQ 3.13.7. It is
confirmed in the Amazon MQ 20251225 build (3-node cluster). Reproduction on
RabbitMQ `main` (single instance) is in progress.

## Observed Behavior

### Amazon MQ for RabbitMQ (3.13.7, awsbuild_20251225) — CONFIRMED

Production broker `b-c24a60f7-ce4a-4ca4-b1c6-d113bc60c936` (3-node m5.4xlarge cluster):

- Disk declined 24–57 GB per node during business hours (13:00–20:00 UTC) on April 8–10, 2026
- Recovered overnight as publish rate dropped and GC caught up
- No disk alarm fired because peak rate (~300–500 msg/s) was lower than the March 23 incident (~840 msg/s)
- Customer workaround: purge `webhook_retry_queue`

Reproduction on 3-node m5.4xlarge test cluster (awsbuild_20251225, same vhost):

- Disk declined ~3 GB/node in ~7 minutes at 200 msg/s baseline
- Accelerated after spike to 500 msg/s

### Vanilla RabbitMQ 3.13.7 (upstream) — CONFIRMED NOT AFFECTED

Two separate test runs, both showing no GC lag:

**Run 1: 3-node m5.4xlarge cluster (same workload, same vhost)**
- Disk stable throughout baseline and spike phases

**Run 2: single-instance m7g.large (2026-04-13)**
- Disk stable at 185.1–185.4 GB throughout a 23-minute run (7-minute baseline + 16-minute spike at 440+ msg/s, 1000 unacked)

### RabbitMQ `main` (single instance, m7g.large) — IN PROGRESS

**Run 1 (2026-04-13, 30-minute baseline):**
- Disk declined ~3 GB during the baseline phase (182.96 GB at 14:43 from 185.79 GB start)
- Disk recovered mid-run as held acks fired — result inconclusive

**Run 2 (2026-04-13, 7-minute baseline, started 18:03:15 UTC):**
- Disk declined ~3 GB during baseline phase (184.27 → 182.83 GB by 18:08)
- Disk flat since spike started at 18:10 — result inconclusive, run ongoing

## Workload

Three concurrent processes:

- **main-workload**: 100 classic queues (`repro-queue-1` through `repro-queue-100`),
  100 producers + 100 consumers, 120 KB messages, consumers acking immediately.
  Variable rate: 2 msg/s/producer (200 msg/s aggregate) for `BASELINE_MINUTES`
  (default: 7 minutes), then 5 msg/s/producer (500 msg/s aggregate) indefinitely.
- **webhook-publisher**: 1 producer, 3 msg/s to `webhook_retry_queue`.
- **webhook-consumer**: Pika consumer on `webhook_retry_queue` holding acks for
  1–29.8 minutes (up to 1000 messages in flight).

Policy on `/` vhost: `queue-version: 2`. On the cluster reproduction: also
`ha-mode: all`, `ha-sync-mode: automatic`.

Reproduction scripts: https://github.com/lukebakken/rmq-gc-lag

## Root Cause (Working Theory)

The `webhook_retry_queue` consumer holds acks for up to 30 minutes. The unacked
messages remain referenced in the shared message store index with `ref_count > 0`,
pinning the segment files that contain them. The message store GC cannot delete or
compact those files while any message they contain is still referenced.

The high-throughput queues (`repro-queue-*`) write new messages to the same shared
message store. As they publish and consume, their messages are written to new segment
files. But because the `webhook_retry_queue` messages pin older files, the store
accumulates files faster than GC can reclaim them.

The mechanism is confirmed by the vhost isolation mitigation: moving
`webhook_retry_queue` to a separate vhost gives it a separate message store instance.
Its unacked messages no longer pin files in the `/` vhost's store, and GC runs freely
— disk was stable at 185.6 GB throughout a 40-minute run at 200–500 msg/s.

## Suspected Regression Commit

There are 24 commits to `deps/rabbit/src/rabbit_msg_store.erl` between `v3.13.7` and
current `main`. The most likely cause is:

```
e033d97f37 CQ: Defer shared store GC when removes were observed
```

This commit adds a `maps:without` filter in the `maybe_gc` timer handler:

```erlang
Candidates = maps:without(maps:keys(NewCandidates), Candidates0),
noreply(maybe_gc(Candidates, State))
```

Any file that had a message removed since the GC timer was started is excluded from
the current GC pass and deferred to the next 15-second cycle. Under high publish rate
with many queues all removing messages continuously, `gc_candidates` is populated
constantly — meaning every GC candidate also has recent removes, so `maps:without`
excludes them all every cycle and GC never runs.

Other commits in the same cluster (all by the same author, March 2024):

- `2955c4e8e2 CQ: Get messages list from file when doing compaction`
- `df9f9604e2 CQ: Rewrite the message store file scanning code`

These change the compaction algorithm but not the GC triggering logic. They are less
likely to be the primary cause but have not been ruled out.

## Mitigation (Confirmed)

Move `webhook_retry_queue` (and any other queue with long consumer timeouts) to a
dedicated vhost. This is a configuration-only change requiring no code modification
or instance upgrade.

Vhost isolation experiment results (awsbuild_20251225, 3-node cluster):
- Same vhost: disk declined ~3 GB/node in ~7 minutes at 200 msg/s
- Separate vhost: disk stable at 185.6 GB throughout 40-minute run at 200–500 msg/s

## Next Steps

- Complete `main` Run 2 (30-minute mark at 18:33:15 UTC) and record final disk reading
- If `main` reproduces: file a GitHub issue against `rabbitmq/rabbitmq-server` with
  reproduction steps pointing to https://github.com/lukebakken/rmq-gc-lag, tag
  @lhoguin (https://github.com/lhoguin)
- If `main` does not reproduce: investigate whether the single-instance topology
  (no mirroring) is a required condition, or whether the workload needs adjustment
