# Runtime observability with Tetragon (Module 6)

Tetragon adds eBPF-based runtime visibility - process execution and network activity - for
the migrated namespace. It is installed **observe-only**: it reports events, it does not kill
processes or block traffic, so it cannot affect the running workloads. It coexists with Cilium
(both use eBPF).

## Install

```bash
./scripts/05-install-tetragon.sh        # helm upgrade --install tetragon cilium/tetragon -n kube-system
kubectl apply -f tetragon/tracingpolicy.yaml
```

## What's monitored

- Process exec/exit - captured by Tetragon's base sensors for every pod (no policy needed).
  Captured live in the k3d lab (see [`sample-events.txt`](./sample-events.txt)): JVM start and
  an injected shell + `curl`/`nc`/`id` in the distroless app pod.
- Outbound TCP connections - added by [`tracingpolicy.yaml`](./tracingpolicy.yaml) (a
  `tcp_connect` kprobe), reporting the destination of each connection attempt. The k3d lab
  loaded the kprobe but did not emit events on that kernel; on the live AKS cluster
  (Ubuntu 22.04) the kprobe delivers the full socket - see [`aks-events.json`](./aks-events.json):
  ```
  function_name: tcp_connect    policy_name: monitor-egress-connect
  saddr 10.244.1.125 -> daddr 20.205.243.168:443   state TCP_SYN_SENT
  pod: petclinic/petclinic-769ff69c9d-4xvtc        node: aks-system-...-vmss000001
  ```

## Capture events

```bash
# stream compact events for the namespace
kubectl -n kube-system exec ds/tetragon -c tetragon -- \
  tetra getevents -o compact --namespace petclinic
```
Sample capture: [`sample-events.txt`](./sample-events.txt).

## How this supports the migration

- Post-migration hypercare: a baseline of "normal" process + egress behavior on AKS. Any new
  binary, shell, or destination after cutover is immediately visible - the fastest way to catch a
  regression or misconfig in the first days on the new platform.
- Incident triage: full process ancestry (binary, args, UID, pod, container) and the exact
  outbound connection for an event, so an alert becomes an actionable timeline instead of a guess.
- Policy tuning: observed egress destinations feed straight back into the Cilium FQDN
  allowlist ([`../kubernetes/network/40-cilium-egress-fqdn.yaml`](../kubernetes/network/40-cilium-egress-fqdn.yaml))
  and the Azure Firewall rules - observe first, then tighten.

## Escalation rules (what to alert/act on)

| Signal | Why it matters | Action |
|---|---|---|
| **Unexpected shell exec** (`/bin/sh`, `/bin/bash`) in the app pod | distroless app has no shell - a shell means an interactive intrusion or debug container | page on-call; in enforce mode, `Sigkill` |
| **Unexpected egress** - connect to an IP/FQDN not in the allowlist | data exfil or C2; Cilium already blocks it, Tetragon attributes *which process* tried | correlate with Cilium drop; investigate the process |
| **Privilege escalation** - `setuid`/`setgid`, capability changes | container breakout attempt | high-severity page; quarantine the node/pod |
| **Suspicious binary** - `curl`/`wget`/`nc`/package managers in the runtime pod | download-and-run tooling that shouldn't exist in a hardened image | alert; review image + admission policy |

**Enforcement option (not enabled):** any rule above can move from observe to block by adding a
selector with `matchActions: [{action: Sigkill}]` to the TracingPolicy. Left off here so it
cannot impact running services; on AKS it would be enabled in a staged rollout after the
observe baseline is trusted.
