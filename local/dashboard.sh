#!/bin/bash

# Dashboard Manager - Start, stop, and manage Kubernetes Dashboard access

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

DASHBOARD_URL="https://localhost:8443"
PID_FILE="dashboard_portforward.pid"
TOKEN_FILE="dashboard_token.txt"

# Function to check if port-forward is running
is_port_forward_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            rm -f "$PID_FILE"
            return 1
        fi
    fi
    return 1
}

# Function to start port-forward
start_port_forward() {
    if is_port_forward_running; then
        echo -e "${GREEN}✓ Dashboard port-forward already running${NC}"
        echo -e "${GREEN}Access: $DASHBOARD_URL${NC}"
        return 0
    fi

    echo -e "${YELLOW}Starting Dashboard port-forward...${NC}"

    # Check if dashboard is deployed
    if ! kubectl get svc kubernetes-dashboard-kong-proxy -n kubernetes-dashboard >/dev/null 2>&1; then
        echo -e "${RED}Error: Kubernetes Dashboard not found${NC}"
        echo -e "${YELLOW}Install it first with: ./install.sh${NC}"
        return 1
    fi

    # Start port-forward in background
    nohup kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443 \
        > dashboard_port_forward.log 2>&1 &

    local pid=$!
    echo "$pid" > "$PID_FILE"

    # Wait and verify
    sleep 3
    if is_port_forward_running; then
        echo -e "${GREEN}✓ Dashboard port-forward started successfully${NC}"
        echo -e "${GREEN}Access: $DASHBOARD_URL${NC}"
        echo -e "${YELLOW}PID: $pid saved to $PID_FILE${NC}"
        return 0
    else
        echo -e "${RED}Failed to start port-forward${NC}"
        return 1
    fi
}

# Function to stop port-forward
stop_port_forward() {
    if is_port_forward_running; then
        local pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        echo -e "${GREEN}✓ Dashboard port-forward stopped${NC}"
    else
        echo -e "${YELLOW}Dashboard port-forward not running${NC}"
    fi
}

# Function to get dashboard token
get_token() {
    if [ -f "$TOKEN_FILE" ]; then
        echo -e "${GREEN}Dashboard token (from $TOKEN_FILE):${NC}"
        cat "$TOKEN_FILE"
        echo
    else
        echo -e "${YELLOW}Generating new token...${NC}"
        if kubectl get serviceaccount admin-user -n kubernetes-dashboard >/dev/null 2>&1; then
            local token=$(kubectl -n kubernetes-dashboard create token admin-user --duration=24h)
            echo "$token" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            echo -e "${GREEN}New token generated and saved to $TOKEN_FILE:${NC}"
            echo "$token"
        else
            echo -e "${RED}Error: admin-user service account not found${NC}"
            echo -e "${YELLOW}Run ./install.sh to create it${NC}"
        fi
    fi
}

# Function to show status
show_status() {
    echo -e "${BLUE}=== Dashboard Status ===${NC}"

    # Check if deployed
    if kubectl get deployment -n kubernetes-dashboard >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Dashboard deployed${NC}"
        local ready_pods=$(kubectl get pods -n kubernetes-dashboard --no-headers | grep Running | wc -l)
        echo -e "${GREEN}✓ $ready_pods pods running${NC}"
    else
        echo -e "${RED}✗ Dashboard not deployed${NC}"
        return 1
    fi

    # Check port-forward
    if is_port_forward_running; then
        echo -e "${GREEN}✓ Port-forward active (PID: $(cat $PID_FILE))${NC}"
        echo -e "${GREEN}✓ Access: $DASHBOARD_URL${NC}"
    else
        echo -e "${YELLOW}⚠ Port-forward not running${NC}"
    fi

    # Check token
    if [ -f "$TOKEN_FILE" ]; then
        echo -e "${GREEN}✓ Token available in $TOKEN_FILE${NC}"
    else
        echo -e "${YELLOW}⚠ No token file found${NC}"
    fi
}

# Function to open browser
open_browser() {
    echo -e "${YELLOW}Opening Dashboard in browser...${NC}"

    if ! is_port_forward_running; then
        echo -e "${YELLOW}Port-forward not running, starting it first...${NC}"
        start_port_forward
        sleep 2
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "$DASHBOARD_URL"
    elif command -v xdg-open > /dev/null 2>&1; then
        xdg-open "$DASHBOARD_URL"
    else
        echo -e "${YELLOW}Cannot open browser automatically${NC}"
        echo -e "${GREEN}Please open: $DASHBOARD_URL${NC}"
    fi
}

# Function to show help
show_help() {
    echo -e "${BLUE}Dashboard Manager - Kubernetes Dashboard Helper${NC}"
    echo
    echo -e "${YELLOW}Usage: $0 [command]${NC}"
    echo
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  ${GREEN}start${NC}     Start Dashboard port-forward"
    echo -e "  ${GREEN}stop${NC}      Stop Dashboard port-forward"
    echo -e "  ${GREEN}restart${NC}   Restart Dashboard port-forward"
    echo -e "  ${GREEN}status${NC}    Show Dashboard status"
    echo -e "  ${GREEN}token${NC}     Show/generate access token"
    echo -e "  ${GREEN}open${NC}      Open Dashboard in browser"
    echo -e "  ${GREEN}logs${NC}      Show port-forward logs"
    echo -e "  ${GREEN}help${NC}      Show this help"
    echo
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0 start     # Start port-forward"
    echo -e "  $0 open      # Start + open browser"
    echo -e "  $0 token     # Get access token"
}

# Function to show logs
show_logs() {
    if [ -f "dashboard_port_forward.log" ]; then
        echo -e "${YELLOW}Port-forward logs:${NC}"
        tail -20 dashboard_port_forward.log
    else
        echo -e "${YELLOW}No log file found${NC}"
    fi
}

# Main script logic
case "${1:-help}" in
    "start")
        start_port_forward
        ;;
    "stop")
        stop_port_forward
        ;;
    "restart")
        stop_port_forward
        sleep 1
        start_port_forward
        ;;
    "status")
        show_status
        ;;
    "token")
        get_token
        ;;
    "open")
        open_browser
        ;;
    "logs")
        show_logs
        ;;
    "help"|*)
        show_help
        ;;
esac