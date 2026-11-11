.DEFAULT_GOAL := build

.PHONY: build
build:
	zig build --summary all

.PHONY: release
release:
	zig build -Doptimize=ReleaseSmall --summary all

.PHONY: run
run:
	zig build run

.PHONY: test
test:
	zig build test --summary all

.PHONY: clean
clean:
	rm -rf .zig-cache zig-out zig-pkg

.PHONY: cleancache
cleancache:
	rm -rf ~/.cache/zig

.PHONY: cleanall
cleanall: cleancache clean
