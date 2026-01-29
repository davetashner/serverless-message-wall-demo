# Workload Microservices

10 minimal microservices that generate sparse, observable logs for demo purposes.

## Services

| Name | Log Interval | Description |
|------|--------------|-------------|
| heartbeat | 30s | Periodic health pulse with counter |
| ticker | 45s | Timestamp logging |
| greeter | 40s | Random friendly greetings |
| counter | 20s | Simple incrementing counter |
| weather | 60s | Fake weather updates |
| quoter | 55s | Random inspirational quotes |
| pinger | 25s | Simulated upstream latency checks |
| auditor | 35s | Fake audit event logging |
| reporter | 50s | Summary status reports |
| sentinel | 45s | Watchdog status messages |

## Usage

### Build the container image

```bash
cd app/microservices
./build.sh

# Load into kind clusters
kind load docker-image messagewall-microservice:latest --name workload
```

### Publish to ConfigHub

```bash
# Create space and publish manifests
scripts/publish-workloads-to-confighub.sh --apply
```

### Watch logs

```bash
# Single service
kubectl logs -f deployment/heartbeat -n microservices --context kind-workload

# All services
kubectl logs -f -l tier=microservices -n microservices --context kind-workload
```

## Configuration

Each service is configured via environment variables:

- `SERVICE_NAME` - Which service behavior to use (heartbeat, ticker, etc.)
- `LOG_INTERVAL` - Seconds between log messages (default: 30)

To change behavior, edit the deployment manifest and republish to ConfigHub.
