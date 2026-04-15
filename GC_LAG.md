# Classic Queue Message Store GC Lag

## Summary

Under sustained publish load with a long-timeout consumer queue in the same vhost,
the classic queue shared message store fails to reclaim segment files fast enough.
Disk usage grows continuously. This behavior is a regression introduced by commit
0278980ba0 (PR #13959). Reverting that commit restores stable disk behavior on both
a 3-node cluster and a single-instance `main` build.

## Observed Behavior

### RabbitMQ `main` with 0278980ba0 present (single instance, m7g.large) — PARTIALLY AFFECTED

Disk oscillated within a ~3 GB band rather than accumulating continuously. GC kept
up on average. The 4.x queue architecture changes (`q_head`/`q_tail` replacing
`q1`/`q2`/`q3`/`q4`/`delta`) alter the message store access pattern in a way that
partially mitigates the issue, but do not fix it.

### 3-node cluster with 0278980ba0 present (m7g.large, `ha-mode: all`) — CONFIRMED AFFECTED

Disk declined continuously; 15 GB EBS volumes exhausted in under 30 minutes.

### RabbitMQ v3.13.7 (pre-regression, pre-refactor) — CONFIRMED NOT AFFECTED

Single-instance m7g.large: disk stable at 185.1-185.4 GB throughout a 23-minute run
(7-minute baseline + 16-minute spike at 440+ msg/s, 1000 unacked). Note: v3.13.7
predates the major `rabbit_msg_store` refactor that introduced the shared store
architecture, so this data point establishes a pre-regression baseline but is not
directly comparable to `main`.

### After reverting 0278980ba0 (branch `lukebakken/cq-gc`) — CONFIRMED FIXED

**3-node cluster (m7g.large, `ha-mode: all`):**
- Disk stable at 13.6-13.9 GB throughout a 6-minute monitoring window
- Publish rate 504/s, 1030 unacked - full spike-phase workload

**Single instance (`main`):**
- Disk stable at 184.93-185.44 GB throughout a 20-minute monitoring window
- No oscillation; flat throughout baseline and spike phases
- Confirmed stable over multiple additional 20-minute monitoring windows

## Workload

Three concurrent processes:

- **main-workload**: 100 classic queues (`repro-queue-1` through `repro-queue-100`),
  100 producers + 100 consumers, 120 KB messages, consumers acking immediately.
  Variable rate: 2 msg/s/producer (200 msg/s aggregate) for `BASELINE_MINUTES`
  (default: 7 minutes), then 5 msg/s/producer (500 msg/s aggregate) indefinitely.
- **slow-ack-publisher**: 1 producer, 3 msg/s to `slow-ack-queue`.
- **slow-ack-consumer**: Pika consumer on `slow-ack-queue` holding acks for
  1-29.8 minutes (up to 1000 messages in flight).

Cluster policy on `/` vhost: `ha-mode: all`, `ha-sync-mode: automatic`,
`queue-version: 2`. Single-instance policy: `queue-version: 2` only.

Reproduction scripts: https://github.com/lukebakken/rmq-gc-lag

## Candidate Commits

Two commits to `deps/rabbit/src/rabbit_msg_store.erl` were investigated:

### `0278980ba0` — CQ shared store: Delete from index on remove or roll over (PRIMARY)

Replaces the `scan_and_vacuum_message_file` call in `delete_file` with an eager
index cleanup mechanism (`current_file_removes`). As a side effect, messages removed
from non-current files now produce `not_found` index lookups during
`scan_and_vacuum_message_file` instead of `previously_valid` ones, causing
byte-by-byte scanning instead of skipping. Under high throughput with many queues,
GC compaction rate drops far enough that it cannot keep pace with the publish rate.

This is the primary candidate for the regression. Reverting it alone is sufficient
to fix the issue.

**Note:** Three independent improvements from this commit have been retained as they
are unrelated to the broken mechanism:
- `compact_file/2` early-exit guard (file already deleted)
- `prioritise_cast/3` in `rabbit_msg_store_gc` (delete requests before compaction)
- `index_update_fields` assertion relaxed (`true=` to `_=`)

### `e033d97f37` — CQ: Defer shared store GC when removes were observed

Adds a `maps:without` filter in the `maybe_gc` timer handler:

```erlang
Candidates = maps:without(maps:keys(NewCandidates), Candidates0),
noreply(maybe_gc(Candidates, State))
```

Any file that had a message removed since the GC timer was started is excluded from
the current GC pass. Under high publish rate with many queues removing messages
continuously, `gc_candidates` is populated constantly - every GC candidate also has
recent removes, so `maps:without` excludes them all every 15-second cycle and GC
never runs.

**Note:** A build containing this commit but not 0278980ba0 shows stable disk.
Reverting this commit alone was insufficient to fix the regression when 0278980ba0
is also present.

## Mitigation (Confirmed)

Move queues with long consumer timeouts to a dedicated vhost. This gives them a
separate message store instance whose unacked messages do not pin files in the
shared store.

Vhost isolation experiment results (3-node cluster, m7g.large):
- Same vhost: disk declined ~3 GB/node in ~7 minutes at 200 msg/s
- Separate vhost: disk stable at 185.6 GB throughout a 40-minute run

## Investigation Branch

| Branch | Repo | Description |
|---|---|---|
| `lukebakken/cq-gc` | `rabbitmq-server` (upstream fork) | Reverts 0278980ba0; retains safe improvements |

## Next Steps

- Run `burst-drain-workload` and `fanout-workload` against `lukebakken/cq-gc` to
  stress additional GC code paths
- File GitHub issue against `rabbitmq/rabbitmq-server`, tag @lhoguin
- Determine whether `e033d97f37` should be reinstated once `0278980ba0` is fixed
