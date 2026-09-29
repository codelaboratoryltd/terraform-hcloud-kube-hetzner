/*
 * Layers a pinned k3s binary and install script onto an EXISTING MicroOS
 * snapshot, so autoscaled nodes can join the cluster without reaching
 * get.k3s.io or GitHub at boot (see var.autoscaler_k3s_preinstalled).
 *
 * It starts from a snapshot rather than from the upstream qcow2 on purpose:
 * hcloud-microos-snapshots.pkr.hcl pulls whatever Tumbleweed is current, so a
 * rebuild would also change the OS and kernel under every new node. This
 * template changes nothing but the two k3s files.
 *
 * Usage:
 *   HCLOUD_TOKEN=... packer init  hcloud-microos-k3s-preinstalled.pkr.hcl
 *   HCLOUD_TOKEN=... packer build -var base_snapshot_id=<id> hcloud-microos-k3s-preinstalled.pkr.hcl
 *
 * The result keeps the microos-snapshot=yes label, so it becomes the
 * most_recent x86 image the module selects. Static nodes ignore image changes
 * (lifecycle.ignore_changes); only newly created servers use it. x86 only.
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

variable "base_snapshot_id" {
  type        = string
  description = "ID of the existing MicroOS x86 snapshot to layer k3s onto."
}

# Keep this matched to the cluster's k3s version. An agent may run older than
# the servers, never newer.
variable "k3s_version" {
  type    = string
  default = "v1.34.11+k3s1"
}

# sha256 of the k3s binary for k3s_version, from the release's sha256sum-amd64.txt.
variable "k3s_sha256" {
  type    = string
  default = "c1991a83985375d318560ac10f2def2fa117995d94d0319d801f283ca074d1b0"
}

# sha256 of install.sh at the k3s_version tag.
variable "install_sh_sha256" {
  type    = string
  default = "40b487f0d8ef4f5d1bf422e7bb6228cc7789c40ecc66c5ab067d396bbee9816e"
}

locals {
  k3s_tag_url = replace(var.k3s_version, "+", "%2B")
}

source "hcloud" "microos-x86-k3s" {
  image       = var.base_snapshot_id
  location    = "nbg1"
  server_type = "cx23"
  snapshot_labels = {
    microos-snapshot = "yes"
    creator          = "kube-hetzner"
    k3s-preinstalled = replace(var.k3s_version, "+", "-")
    base-snapshot    = var.base_snapshot_id
  }
  snapshot_name = "OpenSUSE MicroOS x86 by Kube-Hetzner (k3s ${var.k3s_version})"
  ssh_username  = "root"
  token         = var.hcloud_token
}

build {
  sources = ["source.hcloud.microos-x86-k3s"]

  provisioner "shell" {
    inline = [<<-EOT
      set -eux
      curl -fsSL --retry 5 -o /usr/local/bin/k3s \
        "https://github.com/k3s-io/k3s/releases/download/${local.k3s_tag_url}/k3s"
      echo "${var.k3s_sha256}  /usr/local/bin/k3s" | sha256sum -c -
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
