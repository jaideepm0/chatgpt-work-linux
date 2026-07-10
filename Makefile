SHELL := /usr/bin/env bash
.DEFAULT_GOAL := build

.PHONY: build check clean doctor install-user package-pacman run test uninstall-user

build:
	env PATH=/usr/bin:/bin \
		RUSTFLAGS='--remap-path-prefix=$(CURDIR)=/usr/src/chatgpt-work-linux' \
		cargo build --release --locked

run:
	env PATH=/usr/bin:/bin cargo run --locked --

doctor:
	env PATH=/usr/bin:/bin cargo run --locked -- doctor

test:
	env PATH=/usr/bin:/bin cargo test --locked
	bash tests/upstream_tooling.sh

check:
	env PATH=/usr/bin:/bin cargo fmt --all -- --check
	env PATH=/usr/bin:/bin cargo clippy --workspace --all-targets --locked -- -D warnings
	$(MAKE) test
	bash -n scripts/*.sh
	desktop-file-validate packaging/linux/chatgpt-work-linux.desktop
	appstreamcli validate --pedantic packaging/linux/io.github.chatgpt_work_linux.metainfo.xml

package-pacman:
	bash scripts/build-pacman.sh

install-user:
	bash scripts/install-user.sh

uninstall-user:
	bash scripts/uninstall-user.sh

clean:
	env PATH=/usr/bin:/bin cargo clean
	rm -rf -- dist packaging/arch/pkg packaging/arch/src
