NAMESPACE      := micewriter-infra
MINIO_RELEASE  := micewriter-minio
NESSIE_RELEASE := micewriter-nessie

# Path to local kubeconfig
HOME_DIR       := $(if $(USERPROFILE),$(USERPROFILE),$(HOME))
KUBE_CONFIG    ?= $(HOME_DIR)/.kube/config

KUBECTL        := kubectl --kubeconfig $(KUBE_CONFIG)
HELM           := helm --kubeconfig $(KUBE_CONFIG)

MINIO_CHART    := oci://registry-1.docker.io/bitnamicharts/minio
MINIO_VERSION  := 17.0.21
NESSIE_CHART   := nessie
NESSIE_VERSION := 0.107.6
NESSIE_REPO    := https://charts.projectnessie.org
TRINO_RELEASE  := trino
TRINO_REPO     := https://trinodb.github.io/charts
CERT_VERSION   := v1.20.2

MINIO_USER     := $(shell grep -m1 '^\s*rootUser:' minio/values.yaml | awk '{print $$2}')
MINIO_PASSWORD := $(shell grep -m1 '^\s*rootPassword:' minio/values.yaml | awk '{print $$2}')

.PHONY: up down status repo clean console query-up query-down test

## Add required Helm repos
repo:
	$(HELM) repo add nessie $(NESSIE_REPO)
	$(HELM) repo update

## Deploy MinIO and Nessie into the cluster
up: repo
	@echo "Installing cert-manager $(CERT_VERSION)..."
	$(KUBECTL) apply -f https://github.com/cert-manager/cert-manager/releases/download/$(CERT_VERSION)/cert-manager.yaml
	$(KUBECTL) wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
	@echo "Deploying in-cluster registry..."
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml > temp-ns.yaml
	$(KUBECTL) apply -f temp-ns.yaml
	rm -f temp-ns.yaml
	$(KUBECTL) apply -f registry/registry.yaml
	$(KUBECTL) rollout status deployment/registry -n $(NAMESPACE) --timeout=120s
	@echo "Deploying MinIO..."
	$(HELM) upgrade --install $(MINIO_RELEASE) $(MINIO_CHART) \
		--namespace $(NAMESPACE) --create-namespace \
		--version $(MINIO_VERSION) \
		--values minio/values.yaml \
		--wait
	@echo "Enabling MinIO native WebUI..."
	$(KUBECTL) set env deployment/$(MINIO_RELEASE) MINIO_BROWSER=on -n $(NAMESPACE)
	@echo "Provisioning MinIO iceberg bucket..."
	$(KUBECTL) exec -n $(NAMESPACE) deployment/$(MINIO_RELEASE) -- sh -c "mc alias set local http://localhost:9000 $(MINIO_USER) $(MINIO_PASSWORD) && mc mb local/iceberg --ignore-existing"
	@echo "Creating nessie-s3-creds Secret..."
	$(KUBECTL) create secret generic nessie-s3-creds \
		--from-literal=aws_access_key_id=$(MINIO_USER) \
		--from-literal=aws_secret_access_key=$(MINIO_PASSWORD) \
		-n $(NAMESPACE) \
		--dry-run=client -o yaml > temp-secret.yaml
	$(KUBECTL) apply -f temp-secret.yaml
	rm -f temp-secret.yaml
	@echo "Deploying Nessie..."
	$(HELM) upgrade --install $(NESSIE_RELEASE) $(NESSIE_CHART) \
		--repo $(NESSIE_REPO) \
		--namespace $(NAMESPACE) --create-namespace \
		--version $(NESSIE_VERSION) \
		--values nessie/values.yaml \
		--wait
	@echo ""
	@echo "✓ Local data lake is up via ServiceLB (LoadBalancer)."
	@echo "  MinIO console : http://k8s-node-1.local:9001     (user: $(MINIO_USER) / $(MINIO_PASSWORD))"
	@echo "  MinIO S3 API  : http://k8s-node-1.local:9000"
	@echo "  Nessie API v1 : http://k8s-node-1.local:19120/api/v1"
	@echo "  Nessie API v2 : http://k8s-node-1.local:19120/api/v2"
	@echo ""

## Tear down both releases (namespace and PVCs are kept to avoid accidental data loss)
down:
	$(HELM) uninstall $(NESSIE_RELEASE) --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall $(MINIO_RELEASE)  --namespace $(NAMESPACE) --ignore-not-found

## Show pod status
status:
	$(KUBECTL) get pods -n $(NAMESPACE) -o wide

## Port-forward MinIO console to localhost:9001
console:
	@echo "Forwarding MinIO Console to http://localhost:9001 (Press Ctrl+C to stop)"
	@while true; do \
		$(KUBECTL) port-forward svc/$(MINIO_RELEASE) 9001:9001 --address 0.0.0.0 -n $(NAMESPACE); \
		sleep 0.5; \
	done

## Deploy Trino and Querybook
query-up:
	@echo "Deploying Trino..."
	$(HELM) upgrade --install $(TRINO_RELEASE) trino \
		--repo $(TRINO_REPO) \
		--namespace $(NAMESPACE) \
		--values trino/values.yaml \
		--wait
	@echo "Deploying Querybook (MySQL, Redis, web, worker)..."
	$(KUBECTL) apply -f querybook/querybook.yaml
	@echo ""
	@echo "✓ Query stack is up."
	@echo "  Trino         : http://k8s-node-1.local:8080"
	@echo "  Querybook     : http://k8s-node-1.local:10001"
	@echo ""
	@echo "Register Trino in Querybook admin UI (/admin/query_engine/):"
	@echo "  Language: trino  |  Host: trino.$(NAMESPACE).svc.cluster.local  |  Port: 8080  |  Catalog: iceberg"

## Tear down Trino and Querybook
query-down:
	$(HELM) uninstall $(TRINO_RELEASE) --namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete -f querybook/querybook.yaml --ignore-not-found

## Run integration tests against Trino
test:
	pwsh ./test.ps1

## Purge PVCs to reset state completely
clean: down
	$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found
