const std = @import("std");
const lib = @import("syncthing_events_lib");
const Config = lib.Config;
const EventPoller = lib.EventPoller;

const Args = struct {
    config_path: []const u8 = "config.json",
    syncthing_url: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);

    var parsed_config = try loadConfig(allocator, args.config_path);
    defer parsed_config.deinit();
    var config = parsed_config.value;

    if (args.syncthing_url) |url| {
        config.syncthing_url = url;
    }

    var poller = try EventPoller.init(allocator, config);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Monitoring Syncthing events at {s}\n", .{config.syncthing_url});

    while (true) {
        const events = poller.poll() catch |err| {
            std.log.err("Error polling events: {s}", .{@errorName(err)});
            continue;
        };
        defer {
            for (events) |*event| {
                event.deinit(allocator);
            }
            allocator.free(events);
        }

        for (events) |event| {
            for (config.watchers) |watcher| {
                if (watcher.matches(event.folder, event.path)) {
                    try stdout.print("Match found for {s}/{s}, executing command\n", .{ event.folder, event.path });
                    try lib.executeCommand(allocator, watcher.command, event);
                }
            }
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = Args{};
    var arg_it = try std.process.ArgIterator.initWithAllocator(allocator);
    defer arg_it.deinit();

    // Skip program name
    _ = arg_it.skip();

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            if (arg_it.next()) |config_path| {
                args.config_path = try allocator.dupe(u8, config_path);
            } else {
                std.debug.print("Error: --config requires a path argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--url")) {
            if (arg_it.next()) |url| {
                args.syncthing_url = try allocator.dupe(u8, url);
            } else {
                std.debug.print("Error: --url requires a URL argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        }
    }

    return args;
}

fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Config) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const max_size = 1024 * 1024; // 1MB max config size
    const content = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(content);

    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".json")) {
        return try std.json.parseFromSlice(Config, allocator, content, .{});
    } else if (std.mem.eql(u8, ext, ".zon")) {
        // TODO: Implement ZON parsing
        return error.UnsupportedConfigFormat;
    } else if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) {
        // TODO: Implement YAML parsing
        return error.UnsupportedConfigFormat;
    } else {
        return error.UnsupportedConfigFormat;
    }
}

fn printUsage() void {
    const usage =
        \\Usage: syncthing_events [options]
        \\
        \\Options:
        \\  --config <path>  Path to config file (default: config.json)
        \\  --url <url>      Override Syncthing URL from config
        \\  --help          Show this help message
        \\
    ;
    std.debug.print(usage, .{});
}

test "argument parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test default values
    const default_args = try parseArgs(allocator);
    try testing.expectEqualStrings("config.json", default_args.config_path);
    try testing.expectEqual(@as(?[]const u8, null), default_args.syncthing_url);
}

test "config loading" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a temporary config file
    const config_json =
        \\{
        \\  "syncthing_url": "http://test:8384",
        \\  "max_retries": 3,
        \\  "retry_delay_ms": 2000,
        \\  "watchers": [
        \\    {
        \\      "folder": "test",
        \\      "path_pattern": ".*\\.txt$",
        \\      "command": "echo ${path}"
        \\    }
        \\  ]
        \\}
    ;

    try std.fs.cwd().writeFile("test_config.json", config_json);
    defer std.fs.cwd().deleteFile("test_config.json") catch {};

    const config = try loadConfig(allocator, "test_config.json");
    defer config.deinit(allocator);

    try testing.expectEqualStrings("http://test:8384", config.syncthing_url);
    try testing.expectEqual(@as(u32, 3), config.max_retries);
    try testing.expectEqual(@as(u32, 2000), config.retry_delay_ms);
    try testing.expectEqual(@as(usize, 1), config.watchers.len);
}
