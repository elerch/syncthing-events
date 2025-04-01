const std = @import("std");
const lib = @import("syncthing_events_lib");
const Config = lib.Config;
const EventPoller = lib.EventPoller;

const Args = struct {
    config_path: []const u8 = "config.json",
    syncthing_url: ?[]const u8 = null,
};

pub fn main() !u8 {
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

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Monitoring Syncthing events at {s}\n", .{config.syncthing_url});

    while (true) {
        var arena_alloc = std.heap.ArenaAllocator.init(allocator);
        defer arena_alloc.deinit();
        const arena = arena_alloc.allocator();

        var poller = try EventPoller.init(arena, config);
        const events = poller.poll() catch |err| switch (err) {
            error.Unauthorized => {
                std.log.err("Not authorized to use syncthing. Please set ST_EVENTS_AUTH environment variable and try again", .{});
                return 2;
            },
            error.MaxRetriesExceeded => {
                std.log.err("Maximum retries exceeded - exiting", .{});
                return 1;
            },
            else => {
                std.log.err("Error polling events: {s}", .{@errorName(err)});
                continue;
            },
        };

        for (events) |event| {
            for (config.watchers) |watcher| {
                if (watcher.matches(event.folder, event.path)) {
                    try stdout.print("Match found for {s}/{s}, executing command\n", .{ event.folder, event.path });
                    try lib.executeCommand(allocator, watcher.command, event);
                }
            }
        }
    }
    return 0;
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

    return try parseConfig(allocator, content, try detectFileType(path));
}

const FileType = enum {
    json,
    zon,
    yaml,
};

fn detectFileType(path: []const u8) !FileType {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".json"))
        return .json;
    if (std.mem.eql(u8, ext, ".zon"))
        return .zon;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml"))
        return .yaml;
    return error.UnknownFileType;
}

fn parseConfig(allocator: std.mem.Allocator, content: []const u8, file_type: FileType) !std.json.Parsed(Config) {
    return switch (file_type) {
        .json => try std.json.parseFromSlice(Config, allocator, content, .{}),
        .zon => error.UnsupportedConfigFormat, // TODO: Implement ZON parsing
        .yaml => error.UnsupportedConfigFormat, // TODO: Implement YAML parsing
    };
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

    // Test code:
    const parsed_config = try parseConfig(allocator, config_json, .json);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    try testing.expectEqualStrings("http://test:8384", config.syncthing_url);
    try testing.expectEqual(@as(u32, 3), config.max_retries);
    try testing.expectEqual(@as(u32, 2000), config.retry_delay_ms);
    try testing.expectEqual(@as(usize, 1), config.watchers.len);
}
