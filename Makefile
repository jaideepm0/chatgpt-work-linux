SHELL := /usr/bin/env bash
.DEFAULT_GOAL := build

.PHONY: build check clean doctor install-user package-flatpak package-pacman run sbom smoke-wayland test uninstall-user

build:
	env PATH=/usr/bin:/bin \
		RUSTFLAGS='--remap-path-prefix=$(CURDIR)=/usr/src/chatgpt-work-linux --remap-path-prefix=$(HOME)/.cargo=/usr/src/cargo --remap-path-prefix=$(HOME)/.rustup=/usr/src/rustup' \
		cargo build --release --locked

run:
	env PATH=/usr/bin:/bin cargo run --locked --

doctor:
	env PATH=/usr/bin:/bin cargo run --locked -- doctor

smoke-wayland: build
	bash scripts/smoke-wayland.sh ./target/release/chatgpt-work-linux

test:
	env PATH=/usr/bin:/bin cargo test --locked
	bash tests/upstream_tooling.sh

check:
	env PATH=/usr/bin:/bin cargo fmt --all -- --check
	env PATH=/usr/bin:/bin cargo clippy --workspace --all-targets --locked -- -D warnings
	$(MAKE) test
	bash -n scripts/*.sh
	desktop-file-validate packaging/linux/io.github.chatgpt_work_linux.desktop
	desktop-file-validate packaging/flatpak/io.github.chatgpt_work_linux.desktop
	appstreamcli validate --pedantic packaging/linux/io.github.chatgpt_work_linux.metainfo.xml
	flatpak-builder --show-manifest packaging/flatpak/io.github.chatgpt_work_linux.yml >/dev/null

package-pacman:
	bash scripts/build-pacman.sh

package-flatpak:
	bash scripts/build-flatpak.sh

sbom:
	mkdir -p dist
	SOURCE_DATE_EPOCH=0 CARGO_NET_OFFLINE=true cargo cyclonedx --format json --spec-version 1.5 --override-filename chatgpt-work-linux.cdx --all --target x86_64-unknown-linux-gnu --quiet
	mv -f chatgpt-work-linux.cdx.json dist/chatgpt-work-linux.cdx.json

install-user:
	bash scripts/install-user.sh

uninstall-user:
	bash scripts/uninstall-user.sh

clean:
	env PATH=/usr/bin:/bin cargo clean
	rm -rf -- dist packaging/arch/pkg packaging/arch/src
