#!/bin/bash
# Opens iTerm2 with a multi-pane demo layout
# Requires iTerm2 to be installed
#
# Layout:
#   ┌─────────────────┬─────────────────┐
#   │ COMMAND         │ ACTUATOR        │
#   │ (run demo here) │ managed -w      │
#   ├─────────────────┼─────────────────┤
#   │ HEARTBEAT       │ WORKLOAD        │
#   │ logs -f         │ pods -w         │
#   ├─────────────────┼─────────────────┤
#   │ COUNTER         │                 │
#   │ logs -f         │                 │
#   └─────────────────┴─────────────────┘

osascript <<'APPLESCRIPT'
tell application "iTerm2"
    activate

    -- Create new window
    create window with default profile

    tell current session of current window
        set name to "COMMAND"
        write text "# Demo command pane - run commands here"
        write text "cd ~/Development/serverless-message-wall-demo"
        write text "echo ''"
        write text "echo '=== DEMO READY ==='"
        write text "echo 'Panes: COMMAND (here), ACTUATOR, WORKLOAD, HEARTBEAT, COUNTER'"
        write text "echo ''"
        write text "echo 'Quick commands:'"
        write text "echo '  ./scripts/demo-preflight.sh      # Check readiness'"
        write text "echo '  ./scripts/demo-multi-cluster.sh  # Run multi-cluster demo'"
        write text "echo '  ./scripts/demo-reconciliation.sh # Run self-healing demo'"
        write text "echo ''"
    end tell

    tell current window
        -- Split right: ACTUATOR managed resources
        tell current session
            set actuator_session to (split vertically with default profile)
        end tell
        tell actuator_session
            set name to "ACTUATOR"
            write text "kubectl config use-context kind-actuator"
            write text "echo '=== ACTUATOR: Crossplane Managed Resources ==='"
            write text "kubectl get managed -w"
        end tell

        -- Split ACTUATOR down: WORKLOAD pods
        tell actuator_session
            set workload_session to (split horizontally with default profile)
        end tell
        tell workload_session
            set name to "WORKLOAD"
            write text "kubectl config use-context kind-workload"
            write text "echo '=== WORKLOAD: Order Platform Pods ==='"
            write text "kubectl get pods --all-namespaces -l app.kubernetes.io/managed-by=argocd -w"
        end tell

        -- Split COMMAND down: HEARTBEAT logs
        tell current session
            set heartbeat_session to (split horizontally with default profile)
        end tell
        tell heartbeat_session
            set name to "HEARTBEAT"
            write text "kubectl config use-context kind-workload"
            write text "echo '=== HEARTBEAT Logs (platform-ops-dev) ==='"
            write text "sleep 2 && kubectl logs -f deployment/heartbeat -n platform-ops-dev"
        end tell

        -- Split HEARTBEAT right: COUNTER logs
        tell heartbeat_session
            set counter_session to (split vertically with default profile)
        end tell
        tell counter_session
            set name to "COUNTER"
            write text "kubectl config use-context kind-workload"
            write text "echo '=== COUNTER Logs (data-dev) ==='"
            write text "sleep 2 && kubectl logs -f deployment/counter -n data-dev"
        end tell

    end tell
end tell
APPLESCRIPT

echo "iTerm2 demo layout opened"
echo ""
echo "Layout:"
echo "┌─────────────────┬─────────────────┐"
echo "│ COMMAND         │ ACTUATOR        │"
echo "│ (run demo here) │ managed -w      │"
echo "├─────────────────┼─────────────────┤"
echo "│ HEARTBEAT       │ WORKLOAD        │"
echo "│ logs -f         │ pods -w         │"
echo "├─────────────────┼─────────────────┤"
echo "│ COUNTER         │                 │"
echo "│ logs -f         │                 │"
echo "└─────────────────┴─────────────────┘"
echo ""
echo "Namespaces used:"
echo "  • platform-ops-dev (heartbeat, sentinel)"
echo "  • data-dev (counter, reporter)"
echo "  • customer-dev (greeter, weather)"
echo "  • integrations-dev (pinger, ticker)"
echo "  • compliance-dev (auditor, quoter)"
