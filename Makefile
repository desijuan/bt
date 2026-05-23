.DEFAULT_GOAL := build

build:
	zig build --summary all

release:
	zig build -Doptimize=ReleaseSmall --summary all

run:
	zig build run

test:
	zig build test --summary all

clean:
	rm -rf .zig-cache zig-out zig-pkg

.PHONY: build release run clean
