# nook

Automatic tiling for macOS. Open a window and it gets a place; close one and the rest fill the space. Nook lives in the menu bar and follows one rule: **each new window takes half of the newest space.**

```
1 window            2 windows           3 windows           4 windows
┌───────────────┐   ┌───────┬───────┐   ┌───────┬───────┐   ┌───────┬───────┐
│               │   │       │       │   │       │   2   │   │   1   │   2   │
│       1       │   │   1   │   2   │   │   1   ├───────┤   ├───────┼───────┤
│               │   │       │       │   │       │   3   │   │   4   │   3   │
└───────────────┘   └───────┴───────┘   └───────┴───────┘   └───────┴───────┘
```

Requires macOS 15 or later on an Apple silicon or Intel Mac (`scripts/bundle.sh` builds one app for both), and Accessibility access (System Settings → Privacy & Security → Accessibility).

## Build and run

Only the Command Line Tools are needed; Xcode isn't.

```sh
scripts/bundle.sh --open        # build build/Nook.app and launch it
scripts/bundle.sh --install     # copy to /Applications as well
scripts/test.sh                 # layout and stack tests
```

macOS ties the Accessibility grant to the app's code signature. An ad-hoc signature changes on every build, so macOS asks again after each rebuild. To avoid that, sign with a stable identity:

```sh
NOOK_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/bundle.sh --install
```

If Nook stays at "Needs Accessibility access" after you've switched it on, an older build's entry is in the way. Remove every Nook row from the Accessibility list, or run `tccutil reset Accessibility dev.mithun.nook`, then open Nook again.

## Features

| | |
|---|---|
| **Layouts** | Grid (the fold), Columns, Rows, Side. Ultrawide (≥ 2:1) and vertical screens get their own versions. Main window size: Half, 60% or Two-thirds. |
| **Per screen, per Space** | Each screen keeps its own layout, window count (1–4, or 5 in Side on ultrawide or vertical), sizes and order. |
| **Stacks** | More windows than tiles stack in the tile you're working in. Native tabs (Terminal, Ghostty) share their window's tile. ⌃⌥⌘ + arrow stacks the active window onto its neighbour, up to 5 to a tile. |
| **Split or tabbed stacks** | ⌃⌥T switches a stack between tabs (one window shows) and split (every window shows, one above the other, like a terminal above its logs). In a split stack, ⌃⌥⇧ ↑↓ moves between rows, ⌃⌥ ↑↓ moves the window up or down, ⌃⌥⇧ = / - changes its height, ⌃⌥E evens the heights, and dragging the line between two rows resizes both. ⌃⌥O takes a window back out. |
| **Widths** | ⌃⌥W steps the active window through 25, 33, 50, 66 and 75% of the screen. Sizes stay when windows open and close. |
| **Pins** | ⌃⌥⇧P keeps a window in its place: new and closed windows go around it, and swaps leave it alone. Press again to unpin. |
| **Swipe** | Hold ⌃⌥ and swipe with two fingers to move to the window that way. Without the keys, apps scroll as usual. |
| **Rearranging** | ⌘-drag to swap, ⌥⌘-drag to stack, drag onto another screen to move. ⌃⌥ + arrow swaps, and crosses screens at the edge. |
| **Resizing** | Drag the edge between two windows and the neighbours follow live. Sizes belong to positions and survive swaps, opens and closes. |
| **Apps that won't shrink** | Nook learns an app's minimum size (asking twice before trusting it), moves split lines to fit it, and floats the window, with a "Needs more room" card, when it can't fit. |
| **Focus mode** | One window fills the screen; the others stay put underneath. |
| **No peek** | Dims and blurs everything except the window you're in. |
| **Clean Space** | The active window on a plain background, for sharing or presenting. |
| **Window search** | ⌃⌥S, type a few letters of an app or window title, press Return. Finds minimized windows and hidden apps too. Titles are read only while it's open. |
| **Tab View and overview** | ⌥⇥ shows every window, screen by screen, where it sits. Arrows move between them spatially. ⌃⌥⇧O opens the same view without holding a key, until you pick a window or press Esc. |
| **Quick actions** | Rest on the grip above the active window for Primary, Focus, Next screen and Float. Stacks show chips you can click, scroll, close or drag to another tile. |
| **Highlight** | A border on the active window or on all windows, or a glow. Drawn in the gaps, never over window content. |
| **Floating** | Float one window (⌃⌥F), exclude whole apps, or tell Nook to always float a dialog by its title's first two words (⌃⌥⇧F). |
| **Hover focus** | Optional focus-follows-mouse that doesn't steal focus while you type or drag. |
| **Stage Manager** | Nook pauses while Stage Manager is on. |
| **Setup check** | Settings → General lists other window managers that are running (Rectangle, Magnet, Amethyst, AeroSpace, yabai and more) and macOS edge tiling, with a button to the right System Settings page. |
| **Clean quit** | When Nook quits, each tiled window goes back to where it was before Nook moved it. Windows you floated stay where you put them. |
| **Where new windows open** | At the end (the fold), next to the active window, or as the main window. Each app can have its own choice and its own width (Settings → Apps). |
| **Session restore** | Window order and stacks on each screen come back after a restart or log-out. Windows are matched by app and a fingerprint of their title; titles themselves are never stored. |
| **Workspaces** | Save the windows on every screen under a name, and load them again later (Settings → Workspaces). Loading opens apps that aren't running. Each workspace can have its own shortcut, and can be exported to JSON. |
| **Back after sleep** | After sleep, a screen lock or a display reconnecting, windows go back to their places, and back to the display they came from. |
| **Window bar** | An optional row of app icons for each screen, at the top or bottom, always or while you hold the shortcut keys. Click to go to a window; drag onto another to swap them. |
| **Menu bar position** | Optional “2 of 3” beside the menu bar icon. |
| **Keep window heights** | Optional: a window shorter than its tile keeps its own height. |
| **Your own shortcuts** | Change any shortcut in Settings → Keyboard, give any action a second one, or add keys to actions with none (layouts, pause, workspaces). |
| **Restart if stuck** | Optional: Nook opens again if it stops answering or ends by accident. |
| **Updates** | Optional daily check of GitHub for a newer version, or Check Now in Settings → General. |
| **Guided tour** | The tour ends with a list of shortcuts that tick off as you try them. |
| **Activity** | Windows placed this week, keyboard vs mouse, and time saved. Counts only: never titles or app names. |

Added beyond the original brief:

- **Cycle layouts** with ⌃⌥L, and **move to the next screen** with ⌃⌥N.
- **Separate outer margin** from the gap between windows.
- **Move pointer with keyboard focus**, so the cursor follows the window you activate from the keyboard.
- **Scripting**: every action is a `nook://` URL, and a bundled `nook` CLI wraps them, including `nook workspace save|load <name>`, `nook workspace export <name> <file>` / `import <file>`, `nook focus-app Safari` (also `nook://focus?app=Safari`), and `nook notify success|failure`, which flags the terminal window a long job ran in: `npm test && nook notify success || nook notify failure`.
- **Config as JSON**: export and import your settings (Settings → Advanced) to keep them in dotfiles.
- **Shortcut conflict detection**: keys already taken by another app are dimmed, and keys macOS reserves are marked "left to macOS".

## Keyboard

The ⌃⌥ prefix can be switched to ⌥⌘ or ⌃⇧ in Settings → Keyboard.

| Keys | Action |
|---|---|
| ⌃⌥ ← → ↑ ↓ | Swap with the neighbour; past the edge, move to the next screen |
| ⌃⌥⇧ ← → ↑ ↓ | Activate the neighbour; past the edge, the nearest window on the next screen |
| ⌃⌥ 1 … 5 | Activate window 1 to 5 on this screen (1 is primary) |
| ⌃⌥ S | Search windows |
| ⌃⌥⇧ O | Overview of every window |
| ⌃⌥⌘ ← → ↑ ↓ | Stack onto the neighbour |
| ⌃⌥ T / ⌃⌥ O | Split or tabbed stack / take out of the stack |
| ⌃⌥⇧ = / - , ⌃⌥ E | Taller / shorter in a split stack, even heights |
| ⌃⌥ W | Cycle width |
| ⌃⌥⇧ P | Pin or unpin |
| ⌃⌥ ↩ | Make the active window primary |
| ⌃⌥ ] / [ | Activate the next / previous window |
| ⌃⌥ \` / ⌃⌥⇧ \` | Next / previous window in this tile's stack |
| ⌥ ⇥ / ⌥⇧ ⇥ | Tab View |
| ⌃⌥ = / - / 0 | Grow / shrink / reset sizes on this screen |
| ⌃⌥ F / ⌃⌥⇧ F | Float or tile / always float windows like this one |
| ⌃⌥ Z | Focus mode |
| ⌃⌥ D | No peek mode |
| ⌃⌥ P | Clean Space |
| ⌃⌥ R | Retile |
| ⌃⌥ L | Cycle this screen's layout |
| ⌃⌥ N | Move to the next screen |
| ⌃⌥⌘ 1–5 | Windows on this screen |

## Scripting

```sh
open -g nook://layout/side
open -g nook://count/2
open -g nook://swap/left
```

Or link the CLI (Settings → Advanced copies this command):

```sh
sudo ln -sf /Applications/Nook.app/Contents/Resources/nook /usr/local/bin/nook
nook layout columns
nook retile
```

Verbs: `retile toggle primary next previous stack-next stack-previous grow shrink reset float focus nopeek cleanspace next-screen cycle-layout tabview settings`, plus `swap/<left|right|up|down>`, `layout/<grid|columns|rows|side>` and `count/<1-5>`.

## Architecture

```
Sources/
  NookKit/                 pure model, no AppKit, unit tested
    Layout.swift           layouts as split trees, per screen shape
    Solver.swift           lays a tree into a rect: gaps, weights, minimum sizes, edge moves
    ScreenModel.swift      ordered tiles, stacks, overflow, swaps
  Nook/
    System/                Accessibility helpers, displays and Spaces, the per-app AX observer
    Engine/                state, event handling, layout application, commands
    Input/                 Carbon hotkeys, global mouse handling (drag, resize, hover)
    Model/                 preferences and persistence
    UI/                    menu bar panel, overlays (borders, shades, grips, Tab View, cards), settings, tour
Tests/NookKitTests/        layout, solver, resize and stack behaviour
```

The engine keeps one `ScreenModel` per screen per Space, keyed by display UUID and Space ID. Every change (a window opens, a drag ends, a setting changes) marks screens dirty. Each dirty screen is planned once (`Solver` turns its split tree into frames), and only windows whose frames differ get moved.

Private APIs: `_AXUIElementGetWindow` (AX element → window ID), `CGSManagedDisplayGetCurrentSpace` (current Space), and `_SLPSSetFrontProcessWithOptions` (reliable activation, looked up at runtime). yabai, AeroSpace, AltTab and Rectangle rely on the same calls. This is also why Nook can't be sandboxed or sold on the Mac App Store.

`Nook --snapshot <dir>` renders the panel, every settings page and every tour step to PNGs in light and dark, for design review without screen-recording access.

## Privacy

Nook reads window positions, sizes and owning apps, and moves and resizes windows. It reads titles only to match Always-float rules and to label Tab View, and never stores them. It takes no screenshots, makes no network requests, and keeps everything in its preferences on this Mac.
