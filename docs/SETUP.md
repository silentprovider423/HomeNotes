# Setup guide: from IPA to your notes

HomeNotes is only the app. Your notes live in your own **Nextcloud** with the **Notes** app, so you need that first. If you already run Nextcloud, skip to step 2.

## What you need

- An iPhone with **iOS 26 or newer**
- A computer that runs all the time (NAS, mini PC, home server, old laptop) with **Docker**
- A free Apple ID for sideloading

## 1. Set up Nextcloud with Docker

The official all-in-one image is the easiest way: <https://github.com/nextcloud/all-in-one>. If you prefer a small classic setup, this `docker-compose.yml` is enough for notes:

```yaml
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    environment:
      MARIADB_ROOT_PASSWORD: change-me-root
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: change-me
    volumes: [db:/var/lib/mysql]
  app:
    image: nextcloud:33
    restart: unless-stopped
    ports: ["8080:80"]
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: change-me
      NEXTCLOUD_TRUSTED_DOMAINS: "cloud.example.com 192.168.1.10"
    volumes: [nextcloud:/var/www/html]
    depends_on: [db]
volumes: { db: {}, nextcloud: {} }
```

```bash
docker compose up -d
```

Open `http://<server-ip>:8080` in a browser and create the admin account.

## 2. Install the Notes app

In Nextcloud: your avatar → **Apps** → search for **Notes** → *Download and enable*. Or on the command line:

```bash
docker compose exec -u www-data app php occ app:install notes
```

HomeNotes needs Notes API **1.2 or newer**; attachments need Notes **4.12.3+**, deleting attachments Notes **6.1+**. The app checks this when you sign in and hides what your server can't do.

Optional: create a normal user for yourself instead of using the admin account (Admin → Users).

## 3. Make the server reachable from the iPhone

| Where | Address to use in the app | Works away from home |
|---|---|---|
| Home Wi-Fi only | `http://192.168.x.y:8080` | no |
| VPN (Tailscale, WireGuard) | `http://100.x.y.z:8080` (Tailscale IP) or your WireGuard IP | yes, with VPN on |
| Public with HTTPS (reverse proxy, Cloudflare Tunnel) | `https://cloud.example.com` | yes |

Important:

- iOS blocks plain `http://` to public domain names. A public address **must** use HTTPS with a normal certificate (e.g. Let's Encrypt).
- Add every address you use to `NEXTCLOUD_TRUSTED_DOMAINS` (or `trusted_domains` in `config.php`), otherwise Nextcloud refuses the login page.
- Behind a reverse proxy set `overwriteprotocol` to `https` in `config.php`, otherwise the login flow hands out `http://` links.
- Type `http://` in front of IP addresses. Without it the app tries `https://`.

## 4. Install the IPA

1. Install [SideStore](https://sidestore.io) (no computer needed later) or [AltStore](https://altstore.io) (needs AltServer on your computer) and sign in with your Apple ID.
2. Download `HomeNotes-<version>.ipa` from the latest release on the iPhone.
3. Open it with SideStore/AltStore ("Share" → SideStore, or the **+** button in My Apps).
4. If iOS asks: Settings → Privacy & Security → **Developer Mode** on, iPhone restarts.

With a free Apple ID the app has to be **refreshed every 7 days**. SideStore and AltStore do that for you, just open them once a week.

## 5. First start

1. Open HomeNotes, enter the server address from step 3 and tap **Sign In with Browser**.
2. Log in on your Nextcloud page and confirm *Grant access*. The browser sheet closes by itself.
3. Allow **local network** access when asked (needed for servers at home).
4. Your notes load. They are cached on the iPhone, so they are there without a connection too; changes made offline are uploaded later.

To sign out (and revoke the app password): Folders → **…** → Settings → Sign Out. You can also revoke it in Nextcloud under Settings → Security → *Devices & sessions*.

## Good to know

- Notes are files in `Notes/` in your Nextcloud (folder = category). You can edit them in the Notes web app, in other Notes clients or in any text editor – HomeNotes merges changes made at the same time.
- Images and files you attach are stored next to the note in `.attachments.<note id>/`.
- "Recently Deleted" lives on the iPhone (the Notes API has no trash). Deleted notes are also in Nextcloud's own trash bin.
