PERF_TEST_JAR := /home/ec2-user/rabbitmq-perf-test/target/perf-test.jar
JAVA_OPTS := -Xmx1700m
BASELINE_MINUTES := 7
NODE := guest:guest@10.0.1.90
MGMT := http://$(NODE):15672
URI := amqp://$(NODE):5672

.ONESHELL:
.PHONY: classic-policy clean webhook-consumer webhook-publisher main-workload setup

setup:
	sudo dnf install --assumeyes python python-pip
	python -m pip install pipenv
	pipenv install
	make -C $(HOME)/rabbitmq-perf-test binary

classic-policy:
	curl -sf -u guest:guest \
		-X PUT $(MGMT)/api/policies/%2F/classic-all \
		-H 'Content-Type: application/json' \
		-d '{"pattern":".*","definition":{"queue-version":2},"apply-to":"classic_queues"}'

webhook-consumer:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > webhook_consumer.log
	python3 webhook_consumer.py \
		--uri amqp://$(NODE):5672 \
		2>&1 | tee -a webhook_consumer.log

webhook-publisher:
	date -u +'started: %Y-%m-%dT%H:%M:%SZ' > webhook_publisher.log
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uri $(URI) \
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
		--variable-rate "2:$$(($(BASELINE_MINUTES) * 60))" \
		--variable-rate '5:86400' \
		--id main-workload \
		2>&1 | tee -a main_workload.log
