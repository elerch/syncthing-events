const std = @import("std");
const mvzr = @import("mvzr");

pub const Config = struct {
    syncthing_url: []const u8 = "http://localhost:8384",
    max_retries: usize = std.math.maxInt(usize),
    retry_delay_ms: u32 = 1000,
    watchers: []*Watcher,
};

pub const Watcher = struct {
    folder: []const u8,
    path_pattern: []const u8,
    command: []const u8,
    compiled_pattern: ?mvzr.Regex = null,

    pub fn matches(self: *Watcher, folder: []const u8, path: []const u8) bool {
        if (!std.mem.eql(u8, folder, self.folder)) {
            return false;
        }
        std.log.debug(
            "Watcher match on folder {s}. Checking path {s} against pattern {s}",
            .{ folder, path, self.path_pattern },
        );
        self.compiled_pattern = self.compiled_pattern orelse mvzr.compile(self.path_pattern);
        if (self.compiled_pattern == null) {
            std.log.err("watcher path_pattern failed to compile and will never match: {s}", .{self.path_pattern});
        }
        if (self.compiled_pattern) |pattern|
            return pattern.isMatch(path);
        return false;
    }
};

pub const SyncthingEvent = struct {
    id: i64,
    data_type: []const u8,
    folder: []const u8,
    path: []const u8,
    time: []const u8,

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !SyncthingEvent {
        const data = value.object.get("data").?.object;
        return SyncthingEvent{
            .id = value.object.get("id").?.integer,
            .time = value.object.get("time").?.string,
            .data_type = try allocator.dupe(u8, data.get("type").?.string),
            .folder = try allocator.dupe(u8, data.get("folder").?.string),
            .path = try allocator.dupe(u8, data.get("item").?.string),
        };
    }

    pub fn deinit(self: *SyncthingEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.data_type);
        allocator.free(self.time);
        allocator.free(self.folder);
        allocator.free(self.path);
    }
};

pub const EventPoller = struct {
    allocator: std.mem.Allocator,
    config: Config,
    last_id: ?i64,
    api_key: []u8,

    pub fn init(allocator: std.mem.Allocator, api_key: []u8, config: Config) !EventPoller {
        return .{
            .allocator = allocator,
            .config = config,
            .last_id = null,
            .api_key = api_key,
        };
    }

    pub fn poll(self: *EventPoller) ![]SyncthingEvent {
        var client = std.http.Client{ .allocator = self.allocator };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        try client.initDefaultProxies(aa);

        var auth_buf: [1024]u8 = undefined;
        const auth = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key});

        var retry_count: usize = 0;
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
                .headers = .{
                    .authorization = .{ .override = auth },
                },
            }) catch |err| {
                std.log.err("HTTP request failed: {s}", .{@errorName(err)});
                if (retry_count + 1 < self.config.max_retries) {
                    std.time.sleep(self.config.retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            if (response.status == .forbidden) return error.Unauthorized;
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

            std.log.debug("Got event response:\n{s}", .{al.items});
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
                } else if (std.mem.eql(u8, var_name, "id")) {
                    try std.fmt.format(result.writer(), "{d}", .{event.id});
                } else if (std.mem.eql(u8, var_name, "folder")) {
                    try result.appendSlice(event.folder);
                } else if (std.mem.eql(u8, var_name, "data_type")) {
                    try result.appendSlice(event.data_type);
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
        \\  "data": {
        \\    "folder": "default",
        \\    "item": "test.txt",
        \\    "type": "file"
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event_json, .{});
    defer parsed.deinit();

    var event = try SyncthingEvent.fromJson(std.testing.allocator, parsed.value);
    defer event.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 123), event.id);
    try std.testing.expectEqualStrings("file", event.data_type);
    try std.testing.expectEqualStrings("default", event.folder);
    try std.testing.expectEqualStrings("test.txt", event.path);
}

test "command variable expansion" {
    const event = SyncthingEvent{
        .id = 1,
        .data_type = "file",
        .folder = "photos",
        .path = "vacation.jpg",
    };

    const command = "convert ${path} -resize 800x600 thumb_${folder}_${id}.jpg";
    const expanded = try expandCommandVariables(std.testing.allocator, command, event);
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings(
        "convert vacation.jpg -resize 800x600 thumb_photos_1.jpg",
        expanded,
    );
}

test "watcher pattern matching" {
    var watcher = Watcher{
        .folder = "photos",
        .path_pattern = ".*\\.jpe?g$",
        .command = "echo ${path}",
    };

    try std.testing.expect(watcher.matches("photos", "test.jpg"));
    try std.testing.expect(watcher.matches("photos", "test.jpeg"));
    try std.testing.expect(!watcher.matches("photos", "test.png"));
    try std.testing.expect(!watcher.matches("documents", "test.jpg"));
}

test "end to end config / event" {
    const config_json =
        \\{
        \\  "syncthing_url": "http://test:8384",
        \\  "max_retries": 3,
        \\  "retry_delay_ms": 2000,
        \\  "watchers": [
        \\    {
        \\      "folder": "default",
        \\      "path_pattern": ".*\\.txt$",
        \\      "command": "echo ${path}"
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, config_json, .{});
    defer parsed.deinit();

    const config = parsed.value;

    const event_json =
        \\{
        \\  "id": 123,
        \\  "type": "ItemFinished",
        \\  "data": {
        \\    "folder": "default",
        \\    "item": "blah/test.txt",
        \\    "type": "file"
        \\  }
        \\}
    ;
    var parsed_event = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event_json, .{});
    defer parsed_event.deinit();
    var event = try SyncthingEvent.fromJson(std.testing.allocator, parsed_event.value);
    defer event.deinit(std.testing.allocator);

    try std.testing.expect(config.watchers[0].matches(event.folder, event.path));
}
