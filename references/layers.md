# The connection ladder

Every connection climbs these layers in order. An error reports only the first layer that fails.

| # | Layer | Question | Typical owner |
|---|---|---|---|
| 1 | DNS | Does the host name exist in this network? | platform gives the endpoint, you put it in config |
| 2 | Network | Is the port open from this cluster (firewall, security group, network policy)? | platform |
| 3 | TLS | Do both sides agree on CA, certificate and protocol? Does the client library support it? | CA from platform, library/config is yours |
| 4 | Identity | Does the target know who you are (user/password, client certificate, token, cloud role)? | issued by platform, wired in by you |
| 5 | Permission | May this identity do this action (ACL, GRANT, bucket policy, route)? | platform |
| 6 | Sub-resource | Does the permission cover the inner resource (consumer group, database, prefix, path)? | platform |
| 7 | Protocol / app | Right route, headers, port, topic name, path for this environment? | you |

## Probe result → layer → who fixes it

| Probe result | Layer | Meaning | Usually |
|---|---|---|---|
| `NO_DNS` | 1 | name does not resolve here (old env host, typo, private zone not linked) | fix config / ask for endpoint |
| `BLOCKED_OR_TIMEOUT` | 2 | packets dropped | ask platform (firewall / SG / NetworkPolicy) |
| `REFUSED` | 2 | host up, nothing listening on that port | wrong port in config, or service down |
| `TLS_HANDSHAKE_FAILED` | 3 | no TLS agreement (plain-text port, protocol mismatch, mTLS required) | config / library |
| `TLS_VERIFY_FAILED` | 3 | server cert not trusted with the CA you use | get the right CA bundle |
| `AUTH_FAILED` | 4 | credentials rejected | wrong secret wired, or not issued yet |
| `TOPIC_AUTH_FAILED` | 5 | identity lacks READ/DESCRIBE on topic | ask platform for the ACL |
| `TOPIC_NOT_FOUND` | 7 | topic name is wrong for this env, or it was never created | fix config / ask for the topic |
| `GROUP_AUTH_FAILED` | 6 | topic OK, consumer group not allowed | ask platform for the group ACL |
| `HTTP 404` → `HTTP 200` with headers | 7 | route exists, request incomplete | add the headers |
| `HTTP 404` both times | 5/7 | route missing | ask platform |
| `HTTP 401/403` | 4/5 | identity or permission at the gateway | depends on the gateway setup |

Note: a Kubernetes **Service (ClusterIP)** silently drops ports it does not declare, so a wrong port on a
Service name shows `BLOCKED_OR_TIMEOUT`, not `REFUSED`. Probe the pod IP to tell a closed port from a firewall.

## What a probe does NOT prove
- `OPEN` ≠ the protocol login works (port 22 open ≠ SFTP login OK).
- `META_OK` (topic visible) ≠ the topic is readable.
- An empty topic cannot prove reads — there is nothing to read.
- `NO_ERROR_IN_15S` on a group = no auth error was seen in 15 s, not a successful consume.
- A probe uses its own client: client-library limitations (e.g. code that only speaks SASL) are only
  found by reading the code.
