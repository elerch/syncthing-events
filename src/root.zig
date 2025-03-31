const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const mvzr = @import("mvzr");

pub const Config = struct {
    syncthing_url: []const u8 = "http://localhost:8384",
    max_retries: u32 = 5,
    retry_delay_ms: u32 = 1000,
    watchers: []Watcher,

    pub fn deinit(self: *Config, allocator: Allocator) void {
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
    compiled_pattern: ?mvzr.Pattern = null,

    pub fn init(allocator: Allocator, folder: []const u8, path_pattern: []const u8, command: []const u8) !Watcher {
        var watcher = Watcher{
            .folder = try allocator.dupe(u8, folder),
            .path_pattern = try allocator.dupe(u8, path_pattern),
            .command = try allocator.dupe(u8, command),
            .compiled_pattern = null,
        };
        watcher.compiled_pattern = try mvzr.Pattern.compile(allocator, path_pattern);
        return watcher;
    }

    pub fn deinit(self: *Watcher, allocator: Allocator) void {
        if (self.compiled_pattern) |*pattern| {
            pattern.deinit();
        }
        allocator.free(self.folder);
        allocator.free(self.path_pattern);
        allocator.free(self.command);
    }

    pub fn matches(self: *const Watcher, folder: []const u8, path: []const u8) bool {
        if (!std.mem.eql(u8, folder, self.folder)) {
            return false;
        }
        if (self.compiled_pattern) |pattern| {
            return pattern.match(path);
        }
        return false;
    }
};

pub const SyncthingEvent = struct {
    id: i64,
    type: []const u8,
    folder: []const u8,
    path: []const u8,
    
    pub fn fromJson(allocator: Allocator, value: json.Value) !SyncthingEvent {
        return SyncthingEvent{
            .id = value.object.get("id").?.integer,
            .type = try allocator.dupe(u8, value.object.get("type").?.string),
            .folder = try allocator.dupe(u8, value.object.get("folder").?.string),
            .path = try allocator.dupe(u8, value.object.get("path").?.string),
        };
    }

    pub fn deinit(self: *SyncthingEvent, allocator: Allocator) void {
        allocator.free(self.type);
        allocator.free(self.folder);
        allocator.free(self.path);
    }
};

pub const EventPoller = struct {
    allocator: Allocator,
    config: Config,
    last_id: i64,
    client: std.http.Client,

    pub fn init(allocator: Allocator, config: Config) !EventPoller {
        return EventPoller{
            .allocator = allocator,
            .config = config,
            .last_id = 0,
            .client = std.http.Client.init(allocator),
        };
    }

    pub fn deinit(self: *EventPoller) void {
        self.client.deinit();
    }

    pub fn poll(self: *EventPoller) ![]SyncthingEvent {
        var retry_count: u32 = 0;
        while (retry_count < self.config.max_retries) : (retry_count += 1) {
            var url_buf: [256]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "{s}/rest/events?events=ItemFinished&since={d}", .{
                self.config.syncthing_url, self.last_id,
            });

            var events = std.ArrayList(SyncthingEvent).init(self.allocator);
            errdefer events.deinit();

            var response = self.client.get(url) catch |err| {
                std.log.err("HTTP request failed: {s}", .{@errorName(err)});
                if (retry_count + 1 < self.config.max_retries) {
                    std.time.sleep(self.config.retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            defer response.deinit();

            if (response.status_code != 200) {
                std.log.err("HTTP status code: {d}", .{response.status_code});
                if (retry_count + 1 < self.config.max_retries) {
                    std.time.sleep(self.config.retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return error.HttpError;
            }

            var parser = json.Parser.init(self.allocator, false);
            defer parser.deinit();

            var tree = try parser.parse(response.body);
            defer tree.deinit();

            const array = tree.root.array;
            for (array.items) |item| {
                const event = try SyncthingEvent.fromJson(self.allocator, item);
                try events.append(event);
                if (event.id > self.last_id) {
                    self.last_id = event.id;
                }
            }

            return events.toOwnedSlice();
        }
        return error.MaxRetriesExceeded;
    }
};

pub fn executeCommand(allocator: Allocator, command: []const u8, event: SyncthingEvent) !void {
    var expanded_cmd = try expandCommandVariables(allocator, command, event);
    defer allocator.free(expanded_cmd);

    var process = std.ChildProcess.init(&[_][]const u8{ "sh", "-c", expanded_cmd }, allocator);
    process.stdout_behavior = .Inherit;
    process.stderr_behavior = .Inherit;

    _ = try process.spawnAndWait();
}

fn expandCommandVariables(allocator: Allocator, command: []const u8, event: SyncthingEvent) ![]const u8 {
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

    var parser = json.Parser.init(testing.allocator, false);
    defer parser.deinit();

    var tree = try parser.parse(config_json);
    defer tree.deinit();

    const config = try json.parse(Config, &tree, .{ .allocator = testing.allocator });
    defer config.deinit(testing.allocator);

    try testing.expectEqualStrings("http://test:8384", config.syncthing_url);
    try testing.expectEqual(@as(u32, 3), config.max_retries);
    try testing.expectEqual(@as(u32, 2000), config.retry_delay_ms);
    try testing.expectEqual(@as(usize, 1), config.watchers.len);
    try testing.expectEqualStrings("test", config.watchers[0].folder);
    try testing.expectEqualStrings(".*\\.txt$", config.watchers[0].path_pattern);
    try testing.expectEqualStrings("echo ${path}", config.watchers[0].command);
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

    var parser = json.Parser.init(testing.allocator, false);
    defer parser.deinit();

    var tree = try parser.parse(event_json);
    defer tree.deinit();

    var event = try SyncthingEvent.fromJson(testing.allocator, tree.root);
    defer event.deinit(testing.allocator);

    try testing.expectEqual(@as(i64, 123), event.id);
    try testing.expectEqualStrings("ItemFinished", event.type);
    try testing.expectEqualStrings("default", event.folder);
    try testing.expectEqualStrings("test.txt", event.path);
}

test "command variable expansion" {
    const event = SyncthingEvent{
        .id = 1,
        .type = "ItemFinished",
        .folder = "photos",
        .path = "vacation.jpg",
    };

    const command = "convert ${path} -resize 800x600 thumb_${folder}_${type}.jpg";
    const expanded = try expandCommandVariables(testing.allocator, command, event);
    defer testing.allocator.free(expanded);

    try testing.expectEqualStrings(
        "convert vacation.jpg -resize 800x600 thumb_photos_ItemFinished.jpg",
        expanded,
    );
}

test "watcher pattern matching" {
    var watcher = try Watcher.init(
        testing.allocator,
        "photos",
        ".*\\.jpe?g$",
        "echo ${path}",
    );
    defer watcher.deinit(testing.allocator);

    try testing.expect(watcher.matches("photos", "test.jpg"));
    try testing.expect(watcher.matches("photos", "test.jpeg"));
    try testing.expect(!watcher.matches("photos", "test.png"));
    try testing.expect(!watcher.matches("documents", "test.jpg"));
}