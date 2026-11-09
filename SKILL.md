---
name: k8s-connection-probe
description: Before deploying a service to a Kubernetes environment, find every outbound connection it needs (PostgreSQL/MySQL databases, Redis, Kafka topics and consumer groups, object storage, SFTP, HTTP APIs and gateways) and prove each one live from a throwaway pod inside the same cluster, with the service's own identity. Output is a per-connection verdict with the exact error, the failing layer, and who has to fix it (platform/DevOps team vs. your own config or code), plus a ready-to-send request for the platform team. Use when someone asks "what will break when I deploy this?", "check the connections of <service>", "why can't my pod reach X", "do I have the right Kafka ACLs", "what do I need to ask DevOps for", or is about to migrate a service to a new cluster, cloud or environment — even before the code is finished.
---

# k8s-connection-probe

A connection is not a switch. It is a ladder of layers, and an error only ever shows the **first**
layer that failed — everything above it stays invisible until that one is fixed. Deploy-and-see
therefore finds problems one per deploy cycle. Probing every layer of every dependency up front
finds them all in one pass. Read `references/layers.md` for the ladder and the error table.

## Rules (read first)
- **Always pass `--context` and `--namespace` explicitly.** Confirm both with the user before the first probe.
  Never use whatever the current kubectl context happens to be.
- **Never print secret values.** Pass credentials as env names expanded inside the pod (`'$KAFKA_PASS'`).
- **Read-only by default.** Do not produce to topics, write to databases or buckets, or create topics,
  tables, users or grants to make a probe pass. If a write test is truly needed, ask the user and the
  owner of the resource first — other teams will read whatever you write.
- **Always clean up:** finish with `probe.sh ... down`. Pods also self-terminate after 30 minutes.
- **Be honest about what a probe proves.** `OPEN` is not "login works". `META_OK` is not "can read".
  An empty topic cannot prove reads. `NO_ERROR_IN_15S` is "no auth error seen", not success.

## Workflow

### 1. Discover what the service needs (from the code, not from memory)
Read the service's deployment config (Kubernetes manifests, kustomize overlays, Helm values) and its
code. List every outbound dependency as a table:

| kind | target (host:port / topic / bucket / URL) | direction (read/write/both) | credentials from | env |
|---|---|---|---|---|

Look for: env vars and config maps with hosts, ports and URLs; Kafka topics produced and consumed
**and the consumer group id**; database names; bucket names and prefixes; HTTP clients and the
headers they send; TLS settings (CA files, mTLS, SASL). Flag values that still point at the old
environment, placeholders like `TBC`, and code paths that do not support what the new env requires
(e.g. code only speaks SASL but the new Kafka requires mTLS) — a probe cannot see those, only reading can.

### 2. Check access
```bash
scripts/probe.sh --context <ctx> -n <ns> can-i
```
If pods cannot be created, stop and say so; fall back to reading logs of the real pods.

### 3. Start the probe with the service's identity
```bash
scripts/probe.sh --context <ctx> -n <ns> up --like <deployment>        # netshoot: dns/tcp/tls/http
scripts/probe.sh --context <ctx> -n <ns> kafka-up --like <deployment>  # only if Kafka is involved
```
`--like` copies serviceAccount, env, envFrom and volumes from the deployment, so the error the probe
sees is the error the service will see. Without it you only test the network path.

### 4. Probe every dependency, bottom layer first
```bash
P="scripts/probe.sh --context <ctx> -n <ns>"
$P dns  db.example.internal
$P tcp  db.example.internal 5432
$P tls  kafka.example.internal 9093
$P http https://api.example.internal/orders -H 'X-Request-Source: my-service'
$P kafka meta  kafka.example.internal:9093 orders -- -X security.protocol=SSL ...
$P kafka read  kafka.example.internal:9093 orders -- ...
$P kafka group kafka.example.internal:9093 orders --group my-service -- ...
```
For an HTTP 404 behind a gateway, probe **twice** — without and with the headers the service sends.
404 → 200 means the route exists and your request is missing something (you fix it); 404 → 404 means
the route itself is missing (platform team). Status codes alone cannot tell these apart.

Databases and Redis have their own client pods (same `--like` identity), so the check goes past
"port open" to "can this user log in, reach this database, and do what the service does":
```bash
$P client-up redis --like <deployment>
$P redis orders-cache 6379 --pass-env REDIS_PASS            # REDIS_OK | AUTH_REQUIRED | AUTH_FAILED | ...
$P client-up postgres --like <deployment>
$P postgres orders-db 5432 orders --user-env PG_USER --pass-env PG_PASS     # PG_OK | DB_NOT_FOUND | ...
$P client-up mysql --like <deployment>
$P mysql billing-db 3306 billing --user-env DB_USER --pass-env DB_PASS --grants   # + CAN_WRITE | READ_ONLY
```
`--grants` matters: "login works" is not "the service can INSERT". A read-only user is a config fix
(point at the user that can write) or a grant request — the probe tells you which before deploy.
Object storage (S3/GCS) is not built in: run the cloud CLI briefly in a pod with the service's
identity (e.g. `aws s3 ls s3://bucket/prefix/`) and report the exact error.

### 5. Sort and report
Put every dependency in exactly one group:
- **Ask the platform team** — firewall, missing ACL/grant/policy, missing route, credentials not issued.
- **Fix ourselves** — wrong host/port/env value, missing header, code that lacks the required auth/TLS
  mode, a credential that exists but our config points at the wrong one.
- **Works** — with the evidence line from the probe.
- **Not provable yet** — say why (empty topic, write test not allowed, client not available).

Then write one request per category for the platform team: target, exact error line, time of the
probe, and only the items that are actually missing. One complete request is done in one round;
a vague one comes back with questions.

### 6. Clean up
```bash
scripts/probe.sh --context <ctx> -n <ns> down
```
