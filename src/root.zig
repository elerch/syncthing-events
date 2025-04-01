const std = @import("std");
const mvzr = @import("mvzr");

pub const Config = struct {
    syncthing_url: []const u8 = "http://localhost:8384",
    max_retries: usize = std.math.maxInt(usize),
    retry_delay_ms: u32 = 1000,
    watchers: []Watcher,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.watchers) |*watcher| {
            watcher.deinit(allocator);
        }
        allocator.free(self.watchers);
    }
};

pub const Watcher = struct {
    folder: []const u8,
    path_pattern: []const u8,
    command: []const u8,
    compiled_pattern: ?mvzr.Regex = null,

    pub fn init(allocator: std.mem.Allocator, folder: []const u8, path_pattern: []const u8, command: []const u8) !Watcher {
        var watcher = Watcher{
            .folder = try allocator.dupe(u8, folder),
            .path_pattern = try allocator.dupe(u8, path_pattern),
            .command = try allocator.dupe(u8, command),
            .compiled_pattern = null,
        };
        watcher.compiled_pattern = mvzr.compile(path_pattern);
        return watcher;
    }

    pub fn deinit(self: *Watcher, allocator: std.mem.Allocator) void {
        allocator.free(self.folder);
        allocator.free(self.path_pattern);
        allocator.free(self.command);
    }

    pub fn matches(self: *const Watcher, folder: []const u8, path: []const u8) bool {
        if (!std.mem.eql(u8, folder, self.folder)) {
            return false;
        }
        if (self.compiled_pattern) |pattern| {
            return pattern.match(path) != null;
        }
        return false;
    }
};

pub const SyncthingEvent = struct {
    id: i64,
    type: []const u8,
    folder: []const u8,
    path: []const u8,

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !SyncthingEvent {
        return SyncthingEvent{
            .id = value.object.get("id").?.integer,
            .type = try allocator.dupe(u8, value.object.get("type").?.string),
            .folder = try allocator.dupe(u8, value.object.get("folder").?.string),
            .path = try allocator.dupe(u8, value.object.get("path").?.string),
        };
    }

    pub fn deinit(self: *SyncthingEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.type);
        allocator.free(self.folder);
        allocator.free(self.path);
    }
};

pub const EventPoller = struct {
    allocator: std.mem.Allocator,
    config: Config,
    last_id: ?i64,

    pub fn init(allocator: std.mem.Allocator, config: Config) !EventPoller {
        return .{
            .allocator = allocator,
            .config = config,
            .last_id = null,
        };
    }

    pub fn poll(self: *EventPoller) ![]SyncthingEvent {
        var client = std.http.Client{ .allocator = self.allocator };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        try client.initDefaultProxies(aa);

        var retry_count: usize = self.config.max_retries;
        while (retry_count < self.config.max_retries) : (retry_count += 1) {
            var url_buf: [1024]u8 = undefined;
            var since_buf: [100]u8 = undefined;
            const since = if (self.last_id) |id|
                try std.fmt.bufPrint(&since_buf, "&since={d}", .{id})
            else
                "";
            const url = try std.fmt.bufPrint(&url_buf, "{s}/rest/events?events=ItemFinished{s}", .{
                self.config.syncthing_url, since,
            });

            var al = std.ArrayList(u8).init(self.allocator);
            defer al.deinit();

            const response = client.fetch(.{
                .location = .{ .url = url },
                .response_storage = .{ .dynamic = &al },
            }) catch |err| {
                std.log.err("HTTP request failed: {s}", .{@errorName(err)});
                if (retry_count + 1 < self.config.max_retries) {
                    std.time.sleep(self.config.retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            if (response.status != .ok) {
                std.log.err("HTTP status code: {}", .{response.status});
                if (retry_count + 1 < self.config.max_retries) {
                    std.time.sleep(self.config.retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return error.HttpError;
            }

            var events = std.ArrayList(SyncthingEvent).init(self.allocator);
            errdefer events.deinit();

            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, al.items, .{});

            const array = parsed.array;
            for (array.items) |item| {
                const event = try SyncthingEvent.fromJson(self.allocator, item);
                try events.append(event);
                if (self.last_id == null or event.id > self.last_id.?) {
                    self.last_id = event.id;
                }
            }

            return try events.toOwnedSlice();
        }
        return error.MaxRetriesExceeded;
    }
};

pub fn executeCommand(allocator: std.mem.Allocator, command: []const u8, event: SyncthingEvent) !void {
    const expanded_cmd = try expandCommandVariables(allocator, command, event);
    defer allocator.free(expanded_cmd);

    // TODO: Should this spawn sh like this, or exec directly?
    var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", expanded_cmd }, allocator);
    process.stdout_behavior = .Inherit;
    process.stderr_behavior = .Inherit;

    _ = try process.spawnAndWait();
}

fn expandCommandVariables(allocator: std.mem.Allocator, command: []const u8, event: SyncthingEvent) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < command.len) {
        if (command[i] == '$' and i + 1 < command.len and command[i + 1] == '{') {
            var j = i + 2;
            while (j < command.len and command[j] != '}') : (j += 1) {}
            if (j < command.len) {
                const var_name = command[i + 2 .. j];
                if (std.mem.eql(u8, var_name, "path")) {
                    try result.appendSlice(event.path);
                } else if (std.mem.eql(u8, var_name, "folder")) {
                    try result.appendSlice(event.folder);
                } else if (std.mem.eql(u8, var_name, "type")) {
                    try result.appendSlice(event.type);
                }
                i = j + 1;
                continue;
            }
        }
        try result.append(command[i]);
        i += 1;
    }

    return result.toOwnedSlice();
}

test "config parsing" {
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

    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, config_json, .{});
    defer parsed.deinit();

    const config = parsed.value;

    try std.testing.expectEqualStrings("http://test:8384", config.syncthing_url);
    try std.testing.expectEqual(@as(u32, 3), config.max_retries);
    try std.testing.expectEqual(@as(u32, 2000), config.retry_delay_ms);
    try std.testing.expectEqual(@as(usize, 1), config.watchers.len);
    try std.testing.expectEqualStrings("test", config.watchers[0].folder);
    try std.testing.expectEqualStrings(".*\\.txt$", config.watchers[0].path_pattern);
    try std.testing.expectEqualStrings("echo ${path}", config.watchers[0].command);
}

test "event parsing" {
    const event_json =
        \\{
        \\  "id": 123,
        \\  "type": "ItemFinished",
        \\  "folder": "default",
        \\  "path": "test.txt"
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event_json, .{});
    defer parsed.deinit();

    var event = try SyncthingEvent.fromJson(std.testing.allocator, parsed.value);
    defer event.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 123), event.id);
    try std.testing.expectEqualStrings("ItemFinished", event.type);
    try std.testing.expectEqualStrings("default", event.folder);
    try std.testing.expectEqualStrings("test.txt", event.path);
}

test "command variable expansion" {
    const event = SyncthingEvent{
        .id = 1,
        .type = "ItemFinished",
        .folder = "photos",
        .path = "vacation.jpg",
    };

    const command = "convert ${path} -resize 800x600 thumb_${folder}_${type}.jpg";
    const expanded = try expandCommandVariables(std.testing.allocator, command, event);
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings(
        "convert vacation.jpg -resize 800x600 thumb_photos_ItemFinished.jpg",
        expanded,
    );
}

test "watcher pattern matching" {
    var watcher = try Watcher.init(
        std.testing.allocator,
        "photos",
        ".*\\.jpe?g$",
        "echo ${path}",
    );
    defer watcher.deinit(std.testing.allocator);

    try std.testing.expect(watcher.matches("photos", "test.jpg"));
    try std.testing.expect(watcher.matches("photos", "test.jpeg"));
    try std.testing.expect(!watcher.matches("photos", "test.png"));
    try std.testing.expect(!watcher.matches("documents", "test.jpg"));
}
