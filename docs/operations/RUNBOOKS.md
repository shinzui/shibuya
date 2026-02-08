# Shibuya Operational Runbooks

This document provides step-by-step procedures for common operational tasks.

---

## Graceful Restart

### When to Use
- Deploying new code
- Configuration changes
- Routine maintenance

### Procedure

1. **Verify current state**
   ```bash
   kubectl get pods -l app=shibuya-worker
   curl http://<pod-ip>:9090/health/ready
   ```

2. **Initiate rolling restart**
   ```bash
   kubectl rollout restart deployment/shibuya-worker
   ```

3. **Monitor the rollout**
   ```bash
   kubectl rollout status deployment/shibuya-worker
   ```

4. **Verify new pods are healthy**
   ```bash
   kubectl get pods -l app=shibuya-worker
   # All pods should be Running and Ready
   ```

### What Happens During Restart

1. Kubernetes sends SIGTERM to the pod
2. Shibuya receives signal and calls `stopAppGracefully`
3. Adapters stop producing new messages
4. In-flight messages are processed (up to `drainTimeout`)
5. Pod terminates cleanly
6. New pod starts and becomes ready

### Troubleshooting

**Pod takes too long to terminate:**
- Check if `terminationGracePeriodSeconds` > `drainTimeout`
- Check for stuck handlers in logs
- May need to force delete: `kubectl delete pod <name> --force --grace-period=0`

**New pods not becoming ready:**
- Check `/health/ready` response for failure reason
- Check dependency connectivity
- Review startup logs

---

## Scaling Up/Down

### Scaling Up

1. **Check current capacity**
   ```bash
   kubectl get deployment shibuya-worker
   curl http://<metrics-svc>:9090/metrics/prometheus | grep shibuya_messages
   ```

2. **Scale up**
   ```bash
   kubectl scale deployment/shibuya-worker --replicas=5
   ```

3. **Verify new replicas are processing**
   ```bash
   # Wait for pods to be ready
   kubectl get pods -l app=shibuya-worker -w

   # Check metrics show distributed load
   curl http://<metrics-svc>:9090/health
   ```

### Scaling Down

1. **Ensure PodDisruptionBudget allows scale-down**
   ```bash
   kubectl get pdb shibuya-worker-pdb
   ```

2. **Scale down gradually**
   ```bash
   kubectl scale deployment/shibuya-worker --replicas=2
   ```

3. **Monitor for message loss**
   ```bash
   # Check dead letter queue for unexpected entries
   # Check metrics for processing continuity
   ```

### Auto-scaling (HPA)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: shibuya-worker-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: shibuya-worker
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Pods
      pods:
        metric:
          name: shibuya_inbox_utilization
        target:
          type: AverageValue
          averageValue: "70"
```

---

## Handling Stuck Processors

### Detection

**Via Alert:**
- `ShibuyaProcessorStuck` alert fires when a processor is in processing state for > 5 minutes

**Via API:**
```bash
curl http://<pod-ip>:9090/health/ready | jq '.processors'
# Look for "stuck" > 0
```

**Via Metrics:**
```promql
shibuya_processor_state == 2  # Processing state
and (time() - shibuya_processor_last_activity_seconds) > 300
```

### Investigation

1. **Identify the stuck processor**
   ```bash
   curl http://<pod-ip>:9090/health | jq '.processors'
   ```

2. **Check what message is being processed**
   ```bash
   # Check application logs for the processor ID
   kubectl logs <pod> | grep "processor-id"
   ```

3. **Common causes:**
   - Downstream service timeout (database, API)
   - Deadlock in handler code
   - Resource exhaustion (memory, file descriptors)
   - Network partition

### Resolution

**Option 1: Wait for timeout**
- If using PGMQ adapter, lease will expire and message will be retried

**Option 2: Restart the pod**
```bash
kubectl delete pod <pod-name>
# Message will be reprocessed by another pod or after restart
```

**Option 3: Force shutdown (last resort)**
```bash
kubectl delete pod <pod-name> --force --grace-period=0
```

### Prevention

1. Set appropriate handler timeouts
2. Use circuit breakers for external calls
3. Monitor memory usage
4. Set reasonable `stuckThreshold` in health config

---

## Investigating Message Failures

### Detection

**Via Metrics:**
```promql
rate(shibuya_messages_failed_total[5m]) > 0
```

**Via Health Endpoint:**
```bash
curl http://<pod-ip>:9090/health | jq '.processors | to_entries[] | select(.value.stats.failed > 0)'
```

### Investigation Steps

1. **Get failure rate and count**
   ```bash
   curl http://<pod-ip>:9090/metrics | jq '.["processor-id"].stats'
   ```

2. **Check application logs**
   ```bash
   kubectl logs <pod> | grep -i "error\|exception\|failed"
   ```

3. **Check dead letter queue**
   ```sql
   -- For PGMQ adapter
   SELECT * FROM pgmq.read('your_queue_dlq', 100, 0);
   ```

4. **Analyze failure patterns**
   - Are failures correlated with time?
   - Are specific message types failing?
   - Are failures on specific pods?

### Common Failure Causes

| Symptom | Likely Cause | Resolution |
|---------|--------------|------------|
| All messages failing | Downstream service down | Check dependencies, enable circuit breaker |
| Specific message IDs | Poison messages | Check DLQ, fix handler to handle edge cases |
| Sporadic failures | Transient errors | Verify retry logic is working |
| Failures after deploy | Code regression | Rollback deployment |

### Resolution

1. **Fix the root cause** (code bug, config issue, etc.)
2. **Reprocess failed messages** (see DLQ Processing below)
3. **Monitor for recurrence**

---

## Dead Letter Queue Processing

### Viewing DLQ Contents

For PGMQ adapter:
```sql
-- View messages in DLQ
SELECT msg_id, enqueued_at, message
FROM pgmq.read('your_queue_dlq', 100, 0);

-- Count messages
SELECT COUNT(*) FROM pgmq.queue_your_queue_dlq;
```

### Analyzing DLQ Messages

1. **Sample messages to understand failure patterns**
   ```sql
   SELECT message->>'type', COUNT(*)
   FROM pgmq.queue_your_queue_dlq
   GROUP BY message->>'type';
   ```

2. **Check if messages are processable now**
   - Was it a transient error that's resolved?
   - Was it a code bug that's now fixed?
   - Is it a poison message that needs special handling?

### Reprocessing DLQ Messages

**Option 1: Move back to main queue (PGMQ)**
```sql
-- Move all DLQ messages back to main queue
INSERT INTO pgmq.queue_your_queue (message, enqueued_at)
SELECT message, NOW() FROM pgmq.queue_your_queue_dlq;

-- Clear DLQ after successful move
DELETE FROM pgmq.queue_your_queue_dlq;
```

**Option 2: Selective reprocessing**
```sql
-- Move only messages of specific type
INSERT INTO pgmq.queue_your_queue (message, enqueued_at)
SELECT message, NOW() FROM pgmq.queue_your_queue_dlq
WHERE message->>'type' = 'order_created';

DELETE FROM pgmq.queue_your_queue_dlq
WHERE message->>'type' = 'order_created';
```

**Option 3: Manual processing**
- Export messages to file
- Process with a dedicated script
- Delete from DLQ after successful processing

### Preventing DLQ Growth

1. **Fix underlying issues promptly**
2. **Set up alerts for DLQ growth**
   ```promql
   increase(shibuya_dlq_messages_total[1h]) > 100
   ```
3. **Regular DLQ review** (daily or weekly)
4. **Consider DLQ retention policy**

---

## Emergency Procedures

### Complete Service Outage

1. **Stop all processing immediately**
   ```bash
   kubectl scale deployment/shibuya-worker --replicas=0
   ```

2. **Investigate root cause**
   - Check logs
   - Check dependencies
   - Check for cascading failures

3. **Fix the issue**

4. **Restart with reduced capacity**
   ```bash
   kubectl scale deployment/shibuya-worker --replicas=1
   ```

5. **Monitor closely, then scale up**

### Database Connection Exhaustion

1. **Check connection count**
   ```sql
   SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'shibuya%';
   ```

2. **If connections are leaked, restart pods**
   ```bash
   kubectl rollout restart deployment/shibuya-worker
   ```

3. **Review connection pool settings**
   - Reduce `maxConnections` per pod
   - Enable connection timeout
   - Add connection health checks

### Message Storm (Sudden Spike)

1. **Enable backpressure by reducing replicas**
   ```bash
   kubectl scale deployment/shibuya-worker --replicas=1
   ```

2. **Monitor queue depth**

3. **Gradually increase replicas as system stabilizes**

4. **Consider rate limiting at source if recurring**

---

## Monitoring Checklist

### Daily Checks
- [ ] All pods Running and Ready
- [ ] No alerts firing
- [ ] DLQ message count acceptable
- [ ] Processing rate within normal range

### Weekly Checks
- [ ] Memory usage trend
- [ ] Failure rate trend
- [ ] DLQ review and cleanup
- [ ] Log analysis for recurring errors

### Monthly Checks
- [ ] Resource utilization review
- [ ] Scaling thresholds review
- [ ] Runbook updates
- [ ] Dependency health check review
