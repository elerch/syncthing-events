const std = @import("std");
const mvzr = @import("mvzr");
const zeit = @import("zeit");

pub const Config = struct {
    syncthing_url: []const u8 = "http://localhost:8384",
    max_retries: usize = std.math.maxInt(usize),
    retry_delay_ms: u32 = 1000,
    watchers: []*Watcher,
};

pub const Watcher = struct {
    folder: []const u8,
    path_pattern: []const u8,
    action: []const u8 = "*",
    event_type: []const u8 = "ItemFinished",
    command: []const u8,
    compiled_pattern: ?mvzr.Regex = null,

    pub fn matches(self: *Watcher, event: SyncthingEvent) bool {
        if (!std.mem.eql(u8, event.folder, self.folder)) {
            return false;
        }
        if (!std.mem.eql(u8, event.event_type, self.event_type)) {
            return false;
        }
        std.log.debug(
            "Watcher match on folder {s}/event type {s}. Checking path {s} against pattern {s}",
            .{ event.folder, event.event_type, event.path, self.path_pattern },
        );
        const action_match =
            (self.action.len == 1 and self.action[0] == '*') or
            std.mem.eql(u8, event.action, self.action);
        if (!action_match) {
            std.log.debug(
                "Event action {s}, but watching for action {s}. Skipping command",
                .{ event.action, self.action },
            );
            return false;
        }
        self.compiled_pattern = self.compiled_pattern orelse mvzr.compile(self.path_pattern);
        if (self.compiled_pattern == null) {
            std.log.err("watcher path_pattern failed to compile and will never match: {s}", .{self.path_pattern});
        }
        if (self.compiled_pattern) |pattern|
            return pattern.isMatch(event.path);
        return false;
    }
};

pub const SyncthingEvent = struct {
    id: i64,
    event_type: []const u8,
    data_type: []const u8,
    folder: []const u8,
    path: []const u8,
    action: []const u8,
    time: []const u8,

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !SyncthingEvent {
        const data = value.object.get("data").?.object;
        // event values differ on this point...
        const path = data.get("item") orelse data.get("path");
        return SyncthingEvent{
            .id = value.object.get("id").?.integer,
            .time = try allocator.dupe(u8, value.object.get("time").?.string),
            .event_type = try allocator.dupe(u8, value.object.get("type").?.string),
            .data_type = try allocator.dupe(u8, data.get("type").?.string),
            .folder = try allocator.dupe(u8, data.get("folder").?.string),
            .action = try allocator.dupe(u8, data.get("action").?.string),
            .path = try allocator.dupe(u8, path.?.string),
        };
    }

    pub fn deinit(self: *SyncthingEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.data_type);
        allocator.free(self.time);
        allocator.free(self.folder);
        allocator.free(self.action);
        allocator.free(self.path);
    }
};

pub const EventPoller = struct {
    allocator: std.mem.Allocator,
    config: Config,
    last_id: ?i64,
    api_key: []u8,
    connection_pool: std.http.Client.ConnectionPool,

    pub fn init(allocator: std.mem.Allocator, api_key: []u8, config: Config, connection_pool: ?std.http.Client.ConnectionPool) !EventPoller {
        return .{
            .allocator = allocator,
            .config = config,
            .last_id = null,
            .api_key = api_key,
            .connection_pool = connection_pool orelse .{},
        };
    }

    pub fn url(self: EventPoller) ![]const u8 {
        const watched_events = blk: {
            var type_set = std.StringArrayHashMap(void).init(self.allocator);
            try type_set.ensureTotalCapacity(self.config.watchers.len);
            for (self.config.watchers) |watcher|
                type_set.putAssumeCapacity(watcher.event_type, {});
            break :blk try std.mem.join(self.allocator, ",", type_set.keys());
        };
        var since_buf: [100]u8 = undefined;
        const since = if (self.last_id) |id|
            try std.fmt.bufPrint(&since_buf, "&since={d}", .{id})
        else
            "";
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}/rest/events?events={s}{s}",
            .{
                self.config.syncthing_url, watched_events, since,
            },
        );
    }

    pub fn poll(self: *EventPoller) ![]SyncthingEvent {
        var client = std.http.Client{ .allocator = self.allocator, .connection_pool = self.connection_pool };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        try client.initDefaultProxies(aa);

        var auth_buf: [1024]u8 = undefined;
        const auth = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key});

        var ucf_retries: usize = 0;
        const MAX_UCF_RETRIES: usize = 20;
        var retry_count: usize = 0;
        const first_run = self.last_id == null;
        const poll_url = try self.url();
        while (retry_count < self.config.max_retries) : (retry_count += 1) {
            var al = std.ArrayList(u8).init(self.allocator);
            defer al.deinit();

            const response = client.fetch(.{
                .location = .{ .url = poll_url },
                .response_storage = .{ .dynamic = &al },
                .headers = .{
                    .authorization = .{ .override = auth },
                },
            }) catch |err| {
                if (err == error.UnexpectedConnectFailure) {
                    ucf_retries += 1;
                    std.log.err(
                        "Unexpected connection failure - may not be recoverable. Retry {d}/{d}",
                        .{ ucf_retries, MAX_UCF_RETRIES },
                    );
                    if (ucf_retries >= MAX_UCF_RETRIES) return error.MaximumUnexpectedConnectionFailureRetriesExceeded;
                    continue;
                } else std.log.err("HTTP request failed: {s}", .{@errorName(err)});
                if (retry_count + 1 < self.config.max_retries) {
                    std.time.sleep(self.config.retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            ucf_retries = 0;

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

            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, al.items, .{});

            const array = parsed.array;
            if (first_run)
                std.log.info("Got first run event response with {d} items", .{array.items.len})
            else if (array.items.len > 0)
                std.log.debug("Got event response:\n{s}", .{al.items});

            var skipped_events: usize = 0;
            for (array.items) |item| {
                var event = try SyncthingEvent.fromJson(self.allocator, item);
                if (self.last_id == null or event.id > self.last_id.?)
                    self.last_id = event.id;
                if (first_run and try eventIsOld(event)) {
                    skipped_events += 1;
                    event.deinit(self.allocator);
                    continue;
                }

                try events.append(event);
            }
            if (skipped_events > 0)
                std.log.info("Skipped {d} old events", .{skipped_events});

            return try events.toOwnedSlice();
        }
        return error.MaxRetriesExceeded;
    }
};

pub fn eventIsOld(event: SyncthingEvent) !bool {
    const event_instant = try zeit.instant(.{ .source = .{ .rfc3339 = event.time } });
    var recent = try zeit.instant(.{});
    recent.timestamp -= std.time.ns_per_s * 60; // Grab any events newer than the last minute
    return event_instant.time().before(recent.time());
}

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
        \\      "action": "update",
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
        \\  "time": "2025-04-01T11:43:51.581184474-07:00",
        \\  "type": "ItemFinished",
        \\  "data": {
        \\    "folder": "default",
        \\    "item": "test.txt",
        \\    "action": "update",
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
        .action = "update",
        .time = "2025-04-01T11:43:51.586762264-07:00",
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
        .action = "update",
    };

    try std.testing.expect(watcher.matches(.{ .folder = "photos", .path = "test.jpg", .data_type = "update", .event_type = "ItemFinished" }));
    try std.testing.expect(watcher.matches(.{ .folder = "photos", .path = "test.jpeg", .data_type = "update", .event_type = "ItemFinished" }));
    try std.testing.expect(watcher.matches(.{ .folder = "photos", .path = "test.png", .data_type = "update", .event_type = "ItemFinished" }));
    try std.testing.expect(watcher.matches(.{ .folder = "documents", .path = "test.jpg", .data_type = "update", .event_type = "ItemFinished" }));
    try std.testing.expect(watcher.matches(.{ .folder = "photos", .path = "test.jpeg", .data_type = "delete", .event_type = "ItemFinished" }));
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
        \\      "action": "update",
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
        \\  "time": "2025-04-01T11:43:51.581184474-07:00",
        \\  "data": {
        \\    "folder": "default",
        \\    "item": "blah/test.txt",
        \\    "type": "file",
        \\    "action": "update"
        \\  }
        \\}
    ;
    var parsed_event = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event_json, .{});
    defer parsed_event.deinit();
    var event = try SyncthingEvent.fromJson(std.testing.allocator, parsed_event.value);
    defer event.deinit(std.testing.allocator);

    try std.testing.expect(config.watchers[0].matches(event));
}
