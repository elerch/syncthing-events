# Syncthing Events Handler

A command-line application written in Zig that monitors Syncthing events and executes configured actions based on file changes.

## Features

- Continuously polls Syncthing events API
- Configurable event filtering based on folder and path patterns
- Executes custom commands when matching events are detected
- Supports JSON, ZON, or YAML configuration formats

## Installation

```bash
zig build
```

The executable will be created in `zig-out/bin/syncthing_events`

## Configuration

Create a configuration file in either JSON, ZON, or YAML format. Example (in JSON):

```json
{
  "syncthing_url": "http://localhost:8384",
  "poll_interval_ms": 1000,
  "watchers": [
    {
      "folder": "default",
      "path_pattern": ".*\\.pdf$",
      "command": "pdftotext \"${path}\" \"${path}.txt\""
    },
    {
      "folder": "photos",
      "path_pattern": ".*\\.(jpg|jpeg|png)$",
      "command": "convert \"${path}\" -resize 800x600 \"${path}.thumb.jpg\""
    }
  ]
}
```

### Configuration Options

- `syncthing_url`: Base URL of your Syncthing instance (default: http://localhost:8384)
- `poll_interval_ms`: How often to check for new events in milliseconds (default: 1000)
- `watchers`: Array of event watchers with the following properties:
  - `folder`: Syncthing folder ID to watch
  - `path_pattern`: Regular expression to match file paths
  - `action`: Action to match on (deleted, updated, modified, etc). Defaults to '*', which is all actions
  - `event_type`: [Event type](https://docs.syncthing.net/dev/events.html#event-types) to match on. Defaults to ItemFinished
  - `command`: Command to execute when a match is found. Supports variables:
    - `${path}`: Full path to the changed file
    - `${folder}`: Folder ID where the change occurred
    - `${type}`: Event type (e.g., "ItemFinished")

## Usage

```bash
# Run with default configuration file (config.json)
syncthing_events

# Specify a custom configuration file
syncthing_events --config my-config.yaml

# Override Syncthing URL
syncthing_events --url http://syncthing:8384
```

## Development

This project uses a devfile for consistent development environments. To start developing:

1. Install a compatible IDE/editor that supports devfile (e.g., VS Code with DevContainer extension)
2. Open the project folder
3. The development container will be automatically built with Zig 0.14.0

### Running Tests

```bash
zig build test
```

## License

MIT License
