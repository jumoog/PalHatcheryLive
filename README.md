# PalHatcheryLive

UE4SS Lua mod for Palworld: keeps the hatchery panel (Ancient Hatchery /
Incubator) **live** while it is open.

## Problem

Vanilla builds the panel once, when it opens. If an egg's timer runs out while
you are standing in that panel, the rows and the "Collect all hatched Pals"
button keep showing the state from the moment you opened it — you have to leave
and come back before you can collect.

## What the mod does

For **every** incubator panel currently on screen (the world HUD above the
machine as well as the big interaction panel):

1. It re-runs the panel's **own** display-update functions whenever something
   changes — panel opened, hatch hook fired, or the number of hatched slots
   moved (a cheap native getter, polled every 500 ms, which never touches the
   UI). Explicitly **not** on a timer: re-poking a panel whose state has not
   changed replays its "complete" presentation and makes the collect button
   flicker. Found live on Palworld 1.0:
   `WBP_IngameMenu_Incubator_Multiple_C` → `OnEggArrayUpdated()`,
   `WBP_Ingame_Incubator_Multiple_C` → `OnEggArrayUpdated()`, `UpdateSimpleSlot()`,
   `WBP_Ingame_Incubator_C` → `UpdateEggDisplay()`.
2. It triggers that same update **immediately** when the game tells the client a
   hatch finished — hooks on `Notify*Hatch*` / `OnRep*Egg*`, resolved at runtime
   from the model's class chain. On this build those are
   `NotifyHatchComplete_ClientInternal`, `NotifyHatchFailed_NoEmptySlot_ClientInternal`
   and `OnRepEggInfoArray`. The `NotifyMultiHatchComplete_ToClient` named in the
   executable does **not** exist on these classes, which is why nothing is
   hardcoded.
3. Optionally it un-greys the collect button once the model's
   `GetHatchedStateArray()` reports hatched pals, addressed through the panel
   property `WBP_CommonButton_OpenAll` rather than its label, so it is
   language-independent. `WBP_CommonButton_SetAll` is deliberately left alone.

   **Off by default**, because on this build there is nothing to un-grey:
   `WBP_CommonButton_C` derives straight from `UserWidget`, not from
   `CommonButtonBase`. It has no enabled state at all — `GetIsInteractionEnabled`
   does not exist on it and `GetIsEnabled` is always `true`, even with an empty
   machine. Its look comes purely from animations (`Anm_DefaultToRed`,
   `AnmEvent_Red/Normal/Focus`). The real fix is the refresh in point 1.

## Status

Confirmed in game: when the timer runs out while the panel is open, the display
switches over and the collect button works without leaving the panel.

Collecting stays vanilla — you click the button. `AUTO_COLLECT = true` in the
CONFIG makes the mod send `RequestObtainAllHatchedCharacter` itself instead, on
the transition only.

## Installation

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Copies `Mods/PalHatcheryLive` to
`<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\PalHatcheryLive`. The `enabled.txt` in
the mod folder is enough for UE4SS 3.0.1 — no entry in `mods.json` / `mods.txt`
required. Hot reload is usually off (`EnableHotReloadSystem = 0`), so restart
the game after installing.

## How the names are found

A panel's Blueprint update function lives in the game assets (Oodle-compressed),
not in the executable. So the mod does not guess: it **asks the class at
runtime** (`ForEachFunction`) and calls only names that look like a display
update and cannot be an action (allow/deny filters in `CONFIG`). If a candidate
turns out to take parameters, UE4SS raises a catchable Lua error and the
candidate is dropped for good rather than called with garbage.

The same approach resolves the model: its property name is a property of the
*class* and therefore stable (`Hatching Egg Model` on the menu panel, `Model` on
the world HUDs), while panel instances are recreated on every open. The name is
learned once by reflection and falls back to a full scan if a game patch changes
it.

The first time each panel class appears, a reflection dump goes into
`ue4ss\UE4SS.log`:

* the panel's class chain with all functions and properties,
* the full widget tree including button labels, `enabled` and `vis`,
* the model's class chain plus the hatched-slot count.

**F8** repeats the dump at any time (the panel has to be open). That log is what
pins the exact vanilla update function if the heuristic misses on your build.

## CONFIG (top of `Scripts/main.lua`)

| Option | Default | Meaning |
| --- | --- | --- |
| `POLL_MS` | `500` | Tick interval. The hatched-slot detector runs on it; it never touches the UI |
| `HEARTBEAT_MS` | `15000` | Only for panels **without** a change detector (the single-egg model has no `GetHatchedStateArray`). `0` = off. Regular panels are purely event-driven |
| `ENABLE_BUTTONS` | `false` | Un-grey a disabled collect button (see point 3 — nothing to do on this build) |
| `COLLECT_BUTTON_PROPS` | `{"WBP_CommonButton_OpenAll"}` | Panel properties holding the collect button |
| `COLLECT_LABELS` | `{"collect","einsammeln","abholen","erhalten"}` | Label filter (lower case) for the fallback used only when no named button exists; every disabled button's label is logged once |
| `AUTO_COLLECT` | `false` | Send the collect request automatically on the transition |
| `PRUNE_CLASSES` | `{"Inventory","ItemSlot"}` | Widget subtrees never walked — the panel embeds the whole player inventory |
| `DUMP_ON_FIRST_OPEN` | `true` | Reflection dump into the log, once per panel class |
| `DUMP_KEY` | `"F8"` | Key for the manual dump |

## Safety

The mod runs on the game thread and touches live widgets, so an unhandled Lua
error would be a crash. Therefore:

* every object access is wrapped in `pcall`, and every object passes `IsValid()`
  before a member call — UE4SS returns a wrapper for null/stale UObjects, **not**
  `nil`, and the resulting access violation is native and not catchable,
* properties are **never** read blind by name — only reflected `ObjectProperty`
  values (reading a `SoftObjectProperty`, for example, can crash inside UE4SS),
* functions are called only when class reflection reported them **and** the name
  passes the deny filter (no `Request*`, `*Server*`, `On*Click*`, `Destroy*`,
  `Set*`, …).

## Multiplayer

Client-side only, and safe on servers: everything it reads is replicated state
the vanilla panel already displays (`GetHatchedStateArray` is a pure getter with
no net flag), and everything it calls is local display code. It changes no game
state. Installing it on a dedicated server is pointless — no widgets exist
there, so it would idle. Untested on a dedicated server; one caveat is that
`NotifyHatchComplete_ClientInternal` is a native, non-reflected call, so whether
the hook fires on a remote client is unverified — the hatched-slot detector
covers that case regardless.
