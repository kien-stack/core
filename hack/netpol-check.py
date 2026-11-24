#!/usr/bin/env python3
"""CI guard: every NetworkPolicy podSelector rendered by a component must match at least one pod template
of the same component (catches label changes after a chart upgrade). Usage: netpol-check.py rendered.yaml...
Pods created by operators (CloudNativePG instances, ClickHouse) are not in the Helm output: list their
labels in OPERATOR_LABELS to accept them."""
import sys, yaml

# Some charts render a bare "=" (YAML value tag), unknown to SafeLoader: read it as a string.
class Loader(yaml.SafeLoader):
    pass
Loader.add_constructor("tag:yaml.org,2002:value", Loader.construct_yaml_str)

OPERATOR_LABELS = [{"cnpg.io/podRole": "instance"}]

def pod_labels(doc):
    k = doc.get("kind")
    spec = doc.get("spec") or {}
    if k in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        return ((spec.get("template") or {}).get("metadata") or {}).get("labels") or {}
    if k == "CronJob":
        t = ((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}
        return (t.get("metadata") or {}).get("labels") or {}
    if k == "Pod":
        return (doc.get("metadata") or {}).get("labels") or {}
    return None

fail = 0
for path in sys.argv[1:]:
    docs = [d for d in yaml.load_all(open(path), Loader=Loader) if isinstance(d, dict)]
    pods = [l for l in (pod_labels(d) for d in docs) if l is not None] + OPERATOR_LABELS
    for d in docs:
        # Only ours (templates/networkpolicy.yaml); upstream charts may target pods created at runtime.
        if d.get("kind") != "NetworkPolicy" or not d["metadata"]["name"].startswith("allow-"):
            continue
        sel = ((d.get("spec") or {}).get("podSelector") or {}).get("matchLabels") or {}
        if not sel:
            continue
        if not any(all(p.get(k) == v for k, v in sel.items()) for p in pods):
            print(f"FAIL {path}: NetworkPolicy {d['metadata']['name']} selects {sel}, no pod has these labels")
            fail = 1
print("netpol-check:", "FAIL" if fail else "OK")
sys.exit(fail)
