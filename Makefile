SHELL := /usr/bin/env bash
.DEFAULT_GOAL := build

.PHONY: build check clean doctor install-user refresh-upstream run sbom smoke-wayland test uninstall-user

build:
	bash scripts/fetch-upstream.sh
	bash scripts/build-work-app.sh ./ChatGPT-work.dmg

run: build
	./.work/chatgpt-work-app/start.sh

doctor: build
	./.work/chatgpt-work-app/start.sh doctor

smoke-wayland: build
	bash scripts/smoke-wayland.sh ./.work/chatgpt-work-app/start.sh

test:
	env PATH=/usr/bin:/bin cargo test --locked
	bash tests/upstream_tooling.sh
	bash tests/runtime_hardening.sh
	python3 -m py_compile scripts/configure-work-runtime.py scripts/patch-computer-use-wayland.py scripts/patch-work-asar.py scripts/validate-work-patch-report.py scripts/inspect-upstream.py

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

install-user: build
	bash scripts/install-user.sh

uninstall-user:
	bash scripts/uninstall-user.sh

clean:
	env PATH=/usr/bin:/bin cargo clean
	rm -rf -- dist packaging/arch/pkg packaging/arch/src
