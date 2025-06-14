.DEFAULT_GOAL := build

build:
	zig build --summary all

run:
	zig build run

test:
	zig build test --summary all

clean:
	rm -rf .zig-cache zig-out

.PHONY: build run clean
