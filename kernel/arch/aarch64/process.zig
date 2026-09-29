//! Minimal ARM64 EL0 process state for the Phase 2 hello-service handoff.

pub const ProcessState = enum {
    ready,
    running,
    waiting,
    exited,
};

pub const Process = struct {
    pid: u64,
    state: ProcessState,
    entry: u64,
    stack_top: u64,
    parent: u64,
};

pub const init_pid: u64 = 1;
pub const hello_pid: u64 = 2;

test "minimal process states support the hello handoff" {
    const testing = @import("std").testing;
    var init = Process{ .pid = init_pid, .state = .running, .entry = 1, .stack_top = 2, .parent = 0 };
    var hello = Process{ .pid = hello_pid, .state = .ready, .entry = 3, .stack_top = 4, .parent = init_pid };
    init.state = .waiting;
    hello.state = .running;
    try testing.expectEqual(ProcessState.waiting, init.state);
    try testing.expectEqual(ProcessState.running, hello.state);
    hello.state = .exited;
    init.state = .running;
    try testing.expectEqual(ProcessState.exited, hello.state);
    try testing.expectEqual(ProcessState.running, init.state);
}
