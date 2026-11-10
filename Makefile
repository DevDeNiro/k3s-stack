# Makefile for K3s Stack Development

.PHONY: help lint helm-test helm-lint helm-template local-install local-deploy-app local-uninstall

SHELL_SCRIPTS := $(shell find vps local -type f -name '*.sh' | sort)
SHELLCHECK_IMAGE := koalaman/shellcheck:stable

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

helm-lint:
	@echo "Running Helm lint..."
	@helm lint charts/common-library
	@helm lint vps/postgres-backup

# common-library is a library chart: Helm cannot render it on its own
helm-template:
	@echo "Validating Helm templates..."
	@helm template postgres-backup vps/postgres-backup --namespace storage > /dev/null
	@echo "Template validation passed."
