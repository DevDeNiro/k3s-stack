# Makefile for K3s Stack Development

.PHONY: help lint helm-test helm-external-test alloy-test helm-lint helm-template local-install local-deploy-app local-uninstall

SHELL_SCRIPTS := $(shell find vps local -type f -name '*.sh' | sort)
SHELLCHECK_IMAGE := koalaman/shellcheck:stable

# postgres-backup with the off-site copy enabled (example repository, pinned restic)
RESTIC_VERSION := $(shell . vps/config/versions.env && echo "$$RESTIC_VERSION")
OFFSITE_TEST_VALUES := --set offsite.enabled=true \
	--set-string offsite.repository=s3:https://s3.example.com/my-bucket/k3s-stack \
	--set-string offsite.region=example-region \
	--set-string offsite.image.tag=$(RESTIC_VERSION)

# Default target
help:
	@echo "Available targets:"
	@echo ""
	@echo "  Local (k3d):"
	@echo "    local-install     - Install local k3d cluster"
	@echo "    local-deploy-app  - Deploy an application chart (APP=<name>)"
	@echo "    local-uninstall   - Remove local k3d cluster"
	@echo ""
	@echo "  Checks:"
	@echo "    lint            - ShellCheck on every script (local binary or Docker image)"
	@echo "    helm-test       - Run Helm lint and template validation"
	@echo "    helm-external-test - Render external VPS/local charts (network, Helm and Ruby required)"
	@echo "    alloy-test      - Test redaction and positions offline (Python 3 and Docker required)"
	@echo "    helm-lint       - Run Helm lint on charts"
	@echo "    helm-template   - Generate and validate Helm templates"

# ShellCheck (settings: .shellcheckrc)
lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SHELL_SCRIPTS); \
	else \
		docker run --rm -v "$(CURDIR):/mnt" -w /mnt $(SHELLCHECK_IMAGE) $(SHELL_SCRIPTS); \
	fi
	@echo "ShellCheck passed."

# Local k3d targets
local-install:
	@./local/install.sh

local-deploy-app:
	@test -n "$(APP)" || { echo "usage: make local-deploy-app APP=<name>"; exit 1; }
	@./local/deploy-app.sh "$(APP)"

local-uninstall:
	@./local/uninstall.sh

# Helm checks: lint every chart, render the installable ones
helm-test: helm-lint helm-template
	@echo "Helm tests completed successfully!"

# Chart repositories and OCI downloads are isolated from the user's Helm config.
helm-external-test:
	@bash vps/scripts/test-external-charts.sh

# Uses only synthetic logs and a cached official Alloy image, without networking.
alloy-test:
	@python3 vps/scripts/test-alloy.py vps/values/alloy.yaml

helm-lint:
	@echo "Running Helm lint..."
	@helm lint charts/common-library
	@helm lint vps/postgres-backup
	@helm lint vps/postgres-backup $(OFFSITE_TEST_VALUES)

# common-library is a library chart: Helm cannot render it on its own
helm-template:
	@echo "Validating Helm templates..."
	@helm template postgres-backup vps/postgres-backup --namespace storage > /dev/null
	@helm template postgres-backup vps/postgres-backup --namespace storage $(OFFSITE_TEST_VALUES) > /dev/null
	@echo "Template validation passed."
