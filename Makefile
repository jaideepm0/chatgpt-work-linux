SHELL := /usr/bin/env bash
.DEFAULT_GOAL := build

.PHONY: build check check-update clean doctor ensure-build install-user migrate-codex-history profile-runtime profile-runtime-constrained refresh-upstream run sbom smoke-wayland test uninstall-user update-user

build:
	bash scripts/fetch-upstream.sh
	bash scripts/build-work-app.sh

check-update:
	bash scripts/check-upstream.sh

ensure-build:
	@expected=$$(python3 -c 'import json; print(json.load(open("docs/upstream-snapshot.json"))["application"]["short_version"])'); \
	if [ ! -x .work/chatgpt-work-app/start.sh ] || \
	   ! rg -q "^CHATGPT_WORK_UPSTREAM_VERSION=$$expected$$" .work/chatgpt-work-app/start.sh; then \
		$(MAKE) build; \
	fi

run: ensure-build
	./.work/chatgpt-work-app/start.sh

doctor: ensure-build
	./.work/chatgpt-work-app/start.sh doctor

smoke-wayland: ensure-build
	bash scripts/smoke-wayland.sh ./.work/chatgpt-work-app/start.sh

profile-runtime: ensure-build
	bash scripts/profile-runtime.sh ./.work/chatgpt-work-app/start.sh

profile-runtime-constrained: ensure-build
	CHATGPT_WORK_PROFILE_SEED_CODEX_HOME=/nonexistent \
		CHATGPT_WORK_PROFILE_SEED_STATE=/nonexistent \
		CHATGPT_WORK_PROFILE_SEED_CONFIG=/nonexistent \
		CHATGPT_WORK_PROFILE_MEMORY_HIGH_MIB=704 CHATGPT_WORK_PROFILE_MEMORY_MAX_MIB=768 \
		bash scripts/profile-runtime.sh ./.work/chatgpt-work-app/start.sh

test:
	env PATH=/usr/bin:/bin cargo test --locked
	bash tests/upstream_tooling.sh
	bash tests/runtime_hardening.sh
	bash tests/codex_history_migration.sh
	python3 -m py_compile scripts/configure-work-runtime.py scripts/migrate-codex-history.py scripts/patch-compat-adapter.py scripts/patch-computer-use-wayland.py scripts/patch-work-asar.py scripts/validate-work-patch-report.py scripts/inspect-upstream.py

check:
	env PATH=/usr/bin:/bin cargo fmt --all -- --check
	env PATH=/usr/bin:/bin cargo clippy --workspace --all-targets --locked -- -D warnings
	$(MAKE) test
	bash -n scripts/*.sh
	desktop-file-validate packaging/linux/io.github.chatgpt_work_linux.desktop
	desktop-file-validate packaging/linux/chatgpt-work-linux.desktop
	desktop-file-validate packaging/flatpak/io.github.chatgpt_work_linux.desktop
	appstreamcli validate --pedantic --no-net packaging/linux/io.github.chatgpt_work_linux.metainfo.xml

sbom:
	mkdir -p dist
	SOURCE_DATE_EPOCH=0 CARGO_NET_OFFLINE=true cargo cyclonedx --format json --spec-version 1.5 --override-filename chatgpt-work-linux.cdx --all --target x86_64-unknown-linux-gnu --quiet
	bash scripts/normalize-sbom.sh chatgpt-work-linux.cdx.json '$(CURDIR)'
	mv -f chatgpt-work-linux.cdx.json dist/chatgpt-work-linux.cdx.json

refresh-upstream:
	bash scripts/refresh-upstream-snapshot.sh

update-user:
	bash scripts/update-user.sh

install-user: ensure-build
	bash scripts/install-user.sh

migrate-codex-history:
	python3 scripts/migrate-codex-history.py

uninstall-user:
	bash scripts/uninstall-user.sh

clean:
	env PATH=/usr/bin:/bin cargo clean
	rm -rf -- dist packaging/arch/pkg packaging/arch/src
