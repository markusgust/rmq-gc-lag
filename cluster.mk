PERF_TEST_JAR := $(CURDIR)/lib/perf-test.jar
JAVA_OPTS := -Xmx1700m
BASELINE_MINUTES := 7

AMQP_URL0 ?= amqp://guest:guest@localhost:5672
AMQP_URL1 ?= amqp://guest:guest@localhost:5672
AMQP_URL2 ?= amqp://guest:guest@localhost:5672

# Parse URL components from primary node for management API access
_USERINFO := $(shell echo '$(AMQP_URL0)' | sed -n 's|^amqps\{0,1\}://\([^@]*\)@.*|\1|p')
_USER     := $(shell echo '$(_USERINFO)' | sed 's|:.*||')
_HOST     := $(shell echo '$(AMQP_URL0)' | sed -n 's|^amqps\{0,1\}://[^@]*@\([^:/]*\).*|\1|p')
_VHOST    := $(shell echo '$(AMQP_URL0)' | sed -n 's|^amqps\{0,1\}://[^@]*@[^/]*/\(.*\)|\1|p')
MGMT_URL  ?= https://$(_HOST)
VHOST     := $(if $(_VHOST),$(_VHOST),%2F)
URIS      := $(AMQP_URL0),$(AMQP_URL1),$(AMQP_URL2)

.ONESHELL:
.PHONY: ha-policy create-vhost clean slow-ack-consumer slow-ack-publisher main-workload setup debug

debug:
	@echo "AMQP_URL0: $(AMQP_URL0)"
	@echo "AMQP_URL1: $(AMQP_URL1)"
	@echo "AMQP_URL2: $(AMQP_URL2)"
	@echo "MGMT_URL:  $(MGMT_URL)"
	@echo "VHOST:     $(VHOST)"
	@echo "URIS:      $(URIS)"

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
	curl -sf -u '$(_USERINFO)' \
		-X PUT $(MGMT_URL)/api/policies/$(VHOST)/ha-all \
		-H 'Content-Type: application/json' \
		-d '{"pattern":".*","definition":{"ha-mode":"all","ha-sync-mode":"automatic","queue-version":2},"apply-to":"classic_queues"}'

create-vhost:
	curl -sf -u '$(_USERINFO)' \
		-X PUT $(MGMT_URL)/api/vhosts/$(VHOST) \
		-H 'Content-Type: application/json' \
		-d '{}'
	curl -sf -u '$(_USERINFO)' \
		-X PUT $(MGMT_URL)/api/permissions/$(VHOST)/$(_USER) \
		-H 'Content-Type: application/json' \
		-d '{"configure":".*","write":".*","read":".*"}'
	curl -sf -u '$(_USERINFO)' \
		-X PUT $(MGMT_URL)/api/policies/$(VHOST)/ha-all \
		-H 'Content-Type: application/json' \
		-d '{"pattern":".*","definition":{"ha-mode":"all","ha-sync-mode":"automatic","queue-version":2},"apply-to":"classic_queues"}'

slow-ack-consumer:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > slow_ack_consumer.log
	python3 slow_ack_consumer.py \
		--uri '$(AMQP_URL0)' \
		2>&1 | tee -a slow_ack_consumer.log

slow-ack-publisher:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > slow_ack_publisher.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uris '$(URIS)' \
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
	curl -s -u '$(_USERINFO)' $(MGMT_URL)/api/queues | \
		jq -r '.[] | "/api/queues/" + (.vhost | @uri) + "/" + (.name | @uri)' | \
		xargs -I{} curl -sf -u '$(_USERINFO)' -X DELETE $(MGMT_URL){}

main-workload:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > main_workload.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uris '$(URIS)' \
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
