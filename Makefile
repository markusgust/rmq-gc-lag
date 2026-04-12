PERF_TEST_JAR := /home/ec2-user/rabbitmq-perf-test/target/perf-test.jar
JAVA_OPTS := -Xmx1700m
BASELINE_MINUTES := 30
NODE0 := guest:guest@10.0.1.95
NODE1 := guest:guest@10.0.1.120
NODE2 := guest:guest@10.0.1.25
MGMT := http://$(NODE0):15672
VHOST := %2F
URIS := amqp://$(NODE0)/$(VHOST),amqp://$(NODE1):5672/$(VHOST),amqp://$(NODE2):5672/$(VHOST)

.ONESHELL:
.PHONY: ha-policy create-vhost clean webhook-consumer webhook-publisher main-workload

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

webhook-consumer:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > webhook_consumer.log
	python3 webhook_consumer.py \
		--uri amqp://$(NODE0):5672/$(VHOST) \
		2>&1 | tee -a webhook_consumer.log

webhook-publisher:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > webhook_publisher.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uris $(URIS) \
		--queue webhook_retry_queue \
		--flag mandatory \
		--flag persistent \
		--auto-delete false \
		--producers 1 \
		--consumers 0 \
		--rate 3 \
		--size 122880 \
		--confirm 100 \
		--id webhook-publisher \
		2>&1 | tee -a webhook_publisher.log

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
		--variable-rate "2:$$(($(BASELINE_MINUTES) * 60))" \
		--variable-rate '5:86400' \
		--id main-workload \
		2>&1 | tee -a main_workload.log
