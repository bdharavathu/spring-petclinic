#!/usr/bin/env python3
"""Inventory the workloads in a namespace and the dependencies we need to migrate.

Reads live state via kubectl and writes workload_inventory.{json,csv}. Secret and
ConfigMap keys are recorded, never their values.

    ./k8s_inventory_crawler.py            # namespace 'petclinic'
    ./k8s_inventory_crawler.py -n foo
    ./k8s_inventory_crawler.py -A
"""
import argparse
import csv
import json
import re
import subprocess
import sys

WORKLOAD_KINDS = ["deployments", "statefulsets", "daemonsets", "jobs", "cronjobs"]
EXTRA_KINDS = ["services", "ingress", "configmaps", "secrets", "pvc",
               "serviceaccounts", "networkpolicies"]

DB_RE = re.compile(r"jdbc:\w+:|(?:postgresql|mysql|mongodb(?:\+srv)?|sqlserver|redis)://"
                   r"|:(?:5432|3306|1433|27017|6379)\b", re.I)
URL_RE = re.compile(r"https?://[^\s\"']+")
JAVA_IMAGES = ("temurin", "openjdk", "jdk", "jre")
RUNTIME_NAMES = ("postgres", "mysql", "mongo", "redis", "nginx", "node", "python", "dotnet")


def kubectl(kind, scope):
    out = subprocess.run(["kubectl", "get", kind, "-o", "json", *scope],
                         capture_output=True, text=True)
    if out.returncode:
        print(f"warn: skipping {kind}: {out.stderr.strip()}", file=sys.stderr)
        return []
    return json.loads(out.stdout)["items"]


def runtime_of(image):
    image = image.lower()
    if any(j in image for j in JAVA_IMAGES):
        return "java"
    return next((n for n in RUNTIME_NAMES if n in image), "unknown")


def pod_spec(obj):
    spec = obj["spec"]
    if obj["kind"] == "CronJob":
        return spec["jobTemplate"]["spec"]["template"]["spec"]
    return spec.get("template", {}).get("spec", {})


def workload_rows(obj, configmap_values):
    ns, name, kind = obj["metadata"]["namespace"], obj["metadata"]["name"], obj["kind"]
    spec, ps = obj["spec"], pod_spec(obj)

    pvcs = [v["persistentVolumeClaim"]["claimName"]
            for v in ps.get("volumes", []) if "persistentVolumeClaim" in v]
    pvcs += [f"{t['metadata']['name']} (vct)" for t in spec.get("volumeClaimTemplates", [])]

    rows = []
    for c in ps.get("containers", []):
        env = c.get("env", [])
        secrets, configmaps, values = set(), set(), []
        for e in env:
            if e.get("value"):
                values.append(e["value"])
            ref = e.get("valueFrom", {})
            if "secretKeyRef" in ref:
                secrets.add(ref["secretKeyRef"]["name"])
            if "configMapKeyRef" in ref:
                configmaps.add(ref["configMapKeyRef"]["name"])
        for ref in c.get("envFrom", []):
            if "secretRef" in ref:
                secrets.add(ref["secretRef"]["name"])
            if "configMapRef" in ref:
                cm = ref["configMapRef"]["name"]
                configmaps.add(cm)
                values += configmap_values.get((ns, cm), {}).values()
        for v in ps.get("volumes", []):
            if "secret" in v:
                secrets.add(v["secret"]["secretName"])
            if "configMap" in v:
                configmaps.add(v["configMap"]["name"])

        res = c.get("resources", {})
        req, lim = res.get("requests", {}), res.get("limits", {})
        rows.append({
            "namespace": ns, "kind": kind, "name": name, "container": c["name"],
            "image": c.get("image", ""), "runtime": runtime_of(c.get("image", "")),
            "replicas": spec.get("replicas"),
            "ports": [p["containerPort"] for p in c.get("ports", [])],
            "env_keys": [e["name"] for e in env],
            "secrets": sorted(secrets), "configmaps": sorted(configmaps), "pvcs": pvcs,
            "service_account": ps.get("serviceAccountName"),
            "databases": sorted({v for v in values if DB_RE.search(v)}),
            "external_urls": sorted(set(URL_RE.findall(" ".join(values)))),
            "requests": {"cpu": req.get("cpu"), "memory": req.get("memory")},
            "limits": {"cpu": lim.get("cpu"), "memory": lim.get("memory")},
            "probes": [p for p in ("liveness", "readiness", "startup")
                       if c.get(f"{p}Probe")],
        })
    return rows


def summarize(kind, items):
    rows = []
    for it in items:
        m = it["metadata"]
        row = {"namespace": m["namespace"], "name": m["name"]}
        spec = it.get("spec", {})
        if kind == "services":
            row["type"] = spec.get("type", "ClusterIP")
            row["ports"] = [f"{p.get('port')}->{p.get('targetPort')}" for p in spec.get("ports", [])]
        elif kind == "ingress":
            row["hosts"] = [r.get("host") for r in spec.get("rules", [])]
        elif kind in ("secrets", "configmaps"):
            row["keys"] = sorted((it.get("data") or {}).keys())  # keys only
            if kind == "secrets":
                row["type"] = it.get("type")
        elif kind == "pvc":
            row["storage"] = spec.get("resources", {}).get("requests", {}).get("storage")
        rows.append(row)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-n", "--namespace", default="petclinic")
    ap.add_argument("-A", "--all-namespaces", action="store_true")
    ap.add_argument("--prefix", default="workload_inventory")
    args = ap.parse_args()
    scope = ["-A"] if args.all_namespaces else ["-n", args.namespace]

    raw = {kind: kubectl(kind, scope) for kind in WORKLOAD_KINDS + EXTRA_KINDS}

    configmap_values = {(c["metadata"]["namespace"], c["metadata"]["name"]): c.get("data") or {}
                        for c in raw["configmaps"]}

    workloads = []
    for kind in WORKLOAD_KINDS:
        for obj in raw[kind]:
            workloads += workload_rows(obj, configmap_values)

    inventory = {
        "workloads": workloads,
        "resources": {k: summarize(k, raw[k]) for k in EXTRA_KINDS},
        "totals": {k: len(raw[k]) for k in EXTRA_KINDS} | {"workload_containers": len(workloads)},
    }

    with open(f"{args.prefix}.json", "w") as f:
        json.dump(inventory, f, indent=2, default=str)

    fields = ["namespace", "kind", "name", "container", "image", "runtime", "replicas",
              "ports", "env_keys", "databases", "external_urls", "secrets", "configmaps",
              "pvcs", "service_account", "cpu_req", "mem_req", "cpu_lim", "mem_lim", "probes"]
    with open(f"{args.prefix}.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for wl in workloads:
            w.writerow({
                **{k: wl[k] for k in ("namespace", "kind", "name", "container", "image",
                                      "runtime", "replicas", "service_account")},
                "ports": ";".join(map(str, wl["ports"])),
                "env_keys": len(wl["env_keys"]),
                "databases": ";".join(wl["databases"]),
                "external_urls": ";".join(wl["external_urls"]),
                "secrets": ";".join(wl["secrets"]),
                "configmaps": ";".join(wl["configmaps"]),
                "pvcs": ";".join(wl["pvcs"]),
                "cpu_req": wl["requests"]["cpu"], "mem_req": wl["requests"]["memory"],
                "cpu_lim": wl["limits"]["cpu"], "mem_lim": wl["limits"]["memory"],
                "probes": ";".join(wl["probes"]),
            })

    print(f"{len(workloads)} workload containers, "
          + ", ".join(f"{len(raw[k])} {k}" for k in EXTRA_KINDS))


if __name__ == "__main__":
    main()
