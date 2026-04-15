# Future Work

## Completed

### Isolate slow-consumer queue in a separate virtual host

Demonstrated on 2026-04-11. With `slow-ack-queue` in a dedicated vhost, disk
free was stable at 185.6 GB throughout a 40-minute baseline + spike run (~100 MB
total decline vs ~3 GB/7 min in the same-vhost configuration).

### Identify and revert candidate regression commits

0278980ba0 ("CQ shared store: Delete from index on remove or roll over") identified
as the primary candidate. Reverting it restores stable disk on both a 3-node cluster
and single-instance `main`. See [GC_LAG.md](GC_LAG.md) for details.

### Add GC stress workloads

`gc-stress-workload`, `burst-drain-workload`, `fanout-publisher`, and
`fanout-consumer` added to `single.mk` to exercise specific code paths in
`rabbit_msg_store.erl` changed by the candidate commits.

## Planned

### Complete stress workload runs

Run `burst-drain-workload` and `fanout-publisher`/`fanout-consumer` against the
`lukebakken/cq-gc` branch and confirm stable disk under each workload.

### File GitHub issue

File issue against `rabbitmq/rabbitmq-server` with full reproduction evidence,
tagging @lhoguin.

### Quantify the GC reclaim rate threshold

Determine the aggregate publish rate at which the classic queue message store GC can
no longer keep pace on an m5.4xlarge instance with `ha-mode: all`. Run the same-vhost
workload at increasing publish rates (100, 200, 300, 400, 500 msg/s) and measure the
disk decline rate at each level to find the crossover point.

### Repeat with quorum queues

Run the same workload with quorum queues instead of classic mirrored queues to compare
disk growth behavior under equivalent throughput and unacked counts.
