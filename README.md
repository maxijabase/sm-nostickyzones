# TF2 Sticky Removal Zones

## Description

TF2 Sticky Removal Zones is a SourceMod plugin for Team Fortress 2 that allows server administrators to create custom zones where stickybombs are automatically removed. This plugin enhances gameplay balance by preventing sticky spam in critical areas of the map.

## Features

- Create custom-sized sticky removal zones
- Team-specific zones (RED, BLU, or both)
- Visual representation of zones for easy management
- Automatic removal of stickybombs in designated areas
- Persistent zones across map changes and server restarts

## Installation

1. Ensure that you have SourceMod installed on your TF2 server.
2. Download the `nostickyzones.smx` file.
3. Place the file in your `addons/sourcemod/plugins/` directory.
4. Create a database configuration named "no_sticky_zones" in your `addons/sourcemod/configs/databases.cfg` file.
5. Restart your server or load the plugin using the `sm plugins load nostickyzones` command.

## Commands

| Command | Description | Required Flag |
|---------|-------------|---------------|
| `sm_stickyzones` | Opens the sticky removal zones menu | ADMFLAG_ROOT |
| `sm_showstickyzones` | Shows all sticky removal zones for 10 seconds | ADMFLAG_ROOT |

## Usage

1. Use the `sm_stickyzones` command to open the management menu.
2. To create a zone:
   - Select "Create Zone"
   - Set the width, length, and height of the zone
   - Choose the team(s) affected by the zone
   - Confirm the creation
3. To delete a zone, use the "Delete Nearest Zone" option while standing close to the zone you wish to remove.
4. Use `sm_showstickyzones` to visualize all existing zones on the map.

## Zone Visualization

- RED zones: Remove BLU stickybombs
- BLU zones: Remove RED stickybombs
- White zones: Remove stickybombs from both teams

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

