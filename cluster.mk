PERF_TEST_JAR := $(CURDIR)/lib/perf-test.jar
JAVA_OPTS := -Xmx1700m
BASELINE_MINUTES := 7

NODE0 ?= guest:guest@$(RMQ_NODE0)
NODE1 ?= guest:guest@$(RMQ_NODE1)
NODE2 ?= guest:guest@$(RMQ_NODE2)
MGMT := http://$(RMQ_NODE0):15672
VHOST := %2F
URIS := amqp://$(NODE0)/$(VHOST),amqp://$(NODE1):5672/$(VHOST),amqp://$(NODE2):5672/$(VHOST)

.ONESHELL:
.PHONY: classic-policy clean slow-ack-consumer slow-ack-publisher main-workload setup debug

debug:
	@echo "NODE0: $(NODE0)"
	@echo "NODE1: $(NODE1)"
	@echo "NODE2: $(NODE2)"
	@echo "MGMT:  $(MGMT)"
	@echo "VHOST: $(VHOST)"
	@echo "URIS:  $(URIS)"

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

ha-policy:
	curl -sf -u guest:guest \
		-X PUT $(MGMT)/api/policies/$(VHOST)/ha-all \
		-H 'Content-Type: application/json' \
		-d '{"pattern":".*","definition":{"ha-mode":"all","ha-sync-mode":"automatic","queue-version":2},"apply-to":"classic_queues"}'

create-vhost:
	curl -sf -u guest:guest \
		-X PUT $(MGMT)/api/vhosts/$(VHOST) \
		-H 'Content-Type: application/json' \
		-d '{}'
	curl -sf -u guest:guest \
		-X PUT $(MGMT)/api/permissions/$(VHOST)/guest \
		-H 'Content-Type: application/json' \
		-d '{"configure":".*","write":".*","read":".*"}'
	curl -sf -u guest:guest \
		-X PUT $(MGMT)/api/policies/$(VHOST)/ha-all \
		-H 'Content-Type: application/json' \
		-d '{"pattern":".*","definition":{"ha-mode":"all","ha-sync-mode":"automatic","queue-version":2},"apply-to":"classic_queues"}'

slow-ack-consumer:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > slow_ack_consumer.log
	python3 slow_ack_consumer.py \
		--uri amqp://$(NODE0):5672 \
		2>&1 | tee -a slow_ack_consumer.log

slow-ack-publisher:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > slow_ack_publisher.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uris $(URIS) \
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
		--uris $(URIS) \
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
