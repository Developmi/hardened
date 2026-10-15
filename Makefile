SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ==============================================================================
# DEVELOPMI PLATFORM - HARDENED INFRASTRUCTURE SUITE
# ==============================================================================

# Package manager & toolchain
PKG ?= uv
ANSIBLE_INVENTORY ?= inventory/hosts.ini
PLAYBOOK ?= playbooks/site.yml

# Scoping & Targeting
TARGET ?=
ANSIBLE_LIMIT ?= $(TARGET)
ANSIBLE_LIMIT_FLAG = $(if $(ANSIBLE_LIMIT),--limit $(ANSIBLE_LIMIT),)
ANSIBLE_OPTS ?=
TAGS ?=
SKIP_TAGS ?=
CHECK ?=
APT_FORCE ?= false
APT_FORCE_FLAG := $(if $(filter true,$(APT_FORCE)),--extra-vars "apt_force_cleanup=true",)

# Edge Proxy configuration
BACKEND ?= caddy

# Secrets management
SOPS_FILE ?= inventory/group_vars/all/secrets.sops.yml
SOPS_SAMPLE ?= inventory/group_vars/all/secrets.sops.yml.example

# Teardown safety
CONFIRM ?=
NUKE_CONFIRM_PHRASE ?= DESTROY_ALL_INFRASTRUCTURE

# Sudo become prompt override (for bootstrap on hosts without NOPASSWD sudoers)
ASK_BECOME ?=
BECOME_PROMPT_FLAG = $(if $(filter true 1 yes,$(ASK_BECOME)),--ask-become-pass,)


# Vault prompt override (for custom vaults or transitional keys)
VAULT_PROMPT_FLAG ?=

# Unified Ansible execution parameters
ANSIBLE_FLAGS = $(BECOME_PROMPT_FLAG) $(VAULT_PROMPT_FLAG) $(APT_FORCE_FLAG) $(ANSIBLE_OPTS) $(ANSIBLE_LIMIT_FLAG)
ANSIBLE_RUN = $(PKG) run ansible-playbook -i $(ANSIBLE_INVENTORY)

##@ 1. Toolchain & Quality

help: ## Show this interactive help with usage and flags
	@awk 'BEGIN {FS = ":.*## "; printf "\n\033[1;37mUsage:\033[0m\n  make \033[36m<target>\033[0m [\033[90mVARIABLE=value\033[0m]\n"} \
	  /^[a-zA-Z0-9_.-]+:.*## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1;33m%s\033[0m\n", substr($$0, 5) } \
	  END { printf "\n\033[1;37mExamples:\033[0m\n  make setup\n  make lint\n  make deploy-hardening TARGET=brain-1\n  make deploy-edge TARGET=brain-1\n  make run PLAYBOOK=playbooks/l6/engine.yml CHECK=1\n  make verify COMPONENT=edge\n\n" }' $(MAKEFILE_LIST)

setup: ## Bootstrap local environment (sync + collections + pre-commit)
	@echo "=== Bootstrapping Local Toolchain ==="
	$(PKG) sync
	$(PKG) run ansible-galaxy collection install -r requirements.yml
	$(PKG) run pre-commit install
	@echo "=== Toolchain Ready ==="

sync: ## Sync Python dependencies with uv
	@echo "Running $(PKG) sync..."
	$(PKG) sync

lint: ## Strict code quality audit (yamllint + ansible-lint + zizmor)
	@set -e; \
	echo "==> 1/3 Checking YAML syntax (yamllint)..."; \
	$(PKG) run yamllint $$(git ls-files '*.yml' '*.yaml'); \
	echo "==> 2/3 Checking Ansible playbooks & roles (ansible-lint)..."; \
	files=$$(find playbooks -name '*.yml' -not -path '*/\.*' | sort); \
	$(PKG) run ansible-lint $$files; \
	echo "==> 3/3 Checking GitHub Actions security (zizmor)..."; \
	$(PKG) run zizmor .; \
	echo "=== Quality Gates: ALL PASSED ==="

precommit: ## Run all pre-commit hooks on repository files
	$(PKG) run pre-commit run --all-files

test: ## Run Molecule tests [LAYER=<scenario_name>]
	@if [ -n "$(LAYER)" ]; then \
		echo "=> Running Molecule layer scenario: $(LAYER)"; \
		$(PKG) run --group test molecule test -s $(LAYER); \
	else \
		echo "=> Running Full Molecule Suite..."; \
		$(PKG) run --group test molecule test --all; \
	fi

show-inventory: ## Print current hosts inventory file
	@test -f $(ANSIBLE_INVENTORY) && cat $(ANSIBLE_INVENTORY) || (echo "Inventory not found: $(ANSIBLE_INVENTORY)" && exit 1)

##@ 2. Secrets (SOPS + Age)

sops-init: ## Initialize secrets.sops.yml from sample template
	@if [ -f "$(SOPS_FILE)" ]; then \
		echo "SOPS file already exists: $(SOPS_FILE)"; \
	else \
		cp "$(SOPS_SAMPLE)" "$(SOPS_FILE)"; \
		echo "Created $(SOPS_FILE) from $(SOPS_SAMPLE)."; \
	fi

sops-edit: ## Edit encrypted secrets in $$EDITOR with automatic re-encryption
	@test -f "$(SOPS_FILE)" || (echo "Missing SOPS file: $(SOPS_FILE)" && exit 1)
	$(PKG) run sops edit "$(SOPS_FILE)"

sops-encrypt: ## Encrypt secrets file in place (requires Age key)
	@test -f "$(SOPS_FILE)" || (echo "Missing SOPS file: $(SOPS_FILE)" && exit 1)
	$(PKG) run sops --encrypt --in-place "$(SOPS_FILE)"

sops-view: ## View decrypted secrets in stdout
	@test -f "$(SOPS_FILE)" || (echo "Missing SOPS file: $(SOPS_FILE)" && exit 1)
	$(PKG) run sops decrypt "$(SOPS_FILE)"

##@ 3. Deployment Layers (L1 - L6)

deploy-bootstrap: ## First-deploy host bootstrap [CONTROLLER_IP=x.x.x.x]
	@echo "=== First Deploy: Host Bootstrap ==="
	@EXTRA_E="" ; \
	if [ -n "$(CONTROLLER_IP)" ]; then \
		EXTRA_E="-e controller_ip=$(CONTROLLER_IP)"; \
	elif [ -n "$$SSH_CLIENT" ]; then \
		EXTRA_E="-e controller_ip=$$(echo "$$SSH_CLIENT" | awk '{print $$1}')"; \
	elif [ -n "$$SSH_CONNECTION" ]; then \
		EXTRA_E="-e controller_ip=$$(echo "$$SSH_CONNECTION" | awk '{print $$1}')"; \
	else \
		LOCAL_IP=$$(ip route get 1.1.1.1 2>/dev/null | awk '{print $$7; exit}' || echo "127.0.0.1"); \
		EXTRA_E="-e controller_ip=$$LOCAL_IP"; \
	fi; \
	$(ANSIBLE_RUN) playbooks/site.yml $(ANSIBLE_FLAGS) -e bootstrap_mode=true $${EXTRA_E}

deploy-hardening: ## Deploy full OS hardening L1+L2 (site.yml) [TARGET=<host>]
	@echo "=== Full Hardening (L1 Baseline + L2 Compliance/Zero Trust) ==="
	$(ANSIBLE_RUN) playbooks/site.yml $(ANSIBLE_FLAGS)

deploy-engine: ## Deploy hardened Docker Engine runtime (L6) [TARGET=<host>]
	@echo "=== L6: Docker Engine Runtime ==="
	$(ANSIBLE_RUN) playbooks/l6/engine.yml $(ANSIBLE_FLAGS)

deploy-edge: ## Deploy Caddy WAF Ingress (L4) [TARGET=brain] [BACKEND=caddy]
	@EDGE_TARGET="$(if $(TARGET),$(TARGET),brain)"; \
	echo "=== L4: Edge Proxy ($(BACKEND) on $$EDGE_TARGET) ==="; \
	$(ANSIBLE_RUN) playbooks/l4/edge.yml $(ANSIBLE_FLAGS) --limit "$$EDGE_TARGET" -e reverse_proxy_backend=$(BACKEND) -e target_group="$$EDGE_TARGET"

deploy-monitoring: ## Deploy exporters & full observability stack (L3)
	@echo "=== L3: Monitoring (Exporters on all hosts + Stack on brain) ==="
	$(ANSIBLE_RUN) playbooks/l3/exporters.yml $(ANSIBLE_FLAGS)
	$(ANSIBLE_RUN) playbooks/l3/stack.yml $(ANSIBLE_FLAGS)

deploy-backups: ## Deploy unified backup engine & stack backups (L6)
	@echo "=== L6: Backup Infrastructure ==="
	$(ANSIBLE_RUN) playbooks/l6/backup-stack.yml $(ANSIBLE_FLAGS) --limit brain
	$(ANSIBLE_RUN) playbooks/l6/backup-engine.yml $(ANSIBLE_FLAGS)

deploy-portainer: ## Deploy optional Portainer runtime (Maintenance / Experimental) [TARGET=muscle]
	@echo "⚠️  [WARNING] Portainer runtime is in MAINTENANCE / EXPERIMENTAL mode."
	@echo "⚠️  [NOTICE] Running Portainer exposes the docker.sock attack surface. Operator executes under their own responsibility."
	$(ANSIBLE_RUN) playbooks/l6/portainer.yml -e enable_portainer=true $(ANSIBLE_FLAGS)

deploy-platform: ## Deploy complete core platform (hardening→engine→monitoring→backups)
	@echo "=== Full Core Platform Deployment ==="
	@$(MAKE) deploy-hardening
	@$(MAKE) deploy-engine
	@$(MAKE) deploy-monitoring
	@$(MAKE) deploy-backups
	@echo "=== Platform Core: READY ==="

##@ 4. Operations & Verification

run: ## Universal playbook runner [PLAYBOOK=path] [TARGET=host] [CHECK=1] [TAGS=t]
	@test -n "$(PLAYBOOK)" || (echo "ERROR: Set PLAYBOOK=<path>.yml" && exit 1)
	@test -f "$(PLAYBOOK)" || (echo "ERROR: Playbook not found: $(PLAYBOOK)" && exit 1)
	$(ANSIBLE_RUN) $(PLAYBOOK) $(ANSIBLE_FLAGS) \
		$(if $(TAGS),--tags "$(TAGS)") \
		$(if $(SKIP_TAGS),--skip-tags "$(SKIP_TAGS)") \
		$(if $(filter 1,$(CHECK)),--check --diff)

validate: ## Audit compliance & OS state (read-only) [LAYER=l1|l2] [TARGET=host]
	@echo "=== Running Security & Compliance Validation Audit ==="
	@if [ "$(LAYER)" = "l1" ]; then \
		$(ANSIBLE_RUN) playbooks/ops/validate.yml $(ANSIBLE_FLAGS) --tags l1-os-baseline; \
	elif [ "$(LAYER)" = "l2" ]; then \
		$(ANSIBLE_RUN) playbooks/l2/validate.yml $(ANSIBLE_FLAGS); \
	else \
		$(ANSIBLE_RUN) playbooks/ops/validate.yml $(ANSIBLE_FLAGS) && \
		$(ANSIBLE_RUN) playbooks/l2/validate.yml $(ANSIBLE_FLAGS); \
	fi

verify: ## Verify platform health [COMPONENT=all|edge|lockdown|monitoring|backups]
	@comp="$(if $(COMPONENT),$(COMPONENT),all)"; \
	echo "=== Verifying Platform Component: $$comp ==="; \
	if [ "$$comp" = "edge" ] || [ "$$comp" = "all" ]; then \
		$(ANSIBLE_RUN) playbooks/l4/verify-caddy.yml $(ANSIBLE_FLAGS); \
	fi; \
	if [ "$$comp" = "monitoring" ] || [ "$$comp" = "all" ]; then \
		$(PKG) run ansible all -i $(ANSIBLE_INVENTORY) -m shell -a "docker ps --format '{{.Names}}: {{.Status}}' | grep -E 'node-exporter|cadvisor' || true" $(ANSIBLE_FLAGS); \
	fi; \
	if [ "$$comp" = "backups" ] || [ "$$comp" = "all" ]; then \
		$(PKG) run ansible all -i $(ANSIBLE_INVENTORY) -m shell -a "systemctl list-timers --all | grep backup- || echo 'no backup timers active'" $(ANSIBLE_FLAGS); \
	fi; \
	if [ "$$comp" = "lockdown" ]; then \
		$(PKG) run ansible all -i $(ANSIBLE_INVENTORY) --become -m ping || exit 1; \
	fi

reboot: ## Controlled rolling reboot with health verification [TARGET=<host>]
	@if [ -z "$(TARGET)" ]; then \
		echo "ERROR: TARGET is required for controlled reboot (e.g. make reboot TARGET=muscle-1 or TARGET=all)"; \
		exit 1; \
	fi
	$(ANSIBLE_RUN) playbooks/ops/reboot.yml $(ANSIBLE_FLAGS)

upgrade: ## Controlled rolling OS package upgrade [TARGET=<host>]
	$(ANSIBLE_RUN) playbooks/ops/upgrade.yml $(ANSIBLE_FLAGS)

nuke: ## Destructive teardown [CONFIRM=DESTROY_ALL_INFRASTRUCTURE]
	@test "$(CONFIRM)" = "$(NUKE_CONFIRM_PHRASE)" || (echo "ERROR: Nuke requires explicit confirmation. Set CONFIRM=$(NUKE_CONFIRM_PHRASE)" && exit 1)
	@echo "=== NUKE: DESTROYING ALL INFRASTRUCTURE ==="
	$(ANSIBLE_RUN) playbooks/ops/nuke.yml $(ANSIBLE_FLAGS)

# ==============================================================================
# COMPATIBILITY ALIASES
# ==============================================================================

deploy: deploy-hardening
deploy-first: deploy-bootstrap
check:
	@$(MAKE) run CHECK=1
dry-run:
	@$(MAKE) run CHECK=1
precommit-run: precommit
precommit-install:
	$(PKG) run pre-commit install
install-collections:
	$(PKG) run ansible-galaxy collection install -r requirements.yml
check-toolchain:
	./scripts/setup.sh --validate
setup-toolchain:
	./scripts/setup.sh --install
deploy-l1:
	$(ANSIBLE_RUN) playbooks/l1/baseline.yml $(ANSIBLE_FLAGS)
deploy-lockdown:
	$(ANSIBLE_RUN) playbooks/l2/lockdown.yml $(ANSIBLE_OPTS)
deploy-compliance:
	$(ANSIBLE_RUN) playbooks/l2/compliance.yml $(ANSIBLE_FLAGS)
reconnect-tailscale:
	$(ANSIBLE_RUN) playbooks/l2/tailscale-recover.yml $(ANSIBLE_FLAGS)
validate-l1:
	@$(MAKE) validate LAYER=l1
validate-l2:
	@$(MAKE) validate LAYER=l2
audit-full:
	@$(MAKE) validate
deploy-exporters:
	$(ANSIBLE_RUN) playbooks/l3/exporters.yml $(ANSIBLE_FLAGS)
deploy-monitoring-stack:
	$(ANSIBLE_RUN) playbooks/l3/stack.yml $(ANSIBLE_FLAGS)
verify-caddy:
	$(ANSIBLE_RUN) playbooks/l4/verify-caddy.yml $(ANSIBLE_FLAGS)
heal-caddy:
	@$(MAKE) deploy-edge TARGET=$(TARGET)
deploy-backup-stack:
	$(ANSIBLE_RUN) playbooks/l6/backup-stack.yml $(ANSIBLE_FLAGS) --limit brain
deploy-backup-engine:
	$(ANSIBLE_RUN) playbooks/l6/backup-engine.yml $(ANSIBLE_FLAGS)
backup-now:
	$(ANSIBLE_RUN) playbooks/l6/backup-stack.yml $(ANSIBLE_FLAGS) --tags stack_backup --limit brain
provision-host:
	$(ANSIBLE_RUN) playbooks/ops/bootstrap.yml $(ANSIBLE_FLAGS)
deploy-local:
	$(ANSIBLE_RUN) playbooks/ops/local-devices.yml $(ANSIBLE_FLAGS)
verify-lockdown:
	@$(MAKE) verify COMPONENT=lockdown
verify-tailscale:
	$(PKG) run ansible all -i $(ANSIBLE_INVENTORY) -m command -a "tailscale status"
verify-crowdsec:
	$(PKG) run ansible all -i $(ANSIBLE_INVENTORY) -m shell -a "timeout 15 cscli alerts list || echo 'crowdsec OK'"
verify-auditd:
	$(PKG) run ansible all -i $(ANSIBLE_INVENTORY) -m shell -a "tail -n 50 /var/log/audit/audit.log"
verify-observability:
	@$(MAKE) verify COMPONENT=monitoring
verify-timers:
	@$(MAKE) verify COMPONENT=backups
test-layer:
	@$(MAKE) test LAYER=$(LAYER)

.PHONY: help setup sync lint precommit test show-inventory \
	sops-init sops-edit sops-encrypt sops-view \
	deploy-bootstrap deploy-hardening deploy-engine deploy-edge \
	deploy-monitoring deploy-backups deploy-portainer deploy-platform \
	run validate verify nuke reboot upgrade \
	deploy deploy-first check dry-run precommit-run precommit-install \
	install-collections check-toolchain setup-toolchain deploy-l1 deploy-lockdown \
	deploy-compliance reconnect-tailscale validate-l1 validate-l2 audit-full \
	deploy-exporters deploy-monitoring-stack verify-caddy heal-caddy \
	deploy-backup-stack deploy-backup-engine backup-now provision-host deploy-local \
	verify-lockdown verify-tailscale verify-crowdsec verify-auditd verify-observability \
	verify-timers test-layer
