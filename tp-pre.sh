#!/usr/bin/env bash
# ============================================================================
# tp-pre.sh — Trident Port pre-engagement inventory.
#
# WHAT IT IS FOR
#
# Everything needed to walk away from a customer's cluster and, without going
# back, DESIGN THE DESTINATION and PROPOSE THE WHOLE MIGRATION:
#
#   * which backends and StorageClasses would have to be built, and why
#   * every namespace, every claim, what holds it, and how it would be cut
#   * the totals the destination has to be sized against
#   * a CSV, so waves can be planned in a spreadsheet rather than a terminal
#
# It answers the second question too — is this cluster migratable at all —
# but that is the easy half. The hard half is walking away with enough.
#
# Changes nothing in the estate. Every command is `get`, `version`, `auth can-i`
# or a REST GET against ONTAP, with exceptions that are each named where they
# run and that are OFF unless asked for:
#   --probe-pull    a throwaway pod `tp-pull-probe` (created, then deleted by name)
#   --count-files   a bounded read-only `find` through `kubectl exec`
# and one that is on: `kubectl exec` into pods that are already running to READ
# (tridentctl get on the Trident controller; kernel-module state through the
# Trident node plugin). Nothing is patched or scaled. The file can be handed to
# their reviewer before it is run.
#
# SECTION G2 writes the machine-readable half: tp-pre-<context>-<date>.json (every
# claim, workload, Argo/Flux object, operator, node, ...) and .md (the risks, on
# top, in words), and bundles all four files into one .tgz to send back. A
# section the account cannot read says `unknown: forbidden (<verb> <resource>)`.
#
# WHAT LEAVES THE CLUSTER
#
# A shape, never data. Secrets are not read. Environment variable values are
# not collected — see collect-for-replay.sh, which redacts them, for the
# machine-readable dump. This one prints tables a person reads.
#
# TWO SECTIONS, BECAUSE ACCESS DIFFERS
#
#   Kubernetes    always. Needs only kubectl (or oc).
#   The array     only if ONTAP credentials are to hand. Skipped cleanly
#                 otherwise, with the exact commands to hand to whoever does
#                 have them.
#
# USAGE
#   ./tp-pre.sh                        every namespace holding a claim
#   ./tp-pre.sh -n prod-a,prod-b       only these
#   ./tp-pre.sh --no-internal          do not print our design at the end
#   ./tp-pre.sh --count-files          also count files per claim (find, bounded by
#                                      TP_COUNT_TIMEOUT s / TP_COUNT_CAP files per
#                                      claim and TP_COUNT_MAX_PVCS claims; execs a
#                                      read-only find in the pod that mounts it)
#   ./tp-pre.sh --probe-pull           also run a pod to test the image pull (CREATES a
#                                      pod, then deletes it) - off by default
#   ./tp-pre.sh --read-timeout 600     seconds allowed to each batch read (default 300)
#   ./tp-pre.sh --node-debug           oc only: when the node plugin has no shell,
#                                      read the node with a temporary `oc debug node`
#                                      pod (oc deletes it on exit)
#   ONTAP_MGMT_LIF=1.2.3.4 ONTAP_USER=admin ./tp-pre.sh
#                                      asks for the password without echoing it; if
#                                      ONTAP_PASS is already set it is used as is
#
# LEAVES ON THEIR DISK
#   tp-pre-<context>-<date>.txt        the report, as printed
#   tp-pre-<context>-<date>.csv        one row per claim, for planning
#
# AND NOTHING ELSE. The destination we would build is OURS, and it used to be
# written beside those two as a third file labelled INTERNAL. A label on a
# file left on somebody else's disk protects nothing: it is on their disk. So
# it is PRINTED ON THE TERMINAL at the end of the run, between two markers,
# and never written anywhere. Copy it out of the scrollback; the design work
# happens on our side, and what the customer gets is the finished plan.
# ============================================================================
set -uo pipefail

NS_FILTER=""
TP_PRINT_INTERNAL=true
TP_NODE_DEBUG=false
TP_COUNT_FILES=false
TP_PROBE_PULL=false
TP_READ_TIMEOUT=300
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespaces) NS_FILTER="${2:-}"; shift 2 ;;
    # For a shared screen. The design is ours either way; this is the switch
    # for the one situation where the customer is watching the terminal.
    --no-internal) TP_PRINT_INTERNAL=false; shift ;;
    # OpenShift only. Sections H and I read the node plugin by exec; when its
    # container has no shell and no cat, the only way left to read a node is a
    # temporary privileged pod (`oc debug node/<n>`). Off unless asked for.
    --node-debug) TP_NODE_DEBUG=true; shift ;;
    --count-files) TP_COUNT_FILES=true; shift ;;
    --probe-pull) TP_PROBE_PULL=true; shift ;;
    --read-timeout) TP_READ_TIMEOUT="${2:-300}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# `oc` is kubectl plus OpenShift's own resources, so prefer it when present.
K=kubectl; command -v oc >/dev/null 2>&1 && K=oc
command -v "$K" >/dev/null 2>&1 || { echo "no kubectl or oc in PATH" >&2; exit 1; }
$K version >/dev/null 2>&1 || $K get --raw=/version >/dev/null 2>&1 || {
  echo "cannot reach the cluster API — check your kubeconfig" >&2; exit 1; }
HAVE_JQ=false; command -v jq >/dev/null 2>&1 && HAVE_JQ=true

# tr -c replaces every character NOT in the set, and the trailing newline is
# one of them — so the context came out as "mycluster-" and the files as
# "tp-pre-mycluster--<date>". Strip the newline first, then squeeze and trim.
CTX=$($K config current-context 2>/dev/null | tr -d '\n' \
      | tr -c 'a-zA-Z0-9_.-' '-' | sed 's/-\{1,\}$//')
[ -n "$CTX" ] || CTX=cluster
STAMP=$(date +%Y%m%d-%H%M)
OUT="tp-pre-${CTX}-${STAMP}.txt"
CSV="tp-pre-${CTX}-${STAMP}.csv"
# fd 3 is the terminal, kept BEFORE stdout is teed into the report. Everything
# written to it is seen by whoever is running this and lands in no file — that
# is where our own destination design goes at the end.
exec 3>&1
exec > >(tee "$OUT") 2>&1

# provisioned, free, used — all in bytes; used 0 means "we could not see it".
# A function rather than an inline if, so the three verdicts can be exercised
# without an array: this is the sentence a proposal gets written from, and
# getting it backwards is worse than not printing it.
tp_fit_verdict() {
  _prov=$1; _free=$2; _used=${3:-0}
  if [ "$_free" -ge "$_prov" ]; then
    echo "   FITS even if every claim were thick-provisioned."
  elif [ "$_used" -gt 0 ] && [ "$_free" -ge "$_used" ]; then
    echo "   *** DOES NOT FIT ON PROVISIONED SIZE — fits on used ***"
    echo "     The bytes that have to move fit in the space that is free."
    echo "     The PROVISIONED total does not, so the destination volumes"
    echo "     have to be thin as well, and an autogrow that reaches the"
    echo "     provisioned total will fill the aggregate."
  elif [ "$_used" -gt 0 ]; then
    echo "   *** DOES NOT FIT ***"
    echo "     Not even the used bytes fit in the free space. This is a"
    echo "     sizing conversation before it is a migration conversation,"
    echo "     and better had now than with the first wave already stopped."
  else
    echo "   *** CANNOT SAY — provisioned does not fit and used is unknown ***"
    echo "     Do not report this as a fit or as a failure. Get the used"
    echo "     figure from whoever owns the source, then decide."
  fi
}

# ── WHO OWNS A WORKLOAD ─────────────────────────────────────────────────────
#
# THE SAME QUESTION THE ENGINE ASKS, ASKED THE SAME WAY.
#
# This used to walk `ownerReferences` over `deploy,sts` and stop there, which
# is HALF of the product's method and the weaker half. Measured on a
# lab cluster on 19-aug-2026: `demo-presentation/postgresql/shop-db` existed, with its
# claim, and the report said the namespace had no operator — because Zalando's
# postgres-operator sets no ownerReference at all (`enable_owner_references`
# is off by default, and the StatefulSet it manages reads `SIN OWNER`).
#
# Two lines below that, the report says "Scaling what an operator owns
# achieves nothing — it reconciles the replicas back in seconds". So the
# warning was printed for the operators that did not need it and withheld
# from the one that did: the window gets planned as a plain scale to zero, the
# StatefulSet is scaled, and the operator puts the replicas back mid-cutover.
#
# The product answers this in two steps, and so does this:
#
#   1. an ownerReference whose kind is not one of Kubernetes's own; failing
#      that,
#   2. the conventions the registry records — EVERY required label must match,
#      the named label carries the CR's name, and THE CR IS CONFIRMED TO
#      EXIST before the claim is made.
#
# Step 2's confirmation is the whole reason this is not "match a CR with the
# same name". In the same test lab a bare `StatefulSet/db` carries no owner and
# no CR, and matching on name alone would turn every hand-made StatefulSet
# into an operated one the moment something in the namespace shares its name.
# A label convention is evidence about somebody else's cluster; it is checked
# before it is acted on.
#
# DaemonSets are read too. One holds a claim in a test namespace, and a
# `get deploy,sts` never saw it.

#   Kinds we have a tested stop recipe for. Generated from the product's
#   operator catalogue; a test fails if the two drift. Embedded rather than
#   imported because this script is one file copied to a jumphost with
#   nothing installed.
#   "RedisFailover" REMOVED, 20-sep-2026: spotahome/redis-operator
#   confirmed archived upstream, no
#   successor named -- gone from the catalogue, so it is gone here
#   too, per this list's own generation rule above.
TP_KNOWN_OPERATORS="Alertmanager|CassandraDatacenter|ClickHouseInstallation|Cluster|CrdbCluster|Dragonfly|Elasticsearch|EtcdCluster|KafkaNodePool|MariaDB|MongoDBCommunity|MysqlCluster|OpenSearchCluster|PerconaServerMongoDB|PerconaXtraDBCluster|PostgresCluster|Prometheus|RabbitmqCluster|RedisCluster|Seaweed|TemporalCluster|Tenant|VMCluster|ZookeeperCluster|kafka|postgresql"

#   Operators that MANAGE a workload without OWNING it, so no ownerReference
#   points at them. One WHITESPACE-SEPARATED word per kind:
#       CR kind|resource to confirm it with|label carrying its name|labels that must all match
#   Generated from the product's operator registry; a test fails if the two
#   drift. Same reason as
#   above: nothing is installed on a jumphost.
TP_OWNERSHIP_CONVENTIONS="postgresql|postgresqls|cluster-name|application=spilo"

#   THE DATA ENGINES WE RECOGNISE, AND WHAT A COPY OF THE VOLUME MISSES.
#
#   WHY THIS IS IN A PRE-ASSESSMENT AT ALL. Measured on a lab cluster, 19-aug-2026:
#   a Redis started with `--save "" --appendonly no` — a legitimate and common
#   configuration — held 5000 keys in memory and ZERO files on its volume.
#   `tp auto` copied it, validated it, cut it over, reported
#   `copied 1 · validated 1 · cut over 1`, exited 0 and called the two trees
#   identical. They were. Afterwards `DBSIZE` returned 0. We copied the
#   nothing faithfully and signed it as a success, and no check we have could
#   ever have caught it: every one of them compares the source with the
#   destination, and both were empty.
#
#   The place that question had to be asked is here, BEFORE anything moves.
#
#   The sentence in the last field is what NetApp's own published execution
#   hook does to that engine before a snapshot (github.com/NetApp/Verda), and
#   it is the best short statement there is of what each engine keeps
#   somewhere other than the volume. Kafka's is the interesting one: NetApp
#   publishes NO hook for it, having tested that a crash-consistent copy
#   restores — so the absence is a finding too, and not an omission.
#
#   One row per engine, fields separated by SEMICOLONS so that the image
#   pattern can use `|` and the kind list can use `,`:
#       name;image regex;custom resource kinds;memory-first?;what the hook does
TP_DATA_ENGINES="
PostgreSQL;postgres|spilo|timescale|citus;postgresql,PostgreSQL,Postgresql,PostgresCluster,Cluster;on-disk;LOCKs every table and calls pg_backup_start() before the snapshot
MySQL;mysql|percona-xtradb;MysqlCluster,MySQLCluster,InnoDBCluster,PerconaXtraDBCluster;on-disk;runs FLUSH TABLES WITH READ LOCK and holds the database read-only across it
MariaDB;mariadb;MariaDB;on-disk;flushes and read-locks, and NetApp warn that non-InnoDB tables are not even crash-consistent without it
MongoDB;mongo;MongoDB,MongoDBCommunity,PerconaServerMongoDB;on-disk;calls db.fsyncLock() to push pending writes onto the volume and block new ones
Cassandra;cassandra|scylla;CassandraDatacenter,ScyllaCluster;on-disk;runs nodetool flush: until it does the memtables are in memory and only the commitlog is on disk
Elasticsearch;elasticsearch|opensearch;Elasticsearch,OpenSearchCluster;on-disk;flushes every index and sets index.blocks.read_only for the duration
Kafka;kafka;kafka,KafkaNodePool;on-disk;NOTHING - NetApp tested that Kafka restores from a crash-consistent copy and publish no hook for it
Redis;redis|valkey|dragonfly|keydb;RedisCluster,RedisEnterpriseCluster,Valkey,Dragonfly;memory-first;runs BGSAVE, because until it does the keyspace is in memory and the volume may hold nothing at all
SQL Server;mssql|sqlserver|sql-server;;on-disk;puts every database into READ_ONLY for the duration of the snapshot
YugabyteDB;yugabyte|yb-master|yb-tserver;;on-disk;takes YugabyteDB's OWN snapshot with yb-admin - the volume alone is not the unit of recovery
"

#   An image whose name matches an engine above and that is NOT the engine.
#   Every one of these was going to be reported as a database: `postgres` is
#   in `postgres-operator` and in `postgres-exporter`, and the operator's own
#   pod holds no data at all. Over-matching here would fill the section with
#   controllers and metrics sidecars and bury the one line that matters.
TP_NOT_THE_ENGINE="exporter|metrics|operator|controller|backup|restore|dump|bouncer|proxy|haproxy|maxscale|orchestrator|-cli|kubectl|busybox|debug"

#   The kinds the product can stop through a custom resource, in every
#   spelling it accepts, plus the two kinds it handles
#   outside the registry (Strimzi's Kafka, KubeVirt's VirtualMachine).
TP_REGISTRY_OPERATORS="ActiveMQArtemis|Alertmanager|CassandraDatacenter|ClickHouseInstallation|Cluster|CouchbaseCluster|CrdbCluster|Dragonfly|Elasticsearch|EtcdCluster|Hazelcast|InnoDBCluster|Kafka|KafkaNodePool|Keycloak|MariaDB|Milvus|MongoDB|MongoDBCommunity|MySQLCluster|MysqlCluster|NexusRepo|OpenSearchCluster|PerconaServerMongoDB|PerconaXtraDBCluster|PostgreSQL|PostgresCluster|Postgresql|Prometheus|RabbitmqCluster|RedisCluster|RedisEnterpriseCluster|ScyllaCluster|Seaweed|SolrCloud|TemporalCluster|Tenant|TidbCluster|VMCluster|Valkey|VirtualMachine|ZookeeperCluster|activemqartemis|alertmanager|cassandradatacenter|clickhouseinstallation|cluster|couchbasecluster|crdbcluster|dragonfly|elasticsearch|etcdcluster|hazelcast|innodbcluster|kafka|kafkanodepool|keycloak|mariadb|milvus|mongodb|mongodbcommunity|mysqlcluster|nexusrepo|opensearchcluster|perconaservermongodb|perconaxtradbcluster|postgrescluster|postgresql|prometheus|rabbitmqcluster|rediscluster|redisenterprisecluster|scyllacluster|seaweed|solrcloud|temporalcluster|tenant|tidbcluster|valkey|virtualmachine|vmcluster|zookeepercluster"

#   Of those, the ones whose CRD declares a minimum ABOVE ZERO. Patching the
#   custom resource to zero is refused by the API server, so there is no stop
#   through the custom resource at all: the operator has to be held down and
#   the workload scaled underneath it.
#
#   THIS IS THE ONE THE REPORT NEVER SAID. The inventory named the operators
#   and stopped there, and "there is an operator here" and "we can stop it"
#   are different sentences. A namespace whose operator refuses zero is a
#   namespace that may be copied HOT — and everything the engines above need
#   before a copy is worth anything applies to exactly those.
#
#   Generated from the product's registry; the drift test fails in
#   both directions, because a kind missing here is a hot copy nobody warned
#   about and a kind invented here is a window we asked for and did not need.
TP_REFUSES_ZERO="CassandraDatacenter|Cluster|CouchbaseCluster|CrdbCluster|InnoDBCluster|KafkaNodePool|MySQLCluster|PostgresCluster|Seaweed|Tenant|TemporalCluster|ZookeeperCluster|cassandradatacenter|cluster|couchbasecluster|crdbcluster|innodbcluster|kafkanodepool|postgrescluster|seaweed|tenant|temporalcluster|zookeepercluster"

#   The CRDs section G2 looks for, as Kind=resource pairs: one per entry of
#   the product's operator registry, plus Strimzi's Kafka, which
#   it handles outside the registry. A resource with a dot is
#   plural.group and is matched on both; one without is matched on kind alone.
#   Generated, not typed: a test fails on drift.
TP_REGISTRY_CRDS="ActiveMQArtemis=activemqartemises.broker.amq.io;Alertmanager=alertmanagers.monitoring.coreos.com;CassandraDatacenter=cassandradatacenters.cassandra.datastax.com;ClickHouseInstallation=clickhouseinstallations.clickhouse.altinity.com;Cluster=clusters.postgresql.cnpg.io;CouchbaseCluster=couchbaseclusters.couchbase.com;CrdbCluster=crdbcluster;Dragonfly=dragonflies.dragonflydb.io;Elasticsearch=elasticsearches.elasticsearch.k8s.elastic.co;EtcdCluster=etcdclusters.etcd-operator.cozystack.io;Hazelcast=hazelcasts.hazelcast.com;InnoDBCluster=innodbclusters.mysql.oracle.com;KafkaNodePool=kafkanodepool;Keycloak=keycloaks.k8s.keycloak.org;MariaDB=mariadb;Milvus=milvuses.milvus.io;MongoDB=mongodb.mongodb.com;MongoDBCommunity=mongodbcommunity;MySQLCluster=mysqlclusters.moco.cybozu.com;MysqlCluster=mysqlclusters.mysql.presslabs.org;NexusRepo=nexusrepos.sonatype.com;OpenSearchCluster=opensearchclusters.opensearch.org;PerconaServerMongoDB=perconaservermongodbs.psmdb.percona.com;PerconaXtraDBCluster=perconaxtradbclusters.pxc.percona.com;PostgresCluster=postgresclusters.postgres-operator.crunchydata.com;Prometheus=prometheuses.monitoring.coreos.com;RabbitmqCluster=rabbitmqclusters.rabbitmq.com;RedisCluster=redisclusters.redis.redis.opstreelabs.in;RedisEnterpriseCluster=redisenterpriseclusters.app.redislabs.com;ScyllaCluster=scyllaclusters.scylla.scylladb.com;Seaweed=seaweeds.seaweed.seaweedfs.com;SolrCloud=solrclouds.solr.apache.org;TemporalCluster=temporalclusters.temporal.io;Tenant=tenants.minio.min.io;TidbCluster=tidbclusters.pingcap.com;VMCluster=vmclusters.operator.victoriametrics.com;Valkey=valkeys.hyperspike.io;VirtualMachine=virtualmachines.kubevirt.io;ZookeeperCluster=zookeeperclusters.zookeeper.pravega.io;postgresql=postgresql;Kafka=kafkas.kafka.strimzi.io"

# tp_stop_strategy <kind> <how-many-other-namespaces-hold-this-kind>
#
# The same four answers the product's engine gives, in the same
# order, from the same evidence:
#
#   plain             an ordinary workload: it scales to zero and stays there
#   via-cr            its custom resource takes it down when patched to zero
#   hold-operator     the CR will not go to zero, so the controller has to be
#                     held down and the workload scaled underneath it
#   needs-agreement   the same, AND that controller serves other namespaces,
#                     so holding it down suspends reconciliation there too —
#                     which is not ours to decide
#
# A test runs this and the engine's own function over every kind the registry
# knows and fails on the first disagreement.
tp_stop_strategy() {
  _kind=${1:-}; _others=${2:-0}
  case "$_kind" in
    ""|StatefulSet|Deployment|DaemonSet) echo plain; return 0 ;;
  esac
  if echo "$_kind" | grep -qE "^($TP_REFUSES_ZERO)$"; then
    :
  elif echo "$_kind" | grep -qE "^($TP_REGISTRY_OPERATORS)$"; then
    # In the registry and its CRD accepts zero: one patch and the operator
    # takes its own pods down.
    echo via-cr; return 0
  fi
  # Either the CRD refuses zero, or nobody has studied this kind. Both end at
  # the same place — scale the workload and hold the controller off it — and
  # the two are told apart in the line the report prints, not here.
  if [ "${_others:-0}" -gt 0 ] 2>/dev/null; then
    echo needs-agreement; return 0
  fi
  echo hold-operator
}

#   Us. The Trident Port operator owns the product's own Deployment through a
#   TridentPort CR, so a run in a cluster where we are already installed
#   listed US as an unknown operator to go and validate. Excluded by KIND AND
#   API GROUP, not by namespace or name: a customer can install us anywhere,
#   and a customer resource of their own called `trident-port` in some other
#   group is a real finding that must still be reported.
TP_OUR_OWN_KIND="TridentPort"
TP_OUR_OWN_GROUP="trident-port.netapp.io"

#   An ownerReference to one of these says the workload belongs to Kubernetes
#   itself. Kept as one jq definition used by both passes below, because two
#   copies of this list is how the two passes come to disagree.
TP_JQ_OWNERS='def tp_operator_refs: (.metadata.ownerReferences // [])[]
  | select(.kind != "ReplicaSet" and .kind != "Deployment"
           and .kind != "StatefulSet" and .kind != "DaemonSet"
           and .kind != "Job" and .kind != "CronJob" and .kind != "Node");'

# tp_operator_owners <namespace> [workloads-json-file]
# Prints one line per operator found:  <kind>\t<name>\t<how>
# `how` is `owns it`, `manages it by label; no ownerReference`, or `ours`.
tp_operator_owners() {
  _ns=$1; _wfile=${2:-}
  $HAVE_JQ || return 0
  if [ -n "$_wfile" ] && [ -s "$_wfile" ]; then
    _wjson=$(cat "$_wfile")
  else
    _wjson=$($K get deploy,sts,ds -n "$_ns" -o json 2>/dev/null)
  fi
  [ -n "$_wjson" ] || return 0

  printf '%s' "$_wjson" | jq -r "$TP_JQ_OWNERS"'
    .items[]? | tp_operator_refs
    | . as $r
    | "\($r.kind)\t\($r.name)\t"
      + (if $r.kind == $ourkind
            and (($r.apiVersion // "") | split("/") | .[0]) == $ourgroup
         then "ours" else "owns it" end)' \
    --arg ourkind "$TP_OUR_OWN_KIND" --arg ourgroup "$TP_OUR_OWN_GROUP" \
    2>/dev/null | sort -u

  while IFS='|' read -r _kind _res _label _req; do
    [ -n "$_kind" ] || continue
    # Only workloads that no operator owns: one that already has an owner was
    # answered by the pass above, and answering it twice by a weaker method
    # is how the two answers come to disagree.
    _cands=$(printf '%s' "$_wjson" | jq -r "$TP_JQ_OWNERS"'
      .items[]? | select([tp_operator_refs] | length == 0)
      | (.metadata.labels // {}) as $l
      | select([$req | split(",")[] | select(length > 0) | split("=")
                | $l[.[0]] == .[1]] | all)
      | ($l[$namelabel] // "") | select(. != "")' \
      --arg namelabel "$_label" --arg req "$_req" 2>/dev/null | sort -u)
    for _name in $_cands; do
      # The confirmation. Without it a copied label stops an application
      # through a custom resource that is not there.
      $K get "$_res" "$_name" -n "$_ns" >/dev/null 2>&1 \
        && printf '%s\t%s\t%s\n' "$_kind" "$_name" \
             "manages it by label; no ownerReference"
    done
  done <<TP_CONVENTIONS
$(printf '%s\n' $TP_OWNERSHIP_CONVENTIONS)
TP_CONVENTIONS
  # Explicitly, because otherwise the exit status is whatever the last CR
  # confirmation happened to return: "no operator here" would read as a
  # failure to a caller that checks, and "an operator here" as a success.
  return 0
}

# ── ARGO CD AND ARGO WORKFLOWS: HOW THEY ARE SET UP ─────────────────────────
#
# READ-ONLY (`get` only), and it never turns an instrument that cannot see
# into a fact: a list that could not be read prints "unreadable", never 0 and
# never "none". "not installed" is said only when the API itself says the
# resource type does not exist.
#
# The product asks the same questions the same way — `applications.argoproj.io`
# fully qualified (a Trident Protect CRD also has the plural `applications`),
# `automated` PRESENT is auto-sync whatever it holds, an ApplicationSet child
# is an Application with an ownerReference of kind ApplicationSet, and a claim belongs to a Workflow by an
# argoproj.io ownerReference of kind Workflow or by the
# workflows.argoproj.io/workflow label.
#
# tp_argo_read <crd> <resource> <outfile>
#   prints ok | absent | unreadable ; on ok the JSON list is in <outfile>
tp_argo_read() {
  _crd=$1; _res=$2; _file=$3; _errf="${3}.err"
  : > "$_file"
  _crd_err=$($K get crd "$_crd" -o name 2>&1 >/dev/null); _crd_rc=$?
  if [ "$_crd_rc" -ne 0 ]; then
    case "$_crd_err" in
      *NotFound*|*"not found"*) echo absent; return 0 ;;
    esac
    # The CRD itself could not be read (no RBAC on CRDs, say). Try the list
    # before giving up: the list is what is wanted.
  fi
  if $K get "$_res" -A -o json >"$_file" 2>"$_errf"; then
    if $HAVE_JQ && jq -e '.items | type == "array"' "$_file" >/dev/null 2>&1; then
      rm -f "$_errf"; echo ok; return 0
    fi
    rm -f "$_errf"; echo unreadable; return 0
  fi
  if grep -qiE "doesn't have a resource type|the server could not find the requested resource" "$_errf" 2>/dev/null; then
    rm -f "$_errf"; echo absent; return 0
  fi
  rm -f "$_errf"; echo unreadable
}

tp_argo_probe() {
  _tmp="/tmp/tp-argo.$$"
  echo "-- Argo CD ApplicationSets and Applications (read-only) --"
  $HAVE_JQ || echo "   NOTE: jq is missing, so no list can be counted: every count below is unreadable."

  _state=$(tp_argo_read applicationsets.argoproj.io applicationsets.argoproj.io "$_tmp.appsets")
  case "$_state" in
    absent)     echo "   ApplicationSets: CRD applicationsets.argoproj.io not installed" ;;
    unreadable) echo "   ApplicationSets: unreadable (could not list applicationsets.argoproj.io)" ;;
    ok)
      echo "   ApplicationSets: CRD present, $(jq '.items | length' "$_tmp.appsets") found"
      jq -r '.items[] | "     \(.metadata.namespace)/\(.metadata.name)"' "$_tmp.appsets" 2>/dev/null
      ;;
  esac

  _state=$(tp_argo_read applications.argoproj.io applications.argoproj.io "$_tmp.apps")
  case "$_state" in
    absent)
      echo "   Applications: CRD applications.argoproj.io not installed" ;;
    unreadable)
      echo "   Applications: unreadable (could not list applications.argoproj.io)"
      echo "   Applications owned by an ApplicationSet: unreadable"
      echo "   Applications with spec.syncPolicy.automated: unreadable"
      echo "   Applications with selfHeal true: unreadable"
      echo "   Application source type: unreadable" ;;
    ok)
      jq -r '
        def srcs: if ((.spec.sources // null) | type) == "array" and ((.spec.sources | length) > 0)
                  then .spec.sources
                  elif ((.spec.source // null) | type) == "object" then [.spec.source]
                  else [] end;
        def srckind:
          srcs as $s
          | if ($s | length) == 0 then "unknown"
            elif any($s[]; type != "object") then "unknown"
            elif any($s[]; (.helm // null) != null or (.chart // null) != null) then "Helm"
            elif any($s[]; (.kustomize // null) != null) then "Kustomize"
            elif any($s[]; (.plugin // null) != null) then "unknown"
            else "directory" end;
        def policy: ((.spec.syncPolicy | objects) // {});
        def automated: (policy | has("automated")) and (policy.automated != null);
        def selfheal: ((policy.automated | objects | .selfHeal) // false) == true;
        def owned: any((.metadata.ownerReferences // [])[]?; .kind == "ApplicationSet");
        .items as $a
        | "   Applications: \($a | length) in total",
          "   Applications owned by an ApplicationSet (ownerReferences kind ApplicationSet): \([$a[] | select(owned)] | length)",
          "   Applications with spec.syncPolicy.automated: \([$a[] | select(automated)] | length)",
          "   Applications with selfHeal true: \([$a[] | select(selfheal)] | length)",
          "   Application source type: Helm \([$a[] | select(srckind == "Helm")] | length), Kustomize \([$a[] | select(srckind == "Kustomize")] | length), directory (no helm/kustomize block) \([$a[] | select(srckind == "directory")] | length), unknown \([$a[] | select(srckind == "unknown")] | length)"
      ' "$_tmp.apps" 2>/dev/null || echo "   Applications: unreadable (the list could not be parsed)"
      ;;
  esac
  echo "   (a source with no helm/kustomize block can still be auto-detected by"
  echo "    Argo CD from the repository content; that is not visible here)"

  echo
  echo "-- Argo Workflows (read-only) --"
  _state=$(tp_argo_read workflows.argoproj.io workflows.argoproj.io "$_tmp.wf")
  case "$_state" in
    absent)
      echo "   Workflows: CRD workflows.argoproj.io not installed"
      echo "   Claims owned by Workflows: not installed" ;;
    unreadable)
      echo "   Workflows: unreadable (could not list workflows.argoproj.io)"
      echo "   Claims owned by Workflows: unreadable" ;;
    ok)
      echo "   Workflows: $(jq '.items | length' "$_tmp.wf")"
      if $K get pvc -A -o json >"$_tmp.pvc" 2>/dev/null \
         && jq -e '.items | type == "array"' "$_tmp.pvc" >/dev/null 2>&1; then
        echo "   Claims owned by Workflows (argoproj.io Workflow ownerReference or workflows.argoproj.io/workflow label): $(jq '[.items[]
          | select(any((.metadata.ownerReferences // [])[]?; .kind == "Workflow" and (((.apiVersion // "") | split("/")[0]) == "argoproj.io"))
                   or (((.metadata.labels // {})["workflows.argoproj.io/workflow"] // "") != ""))] | length' "$_tmp.pvc")"
      else
        echo "   Claims owned by Workflows: unreadable (could not list persistentvolumeclaims)"
      fi ;;
  esac
  rm -f "$_tmp".*
  return 0
}

hr() { printf '%s\n' "════════════════════════════════════════════════════════════════"; }
sec() { echo; hr; echo "  $*"; hr; }

echo "Trident Port — pre-engagement inventory"
echo "  client   $K        context  $CTX"
echo "  date     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
$HAVE_JQ || echo "  NOTE: jq is missing. The per-claim detail and the CSV need it."

# ── which namespaces ────────────────────────────────────────────────────────
if [ -n "$NS_FILTER" ]; then
  NAMESPACES=$(echo "$NS_FILTER" | tr ',' ' ')
else
  NAMESPACES=$($K get pvc -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)
fi
NS_COUNT=$(echo "$NAMESPACES" | tr ' ' '\n' | grep -c . || echo 0)

# ============================================================================
sec "A. CAN THIS CLUSTER MIGRATE AT ALL"

# An inventory of an estate that is still coming up reads EXACTLY like an
# inventory of a settled one, and that is the whole danger. Measured on a
# lab cluster on 19-aug-2026: this ran minutes after the estate was
# bootstrapped, the CockroachDB StatefulSet did not exist yet, and the report
# said its namespace had one operator. Re-run with everything up, it had two.
# Nothing in the first report looked incomplete.
#
# What can honestly be measured from here is how recently things were made.
# It does not prove an estate is settled — a deployment that finished an hour
# ago and is still crash-looping looks old — so it never says "settled". It
# says whether anything moved while this ran, and that is a real answer.
#
# THE CUT-OFF IS A STRING, AND ON PURPOSE. The obvious way to write this is
# `now - (.metadata.creationTimestamp | fromdateiso8601) < 600` in jq, and it
# is wrong on most machines: jq 1.6's fromdateiso8601 goes through the local
# timezone. Measured here, TZ=CEST, on a timestamp generated seconds earlier:
#
#     $ jq -n 'now - ("2026-08-19T13:11:54Z" | fromdateiso8601)'
#     -3599.07
#
# — an hour into the future. West of UTC the sign flips and nothing is ever
# recent; east of it everything is. A Kubernetes creationTimestamp is always
# RFC 3339 in UTC with a Z, so these sort lexicographically, and a plain `>`
# compares the same on every jumphost in every timezone.
echo "-- Was the estate still changing while this ran? --"
CUTOFF=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
if $HAVE_JQ && [ -n "$CUTOFF" ]; then
  YOUNG=$($K get deploy,sts,ds -A -o json 2>/dev/null | jq -r --arg cutoff "$CUTOFF" '
    .items[]?
    | select(((.metadata.creationTimestamp // "") | length) > 0)
    | select(.metadata.creationTimestamp > $cutoff)
    | "     \(.metadata.namespace)/\(.kind)/\(.metadata.name)"' 2>/dev/null)
  if [ -n "$YOUNG" ]; then
    echo "   *** WORKLOADS CREATED IN THE LAST 10 MINUTES ***"
    echo "$YOUNG" | head -12
    echo "     This inventory is a snapshot of a moving estate. Anything"
    echo "     created after this run started is simply absent from it, and"
    echo "     an absent operator is a window planned without it. Re-run once"
    echo "     nothing is still being created, and plan from that run."
  else
    echo "   nothing was created in the last 10 minutes, so the estate was not"
    echo "   visibly moving while this ran. That is the cheap half of the"
    echo "   question — ask them the other half: is anything mid-deployment,"
    echo "   scaled down for now, or waiting on a change window?"
  fi
else
  echo "   NOT CHECKED — needs jq and a date that understands '10 minutes"
  echo "   ago'. Do not read this as 'nothing moved'."
fi

echo
echo "-- Kubernetes version --"
$K version -o json 2>/dev/null | grep -E '"gitVersion"' | tail -1
echo "   1.29 is the floor for live-sync: the sidecar is a native sidecar"
echo "   (initContainer with restartPolicy: Always), absent below it."

echo
echo "-- Trident --"
$K get deploy -n trident -o jsonpath='{range .items[*]}   {.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
  || echo "   NOT INSTALLED — the destination does not exist yet; building it is our job."
echo "   Qtree import is Tech Preview from 26.06. Below that an"
echo "   ontap-nas-economy destination cannot be adopted."

echo
echo "-- Nodes --"
$K get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory --no-headers 2>/dev/null | sed 's/^/   /'
echo "-- Node load (for concurrency) --"
if [ "$K" = oc ]; then oc adm top nodes 2>&1; else $K top nodes 2>&1; fi | sed 's/^/   /' | head -6
echo "   If that failed there is no metrics-server: concurrency becomes an"
echo "   ESTIMATE, not a measurement. Say so rather than quoting the number."

echo
echo "-- Can the nodes run the copy image? --"
if $TP_PROBE_PULL; then
  $K run tp-pull-probe --image=alpine:3.19 --restart=Never --command -- sh -c 'echo ok' >/dev/null 2>&1
  $K wait --for=jsonpath='{.status.phase}'=Succeeded pod/tp-pull-probe --timeout=90s >/dev/null 2>&1 \
    && echo "   OK — alpine:3.19 runs on this cluster" \
    || { echo "   PROBE DID NOT SUCCEED:"; $K describe pod tp-pull-probe 2>/dev/null | sed -n '/Events:/,$p' | tail -8 | sed 's/^/     /'; }
  $K delete pod tp-pull-probe --ignore-not-found >/dev/null 2>&1
else
  echo "   NOT RUN - this test creates a pod, and this script otherwise writes nothing."
  echo "   Re-run with --probe-pull to test it, or ask the cluster team whether the"
  echo "   nodes can pull alpine:3.19 (or the mirrored equivalent) from their registry."
fi
echo "   Wait for Succeeded, not Ready: the container prints and exits, so a"
echo "   Ready condition is never satisfied and the wait times out for a"
echo "   reason that belongs to the wait."

# ============================================================================
sec "B. WHAT EXISTS TODAY — the source side"

echo "-- StorageClasses --"
$K get sc -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode --no-headers 2>/dev/null | sed 's/^/   /'

echo
echo "-- Trident backends: where the array is, which SVM, which driver --"
echo "   (a backend made with tridentctl has NO tbc; that is normal)"
$K get tbc -n trident -o custom-columns=NAME:.metadata.name,BACKEND:.spec.backendName,DRIVER:.spec.storageDriverName,SVM:.spec.svm,MGMT:.spec.managementLIF,DATA:.spec.dataLIF,PREFIX:.spec.storagePrefix,SECRET:.spec.credentials.name --no-headers 2>/dev/null | sed 's/^/   /'
$K get tbe -n trident -o custom-columns=NAME:.metadata.name,BACKEND:.backendName,STATE:.state,ONLINE:.online --no-headers 2>/dev/null | sed 's/^/   /'
echo "   Anything but online provisions nothing, and the failure shows up on"
echo "   a PVC stuck Pending rather than on the backend."
$K exec -n trident deploy/trident-controller -c trident-main -- tridentctl get backend -o json 2>/dev/null \
  | { $HAVE_JQ && jq -r '.items[]? |
        # tridentctl nests everything under .config and spells the driver
        # differently from the TBC. Reading the TBC key here printed a null
        # driver and an empty object for the prefix on a real cluster.
        "   \(.name)\t\(.config.storageDriverName // .storageDriverName // "-")" +
        "\tsvm=\(.config.svm // "-")" +
        "\tmgmt=\(.config.managementLIF // "-")" +
        "\tdata=\(.config.dataLIF // "-")" +
        "\tprefix=\(if (.config.storagePrefix|type) == "string" then .config.storagePrefix else "-" end)"' \
      || cat; } 2>/dev/null

# The prefix decides whether a NEW backend collides with this one, and
# neither the TBC nor tridentctl reported it as a string on a real cluster —
# both printed an empty object. It is in plain sight in the internal names,
# so it is derived rather than reported as absent.
if $HAVE_JQ; then
  DERIVED=$($K get tridentvolumes -n trident -o json 2>/dev/null \
    | jq -r '[.items[]? | .config.internalName // ""
              | capture("^(?<p>.*?)pvc_") | .p] | unique | .[]' 2>/dev/null)
  [ -n "$DERIVED" ] && {
    echo "   prefixes actually in use, read from the volume names:"
    echo "$DERIVED" | sed 's/^/     /'
  }
fi

echo
echo "-- Every CSI driver installed, and how it treats ownership --"
# fsGroupPolicy is the one that matters here. A driver set to None does not
# let the kubelet chown the volume, so file ownership is whatever the copy
# wrote — and a copy that ran as the wrong uid produces an application that
# starts and cannot read its own data.
$K get csidrivers -o custom-columns=NAME:.metadata.name,ATTACH:.spec.attachRequired,FSGROUP:.spec.fsGroupPolicy --no-headers 2>/dev/null | sed 's/^/   /' \
  || echo "   could not list csidrivers"
echo "   A provisioner here with no StorageClass above it is a driver"
echo "   somebody installed and nothing uses. A StorageClass whose"
echo "   provisioner is NOT here provisions nothing at all."

# Only when the source is vSphere CSI. A limit nobody hits until they do,
# and then it is at 3am: a node takes at most 59 vSphere volumes across its
# four PVSCSI controllers, and the 60th claim schedules nowhere with an error
# that talks about the pod, not about the controller that is full.
#
# It is NOT doubled by migrating. The destination is an ONTAP volume — NFS or
# iSCSI from the guest — and neither takes a PVSCSI slot; the source is
# already attached and the copy pod mounts that same claim. What this says is
# how much room the estate has, which decides where anything can be placed.
if $K get csidrivers -o name 2>/dev/null | grep -q "csi.vsphere.vmware.com"; then
  echo
  echo "-- vSphere CSI: volumes attached per node (limit 59) --"
  $K get volumeattachment -o json 2>/dev/null | python3 -c '
import json, sys, collections
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    print("   could not read volumeattachments"); raise SystemExit
per = collections.Counter()
for va in items:
    spec = va.get("spec", {})
    if spec.get("attacher") != "csi.vsphere.vmware.com":
        continue
    if not (va.get("status") or {}).get("attached"):
        continue
    per[spec.get("nodeName", "?")] += 1
if not per:
    print("   none attached right now")
else:
    for node, n in sorted(per.items(), key=lambda kv: -kv[1]):
        room = 59 - n
        flag = ""
        if room <= 0:
            flag = "   <- FULL: nothing more schedules here"
        elif room <= 10:
            flag = "   <- %d left" % room
        print("   %-42s %2d/59%s" % (node, n, flag))
' || echo "   could not count"
  echo "   A node at 59 takes no more vSphere volumes, and the pod that"
  echo "   wanted one stays Pending saying nothing about controllers."
fi

echo
echo "-- Snapshot support --"
$K get volumesnapshotclass -o custom-columns=NAME:.metadata.name,DRIVER:.driver --no-headers 2>/dev/null | sed 's/^/   /' \
  || echo "   none — the snapshot mode is unavailable"
echo -n "   may create volumesnapshots: "; $K auth can-i create volumesnapshots 2>&1 | head -1
echo "   Present, absent and FORBIDDEN are three different answers."
# VolumeGroupSnapshot: crash-consistent across every claim in a group, so a
# namespace of claims can be cut over at one instant instead of one at a
# time. GA in Kubernetes 1.36. It only helps when EVERY claim in the
# namespace has a class registered for its driver — one that has not is one
# that cuts over separately, and then the group was not consistent after all.
VGS=$($K get volumegroupsnapshotclasses -o custom-columns=NAME:.metadata.name,DRIVER:.driver --no-headers 2>/dev/null)
if [ -n "$VGS" ]; then
  echo "   VolumeGroupSnapshotClasses (crash-consistent multi-claim cutover):"
  echo "$VGS" | sed 's/^/     /'
else
  echo "   no VolumeGroupSnapshotClass — a namespace's claims cut over one"
  echo "   at a time, not at one instant"
fi

echo
echo "-- What is on the array behind each claim --"
$K get tridentvolumes -n trident -o custom-columns=PV:.config.name,INTERNAL:.config.internalName,POOL:.pool,SIZE:.config.size --no-headers 2>/dev/null | sed 's/^/   /' | head -40
echo "   internalName is the FlexVol, qtree or LUN. With the economy drivers"
echo "   many claims share one FlexVol — and SnapMirror replicates the FlexVol."

# ============================================================================
sec "C. EVERY NAMESPACE, EVERY CLAIM — the migration proposal"
echo "  $NS_COUNT namespace(s) hold a persistent volume"

# TridentBackendConfig, read for real : until now this
# only reached the printed report (section B, "$K get tbc -n trident" above)
# and a YAML draft at the end of this file — never the CSV, and never a
# `kubectl get tridentbackendconfigs.trident.netapp.io`, only the `tbc`
# shortname. A StorageClass names a Trident backend only through
# `parameters.backendType`, which is a DRIVER name, and more than one backend
# can share a driver, so the most this can honestly say per claim is "the
# backend(s) built with this driver" — never "the one backend that would
# serve this claim". Read across every namespace, unlike the rest of this
# file's `-n trident`: Trident is not always installed in a namespace
# literally called `trident`, and this is the one read here cheap enough to
# not assume it. Same silent-if-missing shape as every other optional read
# in this file: no CRD, no output, empty map, "-" in the column — never an
# error that cuts the rest of the report.
TP_SC_TBC_MAP='{}'
# fsType (StorageClass -> .parameters.fsType), same pattern as the
# backend map right below it, and read from the same `$K get sc -o json`
# rather than a second round-trip. Unlike the backend map this is NOT
# filtered to the Trident provisioner: fsType is a parameter every CSI
# driver's StorageClass can carry (ceph-rbd, longhorn, ...), and the source
# side of a pre-assessment is routinely not Trident at all — that is the
# whole reason this column exists: a source fsType that does not match what the
# destination StorageClass wants is exactly the choque this CSV is meant to
# surface before the migration, not at cutover.
TP_SC_FSTYPE_MAP='{}'
if $HAVE_JQ; then
  TP_SC_JSON=$($K get sc -o json 2>/dev/null)
  TP_TBC_DRIVER_MAP=$($K get tridentbackendconfigs.trident.netapp.io -A -o json 2>/dev/null | jq -c '
    ([.items[]? | select(.spec.storageDriverName != null and .spec.backendName != null)]
     | group_by(.spec.storageDriverName)
     | map({(.[0].spec.storageDriverName): ([.[].spec.backendName] | join("|"))})
     | add) // {}' 2>/dev/null)
  [ -z "$TP_TBC_DRIVER_MAP" ] && TP_TBC_DRIVER_MAP='{}'
  TP_SC_TBC_MAP=$(printf '%s' "$TP_SC_JSON" | jq -c --argjson drivers "$TP_TBC_DRIVER_MAP" '
    ([.items[]? | select(.provisioner == "csi.trident.netapp.io") |
      (.parameters.backendType // "") as $driver |
      select($driver != "") |
      {(.metadata.name): ($drivers[$driver] // "-")}]
     | add) // {}' 2>/dev/null)
  [ -z "$TP_SC_TBC_MAP" ] && TP_SC_TBC_MAP='{}'
  TP_SC_FSTYPE_MAP=$(printf '%s' "$TP_SC_JSON" | jq -c '
    ([.items[]? | {(.metadata.name): (.parameters.fsType // "-")}] | add) // {}' 2>/dev/null)
  [ -z "$TP_SC_FSTYPE_MAP" ] && TP_SC_FSTYPE_MAP='{}'
fi

# Column order: fsType sits next to tridentBackend — both answer "what would
# the destination need to match" — and annotations sits right after labels,
# the same key=value|-joined shape it already uses.
printf 'namespace,claim,storageClass,volumeMode,accessModes,size,holder,ownerKind,fromTemplate,cutover,pod,pv,tridentBackend,fsType,labels,annotations\n' > "$CSV"

for NS in $NAMESPACES; do
  [ -z "$NS" ] && continue
  echo
  echo "── $NS ─────────────────────────────────────────────────────────"
  $K get pvc -n "$NS" -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,MODE:.spec.volumeMode,ACCESS:.spec.accessModes,SIZE:.status.capacity.storage,PHASE:.status.phase --no-headers 2>/dev/null | sed 's/^/   /'

  if $HAVE_JQ; then
    echo "   workloads:"
    $K get deploy,sts,ds -n "$NS" -o json 2>/dev/null > /tmp/tp-w.$$ || true
    jq -r '.items[]? |
      "     \(.kind)/\(.metadata.name)  replicas=\(.spec.replicas // 1)" +
      # Declared is not running. A StatefulSet that says replicas=3 with one
      # pod up produces one claim, and the report then reads as if we had
      # missed two. Say which it is, because a claim whose pod never started
      # may also hold nothing.
      (if ((.status.readyReplicas // 0) != (.spec.replicas // 1))
       then "  (\(.status.readyReplicas // 0) actually ready)" else "" end) +
      "  owner=\(((.metadata.ownerReferences // []) | map(.kind) | join(",")) // "-")" +
      (if ((.spec.volumeClaimTemplates // []) | length) > 0
       then "  vct=\((.spec.volumeClaimTemplates | map(.metadata.name) | join(",")))  -> PV-SWAP cutover"
       else "" end)' /tmp/tp-w.$$ 2>/dev/null

    # An operator above any of them means scaling what it manages achieves
    # nothing, because it reconciles back in seconds. Asked through the same
    # function section D uses — this line used to have its own weaker copy of
    # the question, and a namespace could be called operator-free here and
    # operator-owned there.
    OPERATOR=$(tp_operator_owners "$NS" /tmp/tp-w.$$ | awk -F'\t' '$3 != "ours"')
    [ -n "$OPERATOR" ] && {
      echo "     *** OPERATOR-OWNED: the stop goes through its custom resource ***"
      echo "$OPERATOR" | awk -F'\t' '{printf "       %s/%s   %s\n", $1, $2, $3}'
    }

    # Fetched ONCE per namespace and kept on disk: "what mounts what" below,
    # the bare-pod check, the subPath check and the CSV row all ask this same
    # question of the same pods — this used to be four separate `$K get pods`
    # calls per namespace.
    $K get pods -n "$NS" -o json 2>/dev/null > /tmp/tp-p.$$ || true

    echo "   what mounts what:"
    jq -r '
      .items[]? | . as $p | ($p.spec.volumes // [])[] |
      select(.persistentVolumeClaim) |
      "     \($p.metadata.name) -> \(.persistentVolumeClaim.claimName)"' /tmp/tp-p.$$ 2>/dev/null

    # Things that hold a claim and are NOT running right now. A CronJob has
    # no pod between firings, so it appears in neither the workload list nor
    # in what-mounts-what — and then it fires at three in the morning, in the
    # middle of the window, and takes the claim while the copy is running.
    # This is the one class of holder that cannot be found by looking at what
    # is up.
    SCHEDULED=$($K get cronjob,job -n "$NS" -o json 2>/dev/null | jq -r '
      .items[]? | . as $w
      | ((.spec.jobTemplate.spec.template.spec.volumes // [])
         + (.spec.template.spec.volumes // []))[]
      | select(.persistentVolumeClaim)
      | "     \(.persistentVolumeClaim.claimName)  <- \($w.kind)/\($w.metadata.name)"
        + (if $w.spec.schedule then "  schedule: \($w.spec.schedule)" else "" end)
        + (if $w.spec.suspend == true then "  (SUSPENDED)" else "" end)' \
      2>/dev/null | sort -u)
    [ -n "$SCHEDULED" ] && {
      echo "   *** HOLDS A CLAIM AND IS NOT ALWAYS RUNNING ***"
      echo "$SCHEDULED"
      echo "     Suspend these before the window. A CronJob that fires during"
      echo "     the copy takes the claim from under it, and nothing above"
      echo "     reports it because between firings there is no pod."
    }

    # A claim held by a Pod with no controller above it. Found on a real
    # cluster: three postgres claims appeared under "what mounts what" and
    # in no workload, because the pods are bare. That is not a detail — a
    # bare Pod cannot be scaled to zero, so the stop is a delete, and
    # nothing recreates it afterwards. Somebody has to know that before the
    # window, not during it.
    BARE=$(jq -r '
      .items[]? | select((.metadata.ownerReferences // []) | length == 0)
      | . as $p | ($p.spec.volumes // [])[] | select(.persistentVolumeClaim)
      | "     \(.persistentVolumeClaim.claimName)  held by pod/\($p.metadata.name)"' \
      /tmp/tp-p.$$ 2>/dev/null | sort -u)
    [ -n "$BARE" ] && {
      echo "   *** BARE PODS — no controller owns these ***"
      echo "$BARE"
      echo "     Stopping one is a delete, and nothing brings it back."
    }

    # subPath is worth surfacing: the data lives in a subdirectory of the
    # volume, so anybody validating the destination at its root sees a
    # directory where they expected the application's files.
    # Only subPaths on volumes that are CLAIMS. A pod commonly has a dozen
    # emptyDir mounts with subPaths and none of them is being migrated;
    # listing them buries the one that is. On the first real run this printed
    # twelve irrelevant lines above the single line that mattered.
    SUBPATHS=$(jq -r '
      .items[]? | . as $p
      | [($p.spec.volumes // [])[] | select(.persistentVolumeClaim)
         | {name: .name, claim: .persistentVolumeClaim.claimName}] as $pvc
      | $p.spec.containers[]? | (.volumeMounts // [])[]
      | select(.subPath)
      | . as $m | ($pvc[] | select(.name == $m.name))
      | "     \(.claim) is mounted at subPath \($m.subPath)"' /tmp/tp-p.$$ 2>/dev/null | sort -u)
    [ -n "$SUBPATHS" ] && { echo "   mounted with a subPath:"; echo "$SUBPATHS"; }

    # one CSV row per claim. holder/ownerKind/fromTemplate/cutover thread
    # together data this loop already computed above (the workload/VCT read,
    # and the pod read just above) instead of leaving them empty.
    # pv and tridentBackend are the two genuinely new reads that finding
    # asked for; labels was sitting unused in the same PVC JSON already
    # fetched below. fsType and annotations: fsType comes from
    # $scfstype, same StorageClass-name lookup pattern as $sctbc above it;
    # annotations reads the same PVC JSON as labels, one line down.
    $K get pvc -n "$NS" -o json 2>/dev/null | jq -r --arg ns "$NS" \
      --slurpfile tpw /tmp/tp-w.$$ --slurpfile tpp /tmp/tp-p.$$ \
      --argjson sctbc "$TP_SC_TBC_MAP" --argjson scfstype "$TP_SC_FSTYPE_MAP" '
      # Where a claim is held, and how it would be cut over — checked in
      # decreasing order of certainty, not decreasing importance:
      #  1) a StatefulSet volumeClaimTemplate, matched by the ordinal naming
      #     convention Kubernetes itself guarantees (<template>-<sts>-<n>) —
      #     the one case this can be CERTAIN about, hence fromTemplate=true;
      #  2) a Deployment/DaemonSet/plain-StatefulSet naming this claim
      #     directly in its own pod template — still the workload, not a
      #     guess;
      #  3) whatever Pod actually mounts it right now, one level up its own
      #     ownerReferences (a ReplicaSet, a Job, an operator CR, or nothing
      #     at all — a bare pod). cutover is deliberately "-" here rather
      #     than a guessed method: a kind this cannot classify may have no
      #     scale subresource at all.
      def claim_holder($claim; $workloads; $pods):
        ( [ $workloads[]? | select(.kind == "StatefulSet") | . as $w |
            ($w.spec.volumeClaimTemplates // [])[]? | .metadata.name as $vct |
            select($claim | test("^" + $vct + "-" + $w.metadata.name + "-[0-9]+$")) |
            {holder: ("StatefulSet/" + $w.metadata.name), ownerKind: "StatefulSet",
             fromTemplate: true, cutover: "PV-SWAP"} ]
        + [ $workloads[]? | select(((.spec.volumeClaimTemplates // []) | length) == 0) | . as $w |
            (($w.spec.template.spec.volumes // [])[]? |
             select(.persistentVolumeClaim.claimName == $claim)) |
            {holder: ($w.kind + "/" + $w.metadata.name), ownerKind: $w.kind,
             fromTemplate: false,
             cutover: (if $w.kind == "DaemonSet" then "scale-to-zero (every node)"
                       else "scale-to-zero" end)} ]
        + [ $pods[]? | . as $p |
            (($p.spec.volumes // [])[]? |
             select(.persistentVolumeClaim.claimName == $claim)) |
            (($p.metadata.ownerReferences // [])[0]) as $ref |
            if $ref == null then
              {holder: ("Pod/" + $p.metadata.name), ownerKind: "Pod",
               fromTemplate: false, cutover: "delete (bare pod, no controller)"}
            else
              {holder: ($ref.kind + "/" + $ref.name), ownerKind: $ref.kind,
               fromTemplate: false, cutover: "-"}
            end ]
        ) | first // {holder: "-", ownerKind: "-", fromTemplate: false, cutover: "-"};
      ($tpw[0].items // []) as $wl | ($tpp[0].items // []) as $pl |
      .items[]? | . as $c |
      claim_holder($c.metadata.name; $wl; $pl) as $h |
      [$ns, $c.metadata.name, ($c.spec.storageClassName // "-"),
       ($c.spec.volumeMode // "Filesystem"),
       (($c.spec.accessModes // []) | join("|")),
       ($c.status.capacity.storage // $c.spec.resources.requests.storage // "-"),
       $h.holder, $h.ownerKind, (if $h.fromTemplate then "true" else "false" end), $h.cutover,
       ( ([$pl[]? | select((.spec.volumes // [])[]?.persistentVolumeClaim.claimName == $c.metadata.name)
           | .metadata.name] | join("|")) as $podnames
         | if $podnames == "" then "-" else $podnames end ),
       ($c.spec.volumeName // "-"),
       ($sctbc[($c.spec.storageClassName // "")] // "-"),
       ($scfstype[($c.spec.storageClassName // "")] // "-"),
       ( (($c.metadata.labels // {}) | to_entries | map("\(.key)=\(.value)") | join("|")) as $lbls
         | if $lbls == "" then "-" else $lbls end ),
       ( (($c.metadata.annotations // {}) | to_entries | map("\(.key)=\(.value)") | join("|")) as $annos
         | if $annos == "" then "-" else $annos end )
      ] | @csv' >> "$CSV" 2>/dev/null
    rm -f /tmp/tp-w.$$ /tmp/tp-p.$$
  fi

  # Leftovers from an earlier attempt: a -tp-dest claim means a run started
  # and did not finish, and discovery excludes them as sources.
  LEFT=$($K get pvc -n "$NS" --no-headers 2>/dev/null | grep -c -- '-tp-dest' || true)
  [ "${LEFT:-0}" != "0" ] && echo "   *** ${LEFT} leftover -tp-dest claim(s) from an unfinished run ***"
done

# ============================================================================
sec "D. WHAT WOULD FIGHT BACK"

echo "-- GitOps --"
$K get applications.argoproj.io -A -o json 2>/dev/null | { $HAVE_JQ && jq -r '.items[]? |
  "   \(.metadata.namespace)/\(.metadata.name)  dest=\(.spec.destination.namespace)  sync=\(.spec.syncPolicy)"' || cat; } 2>/dev/null \
  || echo "   no Argo CD"
$K get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend 2>/dev/null | sed 's/^/   /' \
  || echo "   no Flux"
echo "   'automated: {}' — an EMPTY dict — IS auto-sync. The key is the"
echo "   switch, not its contents, which is why the whole syncPolicy prints."
echo
tp_argo_probe

echo
echo "-- Anything that owns or re-creates a claim (provisioner-agnostic) --"
echo "   It does not matter whether it is a database operator, a KubeVirt VM,"
echo "   a Harvester VM or something we have never seen. What matters is that"
echo "   a controller references the claim and will put back what we change."
for R in $($K api-resources --namespaced=true --verbs=list -o name 2>/dev/null \
           | grep -vE '^(pods|events|endpoints|configmaps|secrets|serviceaccounts|services|controllerrevisions\.apps|endpointslices\.discovery\.k8s\.io|leases\.coordination\.k8s\.io|persistentvolumeclaims|replicasets\.apps|deployments\.apps|statefulsets\.apps|daemonsets\.apps)$'); do
  HITS=$($K get "$R" -A -o json 2>/dev/null \
         | grep -oE '"(claimName|persistentVolumeClaimName)": *"[^"]+"' | sort -u | head -6)
  [ -n "$HITS" ] && echo "   $R -> $(echo "$HITS" | tr '\n' ' ')"
done
echo "   (the migration's own migrate-*/validate-* Jobs appear here if a run"
echo "    has already happened; they are not a finding)"

echo
echo "-- Virtual machine disks --"
# The sweep above finds a VM's claim like any other controller's. This names
# them, because the CUTOVER is a different procedure: a VM disk is a
# DataVolume, and CDI re-imports over a claim you have just swapped unless
# the populatedFor annotation is right. Stop the VM, delete the DataVolume
# with --cascade=orphan, recreate the claim — in that order. None of that
# looks like scaling a Deployment, so a VM found late is a wave replanned.
if $K get crd virtualmachines.kubevirt.io >/dev/null 2>&1; then
  VMS=$($K get vm -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RUNNING:.spec.running 2>/dev/null)
  if [ -n "$VMS" ]; then
    echo "$VMS" | sed 's/^/   /'
    echo "   Each of these is its own cutover procedure. Confirm whether"
    echo "   their disks are DataVolumes (CDI) or plain claims."
  else
    echo "   KubeVirt is installed and no VirtualMachine exists"
  fi
else
  echo "   no KubeVirt. Ask anyway whether VMs run anywhere else — Harvester,"
  echo "   OpenShift Virtualization on another cluster — because their disks"
  echo "   may be served by the same array."
fi

echo
echo "-- Holders that are not running right now, cluster-wide --"
# Section C prints these per namespace, and prints nothing when a namespace
# has none. Across 150 namespaces that silence is unreadable: it looks
# identical to not having looked. So state the cluster-wide count once.
if $HAVE_JQ; then
  SCHED_ALL=$($K get cronjob,job -A -o json 2>/dev/null | jq -r '
    [.items[]? | . as $w
     | ((.spec.jobTemplate.spec.template.spec.volumes // [])
        + (.spec.template.spec.volumes // []))[]
     | select(.persistentVolumeClaim)
     | "\($w.metadata.namespace)/\($w.kind)/\($w.metadata.name)"] | unique | .[]')
  if [ -n "$SCHED_ALL" ]; then
    echo "$SCHED_ALL" | sed 's/^/   /'
    echo "   Suspend these before the window. A CronJob that fires during the"
    echo "   copy takes the claim from under it, and between firings there is"
    echo "   no pod, so nothing else in this report would show it."
  else
    echo "   none — no CronJob or Job anywhere in this cluster holds a claim."
    echo "   Checked, not skipped: this is the commonest and best answer."
  fi
else
  echo "   NOT CHECKED — needs jq. Do not read this as 'none'."
fi

echo
TP_OPERATORS_TSV=""
echo "-- OPERATORS: what owns the workloads, and do we have a stop for it --"
# The detection is tp_operator_owners, defined at the top of this file: an
# ownerReference, and where there is none the label conventions the product's
# own registry records, with the custom resource confirmed to exist.
if $HAVE_JQ; then
  FOUND=""
  for NS in $NAMESPACES; do
    [ -z "$NS" ] && continue
    OWNERS=$(tp_operator_owners "$NS" | awk -v ns="$NS" -F'\t' \
             '{printf "%s\t%s\t%s\t%s\n", ns, $1, $2, $3}')
    [ -n "$OWNERS" ] && FOUND="$FOUND$OWNERS"$'\n'
  done
  OURS=$(echo "$FOUND" | awk -F'\t' '$4 == "ours"' | sort -u)
  THEIRS=$(echo "$FOUND" | grep -v '^$' | awk -F'\t' '$4 != "ours"' | sort -u)
  # AND CAN WE STOP IT. Naming the operator is half the question, and it is
  # the half that reads as the whole one. "There is a CrdbCluster here" and
  # "we can take this application down cleanly" are different sentences, and
  # the report only ever printed the first: on a lab cluster, `CrdbCluster/shop-crdb`
  # was listed as KNOWN, and CockroachDB's CRD declares `minimum: 3`, so there
  # is no patch that stops it at all. A migration of that namespace ended
  # `could-not-stop` with `copied=0` nine minutes in.
  #
  # Eleven of the registry's thirty-six kinds are like that, and which eleven
  # is recorded in the product and was never asked here. A namespace whose
  # operator refuses zero is a namespace where the copy may run against a LIVE
  # database — which is where everything section G says about flushing, and
  # about engines that keep their data in memory, stops being theoretical.
  #
  # `others` is how many OTHER namespaces hold this same kind. It is evidence
  # and not proof — an operator can serve a namespace it has no custom
  # resource in — but where it is above zero, holding the controller down
  # suspends reconciliation for somebody who was never asked.
  TP_OPERATORS_TSV=$(echo "$THEIRS" | while IFS=$'\t' read -r NS KIND NAME HOW; do
    [ -n "$KIND" ] || continue
    OTHER_N=$(echo "$THEIRS" | awk -F'\t' -v k="$KIND" -v ns="$NS" \
              '$2 == k && $1 != ns {print $1}' | sort -u | grep -c . || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$NS" "$KIND" "$NAME" "$HOW" \
      "$(tp_stop_strategy "$KIND" "${OTHER_N:-0}")" "${OTHER_N:-0}"
  done)
  if [ -z "$THEIRS" ]; then
    echo "   none — every workload holding a claim is a plain Deployment,"
    echo "   StatefulSet or DaemonSet, so stopping is a scale to zero."
  else
    echo "$TP_OPERATORS_TSV" | while IFS=$'\t' read -r NS KIND NAME HOW STRAT OTHER_N; do
      [ -n "$KIND" ] || continue
      if echo "$KIND" | grep -qE "^($TP_KNOWN_OPERATORS)$"; then
        printf '   %-14s %s/%s   KNOWN — we have a tested stop for this kind\n' "$NS" "$KIND" "$NAME"
      else
        printf '   %-14s %s/%s   *** NOT IN OUR CATALOGUE ***\n' "$NS" "$KIND" "$NAME"
        echo "                  Validate the stop against their cluster before"
        echo "                  the window: tp compat validate-operator-scaling.sh"
      fi
      # THE TWO REASONS ARE NOT THE SAME SENTENCE, and the report used to be
      # able to say only one of them. "Its CRD forbids zero" is a fact about
      # the operator, checkable, and nothing will ever change it. "Nobody has
      # studied this kind" is a fact about US, and the answer to it is an
      # afternoon's work before the window rather than a different procedure
      # for ever. They end in the same place — hold the controller, scale the
      # workload — and a customer is owed the distinction.
      case "$STRAT" in
        via-cr)
          echo "                  STOP: patch its custom resource to zero. The"
          echo "                  operator takes its own pods down and puts them"
          echo "                  back when it is restored." ;;
        hold-operator|needs-agreement)
          if echo "$KIND" | grep -qE "^($TP_REFUSES_ZERO)$"; then
            echo "                  *** ITS CUSTOM RESOURCE REFUSES ZERO ***"
            echo "                  Its CRD declares a minimum above zero, so"
            echo "                  there is no patch that stops it. Measured:"
            echo "                  CockroachDB's declares minimum 3."
          else
            echo "                  *** NO STOP KNOWN FOR THIS KIND ***"
            echo "                  Nothing here knows which field its custom"
            echo "                  resource counts replicas in, and guessing is"
            echo "                  how a patch is accepted, pruned in silence"
            echo "                  and reported as a success."
          fi
          echo "                  Either way the stop is: hold the CONTROLLER"
          echo "                  down, then scale the workload underneath it. A"
          echo "                  different and longer procedure, which needs the"
          echo "                  operator's own namespace — and where it cannot"
          echo "                  be arranged the copy runs HOT."
          if [ "$STRAT" = "needs-agreement" ]; then
            echo "                  *** AND IT IS NOT OURS TO HOLD ***"
            printf '                  This kind also appears in %s other namespace(s).\n' "$OTHER_N"
            echo "                  Holding the controller suspends reconciliation"
            echo "                  there for the length of the window: their pods"
            echo "                  keep running, but nothing fails over, rotates"
            echo "                  a certificate or runs a backup until it is"
            echo "                  released. Somebody who owns those namespaces"
            echo "                  has to agree to that."
          fi ;;
      esac
      case "$HOW" in
        *"no ownerReference"*)
          echo "                  NO ownerReference — this operator manages the"
          echo "                  workload without owning it, so nothing above"
          echo "                  says so. Found by its own label convention and"
          echo "                  confirmed against the custom resource." ;;
      esac
    done
    echo
    echo "   Scaling what an operator owns achieves nothing — it reconciles the"
    echo "   replicas back in seconds. The stop goes through the custom resource"
    echo "   named above."
  fi
  [ -n "$OURS" ] && {
    echo
    echo "   (Trident Port's own TridentPort resource is installed here and is"
    echo "    not listed above. It is ours, it holds none of their workloads,"
    echo "    and listing it asks them to validate a stop for us.)"
  }
fi

echo
echo "-- PodSecurity, which can refuse a root container on its own --"
$K get ns -o custom-columns=NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\\.kubernetes\\.io/enforce --no-headers 2>/dev/null | grep -vE '<none>$' | sed 's/^/   /' || echo "   none set"

if [ "$K" = "oc" ]; then
  echo
  echo "-- OpenShift SCC (per namespace, for the default ServiceAccount) --"
  for NS in $NAMESPACES; do
    [ -z "$NS" ] && continue
    printf '   %-24s anyuid=%s\n' "$NS" \
      "$(oc auth can-i use scc/anyuid --as=system:serviceaccount:$NS:default -n $NS 2>/dev/null)"
  done
  echo "   The copy runs as uid 0 so file ownership survives it. restricted-v2"
  echo "   forbids that and the pod is NEVER CREATED. Fix with anyuid, not"
  echo "   privileged: the copy needs to BE root, not to escape the container."
  echo "   Block<->Filesystem conversions need SYS_ADMIN as well, which anyuid"
  echo "   does NOT grant — that is what trident-port-nfs-import is for."
fi

# ============================================================================
sec "E. TOTALS — what the destination has to be sized against"

if $HAVE_JQ; then
  $K get pvc -A -o json 2>/dev/null | jq -r '
    [.items[]? | {
       sc: (.spec.storageClassName // "-"),
       mode: (.spec.volumeMode // "Filesystem"),
       rwx: (((.spec.accessModes // []) | index("ReadWriteMany")) != null),
       bound: (.status.phase == "Bound"),
       bytes: ((.status.capacity.storage // .spec.resources.requests.storage // "0")
               | capture("(?<n>[0-9.]+)(?<u>[A-Za-z]*)")
               | (.n | tonumber) * (
                   if   .u == "Ki" then 1024 elif .u == "Mi" then 1048576
                   elif .u == "Gi" then 1073741824 elif .u == "Ti" then 1099511627776
                   elif .u == "K"  then 1000 elif .u == "M" then 1000000
                   elif .u == "G"  then 1000000000 elif .u == "T" then 1000000000000
                   else 1 end))
     }] as $all
    | ($all | map(select(.bound))) as $real
    | ($all | map(select(.bound | not))) as $unbound
    | "   claims                \($all | length)"
    , "   of those, BOUND       \($real | length)   <- only these can migrate"
      + (if ($unbound | length) > 0
         then "\n   NEVER BOUND           \($unbound | length)   *** no PV, no data, nothing to copy ***"
         else "" end)
    , "   total provisioned     \(($real | map(.bytes) | add // 0) / 1073741824 | floor) GiB   (bound only)"
    , "   largest single claim  \(($real | map(.bytes) | max // 0) / 1073741824 | floor) GiB"
    , "   raw block claims      \($real | map(select(.mode == "Block")) | length)   (dd over the whole device)"
    , "   RWX claims            \($real | map(select(.rwx)) | length)   (needs a NAS destination)"
    , ""
    , "   by source StorageClass:"
    , ($all | group_by(.sc)[] |
        "     \(.[0].sc)  claims=\(length)  \((map(select(.bound)) | map(.bytes) | add // 0) / 1073741824 | floor) GiB"
        + "  block=\(map(select(.bound and .mode == "Block")) | length)"
        + "  rwx=\(map(select(.bound and .rwx)) | length)"
        + (if (map(select(.bound | not)) | length) > 0
           then "  UNBOUND=\(map(select(.bound | not)) | length)" else "" end))
    , ($all | group_by(.sc)
       | map(select((map(select(.bound)) | length) == 0)) as $dead
       | if ($dead | length) > 0 then
           (["", "   *** THESE STORAGECLASSES PROVISION NOTHING ***"]
            + ($dead | map("     \(.[0].sc)  —  \(length) claim(s), not one ever bound"))
            + ["     A class every claim is Pending on has no working backend",
               "     behind it. Whatever it was meant to serve is not being",
               "     served today — a finding about their CURRENT estate,",
               "     before anyone migrates anything."]) | .[]
         else empty end)' 2>/dev/null
else
  echo "   (needs jq)"
fi

# Kept for section F, which is the only place that knows how big the
# destination is. Two true numbers in two different sections is not an
# answer to "does it fit" — somebody has to notice, and in front of a
# customer nobody does.
TP_BOUND_BYTES=0
if $HAVE_JQ; then
  TP_BOUND_BYTES=$($K get pvc -A -o json 2>/dev/null | jq -r '
    [.items[]? | select(.status.phase == "Bound")
     | ((.status.capacity.storage // "0")
        | capture("(?<n>[0-9.]+)(?<u>[A-Za-z]*)")
        | (.n | tonumber) * (
            if   .u == "Ki" then 1024 elif .u == "Mi" then 1048576
            elif .u == "Gi" then 1073741824 elif .u == "Ti" then 1099511627776
            elif .u == "K"  then 1000 elif .u == "M" then 1000000
            elif .u == "G"  then 1000000000 elif .u == "T" then 1000000000000
            else 1 end))] | add // 0 | floor' 2>/dev/null)
  [ -n "$TP_BOUND_BYTES" ] || TP_BOUND_BYTES=0
fi

echo
echo "   WHAT THIS DECIDES ABOUT THE DESTINATION WE BUILD:"
echo "     any RWX claim      -> a NAS backend is required; SAN cannot serve it"
echo "     any Block claim    -> a SAN backend, or the shape changes on arrival"
echo "     total provisioned  -> the aggregate has to hold it, plus snapshot"
echo "                           reserve if SnapMirror is used"
echo "     largest claim      -> no FlexVol can be smaller than its biggest"
echo "                           tenant"
echo "     storagePrefix      -> the new backend needs one not already in use"
echo "                           (see the prefixes in section B)"

# ============================================================================
sec "F. THE ARRAY"

# WHAT TRIDENT ALREADY KNOWS, ASKED OF THE CLUSTER AND NOT OF THE ARRAY.
#
# This section used to be all-or-nothing on ONTAP credentials: without them
# it printed "NOT COLLECTED" and a list of five things to go and ask someone
# for. Most of that list does not need the array at all — Trident records the
# backend it provisions through and the pool every volume landed on, and the
# person running a pre-assessment has a kubeconfig by definition and the
# array password usually not.
#
# So the cluster-derived half runs ALWAYS, and only the things that genuinely
# live on the filer are deferred. `tridentctl` is used when it is there and
# the CRs when it is not: both are reads of the same records.
echo "-- What Trident records, without asking the array --"
$K -n "${TRIDENT_NS:-trident}" get tridentbackend -o json 2>/dev/null | python3 -c '
import sys, json
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    items = []
if not items:
    print("   no TridentBackend records readable here")
for b in items:
    cfg = b.get("config", {}) or {}
    cfg = cfg.get("ontap_config") or cfg
    bits = []
    for key, label in (("storageDriverName", ""), ("svm", "svm="),
                       ("managementLIF", "mgmt="), ("dataLIF", "data="),
                       ("storagePrefix", "prefix=")):
        val = cfg.get(key)
        if val:
            bits.append("{}{}".format(label, val))
    print("   {:22s} {}".format(b.get("backendName", "?"), "  ".join(bits)))
' 2>/dev/null || echo "   (no python3 here — skipped)"

echo "-- Provisioned per pool, from Trident's own volume records --"
echo "   (free space is NOT here: Trident stores what it created, not what"
echo "    the aggregate has left. That one number still needs the array.)"
$K -n "${TRIDENT_NS:-trident}" get tridentvolume -o json 2>/dev/null | python3 -c '
import sys, json
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    items = []
pools = {}
flexvols = {}
unknown = []
for v in items:
    cfg = v.get("config", {}) or {}
    pool = v.get("pool") or "?"
    try:
        size = int(cfg.get("size") or 0)
    except (TypeError, ValueError):
        size = 0
    got = pools.setdefault(pool, [0, 0])
    got[0] += 1
    got[1] += size
    internal = cfg.get("internalName") or ""
    # A qtree is <flexvol>/<qtree>; a LUN is /vol/<flexvol>/<lun>. Anything
    # else IS the FlexVol. Which one a claim is decides who else a
    # SnapMirror break would stop.
    # WHETHER THE FLEXVOL IS KNOWABLE FROM HERE DEPENDS ON THE DRIVER, and
    # getting this wrong is not a cosmetic error.
    #
    # For ontap-nas and ontap-san the internalName IS the FlexVol, so those
    # claims genuinely move alone. For the ECONOMY drivers it is the qtree
    # or LUN name and the containing FlexVol is recorded NOWHERE in
    # Kubernetes -- checked on a live cluster, 18-aug-2026: a qtree volume
    # carries internalName=sm_pvc_045... and accessInformation.nfsPath
    # =/sm_pvc_045..., and no field anywhere names the volume it sits in.
    #
    # The first version of this grouped by "the bit before the slash", found
    # no slashes, and printed "no FlexVol holds more than one claim" about a
    # cluster whose qtree pool held seven. Under SnapMirror that sentence is
    # how a namespace nobody asked about gets stopped.
    if internal.startswith("/vol/"):
        parts = internal.split("/")
        flexvol = parts[2] if len(parts) > 2 else ""
    elif "/" in internal:
        flexvol = internal.split("/", 1)[0]
    else:
        flexvol = ""          # unknown from here, NOT "it is its own volume"
    if flexvol:
        flexvols.setdefault(flexvol, []).append(
            "{}/{}".format(cfg.get("namespace") or "?",
                           cfg.get("name") or cfg.get("requestName") or "?"))
    else:
        unknown.append("{}/{}".format(cfg.get("namespace") or "?",
                                      cfg.get("name") or "?"))
for pool in sorted(pools):
    count, total = pools[pool]
    print("   {:24s} {} volume(s)   {:.1f} GiB provisioned".format(
        pool, count, total / float(1 << 30)))
shared = {k: v for k, v in flexvols.items() if len(v) > 1}
if shared:
    print()
    print("   FLEXVOLS WITH MORE THAN ONE TENANT — a SnapMirror break applies")
    print("   to the whole volume, so these stop together whether or not they")
    print("   were asked about:")
    for name in sorted(shared)[:12]:
        print("     {}  <- {}".format(name, ", ".join(sorted(shared[name])[:6])))
    if len(shared) > 12:
        print("     ... and {} more".format(len(shared) - 12))
if unknown:
    print()
    print("   {} claim(s) are a QTREE or a LUN inside a shared FlexVol, and".format(len(unknown)))
    print("   WHICH FlexVol is not recorded in Kubernetes at all — Trident")
    print("   stores the qtree name and nothing above it. Who they would stop")
    print("   together under SnapMirror can only be answered by the array.")
    for name in sorted(unknown)[:8]:
        print("     {}".format(name))
    if len(unknown) > 8:
        print("     ... and {} more".format(len(unknown) - 8))
' 2>/dev/null || echo "   (no python3 here — skipped)"
echo

ONTAP_BASE="${ONTAP_API_BASE:-}"
[ -z "$ONTAP_BASE" ] && [ -n "${ONTAP_MGMT_LIF:-}" ] && ONTAP_BASE="https://${ONTAP_MGMT_LIF}/api"

# The password never travels on the command line. With an address and a user
# but no ONTAP_PASS, ask for it on the terminal, without echo. A variable that
# is already set is used untouched, so automation keeps working.
if [ -n "$ONTAP_BASE" ] && [ -n "${ONTAP_USER:-}" ] && [ -z "${ONTAP_PASS:-}" ] && [ -t 0 ]; then
  read -rs -p "ONTAP password for ${ONTAP_USER}: " ONTAP_PASS; echo
fi

if [ -n "$ONTAP_BASE" ] && [ -n "${ONTAP_PASS:-}" ]; then
  AUTH="-u ${ONTAP_USER:-admin}:${ONTAP_PASS}"

  # Ask once, and REFUSE to print a section of empty headings if the array
  # cannot be reached. An unreachable filer printed as blank tables reads as
  # "nothing there" — and the commonest cause is mundane: the address is
  # reachable from the cluster but not from wherever this is being run.
  PROBE=$(curl -sk --max-time 20 -w '\n%{http_code}' $AUTH "$ONTAP_BASE/cluster?fields=name,version" 2>&1)
  CODE=${PROBE##*$'\n'}
  BODY=${PROBE%$'\n'*}
  if [ "$CODE" != "200" ]; then
    # THREE DIFFERENT ANSWERS, and this printed the same paragraph for all
    # of them. Measured on a lab cluster on 18-aug-2026: a placeholder password
    # left in the command produced a clean HTTP 401 — the array answered
    # perfectly well and said "User is not authorized" — and this said
    # "THE ARRAY DID NOT ANSWER" and advised setting up a tunnel. Wrong
    # diagnosis, wrong remedy, and the person reading it went looking for
    # a network problem that did not exist.
    case "$CODE" in
      401|403)
        echo "   THE ARRAY REFUSED THE CREDENTIALS — this section was NOT collected."
        echo "     endpoint: $ONTAP_BASE"
        echo "     user:     ${ONTAP_USER:-admin}"
        echo "     status:   $CODE   $(echo "$BODY" | head -1 | tr -d '\n' | cut -c1-90)"
        echo
        echo "   The array is reachable and answered. What it rejected is the"
        echo "   user or the password: check ONTAP_USER / ONTAP_PASS, and that"
        echo "   the account has an http application login (ontapi/http) —"
        echo "   an ssh-only user gets exactly this."
        ;;
      000|"")
        echo "   THE ARRAY DID NOT ANSWER — this section was NOT collected."
        echo "     endpoint: $ONTAP_BASE"
        echo "     status:   no response"
        echo
        echo "   This is not a finding about the array. The usual cause is that"
        echo "   the management LIF is reachable from the cluster and not from"
        echo "   here — through a tunnel, set ONTAP_API_BASE to the local end:"
        echo "     ONTAP_API_BASE=https://127.0.0.1:9443/api ./tp-pre.sh"
        ;;
      *)
        echo "   THE ARRAY ANSWERED WITH AN ERROR — this section was NOT collected."
        echo "     endpoint: $ONTAP_BASE"
        echo "     status:   $CODE"
        echo "     said:     $(echo "$BODY" | head -2 | tr '\n' ' ' | cut -c1-160)"
        echo
        echo "   Reachable and authenticated, so this IS about the array or the"
        echo "   endpoint: a wrong path, an API version this build does not"
        echo "   have, or a proxy in the way. The status above is the clue."
        ;;
    esac
  else
  echo "-- Cluster --"
  echo "$BODY" | { $HAVE_JQ && jq -r '"   \(.name)   \(.version.full // "?")"' || sed 's/^/   /'; } 2>/dev/null
  echo "-- Aggregates and free space (the destination has to fit) --"
  curl -sk --max-time 20 $AUTH "$ONTAP_BASE/storage/aggregates?fields=name,space.block_storage.available,space.block_storage.size" 2>/dev/null \
    | { $HAVE_JQ && jq -r '.records[]? | "   \(.name)  free=\((.space.block_storage.available // 0)/1073741824|floor) GiB  of \((.space.block_storage.size // 0)/1073741824|floor) GiB"' || cat; } 2>/dev/null
  # THE QUESTION. Section E counts what is provisioned; the lines above
  # count what the destination has. Printing both and comparing neither is
  # how an estate that does not fit gets proposed with a straight face.
  echo "-- DOES IT FIT --"
  if $HAVE_JQ && [ "${TP_BOUND_BYTES:-0}" -gt 0 ]; then
    AGG_FREE=$(curl -sk --max-time 20 $AUTH \
      "$ONTAP_BASE/storage/aggregates?fields=space.block_storage.available" 2>/dev/null \
      | jq -r '[.records[]?.space.block_storage.available // 0] | add // 0 | floor' 2>/dev/null)
    [ -n "$AGG_FREE" ] || AGG_FREE=0

    # Used, not provisioned. Thin provisioning is the norm and the two
    # differ by an order of magnitude; quoting provisioned as if it had to
    # be moved overstates every window we would ever give them.
    SRC_USED=$(curl -sk --max-time 40 $AUTH \
      "$ONTAP_BASE/storage/volumes?fields=name,space.used&max_records=8000" 2>/dev/null \
      | jq -r '[.records[]? | select((.name // "") | test("pvc[_-]"))
               | .space.used // 0] | add // 0 | floor' 2>/dev/null)
    [ -n "$SRC_USED" ] || SRC_USED=0

    printf '   provisioned in Kubernetes (bound)   %s GiB\n' \
      "$((TP_BOUND_BYTES / 1073741824))"
    printf '   free across every aggregate         %s GiB\n' \
      "$((AGG_FREE / 1073741824))"
    if [ "$SRC_USED" -gt 0 ]; then
      # A true number that reads as a failure is a bad number. 485 empty
      # FlexVols come to ~190 MB, and printed as "0 GiB" that looks like the
      # query broke rather than like an empty estate.
      if [ "$SRC_USED" -ge 1073741824 ]; then
        printf '   actually USED on this array today   %s GiB   (volumes named *pvc*)\n' \
          "$((SRC_USED / 1073741824))"
      else
        printf '   actually USED on this array today   %s MiB   (volumes named *pvc*)\n' \
          "$((SRC_USED / 1048576))"
      fi
      echo "     Provisioned is not used. With thin provisioning the two"
      echo "     differ by an order of magnitude, and only the used bytes"
      echo "     have to move."
      # An empty estate fits anywhere. Saying "it fits" without saying that
      # is how a lab result gets quoted about production.
      if [ "$((SRC_USED * 100))" -lt "$TP_BOUND_BYTES" ]; then
        echo
        echo "   *** THE SOURCE IS ESSENTIALLY EMPTY ***"
        echo "     Under 1% of what is provisioned has been written. Any"
        echo "     answer below about whether it fits is true and proves"
        echo "     nothing: there is nothing to move yet. Expect this on a"
        echo "     lab. On a customer's estate it means the claims were"
        echo "     provisioned and never used, which is its own finding."
      fi
    else
      echo "   actually used                       NOT VISIBLE from here"
      echo "     No volume on this array looks like a Trident volume, so the"
      echo "     source is somewhere else. Ask for its USED figure before"
      echo "     promising anything: provisioned is not what has to move."
    fi
    echo
    tp_fit_verdict "$TP_BOUND_BYTES" "$AGG_FREE" "$SRC_USED"
    echo "   Snapshot reserve and SnapMirror overhead are ON TOP of this."
  else
    echo "   NOT COMPUTED — needs jq and a claim total from section E."
  fi

  echo "-- SVMs and the protocols they actually serve --"
  curl -sk --max-time 20 $AUTH "$ONTAP_BASE/svm/svms?fields=name,state,nfs.enabled,iscsi.enabled" 2>/dev/null \
    | { $HAVE_JQ && jq -r '.records[]? | "   \(.name)  \(.state)  nfs=\(.nfs.enabled // false)  iscsi=\(.iscsi.enabled // false)"' || cat; } 2>/dev/null
  echo "   nfs.enabled creates the protocol; it does NOT start the service."
  echo "-- Licences --"
  for L in snapmirror flexclone nfs iscsi; do
    printf '   %-11s ' "$L"
    curl -sk --max-time 15 $AUTH "$ONTAP_BASE/cluster/licensing/licenses?name=$L" 2>/dev/null \
      | { $HAVE_JQ && jq -r '.num_records // 0 | if . > 0 then "present" else "ABSENT" end' || cat; } 2>/dev/null
    echo
  done
  echo "-- SVM peering (for SnapMirror) --"
  curl -sk --max-time 20 $AUTH "$ONTAP_BASE/svm/peers?fields=svm.name,peer.svm.name,state" 2>/dev/null \
    | { $HAVE_JQ && jq -r '(.records // []) | if length == 0 then "   none — SnapMirror needs a peer relationship first" else .[] | "   \(.svm.name) -> \(.peer.svm.name)  \(.state)" end' || cat; } 2>/dev/null
  echo "   'peered', not 'pending'. A pending peer looks exactly like one that"
  echo "   worked until the first relationship is created."
  fi
else
  echo "   The array itself was not asked — no ONTAP credentials in the"
  echo "   environment. Everything above in this section came from the"
  echo "   cluster, and it is most of what a design needs."
  echo
  echo "   FOUR THINGS ARE GENUINELY ONLY ON THE FILER, and no amount of"
  echo "   reading Kubernetes will produce them:"
  echo "     1. FREE space per aggregate. Trident records what it created,"
  echo "        never what is left — so the provisioned totals above say"
  echo "        what has to fit and not whether it does."
  echo "     2. Whether the destination SVM NFS SERVICE is started (not"
  echo "        just the protocol enabled) and whether its export policy has"
  echo "        RULES. The default policy exists with zero rules and denies"
  echo "        everyone — a backend built against it provisions and never"
  echo "        mounts."
  echo "     3. Licences: snapmirror, and flexclone for the wave shape."
  echo "     4. Whether the SVMs are peered, and in which direction."
  echo
  echo "   Ask whoever has the array for those four, or re-run with:"
  echo "     ONTAP_MGMT_LIF=<lif> ONTAP_USER=admin ./tp-pre.sh   (asks for the password)"
  echo "   (through a tunnel: ONTAP_API_BASE=https://127.0.0.1:9443/api)"
fi

# ============================================================================
sec "G. THE APPLICATIONS, AND WHETHER THE VOLUME HOLDS THEIR DATA"

# WHY THIS SECTION EXISTS, AND WHY IT IS IN THE PRE-ASSESSMENT AND NOT IN THE
# MIGRATION.
#
# Measured on a lab cluster, 19-aug-2026. A Redis configured with
# `--save "" --appendonly no` held 5000 keys and its volume held no files at
# all. `tp auto` copied it, validated it, cut it over, called the two trees
# `identical` and exited 0: `copied 1 · validated 1 · cut over 1`. Afterwards
# `DBSIZE` was 0.
#
# Nothing in the product could have caught that. Every check we have compares
# the source with the destination, and an empty source matches an empty
# destination perfectly. The only place the question can be asked is BEFORE
# anything is planned, from outside the container, which is here.
#
# THE RULE THIS SECTION IS WRITTEN UNDER: nothing runs inside the customer's
# containers. No `exec`, no `cp`, no port-forward, no shell. So the used size
# of a volume cannot be read the way a person would read it — with `du` — and
# everything below is an attempt to answer the same question from outside:
#
#   the kubelet publishes per-claim usedBytes and inodesUsed  (a GET, but it
#     needs `get nodes/proxy`, which is an administrator's read and some
#     customers will refuse it — asked for below so the answer is on record)
#   the ARRAY knows the used size of the FlexVol behind each claim, and
#     section F already talks to it
#   and where neither is available this says CANNOT SAY, because a volume
#     nobody could measure must not be reported as a full one.
TP_BLOB_MARK="@@TP-PRE-BLOB@@"

# tp_blob <label> <command...> — run a read, wrapped in a marker line so one
# python program can be handed a dozen different documents on one stdin
# without a single temporary file on their disk. The marker starts a line of
# its own; kubectl's JSON is indented, so no value inside a document can ever
# be mistaken for one.
tp_blob() {
  printf '\n%s %s\n' "$TP_BLOB_MARK" "$1"
  shift
  "$@" 2>/dev/null || true
}

# Trident Protect spells it `exechooks`, Astra Control spelled it
# `executionhooks`, and asking for a resource the cluster does not have is an
# error rather than an empty list. So the CRDs are discovered first and only
# what exists is read. `exechooksruns` — the RESULTS of past hook runs — is
# deliberately not matched: it is history, and this is about what is defined.
TP_HOOK_RESOURCES=$($K api-resources --namespaced=true --verbs=list -o name 2>/dev/null \
                    | grep -E '^(exechooks|executionhooks)\.' | sort -u)

# The nodes worth asking the kubelet about: the ones running a pod that holds
# a claim. Asking every node in a large estate is a lot of calls for nothing.
#
# Fetched ONCE and kept, because the same document is the input to the section
# itself. Two `get pods -A` on a large estate is two large documents over the
# wire to answer one question.
TP_PODS_JSON=$($K get pods -A -o json 2>/dev/null)
TP_STAT_NODES=""
TP_STAT_NODES_ALL=0
if $HAVE_JQ; then
  TP_STAT_NODES_ALL=$(printf '%s' "$TP_PODS_JSON" | jq -r '
    .items[]?
    | select([(.spec.volumes // [])[] | select(.persistentVolumeClaim)] | length > 0)
    | .spec.nodeName // empty' 2>/dev/null | sort -u | grep -c . || true)
  TP_STAT_NODES=$(printf '%s' "$TP_PODS_JSON" | jq -r '
    .items[]?
    | select([(.spec.volumes // [])[] | select(.persistentVolumeClaim)] | length > 0)
    | .spec.nodeName // empty' 2>/dev/null | sort -u | head -60)
fi

# The array half, on the same terms as section F: only if the credentials are
# already in the environment, or asked for once in section F.
TP_ONTAP_AUTH=""
if [ -n "${ONTAP_BASE:-}" ] && [ -n "${ONTAP_PASS:-}" ]; then
  TP_ONTAP_AUTH="-u ${ONTAP_USER:-admin}:${ONTAP_PASS}"
fi
tp_ontap_volumes() {
  [ -n "$TP_ONTAP_AUTH" ] || return 0
  curl -sk --max-time 40 $TP_ONTAP_AUTH \
    "$ONTAP_BASE/storage/volumes?fields=name,space.used,space.size&max_records=8000"
}

# `2>/dev/null`, and NOT `2>&1 | head -1` the way the volumesnapshot line
# above can afford to. nodes/proxy is cluster-scoped, so kubectl prints
# "Warning: resource 'nodes' is not namespace scoped" to stderr FIRST — and
# with stderr folded in, `head -1` reports the warning as the answer. Run
# here against a live cluster, the report read
#   may read the kubelet's own volume statistics: Warning: resource ...
# which is neither yes nor no.
echo -n "   may read the kubelet's own volume statistics: "
$K auth can-i get nodes/proxy 2>/dev/null | head -1 || echo "no"
echo "   That read is what gives a used size per claim without entering any"
echo "   container. If it says no, the used sizes below come from the array or"
echo "   not at all — and 'not at all' is printed as CANNOT SAY, never as 0."
if [ "${TP_STAT_NODES_ALL:-0}" -gt 60 ] 2>/dev/null; then
  echo "   NOTE: $TP_STAT_NODES_ALL nodes hold a claim and only the first 60"
  echo "   were asked. Claims on the rest are simply unmeasured, and appear"
  echo "   below as such."
fi
if [ -n "$TP_HOOK_RESOURCES" ]; then
  echo "   execution hook resources on this cluster: $(echo "$TP_HOOK_RESOURCES" | tr '\n' ' ')"
else
  echo "   no ExecutionHook/ExecHook resource type exists here (no Trident"
  echo "   Protect, no Astra Control), so there are none to read."
fi
echo

# The whole section is one program, handed every document it needs on stdin.
# In a shell variable rather than inline so it can contain both kinds of
# quote, and so `python3 -c` gets it whole.
TP_SECTION_G=$(cat <<'TP_PY'
import calendar
import json
import re
import sys
import time

MARK = "@@TP-PRE-BLOB@@"
MIB = 1024.0 * 1024.0
GIB = MIB * 1024.0

# An application that has been serving for a day has had time to write
# something. Under that, an empty volume is a deployment that only just
# started and says nothing at all.
MIN_AGE_HOURS = 24.0
# "Nearly nothing", as an absolute floor. A freshly made filesystem is not
# empty — a 1 GiB ext4 carries tens of megabytes of its own metadata before
# anybody writes a byte — so "used == 0" alone would miss every formatted
# volume that was never written to.
NEARLY_EMPTY_BYTES = 64 * 1024 * 1024


def fail(message):
    print("   THIS SECTION COULD NOT BE COMPLETED: %s" % message)
    print("   Read it as 'not checked'. Nothing above this section depends")
    print("   on it, and nothing below it should be quoted.")


def blobs():
    """label -> [text], in the order they were produced."""
    out, label, buf = {}, None, []
    for line in sys.stdin.read().splitlines():
        if line.startswith(MARK):
            if label is not None:
                out.setdefault(label, []).append("\n".join(buf))
            label, buf = line[len(MARK):].strip(), []
        elif label is not None:
            buf.append(line)
    if label is not None:
        out.setdefault(label, []).append("\n".join(buf))
    return out


RAW = blobs()


def texts(label):
    return RAW.get(label) or []


def one(label):
    got = texts(label)
    return got[0] if got else ""


def as_json(text):
    try:
        return json.loads(text) or {}
    except Exception:
        return {}


def items(label, index=0):
    got = texts(label)
    if index >= len(got):
        return []
    got = as_json(got[index]).get("items")
    return got if isinstance(got, list) else []


def hours_since(stamp):
    """Hours since an RFC 3339 UTC timestamp, or -1 when it cannot be read.

    Through calendar.timegm and never through the local clock. Kubernetes
    always writes UTC with a Z, and the same function read through a local
    timezone is what made the estate-is-moving check an hour wrong on every
    jumphost west or east of UTC.
    """
    try:
        return (time.time()
                - calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))) / 3600.0
    except Exception:
        return -1.0


def human_age(hours):
    if hours < 0:
        return "age unknown"
    if hours < 48:
        return "up %dh" % int(hours)
    return "up %dd" % int(hours / 24)


def quantity_bytes(text):
    """A Kubernetes quantity — 200Mi, 1Gi, 500M — in bytes, or None.

    Needed to answer a question the kubelet's own numbers raise: is the
    figure it just gave us even ABOUT this claim?
    """
    match = re.match(r"^\s*([0-9.]+)\s*([A-Za-z]*)\s*$", text or "")
    if not match:
        return None
    scale = {"": 1.0, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
             "P": 1e15, "Ki": 1024.0, "Mi": 1024.0 ** 2, "Gi": 1024.0 ** 3,
             "Ti": 1024.0 ** 4, "Pi": 1024.0 ** 5}
    if match.group(2) not in scale:
        return None
    return float(match.group(1)) * scale[match.group(2)]


def human_bytes(value):
    if value is None:
        return "?"
    if value >= GIB:
        return "%.1f GiB" % (value / GIB)
    if value >= MIB:
        return "%.0f MiB" % (value / MIB)
    return "%d B" % int(value)


# ── the embedded tables, read back from the shell ───────────────────────────
ENGINES = []
for row in one("engines").splitlines():
    row = row.strip()
    if not row or row.startswith("#"):
        continue
    parts = row.split(";")
    if len(parts) < 5:
        continue
    try:
        pattern = re.compile(parts[1].strip(), re.I)
    except re.error:
        continue
    ENGINES.append({
        "name": parts[0].strip(),
        "match": pattern,
        "kinds": [k.strip() for k in parts[2].split(",") if k.strip()],
        "memory_first": parts[3].strip() == "memory-first",
        "hook": ";".join(parts[4:]).strip(),
    })

try:
    NOT_THE_ENGINE = re.compile(one("engine-not").strip() or "(?!)", re.I)
except re.error:
    NOT_THE_ENGINE = re.compile("(?!)")

ENGINE_BY_KIND = {}
for engine in ENGINES:
    for kind in engine["kinds"]:
        ENGINE_BY_KIND[kind] = engine


def engine_for_image(image):
    """Which engine this image is, or None. The exclusions are the whole
    difficulty: `postgres` is in `postgres-operator` and in
    `postgres-exporter`, and neither of them holds a byte of the database."""
    low = (image or "").lower()
    if not low or NOT_THE_ENGINE.search(low):
        return None
    for engine in ENGINES:
        if engine["match"].search(low):
            return engine
    return None


def persistence_switched_off(container):
    """(rdb_off, aof_off, said_anything) from a container's own arguments.

    ONLY the command and the arguments. Environment variable VALUES are not
    read anywhere in this script — one of them is a password often enough
    that the rule is worth more than the extra coverage — and the
    configuration file inside the image cannot be read without entering the
    container, which is the line this whole section is written not to cross.

    So this answers conclusively when the arguments say so, and stays quiet
    otherwise. It never reports the arguments themselves: a command line
    carries credentials as often as an environment variable does.
    """
    argv = list(container.get("command") or []) + list(container.get("args") or [])
    tokens = []
    for arg in argv:
        arg = "%s" % arg
        if " " in arg or "\t" in arg:
            # A shell-wrapped command: `sh -c "redis-server --save ''"`.
            tokens.extend(arg.split())
        else:
            # Appended whole, empty string included: `["--save", ""]` is the
            # exact shape of the configuration that emptied the volume, and
            # splitting it would make the empty argument disappear.
            tokens.append(arg)

    def value_after(index):
        return tokens[index + 1] if index + 1 < len(tokens) else ""

    def clean(text):
        return ("%s" % text).strip().strip('"').strip("'")

    saves, aof = [], None
    for index, token in enumerate(tokens):
        bare = clean(token)
        if bare in ("--save", "save"):
            saves.append(clean(value_after(index)))
        elif bare.startswith("--save="):
            saves.append(clean(bare.split("=", 1)[1]))
        elif bare in ("--appendonly", "appendonly"):
            aof = clean(value_after(index)).lower()
        elif bare.startswith("--appendonly="):
            aof = clean(bare.split("=", 1)[1]).lower()
    rdb_off = bool(saves) and all(value == "" for value in saves)
    return rdb_off, aof == "no", bool(saves) or aof is not None

# ── the report itself, in one function ──────────────────────────────────────
#
# One function, so that a defect in it prints a sentence rather than a
# traceback into the middle of a customer's report, and so that a reader can
# always tell "this did not run" from "there was nothing to say".
def report():

    # ── what the cluster said ───────────────────────────────────────────────────
    PODS = []
    for pod in items("pods"):
        meta = pod.get("metadata") or {}
        spec = pod.get("spec") or {}
        status = pod.get("status") or {}
        claims = []
        for volume in (spec.get("volumes") or []):
            claim = (volume.get("persistentVolumeClaim") or {}).get("claimName")
            if claim:
                claims.append(claim)
        PODS.append({
            "ns": meta.get("namespace") or "",
            "name": meta.get("name") or "",
            "node": spec.get("nodeName") or "",
            "phase": status.get("phase") or "",
            "hours": hours_since(status.get("startTime")
                                 or meta.get("creationTimestamp") or ""),
            "claims": claims,
            "containers": list(spec.get("containers") or []),
            "fsgroup": (spec.get("securityContext") or {}).get("fsGroup"),
        })

    CLAIMS = {}
    for pvc in items("pvcs"):
        meta = pvc.get("metadata") or {}
        spec = pvc.get("spec") or {}
        status = pvc.get("status") or {}
        key = (meta.get("namespace") or "", meta.get("name") or "")
        CLAIMS[key] = {
            "sc": spec.get("storageClassName") or "-",
            "mode": spec.get("volumeMode") or "Filesystem",
            "phase": status.get("phase") or "",
            "pv": spec.get("volumeName") or "",
            "bytes": quantity_bytes(
                (status.get("capacity") or {}).get("storage")
                or (((spec.get("resources") or {}).get("requests") or {})
                    .get("storage"))),
        }

    OPERATORS = []
    for line in one("operators").splitlines():
        parts = line.split("\t")
        if len(parts) >= 6 and parts[1]:
            OPERATORS.append({"ns": parts[0], "kind": parts[1], "name": parts[2],
                              "how": parts[3], "strategy": parts[4],
                              "others": parts[5]})

    # ── 1. which engines are here ───────────────────────────────────────────────
    print("-- Data engines, and what a copy of their volume does not contain --")

    engines_by_ns = {}
    for operator in OPERATORS:
        engine = ENGINE_BY_KIND.get(operator["kind"])
        if engine:
            engines_by_ns.setdefault((operator["ns"], engine["name"]), []).append(
                "%s/%s" % (operator["kind"], operator["name"]))

    rows, found_engines, memory_first_here = [], {}, []
    engine_pods_without_a_claim = []
    for pod in PODS:
        matched = None
        for container in pod["containers"]:
            matched = engine_for_image(container.get("image"))
            if matched:
                break
        if not matched:
            continue
        found_engines[matched["name"]] = matched
        crs = engines_by_ns.get((pod["ns"], matched["name"])) or []
        evidence = ("its operator: " + ", ".join(sorted(set(crs)))) if crs \
            else "the container image"
        if not pod["claims"]:
            engine_pods_without_a_claim.append(
                (pod["ns"], pod["name"], matched["name"], pod["phase"]))
        for claim in sorted(set(pod["claims"])):
            rows.append((pod["ns"], pod["name"], matched["name"], claim, evidence,
                         pod["hours"], matched))
        if matched["memory_first"] and pod["claims"]:
            # Only where it holds a claim. ArgoCD's own Redis runs with
            # `--save "" --appendonly no` on nearly every cluster and holds
            # no volume at all — a true statement about a cache, and noise in
            # a report about which volumes to move.
            memory_first_here.append((pod, matched))

    # An operator whose kind names an engine, in a namespace where no image
    # matched. It is still that engine: the custom resource is the operator
    # saying so, and an image can be renamed, mirrored or built in-house.
    for (namespace, name), crs in sorted(engines_by_ns.items()):
        if not any(row[0] == namespace and row[2] == name for row in rows):
            engine = [e for e in ENGINES if e["name"] == name][0]
            found_engines[name] = engine
            rows.append((namespace, "-", name, "-",
                         "its operator: " + ", ".join(sorted(set(crs))), -1.0,
                         engine))

    if not rows and (engine_pods_without_a_claim or engines_by_ns):
        print("   an engine runs here and NONE of them holds a claim. Every one")
        print("   of them is listed below, and storage migration moves nothing")
        print("   of theirs.")
    elif not rows:
        print("   none recognised. That is a real answer only if the engines here")
        print("   are ones we know: this matches on the container image and on the")
        print("   custom resource, so an in-house image serving an in-house")
        print("   database is invisible to it. Ask what each namespace runs.")
    else:
        for namespace, pod, name, claim, evidence, hours, _engine in sorted(rows):
            print("   %-38s %-13s %-24s %s"
                  % (namespace + "/" + pod, name, claim, evidence))
        print()
        print("   What NetApp's own published execution hook does to each of these")
        print("   BEFORE a snapshot is taken (github.com/NetApp/Verda) — which is")
        print("   the shortest statement there is of what each engine holds")
        print("   somewhere other than its volume:")
        for name in sorted(found_engines):
            print("     %s" % name)
            print("       %s" % found_engines[name]["hook"])
        print()
        print("   OUR COPY RUNS NO HOOKS. Where the application is STOPPED first")
        print("   this mostly does not matter: every engine above flushes on a")
        print("   clean shutdown. Where it cannot be stopped — see the operators")
        print("   that refuse zero, at the end of this section — the copy is taken")
        print("   from a live engine, and each line above is what would be missing")
        print("   from it.")

    if engine_pods_without_a_claim:
        print()
        print("   *** A DATA ENGINE THAT HOLDS NO CLAIM AT ALL ***")
        for namespace, pod, name, phase in sorted(engine_pods_without_a_claim):
            print("     %s/%s   %s   (%s)" % (namespace, pod, name, phase))
        print("     Its data is on an emptyDir, a hostPath, or somewhere off this")
        print("     cluster entirely. Migrating storage moves NOTHING of it, and")
        print("     if it is on the list of things to migrate, the list is wrong.")

    if memory_first_here:
        print()
        print("   *** AN ENGINE THAT KEEPS ITS DATA IN MEMORY IS RUNNING HERE ***")
        print("     Redis, Valkey and Dragonfly write to their volume only when")
        print("     persistence is configured. `--save \"\" --appendonly no` is a")
        print("     legitimate and common configuration, and under it the volume")
        print("     is EMPTY: a copy of it is faithful and worthless.")
        print("     Measured on our own lab, 19-aug-2026: 5000 keys in memory,")
        print("     0 files on the volume, and the migration reported")
        print("     copied 1 / validated 1 / cut over 1 and exited 0. Afterwards")
        print("     DBSIZE was 0. No check we have could have caught it — they all")
        print("     compare the source with the destination, and both were empty.")
        for pod, engine in sorted(memory_first_here,
                                  key=lambda item: (item[0]["ns"], item[0]["name"])):
            verdicts = [persistence_switched_off(container)
                        for container in pod["containers"]
                        if engine_for_image(container.get("image"))]
            rdb_off = any(item[0] for item in verdicts)
            aof_off = any(item[1] for item in verdicts)
            spoke = any(item[2] for item in verdicts)
            where = "%s/%s" % (pod["ns"], pod["name"])
            if rdb_off and aof_off:
                print("     %s" % where)
                print("       ITS OWN ARGUMENTS SWITCH BOTH FORMS OF PERSISTENCE")
                print("       OFF. Nothing is ever written to this volume, and")
                print("       nothing will be during the copy either. Migrating it")
                print("       moves an empty directory. THIS IS THE MEASURED CASE.")
            elif rdb_off:
                print("     %s" % where)
                print("       its arguments switch snapshotting off and say nothing")
                print("       about the append-only file. If that is off too — it is")
                print("       in a config file we do not read — the volume is empty.")
            elif spoke:
                print("     %s   persistence is configured in its arguments" % where)
            else:
                print("     %s" % where)
                print("       its arguments say nothing either way: the setting is")
                print("       in a config file inside the image, and reading that")
                print("       means entering the container. ASK, or look at the")
                print("       used size below.")

    # Operator kinds that are stateful and that no published hook covers. Naming
    # them is the honest half of the section: we know something is there and we
    # have no statement about what it keeps off the volume.
    unclassified = sorted(set(operator["kind"] for operator in OPERATORS
                              if operator["kind"] not in ENGINE_BY_KIND))
    if unclassified:
        print()
        print("   Operators here that no published hook covers: %s"
              % ", ".join(unclassified))
        print("     Not a problem and not an all-clear. It means nobody has")
        print("     published what these need before a copy, so ask their owner")
        print("     the same question: is all of the data on the volume?")

    # ── 2. the volume that holds nothing under an application that has been up ──
    print()
    print("-- Volumes with almost nothing in them under a long-lived app --")

    # From the kubelet, per claim, without entering anything: usedBytes is what
    # statfs says, and inodesUsed is the sharper of the two — a filesystem with
    # two inodes in it has a root directory and a lost+found and NO FILES.
    #
    # AND IT IS NOT ALWAYS ABOUT THE CLAIM. Measured on a live cluster here,
    # 20-aug-2026, on the csi-hostpath driver:
    #
    #   tpr-empty/data     asked 200Mi   kubelet says 115.4 GiB, 56.6 GiB used
    #   tpr-writer/data    asked 200Mi   kubelet says 115.4 GiB, 56.6 GiB used
    #   rehearsal/ledger   asked 1Gi     kubelet says 115.4 GiB, 56.6 GiB used
    #
    # — the NODE's own disk, reported identically for every claim on it,
    # including one that was empty. A volume that is a bind mount out of the
    # node's filesystem has no filesystem of its own for statfs to describe,
    # and the same is true of an ontap-nas-economy qtree, which reports the
    # FlexVol it sits inside.
    #
    # Taken at face value that number says an EMPTY volume is 56 GiB full:
    # the exact false all-clear this section exists to prevent, arriving
    # through the very measurement meant to prevent it. So a figure whose
    # capacity does not match the claim's own is DISCARDED and counted, and
    # the report says the claim could not be measured — which is true.
    USED = {}
    untrusted = []
    nodes_answered = 0
    for text in texts("nodestats"):
        document = as_json(text)
        if not document:
            continue
        nodes_answered += 1
        for pod in (document.get("pods") or []):
            for volume in (pod.get("volume") or []):
                ref = volume.get("pvcRef") or {}
                if not ref.get("name"):
                    continue
                key = (ref.get("namespace") or "", ref["name"])
                asked = (CLAIMS.get(key) or {}).get("bytes")
                reported = volume.get("capacityBytes")
                if asked and reported and reported > asked * 1.5 + 64 * MIB:
                    untrusted.append((key, reported, asked))
                    continue
                USED[key] = {"used": volume.get("usedBytes"),
                             "capacity": volume.get("capacityBytes"),
                             "inodes": volume.get("inodesUsed"),
                             "source": "the kubelet"}

    # And from the array, which knows the used size of the FlexVol behind each
    # claim. Joined through the PV name, because that is the one identifier the
    # claim and Trident's own record certainly share.
    #
    # Only for the drivers where the internalName IS the FlexVol. For the economy
    # drivers it is a qtree or a LUN inside a shared volume and the containing
    # FlexVol is recorded nowhere in Kubernetes — the same limit section F hits,
    # and the same answer: say so rather than report the whole volume's usage as
    # if it belonged to one claim.
    internal_by_pv = {}
    for volume in items("tridentvolumes"):
        config = volume.get("config") or {}
        if config.get("name") and config.get("internalName"):
            internal_by_pv[config["name"]] = config["internalName"]
    array_usage = {}
    for record in (as_json(one("ontap-volumes")).get("records") or []):
        space = record.get("space") or {}
        if record.get("name"):
            array_usage[record["name"]] = (space.get("used"), space.get("size"))
    shared_flexvol = []
    for key, claim in CLAIMS.items():
        if key in USED or not claim["pv"]:
            continue
        internal = internal_by_pv.get(claim["pv"], "")
        if not internal:
            continue
        if "/" in internal:
            shared_flexvol.append(key)
            continue
        used, size = array_usage.get(internal, (None, None))
        if used is not None:
            USED[key] = {"used": used, "capacity": size, "inodes": None,
                         "source": "the array"}


    def verdict(measure):
        """EMPTY, NEARLY EMPTY, or None. None means 'there is data in it'.

        SIXTEEN INODES, not zero and not two. A freshly formatted ext4
        reports eleven in use before anybody has written a single file —
        lost+found, the journal, the resize inode — so `inodesUsed == 0` is
        a test that a genuinely empty volume fails. Sixteen is "no files",
        and it is only ever read together with the bytes.
        """
        used = measure.get("used")
        if used is None:
            return None
        inodes = measure.get("inodes")
        capacity = measure.get("capacity") or 0
        small = used < NEARLY_EMPTY_BYTES or (capacity and used < capacity / 100.0)
        if inodes is not None and inodes <= 16 and small:
            return "EMPTY"
        if used == 0:
            return "EMPTY"
        if small:
            return "NEARLY EMPTY"
        return None


    holder_hours = {}
    for pod in PODS:
        if pod["phase"] != "Running":
            continue
        for claim in pod["claims"]:
            key = (pod["ns"], claim)
            holder_hours[key] = max(holder_hours.get(key, -1.0), pod["hours"])

    engine_claims = {}
    for namespace, pod, name, claim, _evidence, _hours, engine in rows:
        if claim != "-":
            engine_claims[(namespace, claim)] = name

    loud, quiet, block_claims = [], [], []
    for key, measure in sorted(USED.items()):
        claim = CLAIMS.get(key) or {}
        if claim.get("mode") == "Block":
            # A raw device has no filesystem to be empty. Whatever it holds is
            # copied byte for byte, and asking how much of it is used is a
            # question about the guest's filesystem, not about the volume.
            block_claims.append(key)
            continue
        call = verdict(measure)
        if not call:
            continue
        hours = holder_hours.get(key, -1.0)
        inodes = measure.get("inodes")
        line = ("%s/%s   %s of %s%s (%s)"
                % (key[0], key[1], human_bytes(measure.get("used")),
                   human_bytes(measure.get("capacity")),
                   "" if inodes is None else ", %d inodes" % inodes,
                   measure["source"]))
        if key in engine_claims and hours >= MIN_AGE_HOURS:
            loud.append((call, line, engine_claims[key], human_age(hours)))
        else:
            quiet.append((call, line, human_age(hours)))

    if not USED:
        print("   CANNOT SAY — no used size was readable for any claim.")
        if untrusted:
            print("     %d of them WERE answered for, with a figure that is not"
                  % len(untrusted))
            print("     about the claim — see below. Discarded, not reported.")
        print("     The kubelet's statistics need `get nodes/proxy`, which is an")
        print("     administrator's read, and the array was not asked or did not")
        print("     answer. This is NOT 'the volumes have data in them': it is")
        print("     'nobody measured'. Either get that read, re-run with the ONTAP")
        print("     credentials, or ask them for a `du -sh` of each volume — a")
        print("     number this script will not go and take for itself.")
    else:
        if loud:
            print("   *** A DATA ENGINE'S VOLUME IS EMPTY AND ITS POD IS NOT ***")
            for call, line, name, age in sorted(loud):
                print("     %-12s %s   %s, %s" % (call, line, name, age))
            print("     An application that has been serving for days and has")
            print("     written nothing to its volume is not keeping its data")
            print("     there. Copying it will succeed, validate, cut over and")
            print("     report a clean run, and the application will come up with")
            print("     nothing in it. Find out where the data really is BEFORE")
            print("     the window: in memory, on an emptyDir, on a hostPath, or")
            print("     on a second claim nobody mentioned.")
        elif not [key for key in engine_claims if key in USED]:
            print("   %d claim(s) were measurable and NOT ONE of them belongs to"
                  % len(USED))
            print("   a data engine. So this checked nothing about the engines:")
            print("   do not read it as an all-clear about them.")
        else:
            print("   none of the %d engine volume(s) that could be measured is"
                  % len([key for key in engine_claims if key in USED]))
            print("   empty. Checked, not skipped — and it says nothing about")
            print("   the ones that could not be measured, listed below.")
        if quiet:
            print()
            print("   Other claims with almost nothing in them (%d). Not a fault —"
                  % len(quiet))
            print("   most estates have some — but they size the destination and")
            print("   they are the cheapest waves to move first:")
            for call, line, age in sorted(quiet)[:10]:
                print("     %-12s %s   %s" % (call, line, age))
            if len(quiet) > 10:
                print("     ... and %d more" % (len(quiet) - 10))

    if untrusted:
        print()
        print("   %d claim(s) the kubelet answered about with a figure that is"
              % len(untrusted))
        print("   NOT about them, and which was therefore thrown away:")
        for key, reported, asked in sorted(untrusted)[:6]:
            print("     %s/%s   asked for %s, the kubelet describes %s"
                  % (key[0], key[1], human_bytes(asked), human_bytes(reported)))
        if len(untrusted) > 6:
            print("     ... and %d more" % (len(untrusted) - 6))
        print("     A volume that is a directory on the node — local-path,")
        print("     hostPath, csi-hostpath — has no filesystem of its own, so")
        print("     statfs describes the NODE's disk and every claim on it")
        print("     reports the same number. An ontap-nas-economy qtree does")
        print("     the same with the FlexVol it sits in. Measured here on a")
        print("     live cluster: an empty 200Mi claim reported 56.6 GiB used")
        print("     of 115.4 GiB, and so did every other claim on that node.")
        print("     Reporting that would have said a volume was full BECAUSE")
        print("     it is empty. Their used size is unknown; ask the array, or")
        print("     ask them.")

    missing = sorted(key for key in CLAIMS
                     if key not in USED and (CLAIMS[key].get("phase") == "Bound"))
    if missing:
        print()
        overlap = len([key for key, _r, _a in untrusted if key in set(missing)])
        print("   %d bound claim(s) could not be measured at all%s."
              % (len(missing),
                 "" if not overlap else ", %d of them for the reason above" % overlap))
        if shared_flexvol:
            print("     %d of them are a qtree or a LUN inside a shared FlexVol,"
                  % len(shared_flexvol))
            print("     and Kubernetes does not record which volume that is, so")
            print("     the array cannot be asked about them by name either.")
        print("     Their used size is UNKNOWN. It is not zero and it is not the")
        print("     provisioned size.")
    if block_claims:
        print()
        print("   %d raw block claim(s) are excluded from this: a device has no"
              % len(block_claims))
        print("   filesystem to be empty, and it is copied byte for byte anyway.")

    # ── 3. the hooks they already run ───────────────────────────────────────────
    print()
    print("-- Execution hooks the customer has already written --")
    hooks = []
    for text in texts("hooks"):
        for hook in (as_json(text).get("items") or []):
            meta = hook.get("metadata") or {}
            spec = hook.get("spec") or {}
            detail = []
            for field in ("action", "stage", "enabled", "applicationRef"):
                value = spec.get(field)
                if isinstance(value, (str, bool, int)):
                    detail.append("%s=%s" % (field, value))
            hooks.append((meta.get("namespace") or "-", meta.get("name") or "-",
                          hook.get("kind") or "?", " ".join(detail)))
    if hooks:
        print("   *** THEY ALREADY RUN EXECUTION HOOKS ***")
        for namespace, name, kind, detail in sorted(hooks):
            print("     %-18s %-26s %s  %s" % (namespace, name, kind, detail))
        print("     Somebody has already decided that these applications cannot")
        print("     be snapshotted safely without being quiesced first. That")
        print("     decision was made about THEIR data by somebody who knows it.")
        print("     Our copy runs none of these. Read the scripts before the")
        print("     window — they say exactly what each application needs — and")
        print("     for anything that cannot be stopped, that reading IS the")
        print("     migration plan for it.")
    elif texts("hooks"):
        print("   none defined, and the resource type exists here — so this was")
        print("   asked and answered, not skipped.")
    else:
        print("   not applicable: no ExecutionHook resource type on this cluster.")
        print("   Ask anyway whether they quiesce anything before their backups.")
        print("   A hook they run outside Kubernetes is the same finding.")

    # ── 4. fsGroup, and ONLY where this migration would change it ───────────────
    #
    # `fsGroupPolicy` is collected in section B against every driver and crossed
    # with nothing, which is how a field that matters twice gets read as if it
    # mattered always. It only matters if the migration CHANGES the group that
    # ends up on the files, and that is two situations and no others:
    #
    #   1. the destination claim is used from a DIFFERENT NAMESPACE on OpenShift,
    #      where the GID is allocated per namespace, so the same pod definition
    #      gets a different fsGroup on the other side; and
    #   2. the source driver and the destination driver declare a DIFFERENT
    #      fsGroupPolicy, so one of them re-owns the files on mount and the other
    #      leaves whatever the copy wrote.
    #
    # Migrating a namespace to itself, between two drivers that agree, nothing
    # happens — and saying it anyway is how a report teaches people to skim.
    print()
    print("-- fsGroup: only where this migration would change it --")

    policies = {}
    for driver in items("csidrivers"):
        name = (driver.get("metadata") or {}).get("name") or ""
        if name:
            policies[name] = (driver.get("spec") or {}).get("fsGroupPolicy") \
                or "unset (ReadWriteOnceWithFSType)"
    provisioners = {}
    for storageclass in items("storageclasses"):
        name = (storageclass.get("metadata") or {}).get("name") or ""
        if name:
            provisioners[name] = storageclass.get("provisioner") or ""

    DEST_DRIVER = "csi.trident.netapp.io"
    said_something = False
    in_use = sorted(set(claim["sc"] for claim in CLAIMS.values()
                        if claim.get("phase") == "Bound" and claim.get("sc")))
    if DEST_DRIVER in policies:
        destination = policies[DEST_DRIVER]
        for storageclass in in_use:
            provisioner = provisioners.get(storageclass, "")
            source = policies.get(provisioner)
            if not provisioner or source is None or source == destination:
                continue
            said_something = True
            print("   %s (%s) declares fsGroupPolicy %s and Trident declares %s."
                  % (storageclass, provisioner, source, destination))
            if source.startswith("None") or destination.startswith("None"):
                print("     One of the two does NOT let the kubelet set group")
                print("     ownership on mount. Whatever the copy wrote is final on")
                print("     that side, and the application arrives at files owned")
                print("     by a group it may not be in — it starts, and then")
                print("     cannot read its own data.")
            else:
                print("     The two sides re-own the files under different rules.")
                print("     Check one migrated claim's ownership before the wave,")
                print("     not after it.")
    else:
        print("   Trident's own CSIDriver is not on this cluster, so the")
        print("   destination's fsGroupPolicy cannot be read yet. Compare it with")
        print("   the source drivers in section B once the backend exists.")
        said_something = True

    # OpenShift allocates the GID range per namespace, and a pod that does not
    # pin its own fsGroup is given one out of that range at admission. Moving the
    # application to a claim used from another project therefore changes the
    # group on its files. A pod that DOES pin one keeps it, so this stays quiet
    # for those — which is most charts.
    ranges = {}
    for namespace in items("namespaces"):
        meta = namespace.get("metadata") or {}
        annotations = meta.get("annotations") or {}
        text = annotations.get("openshift.io/sa.scc.supplemental-groups") \
            or annotations.get("openshift.io/sa.scc.uid-range") or ""
        match = re.match(r"^(\d+)[/-](\d+)$", text.split(",")[0].strip())
        if match:
            start, span = int(match.group(1)), int(match.group(2))
            ranges[meta.get("name") or ""] = (start, start + span)

    namespace_derived = []
    for pod in PODS:
        if not pod["claims"] or pod["fsgroup"] is None:
            continue
        window = ranges.get(pod["ns"])
        if not window:
            continue
        if window[0] <= int(pod["fsgroup"]) < window[1]:
            namespace_derived.append((pod["ns"], pod["name"], pod["fsgroup"]))
    if namespace_derived:
        said_something = True
        print("   These pods run with an fsGroup out of their OWN namespace's")
        print("   allocated range, so the group on their files belongs to the")
        print("   namespace and not to the application:")
        for namespace, pod, group in sorted(namespace_derived)[:10]:
            print("     %s/%s   fsGroup=%s" % (namespace, pod, group))
        if len(namespace_derived) > 10:
            print("     ... and %d more" % (len(namespace_derived) - 10))
        print("     IF the destination claim is consumed from a DIFFERENT project,")
        print("     the pod there is allocated a different GID and arrives at")
        print("     files owned by this one. Into the same namespace, nothing")
        print("     changes and there is nothing to do.")
    if not said_something:
        print("   nothing to say: every source driver agrees with Trident's")
        print("   fsGroupPolicy, and no pod holding a claim takes its group from")
        print("   its namespace. Migrating into the same namespace, ownership is")
        print("   unaffected.")

    # ── 5. where the copy would be hot ──────────────────────────────────────────
    print()
    print("-- WHERE THE COPY WOULD BE HOT --")
    hot = [operator for operator in OPERATORS
           if operator["strategy"] in ("hold-operator", "needs-agreement")]
    if not OPERATORS:
        print("   no operator owns anything that holds a claim, so every")
        print("   application here stops with a scale to zero and every copy is")
        print("   taken cold. This is the best case and it is common.")
    elif not hot:
        print("   none — every operator found takes its own application down when")
        print("   its custom resource is patched to zero, so every copy can be")
        print("   taken with the engine stopped.")
    else:
        print("   These applications CANNOT be stopped through their own custom")
        print("   resource. Until the controller is held down and the workload")
        print("   scaled underneath it, a copy of their volume is a copy of a")
        print("   running database:")
        for operator in sorted(hot, key=lambda item: (item["ns"], item["kind"])):
            engine = ENGINE_BY_KIND.get(operator["kind"])
            note = engine["name"] if engine else "no published hook"
            extra = ""
            if operator["strategy"] == "needs-agreement":
                extra = "  (+%s other namespace(s) — somebody has to agree)" \
                    % operator["others"]
            print("     %-14s %s/%s   %s%s"
                  % (operator["ns"], operator["kind"], operator["name"], note, extra))
        print("   Everything this section says about flushing, about hooks and")
        print("   about engines that keep their data in memory applies to exactly")
        print("   these namespaces, and to no others.")


try:
    report()
except Exception as _exc:
    fail("%s: %s" % (type(_exc).__name__, _exc))
TP_PY
)

# Everything the program needs, on one stdin, in one pass. Written to no
# file: the two the report promises are the only two, and a section that
# needed a scratch directory on their machine would make that sentence false.
{
  tp_blob engines        printf '%s' "$TP_DATA_ENGINES"
  tp_blob engine-not     printf '%s' "$TP_NOT_THE_ENGINE"
  tp_blob operators      printf '%s' "${TP_OPERATORS_TSV:-}"
  tp_blob pods           printf '%s' "$TP_PODS_JSON"
  tp_blob pvcs           $K get pvc -A -o json
  tp_blob namespaces     $K get ns -o json
  tp_blob storageclasses $K get sc -o json
  tp_blob csidrivers     $K get csidrivers -o json
  tp_blob tridentvolumes $K get tridentvolumes -n trident -o json
  for TP_R in $TP_HOOK_RESOURCES; do
    tp_blob hooks        $K get "$TP_R" -A -o json
  done
  # A GET, and nothing else: the kubelet's own statistics summary, which
  # carries usedBytes and inodesUsed for every claim mounted on that node.
  # This is the only way to size a volume from outside the container, and it
  # is why `auth can-i get nodes/proxy` is printed above.
  for TP_N in $TP_STAT_NODES; do
    tp_blob nodestats    $K get --raw "/api/v1/nodes/$TP_N/proxy/stats/summary"
  done
  tp_blob ontap-volumes  tp_ontap_volumes
} | python3 -c "$TP_SECTION_G" || echo "   (no python3 here — section G skipped)"

# ============================================================================
# ── G2. THE MACHINE-READABLE INVENTORY ───────────────────────────────────────
#
# One batch read per resource type (`get <type> -A -o json`, once), each with a
# time limit, and every section records where it came from and, when it could
# not be read, `unknown: forbidden (list pods)` or the like. The process may
# send get / auth can-i / version only, plus a bounded `find` through exec when
# --count-files is given. It never writes to the cluster.
#
# Needs python3, which sections C and F already use. It does not need jq.
tp_inventory() {
  TP_K="$K" TP_CTX="$CTX" TP_INV_JSON="$INV_JSON" TP_INV_MD="$INV_MD" \
  TP_NS_FILTER="$NS_FILTER" TP_COUNT_FILES="$TP_COUNT_FILES" TP_READ_TIMEOUT="$TP_READ_TIMEOUT" \
  TP_COUNT_TIMEOUT="${TP_COUNT_TIMEOUT:-60}" TP_COUNT_CAP="${TP_COUNT_CAP:-2000000}" \
  TP_COUNT_MAX_PVCS="${TP_COUNT_MAX_PVCS:-200}" \
  TP_DATA_ENGINES="$TP_DATA_ENGINES" TP_NOT_THE_ENGINE="$TP_NOT_THE_ENGINE" \
  TP_REGISTRY_CRDS="$TP_REGISTRY_CRDS" TP_REFUSES_ZERO="$TP_REFUSES_ZERO" \
  python3 - <<'TP_INV_PY'
import collections
import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import sys
import time

# ── tp-pre inventory: the machine-readable half of tp-pre.sh ────────────────
# Read-only. The only verbs this process may send are get, auth (can-i) and
# version; exec only with --count-files, and only a bounded `find`.
K = os.environ.get("TP_K", "kubectl")
OUT_JSON = os.environ["TP_INV_JSON"]
OUT_MD = os.environ["TP_INV_MD"]
CTX = os.environ.get("TP_CTX", "")
READ_TIMEOUT = int(os.environ.get("TP_READ_TIMEOUT", "300") or 300)
NS_FILTER = [n for n in os.environ.get("TP_NS_FILTER", "").replace(",", " ").split() if n]
COUNT_FILES = os.environ.get("TP_COUNT_FILES", "false") == "true"
COUNT_TIMEOUT = int(os.environ.get("TP_COUNT_TIMEOUT", "60") or 60)
COUNT_CAP = int(os.environ.get("TP_COUNT_CAP", "2000000") or 2000000)
COUNT_MAX = int(os.environ.get("TP_COUNT_MAX_PVCS", "200") or 200)
DATA_ENGINES = os.environ.get("TP_DATA_ENGINES", "")
NOT_ENGINE = os.environ.get("TP_NOT_THE_ENGINE", "exporter|operator")
REGISTRY_CRDS = os.environ.get("TP_REGISTRY_CRDS", "")
REFUSES_ZERO = set((os.environ.get("TP_REFUSES_ZERO", "")).split("|"))
IS_TTY = False

ACCESS = {"ReadWriteOnce": "RWO", "ReadWriteMany": "RWX", "ReadOnlyMany": "ROX", "ReadWriteOncePod": "RWOP"}
TIB = 1024 ** 4
GIB = 1024 ** 3
BIG_PVC_BYTES = TIB
MANY_FILES = 1000000
WARN_PCT, OVER_PCT = 70, 80

READ_VERBS = ("get", "auth", "version")


def say(msg):
    print(msg, flush=True)


class Forbidden(Exception):
    pass


def kc(args, timeout):
    """The ONLY door to the cluster. A verb that writes does not get through."""
    verb = args[0]
    if verb == "exec":
        ok = (COUNT_FILES and len(args) > 8 and args[-3:-1] == ["sh", "-c"]
              and args[-1].startswith("find "))
        if not ok:
            raise Forbidden("exec is only for the bounded find of --count-files")
    elif verb not in READ_VERBS:
        raise Forbidden("this collector is read-only; refused: %s" % verb)
    try:
        p = subprocess.run([K] + args, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except OSError as exc:
        return 127, "", str(exc)
    return p.returncode, p.stdout, p.stderr


SECTIONS = collections.OrderedDict()


def sec(name, origin, status, reason=""):
    SECTIONS[name] = {"origin": origin, "status": status}
    if reason:
        SECTIONS[name]["reason"] = reason


def explain(err, what, timeout):
    low = (err or "").lower()
    if err == "timeout":
        return "unknown: timeout after %ss (%s)" % (timeout, what)
    if "forbidden" in low:
        return "unknown: forbidden (%s)" % what
    if "unauthorized" in low:
        return "unknown: unauthorized (%s)" % what
    first = (err or "").strip().splitlines()[:1]
    return "unknown: error (%s): %s" % (what, first[0][:160] if first else "no message")


def is_absent(err):
    low = (err or "").lower()
    return ("doesn't have a resource type" in low
            or "the server could not find the requested resource" in low
            or "no matches for kind" in low)


class Res:
    def __init__(self, status, items=None, reason="", text=""):
        self.status = status          # ok | absent | unknown
        self.items = items or []
        self.reason = reason
        self.text = text

    @property
    def ok(self):
        return self.status == "ok"

    def say(self, absent_text):
        if self.status == "absent":
            return absent_text
        return self.reason


_STEP = [0, 0]


def progress(what):
    _STEP[0] += 1
    say("   [%2d] %s" % (_STEP[0], what))


def parse_items(out):
    data = json.loads(out)
    if isinstance(data, dict) and isinstance(data.get("items"), list):
        return data["items"]
    if isinstance(data, dict) and data.get("kind"):
        return [data]
    raise ValueError("not a list")


def kget(name, resource, cluster=False, ns=None, jsonpath=None, label=None):
    """One batch read: `get <resource> -A -o json`, once per type."""
    args = ["get", resource]
    if ns:
        args += ["-n", ns]
    elif not cluster:
        args += ["-A"]
    args += ["-o", jsonpath if jsonpath else "json"]
    what = "list %s" % resource if not ns else "get %s" % resource
    origin = "%s %s" % (K, " ".join(args))
    progress(label or origin)
    rc, out, err = kc(args, READ_TIMEOUT)
    if rc != 0:
        if is_absent(err):
            sec(name, origin, "absent", "not installed (the API has no such resource type)")
            return Res("absent", reason="not installed")
        if "forbidden" in (err or "").lower() and NS_FILTER and not cluster and not ns:
            return kget_by_namespace(name, resource, jsonpath, origin)
        reason = explain(err, what, READ_TIMEOUT)
        sec(name, origin, "unknown", reason)
        return Res("unknown", reason=reason)
    if jsonpath:
        sec(name, origin, "ok")
        return Res("ok", text=out)
    try:
        items = parse_items(out)
    except ValueError:
        reason = "unknown: unparseable output (%s)" % what
        sec(name, origin, "unknown", reason)
        return Res("unknown", reason=reason)
    sec(name, origin, "ok")
    return Res("ok", items)


def kget_by_namespace(name, resource, jsonpath, origin):
    items, text, bad = [], "", []
    for ns in NS_FILTER:
        args = ["get", resource, "-n", ns, "-o", jsonpath if jsonpath else "json"]
        rc, out, err = kc(args, READ_TIMEOUT)
        if rc != 0:
            bad.append(explain(err, "list %s -n %s" % (resource, ns), READ_TIMEOUT))
            continue
        if jsonpath:
            text += out
        else:
            try:
                items += parse_items(out)
            except ValueError:
                bad.append("unknown: unparseable output (list %s -n %s)" % (resource, ns))
    if bad and not items and not text:
        sec(name, origin + " (per namespace)", "unknown", bad[0])
        return Res("unknown", reason=bad[0])
    sec(name, origin + " (per namespace: -A was forbidden)", "ok",
        "partial: " + bad[0] if bad else "")
    return Res("ok", items, text=text)


def kraw(name, path, what):
    args = ["get", "--raw", path]
    origin = "%s get --raw %s" % (K, path)
    progress(origin)
    rc, out, err = kc(args, READ_TIMEOUT)
    if rc != 0:
        if is_absent(err) or "not found" in (err or "").lower():
            sec(name, origin, "absent", "not installed")
            return Res("absent", reason="not installed")
        reason = explain(err, what, READ_TIMEOUT)
        sec(name, origin, "unknown", reason)
        return Res("unknown", reason=reason)
    try:
        data = json.loads(out)
    except ValueError:
        reason = "unknown: unparseable output (%s)" % what
        sec(name, origin, "unknown", reason)
        return Res("unknown", reason=reason)
    sec(name, origin, "ok")
    return Res("ok", [data])


# ── small parsers ───────────────────────────────────────────────────────────
_Q = re.compile(r"^([0-9]*\.?[0-9]+)(?:[eE]([+-]?[0-9]+))?([A-Za-z]*)$")
_U = {"": 1, "k": 10 ** 3, "K": 10 ** 3, "M": 10 ** 6, "G": 10 ** 9, "T": 10 ** 12,
      "P": 10 ** 15, "E": 10 ** 18, "Ki": 1024, "Mi": 1024 ** 2, "Gi": 1024 ** 3,
      "Ti": 1024 ** 4, "Pi": 1024 ** 5, "Ei": 1024 ** 6, "m": 0.001}


def qty(value):
    """A Kubernetes quantity as a number, or None when it is not one."""
    if value is None:
        return None
    m = _Q.match(str(value).strip())
    if not m or m.group(3) not in _U:
        return None
    num = float(m.group(1))
    if m.group(2):
        num *= 10 ** int(m.group(2))
    return num * _U[m.group(3)]


def cpu_m(value):
    n = qty(value)
    return None if n is None else int(round(n * 1000))


def human(nbytes):
    if not isinstance(nbytes, (int, float)):
        return str(nbytes)
    for unit, size in (("TiB", TIB), ("GiB", GIB), ("MiB", 1024 ** 2)):
        if nbytes >= size:
            return "%.1f %s" % (nbytes / size, unit)
    return "%d B" % nbytes


def meta(o):
    return o.get("metadata") or {}


def labels(o):
    return meta(o).get("labels") or {}


def annos(o):
    return meta(o).get("annotations") or {}


def key(o):
    return (meta(o).get("namespace") or "", meta(o).get("name") or "")


def redact_url(url):
    """Repository URLs may carry credentials in the userinfo. Never keep them."""
    if not isinstance(url, str):
        return url
    m = re.match(r"^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/@\s]*)@", url)
    if m and m.group(1).lower() in ("ssh://", "git+ssh://") and ":" not in m.group(2):
        return url      # ssh://<login>@host is a login name, not a secret
    return re.sub(r"^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s]*@", r"\1", url)


def group_of(api_version):
    api_version = api_version or ""
    return api_version.split("/")[0] if "/" in api_version else ""


# ── 0. identity, version, permissions ───────────────────────────────────────
inv = collections.OrderedDict()
inv["schema"] = "tp-pre-inventory/1"
inv["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
inv["context"] = CTX
inv["client"] = K
inv["namespace_filter"] = NS_FILTER or "all"
inv["count_files"] = COUNT_FILES

say("-- Full inventory (machine-readable), read-only --")

# kube-system UID: the licence fingerprint
progress("%s get namespace kube-system" % K)
rc, out, err = kc(["get", "namespace", "kube-system", "-o", "json"], 60)
ksuid = None
if rc == 0:
    try:
        ksuid = meta(json.loads(out)).get("uid")
    except ValueError:
        ksuid = None
    if ksuid:
        sec("kube_system", "%s get namespace kube-system -o json" % K, "ok")
    else:
        sec("kube_system", "%s get namespace kube-system" % K, "unknown",
            "unknown: unparseable output (get namespaces/kube-system)")
else:
    sec("kube_system", "%s get namespace kube-system -o json" % K, "unknown",
        explain(err, "get namespaces/kube-system", 60))
inv["license"] = {
    "kube_system_uid": ksuid or SECTIONS["kube_system"].get("reason"),
    "origin": SECTIONS["kube_system"]["origin"],
    "note": "the licence fingerprint; issue the licence for this value before arriving",
}

progress("%s version -o json" % K)
rc, out, err = kc(["version", "-o", "json"], 60)
k8s_version = None
if rc == 0:
    try:
        k8s_version = (json.loads(out).get("serverVersion") or {}).get("gitVersion")
    except ValueError:
        k8s_version = None
if not k8s_version:
    r = kraw("k8s_version", "/version", "get /version")
    if r.ok:
        k8s_version = r.items[0].get("gitVersion")
if k8s_version:
    sec("k8s_version", "%s version -o json" % K, "ok")
else:
    sec("k8s_version", "%s version -o json" % K, "unknown", "unknown: server version not returned")


def can_i(verb, resource, all_ns):
    args = ["auth", "can-i", verb, resource] + (["-A"] if all_ns else [])
    rc, out, err = kc(args, 60)
    ans = (out or "").strip().splitlines()[:1]
    ans = ans[0] if ans else ""
    if ans in ("yes", "no"):
        return ans
    return "unknown: %s" % ((err or ans or "no answer").strip().splitlines() or ["no answer"])[0][:100]


PERMS = [
    ("get namespaces/kube-system (licence fingerprint)", "get", "namespaces/kube-system", "none"),
    ("list persistentvolumeclaims -A", "list", "persistentvolumeclaims", None),
    ("list pods -A", "list", "pods", None),
    ("list persistentvolumes", "list", "persistentvolumes", "none"),
    ("list storageclasses", "list", "storageclasses.storage.k8s.io", "none"),
    ("list volumesnapshotclasses", "list", "volumesnapshotclasses.snapshot.storage.k8s.io", "none"),
    ("list customresourcedefinitions", "list", "customresourcedefinitions.apiextensions.k8s.io", "none"),
    ("list nodes", "list", "nodes", "none"),
    ("get nodes/proxy (used bytes, inodes, node disk)", "get", "nodes/proxy", "none"),
    ("list nodes.metrics.k8s.io (metrics API)", "list", "nodes.metrics.k8s.io", "none"),
    ("list statefulsets -A", "list", "statefulsets.apps", None),
    ("list applications.argoproj.io -A", "list", "applications.argoproj.io", None),
    ("create pods/exec (only for --count-files)", "create", "pods/exec", None),
]
perms = []
for label, verb, res, scope in PERMS:
    progress("%s auth can-i %s %s" % (K, verb, res))
    ans = can_i(verb, res, scope is None)
    perms.append({"check": label, "answer": ans,
                  "origin": "%s auth can-i %s %s" % (K, verb, res)})
inv["permissions"] = perms

# ── 1. the batch reads, once per type ───────────────────────────────────────
R = {}
R["pvc"] = kget("pvc", "persistentvolumeclaims")
R["pv"] = kget("pv", "persistentvolumes", cluster=True)
R["sc"] = kget("storageclasses", "storageclasses.storage.k8s.io", cluster=True)
R["pods"] = kget("pods", "pods")
R["deploy"] = kget("deployments", "deployments.apps")
R["sts"] = kget("statefulsets", "statefulsets.apps")
R["ds"] = kget("daemonsets", "daemonsets.apps")
R["rs"] = kget("replicasets", "replicasets.apps")
R["job"] = kget("jobs", "jobs.batch")
R["cronjob"] = kget("cronjobs", "cronjobs.batch")
R["nodes"] = kget("nodes", "nodes", cluster=True)
R["vsc"] = kget("volumesnapshotclasses", "volumesnapshotclasses.snapshot.storage.k8s.io", cluster=True)
R["csidriver"] = kget("csidrivers", "csidrivers.storage.k8s.io", cluster=True)
R["crd"] = kget("crds", "customresourcedefinitions.apiextensions.k8s.io", cluster=True,
                jsonpath='jsonpath={range .items[*]}{.metadata.name}{"\\t"}{.spec.group}{"\\t"}{.spec.names.kind}{"\\t"}{.spec.versions[*].name}{"\\t"}{.metadata.labels.app\\.kubernetes\\.io/version}{"\\n"}{end}',
                label="get customresourcedefinitions (names only)")
R["csv"] = kget("olm_csv", "clusterserviceversions.operators.coreos.com",
                jsonpath='jsonpath={range .items[*]}{.metadata.namespace}{"\\t"}{.metadata.name}{"\\t"}{.spec.version}{"\\t"}{.status.phase}{"\\t"}{.status.reason}{"\\t"}{.spec.customresourcedefinitions.owned[*].kind}{"\\n"}{end}',
                label="get clusterserviceversions (names and versions only)")
R["namespaces"] = kget("namespaces", "namespaces", cluster=True)
R["services"] = kget("services", "services")
R["ingress"] = kget("ingresses", "ingresses.networking.k8s.io")
R["routes"] = kget("routes", "routes.route.openshift.io")
R["apps"] = kget("argo_applications", "applications.argoproj.io")
R["appsets"] = kget("argo_applicationsets", "applicationsets.argoproj.io")
R["argocd_cr"] = kget("argo_argocd_cr", "argocds.argoproj.io")
R["fx_ks"] = kget("flux_kustomizations", "kustomizations.kustomize.toolkit.fluxcd.io")
R["fx_hr"] = kget("flux_helmreleases", "helmreleases.helm.toolkit.fluxcd.io")
R["fx_git"] = kget("flux_gitrepositories", "gitrepositories.source.toolkit.fluxcd.io")
R["tbc"] = kget("trident_tbc", "tridentbackendconfigs.trident.netapp.io")
R["tbe"] = kget("trident_backends", "tridentbackends.trident.netapp.io")
R["tver"] = kget("trident_versions", "tridentversions.trident.netapp.io")
R["scc"] = kget("openshift_scc", "securitycontextconstraints.security.openshift.io", cluster=True)
R["cv"] = kget("openshift_clusterversion", "clusterversions.config.openshift.io", cluster=True)
R["proxy"] = kget("openshift_proxy", "proxies.config.openshift.io", cluster=True)
R["imgcfg"] = kget("openshift_image_config", "images.config.openshift.io", cluster=True)
R["idms"] = kget("openshift_image_mirrors", "imagedigestmirrorsets.config.openshift.io", cluster=True)
R["icsp"] = kget("openshift_icsp", "imagecontentsourcepolicies.operator.openshift.io", cluster=True)
R["metrics"] = kraw("metrics_api", "/apis/metrics.k8s.io/v1beta1/nodes", "get nodes.metrics.k8s.io")
R["secapi"] = kraw("openshift_security_api", "/apis/security.openshift.io/v1", "get security.openshift.io/v1")


def L(name):
    return R[name].items if R[name].ok else []


# ── 2. who holds what: pods, workloads, owners ──────────────────────────────
OBJ = {}
for kind, rname in (("Deployment", "deploy"), ("StatefulSet", "sts"), ("DaemonSet", "ds"),
                    ("ReplicaSet", "rs"), ("Job", "job"), ("CronJob", "cronjob")):
    for o in L(rname):
        OBJ[(kind,) + key(o)] = o

CORE_GROUPS = ("", "apps", "batch", "apps.openshift.io")
WORKLOAD_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "DeploymentConfig",
                  "VirtualMachineInstance", "VirtualMachine")


def owner_of(o):
    refs = meta(o).get("ownerReferences") or []
    for r in refs:
        if r.get("controller"):
            return r
    return refs[0] if refs else None


def chain_of(o):
    """pod -> ReplicaSet -> Deployment -> custom resource, as far as it is readable."""
    out, seen, ns = [], set(), meta(o).get("namespace") or ""
    cur = o
    for _ in range(6):
        ref = owner_of(cur)
        if not ref:
            break
        k = (ref.get("kind"), ns, ref.get("name"))
        out.append({"kind": ref.get("kind"), "name": ref.get("name"),
                    "group": group_of(ref.get("apiVersion"))})
        if k in seen or k not in OBJ:
            break
        seen.add(k)
        cur = OBJ[k]
    return out, cur


TRACK = re.compile(r"^(?:(?P<appns>[^_:]+)_)?(?P<app>[^:]+):")


def gitops_of(*objs):
    """Who reconciles this object: Argo CD, Flux, Helm, an operator, or nobody."""
    for o in objs:
        if not o:
            continue
        a, lab = annos(o), labels(o)
        tid = a.get("argocd.argoproj.io/tracking-id")
        if tid:
            m = TRACK.match(tid)
            return {"manager": "argocd", "app": m.group("app") if m else tid,
                    "app_namespace": (m.group("appns") if m else None), "via": "tracking-id annotation"}
        if lab.get("argocd.argoproj.io/instance"):
            return {"manager": "argocd", "app": lab["argocd.argoproj.io/instance"], "via": "instance label"}
        for ctl, ks in (("flux-kustomization", "kustomize.toolkit.fluxcd.io/name"),
                        ("flux-helmrelease", "helm.toolkit.fluxcd.io/name")):
            if lab.get(ks):
                return {"manager": ctl, "app": lab[ks],
                        "app_namespace": lab.get(ks.replace("/name", "/namespace")), "via": "flux label"}
    for o in objs:
        if not o:
            continue
        a, lab = annos(o), labels(o)
        if a.get("meta.helm.sh/release-name") or lab.get("app.kubernetes.io/managed-by") == "Helm":
            return {"manager": "helm", "app": a.get("meta.helm.sh/release-name", "unknown"),
                    "via": "helm annotation"}
    # app.kubernetes.io/instance alone is a weak sign: only a hint, and only if Argo exists
    for o in objs:
        if o and labels(o).get("app.kubernetes.io/instance") and R["apps"].ok and R["apps"].items:
            return {"manager": "argocd?", "app": labels(o)["app.kubernetes.io/instance"],
                    "via": "app.kubernetes.io/instance label (weak: Argo CD default tracking)"}
    return {"manager": "nobody", "via": "no tracking annotation or label found"}


# engines
ENGINES = []
for line in DATA_ENGINES.strip().splitlines():
    parts = line.split(";")
    if len(parts) >= 5:
        ENGINES.append({"name": parts[0], "image": parts[1], "kinds": [k for k in parts[2].split(",") if k],
                        "memory_first": parts[3] == "memory-first"})
WRITE_HEAVY = re.compile(r"prometheus|thanos|loki|tempo|mimir|victoria|influx|timescale|clickhouse|"
                         r"kafka|pulsar|rabbitmq|minio|seaweed|ceph|cassandra|scylla|elasticsearch|opensearch|"
                         r"mongo|postgres|mysql|mariadb|redis|valkey|etcd|cockroach|couchbase|zookeeper|solr|milvus|tidb|virt-launcher|kubevirt", re.I)


def engine_of(images, kinds):
    for img in images:
        if re.search(NOT_ENGINE, img, re.I):
            continue
        for e in ENGINES:
            if re.search(e["image"], img, re.I):
                return e["name"], "image %s" % img.split("/")[-1][:60]
    for e in ENGINES:
        if any(k in e["kinds"] for k in kinds):
            return e["name"], "custom resource kind %s" % next(k for k in kinds if k in e["kinds"])
    return None, None


def pod_images(p):
    spec = p.get("spec") or {}
    return [c.get("image") or "" for c in (spec.get("containers") or []) + (spec.get("initContainers") or [])]


pod_claims = {}   # (ns, pvc) -> [pod]
pod_info = {}
for p in L("pods"):
    ns, name = key(p)
    phase = (p.get("status") or {}).get("phase")
    ch, last = chain_of(p)
    pod_info[(ns, name)] = {"chain": ch, "last": last}
    if phase in ("Succeeded", "Failed"):
        continue
    for v in (p.get("spec") or {}).get("volumes") or []:
        c = (v.get("persistentVolumeClaim") or {}).get("claimName")
        if c:
            pod_claims.setdefault((ns, c), []).append(p)

# StatefulSets: template names -> unmounted claims still belong to them
sts_by_ns = collections.defaultdict(list)
for s in L("sts"):
    sts_by_ns[meta(s).get("namespace")].append(s)


def sts_for_claim(ns, claim):
    for s in sts_by_ns.get(ns, []):
        for t in (s.get("spec") or {}).get("volumeClaimTemplates") or []:
            if re.match(r"^%s-%s-[0-9]+$" % (re.escape(meta(t).get("name", "\0")), re.escape(meta(s).get("name", "\0"))), claim):
                return s
    return None


# ── 3. node statistics: used bytes, inodes, node disk ───────────────────────
def node_stats(node):
    args = ["get", "--raw", "/api/v1/nodes/%s/proxy/stats/summary" % node]
    rc, out, err = kc(args, 90)
    if rc != 0:
        return node, None, explain(err, "get nodes/proxy", 90)
    try:
        return node, json.loads(out), None
    except ValueError:
        return node, None, "unknown: unparseable output (get nodes/proxy)"


node_names = [meta(n).get("name") for n in L("nodes")]
STATS, STATS_ERR = {}, {}
used_by_claim = {}
progress("%s get --raw /api/v1/nodes/<node>/proxy/stats/summary  (%d nodes)" % (K, len(node_names)))
if node_names:
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for node, data, err in pool.map(node_stats, node_names):
            if data is None:
                STATS_ERR[node] = err
                continue
            STATS[node] = data
            for pod in data.get("pods") or []:
                for vol in pod.get("volume") or []:
                    ref = vol.get("pvcRef")
                    if ref:
                        used_by_claim[(ref.get("namespace"), ref.get("name"))] = {
                            "used": vol.get("usedBytes"), "capacity": vol.get("capacityBytes"),
                            "inodes_used": vol.get("inodesUsed"), "inodes": vol.get("inodes"), "node": node}
if not node_names:
    stats_reason = R["nodes"].reason if not R["nodes"].ok else "unknown: no nodes listed"
    sec("node_stats", "%s get --raw /api/v1/nodes/<node>/proxy/stats/summary" % K, "unknown", stats_reason)
elif STATS and len(STATS) == len(node_names):
    sec("node_stats", "%s get --raw /api/v1/nodes/<node>/proxy/stats/summary" % K, "ok")
elif STATS:
    sec("node_stats", "%s get --raw /api/v1/nodes/<node>/proxy/stats/summary" % K, "ok",
        "partial: %d of %d nodes answered; first error: %s" % (len(STATS), len(node_names), next(iter(STATS_ERR.values()))))
else:
    sec("node_stats", "%s get --raw /api/v1/nodes/<node>/proxy/stats/summary" % K, "unknown",
        next(iter(STATS_ERR.values()), "unknown: no node answered"))
STATS_WHY = SECTIONS["node_stats"].get("reason") if SECTIONS["node_stats"]["status"] == "unknown" else None

# ── 4. persistent volumes, storage classes, SMB ─────────────────────────────
PV = {meta(p).get("name"): p for p in L("pv")}
SC = {meta(s).get("name"): s for s in L("sc")}


def pv_driver(pv):
    spec = (pv or {}).get("spec") or {}
    if spec.get("csi"):
        return spec["csi"].get("driver")
    for k in ("nfs", "hostPath", "local", "iscsi", "fc", "rbd", "cephfs", "azureFile", "flexVolume", "cifs"):
        if k in spec:
            return (spec[k].get("driver") if k == "flexVolume" else k) or k
    return None


def smb_kind(driver, pv=None, sc=None):
    d = (driver or "")
    if d == "smb.csi.k8s.io":
        return "smb.csi.k8s.io"
    if re.search(r"smb|cifs", d, re.I):
        return "driver name mentions smb/cifs: %s" % d
    if d in ("azureFile", "file.csi.azure.com"):
        proto = ((sc or {}).get("parameters") or {}).get("protocol", "")
        if proto == "nfs":
            return None
        return "azure file (SMB unless the class says protocol: nfs)"
    attrs = (((pv or {}).get("spec") or {}).get("csi") or {}).get("volumeAttributes") or {}
    if re.match(r"^(//|smb://|cifs://)", str(attrs.get("source", ""))):
        return "volume source is //host/share"
    return None


# ── 5. operators ─────────────────────────────────────────────────────────────
SUPPORTED = []   # (kind, resource, group)
for pair in REGISTRY_CRDS.split(";"):
    if "=" not in pair:
        continue
    kind, res = pair.split("=", 1)
    grp = res.split(".", 1)[1] if "." in res else None
    SUPPORTED.append((kind, res, grp))
SUP_KINDS = {k for k, _, _ in SUPPORTED}

crds = []
if R["crd"].ok:
    for line in R["crd"].text.splitlines():
        f = line.split("\t")
        if len(f) >= 3 and f[0]:
            crds.append({"name": f[0], "group": f[1], "kind": f[2],
                         "versions": f[3].split() if len(f) > 3 else [],
                         "version_label": f[4] if len(f) > 4 and f[4] else None})
csvs = []
if R["csv"].ok:
    for line in R["csv"].text.splitlines():
        f = line.split("\t")
        if len(f) >= 4 and f[1] and (len(f) < 5 or f[4] != "Copied"):
            csvs.append({"namespace": f[0], "name": f[1], "version": f[2], "phase": f[3],
                         "owns": f[5].split() if len(f) > 5 else []})


def supported_match(crd):
    for kind, res, grp in SUPPORTED:
        if crd["kind"] != kind:
            continue
        if grp is None or crd["group"] == grp:
            return kind
    return None


op_present = []
op_crd_names = []
if R["crd"].ok:
    wanted = []
    for c in crds:
        k = supported_match(c)
        if k:
            wanted.append((k, c))
    for k, c in wanted:
        r = kget("op_cr_" + c["name"], c["name"],
                 jsonpath='jsonpath={range .items[*]}{.metadata.namespace}{"\\t"}{.metadata.name}{"\\n"}{end}',
                 label="get %s -A (names only)" % c["name"])
        crs = [ln.split("\t") for ln in r.text.splitlines() if ln.strip()] if r.ok else None
        csv_hit = [x for x in csvs if k in x["owns"]]
        if csv_hit:
            ver = "%s %s (OLM %s)" % (csv_hit[0]["name"], csv_hit[0]["version"], csv_hit[0]["phase"])
        elif c["version_label"]:
            ver = c["version_label"] + " (CRD label app.kubernetes.io/version)"
        else:
            ver = "unknown: no OLM ClusterServiceVersion and no version label on the CRD"
        op_present.append({
            "kind": k, "crd": c["name"], "group": c["group"], "versions": c["versions"],
            "operator_version": ver,
            "custom_resources": len(crs) if crs is not None else r.reason,
            "namespaces": sorted({x[0] for x in crs if x and x[0]}) if crs is not None else r.reason,
            "refuses_zero": k in REFUSES_ZERO,
        })
        op_crd_names.append(c["name"])

# ── 6. PVC rows ─────────────────────────────────────────────────────────────
ARGO_PRESENT = R["apps"].ok and bool(R["apps"].items)
unsupported_owners = collections.OrderedDict()   # "Kind.group" -> {pvcs, namespaces}
rows = []
nsf = set(NS_FILTER)

for pvc in L("pvc"):
    ns, name = key(pvc)
    if nsf and ns not in nsf:
        continue
    spec, st = pvc.get("spec") or {}, pvc.get("status") or {}
    volname = spec.get("volumeName") or ""
    pv = PV.get(volname)
    scn = spec.get("storageClassName") or ((pv or {}).get("spec") or {}).get("storageClassName") or ""
    sc = SC.get(scn)
    req = qty(((spec.get("resources") or {}).get("requests") or {}).get("storage"))
    cap = qty((st.get("capacity") or {}).get("storage"))
    pods = pod_claims.get((ns, name), [])
    mounted_by, chains, images, kinds, owner_cr, wl = [], [], [], [], None, None
    objs_for_git = [pvc]
    for p in pods:
        pi = pod_info.get(key(p)) or {"chain": [], "last": p}
        ch = pi["chain"]
        mounted_by.append({"pod": meta(p).get("name"), "phase": (p.get("status") or {}).get("phase"),
                           "controller": ("%s/%s" % (ch[-1]["kind"], ch[-1]["name"])) if ch else "bare pod"})
        images += pod_images(p)
        for c in ch:
            if c["kind"] in WORKLOAD_KINDS and wl is None:
                wl = "%s/%s" % (c["kind"], c["name"])
            if c["group"] not in CORE_GROUPS and owner_cr is None:
                owner_cr = {"kind": c["kind"], "group": c["group"], "name": c["name"]}
            kinds.append(c["kind"])
        objs_for_git += [pi["last"], p]
    s_owner = None
    if not pods:
        s_owner = sts_for_claim(ns, name)
        if s_owner is not None:
            wl = "StatefulSet/%s (claim of its volumeClaimTemplates; no pod mounts it now)" % meta(s_owner).get("name")
            ch2, last2 = chain_of(s_owner)
            for c in ch2:
                if c["group"] not in CORE_GROUPS and owner_cr is None:
                    owner_cr = {"kind": c["kind"], "group": c["group"], "name": c["name"]}
                kinds.append(c["kind"])
            objs_for_git += [s_owner, last2]
    if wl is None and mounted_by:
        wl = mounted_by[0]["controller"]
    if owner_cr and owner_cr["kind"] not in SUP_KINDS and owner_cr["kind"] != "VirtualMachineInstance":
        un = unsupported_owners.setdefault("%s.%s" % (owner_cr["kind"], owner_cr["group"]), {"claims": 0, "namespaces": set()})
        un["claims"] += 1
        un["namespaces"].add(ns)
    ocr = pvc.get("metadata", {}).get("ownerReferences") or []
    for ref in ocr:
        if group_of(ref.get("apiVersion")) not in CORE_GROUPS and owner_cr is None:
            owner_cr = {"kind": ref.get("kind"), "group": group_of(ref.get("apiVersion")), "name": ref.get("name"),
                        "via": "claim ownerReference"}
    engine, engine_why = engine_of(images, kinds + ([owner_cr["kind"]] if owner_cr else []))

    # used bytes and files
    stat = used_by_claim.get((ns, name))
    if stat and isinstance(stat.get("used"), (int, float)):
        used, used_src = stat["used"], "kubelet stats/summary (node %s)" % stat["node"]
    elif STATS_WHY:
        used, used_src = STATS_WHY, None
    elif not pods:
        used, used_src = "unknown: not mounted by any live pod, kubelet reports nothing for it", None
    else:
        used, used_src = "unknown: kubelet did not report this volume (node stats incomplete)", None
    if stat and isinstance(stat.get("inodes_used"), (int, float)):
        inodes, inodes_src = stat["inodes_used"], "kubelet inodesUsed: files+dirs on that filesystem; on NFS or a shared filesystem it can be the whole export"
    elif STATS_WHY:
        inodes, inodes_src = STATS_WHY, None
    else:
        inodes, inodes_src = "unknown: not mounted, no kubelet figure", None
    big_basis = req if req is not None else cap
    reasons = []
    if engine:
        reasons.append("data engine: %s (%s)" % (engine, engine_why))
    elif any(WRITE_HEAVY.search(i) for i in images if not re.search(NOT_ENGINE, i, re.I)):
        reasons.append("image of a write-heavy application (%s)" % next(i for i in images if WRITE_HEAVY.search(i)).split("/")[-1][:50])
    if owner_cr and owner_cr["kind"] in SUP_KINDS:
        reasons.append("owned by operator CR %s/%s" % (owner_cr["kind"], owner_cr["name"]))
    if spec.get("volumeMode") == "Block":
        reasons.append("raw block volume")
    if any(k in ("VirtualMachine", "VirtualMachineInstance") for k in kinds):
        reasons.append("virtual machine disk (large files rewritten in place)")
    if isinstance(used, (int, float)) and used >= TIB and reasons:
        reasons.append("holds %s used" % human(used))
    driver = pv_driver(pv) or (sc or {}).get("provisioner") or ((pvc.get("metadata") or {}).get("annotations") or {}).get("volume.beta.kubernetes.io/storage-provisioner")
    smb = smb_kind(driver, pv, sc) or smb_kind((sc or {}).get("provisioner"), pv, sc)
    row = collections.OrderedDict([
        ("namespace", ns), ("name", name), ("phase", st.get("phase")),
        ("requested_bytes", req if req is not None else "unknown: no storage request"),
        ("capacity_bytes", cap if cap is not None else "unknown: not bound"),
        ("used_bytes", used), ("used_source", used_src),
        ("storage_class", scn or "unknown: none"), ("provisioner", (sc or {}).get("provisioner") or driver or "unknown"),
        ("access_modes", spec.get("accessModes") or []), ("volume_mode", spec.get("volumeMode") or "Filesystem"),
        ("volume", volname or None),
        ("reclaim_policy", ((pv or {}).get("spec") or {}).get("persistentVolumeReclaimPolicy") or ("unknown: no PV" if volname else "unknown: not bound")),
        ("mounted", bool(pods)), ("mounted_by", mounted_by[:6]), ("workload", wl or ("none: nothing mounts it" if not pods else "unknown")),
        ("operator_cr", owner_cr), ("gitops", gitops_of(*[o for o in objs_for_git if o])),
        ("data_engine", engine),
        ("inodes_used", inodes), ("inodes_source", inodes_src),
        ("file_count", "unknown: not measured; re-run with --count-files, or read inodes_used"),
        ("combo_candidate", bool(reasons)), ("combo_reasons", reasons),
        ("smb", smb), ("images", sorted({i for i in images if i})[:6]),
    ])
    row["_pods"] = pods
    rows.append(row)


# optional, bounded file counts
def count_files(row):
    pods = [p for p in row["_pods"] if (p.get("status") or {}).get("phase") == "Running"]
    if not pods:
        return "unknown: no running pod mounts it"
    p = pods[0]
    spec = p.get("spec") or {}
    vol = next((v.get("name") for v in spec.get("volumes") or []
                if (v.get("persistentVolumeClaim") or {}).get("claimName") == row["name"]), None)
    for c in spec.get("containers") or []:
        for vm in c.get("volumeMounts") or []:
            if vm.get("name") == vol:
                cmd = "find '%s' -xdev -type f 2>/dev/null | head -n %d | wc -l" % (vm.get("mountPath"), COUNT_CAP)
                rc, out, err = kc(["exec", "-n", row["namespace"], meta(p).get("name"), "-c", c.get("name"),
                                   "--", "sh", "-c", cmd], COUNT_TIMEOUT)
                if err == "timeout":
                    return "unknown: timeout after %ss, the count was cut off" % COUNT_TIMEOUT
                if rc != 0:
                    return "unknown: exec failed (%s)" % (explain(err, "create pods/exec", COUNT_TIMEOUT).replace("unknown: ", ""))
                try:
                    n = int(out.strip())
                except ValueError:
                    return "unknown: no find in the container"
                return {"files": n, "capped": n >= COUNT_CAP, "cap": COUNT_CAP,
                        "method": "find -xdev -type f | head -n %d | wc -l, read-only, in the running pod" % COUNT_CAP}
    return "unknown: the mount path was not found in the pod spec"


if COUNT_FILES:
    todo = sorted(rows, key=lambda r: -(r["used_bytes"] if isinstance(r["used_bytes"], (int, float)) else 0))
    say("   counting files (bounded: %ds and %d files per claim, at most %d claims)" % (COUNT_TIMEOUT, COUNT_CAP, COUNT_MAX))
    for i, r in enumerate(todo):
        if i >= COUNT_MAX:
            r["file_count"] = "unknown: beyond the %d-claim budget of --count-files" % COUNT_MAX
            continue
        say("   [files %d/%d] %s/%s" % (i + 1, min(len(todo), COUNT_MAX), r["namespace"], r["name"]))
        r["file_count"] = count_files(r)
for r in rows:
    r.pop("_pods", None)

# ── 7. StatefulSets with volumeClaimTemplates ───────────────────────────────
sts_rows = []
for s in L("sts"):
    ns, name = key(s)
    if nsf and ns not in nsf:
        continue
    vcts = (s.get("spec") or {}).get("volumeClaimTemplates") or []
    if not vcts:
        continue
    ch, last = chain_of(s)
    cr = next((c for c in ch if c["group"] not in CORE_GROUPS), None)
    git = gitops_of(s)
    if cr:
        manager = "operator: %s.%s/%s" % (cr["kind"], cr["group"], cr["name"])
    elif git["manager"] in ("argocd", "flux-kustomization", "flux-helmrelease"):
        manager = "gitops: %s %s" % (git["manager"], git.get("app", ""))
    elif git["manager"] == "argocd?":
        manager = "probably Argo CD: %s (weak sign)" % git.get("app", "")
    elif git["manager"] == "helm":
        manager = "helm release %s (no GitOps tracking)" % git.get("app", "")
    else:
        manager = "nobody"
    sts_rows.append(collections.OrderedDict([
        ("namespace", ns), ("name", name), ("replicas", (s.get("spec") or {}).get("replicas")),
        ("templates", [{"name": meta(t).get("name"),
                        "storage_class": (t.get("spec") or {}).get("storageClassName") or "unknown: none",
                        "requested": (((t.get("spec") or {}).get("resources") or {}).get("requests") or {}).get("storage"),
                        "volume_mode": (t.get("spec") or {}).get("volumeMode") or "Filesystem"} for t in vcts]),
        ("managed_by", manager), ("gitops", git),
        ("next_step", "volumeClaimTemplates are immutable: the cutover goes through `tp gitops sts-vct` (PV-swap), not a patch"),
    ]))

# ── 8. Argo CD and Flux ─────────────────────────────────────────────────────
SRC_ORDER = ("Plugin", "Helm", "Kustomize", "Directory")


def src_kind(s):
    if not isinstance(s, dict):
        return "unknown"
    if s.get("plugin") is not None:
        return "Plugin"
    if s.get("chart") or s.get("helm") is not None:
        return "Helm"
    if s.get("kustomize") is not None:
        return "Kustomize"
    return "Directory"


def srcs_of(spec):
    if isinstance(spec.get("sources"), list) and spec["sources"]:
        return spec["sources"]
    if isinstance(spec.get("source"), dict):
        return [spec["source"]]
    return []


argo = collections.OrderedDict()
argo_apps = []
if R["apps"].ok:
    app_names = {key(a) for a in R["apps"].items}
    for a in R["apps"].items:
        ns, name = key(a)
        spec, status = a.get("spec") or {}, a.get("status") or {}
        srcs = srcs_of(spec)
        pol = spec.get("syncPolicy") or {}
        auto = pol.get("automated")
        res = status.get("resources") or []
        res_ns = sorted({r.get("namespace") for r in res if r.get("namespace")})
        kinds_h = collections.Counter(r.get("kind") for r in res)
        owner = owner_of(a)
        gen = ({"kind": owner.get("kind"), "name": owner.get("name")}
               if owner and owner.get("kind") == "ApplicationSet" else None)
        dest = spec.get("destination") or {}
        argo_apps.append(collections.OrderedDict([
            ("namespace", ns), ("name", name), ("project", spec.get("project")),
            ("source_kinds", [src_kind(s) for s in srcs] or ["unknown: no source"]),
            ("multi_source", len(srcs) > 1),
            ("sources", [{"kind": src_kind(s), "repo": redact_url(s.get("repoURL")), "path": s.get("path"),
                          "chart": s.get("chart"), "target_revision": s.get("targetRevision")} for s in srcs]),
            ("sync_policy", {"automated": auto is not None, "self_heal": bool((auto or {}).get("selfHeal")),
                             "prune": bool((auto or {}).get("prune")), "sync_options": pol.get("syncOptions") or []}),
            ("generated_by_applicationset", gen),
            ("is_app_of_apps", kinds_h.get("Application", 0) > 0),
            ("child_applications", kinds_h.get("Application", 0)),
            ("destination", {"server": redact_url(dest.get("server")), "name": dest.get("name"), "namespace": dest.get("namespace")}),
            ("managed_namespaces", sorted(set(res_ns) | ({dest.get("namespace")} if dest.get("namespace") else set()))),
            ("managed_resources", len(res) if res else "unknown: status.resources empty or not reported"),
            ("manages_kinds", dict(kinds_h.most_common(12))),
            ("manages_pvc", kinds_h.get("PersistentVolumeClaim", 0) > 0),
            ("manages_statefulset", kinds_h.get("StatefulSet", 0) > 0),
            ("cascade_delete_finalizer", any("resources-finalizer" in f for f in meta(a).get("finalizers") or [])),
            ("sync_status", (status.get("sync") or {}).get("status")),
            ("health_status", (status.get("health") or {}).get("status")),
        ]))
    child_of = {}
    for ap in argo_apps:
        if ap["is_app_of_apps"]:
            for r in (next(a for a in R["apps"].items if key(a) == (ap["namespace"], ap["name"])).get("status") or {}).get("resources") or []:
                if r.get("kind") == "Application":
                    child_of[(r.get("namespace") or ap["namespace"], r.get("name"))] = ap["name"]
    for ap in argo_apps:
        ap["app_of_apps_parent"] = child_of.get((ap["namespace"], ap["name"]))
argo_sets = []
for s in L("appsets"):
    ns, name = key(s)
    spec = s.get("spec") or {}
    gens = []
    for g in spec.get("generators") or []:
        gens += [k for k in g if k != "selector"]
    tmpl = ((spec.get("template") or {}).get("spec")) or {}
    argo_sets.append(collections.OrderedDict([
        ("namespace", ns), ("name", name), ("generators", gens or ["unknown"]),
        ("template_source_kinds", [src_kind(x) for x in srcs_of(tmpl)] or ["unknown"]),
        ("generated_applications", sum(1 for ap in argo_apps if (ap["generated_by_applicationset"] or {}).get("name") == name)),
        ("preserve_resources_on_deletion", bool((spec.get("syncPolicy") or {}).get("preserveResourcesOnDeletion"))),
    ]))
argo_versions = sorted({(c.get("image") or "").rsplit(":", 1)[-1]
                        for kname in ("sts", "deploy") for w in L(kname)
                        for c in ((w.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers", [])
                        if re.search(r"argocd|argo-cd", c.get("image") or "") and ":" in (c.get("image") or "")
                        and "application-controller" in meta(w).get("name", "")})
argo_ns = collections.Counter(a["namespace"] for a in argo_apps)
inv["gitops"] = collections.OrderedDict([
    ("argocd", collections.OrderedDict([
        ("applications_status", "ok" if R["apps"].ok else R["apps"].say("not installed")),
        ("applicationsets_status", "ok" if R["appsets"].ok else R["appsets"].say("not installed")),
        ("argo_namespaces", dict(argo_ns)),
        ("openshift_gitops_present", "openshift-gitops" in argo_ns or any(meta(x).get("namespace") == "openshift-gitops" for x in L("argocd_cr"))),
        ("argocd_instances", [{"namespace": meta(x).get("namespace"), "name": meta(x).get("name")} for x in L("argocd_cr")]
         if R["argocd_cr"].ok else R["argocd_cr"].say("not installed (operator ArgoCD CR)")),
        ("application_controller_versions", argo_versions or "unknown: controller image not found among readable workloads"),
        ("applications", argo_apps if R["apps"].ok else R["apps"].say("not installed")),
        ("applicationsets", argo_sets if R["appsets"].ok else R["appsets"].say("not installed")),
        ("secrets_note", "repository credentials are never read; URLs have any user:token@ removed"),
    ])),
])
fx_ks = [collections.OrderedDict([
    ("namespace", key(k)[0]), ("name", key(k)[1]), ("path", (k.get("spec") or {}).get("path")),
    ("source", "%s/%s" % ((k.get("spec") or {}).get("sourceRef", {}).get("kind"), (k.get("spec") or {}).get("sourceRef", {}).get("name"))),
    ("prune", bool((k.get("spec") or {}).get("prune"))), ("suspended", bool((k.get("spec") or {}).get("suspend"))),
    ("target_namespace", (k.get("spec") or {}).get("targetNamespace")),
    ("inventory_entries", len(((k.get("status") or {}).get("inventory") or {}).get("entries") or []))]) for k in L("fx_ks")]
fx_hr = [collections.OrderedDict([
    ("namespace", key(h)[0]), ("name", key(h)[1]),
    ("chart", ((h.get("spec") or {}).get("chart") or {}).get("spec", {}).get("chart") or ((h.get("spec") or {}).get("chartRef") or {}).get("name")),
    ("version", ((h.get("spec") or {}).get("chart") or {}).get("spec", {}).get("version")),
    ("source", "%s/%s" % ((((h.get("spec") or {}).get("chart") or {}).get("spec") or {}).get("sourceRef", {}).get("kind"),
                          (((h.get("spec") or {}).get("chart") or {}).get("spec") or {}).get("sourceRef", {}).get("name"))),
    ("target_namespace", (h.get("spec") or {}).get("targetNamespace")), ("suspended", bool((h.get("spec") or {}).get("suspend")))]) for h in L("fx_hr")]
fx_git = [{"namespace": key(g)[0], "name": key(g)[1], "url": redact_url((g.get("spec") or {}).get("url")),
           "branch": ((g.get("spec") or {}).get("ref") or {}).get("branch")} for g in L("fx_git")]
inv["gitops"]["flux"] = collections.OrderedDict([
    ("kustomizations", fx_ks if R["fx_ks"].ok else R["fx_ks"].say("not installed")),
    ("helmreleases", fx_hr if R["fx_hr"].ok else R["fx_hr"].say("not installed")),
    ("gitrepositories", fx_git if R["fx_git"].ok else R["fx_git"].say("not installed")),
])

# ── 9. nodes: the 70/80 gate ────────────────────────────────────────────────
req_by_node = collections.defaultdict(lambda: {"cpu": 0, "mem": 0, "pods": 0})
for p in L("pods"):
    node = (p.get("spec") or {}).get("nodeName")
    if not node or (p.get("status") or {}).get("phase") in ("Succeeded", "Failed"):
        continue
    acc = req_by_node[node]
    acc["pods"] += 1
    for c in (p.get("spec") or {}).get("containers") or []:
        rq = ((c.get("resources") or {}).get("requests")) or {}
        acc["cpu"] += cpu_m(rq.get("cpu")) or 0
        acc["mem"] += qty(rq.get("memory")) or 0
usage = {}
if R["metrics"].ok:
    for m in (R["metrics"].items[0].get("items") or []):
        usage[meta(m).get("name")] = m.get("usage") or {}
node_rows = []
pods_read = R["pods"].ok
for n in L("nodes"):
    nm = meta(n).get("name")
    al = (n.get("status") or {}).get("allocatable") or {}
    acpu, amem, apods = cpu_m(al.get("cpu")), qty(al.get("memory")), qty(al.get("pods"))
    rq = req_by_node.get(nm, {"cpu": 0, "mem": 0, "pods": 0})
    u = usage.get(nm) or {}
    st = STATS.get(nm)
    nfs = (st or {}).get("node", {}).get("fs") or {}
    why_usage = R["metrics"].reason if not R["metrics"].ok else "unknown: node absent from the metrics API"
    pct = lambda a, b: (round(100.0 * a / b, 1) if a is not None and b else None)
    node_rows.append(collections.OrderedDict([
        ("name", nm), ("roles", sorted(k.split("/", 1)[1] for k in labels(n) if k.startswith("node-role.kubernetes.io/"))),
        ("kubelet", ((n.get("status") or {}).get("nodeInfo") or {}).get("kubeletVersion")),
        ("allocatable_cpu_m", acpu), ("allocatable_memory_bytes", amem), ("allocatable_pods", apods),
        ("allocatable_ephemeral_bytes", qty(al.get("ephemeral-storage"))),
        ("requests_cpu_m", rq["cpu"] if pods_read else R["pods"].reason),
        ("requests_memory_bytes", rq["mem"] if pods_read else R["pods"].reason),
        ("requests_cpu_pct", pct(rq["cpu"], acpu) if pods_read else R["pods"].reason),
        ("requests_memory_pct", pct(rq["mem"], amem) if pods_read else R["pods"].reason),
        ("pods", rq["pods"] if pods_read else R["pods"].reason),
        ("pods_pct", pct(rq["pods"], apods) if pods_read else R["pods"].reason),
        ("usage_cpu_m", cpu_m(u.get("cpu")) if u else why_usage),
        ("usage_memory_bytes", qty(u.get("memory")) if u else why_usage),
        ("usage_cpu_pct", pct(cpu_m(u.get("cpu")), acpu) if u else why_usage),
        ("usage_memory_pct", pct(qty(u.get("memory")), amem) if u else why_usage),
        ("disk_capacity_bytes", nfs.get("capacityBytes") if st else STATS_ERR.get(nm) or STATS_WHY or "unknown: no node statistics"),
        ("disk_available_bytes", nfs.get("availableBytes") if st else STATS_ERR.get(nm) or STATS_WHY or "unknown: no node statistics"),
        ("unschedulable", bool((n.get("spec") or {}).get("unschedulable"))),
    ]))
inv["nodes"] = node_rows if R["nodes"].ok else R["nodes"].reason

# ── 10. OpenShift ───────────────────────────────────────────────────────────
is_os = R["secapi"].ok or R["cv"].ok
sccs = [meta(s).get("name") for s in L("scc")]
osv = None
if R["cv"].ok and R["cv"].items:
    cv = R["cv"].items[0]
    osv = ((cv.get("status") or {}).get("desired") or {}).get("version")
    cid = (cv.get("spec") or {}).get("clusterID")
    inv["license"]["openshift_cluster_id"] = cid
inv["platform"] = collections.OrderedDict([
    ("kubernetes_version", k8s_version or SECTIONS["k8s_version"].get("reason")),
    ("platform", "openshift" if is_os else ("kubernetes" if R["secapi"].status == "absent" else "unknown: security.openshift.io API not readable")),
    ("openshift_version", osv if osv else (R["cv"].say("not OpenShift") if not R["cv"].ok else "unknown: no version in ClusterVersion")),
    ("security_api_security_openshift_io_v1", "present" if R["secapi"].ok else R["secapi"].say("not installed")),
    ("sccs", sccs if R["scc"].ok else R["scc"].say("not OpenShift")),
    ("scc_anyuid", ("available" if "anyuid" in sccs else "not found") if R["scc"].ok else R["scc"].say("not OpenShift")),
    ("scc_hostmount_anyuid", ("available" if "hostmount-anyuid" in sccs else "not found") if R["scc"].ok else R["scc"].say("not OpenShift")),
    ("scc_privileged", ("available" if "privileged" in sccs else "not found") if R["scc"].ok else R["scc"].say("not OpenShift")),
])
ns_rows = L("namespaces")
psa = collections.Counter(labels(n).get("pod-security.kubernetes.io/enforce", "unset") for n in ns_rows)
inv["platform"]["pod_security_enforce"] = dict(psa) if R["namespaces"].ok else R["namespaces"].reason

# ── 11. Trident and the destination ─────────────────────────────────────────
tbc_rows = []
for t in L("tbc"):
    sp = t.get("spec") or {}
    drv = sp.get("storageDriverName")
    san = sp.get("sanType")
    if drv and "san" in drv:
        proto = {"nvme": "NVMe/TCP", "fcp": "FCP"}.get(str(san).lower(), "iSCSI")
    elif drv and "nas" in drv:
        proto = "SMB/CIFS" if str(sp.get("nasType", "")).lower() == "smb" else "NFS"
    else:
        proto = "unknown: driver %s" % drv
    tbc_rows.append(collections.OrderedDict([
        ("namespace", key(t)[0]), ("name", key(t)[1]), ("backend_name", sp.get("backendName")),
        ("driver", drv), ("protocol", proto), ("svm", sp.get("svm")),
        ("management_lif", sp.get("managementLIF")), ("data_lif", sp.get("dataLIF")),
        ("storage_prefix", sp.get("storagePrefix")),
        ("credentials_secret", (sp.get("credentials") or {}).get("name")),
        ("phase", (t.get("status") or {}).get("phase")), ("state", (t.get("status") or {}).get("lastOperationStatus")),
    ]))
be_rows = [{"name": b.get("backendName") or meta(b).get("name"), "state": b.get("state"), "online": b.get("online"),
            "user_state": b.get("userState")} for b in L("tbe")]
tver = None
for v in L("tver"):
    tver = v.get("trident_version") or tver
if not tver:
    for kname in ("deploy",):
        for w in L(kname):
            if meta(w).get("name") == "trident-controller" or meta(w).get("name") == "trident-operator":
                for c in ((w.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers", []):
                    if "trident" in (c.get("image") or "") and ":" in c["image"]:
                        tver = c["image"].rsplit(":", 1)[-1] + " (image tag)"
trident_sc = [collections.OrderedDict([
    ("name", n), ("backend_type", (s.get("parameters") or {}).get("backendType")),
    ("reclaim_policy", s.get("reclaimPolicy")), ("allow_expansion", s.get("allowVolumeExpansion")),
    ("volume_binding", s.get("volumeBindingMode"))])
    for n, s in SC.items() if s.get("provisioner") == "csi.trident.netapp.io"]
inv["trident"] = collections.OrderedDict([
    ("installed", bool(tver or tbc_rows or trident_sc or any(c["name"] == "tridentorchestrators.trident.netapp.io" for c in crds))
     if R["sc"].ok else R["sc"].reason),
    ("version", tver or ("unknown: not installed, or TridentVersion / trident deployment unreadable"
                         if R["tver"].ok or R["tver"].status == "absent" else R["tver"].reason)),
    ("backend_configs", tbc_rows if R["tbc"].ok else R["tbc"].say("not installed")),
    ("backends", be_rows if R["tbe"].ok else R["tbe"].say("not installed")),
    ("storage_classes", trident_sc if R["sc"].ok else R["sc"].reason),
    ("volume_snapshot_classes", [{"name": meta(v).get("name"), "driver": v.get("driver"), "deletion_policy": v.get("deletionPolicy")} for v in L("vsc")]
     if R["vsc"].ok else R["vsc"].say("not installed (snapshot CRDs absent)")),
    ("csi_drivers", sorted(meta(d).get("name") for d in L("csidriver")) if R["csidriver"].ok else R["csidriver"].reason),
])

# ── 12. network and deployment ──────────────────────────────────────────────
PUBLIC = ("docker.io", "quay.io", "ghcr.io", "registry.k8s.io", "k8s.gcr.io", "gcr.io", "mcr.microsoft.com",
          "registry.redhat.io", "registry.access.redhat.com", "public.ecr.aws", "docker.elastic.co", "gitlab.com")


def reg_host(img):
    first = img.split("/", 1)[0] if "/" in img else ""
    if first and ("." in first or ":" in first or first == "localhost"):
        return first
    return "docker.io"


hosts = collections.Counter()
for p in L("pods"):
    for im in pod_images(p):
        if im:
            hosts[reg_host(im)] += 1
pull_secrets = collections.Counter()
for p in L("pods"):
    for s in (p.get("spec") or {}).get("imagePullSecrets") or []:
        pull_secrets[re.sub(r"-dockercfg-[a-z0-9]+$", "-dockercfg-*", re.sub(r"-token-[a-z0-9]+$", "-token-*", s.get("name") or ""))] += 1
svc_np = [("%s/%s" % key(s), (s.get("spec") or {}).get("type")) for s in L("services")
          if (s.get("spec") or {}).get("type") in ("NodePort", "LoadBalancer")]
mirrors = []
for m in L("idms") + L("icsp"):
    for e in (m.get("spec") or {}).get("imageDigestMirrors") or (m.get("spec") or {}).get("repositoryDigestMirrors") or []:
        mirrors.append({"source": e.get("source"), "mirrors": [redact_url(x) for x in e.get("mirrors") or []]})
px = (L("proxy")[0].get("spec") or {}) if R["proxy"].ok and R["proxy"].items else {}
imgcfg = (L("imgcfg")[0].get("spec") or {}) if R["imgcfg"].ok and R["imgcfg"].items else {}
private_hosts = sorted(h for h in hosts if not any(h == x or h.endswith("." + x) for x in PUBLIC))
public_hosts = sorted(h for h in hosts if h not in private_hosts)
if not R["pods"].ok:
    darksite = R["pods"].reason
elif not hosts:
    darksite = "unknown: no pod images to judge from"
elif public_hosts and not mirrors:
    darksite = "not evident: pods pull from public registries (%s)" % ", ".join(public_hosts[:4])
elif mirrors:
    darksite = "likely: image mirror rules exist (%d)" % len(mirrors)
else:
    darksite = "likely (heuristic): every image comes from a private registry"
inv["network"] = collections.OrderedDict([
    ("registry_hosts_in_use", dict(hosts.most_common(20)) if R["pods"].ok else R["pods"].reason),
    ("private_registry_hosts", private_hosts if R["pods"].ok else R["pods"].reason),
    ("darksite", darksite),
    ("image_mirror_rules", mirrors if (R["idms"].ok or R["icsp"].ok) else "unknown: " + (R["idms"].reason if R["idms"].status == "unknown" else "not OpenShift or no mirror API")),
    ("image_registry_restrictions", {k: imgcfg.get("registrySources", {}).get(k) for k in ("allowedRegistries", "blockedRegistries", "insecureRegistries")
                                     if (imgcfg.get("registrySources") or {}).get(k)} if R["imgcfg"].ok else R["imgcfg"].say("not OpenShift")),
    ("proxy", {"http": redact_url(px.get("httpProxy")), "https": redact_url(px.get("httpsProxy")), "no_proxy": px.get("noProxy")}
     if R["proxy"].ok and px else (R["proxy"].say("unknown: a vanilla Kubernetes proxy is not readable through the API")
                                   if not R["proxy"].ok else "none configured")),
    ("image_pull_secret_names", dict(pull_secrets.most_common(20)) if R["pods"].ok else R["pods"].reason),
    ("nodeport_or_loadbalancer_services", {"count": len(svc_np), "first": svc_np[:20]} if R["services"].ok else R["services"].reason),
    ("routes", {"count": len(L("routes"))} if R["routes"].ok else R["routes"].say("not OpenShift")),
    ("ingresses", {"count": len(L("ingress"))} if R["ingress"].ok else R["ingress"].reason),
])

# ── 13. SMB, operators, summary of PVC risks ────────────────────────────────
smb_pvs = [meta(p).get("name") for p in L("pv") if smb_kind(pv_driver(p), p, SC.get((p.get("spec") or {}).get("storageClassName")))]
smb_scs = [n for n, s in SC.items() if smb_kind(s.get("provisioner"), None, s)]
smb_rows = [{"claim": "%s/%s" % (r["namespace"], r["name"]), "why": r["smb"]} for r in rows if r["smb"]]
inv["smb"] = collections.OrderedDict([
    ("claims", smb_rows if R["pvc"].ok else R["pvc"].reason),
    ("persistent_volumes", smb_pvs if R["pv"].ok else R["pv"].reason),
    ("storage_classes", smb_scs if R["sc"].ok else R["sc"].reason),
    ("note", "SMB/CIFS claims take another route; they are listed, not planned, here"),
])
csv_unsupported = [x for x in csvs if not any(k in SUP_KINDS for k in x["owns"])]
inv["operators"] = collections.OrderedDict([
    ("supported_present", op_present if R["crd"].ok else R["crd"].reason),
    ("supported_origin", "the product operator registry (embedded in tp-pre.sh as TP_REGISTRY_CRDS)"),
    ("unsupported_owning_claims", [{"kind": k, "claims": v["claims"], "namespaces": sorted(v["namespaces"])}
                                   for k, v in unsupported_owners.items()]
     if (R["pvc"].ok and R["pods"].ok) else "unknown: " + (R["pods"].reason or R["pvc"].reason)),
    ("olm_operators_not_supported", [{"name": x["name"], "version": x["version"], "namespace": x["namespace"]} for x in csv_unsupported]
     if R["csv"].ok else R["csv"].say("not OpenShift/OLM")),
    ("crd_groups", {g: sorted({c["kind"] for c in crds if c["group"] == g})
                    for g in sorted({c["group"] for c in crds})
                    if not (g.endswith("k8s.io") or g.endswith("openshift.io") or g.endswith("kubernetes.io"))}
     if R["crd"].ok else R["crd"].reason),
])

inv["sections"] = SECTIONS
inv["pvcs"] = rows if R["pvc"].ok else R["pvc"].reason
inv["statefulsets_with_volume_claim_templates"] = sts_rows if R["sts"].ok else R["sts"].reason
inv["engine_data"] = "from TP_DATA_ENGINES in tp-pre.sh"

# ── 14. headline numbers ────────────────────────────────────────────────────
num = lambda v: isinstance(v, (int, float))
unknown_sections = [(n, s) for n, s in SECTIONS.items() if s["status"] == "unknown"]
big = [r for r in rows if num(r["requested_bytes"]) and r["requested_bytes"] >= BIG_PVC_BYTES]
big_used = [r for r in rows if num(r["used_bytes"]) and r["used_bytes"] >= BIG_PVC_BYTES]
many_inodes = [r for r in rows if num(r["inodes_used"]) and r["inodes_used"] >= MANY_FILES]
many_found = [r for r in rows if isinstance(r["file_count"], dict) and r["file_count"]["files"] >= MANY_FILES]
combo = [r for r in rows if r["combo_candidate"]]
unk_used = [r for r in rows if not num(r["used_bytes"])]
unk_files = [r for r in rows if not num(r["inodes_used"]) and not isinstance(r["file_count"], dict)]
hot = [n for n in node_rows if num(n.get("requests_cpu_pct")) and (n["requests_cpu_pct"] >= WARN_PCT or (num(n.get("requests_memory_pct")) and n["requests_memory_pct"] >= WARN_PCT))]
over = [n for n in node_rows if num(n.get("requests_cpu_pct")) and (n["requests_cpu_pct"] >= OVER_PCT or (num(n.get("requests_memory_pct")) and n["requests_memory_pct"] >= OVER_PCT))]
ks = next((p for p in perms if p["check"].startswith("get namespaces/kube-system")), {})
kube_system_ok = bool(ksuid)
a_kinds = collections.Counter(k for a in argo_apps for k in set(a["source_kinds"]))
inv["risks"] = collections.OrderedDict([
    ("pvcs", len(rows) if R["pvc"].ok else R["pvc"].reason),
    ("pvcs_requested_over_1_tib", len(big) if R["pvc"].ok else R["pvc"].reason),
    ("pvcs_used_over_1_tib", len(big_used)),
    ("pvcs_used_unknown", len(unk_used)),
    ("pvcs_over_1m_files_by_kubelet_inodes", len(many_inodes)),
    ("pvcs_over_1m_files_by_find", len(many_found)),
    ("pvcs_file_count_unknown", len(unk_files)),
    ("pvcs_combo_candidates", len(combo)),
    ("pvcs_smb", len(smb_rows)),
    ("nodes_over_70_pct_requests", len(hot)), ("nodes_over_80_pct_requests", len(over)),
    ("kube_system_readable", kube_system_ok),
    ("sections_unknown", len(unknown_sections)),
])

json.dump(inv, open(OUT_JSON, "w"), indent=1, default=str)

# ── 15. the summary a person reads ──────────────────────────────────────────
md = []
add = md.append
add("# Trident Port pre-engagement summary — %s" % (CTX or "cluster"))
add("")
add("Generated %s by `tp-pre.sh` (read-only). Raw data: `%s`. Every figure below is read from the cluster; "
    "`unknown:` means the cluster did not say, never zero." % (inv["generated"], os.path.basename(OUT_JSON)))
add("")
add("## Risks first")
add("")
risks = []
if not R["pvc"].ok:
    risks.append("**Claims could not be read**: %s" % R["pvc"].reason)
else:
    risks.append("%d PVC > 1 TiB requested (%d > 1 TiB used)%s" % (len(big), len(big_used),
                 "; used is unknown for %d claim(s)" % len(unk_used) if unk_used else ""))
    risks.append("%d PVC with more than 1 M files (kubelet inodes: %d; find: %d)%s" % (
        len(set(map(id, many_inodes)) | set(map(id, many_found))), len(many_inodes), len(many_found),
        "; file count unknown for %d claim(s) -- re-run with --count-files" % len(unk_files) if unk_files else ""))
    risks.append("%d PVC candidates for block mode (Combo) -- live-sync may not keep up (heuristic: image, operator, size, not measured)" % len(combo))
    if smb_rows:
        risks.append("%d SMB/CIFS claim(s) -- another route" % len(smb_rows))
if not kube_system_ok:
    risks.append("**No access to kube-system**: %s -- the licence fingerprint cannot be read" % inv["license"]["kube_system_uid"])
if R["apps"].ok:
    risks.append("Argo: %d Applications (%s), %d ApplicationSet, %d app-of-apps, %d automated, %d selfHeal, %d with cascade-delete finalizer" % (
        len(argo_apps), ", ".join("%d %s" % (v, k) for k, v in sorted(a_kinds.items())) or "none",
        len(argo_sets), sum(1 for a in argo_apps if a["is_app_of_apps"]),
        sum(1 for a in argo_apps if a["sync_policy"]["automated"]), sum(1 for a in argo_apps if a["sync_policy"]["self_heal"]),
        sum(1 for a in argo_apps if a["cascade_delete_finalizer"])))
else:
    risks.append("Argo: %s" % R["apps"].say("not installed"))
if R["fx_ks"].ok or R["fx_hr"].ok:
    risks.append("Flux: %d Kustomizations, %d HelmReleases" % (len(fx_ks), len(fx_hr)))
if R["sts"].ok:
    risks.append("%d StatefulSet(s) with volumeClaimTemplates (%s)" % (len(sts_rows), ", ".join(
        "%d %s" % (v, k) for k, v in collections.Counter(s["managed_by"].split(":")[0].split(" ")[0] for s in sts_rows).items()) or "none"))
if isinstance(inv["operators"]["unsupported_owning_claims"], list) and inv["operators"]["unsupported_owning_claims"]:
    risks.append("Operators not supported that own claims: " + ", ".join(
        "%s (%d claims)" % (u["kind"], u["claims"]) for u in inv["operators"]["unsupported_owning_claims"]))
if over or hot:
    risks.append("Node capacity: %d node(s) at or above 80%% and %d at or above 70%% of allocatable (requests)" % (len(over), len(hot)))
if is_os and R["scc"].ok and "anyuid" not in sccs:
    risks.append("OpenShift: SCC anyuid is not available")
if unknown_sections:
    risks.append("%d of %d sections came back unknown (reason per section in the table at the end): %s" % (
        len(unknown_sections), len(SECTIONS), ", ".join(n for n, _ in unknown_sections[:24])
        + (", ..." if len(unknown_sections) > 24 else "")))
for r_ in risks:
    add("- " + r_)
add("")
add("## Cluster")
add("")
add("| Item | Value |\n|---|---|")
add("| kube-system UID (licence fingerprint) | `%s` |" % inv["license"]["kube_system_uid"])
if inv["license"].get("openshift_cluster_id"):
    add("| OpenShift clusterID | `%s` |" % inv["license"]["openshift_cluster_id"])
add("| Kubernetes | %s |" % inv["platform"]["kubernetes_version"])
add("| Platform | %s %s |" % (inv["platform"]["platform"], inv["platform"]["openshift_version"] if osv else ""))
add("| SCC anyuid / hostmount-anyuid / privileged | %s / %s / %s |" % (inv["platform"]["scc_anyuid"], inv["platform"]["scc_hostmount_anyuid"], inv["platform"]["scc_privileged"]))
add("| Trident | %s |" % (inv["trident"]["version"] if inv["trident"]["installed"] is True else
                          ("not installed" if inv["trident"]["installed"] is False else inv["trident"]["installed"])))
add("| Darksite | %s |" % darksite)
add("")
add("## Claims")
add("")
if R["pvc"].ok:
    tot_req = sum(r["requested_bytes"] for r in rows if num(r["requested_bytes"]))
    tot_used = sum(r["used_bytes"] for r in rows if num(r["used_bytes"]))
    add("%d claims, %s requested; used is readable for %d of them (%s)." % (len(rows), human(tot_req), len(rows) - len(unk_used), human(tot_used)))
    add("")
    add("| Claim | Requested | Used | Files (inodes) | Class | Mode | Held by | Combo |\n|---|---|---|---|---|---|---|---|")
    ranked = sorted(rows, key=lambda r: -((r["used_bytes"] if num(r["used_bytes"]) else 0) or (r["requested_bytes"] if num(r["requested_bytes"]) else 0)))
    for r in ranked[:40]:
        fc = r["file_count"]["files"] if isinstance(r["file_count"], dict) else r["inodes_used"]
        add("| %s/%s | %s | %s | %s | %s | %s %s | %s | %s |" % (
            r["namespace"], r["name"], human(r["requested_bytes"]), human(r["used_bytes"]) if num(r["used_bytes"]) else "unknown",
            fc if num(fc) else "unknown", r["storage_class"], ",".join(ACCESS.get(m, m) for m in r["access_modes"]), r["volume_mode"],
            r["workload"], "yes" if r["combo_candidate"] else ""))
    if len(ranked) > 40:
        add("")
        add("(%d more in the raw file)" % (len(ranked) - 40))
else:
    add(R["pvc"].reason)
add("")
add("## Operators")
add("")
if isinstance(inv["operators"]["supported_present"], list):
    for o in inv["operators"]["supported_present"]:
        add("- %s (%s): %s custom resource(s); operator %s%s" % (
            o["kind"], o["crd"], o["custom_resources"], o["operator_version"], "; CRD refuses zero replicas" if o["refuses_zero"] else ""))
    if not inv["operators"]["supported_present"]:
        add("- no supported operator CRD present")
else:
    add(inv["operators"]["supported_present"])
add("")
add("## Where each section came from")
add("")
add("| Section | Status | Origin |\n|---|---|---|")
for n, s in SECTIONS.items():
    add("| %s | %s | `%s` |" % (n, s.get("reason") or s["status"], s["origin"]))
add("")
open(OUT_MD, "w").write("\n".join(md) + "\n")

say("   inventory:  %s" % OUT_JSON)
say("   summary:    %s" % OUT_MD)
for r_ in risks[:14]:
    say("   * " + r_.replace("**", ""))
TP_INV_PY
}

sec "G2. FULL INVENTORY — for planning a bulk migration"
INV_JSON="tp-pre-${CTX}-${STAMP}.json"
INV_MD="tp-pre-${CTX}-${STAMP}.md"
TGZ="tp-pre-${CTX}-${STAMP}.tgz"
if command -v python3 >/dev/null 2>&1; then
  tp_inventory || echo "   *** the inventory step failed (rc=$?): send the files that exist anyway ***"
else
  echo "   unknown: python3 is not installed here, so the machine-readable inventory"
  echo "   and the summary were not produced. Everything above is still valid."
fi

# ============================================================================
# tp_block_mirror_probe <namespace> <pod> <container>
#
# WHAT THIS ANSWERS, AND WHY IT IS SAFE TO ASK FROM HERE.
#
# Whether this cluster's nodes can run a HOT block-cutover — the application
# keeps writing to its existing block claim while the data mirrors across, and
# the cutover itself is a sub-second pause rather than a copy window — depends
# on an in-kernel device-mapper engine being available on the node. Until this
# was asked, that was a fact nobody in a pre-assessment ever went and got: not
# because it is hard, but because nothing here needed to touch a customer's
# node before.
#
# It can be answered WITHOUT creating anything new. Trident's own node
# plugin — the DaemonSet the customer already has running, a prerequisite of
# using Trident CSI at all — is `privileged: true` and mounts the host's
# `/sys` straight into the container, plus the ENTIRE host root at `/host`
# (bidirectional). A `kubectl exec` into that ALREADY-RUNNING pod, reading
# `/sys/module/<name>` (loaded right now) and `chroot /host modinfo <name>`
# (present in the kernel's own module tree, whether loaded or not) is exactly
# the same class of read section F already performs against
# `deploy/trident-controller` with `tridentctl get backend` a few hundred
# lines above — nothing here is created, patched, scaled or deleted.
#
# BOTH CHECKS, NOT JUST ONE. These modules commonly auto-load only at the
# first `dmsetup create`, so `/sys/module` alone would report "not available"
# on a node where the capability plainly exists and simply has not been used
# yet. `modinfo` against the host's own module tree under `/host` answers the
# question an `insmod` would, without running one.
#
# THE ENGINE'S NAME NEVER REACHES A CUSTOMER'S DISK. Which concrete module
# this finds is Trident Port's own operating detail, kept out of the public
# report by decision — see the header of section H below, and the block
# comment over the INTERNAL section at the end of this file, which is the
# only place this function's raw output is ever printed, and only to a
# terminal fd, never to $OUT or $CSV.
# tp_exec_sh <ns> <pod> <container> <script>
# `exec ... sh -c`, with one addition: rc 127 when the container HAS NO SHELL
# (Trident's `trident-main` has none on OpenShift / 26.06, measured), so the
# caller can tell "no shell" apart from "the read failed".
tp_exec_sh() {
  _e=$(mktemp 2>/dev/null) || _e=/dev/null
  $K exec -n "$1" "$2" -c "$3" -- sh -c "$4" 2>"$_e"
  _rc=$?
  if [ "$_rc" -ne 0 ] && grep -qiE "executable file.*not found" "$_e" 2>/dev/null; then
    [ "$_e" = /dev/null ] || rm -f "$_e"; return 127
  fi
  [ "$_e" = /dev/null ] || rm -f "$_e"; return "$_rc"
}

# tp_exec_cat <ns> <pod> <container> <path>
# Reads one file with no shell. Prints it. rc 0 read, 2 file absent, 3 the
# container has no `cat` either (or anything else went wrong).
tp_exec_cat() {
  _e=$(mktemp 2>/dev/null) || _e=/dev/null
  $K exec -n "$1" "$2" -c "$3" -- cat "$4" 2>"$_e"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then _r=0
  elif grep -qi "no such file" "$_e" 2>/dev/null; then _r=2
  else _r=3; fi
  [ "$_e" = /dev/null ] || rm -f "$_e"
  return "$_r"
}

tp_block_mirror_probe() {
  _ns=$1; _pod=$2; _c=$3; _node=${4:-}
  _out=$(tp_exec_sh "$_ns" "$_pod" "$_c" '
    for m in dm_raid dm_mirror; do
      loaded=no
      [ -d "/sys/module/$m" ] && loaded=yes
      present=unknown
      if command -v chroot >/dev/null 2>&1; then
        hyphenated=$(printf "%s" "$m" | tr "_" "-")
        if chroot /host modinfo "$hyphenated" >/dev/null 2>&1; then
          present=yes
        else
          present=no
        fi
      fi
      printf "%s loaded=%s present=%s\n" "$m" "$loaded" "$present"
    done
  ')
  _rc=$?
  if [ "$_rc" -ne 127 ]; then printf '%s\n' "$_out" | sed '/^$/d'; return 0; fi
  # No shell. /proc/modules is the host kernel's list from any container.
  # It says what is LOADED; absence is never reported as "not available"
  # (present=unknown), because a module may load on first use.
  _mods=$(tp_exec_cat "$_ns" "$_pod" "$_c" /proc/modules)
  if [ $? -eq 0 ] && [ -n "$_mods" ]; then
    for _m in dm_raid dm_mirror; do
      if printf '%s\n' "$_mods" | awk -v m="$_m" '$1==m{f=1} END{exit !f}'; then
        printf '%s loaded=yes present=unknown\n' "$_m"
      else
        printf '%s loaded=no present=unknown\n' "$_m"
      fi
    done
    return 0
  fi
  # Last resort, only when asked: a temporary privileged pod on the node.
  if [ "${TP_NODE_DEBUG:-false}" = true ] && [ "$K" = oc ] && [ -n "$_node" ]; then
    _out=$(timeout 90 oc debug "node/$_node" --quiet -- chroot /host sh -c '
      for m in dm_raid dm_mirror; do
        loaded=no; [ -d "/sys/module/$m" ] && loaded=yes
        present=no
        modinfo "$(printf "%s" "$m" | tr _ -)" >/dev/null 2>&1 && present=yes
        printf "%s loaded=%s present=%s\n" "$m" "$loaded" "$present"
      done' 2>/dev/null)
    if [ -n "$_out" ]; then printf '%s\n' "$_out"; return 0; fi
  fi
  echo "nosh=unreadable"
}

# ============================================================================
sec "H. HOT BLOCK-CUTOVER — can this cluster's nodes run it"

echo "-- Live block migration, without moving a single block yet --"
echo "   A block claim can always migrate OFFLINE: stop the application, copy"
echo "   the device, start it on the new claim. Some engines let it move HOT"
echo "   instead — the application keeps writing to its existing claim while"
echo "   the data mirrors across, and the cutover itself is a brief pause"
echo "   rather than a copy window. Whether that is possible here is a fact"
echo "   about this cluster's own nodes, asked once, before anything is"
echo "   proposed — not a promise made and checked later."
echo "   Read from Trident's OWN node plugin, already running and already"
echo "   privileged: the same kind of read-only exec section F already"
echo "   performs against the controller. Nothing new is created."

TP_H_NS="${TRIDENT_NS:-trident}"
TP_H_PODS=$($K get pods -n "$TP_H_NS" -l app=node.csi.trident.netapp.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}' \
  2>/dev/null)

if [ -z "$TP_H_PODS" ]; then
  echo "   NOT CHECKED — no Trident node pod found (label"
  echo "   app=node.csi.trident.netapp.io, namespace $TP_H_NS). Either Trident"
  echo "   is not installed here yet, or its node plugin is not up; section A"
  echo "   already says which. Do not read this as 'not available' — nobody"
  echo "   could be asked."
else
  TP_H_RUNNING=$(echo "$TP_H_PODS" | awk -F'\t' '$3 == "Running"')
  TP_H_TOTAL=$(echo "$TP_H_PODS" | grep -c . || echo 0)
  TP_H_RUNNING_N=$(echo "$TP_H_RUNNING" | grep -c . || echo 0)
  TP_H_NOT_RUNNING=$((TP_H_TOTAL - TP_H_RUNNING_N))

  # A cap, not a shortcut taken for free. Querying every node is one
  # kubectl exec per node, and an estate can hold hundreds of them. The
  # kernel modules a node offers follow its OS image, and a node POOL
  # normally shares one image — so a sample answers the common case, and
  # every node past the cap is reported as UNMEASURED, never assumed to
  # match the ones that were.
  TP_H_CAP=20
  TP_H_SAMPLE=$(echo "$TP_H_RUNNING" | head -"$TP_H_CAP")
  TP_H_SAMPLE_N=$(echo "$TP_H_SAMPLE" | grep -c . || echo 0)

  [ "${TP_H_NOT_RUNNING:-0}" -gt 0 ] && {
    echo "   $TP_H_NOT_RUNNING node pod(s) are not Running and were skipped —"
    echo "   reported as unmeasured below, never as unavailable."
  }
  [ "${TP_H_RUNNING_N:-0}" -gt "${TP_H_SAMPLE_N:-0}" ] && {
    echo "   $TP_H_RUNNING_N node(s) run the plugin and are Running; only the"
    echo "   first $TP_H_CAP were queried, to bound this run's time. The rest"
    echo "   are UNMEASURED, not assumed."
  }

  TP_H_YES=0; TP_H_NO=0; TP_H_UNKNOWN=0
  while IFS=$'\t' read -r TP_H_POD TP_H_NODE TP_H_PHASE; do
    [ -n "$TP_H_POD" ] || continue
    TP_H_RAW=$(tp_block_mirror_probe "$TP_H_NS" "$TP_H_POD" trident-main "$TP_H_NODE")
    if [ -z "$TP_H_RAW" ]; then
      printf '   %-40s UNKNOWN — the node pod did not answer\n' "$TP_H_NODE"
      TP_H_UNKNOWN=$((TP_H_UNKNOWN + 1))
    elif echo "$TP_H_RAW" | grep -q 'nosh=unreadable'; then
      printf '   %-40s UNKNOWN — the node pod has no shell to read with\n' "$TP_H_NODE"
      TP_H_UNKNOWN=$((TP_H_UNKNOWN + 1))
      TP_H_NEEDS_DEBUG=yes
    elif echo "$TP_H_RAW" | grep -qE 'loaded=yes|present=yes'; then
      printf '   %-40s available\n' "$TP_H_NODE"
      TP_H_YES=$((TP_H_YES + 1))
    elif echo "$TP_H_RAW" | grep -q 'present=unknown'; then
      printf '   %-40s UNKNOWN — not loaded now; the node pod cannot look further\n' "$TP_H_NODE"
      TP_H_UNKNOWN=$((TP_H_UNKNOWN + 1))
    else
      printf '   %-40s not available\n' "$TP_H_NODE"
      TP_H_NO=$((TP_H_NO + 1))
    fi
  done <<TP_H_LOOP
$TP_H_SAMPLE
TP_H_LOOP

  echo
  if [ "$TP_H_NO" -gt 0 ]; then
    echo "   *** AT LEAST ONE NODE CANNOT RUN A HOT BLOCK-CUTOVER ***"
    echo "     Block claims scheduled there still migrate — offline, the same"
    echo "     way every block claim migrates today. A hot cutover is not an"
    echo "     option on that node until this is looked at."
  elif [ "$TP_H_YES" -gt 0 ] && [ "$TP_H_UNKNOWN" -eq 0 ]; then
    echo "   every node checked can run a hot block-cutover."
  fi
  [ -n "${TP_H_NEEDS_DEBUG:-}" ] && {
    echo "   The node plugin container has no shell. By hand, per node:"
    echo "     oc debug node/<node> -- chroot /host sh -c 'grep -E \"^(dm_raid|dm_mirror) \" /proc/modules; ls -d /sys/module/dm_raid /sys/module/dm_mirror'"
    if [ "$K" = oc ]; then
      echo "   Or re-run with --node-debug: it creates a temporary privileged"
      echo "   pod on each node (oc deletes it on exit)."
    fi
  }
  [ "${TP_H_UNKNOWN:-0}" -gt 0 ] && {
    echo "   $TP_H_UNKNOWN node(s) UNKNOWN. Read as 'not checked', never as"
    echo "   'not available' — the node pod may lack a shell utility this read"
    echo "   needs, which says nothing about the kernel underneath it."
  }
fi

# ============================================================================
# tp_hostnqn_path_probe <namespace> <pod> <container>
#
# Measured on a lab cluster: hostPID: true on the node plugin means its
# usual /host bind mount never happens, so the hostNQN it looks for under
# /host/etc/nvme/hostnqn is really at /etc/nvme/hostnqn. Upstream Trident bug.
# Read-only exec, same class of read as tp_block_mirror_probe.
tp_hostnqn_path_probe() {
  _ns=$1; _pod=$2; _c=$3
  _out=$(tp_exec_sh "$_ns" "$_pod" "$_c" '
    nvme_dir=no
    [ -d /etc/nvme ] && nvme_dir=yes
    real=no
    [ -f /etc/nvme/hostnqn ] && real=yes
    hostprefixed=no
    [ -f /host/etc/nvme/hostnqn ] && hostprefixed=yes
    printf "nvme_dir=%s real=%s hostprefixed=%s\n" "$nvme_dir" "$real" "$hostprefixed"
  ')
  _rc=$?
  if [ "$_rc" -ne 127 ]; then printf '%s\n' "$_out" | sed '/^$/d'; return 0; fi
  # No shell: read the two files with `cat`. Both absent is ambiguous (no
  # NVMe here, or no hostnqn yet), so it is not answered.
  tp_exec_cat "$_ns" "$_pod" "$_c" /etc/nvme/hostnqn >/dev/null; _r1=$?
  tp_exec_cat "$_ns" "$_pod" "$_c" /host/etc/nvme/hostnqn >/dev/null; _r2=$?
  if [ "$_r1" -eq 3 ] || [ "$_r2" -eq 3 ] || { [ "$_r1" -eq 2 ] && [ "$_r2" -eq 2 ]; }; then
    echo "nosh=unreadable"; return 0
  fi
  _real=no; [ "$_r1" -eq 0 ] && _real=yes
  _hp=no; [ "$_r2" -eq 0 ] && _hp=yes
  echo "nvme_dir=yes real=$_real hostprefixed=$_hp"
}

# ============================================================================
sec "I. HOSTNQN PATH CONVENTION"

echo "-- Whether Trident can find this node's hostNQN, before anything is built --"
echo "   Trident's node plugin reads NVMe-TCP's hostNQN from a path prefixed"
echo "   with /host, assuming a bind mount of the host root into its own"
echo "   container. hostPID: true on that plugin means the bind mount never"
echo "   happens. Upstream Trident bug, not fixed here — this only says the"
echo "   RISK CONDITION is present, before Trident provisions anything over"
echo "   NVMe-TCP. Definitive answer, once deployed: TridentNode.spec.nqn,"
echo "   which tp plan already reads and warns on when empty."

if [ -z "${TP_H_PODS:-}" ]; then
  echo "   NOT CHECKED — no Trident node pod found (section H already said"
  echo "   why). Nobody could be asked."
else
  TP_I_FLAGGED=0; TP_I_UNKNOWN=0
  while IFS=$'\t' read -r TP_I_POD TP_I_NODE TP_I_PHASE; do
    [ -n "$TP_I_POD" ] || continue
    TP_I_HOSTPID=$($K get pod "$TP_I_POD" -n "$TP_H_NS" -o jsonpath='{.spec.hostPID}' 2>/dev/null)
    TP_I_RC=$?
    if [ "$TP_I_RC" -ne 0 ]; then
      printf "   %-40s UNKNOWN -- could not read this pod's own spec\n" "$TP_I_NODE"
      TP_I_UNKNOWN=$((TP_I_UNKNOWN + 1))
    elif [ "$TP_I_HOSTPID" != "true" ]; then
      printf "   %-40s hostPID: false -- the /host convention applies normally here\n" "$TP_I_NODE"
    else
      TP_I_RAW=$(tp_hostnqn_path_probe "$TP_H_NS" "$TP_I_POD" trident-main)
      if [ -z "$TP_I_RAW" ]; then
        printf "   %-40s UNKNOWN -- hostPID: true, and the node pod did not answer\n" "$TP_I_NODE"
        TP_I_UNKNOWN=$((TP_I_UNKNOWN + 1))
      elif echo "$TP_I_RAW" | grep -q 'nosh=unreadable'; then
        # The definitive answer needs no exec: Trident registers the hostNQN
        # it found on the TridentNode of that node.
        TP_I_NQN=$($K get tridentnodes.trident.netapp.io "$TP_I_NODE" -n "$TP_H_NS" -o jsonpath='{.spec.nqn}' 2>/dev/null)
        if [ -n "$TP_I_NQN" ]; then
          printf "   %-40s hostPID: true -- TridentNode.spec.nqn is set; Trident found a hostNQN here\n" "$TP_I_NODE"
        else
          printf "   %-40s UNKNOWN -- hostPID: true, no shell in the node pod, TridentNode.spec.nqn empty or absent\n" "$TP_I_NODE"
          TP_I_UNKNOWN=$((TP_I_UNKNOWN + 1))
        fi
      elif echo "$TP_I_RAW" | grep -q 'nvme_dir=no'; then
        printf "   %-40s hostPID: true, but no NVMe support here -- the convention does not apply\n" "$TP_I_NODE"
      elif echo "$TP_I_RAW" | grep -q 'real=yes' && echo "$TP_I_RAW" | grep -q 'hostprefixed=no'; then
        printf "   %-40s *** hostPID: true -- /etc/nvme/hostnqn exists, /host/etc/nvme/hostnqn does not ***\n" "$TP_I_NODE"
        TP_I_FLAGGED=$((TP_I_FLAGGED + 1))
      else
        printf "   %-40s hostPID: true, and /host/etc/nvme/hostnqn exists too -- the convention matches here\n" "$TP_I_NODE"
      fi
    fi
  done <<TP_I_LOOP
$TP_H_SAMPLE
TP_I_LOOP

  echo
  if [ "${TP_I_FLAGGED:-0}" -gt 0 ]; then
    echo "   *** THIS DEPLOYMENT USES hostPID; TRIDENT MAY NOT CALCULATE A HOSTNQN ***"
    echo "     This does not mean NVMe-TCP will fail on every node named above"
    echo "     — the risk condition is present. Confirm it against"
    echo "     TridentNode.spec.nqn once deployed, with tp plan."
  fi
  [ "${TP_I_UNKNOWN:-0}" -gt 0 ] && {
    echo "   $TP_I_UNKNOWN node(s) UNKNOWN. Read as 'not checked', never as"
    echo "   'the convention matches' -- the read may have failed."
  }
  [ "${TP_I_FLAGGED:-0}" -eq 0 ] && [ "${TP_I_UNKNOWN:-0}" -eq 0 ] && {
    echo "   no node checked shows the risk condition."
  }
fi


hr
echo "  report:  $OUT"
echo "  csv:     $CSV   (one row per claim, for planning waves)"
[ -f "$INV_JSON" ] && echo "  json:    $INV_JSON   (the raw inventory)"
[ -f "$INV_MD" ] && echo "  summary: $INV_MD   (read this first: the risks, on top)"
# the report is still being flushed through tee; give it a moment, then bundle
sync; sleep 1
TP_BUNDLE=""
for f in "$OUT" "$CSV" "$INV_JSON" "$INV_MD"; do [ -f "$f" ] && TP_BUNDLE="$TP_BUNDLE $f"; done
# shellcheck disable=SC2086
if tar czf "$TGZ" $TP_BUNDLE 2>/dev/null; then
  echo "  SEND:    $TGZ   ($(du -h "$TGZ" | cut -f1))"
else
  echo "  could not build $TGZ - send the files above one by one"
fi
echo "  and nothing else was written to this machine."
hr

# ============================================================================
# ============================================================================
# The destination design is OURS, and it does not go in the report the
# customer reads. They get the inventory of their own estate; what we would
# build with it is a proposal, and a proposal shown before it is decided
# invites a conversation about our internals instead of about their data.
#
# IT USED TO BE A THIRD FILE, labelled "INTERNAL. Not for the customer." —
# written into the working directory of a machine that is theirs. The label
# was the whole protection, and a label on a file sitting on somebody else's
# disk protects nothing: the moment it is written, they have it. It is
# exactly the kind of control this product exists to argue against, one that
# reads as protection and is not.
#
# So it goes to fd 3, which was saved before stdout was teed into the report:
# it appears on the terminal of whoever is running this, is in neither of the
# two files, and touches no disk. Everything below the marker can be selected
# in one go and pasted into the working notes on our side, which is where the
# destination gets designed — the customer gets the finished plan afterwards,
# not the reasoning that produced it.
if $TP_PRINT_INTERNAL; then
exec 1>&3 2>&3
{
echo
echo "════════ BEGIN INTERNAL — COPY THIS NOW, IT IS NOT ON DISK ══════"
echo "  INTERNAL — the destination we would build"
echo "  NOT for the customer. This is a proposal, not an inventory."
echo "  Printed on this terminal only, and written to no file, because"
echo "  this machine is theirs."
echo "════════════════════════════════════════════════════════════════"
echo
echo "-- Every shape in the estate, and what can serve it --"
if $HAVE_JQ; then
  $K get pvc -A -o json 2>/dev/null | jq -r '
    [.items[]? | {
       sc: (.spec.storageClassName // "-"),
       mode: (.spec.volumeMode // "Filesystem"),
       access: (if ((.spec.accessModes // []) | index("ReadWriteMany")) != null
                then "RWX" elif ((.spec.accessModes // []) | index("ReadOnlyMany")) != null
                then "ROX" else "RWO" end)
     }]
    | group_by([.sc, .mode, .access])[]
    | "   \(.[0].sc)  \(.[0].mode)/\(.[0].access)  x\(length)  -> " +
      # The MODE is asked first. Asking about access first said "ontap-nas"
      # for a Block/RWX claim, which is confidently wrong: a NAS class
      # cannot serve a raw device at all, whatever its access mode.
      (if .[0].mode == "Block" and .[0].access == "RWX" then
         "ontap-san, SHARED RAW LUN — confirm it. Rare, and a NAS class cannot serve it"
       elif .[0].mode == "Block" then
         "ontap-san   (a raw device needs a LUN; a NAS class would change its shape)"
       elif .[0].access == "RWX" then
         "ontap-nas   (a shared filesystem; SAN cannot serve it)"
       else
         "ontap-nas or ontap-san   (either serves RWO Filesystem)"
       end)'
  echo
  echo "-- Therefore, the destination classes needed --"
  $K get pvc -A -o json 2>/dev/null | jq -r '
    [.items[]? | {
       sc: (.spec.storageClassName // "-"),
       driver: (if (.spec.volumeMode // "Filesystem") == "Block"
                then "ontap-san"
                elif ((.spec.accessModes // []) | index("ReadWriteMany")) != null
                then "ontap-nas" else "ontap-nas" end),
       bytes: ((.status.capacity.storage // .spec.resources.requests.storage // "0")
               | capture("(?<n>[0-9.]+)(?<u>[A-Za-z]*)")
               | (.n | tonumber) * (
                   if .u == "Ki" then 1024 elif .u == "Mi" then 1048576
                   elif .u == "Gi" then 1073741824 elif .u == "Ti" then 1099511627776
                   else 1 end))
     }]
    | group_by([.sc, .driver])[]
    | "   from \(.[0].sc)  ->  one \(.[0].driver) class"
      + "   (\(length) claims, \((map(.bytes) | add) / 1073741824 | floor) GiB)"'
  echo
  echo "   One destination class per (source class, driver) pair. That is what"
  echo "   --sc-map expresses, and it is why they cannot be collapsed: a"
  echo "   namespace holding both shapes needs both, mapped separately."
fi
echo
echo "-- Block-mirror engine, per node (raw, ours only) --"
echo "   Section H already told the customer yes/no/unknown. This is WHICH"
echo "   engine, re-read fresh rather than cached, because a name kept in a"
echo "   variable from section H is a name one accidental echo away from"
echo "   the customer's file — recomputed here instead, same as every other"
echo "   line in this block."
if [ -n "${TP_H_NS:-}" ] && [ -n "${TP_H_SAMPLE:-}" ]; then
  while IFS=$'\t' read -r TP_HI_POD TP_HI_NODE TP_HI_PHASE; do
    [ -n "$TP_HI_POD" ] || continue
    TP_HI_RAW=$(tp_block_mirror_probe "$TP_H_NS" "$TP_HI_POD" trident-main)
    echo "   $TP_HI_NODE"
    if [ -n "$TP_HI_RAW" ]; then
      echo "$TP_HI_RAW" | sed 's/^/     /'
    else
      echo "     (no answer from the node pod)"
    fi
  done <<TP_HI_LOOP
$TP_H_SAMPLE
TP_HI_LOOP
else
  echo "   not checked in this run — section H found no Trident node pod to"
  echo "   ask (Trident not installed, or its node plugin not up)."
fi
echo
echo "-- Prefixes already in use (the new one must not collide) --"
TP_PFX=$({
  $K get tbc -n trident -o jsonpath='{range .items[*]}{.spec.storagePrefix}{"\n"}{end}' 2>/dev/null
  $K exec -n trident deploy/trident-controller -c trident-main -- tridentctl get backend -o json 2>/dev/null \
    | { $HAVE_JQ && jq -r '.items[]? | select((.config.storagePrefix|type) == "string") | .config.storagePrefix' || true; } 2>/dev/null
} | sed '/^[[:space:]]*$/d' | sort -u)
if [ -n "$TP_PFX" ]; then echo "$TP_PFX" | sed 's/^/   /'
else echo "   (none set; Trident's default applies)"; fi
echo
cat <<'DRAFT'
-- The drafts --

   # One TridentBackendConfig per DRIVER above, not per source class.
   apiVersion: trident.netapp.io/v1
   kind: TridentBackendConfig
   metadata: {name: backend-nas-new, namespace: trident}
   spec:
     version: 1
     backendName: nas-new
     storageDriverName: ontap-nas          # ontap-san where the table says so
     managementLIF: <dest-mgmt-lif>
     dataLIF: <dest-data-lif>
     svm: <dest-svm>
     storagePrefix: <new-prefix>_
     credentials: {name: <secret-name>}
   ---
   # One StorageClass per (source class, driver) pair, so --sc-map is
   # one-to-one and a mixed namespace can send its shapes to different
   # destinations.
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata: {name: sc-nas-new}
   provisioner: csi.trident.netapp.io
   parameters: {backendType: ontap-nas}
   reclaimPolicy: Retain                   # Retain, not Delete: the way back
   allowVolumeExpansion: true
DRAFT
echo "════════ END INTERNAL — nothing above this was written down ═════"
}
fi
