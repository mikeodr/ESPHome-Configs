# ESPHome config tooling
#
#   make test                 Validate all configs (esphome config)
#   make build                Compile all configs (esphome compile)
#   make test CONFIGS="a.yaml b.yaml"   Limit to specific configs
#   make build SECRETS=secrets.yaml     Use real secrets instead of test_secrets
#   make ESPHOME_VERSION=latest test    Use the newest ESPHome release
#   make -s python-version              Minimum Python the ESPHome version requires
#
# Configs are staged into $(STAGE_DIR) with $(SECRETS) copied in as
# secrets.yaml, so a real secrets.yaml in the repo is never touched.

ESPHOME_VERSION ?= 2026.11.0
PYTHON          ?= python3
VENV            ?= .venv
SECRETS         ?= test_secrets
STAGE_DIR       ?= .build/stage
CONFIGS         ?= $(filter-out secrets.yaml,$(wildcard *.yaml))

ESPHOME := $(VENV)/bin/esphome

ifeq ($(ESPHOME_VERSION),latest)
ESPHOME_SPEC := esphome
PYPI_URL     := https://pypi.org/pypi/esphome/json
else
ESPHOME_SPEC := esphome==$(ESPHOME_VERSION)
PYPI_URL     := https://pypi.org/pypi/esphome/$(ESPHOME_VERSION)/json
endif

# Stamp per version so changing ESPHOME_VERSION reinstalls
ESPHOME_STAMP := $(VENV)/.esphome-$(ESPHOME_VERSION)

.PHONY: all tools test build stage version python-version clean distclean

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

# Run an esphome command over each config, report all failures at the end
define run_each
	@cd $(STAGE_DIR) && failed=""; \
	for c in $(CONFIGS); do \
		echo "=== $(1) $$c"; \
		$(CURDIR)/$(ESPHOME) $(1) $$c $(2) || failed="$$failed $$c"; \
	done; \
	if [ -n "$$failed" ]; then echo "FAILED:$$failed"; exit 1; fi; \
	echo "All configs passed: $(1)"
endef

test: tools stage
	$(call run_each,config,>/dev/null)

build: tools stage
	$(call run_each,compile)

clean:
	rm -rf .build

distclean: clean
	rm -rf $(VENV)
