# Shibuya Production Deployment Guide

This guide covers deploying Shibuya-based applications to Kubernetes with proper health checks, monitoring, and graceful shutdown.

## Kubernetes Deployment

### Basic Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shibuya-worker
  labels:
    app: shibuya-worker
spec:
  replicas: 3
  selector:
    matchLabels:
      app: shibuya-worker
  template:
    metadata:
      labels:
        app: shibuya-worker
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics/prometheus"
    spec:
      terminationGracePeriodSeconds: 60  # Must exceed drainTimeout
      containers:
        - name: worker
          image: your-registry/shibuya-worker:latest
          ports:
            - name: metrics
              containerPort: 9090
          env:
            - name: METRICS_PORT
              value: "9090"
            - name: DRAIN_TIMEOUT_SECONDS
              value: "30"
            - name: STUCK_THRESHOLD_SECONDS
              value: "60"
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
          livenessProbe:
            httpGet:
              path: /health/live
              port: metrics
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: metrics
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 3
```

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: shibuya-worker-metrics
  labels:
    app: shibuya-worker
spec:
  selector:
    app: shibuya-worker
  ports:
    - name: metrics
      port: 9090
      targetPort: metrics
  type: ClusterIP
```

### PodDisruptionBudget

Ensure at least one replica is always available during voluntary disruptions:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: shibuya-worker-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: shibuya-worker
```

For larger deployments, use percentage:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: shibuya-worker-pdb
spec:
  maxUnavailable: 25%
  selector:
    matchLabels:
      app: shibuya-worker
```

## Resource Recommendations

### Memory

| Workload Type | Request | Limit | Notes |
|---------------|---------|-------|-------|
| Light (< 100 msg/s) | 128Mi | 512Mi | Small payloads |
| Medium (100-1000 msg/s) | 256Mi | 1Gi | Typical workload |
| Heavy (> 1000 msg/s) | 512Mi | 2Gi | Large payloads or complex handlers |

### CPU

| Workload Type | Request | Limit | Notes |
|---------------|---------|-------|-------|
| IO-bound | 100m | 500m | Database/network heavy |
| Balanced | 250m | 1000m | Typical workload |
| CPU-bound | 500m | 2000m | Complex processing |

### Tuning Tips

1. **Inbox Size**: Match to expected burst size. Default 100 is good for most cases.
2. **Concurrency**: For `Async` mode, set based on downstream capacity (database connections, API rate limits).
3. **Drain Timeout**: Set based on your longest expected handler execution time + buffer.

## Prometheus Configuration

### Scrape Config

Add to your Prometheus configuration:

```yaml
scrape_configs:
  - job_name: 'shibuya-workers'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: kubernetes_pod_name
```

### ServiceMonitor (Prometheus Operator)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: shibuya-worker
  labels:
    app: shibuya-worker
spec:
  selector:
    matchLabels:
      app: shibuya-worker
  endpoints:
    - port: metrics
      path: /metrics/prometheus
      interval: 15s
```

## Alerting Rules

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: shibuya-alerts
spec:
  groups:
    - name: shibuya.rules
      rules:
        # Processor stuck (no progress for 5 minutes)
        - alert: ShibuyaProcessorStuck
          expr: |
            shibuya_processor_state == 2
            and ON(processor_id) (time() - shibuya_processor_last_activity_seconds) > 300
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: "Processor {{ $labels.processor_id }} appears stuck"
            description: "Processor has been in processing state for over 5 minutes without progress."

        # High failure rate
        - alert: ShibuyaHighFailureRate
          expr: |
            rate(shibuya_messages_failed_total[5m])
            / rate(shibuya_messages_processed_total[5m]) > 0.1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High message failure rate on {{ $labels.processor_id }}"
            description: "More than 10% of messages are failing over the last 5 minutes."

        # Processor down
        - alert: ShibuyaProcessorDown
          expr: |
            shibuya_processor_state == 3
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Processor {{ $labels.processor_id }} has failed"
            description: "Processor is in failed state. Check logs for error details."

        # No processors running
        - alert: ShibuyaNoProcessors
          expr: |
            shibuya_processor_count == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "No Shibuya processors running"
            description: "The application has no active processors."

        # High memory usage
        - alert: ShibuyaHighMemory
          expr: |
            container_memory_usage_bytes{container="worker"}
            / container_spec_memory_limit_bytes{container="worker"} > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High memory usage on {{ $labels.pod }}"
            description: "Memory usage is above 85% of limit."

        # Messages backing up (inbox growing)
        - alert: ShibuyaBackpressure
          expr: |
            shibuya_inbox_size > shibuya_inbox_capacity * 0.8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Backpressure detected on {{ $labels.processor_id }}"
            description: "Inbox is more than 80% full, indicating processing cannot keep up."
```

## Graceful Shutdown

Shibuya supports graceful shutdown with configurable drain timeout:

```haskell
-- In your application
let shutdownConfig = ShutdownConfig { drainTimeout = 30 }  -- 30 seconds

-- When stopping
drained <- stopAppGracefully shutdownConfig appHandle
unless drained $
  logWarn "Forced shutdown - some messages may need reprocessing"
```

### Kubernetes Integration

1. Set `terminationGracePeriodSeconds` higher than your `drainTimeout`:
   ```yaml
   terminationGracePeriodSeconds: 60  # > drainTimeout of 30
   ```

2. Handle SIGTERM in your application:
   ```haskell
   import System.Posix.Signals

   main = do
     shutdownVar <- newEmptyMVar

     -- Install signal handler
     installHandler sigTERM (Catch $ putMVar shutdownVar ()) Nothing

     -- Start app
     Right appHandle <- runEff $ runApp ...

     -- Wait for shutdown signal
     takeMVar shutdownVar

     -- Graceful shutdown
     stopAppGracefully defaultShutdownConfig appHandle
   ```

## Health Check Endpoints

| Endpoint | Purpose | Response |
|----------|---------|----------|
| `GET /health/live` | Liveness probe | `{"alive": true}` |
| `GET /health/ready` | Readiness probe | `{"ready": true, "processors": {...}, "dependencies": [...]}` |
| `GET /health` | Debugging | Full status with all processor metrics |

### Readiness Criteria

The `/health/ready` endpoint returns `ready: false` (HTTP 503) when:
- Any processor is in `Failed` state
- Any processor is stuck (processing for > stuckThreshold)
- Any registered dependency check fails

### Configuring Thresholds

```haskell
let config = defaultConfig
      { livenessTimeoutMicros = 2_000_000  -- 2 second timeout
      , stuckThreshold = 120               -- 2 minutes before "stuck"
      }
```

## Next Steps

- See [RUNBOOKS.md](./RUNBOOKS.md) for operational procedures
- See [MONITORING.md](./MONITORING.md) for dashboard setup
