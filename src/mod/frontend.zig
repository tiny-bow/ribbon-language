//! # The Frontend Service
// ... (module documentation remains the same) ...

const frontend = @This();

const std = @import("std");
const log = std.log.scoped(.frontend);

const common = @import("common");
const core = @import("core");
const ir = @import("ir");
const analysis = @import("analysis");
const orchestration = @import("orchestration");
const meta_language = @import("meta_language");
const bytecode = @import("bytecode");

test {
    std.testing.refAllDecls(@This());
}
