# RabbitMQ Classic Queue GC Lag Reproduction

Reproduces classic queue message store GC lag on a single-instance RabbitMQ broker.

When a consumer holds acks for a long time, the unacked messages pin segment files in the shared message store. If a high-throughput queue is in the same message store, GC cannot reclaim those files even after the high-throughput messages are consumed and acknowledged. Disk usage grows until the consumer finally acks or the broker is restarted.

This repository was created to reproduce a production incident on Amazon MQ for RabbitMQ and to demonstrate the vhost isolation mitigation. See [FUTURE.md](FUTURE.md) for planned follow-on experiments.

## How It Works

Three processes run concurrently:

- **main-workload**: 100 classic queues (`repro-queue-1` through `repro-queue-100`) in the `/` vhost. 100 producers + 100 consumers, 120 KB messages, consumers acking immediately. Variable rate: 2 msg/s per producer (200 msg/s aggregate) for `BASELINE_MINUTES` (default: 7 minutes), then 5 msg/s per producer (500 msg/s aggregate) indefinitely.

- **webhook-publisher**: 1 producer publishing 3 msg/s to `webhook_retry_queue`.

- **webhook-consumer**: Pika consumer on `webhook_retry_queue` holding acks for a random 1–29.8 minute duration (up to 1000 messages in flight simultaneously).

## Prerequisites

On the host running the workload:

- Java with `/home/ec2-user/rabbitmq-perf-test/target/perf-test.jar`
- Python 3.9+ with pika: `pip3 install pika`
- RabbitMQ running locally (or set `NODE=guest:guest@<host>`)

## Makefile Targets

```bash
# Apply queue-version:2 policy to / vhost
make classic-policy

# Delete all queues
make clean

# Start the Pika webhook consumer
make webhook-consumer

# Start the webhook_retry_queue publisher
make webhook-publisher

# Start the 20-queue main workload
make main-workload
make main-workload BASELINE_MINUTES=45
```

Each target runs in the foreground. Start each in a separate terminal.
Log files are written to the current directory with a UTC timestamp on the first line.

## Running the Reproduction

```bash
make classic-policy
# terminal 1
make webhook-consumer
# terminal 2
make webhook-publisher
# terminal 3
make main-workload
```

Monitor disk free via the Prometheus endpoint:

```bash
curl -s http://localhost:15692/metrics | grep '^rabbitmq_disk_space_available_bytes'
```

Expected: disk free declines steadily. Rate accelerates after the spike at `BASELINE_MINUTES`.

## Files

- `Makefile` — all targets
- `webhook_consumer.py` — Pika consumer holding acks 1–29.8 min
- `FUTURE.md` — planned follow-on experiments
