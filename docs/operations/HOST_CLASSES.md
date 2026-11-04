---
title: How to Assign and Manage Host Classes
type: operations
owner: maintainers
audience: operator
version: v6.0.0
last-reviewed: 2026-11-04
status: active
project: developmi-hardened
repo: github.com/Developmi/hardened
---

# How to Assign and Manage Host Classes

This guide walks you through assigning hosts to classes (`brain`, `muscle`), migrating hosts between classes, and verifying the result. Host classes control which Ansible roles, hardening profiles, and platform services apply to a node. Assigning the wrong class means the wrong profile is deployed.

_(Source: ARCHITECTURE.md §7)_

## Before You Start

You need to understand what each class does before assigning one.

**Capability summary** - `brain` nodes are management (Portainer, Grafana, backups, ingress control); `muscle` nodes run application workloads. For the full capability matrix (backups, observability, CrowdSec, Tailscale auth, nftables policy, fail2ban bantime, etc.), see [ARCHITECTURE.md §7 - Capability Matrix](../architecture/ARCHITECTURE.md#7-host-classes-brain-muscle).

**Role summary** - `brain` and `muscle` get the full L1-L6 role stack (with brain-only management roles). For the complete per-class allowed-roles table, see [ARCHITECTURE.md §7 - Allowed Roles per Class](../architecture/ARCHITECTURE.md#7-host-classes-brain-muscle).

**Hardening profile** - the `hardening_profile` dispatcher routes `brain` and `muscle` to `server`.

> **Note on Workstation Devices**: Operator and developer laptops/workstations are client endpoints connecting to the cluster over Tailscale; they are not managed through Ansible host classes. See [DEVELOPER_WORKSTATION_GUIDE.md](../security/DEVELOPER_WORKSTATION_GUIDE.md).

**Brain vs muscle roles** - both run Docker, but with different purposes:

- **brain** = operations + observability (runs Docker, monitoring stack, edge proxy, backup orchestration)
- **muscle** = application runtime (runs Docker, application containers, backup-db for databases)

The suite does NOT deploy applications - it prepares the hardened foundation. Application deployment is the operator's responsibility using reference profiles at `apps/`.

## Assigning a Host to a Class

### Prerequisites

- Ansible inventory file (`inventory/hosts.ini` or equivalent) is writable
- `inventory/group_vars/` directory structure exists: `brain/`, `muscle/`
- SOPS age private key available at `~/.config/sops/age/keys.txt` to decrypt `secrets.sops.yml` (the Tailscale trio in `secrets.yml` is the only vaulted exception until gate D4, OPERATIONS_RUNBOOK §7.4)
- Bootstrap identity follows the inventory: SSH as `root` on classic VPS/lab hosts; on cloud images (OCI/AWS/GCP) SSH as the cloud image user (non-root, NOPASSWD sudo). `ansible_become` is derived from `ansible_user`. Declare `ansible_user` per host and `ansible_ssh_private_key_file` in `all:vars`.

### Step 1 - Create or verify the group_vars file

```bash
# For a new brain node:
mkdir -p inventory/group_vars/brain
test -f inventory/group_vars/brain/main.yml || cat > inventory/group_vars/brain/main.yml <<'EOF'
hardening_profile: server
# Add brain-specific vars below (observability endpoints, backup targets, etc.)
EOF
```

Repeat for `muscle`, setting `hardening_profile: server`.

### Step 2 - Tag the host in inventory

Add the host to the matching Ansible group in your inventory file:

```ini
# inventory/hosts.ini
[brain]
brain-1 ansible_host=100.125.56.109 ansible_user=automation public_ip=178.104.18.57 node_role=management caddy_node_id=brain-1

[muscle]
muscle-1 ansible_host=100.66.224.76 ansible_user=automation public_ip=150.136.240.35 node_role=worker caddy_node_id=muscle-1
```

### Step 3 - Verify group_vars are loaded

```bash
# Confirm the host picks up the right hardening_profile
uv run ansible mgmt-node-01 -m debug -a "var=hardening_profile"

# List all facts for the host to verify group membership
uv run ansible mgmt-node-01 -m setup | grep ansible_playbook_dir
```

### Step 4 - Dry-run with the new class

```bash
uv run ansible-playbook -i inventory/hosts.ini playbooks/l2/hardening.yml --limit mgmt-node-01 --check --diff
```

## Class Migration Procedure

Migrating a host between classes (`brain` ↔ `muscle`) requires careful reconfiguration.

### brain → muscle migration

1. **Backup existing configuration**

   ```bash
   mkdir -p backups/$(date +%Y%m%d)
   ansible <hostname> -m fetch \
     --src=/etc/ssh/sshd_config \
     --dest=backups/$(date +%Y%m%d)/ \
     --flat
   ```

2. **Reassign group in inventory** - move the host from the `brain` group to the `muscle` group in `inventory/hosts.ini`. If the host is the _only_ brain, you must first designate another node as brain or accept that management services (Portainer, Grafana) will go down.

3. **Review role differences** - `muscle` excludes management-only roles. Verify your playbooks do not assign brain-only roles (e.g., `portainer` as primary server) to this host.

4. **Dry-run the migration**

   ```bash
   uv run ansible-playbook -i inventory/hosts.ini playbooks/l2/hardening.yml \
     --limit <hostname> --check --diff
   ```

5. **Apply**
   ```bash
   uv run ansible-playbook -i inventory/hosts.ini playbooks/l2/hardening.yml --limit <hostname>
   ```

### muscle → brain migration

Same steps in reverse, plus:

- Ensure the new brain has sufficient persistent storage for backups and evidence
- Verify observability dashboards are reachable after migration
- If HA, add the new brain to the HA configuration

## Verification Checklist

Run these commands after assigning a class or after a migration to confirm the host is in the expected state.

### Per-class verification

```bash
# 1. Confirm hardening_profile is correct
uv run ansible <hostname> -m debug -a "var=hardening_profile"
# Expected: "server" for brain/muscle

# 2. Check active roles (via ansible-playbook tag report)
uv run ansible-playbook -i inventory/hosts.ini playbooks/l2/hardening.yml \
  --limit <hostname> --list-tags

# 3. Verify group membership
uv run ansible <hostname> -m debug -a "var=group_names"
# Expected: ["brain"] or ["muscle"]

# 4. Check nftables firewall status
uv run ansible <hostname> -m shell -a "systemctl is-active nftables && nft list ruleset | grep 'table inet filter'" --become

# 5. Check fail2ban status
uv run ansible <hostname> -m shell -a "fail2ban-client status" --become

# 6. Check CrowdSec
uv run ansible <hostname> -m shell -a "cscli metrics" --become

# 7. Check Tailscale connectivity
uv run ansible <hostname> -m shell -a "tailscale status" --become
```

## Troubleshooting

### Wrong hardening profile applied

**Symptom:** `hardening_profile` returns unexpected value on a server host.

**Causes:**

- Host is in the wrong Ansible group
- `inventory/group_vars/<class>/main.yml` is missing or misspelled

**Fix:**

```bash
# Check which vars files are loaded
uv run ansible <hostname> -m debug -a "var=vars"
# Verify the group file exists
ls -la inventory/group_vars/{brain,muscle}/main.yml
```

### Missing group_vars file

**Symptom:** `hardening_profile` is undefined, playbook fails with `'hardening_profile' is undefined`.

**Fix:** Create the file per the assignment procedure above, or rely on global default in `inventory/group_vars/all/main.yml`:

```yaml
# inventory/group_vars/all/main.yml
hardening_profile: server
```

### Role removed but service still running

**Symptom:** After brain→muscle migration, Portainer or Grafana is still running on the muscle node.

**Fix:** Ansible roles are additive by default - they do not automatically stop services when a role is removed from a host. Manually stop and disable:

```bash
uv run ansible <hostname> -m systemd -a "name=portainer state=stopped enabled=no" --become
```

## Cross-References

- [ARCHITECTURE.md §7 - Host Classes and Capability Profiles](../architecture/ARCHITECTURE.md#7-host-classes-brain-muscle) - SSOT for capability matrix and allowed roles
- [GLOSSARY.md - Host Classes](../GLOSSARY.md#host-classes) - Platform terminology
- [DEVELOPER_WORKSTATION_GUIDE.md](../security/DEVELOPER_WORKSTATION_GUIDE.md) - Workstation security baseline
- [LAYER_BOUNDARIES.md](../architecture/LAYER_BOUNDARIES.md) - Layer deployment scoping
- [OPERATIONS_RUNBOOK.md](OPERATIONS_RUNBOOK.md) - Boot sequence per layer
