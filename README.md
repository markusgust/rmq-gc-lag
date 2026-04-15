# RabbitMQ Classic Queue GC Lag Reproduction

Reproduces classic queue message store GC lag on RabbitMQ brokers running builds
containing commit 0278980ba0. See [GC_LAG.md](GC_LAG.md) for full investigation findings.

## How It Works

Three processes run concurrently for the primary reproduction:

- **main-workload**: 100 classic queues (`repro-queue-1` through `repro-queue-100`)
  in the `/` vhost. 100 producers + 100 consumers, 120 KB messages, consumers acking
  immediately. Variable rate: 2 msg/s per producer for `BASELINE_MINUTES` (default:
  7 minutes), then 5 msg/s per producer indefinitely.

- **slow-ack-publisher**: 1 producer publishing 3 msg/s to `slow-ack-queue`,
  120 KB messages.

- **slow-ack-consumer**: Pika consumer on `slow-ack-queue` holding acks for a
  random 1-29.8 minute duration (up to 1000 messages in flight simultaneously).

Additional single-instance workloads for stress-testing the GC code paths:

- **gc-stress-workload**: 1 producer + 2 consumers on a single queue, 2048-byte
  messages, unlimited publish rate, variable consumer latency (500µs on/off cycling),
  qos 2048. Exercises the `remove_message` path under high throughput.

- **burst-drain-workload**: 1 producer + 1 consumer, 512 KB messages, alternating
  50 msg/s for 30s then 0 msg/s for 30s. Forces complete file evacuation during drain
  phases, exercising `delete_file` -> `scan_and_vacuum_message_file`.

- **fanout-publisher** + **fanout-consumer**: Publisher to a fanout exchange bound to
  5 durable queues; 5 consumers rate-limited to 1000 msg/s each. Exercises
  `remove_message` with `ref_count > 1` as each message is referenced by all 5 queues.
  Run `fanout-setup` once before starting these.

## Prerequisites

On the host running the workload:

- Java 11+ (`java -version` to verify)
- Python 3.9+
- RabbitMQ reachable at the AMQP URL set in `env.mk` (see below)

Both `perf-test.jar` (v2.24.0) and `pika` (v1.3.2) are vendored in `lib/` and
require no installation. `make setup` verifies Java is available.

## Configuration via env.mk

Create `~/env.mk` with the AMQP URL(s) before running any workload. Credentials
and vhost are parsed from the URL automatically. The management API URL defaults
to `http://<host>:15672` but can be overridden with `MGMT_URL`.

**Single-instance** (`MODE=single`, the default):

```make
AMQP_URL ?= amqp://guest:guest@10.0.1.90:5672
```

**Cluster** (`MODE=cluster`):

```make
AMQP_URL0 ?= amqp://guest:guest@10.0.1.40:5672
AMQP_URL1 ?= amqp://guest:guest@10.0.1.122:5672
AMQP_URL2 ?= amqp://guest:guest@10.0.1.254:5672
```

If `~/env.mk` is absent, set the variables manually on the command line:

```bash
# single
make main-workload AMQP_URL=amqp://guest:guest@10.0.1.90:5672

# cluster
make main-workload MODE=cluster \
  AMQP_URL0=amqp://guest:guest@10.0.1.40:5672 \
  AMQP_URL1=amqp://guest:guest@10.0.1.122:5672 \
  AMQP_URL2=amqp://guest:guest@10.0.1.254:5672
```

## Makefile Targets

```bash
# Single-instance (default)
make classic-policy        # Apply queue-version:2 policy to / vhost
make clean                 # Delete all queues
make slow-ack-consumer      # Start the Pika slow-ack consumer
make slow-ack-publisher     # Start the slow-ack-queue publisher
make main-workload         # Start the 100-queue main workload
make gc-stress-workload    # Start the single-queue GC stress workload
make burst-drain-workload  # Start the burst/drain GC stress workload
make fanout-setup          # Create fanout exchange and queues (run once)
make fanout-publisher      # Start the fanout publisher
make fanout-consumer       # Start the fanout consumers

# Cluster
make MODE=cluster ha-policy
make MODE=cluster main-workload
```

Each target runs in the foreground. Start each in a separate terminal.
Log files are written to the current directory with a UTC timestamp on the first line.

## Running the Primary Reproduction

```bash
make classic-policy   # or: make MODE=cluster ha-policy
# terminal 1
make slow-ack-consumer
# terminal 2
make slow-ack-publisher
# terminal 3
make main-workload    # or: make MODE=cluster main-workload
```

Monitor disk free via the Prometheus endpoint:

```bash
curl -s http://<node-ip>:15692/metrics | grep '^rabbitmq_disk_space_available_bytes'
```

## Files

- `Makefile` - delegates to `single.mk` or `cluster.mk` via `MODE`
- `single.mk` - single-instance targets
- `cluster.mk` - cluster targets
- `slow_ack_consumer.py` - Pika consumer holding acks 1-29.8 min
- `lib/perf-test.jar` - RabbitMQ PerfTest v2.24.0 (vendored)
- `lib/python/` - pika v1.3.2 (vendored)
- `GC_LAG.md` - investigation findings and test results
- `FUTURE.md` - planned follow-on experiments
