# Driftwood

Driftwood is a macOS wallpaper app with six original illustrated scenes and matching animated weather. Snow builds up on window ledges, falls when they move, and can settle on exposed windows below. Driftwood runs offline.

## Install

Download **Driftwood-macOS.zip** from [GitHub Releases](https://github.com/Parth-Dande/driftwood/releases/latest), unzip it, and open **Driftwood.app**. Driftwood supports macOS 14 or later on Apple silicon and Intel. The release is ad hoc signed. If macOS blocks the download, use the local build instructions below.

## Use Driftwood

- Choose a scene in the gallery and select **Apply to All Displays**.
- Use **Weather density** for particle count and larger snowflakes at the high end and **Fall speed** for how slowly the weather moves. Both sliders are in the gallery and the cloud-and-moon menu bar popover. Your settings are saved. Turning **Motion** off keeps the scene visible.
- In **Snow Lantern Inn**, drag from the exposed bottom edge of the screen to roll a snowball. Release it above a placed ball to stack them. The top ball gets a face and scarf when three balls stack. Drop a ball above the visible Dock to set it there. The bottom snowbank grows where flakes land. Choose **Plough Snow** in the menu bar to clear accumulated snow and snowmen while flakes keep falling. Snowbanks also grow on visible window tops and the Dock where macOS exposes its position. Snow passes behind Stage Manager thumbnails.
- Use **Import Video…** to loop a local MP4 or MOV silently. The file stays in its original location.
- Close the gallery to leave the wallpaper running. Use the cloud-and-moon menu bar icon to reopen it or switch scenes.
- Choose **Clear** or quit Driftwood to reveal your regular desktop picture.

The weather is drawn in a transparent Metal overlay. Open windows mask the weather over their contents. Clicks pass through the weather, and the snow pickup area sits below regular windows. Snow builds into visible drifts that break into falling flakes when a window moves or resizes. When a window is closed or minimized, its snow drops from the old window position. Petals and leaves can also settle on windows. Leaves also scatter near a moving pointer. Rain splashes against windows and the screen bottom, with occasional lightning. Fireflies drift toward a resting pointer, and meteors throw off sparks when they hit. Window collisions use the visible macOS window bounds. Browser tabs that share a window share its top edge.

Driftwood halves particle density while running on battery or in Low Power Mode. Display-synchronized rendering targets 30 frames per second on wall power and up to 24 on battery or in Low Power Mode. The fine flakes are drawn as soft-edged GPU sprites. A sleeping display or one covered by a full-screen window pauses its weather and video playback. The app applies the same scene or video to every connected display for the current session. Its desktop layer is separate from the system wallpaper and lock screen.

## Build from source

With Xcode Command Line Tools or Xcode installed, run these commands from the repository root:

```sh
./build.sh
open build/Driftwood.app
```

The build uses the macOS SDK, produces a universal binary, and has no package dependencies.

Run the physics checks from the repository root:

```sh
mkdir -p build
xcrun swiftc Sources/WeatherPhysics.swift Sources/Snowballs.swift Tests/WeatherPhysicsTests.swift -o build/weather-tests
./build/weather-tests
```

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/` | SwiftUI gallery, desktop overlay, Metal rendering, and weather simulation |
| `Tests/` | Weather and snowball physics regression tests |
| `Artwork/` | Six bundled wallpapers and their references |
| `build.sh` | Builds the universal macOS app |
| `LICENSE` and `LICENSE-WallFlow` | MIT license and upstream attribution |

## Credits and license

KoiArt’s public wallpaper gallery and weather demo video inspired the themed wallpapers, all-displays action, and desktop weather interactions. Driftwood’s artwork, particles, interface, and name were made independently. The six bundled wallpapers were generated for Driftwood with ImageGen. See [Artwork/REFERENCES.md](Artwork/REFERENCES.md) for the visual references and prompts. The app includes no KoiArt artwork, videos, branding, or code.

Driftwood reuses the desktop window, display identification, and video looping code from [WallFlow](https://github.com/ritulsingh/WallFlow/tree/b0946f519e9b8143e223ba3a9dceeca454f206a8), copyright 2026 ritulsingh, under the MIT license. The desktop window code was adapted for this app. See [LICENSE-WallFlow](LICENSE-WallFlow) for the full upstream notice. The original Driftwood portions are also available under MIT terms in [LICENSE](LICENSE).
