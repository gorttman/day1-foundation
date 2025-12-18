#!/bin/bash
# Remove finalizers to allow deletion
kubectl patch app influxdb -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge

# Or edit and remove finalizers manually
kubectl edit app influxdb -n argocd

# Then delete
kubectl delete app influxdb -n argocd

