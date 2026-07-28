# PalHatcheryLive

UE4SS-Lua-Mod für Palworld: hält das Brutmaschinen-Fenster (Ancient Hatchery /
Incubator) **live**, solange es offen ist.

## Problem

Vanilla baut das Panel einmal beim Öffnen auf. Läuft der Timer eines Eis
herunter, während du im Fenster stehst, zeigen die Zeilen und der Button
"Collect all hatched Pals" weiter den Stand vom Öffnen — du musst raus und
wieder rein, um einsammeln zu können.

## Was der Mod macht

Für **jedes** gerade sichtbare Incubator-Panel (World-HUD über der Maschine wie
auch das große Interaktionsfenster):

1. ruft er die **panel-eigenen** Display-Update-Funktionen periodisch erneut auf
   (Standard: alle 2 s), damit Zeilen und Button dem echten Zustand folgen.
   Live gefunden auf Palworld 1.0:
   `WBP_IngameMenu_Incubator_Multiple_C` → `OnEggArrayUpdated()`,
   `WBP_Ingame_Incubator_Multiple_C` → `OnEggArrayUpdated()`, `UpdateSimpleSlot()`,
   `WBP_Ingame_Incubator_C` → `UpdateEggDisplay()`,
2. löst dasselbe Update **sofort** aus, wenn das Spiel dem Client meldet, dass
   ein Schlupf fertig ist (Hooks auf `Notify*Hatch*`/`OnRep_Hatched*`, aus der
   Klassenkette des Modells zur Laufzeit aufgelöst),
3. entgraut den Collect-Button, sobald `GetHatchedStateArray()` des Modells
   geschlüpfte Pals meldet — angesprochen über die Panel-Property
   `WBP_CommonButton_OpenAll` (nicht über das Label, also sprachunabhängig);
   `WBP_CommonButton_SetAll` bleibt bewusst unangetastet.

   Gemessen: dieser Button meldet `enabled=true` **auch bei leerer Maschine**
   (Label `Alle ausgebrüteten Pals abholen`). Sein Grau-Zustand hängt also nicht
   am `IsEnabled`-Flag von `UWidget` — Punkt 3 ist damit nur Absicherung, der
   eigentliche Fix ist der Refresh aus Punkt 1.

Eingesammelt wird weiter vanilla: du klickst den Button. `AUTO_COLLECT = true`
in der CONFIG lässt den Mod stattdessen `RequestObtainAllHatchedCharacter`
selbst schicken.

## Installation

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Kopiert `Mods/PalHatcheryLive` nach
`<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\PalHatcheryLive`.
Die `enabled.txt` im Mod-Ordner reicht UE4SS 3.0.1 als Aktivierung — kein
Eintrag in `mods.json`/`mods.txt` nötig.

## Erster Start (wichtig)

Der Name der Blueprint-Update-Funktion des Panels steckt nur im Spiel-Asset,
nicht in der Exe — deshalb rät der Mod ihn nicht, sondern **fragt die Klasse zur
Laufzeit** (`ForEachFunction`) und ruft nur Namen auf, die nach Anzeige-Update
aussehen (Allow/Deny-Filter in `CONFIG`). Nimmt eine Kandidatenfunktion doch
Parameter, wirft UE4SS einen abfangbaren Lua-Fehler und der Kandidat fliegt raus.

Beim ersten Auftauchen **jeder** Panel-Klasse schreibt der Mod zusätzlich einen
Reflection-Dump in `ue4ss\UE4SS.log`:

* Klassenkette des Panels mit allen Funktionen und Properties,
* kompletter Widget-Baum inkl. Button-Beschriftungen, `enabled` und `vis`,
* Klassenkette des Modells + Anzahl geschlüpfter Slots.

Mit **F8** lässt sich der Dump jederzeit wiederholen (Panel muss offen sein).
Aus diesem Log lässt sich die exakte Vanilla-Update-Funktion festnageln, falls
die Heuristik auf deinem Build daneben liegt.

## CONFIG (Kopf von `Scripts/main.lua`)

| Option | Default | Bedeutung |
| --- | --- | --- |
| `REFRESH_INTERVAL_MS` | `2000` | Intervall des periodischen Panel-Refresh |
| `ENABLE_BUTTONS` | `true` | Deaktivierten Collect-Button entgrauen |
| `COLLECT_LABELS` | `{"collect","einsammeln",…}` | Button-Label-Filter (Kleinschreibung); leere Liste = jeder deaktivierte Button. Das Label jedes deaktivierten Buttons landet einmalig im Log |
| `AUTO_COLLECT` | `false` | Einsammeln automatisch auslösen |
| `DUMP_ON_FIRST_OPEN` | `true` | Einmaliger Reflection-Dump ins Log |
| `DUMP_KEY` | `"F8"` | Taste für den manuellen Dump |

## Sicherheit

Der Mod läuft auf dem Game-Thread und fasst lebende Widgets an, ein
unbehandelter Lua-Fehler wäre ein Absturz. Deshalb:

* jeder Objektzugriff in `pcall`, jedes Objekt vor einem Member-Call durch
  `IsValid()` (UE4SS liefert für null/stale UObjects einen Wrapper, **nicht**
  `nil`; die daraus folgende Access Violation ist nativ und nicht abfangbar),
* Properties werden **nie** blind per Name gelesen — nur reflektierte
  `ObjectProperty`-Werte (das Lesen z. B. einer `SoftObjectProperty` kann
  innerhalb von UE4SS crashen),
* Funktionen werden nur aufgerufen, wenn die Klassen-Reflection sie gemeldet hat
  **und** der Name den Deny-Filter passiert (kein `Request*`, `*Server*`,
  `On*Click*`, `Destroy*`, `Set*` …).
