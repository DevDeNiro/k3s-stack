# Makefile for K3s Stack Development

.PHONY: help helm-test helm-lint helm-template local-install local-uninstall vps-install

# Default target
help:
	@echo "Available targets:"
	@echo ""
	@echo "  Local (k3d):"
	@echo "    local-install   - Install local k3d cluster"
	@echo "    local-uninstall - Remove local k3d cluster"
	@echo ""
	@echo "  Helm:"
	@echo "    helm-test       - Run Helm lint and template validation"
	@echo "    helm-lint       - Run Helm lint on charts"
	@echo "    helm-template   - Generate and validate Helm templates"

# Local k3d targets
local-install:
	@./local/install.sh

local-uninstall:
	@./local/uninstall.sh

# Helm test target - lint common-library
helm-test: helm-lint helm-template
	@echo "Helm tests completed successfully!"

# Individual lint target
helm-lint:
	@echo "Running Helm lint..."
	@helm lint charts/common-library

# Template validation target
helm-template:
	@echo "Validating Helm templates..."
	@helm template test-release charts/common-library > /dev/null
	@echo "Template validation passed."
