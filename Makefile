default: build

build:
	zig build --summary all

run:
	@zig build run

clean:
	rm -rf .zig-cache zig-out

.PHONY: default build run clean
