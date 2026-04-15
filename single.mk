PERF_TEST_JAR := $(CURDIR)/lib/perf-test.jar
JAVA_OPTS := -Xmx1700m
BASELINE_MINUTES := 7

NODE ?= guest:guest@$(RMQ_NODE)
MGMT := http://$(RMQ_NODE):15672
VHOST := %2F
URI := amqp://$(NODE):5672

.ONESHELL:
.PHONY: classic-policy clean slow-ack-consumer slow-ack-publisher main-workload gc-stress-workload burst-drain-workload fanout-setup fanout-publisher fanout-consumer setup debug

debug:
	@echo "NODE:  $(NODE)"
	@echo "MGMT:  $(MGMT)"
	@echo "VHOST: $(VHOST)"
	@echo "URI:   $(URI)"

setup:
	@echo "=== Checking Java ==="
	java -version
	@echo "=== Checking perf-test jar ==="
	java -jar $(PERF_TEST_JAR) --version
	@echo "=== Checking Python ==="
	python3 --version
	@echo "=== Checking pika ==="
	python3 -c "import sys; sys.path.insert(0, 'lib/python'); import pika; print('pika', pika.__version__)"
	@echo "=== All checks passed ==="

classic-policy:
	curl -sf -u guest:guest \
		-X PUT $(MGMT)/api/policies/%2F/classic-all \
		-H 'Content-Type: application/json' \
		-d '{"pattern":".*","definition":{"queue-version":2},"apply-to":"classic_queues"}'

slow-ack-consumer:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > slow_ack_consumer.log
	python3 slow_ack_consumer.py \
		--uri amqp://$(NODE):5672 \
		2>&1 | tee -a slow_ack_consumer.log

slow-ack-publisher:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > slow_ack_publisher.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uri $(URI) \
		--queue slow-ack-queue \
		--flag mandatory \
		--flag persistent \
		--auto-delete false \
		--producers 1 \
		--consumers 0 \
		--rate 3 \
		--size 122880 \
		--confirm 100 \
		--confirm-timeout $(CONFIRM_TIMEOUT) \
		--id slow-ack-publisher \
		2>&1 | tee -a slow_ack_publisher.log

clean:
	curl -s -u guest:guest $(MGMT)/api/queues | \
		jq -r '.[] | "/api/queues/" + (.vhost | @uri) + "/" + (.name | @uri)' | \
		xargs -I{} curl -sf -u guest:guest -X DELETE $(MGMT){}

main-workload:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > main_workload.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uri $(URI) \
		--queue-pattern 'repro-queue-%d' \
		--queue-pattern-from 1 \
		--queue-pattern-to 100 \
		--flag mandatory \
		--flag persistent \
		--auto-delete false \
		--producers 100 \
		--consumers 100 \
		--size 122880 \
		--confirm 100 \
		--confirm-timeout $(CONFIRM_TIMEOUT) \
		--variable-rate "2:$$(($(BASELINE_MINUTES) * 60))" \
		--variable-rate '5:86400' \
		--id main-workload \
		2>&1 | tee -a main_workload.log

gc-stress-workload:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > gc_stress_workload.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uri $(URI) \
		--queue gc-stress-queue \
		--flag persistent \
		--auto-delete false \
		--producers 1 \
		--consumers 2 \
		--size 2048 \
		--confirm 64 \
		--confirm-timeout $(CONFIRM_TIMEOUT) \
		--qos 2048 \
		--multi-ack-every 1024 \
		--variable-latency 500:10 --variable-latency 0:10 \
		--id gc-stress-workload \
		2>&1 | tee -a gc_stress_workload.log

burst-drain-workload:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > burst_drain_workload.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uri $(URI) \
		--queue burst-drain-queue \
		--flag persistent \
		--auto-delete false \
		--producers 1 \
		--consumers 1 \
		--size 524288 \
		--confirm 10 \
		--confirm-timeout $(CONFIRM_TIMEOUT) \
		--qos 100 \
		--variable-rate '50:30' \
		--variable-rate '0:30' \
		--id burst-drain-workload \
		2>&1 | tee -a burst_drain_workload.log

fanout-setup:
	curl -sf -u guest:guest \
		-X PUT $(MGMT)/api/exchanges/%2F/fanout-stress \
		-H 'Content-Type: application/json' \
		-d '{"type":"fanout","durable":true}'
	for i in 1 2 3 4 5; do \
		curl -sf -u guest:guest \
			-X PUT $(MGMT)/api/queues/%2F/fanout-queue-$$i \
			-H 'Content-Type: application/json' \
			-d '{"durable":true,"arguments":{"x-queue-version":2}}' && \
		curl -sf -u guest:guest \
			-X POST $(MGMT)/api/bindings/%2F/e/fanout-stress/q/fanout-queue-$$i \
			-H 'Content-Type: application/json' \
			-d '{"routing_key":"","arguments":{}}'; \
	done

fanout-publisher:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > fanout_publisher.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uri $(URI) \
		--exchange fanout-stress \
		--predeclared \
		--flag persistent \
		--producers 1 \
		--consumers 0 \
		--rate 500 \
		--size 4096 \
		--confirm 100 \
		--confirm-timeout $(CONFIRM_TIMEOUT) \
		--id fanout-publisher \
		2>&1 | tee -a fanout_publisher.log

fanout-consumer:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > fanout_consumer.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uri $(URI) \
		--queue-pattern 'fanout-queue-%d' \
		--queue-pattern-from 1 \
		--queue-pattern-to 5 \
		--predeclared \
		--producers 0 \
		--consumers 5 \
		--qos 500 \
		--multi-ack-every 100 \
		--consumer-rate 1000 \
		--id fanout-consumer \
		2>&1 | tee -a fanout_consumer.log
