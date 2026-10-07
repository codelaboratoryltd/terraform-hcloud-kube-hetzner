/*
 * Layers a pinned k3s binary and install script onto an EXISTING MicroOS
 * snapshot, so autoscaled nodes can join the cluster without reaching
 * get.k3s.io or GitHub at boot (see var.autoscaler_k3s_preinstalled).
 *
 * It starts from a snapshot rather than from the upstream qcow2 on purpose:
 * hcloud-microos-snapshots.pkr.hcl pulls whatever Tumbleweed is current, so a
 * rebuild would also change the OS and kernel under every new node. This
 * template adds only the two k3s files, plus the incidental state of one boot
 * (a cloud-init instance dir, logs, leases) that each node's first boot
 * supersedes anyway.
 *
 * The checksums pin against corruption and silent re-tagging; the binary's
 * sha256 comes from the same GitHub release, so this is trust-on-first-use,
 * not signature verification.
 *
 * One run builds BOTH architectures from the same k3s_version, so the x86 and
 * ARM snapshots cannot drift apart (the module refuses to plan if they do):
 *   HCLOUD_TOKEN=... packer init  hcloud-microos-k3s-preinstalled.pkr.hcl
 *   HCLOUD_TOKEN=... packer build \
 *     -var 'base_snapshot_ids={x86="<x86 id>",arm="<arm id>"}' \
 *     hcloud-microos-k3s-preinstalled.pkr.hcl
 * Rebuild a single arch only to repair a failed half: -only='*.arm'.
 *
 * Each result is labelled k3s-preinstalled=<version>, which is how the module
 * picks the autoscaler image when autoscaler_k3s_preinstalled is set. It also
 * keeps microos-snapshot=yes, so new static nodes may boot it too; they still
 * run the download path, which is harmless.
 */
packer {
  required_plugins {
    hcloud = {
      version = ">= 1.0.5"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}

variable "hcloud_token" {
  type      = string
  default   = env("HCLOUD_TOKEN")
  sensitive = true
}

variable "base_snapshot_ids" {
  type        = map(string)
  description = "IDs of the existing MicroOS snapshots to layer k3s onto, keyed x86 and arm; each must be of that arch."
  validation {
    condition     = contains(keys(var.base_snapshot_ids), "x86") && contains(keys(var.base_snapshot_ids), "arm")
    error_message = "The base_snapshot_ids map needs both an x86 and an arm entry."
  }
}

# Keep this matched to the cluster's k3s version. An agent may run older than
# the servers, never newer.
variable "k3s_version" {
  type    = string
  default = "v1.34.11+k3s1"
}

# sha256 of the k3s binary for k3s_version, per arch, from the release's
# sha256sum-amd64.txt (asset "k3s") and sha256sum-arm64.txt (asset "k3s-arm64").
variable "k3s_sha256" {
  type = map(string)
  default = {
    x86 = "c1991a83985375d318560ac10f2def2fa117995d94d0319d801f283ca074d1b0"
    arm = "272f45b9efc69d0bbdb7042156156c6903087829a5003d4593af0ad2d08d76d4"
  }
}

# sha256 of install.sh at the k3s_version tag.
variable "install_sh_sha256" {
  type    = string
  default = "40b487f0d8ef4f5d1bf422e7bb6228cc7789c40ecc66c5ab067d396bbee9816e"
}

locals {
  k3s_tag_url = replace(var.k3s_version, "+", "%2B")
  k3s_label   = replace(var.k3s_version, "+", "-")
  # Per arch: the release asset, and a small builder of the matching
  # architecture (a binary for the other arch fails its own `--version` check).
  k3s_asset = { x86 = "k3s", arm = "k3s-arm64" }
}

# Settings shared by both architectures; the build block fills in the rest.
source "hcloud" "microos-k3s" {
  location     = "nbg1"
  ssh_username = "root"
  token        = var.hcloud_token
}

build {
  source "hcloud.microos-k3s" {
    name          = "x86"
    image         = var.base_snapshot_ids["x86"]
    server_type   = "cx23"
    snapshot_name = "OpenSUSE MicroOS x86 by Kube-Hetzner (k3s ${var.k3s_version})"
    snapshot_labels = {
      microos-snapshot = "yes"
      creator          = "kube-hetzner"
      k3s-preinstalled = local.k3s_label
      base-snapshot    = var.base_snapshot_ids["x86"]
    }
  }

  source "hcloud.microos-k3s" {
    name          = "arm"
    image         = var.base_snapshot_ids["arm"]
    server_type   = "cax11"
    snapshot_name = "OpenSUSE MicroOS ARM by Kube-Hetzner (k3s ${var.k3s_version})"
    snapshot_labels = {
      microos-snapshot = "yes"
      creator          = "kube-hetzner"
      k3s-preinstalled = local.k3s_label
      base-snapshot    = var.base_snapshot_ids["arm"]
    }
  }

  provisioner "shell" {
    inline = [<<-EOT
      set -eux
      curl -fsSL --retry 5 -o /usr/local/bin/k3s \
        "https://github.com/k3s-io/k3s/releases/download/${local.k3s_tag_url}/${local.k3s_asset[source.name]}"
      echo "${var.k3s_sha256[source.name]}  /usr/local/bin/k3s" | sha256sum -c -
      chmod 0755 /usr/local/bin/k3s
      /usr/local/bin/k3s --version

      mkdir -p /opt/k3s
      curl -fsSL --retry 5 -o /opt/k3s/install.sh \
        "https://raw.githubusercontent.com/k3s-io/k3s/${local.k3s_tag_url}/install.sh"
      echo "${var.install_sh_sha256}  /opt/k3s/install.sh" | sha256sum -c -
      chmod 0755 /opt/k3s/install.sh

      # Same per-instance clean-up as hcloud-microos-snapshots.pkr.hcl, plus
      # dropping this build's throwaway SSH key; each node's cloud-init
      # writes the cluster keys.
      rm -rf /etc/ssh/ssh_host_* /root/.ssh/authorized_keys
      sync
    EOT
    ]
  }
}
