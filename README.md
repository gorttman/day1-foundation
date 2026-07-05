# pi-lab-day1

## Node labels and workload affinity

Two label conventions steer scheduling on the cluster:

- **`lane`** - coarse role split. `k8smaster` is `lane=infrastructure`
  (control plane, NFS, DNS plumbing); worker Pis are `lane=applications`.
  k8smaster never carries workload-affinity labels.
- **`workload-affinity/<app>=primary`** - names the node an app *prefers*
  to run on. Apps express this with a soft
  `preferredDuringSchedulingIgnoredDuringExecution` node affinity
  (weight 100 for `primary`, weight 50 for an optional `secondary`
  value on the same key) - never `requiredDuringScheduling`, so pods
  still schedule somewhere if the preferred node is down. The reusable
  patch template lives in day2-services under
  `components/workload-affinity/`.

Labels are applied by Ansible, not ad-hoc kubectl:
[`ansible/label-nodes.yml`](ansible/label-nodes.yml) holds the desired
app-to-node map and converges the cluster to it (adds and removes labels)
on each run:

```
sudo ansible-playbook ansible/label-nodes.yml   # on k8smaster, from repo root
```

Currently `immich`, `paperless` and `nextcloud` all point at `pinode-01`
because it is the only applications node - that is expected.

**Adding a new applications Pi later:** edit the `workload_affinity` map
in the playbook (move an app's `primary:` to the new node, optionally set
`secondary:`), add the node to `cluster_nodes`, and re-run the playbook.
It relabels the nodes and strips the old ones; **no app manifests change**
because manifests only ever reference the label key, never a hostname.
