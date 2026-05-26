NAMESPACE      := micewriter-infra
MINIO_RELEASE  := micewriter-minio
NESSIE_RELEASE := micewriter-nessie

# Path to local kubeconfig
HOME_DIR       := $(if $(USERPROFILE),$(USERPROFILE),$(HOME))
KUBE_CONFIG    ?= $(HOME_DIR)/.kube/config

# Dockerized commands
KUBECTL        := docker run --rm -i -v "$(KUBE_CONFIG):/.kube/config" -e KUBECONFIG=/.kube/config bitnami/kubectl:latest
HELM           := docker run --rm -i -v "$(KUBE_CONFIG):/.kube/config" -v "$(CURDIR):/workspace" -w /workspace -e KUBECONFIG=/.kube/config alpine/helm:latest

MINIO_CHART    := oci://registry-1.docker.io/bitnamicharts/minio
MINIO_VERSION  := 17.0.21
NESSIE_CHART   := nessie
NESSIE_VERSION := 0.69.0
NESSIE_REPO    := https://charts.projectnessie.org

.PHONY: up down status repo clean

## Add required Helm repos
repo:
	$(HELM) repo add nessie $(NESSIE_REPO)
	$(HELM) repo update

## Deploy MinIO and Nessie into the cluster
up: repo
	$(HELM) upgrade --install $(MINIO_RELEASE) $(MINIO_CHART) \
		--namespace $(NAMESPACE) --create-namespace \
		--version $(MINIO_VERSION) \
		--values minio/values.yaml \
		--wait
	$(HELM) upgrade --install $(NESSIE_RELEASE) nessie/$(NESSIE_CHART) \
		--namespace $(NAMESPACE) --create-namespace \
		--version $(NESSIE_VERSION) \
		--values nessie/values.yaml \
		--wait
	@echo ""
	@echo "✓ Local data lake is up via ServiceLB (LoadBalancer)."
	@echo "  MinIO console : http://k8s-node-1.local:9001     (user: micewriter / micewriter123)"
	@echo "  MinIO S3 API  : http://k8s-node-1.local:9000"
	@echo "  Nessie REST   : http://k8s-node-1.local:19120/api/v1"
	@echo "  Iceberg REST  : http://k8s-node-1.local:19120/iceberg/v1"
	@echo ""

## Tear down both releases (namespace and PVCs are kept to avoid accidental data loss)
down:
	$(HELM) uninstall $(NESSIE_RELEASE) --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall $(MINIO_RELEASE)  --namespace $(NAMESPACE) --ignore-not-found

## Show pod status
status:
	$(KUBECTL) get pods -n $(NAMESPACE) -o wide

## Purge PVCs to reset state completely
clean: down
	$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found
