#!/usr/bin/env bash
# k8s-connection-probe — test every connection a service needs, from inside its own cluster, before you deploy.
#
# Usage:  probe.sh --context <kube-context> --namespace <ns> [--dry-run] <command> [args]
#
# Commands
#   can-i                                  can I create / exec / delete pods here?
#   up [--like <deployment>]               start the throwaway probe pod (netshoot). --like copies the deployment's
#                                          serviceAccount, env, envFrom and volumes, so the probe has the SAME identity
#   dns  <host>                            layer 1  DNS          -> DNS_OK <ips> | NO_DNS
#   tcp  <host> <port>                     layer 2  network      -> OPEN | REFUSED | BLOCKED_OR_TIMEOUT
#   tls  <host> <port> [--sni <name>] [--ca <path-in-pod>]
#                                          layer 3  TLS          -> TLS_OK | TLS_VERIFY_FAILED <reason> | TLS_HANDSHAKE_FAILED
#   http <url> [-H 'Name: value' ...]      layer 4–7 HTTP        -> HTTP <code> | HTTP_NO_RESPONSE
#   kafka-up [--like <deployment>]         start a kcat pod for Kafka checks (same identity options as up)
#   kafka <meta|read|group> <broker:port> <topic> [--group <id>] [-- <extra kcat args>]
#                                          layer 4–6 Kafka       -> META_OK | READ_OK | GROUP_JOIN_OK | TOPIC_AUTH_FAILED |
#                                                                   GROUP_AUTH_FAILED | AUTH_FAILED | TLS_FAILED |
#                                                                   TOPIC_NOT_FOUND | BROKER_UNREACHABLE | NO_ERROR_IN_<n>S
#   client-up <redis|postgres|mysql> [--like <deployment>]
#                                          start a database client pod (same identity options as up)
#   redis <host> <port> [--tls] [--pass-env VAR]
#                                          layer 2–5 Redis       -> REDIS_OK | AUTH_REQUIRED | AUTH_FAILED | PERMISSION_DENIED |
#                                                                   REFUSED | UNREACHABLE | NO_DNS
#   postgres <host> <port> <db> --user-env U --pass-env P [--sslmode require]
#                                          layer 2–6 PostgreSQL  -> PG_OK | AUTH_FAILED | DB_NOT_FOUND | PERMISSION_DENIED |
#                                                                   NOT_ALLOWED_FROM_HERE | REFUSED | UNREACHABLE | NO_DNS
#   mysql <host> <port> <db> --user-env U --pass-env P [--grants]
#                                          layer 2–6 MySQL       -> MYSQL_OK | AUTH_FAILED | DB_NOT_FOUND | PERMISSION_DENIED |
#                                                                   UNREACHABLE | NO_DNS · --grants adds GRANT lines and
#                                                                   CAN_WRITE | READ_ONLY (no INSERT/UPDATE/DELETE)
#   down                                   delete every probe pod (always run this at the end)
#
# Credentials are never printed. Pass them as env names expanded INSIDE the pod, e.g.
#   probe.sh ... kafka read broker:9093 orders -- -X sasl.username='$KAFKA_USER' -X sasl.password='$KAFKA_PASS'
# (single quotes, so your shell does not expand them; the pod got the values via --like).
set -euo pipefail

NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.13}"
KCAT_IMAGE="${KCAT_IMAGE:-edenhill/kcat:1.7.1}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7.4-alpine}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.4}"
POD="conn-probe" KPOD="conn-probe-kcat" LABEL="app.kubernetes.io/name=conn-probe"
CTX="" NS="" DRY=0

die() { echo "error: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="${2:-}"; shift 2 ;;
    --namespace|-n) NS="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
CMD="${1:-}"; [ -n "$CMD" ] && shift || true
[ -n "$CMD" ] || { sed -n '2,27p' "$0"; exit 2; }
# Never guess the cluster: a probe in the wrong cluster gives confident, wrong answers.
[ -n "$CTX" ] || die "--context is required (kubectl config get-contexts)"
[ -n "$NS" ] || die "--namespace is required"

k() { if [ "$DRY" = 1 ]; then { printf 'kubectl --context %q -n %q' "$CTX" "$NS"; printf ' %q' "$@"; echo; } >&2; else kubectl --context "$CTX" -n "$NS" --request-timeout=60s "$@"; fi; }
kx() { local pod="$1"; shift; if [ "$DRY" = 1 ]; then k exec "$pod" -- sh -c "$*"; else kubectl --context "$CTX" -n "$NS" exec "$pod" -- sh -c "$*" 2>&1 || true; fi; }
q() { printf '%q' "$1"; }

# Build pod overrides: optional identity copied from a deployment, a hard 30-minute lifetime, small resources.
overrides() {   # overrides <image> <deployment-or-empty>
  local image="$1" like="$2" spec='{}'
  if [ -n "$like" ]; then
    if [ "$DRY" = 1 ]; then spec='{"note":"identity copied from deployment '"$like"'"}'
    else spec=$(kubectl --context "$CTX" -n "$NS" get deploy "$like" -o json) || die "deployment '$like' not found in $NS"; fi
  fi
  python3 - "$image" "$spec" <<'PY'
import json, sys
image, spec = sys.argv[1], json.loads(sys.argv[2])
pod = spec.get("spec", {}).get("template", {}).get("spec", {})
src = (pod.get("containers") or [{}])[0]
c = {"name": "probe", "image": image, "command": ["sh", "-c", "sleep 1800"],
     "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}}}
for key in ("env", "envFrom", "volumeMounts"):
    if src.get(key): c[key] = src[key]
out = {"spec": {"containers": [c], "restartPolicy": "Never", "activeDeadlineSeconds": 1800}}
if pod.get("serviceAccountName"): out["spec"]["serviceAccountName"] = pod["serviceAccountName"]
if pod.get("volumes"): out["spec"]["volumes"] = pod["volumes"]
if pod.get("imagePullSecrets"): out["spec"]["imagePullSecrets"] = pod["imagePullSecrets"]
print(json.dumps(out))
PY
}

start_pod() {   # start_pod <name> <image> [--like <deployment>]
  local name="$1" image="$2" like=""; shift 2
  [ "${1:-}" = "--like" ] && like="${2:-}"
  k delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k run "$name" --image="$image" --restart=Never --labels="$LABEL" --overrides="$(overrides "$image" "$like")" >/dev/null \
    || { echo "POD_CREATE_DENIED_OR_FAILED (run: probe.sh ... can-i)"; exit 1; }
  [ "$DRY" = 1 ] && return 0
  k wait --for=condition=Ready "pod/$name" --timeout=180s >/dev/null \
    || { echo "POD_NOT_READY: $(k get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"; exit 1; }
  echo "READY $name in $CTX/$NS${like:+ (identity of deployment/$like)}"
}

case "$CMD" in
  can-i)
    for v in "create pods" "create pods/exec" "delete pods" "get deployments"; do
      printf '%-18s %s\n' "$v" "$(k auth can-i $v 2>/dev/null || echo no)"; done ;;
  up)        start_pod "$POD" "$NETSHOOT_IMAGE" "$@" ;;
  kafka-up)  start_pod "$KPOD" "$KCAT_IMAGE" "$@" ;;
  dns)
    h="${1:?host}"; out=$(kx "$POD" "nslookup $(q "$h") 2>&1")
    if echo "$out" | grep -qiE "NXDOMAIN|can't find|server can't|no answer"; then echo "NO_DNS $h"
    else echo "DNS_OK $h $(echo "$out" | awk '/^Address/ && !/#53/ {print $2}' | tr '\n' ' ')"; fi ;;
  tcp)
    h="${1:?host}" p="${2:?port}"
    out=$(kx "$POD" "nc -z -v -w 5 $(q "$h") $(q "$p") 2>&1; echo rc=\$?")
    if echo "$out" | grep -q "rc=0"; then echo "OPEN $h:$p"
    elif echo "$out" | grep -qi "refused"; then echo "REFUSED $h:$p   (host reachable, nothing listening on that port)"
    elif echo "$out" | grep -qiE "bad address|unknown host|not known"; then echo "NO_DNS $h"
    else echo "BLOCKED_OR_TIMEOUT $h:$p   (usually a firewall / security group)"; fi ;;
  tls)
    h="${1:?host}" p="${2:?port}"; shift 2; sni="$h" ca=""
    while [ $# -gt 0 ]; do case "$1" in --sni) sni="$2"; shift 2 ;; --ca) ca="$2"; shift 2 ;; *) shift ;; esac; done
    out=$(kx "$POD" "echo | timeout 10 openssl s_client -connect $(q "$h:$p") -servername $(q "$sni") ${ca:+-CAfile $(q "$ca")} 2>&1")
    code=$(echo "$out" | sed -n 's/.*Verify return code: \([0-9]*\) (\(.*\)).*/\1 \2/p' | tail -1)
    # openssl still prints "Verify return code: 0" when the handshake never completed, so require a peer certificate
    if echo "$out" | grep -qiE "no peer certificate available|Cipher is \(NONE\)"; then code=""; fi
    if [ -z "$code" ]; then echo "TLS_HANDSHAKE_FAILED $h:$p   ($(echo "$out" | grep -iE 'error|alert|refused' | head -1 | cut -c1-100))"
    elif [ "${code%% *}" = 0 ]; then echo "TLS_OK $h:$p"
    else echo "TLS_VERIFY_FAILED $h:$p ${code#* }   (wrong CA bundle, or a self-signed / private CA)"; fi ;;
  http)
    url="${1:?url}"; shift; hs=""
    while [ $# -gt 0 ]; do [ "$1" = "-H" ] && { hs="$hs -H $(q "$2")"; shift 2; } || shift; done
    code=$(kx "$POD" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 $hs $(q "$url")" | tail -1)
    if [ "$code" = 000 ] || [ -z "$code" ]; then echo "HTTP_NO_RESPONSE $url"; else echo "HTTP $code $url"; fi ;;
  kafka)
    mode="${1:?meta|read|group}" b="${2:?broker:port}" t="${3:?topic}"; shift 3; g="conn-probe-$$" extra=""
    while [ $# -gt 0 ]; do case "$1" in --group) g="$2"; shift 2 ;; --) shift; extra="$*"; break ;; *) shift ;; esac; done
    case "$mode" in
      meta)  run="kcat -b $(q "$b") -L -t $(q "$t") $extra" ;;
      read)  run="kcat -b $(q "$b") -C -t $(q "$t") -o -1 -c 1 -e -q $extra" ;;
      group) run="timeout 15 kcat -b $(q "$b") -G $(q "$g") -X enable.auto.commit=false -X auto.offset.reset=latest $extra $(q "$t")" ;;
      *) die "kafka mode must be meta, read or group" ;;
    esac
    out=$(kx "$KPOD" "$run 2>&1; echo rc=\$?")
    if   echo "$out" | grep -qi "Topic authorization failed";            then echo "TOPIC_AUTH_FAILED $t   (identity lacks READ/DESCRIBE on the topic)"
    elif echo "$out" | grep -qiE "Group authorization failed|not authorized to access group"; then echo "GROUP_AUTH_FAILED $g   (topic is fine, the consumer group needs its own ACL)"
    elif echo "$out" | grep -qi "Unknown topic or partition";            then echo "TOPIC_NOT_FOUND $t   (wrong topic name for this env, or the topic was never created)"
    elif echo "$out" | grep -qiE "Authentication failed|SASL authentication";               then echo "AUTH_FAILED   (user/password or certificate rejected)"
    elif echo "$out" | grep -qiE "SSL handshake failed|certificate verify failed";          then echo "TLS_FAILED   (CA / client certificate / protocol mismatch)"
    elif echo "$out" | grep -qiE "all brokers are down|Broker transport failure|Connection refused|timed out"; then echo "BROKER_UNREACHABLE $b"
    elif [ "$mode" = group ]; then echo "NO_ERROR_IN_15S group $g   (joined without an auth error — not proof that reads work)"
    elif echo "$out" | grep -q "rc=0"; then [ "$mode" = meta ] && echo "META_OK $t" || echo "READ_OK $t"
    else echo "UNKNOWN   $(echo "$out" | grep -v '^rc=' | tail -2 | tr '\n' ' ' | cut -c1-160)"; fi ;;
  client-up)
    kind="${1:?redis|postgres|mysql}"; shift
    case "$kind" in redis) img="$REDIS_IMAGE" ;; postgres) img="$POSTGRES_IMAGE" ;; mysql) img="$MYSQL_IMAGE" ;; *) die "client must be redis, postgres or mysql" ;; esac
    start_pod "conn-probe-$kind" "$img" "$@" ;;
  redis)
    h="${1:?host}" p="${2:?port}"; shift 2; tls="" auth=""
    while [ $# -gt 0 ]; do case "$1" in --tls) tls="--tls --insecure"; shift ;; --pass-env) auth="--no-auth-warning -a \"\$$2\""; shift 2 ;; *) shift ;; esac; done
    # redis-cli hangs silently on an unknown host, so resolve the name first. busybox nslookup ignores the
    # cluster search domains (short Service names fail); ping uses the normal resolver and says "bad address".
    out=$(kx conn-probe-redis "ping -c 1 -W 1 $(q "$h") 2>&1 | grep -qi 'bad address' && { echo NO_DNS_MARK; exit 0; }; timeout 8 redis-cli -h $(q "$h") -p $(q "$p") $tls $auth PING 2>&1; echo rc=\$?")
    if   echo "$out" | grep -q "NO_DNS_MARK";                          then echo "NO_DNS $h"
    elif echo "$out" | grep -q "^PONG";                                then echo "REDIS_OK $h:$p"
    elif echo "$out" | grep -qiE "WRONGPASS|invalid password|invalid username"; then echo "AUTH_FAILED $h:$p   (password / ACL user rejected)"
    elif echo "$out" | grep -qi "NOAUTH";                               then echo "AUTH_REQUIRED $h:$p   (server needs a password; the client sent none)"
    elif echo "$out" | grep -qi "NOPERM";                               then echo "PERMISSION_DENIED $h:$p   (ACL user may not run this command)"
    elif echo "$out" | grep -qi "refused";                              then echo "REFUSED $h:$p"
    else echo "UNREACHABLE $h:$p   (timeout, firewall, or TLS required: try --tls)"; fi ;;
  postgres)
    h="${1:?host}" p="${2:?port}" db="${3:?database}"; shift 3; u="" pw="" ssl="prefer"
    while [ $# -gt 0 ]; do case "$1" in --user-env) u="$2"; shift 2 ;; --pass-env) pw="$2"; shift 2 ;; --sslmode) ssl="$2"; shift 2 ;; *) shift ;; esac; done
    [ -n "$u" ] && [ -n "$pw" ] || die "postgres needs --user-env and --pass-env (names of env vars inside the pod)"
    out=$(kx conn-probe-postgres "PGCONNECT_TIMEOUT=6 PGPASSWORD=\"\$$pw\" psql \"host=$h port=$p dbname=$db user=\$$u sslmode=$ssl\" -tAc 'select 1' 2>&1")
    if   echo "$out" | grep -qx "1";                                         then echo "PG_OK $h:$p/$db"
    elif echo "$out" | grep -qi "password authentication failed";            then echo "AUTH_FAILED $h:$p   (user/password rejected)"
    elif echo "$out" | grep -qi "does not exist";                            then echo "DB_NOT_FOUND $db   (wrong database name for this env, or not created)"
    elif echo "$out" | grep -qiE "permission denied for database|CONNECT privilege"; then echo "PERMISSION_DENIED $db   (user may not connect to this database)"
    elif echo "$out" | grep -qi "no pg_hba.conf entry";                      then echo "NOT_ALLOWED_FROM_HERE $h:$p   (server rejects this client address / SSL mode)"
    elif echo "$out" | grep -qiE "could not translate host name";            then echo "NO_DNS $h"
    elif echo "$out" | grep -qi "refused";                                   then echo "REFUSED $h:$p"
    else echo "UNREACHABLE $h:$p   ($(echo "$out" | tail -1 | cut -c1-100))"; fi ;;
  mysql)
    h="${1:?host}" p="${2:?port}" db="${3:?database}"; shift 3; u="" pw="" grants=0
    while [ $# -gt 0 ]; do case "$1" in --user-env) u="$2"; shift 2 ;; --pass-env) pw="$2"; shift 2 ;; --grants) grants=1; shift ;; *) shift ;; esac; done
    [ -n "$u" ] && [ -n "$pw" ] || die "mysql needs --user-env and --pass-env (names of env vars inside the pod)"
    base="MYSQL_PWD=\"\$$pw\" mysql -h $(q "$h") -P $(q "$p") -u \"\$$u\" --connect-timeout=6 -N -B"
    out=$(kx conn-probe-mysql "$base -e 'select 1' $(q "$db") 2>&1")
    if   echo "$out" | grep -qx "1"; then echo "MYSQL_OK $h:$p/$db"
      if [ "$grants" = 1 ]; then
        g=$(kx conn-probe-mysql "$base -e 'SHOW GRANTS' 2>&1" | tr -d '`')
        echo "$g" | sed 's/^/GRANT: /' | sed 's/^GRANT: GRANT /GRANT: /'
        if echo "$g" | grep -qiE "ALL PRIVILEGES|INSERT"; then echo "CAN_WRITE"; else echo "READ_ONLY   (no INSERT/UPDATE/DELETE: use a user that can write, or ask for the grant)"; fi
      fi
    elif echo "$out" | grep -q "ERROR 1045"; then echo "AUTH_FAILED $h:$p   (user/password rejected)"
    elif echo "$out" | grep -q "ERROR 1044"; then echo "PERMISSION_DENIED $db   (no access to this database, or it does not exist — MySQL hides which from users without access)"
    elif echo "$out" | grep -q "ERROR 1049"; then echo "DB_NOT_FOUND $db   (wrong database name for this env, or not created)"
    elif echo "$out" | grep -q "ERROR 2005"; then echo "NO_DNS $h"
    else echo "UNREACHABLE $h:$p   ($(echo "$out" | tail -1 | cut -c1-100))"; fi ;;
  down) k delete pod -l "$LABEL" --wait=false --ignore-not-found ;;
  *) die "unknown command '$CMD' (try --help)" ;;
esac
