# Clear Dock

A replacement for the macOS Dock, with a customisable top bar and a lock-in mode for focusing on a few windows.

It's built to stay light. In testing it used about 18 MB of memory at start and under 1% of one CPU core at rest.

## Features

**Dock**

- Sits on the left, bottom or right of the screen, and can hide until the pointer reaches the edge
- Lets you choose the icon style, shape, size, spacing and hover effect
- Offers no background, glass, a colour or your wallpaper behind the icons
- Shows window previews when you point at an app, and an app's windows when you scroll up on its icon
- Includes notification badges, the Trash and the apps pinned in your macOS Dock

**Top bar**

- Shows your desktops, the app in front, lock-in mode, the song playing, volume, battery, and the date and time
- Lets you turn each item on or off and place it on the left or right
- Takes on the colour of the desktop you're on
- Can replace the macOS menu bar, with the macOS menus still there when you hold the pointer at the top

**Lock-in mode**

- Gives a desktop over to two windows side by side, or three with two stacked beside a big one
- Tucks the other windows away until you unlock
- Works on each desktop separately
- Has an optional calm backdrop and a glowing edge around the windows

## Requirements

- macOS 26 or later
- An Apple silicon Mac
- Xcode or the Xcode Command Line Tools, with Swift 6

## Build and install

There's no prebuilt download, so you build it yourself:

```bash
git clone https://github.com/capi-git/ClearDock.git
cd ClearDock
./build.sh install
```

This copies `Clear Dock.app` to your Applications folder. Running `./build.sh` on its own builds the app into the `build` folder without installing it.

## Permissions

macOS asks for these when they're needed:

- **Accessibility:** for notification badges and for arranging windows in lock-in mode
- **Screen & System Audio Recording:** for window previews, desktop pictures and the calm backdrop
- **Automation:** to empty the Trash through Finder and to read what's playing in Spotify or Music

Clear Dock has no accounts or analytics. Its only network request downloads the album cover for the song playing in Spotify.

## Good to know

- **It changes your macOS Dock settings while it runs.** Clear Dock hides the macOS Dock by changing the Dock's settings and restarting it. Quitting Clear Dock puts the original settings back. If it ever crashes or is force quit, a small helper (a second "ClearDock" in Activity Monitor, about 2 MB) puts them back instead. You can turn this off with "Hide the macOS Dock" in Settings.
- **It uses private macOS interfaces.** Clear Dock relies on some of these for desktops and windows, so a macOS update could break parts of it.

## License

[MIT](LICENSE)
