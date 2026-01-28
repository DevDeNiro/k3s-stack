#!/bin/bash
set -euo pipefail

# =============================================================================
# Apply Configuration to Templates
# Generates manifests from templates using config.env values
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${VPS_DIR}/config.env"
TEMPLATES_DIR="${VPS_DIR}/manifests/templates"
OUTPUT_DIR="${VPS_DIR}/manifests"

# =============================================================================
# Usage
# =============================================================================
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Generate manifests from templates using config.env values."
    echo ""
    echo "Options:"
    echo "  --check    Validate config without generating files"
    echo "  --help     Show this help"
    echo ""
    echo "Templates: ${TEMPLATES_DIR}/*.tpl"
    echo "Output:    ${OUTPUT_DIR}/"
    exit 0
}

# =============================================================================
# Load configuration
# =============================================================================
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: Configuration file not found: ${CONFIG_FILE}${NC}"
        echo ""
        echo -e "${YELLOW}Create it from the example:${NC}"
        echo "  cp ${VPS_DIR}/config.env.example ${CONFIG_FILE}"
        echo ""
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    # Export variables for envsubst
    export SCM_PROVIDER="${SCM_PROVIDER:-}"
    export SCM_ORGANIZATION="${SCM_ORGANIZATION:-}"
    export REGISTRY_BASE="${REGISTRY_BASE:-}"
    export LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
}

# =============================================================================
# Validate configuration
# =============================================================================
validate_config() {
    echo -e "${YELLOW}>>> Validating configuration...${NC}"
    
    local errors=0
    
    if [[ -z "$SCM_PROVIDER" ]]; then
        echo -e "${RED}  ✗ SCM_PROVIDER is not set${NC}"
        ((errors++))
    elif [[ "$SCM_PROVIDER" != "github" && "$SCM_PROVIDER" != "gitlab" ]]; then
        echo -e "${RED}  ✗ SCM_PROVIDER must be 'github' or 'gitlab' (got: $SCM_PROVIDER)${NC}"
        ((errors++))
    else
        echo -e "${GREEN}  ✓ SCM_PROVIDER: $SCM_PROVIDER${NC}"
    fi
    
    if [[ -z "$SCM_ORGANIZATION" ]]; then
        echo -e "${RED}  ✗ SCM_ORGANIZATION is not set${NC}"
        ((errors++))
    else
        echo -e "${GREEN}  ✓ SCM_ORGANIZATION: $SCM_ORGANIZATION${NC}"
    fi
    
    if [[ -z "$REGISTRY_BASE" ]]; then
        echo -e "${RED}  ✗ REGISTRY_BASE is not set${NC}"
        ((errors++))
    else
        echo -e "${GREEN}  ✓ REGISTRY_BASE: $REGISTRY_BASE${NC}"
    fi
    
    if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
        echo -e "${RED}  ✗ LETSENCRYPT_EMAIL is not set${NC}"
        ((errors++))
    elif [[ ! "$LETSENCRYPT_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        echo -e "${RED}  ✗ LETSENCRYPT_EMAIL is not a valid email${NC}"
        ((errors++))
    else
        echo -e "${GREEN}  ✓ LETSENCRYPT_EMAIL: $LETSENCRYPT_EMAIL${NC}"
    fi
    
    if [[ $errors -gt 0 ]]; then
        echo ""
        echo -e "${RED}Configuration has $errors error(s). Fix config.env and retry.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Configuration valid${NC}"
}

# =============================================================================
# Process templates
# =============================================================================
process_templates() {
    echo -e "${YELLOW}>>> Processing templates...${NC}"
    
    # Only substitute our specific variables (not ArgoCD's {{repository}} etc.)
    local vars='${SCM_PROVIDER} ${SCM_ORGANIZATION} ${REGISTRY_BASE} ${LETSENCRYPT_EMAIL}'
    
    for template in "${TEMPLATES_DIR}"/*.tpl; do
        if [[ ! -f "$template" ]]; then
            echo -e "${YELLOW}  No templates found in ${TEMPLATES_DIR}${NC}"
            return 0
        fi
        
        local filename
        filename=$(basename "$template" .tpl)
        local output="${OUTPUT_DIR}/${filename}"
        
        envsubst "$vars" < "$template" > "$output"
        echo -e "${GREEN}  ✓ Generated: ${filename}${NC}"
    done
}

# =============================================================================
# Main
# =============================================================================
main() {
    local check_only=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                check_only=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                ;;
        esac
    done
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}         Apply Configuration to Templates                      ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    load_config
    validate_config
    
    if [[ "$check_only" == "true" ]]; then
        echo ""
        echo -e "${GREEN}Configuration check passed.${NC}"
        exit 0
    fi
    
    process_templates
    
    echo ""
    echo -e "${GREEN}✓ Manifests generated successfully${NC}"
    echo -e "${YELLOW}Apply with: kubectl apply -f ${OUTPUT_DIR}/<manifest>.yaml${NC}"
}

main "$@"
