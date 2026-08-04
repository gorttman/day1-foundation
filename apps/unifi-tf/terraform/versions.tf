terraform {
  required_version = ">= 1.7.0"

  required_providers {
    unifi = {
      source  = "filipowm/unifi"
      version = "~> 1.0"
    }
  }

  # State backend: shared Postgres instance (postgres.postgres.svc.cluster.local),
  # database "unifi_tf", owned by role "unifi_tf" - see README.md, same
  # pattern as apps/cloudflare-tf. conn_str is partial config, supplied at
  # `terraform init` via -backend-config from the TF_BACKEND_PG_CONN_STR
  # secret, never committed here.
  backend "pg" {}
}

provider "unifi" {
  api_url = var.unifi_api_url
  api_key = var.unifi_api_key

  # The Dream Machine's local controller API serves a self-signed cert -
  # same situation as qnap's origin override in cloudflare-tf/tunnel.tf.
  allow_insecure = true

  # Provisional: api_key is the preferred auth method (requires firmware
  # >= 9.0.108, see variables.tf). If the running firmware turns out to
  # be older, swap this block to `username = var.unifi_username` /
  # `password = var.unifi_password` instead - those variables already
  # exist for that fallback but aren't wired in here yet, since which
  # auth method actually applies isn't confirmed until the firmware
  # version is checked (see README.md).
}
