# Developer Workstation Security Baseline

> **Security Standard** - Operator & Developer Endpoint Baseline for `developmi-platform`
> **Model**: Zero Trust (NIST SP 800-207) | **Scope**: macOS, Linux, Windows (WSL2)

---

## 1. Architectural Philosophy: Zero Trust Over Endpoint Push

In `developmi-platform`, server infrastructure never trusts client workstations by default, and workstations are **not** managed via Ansible push playbooks over SSH. Laptops sleep, roam dynamic networks, and run diverse operating systems where server-grade kernel drops (`policy drop`, aggressive sysctl) break local developer experience (Docker Desktop, local test ports, debuggers).

Instead, security is enforced through **Zero Trust Network Access (ZTNA)** and **Hardware-Backed Cryptographic Identity**:

- The server cluster assumes client devices may be untrusted or compromised.
- All access to server control planes and SSH is gated behind **Tailscale mesh ACLs**, MFA, and hardware security keys.
- Developers maintain a standardized local security baseline without orchestration overhead.

---

## 2. The 4 Essential Pillars of the Client Baseline

```
┌────────────────────────────────────────────────────────────────────────┐
│                   CLIENT WORKSTATION BASELINE                         │
├──────────────────┬──────────────────┬─────────────────┬────────────────┤
│ 1. Disk Crypto   │ 2. FIDO2 / Keys  │ 3. Mesh Network │ 4. Secrets     │
│ LUKS / FileVault │ ed25519-sk       │ Tailscale + MFA │ SOPS + age     │
│ BitLocker (TPM)  │ Signed Commits   │ Least Privilege │ 1Password/Bitw │
└──────────────────┴──────────────────┴─────────────────┴────────────────┘
```

### Pillar 1: Full Disk Encryption (At-Rest Protection)

Physical theft or loss of a developer device must not compromise local repositories, SSH private keys, or session tokens.

| Operating System   | Encryption Engine    | Standard Requirement                                                |
| :----------------- | :------------------- | :------------------------------------------------------------------ |
| **macOS**          | **FileVault**        | Mandatory enabled via System Settings. Secure Enclave backed.       |
| **Linux**          | **LUKS2 (dm-crypt)** | Mandatory on `/` and `/home`. Modern distros enable during install. |
| **Windows / WSL2** | **BitLocker**        | Mandatory on OS volume using TPM 2.0 with PIN.                      |

---

### Pillar 2: Hardware-Backed Cryptographic Identity (In-Transit Protection)

Private keys used for Git commit signing and cluster SSH must **never** be exportable from the machine.

#### 2.1 SSH Authentication via FIDO2 / Hardware Keys

Generate a hardware-backed resident key (e.g. YubiKey 5 Series) that requires physical touch:

```bash
# Generate FIDO2 resident key (requires physical touch on use)
ssh-keygen -t ed25519-sk -O resident -O verify-required -C "operator@developmi"
```

_Benefit: Even if malware compromises the laptop filesystem, the private key cannot be extracted without the physical token._

#### 2.2 Cryptographic Git Commit Signing

All commits to `developmi-platform` require GPG or SSH signature verification (`git commit -S`).

Configure SSH-based commit signing natively in Git:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_sk.pub
git config --global commit.gpgsign true
```

---

### Pillar 3: Overlay Network & Least Privilege (Tailscale)

Client devices connect to the cluster strictly as client nodes on the private Tailnet:

1. **No Inbound Public Ports**: Client workstations must not listen on public IPv4/IPv6 interfaces.
2. **Tailscale Multi-Factor Authentication (MFA)**: Operators authenticate into Tailscale using a corporate IdP or GitHub OAuth with WebAuthn/FIDO2 MFA.
3. **ACL Enforcement**: The Tailscale ACL policy ([roles/L2_compliance/general/templates/tailscale/tailscale-acls.json.j2](file:///mnt/Workspace/_03_INFRA/developmi-platform/roles/L2_compliance/general/templates/tailscale/tailscale-acls.json.j2)) restricts operator traffic strictly to authorized management ports (`tag:brain:22`, `tag:muscle:22`, `tag:muscle:8443`).

---

### Pillar 4: Secret Management & Hygiene

- **SOPS + age**: All environment secrets and keys in this repo reside encrypted in `inventory/group_vars/all/secrets.sops.yml`.
- **Private age Key Storage**: The operator's age private key (`~/.config/sops/age/keys.txt`) must have file mode `0600` and be stored in a password manager (e.g. 1Password / Bitwarden).
- **Zero Plaintext Secrets in Dotfiles**: Do not commit secrets, tokens, or age keys to personal dotfile repositories.

---

## 3. Quick Checklist for New Developers / Operators

- [ ] Full disk encryption enabled and verified on laptop.
- [ ] OS automatic security patches enabled.
- [ ] Tailscale client installed and enrolled in the cluster Tailnet with MFA.
- [ ] Hardware key (YubiKey) or hardware-backed SSH key configured for Git signing and SSH.
- [ ] Pre-commit hooks installed locally: `make precommit-install`.
- [ ] Age key imported: `mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age`.
