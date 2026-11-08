#!/usr/bin/env python3
"""Legt Demo-Notizen für Screenshots in einem TESTKONTO an (nie im echten Konto benutzen).
   set -a; . ./.test-account; set +a; python3 tools/demo-notes.py <bild.jpg>
Vorhandene Demo-Notizen (gleicher Titel und Ordner) werden vorher gelöscht."""
import base64, json, os, sys, time, urllib.request, uuid

S, U, P = os.environ["NOTES_SERVER"].rstrip("/"), os.environ["NOTES_USER"], os.environ["NOTES_PASSWORD"]
AUTH = "Basic " + base64.b64encode(f"{U}:{P}".encode()).decode()
API = S + "/index.php/apps/notes/api/v1/"

def call(method, path, body=None, raw=None, ctype=None):
    req = urllib.request.Request(API + path, method=method, data=raw if raw is not None else (json.dumps(body).encode() if body is not None else None))
    req.add_header("Authorization", AUTH); req.add_header("Accept", "application/json")
    if body is not None: req.add_header("Content-Type", "application/json")
    if ctype: req.add_header("Content-Type", ctype)
    with urllib.request.urlopen(req) as r:
        d = r.read()
        return json.loads(d) if d else None

DAY = 86400
now = int(time.time())
NOTES = [
    ("", "Groceries", True, now - 600, """# Groceries

- [x] Milk
- [ ] Sourdough bread
- [ ] Apples
- [x] Coffee beans
- [ ] Tomatoes
- [ ] Olive oil
- [ ] Basil"""),
    ("Travel", "Weekend in Lisbon", False, now - 3 * 3600, """# Weekend in Lisbon

Three days, no car, lots of **pastéis de nata**.

{IMG}

## Plan

| Day | Morning | Evening |
| --- | --- | --- |
| Fri | Alfama walk | Fado in Mouraria |
| Sat | Belém | LX Factory |
| Sun | Sintra | Sunset at Miradouro |

## Packing
- Comfortable shoes
- Rain jacket
- Power adapter

Tram 28 timetable: https://www.carris.pt"""),
    ("Recipes", "Lemon Pasta", False, now - 1 * DAY - 3600, """# Lemon Pasta

*Ready in 20 minutes, serves 2*

## Ingredients
* 250 g spaghetti
* 2 lemons (zest and juice)
* 60 g butter
* 50 g parmesan
* Black pepper

## Steps
1. Cook the pasta in salted water.
2. Melt the butter, add zest and juice.
3. Toss with pasta, parmesan and a splash of pasta water.

> Add the cheese off the heat, otherwise it clumps."""),
    ("Work/Projects", "Project Ideas", False, now - 4 * DAY, """# Project Ideas

## Home server
- **Backups**: second disk, weekly check
- *Photo* library on Immich
- Notes on Nextcloud ✓

## App
- ~~Dark mode~~ done
- Widgets for pinned notes
- Share extension

```
docker compose pull && docker compose up -d
```"""),
    ("Work", "Team Meeting", False, now - 12 * DAY, """# Team Meeting

Attendees: Alex, Sam, Robin

## Decisions
- Release on **Friday**
- Beta testers get the build on Wednesday

## To do
- [x] Update changelog
- [ ] Write release notes
- [ ] Book demo room"""),
    ("", "Books to Read", False, now - 40 * DAY, """# Books to Read

- ~~The Pragmatic Programmer~~
- Designing Data-Intensive Applications
- A Philosophy of Software Design
- The Design of Everyday Things"""),
    ("", "Gift Ideas", True, now - 2 * DAY, """# Gift Ideas

- [ ] Mom: herb garden kit
- [ ] Dad: vinyl record
- [x] Sam: board game"""),
]

existing = call("GET", "notes?exclude=content")
for cat, title, fav, mod, content in NOTES:
    for n in existing:
        if n.get("category") == cat and n.get("title") == title:
            call("DELETE", f"notes/{n['id']}")
for cat, title, fav, mod, content in NOTES:
    n = call("POST", "notes", {"title": title, "content": content.replace("{IMG}", ""), "category": cat, "favorite": fav, "modified": mod})
    if "{IMG}" in content and len(sys.argv) > 1:
        boundary = uuid.uuid4().hex
        data = open(sys.argv[1], "rb").read()
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"Lisbon.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n").encode() + data + f"\r\n--{boundary}--\r\n".encode()
        path = call("POST", f"attachment/{n['id']}", raw=body, ctype=f"multipart/form-data; boundary={boundary}")["filename"]
        n = call("PUT", f"notes/{n['id']}", {"content": content.replace("{IMG}", f"![Lisbon]({path.replace(' ', '%20')})"), "modified": mod})
    print("angelegt:", cat or "–", "/", title)
