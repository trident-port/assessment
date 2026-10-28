# Trident Port assessment

`tp-pre.sh` is a read-only inventory of a Kubernetes or OpenShift cluster. It is
the first step of planning a move of persistent volumes to NetApp Trident. It
produces a report; you send us the report; nothing is installed.

Version: v1.2.2

## What it does

- Lists the storage in the cluster: StorageClasses, claims (PVCs), volumes,
  which workloads use them, how big they are, and which database or platform
  operators are involved.
- Checks what the cluster would need to run a migration (snapshots, node
  settings, Trident if present).
- Writes a few files in the directory where you run it, and one archive.

## What it does NOT do

- It does not change, create, patch, scale or delete anything in the cluster.
- It does not read Secrets, ConfigMap contents, environment variable values, or
  anything inside your volumes. Only the shape: names, sizes, classes, counts.
- It does not send anything anywhere. You decide what to return.
- It never writes to a storage array. If you give it array credentials it
  makes GET requests only; without them that part is skipped.

Two reads go through running pods, and change nothing: `kubectl exec` runs
`tridentctl get` on the Trident controller and reads kernel-module state
through the Trident node plugin.

Options that do more are **off unless you ask**:

| Option | What it adds |
|---|---|
| `--probe-pull` | Creates one throwaway pod, `tp-pull-probe`, to test an image pull, then deletes it. This is the only option that creates an object. |
| `--count-files` | Counts files per claim with a bounded read-only `find`, run with `kubectl exec` in the pod that already mounts the claim. |
| `--node-debug` | OpenShift only: reads a node through a temporary `oc debug node` pod, which `oc` removes on exit. |

## Requirements

- `bash`, `python3`, and `kubectl` (or `oc`) already logged in to the cluster.
- `jq` is optional; some sections are shorter without it.
- A read-only account is enough. A section the account cannot read says
  `unknown: forbidden (...)` instead of failing.

## Run it

```sh
curl -fsSLO https://raw.githubusercontent.com/trident-port/assessment/main/tp-pre.sh
curl -fsSLO https://raw.githubusercontent.com/trident-port/assessment/main/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
bash tp-pre.sh
```

The script is a plain text file: read it before you run it. To limit it to some
namespaces, use `-n prod-a,prod-b`.

To include the array, set its address and account:
`ONTAP_MGMT_LIF=<address> ONTAP_USER=<user> bash tp-pre.sh`
The script asks for the password on the terminal and does not show it. It is
never placed on the command line.

## What to send back

The archive `tp-pre-<context>-<date>.tgz` in the current directory. It holds
the report (`.txt`), the planning table (`.csv`), and the machine-readable
inventory (`.json`) with its summary (`.md`). Open them first if you want to
check what leaves.

## Options

```text
-n, --namespaces a,b   only these namespaces (default: every namespace with a claim)
--no-internal          do not print the last section on the terminal
--count-files          also count files per claim
--probe-pull           also test an image pull (creates and deletes one pod)
--read-timeout N       seconds allowed to each batch read (default 300)
--node-debug           oc only: read nodes through a temporary debug pod
-h, --help             show the header of the script
```

## License

License: see `LICENSE` (all rights reserved).
