# ESPHome config tooling
#
#   make test                 Validate all configs (esphome config)
#   make build                Compile all configs (esphome compile)
#   make test CONFIGS="a.yaml b.yaml"   Limit to specific configs
#   make build SECRETS=secrets.yaml     Use real secrets instead of test_secrets
#   make ESPHOME_VERSION=latest test    Use the newest ESPHome release
#   make -s python-version              Minimum Python the ESPHome version requires
#   make size                 Re-print the memory summary from the last build
#
# Configs are staged into $(STAGE_DIR) with $(SECRETS) copied in as
# secrets.yaml, so a real secrets.yaml in the repo is never touched.

ESPHOME_VERSION ?= 2026.11.0
PYTHON          ?= python3
VENV            ?= .venv
SECRETS         ?= test_secrets
STAGE_DIR       ?= .build/stage
LOG_DIR         ?= .build/logs
CONFIGS         ?= $(filter-out secrets.yaml,$(wildcard *.yaml))

ESPHOME := $(VENV)/bin/esphome

SHELL := /bin/bash

ifeq ($(ESPHOME_VERSION),latest)
ESPHOME_SPEC := esphome
PYPI_URL     := https://pypi.org/pypi/esphome/json
else
ESPHOME_SPEC := esphome==$(ESPHOME_VERSION)
PYPI_URL     := https://pypi.org/pypi/esphome/$(ESPHOME_VERSION)/json
endif

# Stamp per version so changing ESPHOME_VERSION reinstalls
ESPHOME_STAMP := $(VENV)/.esphome-$(ESPHOME_VERSION)

.PHONY: all tools test build _compile size stage version python-version clean distclean

all: test

tools: $(ESPHOME_STAMP)

$(ESPHOME_STAMP):
	@if command -v uv >/dev/null 2>&1; then \
		[ -x $(VENV)/bin/python ] || uv venv -q --python $(PYTHON) $(VENV); \
		VIRTUAL_ENV=$(VENV) uv pip install -q --upgrade "$(ESPHOME_SPEC)"; \
	else \
		[ -x $(VENV)/bin/python ] || $(PYTHON) -m venv $(VENV); \
		$(VENV)/bin/pip install -q --upgrade pip; \
		$(VENV)/bin/pip install -q --upgrade "$(ESPHOME_SPEC)"; \
	fi
	@rm -f $(VENV)/.esphome-*
	@touch $@
	@$(ESPHOME) version

version: tools
	@$(ESPHOME) version

# Lower bound of ESPHome's requires_python on PyPI (e.g. ">=3.12.0,<3.16" -> 3.12),
# so CI's Python tracks ESPHome instead of a hardcoded version
python-version:
	@json=$$(curl -fsSL $(PYPI_URL)) && printf '%s' "$$json" | $(PYTHON) -c 'import json, re, sys; \
		spec = json.load(sys.stdin)["info"]["requires_python"] or ""; \
		m = re.search(r">=\s*(\d+\.\d+)", spec); \
		sys.exit("No lower bound in requires_python: " + repr(spec)) if not m else print(m.group(1))'

# Copy the repo (minus build artifacts) into the stage dir. The stage's own
# .esphome/ cache is preserved between runs to speed up compiles.
stage:
	@test -f $(SECRETS) || { echo "Secrets file '$(SECRETS)' not found"; exit 1; }
	@mkdir -p $(STAGE_DIR)
	@rsync -a --delete \
		--exclude '/.git/' --exclude '/.venv/' --exclude '/.build/' \
		--exclude '/.esphome/' --exclude '/secrets.yaml' \
		--filter 'protect /.esphome/' --filter 'protect /secrets.yaml' \
		./ $(STAGE_DIR)/
	@cp $(SECRETS) $(STAGE_DIR)/secrets.yaml

# Run an esphome command over each config, report all failures at the end.
# Output is also logged to $(LOG_DIR)/<config>.<cmd>.log for the size summary.
define run_each
	@mkdir -p $(LOG_DIR); \
	log_dir=$(abspath $(LOG_DIR)); \
	cd $(STAGE_DIR) && failed=""; \
	for c in $(CONFIGS); do \
		echo "=== $(1) $$c"; \
		set -o pipefail; \
		$(CURDIR)/$(ESPHOME) $(1) $$c 2>&1 | tee "$$log_dir/$$c.$(1).log" $(2) || failed="$$failed $$c"; \
	done; \
	if [ -n "$$failed" ]; then echo "FAILED:$$failed"; exit 1; fi; \
	echo "All configs passed: $(1)"
endef

test: tools stage
	$(call run_each,config,>/dev/null)

# Summary is printed even if some configs failed, then the failure propagates
build: tools stage
	@rc=0; $(MAKE) --no-print-directory _compile || rc=$$?; \
	$(MAKE) --no-print-directory size; exit $$rc

_compile:
	$(call run_each,compile)

# Free RAM/flash per device, parsed from the last compile logs. On ESP8266 an
# OTA update needs room for the old and new image side by side, so "OTA room"
# (flash free minus one image) going negative means OTA will likely fail.
size:
	@printf '%-24s %-6s %21s %8s %23s %10s %10s\n' \
		CONFIG CHIP "RAM used/total" "RAM free" "FLASH used/total" "FLASH free" "OTA room~"; \
	for c in $(CONFIGS); do \
		log=$(LOG_DIR)/$$c.compile.log; \
		storage=$(STAGE_DIR)/.esphome/storage/$$c.json; \
		chip=$$(sed -n 's/.*"core_platform": *"\([a-z0-9]*\)".*/\1/p' $$storage 2>/dev/null); \
		if ! grep -q '^Flash:' $$log 2>/dev/null; then \
			printf '%-24s %-6s %s\n' "$${c%.yaml}" "$${chip:-?}" "(no build output)"; continue; \
		fi; \
		awk -v c="$${c%.yaml}" -v chip="$${chip:-?}" ' \
			/^RAM:/   { for (i = 1; i <= NF; i++) { if ($$i == "(used") ru = $$(i+1); if ($$i == "from") rt = $$(i+1) } } \
			/^Flash:/ { for (i = 1; i <= NF; i++) { if ($$i == "(used") fu = $$(i+1); if ($$i == "from") ft = $$(i+1) } } \
			END { \
				ota = (chip == "esp8266") ? sprintf("%d", ft - 2 * fu) : "-"; \
				printf "%-24s %-6s %21s %8d %23s %10d %10s%s\n", c, chip, \
					ru "/" rt, rt - ru, fu "/" ft, ft - fu, ota, \
					(ota != "-" && ota + 0 < 0) ? "  <-- OTA at risk" : "" \
			}' $$log; \
	done

clean:
	rm -rf .build

distclean: clean
	rm -rf $(VENV)
