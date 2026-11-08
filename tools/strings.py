#!/usr/bin/env python3
"""Baut Resources/Localizable.xcstrings aus den beim Bauen extrahierten Texten (deutsche Schlüssel) + englischer Übersetzung.
Aufruf nach einem Simulator-Build:  python3 tools/strings.py   (meldet fehlende Übersetzungen)"""
import glob, json, os, sys

EN = {
    "%lld": "%lld", "%lld Notizen": "%lld notes", "%lld Notizen bewegen": "Move %lld notes",
    "%lld Notizen gefunden": "%lld notes found", "%lld Notizen löschen?": "Delete %lld notes?",
    "(Konflikt)": "(Conflict)", "1 Notiz": "1 note", "1 Notiz gefunden": "1 note found",
    "Abbrechen": "Cancel", "Abgleich": "Sync", "Abmelden": "Sign Out", "Abmelden?": "Sign out?",
    "Account": "Account", "Alle Häkchen entfernen": "Uncheck All", "Alle Notizen": "All Notes",
    "Alle Notizen endgültig löschen?": "Permanently delete all notes?",
    "Alle Notizen und Unterordner werden gelöscht. Die Notizen bleiben 30 Tage in „Zuletzt gelöscht“.":
        "All notes and subfolders will be deleted. The notes stay in Recently Deleted for 30 days.",
    "Alle abhaken": "Check All", "Alle bewegen": "Move All", "Alle löschen": "Delete All",
    "Als Markdown exportieren": "Export as Markdown", "Als erledigt markieren": "Mark as Checked",
    "Angepinnt": "Pinned", "Anhang": "Attachment", "Anhang löschen": "Delete Attachment", "Anhänge": "Attachments",
    "Anmeldung abgelaufen": "Sign-in expired", "Anpinnen": "Pin", "Anzeigen": "View",
    "Auf diesem Server ist die App „Notes“ nicht installiert.": "The Notes app is not installed on this server.",
    "Aufzählung": "Bulleted List", "Ausrücken": "Decrease Indent", "A–Z": "A–Z",
    "Bearbeitungsdatum": "Date Edited", "Benutzer": "User", "Bewegen": "Move", "Checkliste": "Checklist",
    "Das kann nicht widerrufen werden.": "This can't be undone.", "Datei anhängen": "Attach File",
    "Dein Server unterstützt keine Anhänge (Nextcloud Notes 4.12.3 oder neuer nötig).":
        "Your server doesn't support attachments (Nextcloud Notes 4.12.3 or newer required).",
    "Deine Notizen in deiner eigenen Nextcloud": "Your notes in your own Nextcloud",
    "Dicktengleich": "Monostyled",
    "Die App bekommt ein eigenes App-Passwort – dein Nextcloud-Passwort sieht sie nie. Nötig ist die Nextcloud-App „Notes“.":
        "The app gets its own app password – it never sees your Nextcloud password. Requires the Nextcloud Notes app.",
    "Die Notiz liegt danach 30 Tage in „Zuletzt gelöscht“.": "The note will stay in Recently Deleted for 30 days.",
    "Die Notiz wurde inzwischen woanders geändert.": "The note was changed somewhere else in the meantime.",
    "Die Notizen bleiben in deiner Nextcloud. Auf diesem iPhone wird der Zwischenspeicher gelöscht.":
        "Your notes stay in your Nextcloud. The cache on this iPhone will be deleted.",
    "Durchgestrichen": "Strikethrough", "Einrücken": "Increase Indent", "Einstellungen": "Settings",
    "Endgültig löschen": "Delete Permanently", "Erstellt: %@": "Created: %@", "Erstellungsdatum": "Date Created",
    "Fehler": "Error", "Fertig": "Done", "Fett": "Bold", "Format": "Format",
    "Foto oder Video aufnehmen": "Take Photo or Video", "Foto oder Video auswählen": "Choose Photo or Video",
    "Gelöschte Notizen bleiben 30 Tage in „Zuletzt gelöscht“.": "Deleted notes stay in Recently Deleted for 30 days.",
    "Gestern": "Yesterday", "Gib einen Namen für diesen Ordner ein.": "Enter a name for this folder.",
    "Heute": "Today", "HomeNotes": "HomeNotes", "Im Browser anmelden": "Sign In with Browser",
    "In Notiz suchen": "Find in Note", "In Text konvertieren": "Convert to Text", "Jetzt abgleichen": "Sync Now",
    "Kein weiterer Text": "No additional text", "Keine Nextcloud unter dieser Adresse": "No Nextcloud at this address",
    "Keine Notizen": "No Notes", "Keine Verbindung zum Server": "No connection to the server",
    "Kopie senden": "Send a Copy", "Kursiv": "Italic", "Link bearbeiten": "Edit Link", "Link entfernen": "Remove Link",
    "Link hinzufügen": "Add Link", "Link hinzufügen …": "Add Link…", "Link zu:": "Link to:", "Loslösen": "Unpin",
    "Löschen": "Delete", "Markierte löschen": "Delete Checked", "Markierte nach unten bewegen": "Move Checked to Bottom",
    "Mehr": "More", "Mit nächster Zeile tauschen": "Swap with Next Row", "Nach Datum gruppieren": "Group by Date",
    "Name": "Name", "Neue Notiz": "New Note", "Neue Notizen beginnen mit": "New Notes Start With",
    "Neuer Ordner": "New Folder", "Neuer Unterordner": "New Subfolder", "Neueste zuerst": "Newest First",
    "Nextcloud Notes": "Nextcloud Notes", "Nicht angemeldet": "Not signed in", "Noch %lld Tage": "%lld days left",
    "Noch 1 Tag": "1 day left", "Noch nicht gesichert": "Not saved yet", "Notiz anpinnen": "Pin Note",
    "Notiz bewegen": "Move Note", "Notiz loslösen": "Unpin Note", "Notiz löschen?": "Delete note?",
    "Notizen": "Notes", "Notizen auswählen": "Select Notes",
    "Notizen sind bis zu 30 Tage lang verfügbar. Danach werden sie endgültig gelöscht.":
        "Notes are available here for up to 30 days. After that time, notes will be permanently deleted.",
    "Notizen sortieren nach": "Sort Notes By",
    "Notizen werden als Markdown-Dateien in deiner Nextcloud gespeichert (App „Notes“) und auf diesem iPhone zwischengespeichert, damit sie auch ohne Verbindung da sind.":
        "Notes are stored as Markdown files in your Nextcloud (Notes app) and cached on this iPhone so they are available offline.",
    "Notizenanzahl einblenden": "Show Note Count", "Nummeriert": "Numbered List", "OK": "OK", "Offline": "Offline",
    "Ordner": "Folders", "Ordner lassen sich nur mit Verbindung zum Server ändern.": "Folders can only be changed while connected to the server.",
    "Ordner löschen": "Delete Folder", "Ordner löschen?": "Delete folder?", "Ordner umbenennen": "Rename Folder",
    "Reihenfolge": "Order", "Schließen": "Close", "Schreibtools": "Writing Tools", "Server": "Server",
    "Server-Adresse, z. B. cloud.example.com": "Server address, e.g. cloud.example.com",
    "Server-Fehler %lld: %@": "Server error %lld: %@", "Sichern": "Save", "Sortieren nach": "Sort By",
    "Spalte %lld": "Column %lld", "Spalte hinzufügen": "Add Column", "Spalte links hinzufügen": "Add Column Before",
    "Spalte löschen": "Delete Column", "Spalte rechts hinzufügen": "Add Column After", "Spiegelstrich": "Dashed List",
    "Suchen": "Search", "Tabelle": "Table", "Tabelle löschen": "Delete Table", "Tabelle löschen?": "Delete table?",
    "Tastatur ausblenden": "Hide Keyboard", "Teilen": "Share", "Text": "Body",
    "Tippe auf „Neue Notiz“, um eine zu beginnen.": "Tap New Note to start one.", "Titel": "Title",
    "Toptreffer": "Top Hits", "Umbenennen": "Rename", "Unterordner von „%@“": "Subfolder of “%@”",
    "Unterstrichen": "Underline", "Unterüberschrift": "Subheading", "Version": "Version",
    "Vorherige 30 Tage": "Previous 30 Days", "Vorherige 7 Tage": "Previous 7 Days",
    "Warte auf Anmeldung im Browser …": "Waiting for sign-in in the browser…", "Widerrufen": "Undo",
    "Wiederherstellen": "Recover", "Wiederholen": "Redo", "Zeile %lld": "Row %lld", "Zeile hinzufügen": "Add Row",
    "Zeile löschen": "Delete Row", "Zeile oberhalb hinzufügen": "Add Row Above", "Zeile unterhalb hinzufügen": "Add Row Below",
    "Zellinhalt löschen": "Delete Cell Contents", "Zitatblock": "Block Quote", "Zuletzt abgeglichen": "Last Synced",
    "Zuletzt gelöscht": "Recently Deleted", "Z–A": "Z–A", "nicht verfügbar": "not available", "verfügbar": "available",
    "Älteste zuerst": "Oldest First", "Überschrift": "Heading",
    "„%@“ wurde gleichzeitig woanders geändert – deine Fassung liegt als Kopie daneben.":
        "“%@” was changed somewhere else at the same time – your version was saved as a copy next to it.",
    "Anhang": "Attachment", "Gestern": "Yesterday",
}
SKIP = {"", "·", "–", "•"}

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
keys = set()
for f in glob.glob(os.path.join(root, "build/Build/Intermediates.noindex/HomeNotes.build/*/HomeNotes.build/Objects-normal/arm64/*.stringsdata")):
    for t, entries in json.load(open(f)).get("tables", {}).items():
        if t == "Localizable":
            keys |= {e["key"] for e in entries}
if not keys:
    sys.exit("Keine extrahierten Texte gefunden – erst bauen.")
missing = sorted(k for k in keys - SKIP if k not in EN)
strings = {}
for k in sorted(keys | SKIP):
    if k in SKIP:
        strings[k] = {"shouldTranslate": False}
        continue
    # Deutsch ausdrücklich mit eintragen – sonst baut Xcode kein de.lproj und deutsche iPhones bekommen Englisch
    strings[k] = {"localizations": {
        "de": {"stringUnit": {"state": "translated", "value": k}},
        "en": {"stringUnit": {"state": "translated", "value": EN.get(k, k)}}}}
out = {"sourceLanguage": "de", "strings": strings, "version": "1.0"}
with open(os.path.join(root, "Resources/Localizable.xcstrings"), "w") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(keys)} Texte, fehlend: {missing}" if missing else f"{len(keys)} Texte, alle übersetzt")
sys.exit(1 if missing else 0)
