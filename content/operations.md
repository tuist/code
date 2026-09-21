+++
title = "Operate Code"
template = "page.html"
+++

# 📈 Operate Code

Expose only port `4000` publicly. Keep the health, metrics, and administration
port `4002` inside the cluster. Readiness checks object storage, so a node that
cannot consult the log leaves traffic rotation rather than serving a stale view.

Use `GET /health` for liveness and `GET /ready` for readiness. For autoscaling,
watch `code_git_requests_in_flight` first. Long clones hold connections even
when central processing unit use looks quiet, so that metric reacts sooner than
central processing unit alone.

The chart can scale from three to fifty replicas:

```yaml
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 50
  inFlightMetric:
    enabled: true
    target: 40
```

Use central processing unit as a secondary signal for compaction load. The
[operations reference](https://github.com/tuist/code/blob/main/docs/operations.md)
lists every metric, configuration variable, and failure mode.
