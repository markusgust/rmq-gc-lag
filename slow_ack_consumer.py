#!/usr/bin/env python3
"""
slow_ack_consumer.py - Simulates slow-ack-queue consumer behavior.

Consumes from slow-ack-queue and holds acks for a random duration
between 1 and 29.8 minutes, simulating the customer's long consumer timeout.
If more than 1000 messages are currently held, new messages are acked immediately.

Cross-thread acks use connection.add_callback_threadsafe() per the pika
basic_consumer_threaded.py example.

Usage:
    python3 slow_ack_consumer.py [--uri amqp://guest:guest@localhost:5672]
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib", "python"))

import argparse
import functools
import logging
import random
import threading
import time

import pika

QUEUE_NAME = "slow-ack-queue"
MAX_HELD = 1000
MIN_ACK_DELAY = 60.0
MAX_ACK_DELAY = 29.8 * 60

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("slow_ack_consumer.log"),
    ],
)
log = logging.getLogger(__name__)


def ack_message(channel, delivery_tag):
    if channel.is_open:
        channel.basic_ack(delivery_tag=delivery_tag)


def hold_and_ack(connection, channel, delivery_tag, delay):
    time.sleep(delay)
    cb = functools.partial(ack_message, channel, delivery_tag)
    connection.add_callback_threadsafe(cb)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--uri", default="amqp://guest:guest@localhost:5672")
    args = parser.parse_args()

    params = pika.URLParameters(args.uri)
    params.heartbeat = 3600

    connection = pika.BlockingConnection(params)
    channel = connection.channel()
    channel.queue_declare(queue=QUEUE_NAME, durable=True)

    # Use a mutable container so the worker closure can decrement without nonlocal
    held_count = [0]
    held_lock = threading.Lock()

    def on_message(ch, method, _properties, _body):
        with held_lock:
            current = held_count[0]

        if current >= MAX_HELD:
            ch.basic_ack(delivery_tag=method.delivery_tag)
            log.debug("immediate ack (held=%d)", current)
            return

        delay = random.uniform(MIN_ACK_DELAY, MAX_ACK_DELAY)

        with held_lock:
            held_count[0] += 1

        def worker():
            hold_and_ack(connection, ch, method.delivery_tag, delay)
            with held_lock:
                held_count[0] -= 1

        t = threading.Thread(target=worker, daemon=True)
        t.start()
        log.debug(
            "holding tag %d for %.1f min (held=%d)",
            method.delivery_tag,
            delay / 60,
            current + 1,
        )

    channel.basic_qos(prefetch_count=MAX_HELD + 100)
    channel.basic_consume(queue=QUEUE_NAME, on_message_callback=on_message)

    log.info(
        "Consuming from %s (hold range: %.0f-%.0f min, max held: %d)",
        QUEUE_NAME,
        MIN_ACK_DELAY / 60,
        MAX_ACK_DELAY / 60,
        MAX_HELD,
    )

    try:
        channel.start_consuming()
    except KeyboardInterrupt:
        channel.stop_consuming()
    finally:
        connection.close()


if __name__ == "__main__":
    main()
