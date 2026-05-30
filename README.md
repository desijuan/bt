<a href="https://asciinema.org/a/pPjSg1Dmwl7T1dPT"><img src="https://asciinema.org/a/pPjSg1Dmwl7T1dPT.svg" alt="bt demo" width="100%"/></a>

# bt

A small command-line BitTorrent client written in Zig using io_uring.

**bt** is an experiment in low-level asynchronous networking:

- concurrent peer communication
- finite state machines
- direct Linux async I/O via liburing (io_uring)
- low resource usage

## Current status

The client is already capable of:

- parsing .torrent files
- communicating with trackers
- obtaining peer lists
- opening many concurrent peer connections
- performing BitTorrent handshakes
- requesting blocks from peers

bt can maintain dozens of concurrent peer connections simultaneously. In practice, if
we define a successful peer intereaction as completing the handshake and requesting a block, with
around 45 peers contacted concurrently, the client usually reaches between 10 and 20 successful peer
interactions.

It is already capable of surviving real-world peer/network failures including: timeouts, refused
connections, resets, invalid responses and partial protocol flows.

And has already been tested and successfully interoperated with multiple real-world BitTorrent
clients including qBittorrent, Transmission and libtorrent-based peers.

The downloading pipeline is still work in progress.

## Design goals

bt is intentionally designed as a low-level Linux networking project.

The goal is not to build a feature-rich torrent client, but rather to explore:

- asynchronous network programming
- event-driven architectures
- I/O with io_uring
- finite state machines
- manual memory handling without comprimising safety
- efficient resource usage

The implementation uses:

- Zig
- liburing
- non-blocking sockets
- a single-threaded event loop
- explicit FSM transitions

No async runtime or heavyweight framework is used.

The explicit FSM approach proved particularly useful for debugging protocol transitions and
recovering from peer/network failures.

## Build

### Release

zig build -Doptimize=ReleaseFast --summary all

### Debug

zig build --summary all

## Architecture

Each peer connection is represented by a finite state machine.

The client tracks:

- the current connection state
- the last operation submitted to the ring
- protocol-specific context

Incoming events are processed by mapping:

`(state, operation, message) -> (new_state, next_operation)`

This model turned out to work extremely well for expressing the BitTorrent protocol flow while
keeping the implementation explicit and debuggable.

## Connection lifecycle

For each peer, bt currently performs:

- socket creation
- connection to peer
- BitTorrent handshake
- peer response validation
- piece/block request
- block reception (partial WIP)

All socket operations are driven through io_uring using the zig standard library, that wraps around
liburing.

## Configuration

Concurrency level can be configured in config.zon via the value `n_clients`. For example, if we
would want 8 concurrent connections, we would set the following in the file `./config.zon`:

```zig
.{
    .n_clients = 8,
}
```

Other configurable parameters include:

- max_keepalives: maximum amount of keepalives before closing the connection
- timeout_ms: maximum time (in milliseconds) a TCP connection may remain unacknowledged before it is
  terminated

The default values are defined in the file `src/Config.zon`:

```zig
n_clients: u16 = 1,
max_keepalives: u16 = 8,
timeout_ms: c_int = 2000,
```

## io_uring

bt uses io_uring via liburing directly instead of epoll/libuv-style abstractions.

This provides:

- fewer dependencies
- very small binary size (~700kB)
- a clean event-driven architecture
- explicit submission/completion semantics
- efficient concurrent socket management
- low syscall overhead

## Download FSM (WIP)

The full downloading sub-state-machine is still under development.

Remaining work includes:

- partial message handling
- block assembly
- piece verification
- download scheduling
- writing verified pieces to disk
- Choke handling

## Notes

bt is currently developed and tested on Linux only.
The implementation assumes a somewhat modern Linux kernel supporting io_uring.

## Performance characteristics

On a 2025 AMD Ryzen 7 laptop with 24 GB RAM, running on Linux with the following in the
`./config.zon` file:

```zig
.{
    .n_clients = 8,
}
```

bt contacted 43 peers, achieving 9 successful unchokes in concurrent peer communication lasting
~9.6 seconds while using very few resources:

```
real    0m9.608s
user    0m0.003s
sys     0m0.021s
```

The extremely low CPU time is one of the primary goals of the project:

- the process spends most of its lifetime blocked inside io_uring
- socket operations are fully event-driven
- no busy polling or thread-per-connection model is used
- peer concurrency is handled inside a single-threaded event loop

While the downloading pipeline is still incomplete, current results already suggest that the
architecture scales efficiently with very low CPU overhead.

## License

Released under the MIT License.
