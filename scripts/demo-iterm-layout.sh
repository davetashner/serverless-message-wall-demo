#!/bin/bash
# Opens iTerm2 with a multi-pane demo layout
# Requires iTerm2 to be installed

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
            write text "echo '=== WORKLOAD: Microservice Pods ==='"
            write text "kubectl get pods -n microservices -w"
        end tell

        -- Split COMMAND down: HEARTBEAT logs
        tell current session
            set heartbeat_session to (split horizontally with default profile)
        end tell
        tell heartbeat_session
            set name to "HEARTBEAT"
            write text "kubectl config use-context kind-workload"
            write text "echo '=== HEARTBEAT Logs ==='"
            write text "sleep 2 && kubectl logs -f deployment/heartbeat -n microservices"
        end tell

        -- Split HEARTBEAT right: COUNTER logs
        tell heartbeat_session
            set counter_session to (split vertically with default profile)
        end tell
        tell counter_session
            set name to "COUNTER"
            write text "kubectl config use-context kind-workload"
            write text "echo '=== COUNTER Logs ==='"
            write text "sleep 2 && kubectl logs -f deployment/counter -n microservices"
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
