# Self-Hosted WatchParty with OpenTogetherTube & Tailscale

A complete, self-hosted watch party solution that streams local video files synchronously to remote friends over HTTPS without requiring port forwarding, static public IPs, or router access.

---

## Stack Architecture

* **[OpenTogetherTube](https://github.com/dyc3/opentogethertube)**: Open-source Node.js web application for synchronized video playback and real-time room chat.
* **[Nginx Video Server](https://nginx.org/)**: Light, event-driven web server configured with CORS headers to stream video files directly from `~/Videos`.
* **[Tailscale Funnel](https://tailscale.com/kb/1223/funnel)**: Zero-config mesh network powered by [WireGuard®](https://www.wireguard.com/) providing secure, persistent public HTTPS ingress tunnels that bypass CGNAT and home firewalls.

---

## Prerequisites

* A Linux host operating system ([Fedora](https://fedoraproject.org/) or [Debian](https://www.debian.org/)/[Ubuntu](https://ubuntu.com/) derivative).
* A free [Tailscale Account](https://tailscale.com/).
* A regular Linux user account with `sudo` administrative privileges.
* [FFmpeg](https://ffmpeg.org/) installed for media transcoding (`sudo dnf install ffmpeg` or `sudo apt install ffmpeg`).

---

## Quick Start (Automated Setup)

1. Save your `setup_watchparty.sh` script inside your project directory (e.g., `~/dev/watchparty/setup_watchparty.sh`).
2. Make the setup script executable:
   ```bash
   chmod +x setup_watchparty.sh
   ```
3. Run the setup script:
   ```bash
   ./setup_watchparty.sh
   ```
   *The script automatically prompts for your OS profile (Debian/Ubuntu vs. Fedora), installs dependencies, enables systemd services on boot, clones the OpenTogetherTube repository, generates secure secrets, configures `production.toml` and `nginx.conf`, provisions background Tailscale Funnels, launches the Docker stack, and runs database migrations.*

---

## Daily Operation & Stack Management

Containers are configured with `restart: "no"` so they only run when you explicitly turn them on.

### Daily Management Commands

| Action | Command |
| :--- | :--- |
| **Start WatchParty Stack** | `docker compose start` |
| **Stop WatchParty Stack** | `docker compose stop` |
| **Check Container Status** | `docker compose ps` |
| **Check Active Funnels** | `tailscale funnel status` |
| **View App Logs** | `docker compose logs -f opentogethertube` |
| **View Video Server Logs** | `docker compose logs -f videoserver` |

---

## Universal Video Encoding Rules

Web browsers require specific video codecs for cross-platform playback across Windows, macOS, iOS, Android, and Linux. Non-standard profiles (such as 10-bit color, H.265/HEVC, or 5.1 surround sound) cause browser decode errors (like `NS_ERROR_DOM_MEDIA_DECODE_ERR`) or black screens.

### Mandatory Encoding Profile

* **Container:** MP4 (`.mp4`)
* **Video Codec:** H.264 / AVC (`libx264`)
* **Color Space / Pixel Format:** 8-bit `yuv420p`
* **Audio Codec:** 2-Channel Stereo AAC (`-c:a aac -ac 2`)
* **HTTP Fast-Start:** `-movflags +faststart`

### Universal FFmpeg Conversion Command

Run this command on any video or `.mkv` file before streaming:

```bash
ffmpeg -i ~/Videos/input.mkv \
  -c:v libx264 -pix_fmt yuv420p -preset fast -crf 22 \
  -c:a aac -ac 2 -b:a 192k \
  -movflags +faststart \
  ~/Videos/output.mp4
```

### Burning Subtitles Into Video

To hardcode soft or external subtitles (`.srt` / `.ass`) into the video stream while preserving web compatibility:

```bash
ffmpeg -i ~/Videos/input.mkv \
  -vf "subtitles=/path/to/subtitles.srt" \
  -c:v libx264 -pix_fmt yuv420p -preset fast -crf 22 \
  -c:a aac -ac 2 -b:a 192k \
  -movflags +faststart \
  ~/Videos/output_subtitled.mp4
```

### Verifying File Compatibility

Check that an encoded file matches web standards:

```bash
ffprobe -v error -show_entries stream=codec_name,pix_fmt,channels -of default=noprintwrappers=1 ~/Videos/output.mp4
```
*Expected output: `h264`, `yuv420p`, `aac`, `2`.*

---

## Adding Videos to Your Room

1. Place your converted MP4 files in `~/Videos/`.
2. Open your OpenTogetherTube interface at `https://<your-magicdns>.ts.net/`.
3. Create or join a room.
4. Add the video stream URL to the room queue using your video server's HTTPS endpoint:
   ```text
   https://<your-magicdns>.ts.net:8443/output.mp4
   ```

---

## Troubleshooting

### CORS Errors in Browser Console
If the browser blocks video fetching due to Cross-Origin Resource Sharing rules:
* Ensure `nginx.conf` contains `add_header 'Access-Control-Allow-Origin' '*' always;` on all endpoints and preflight `OPTIONS` blocks.
* Restart the video server: `docker compose restart videoserver`.

### Audio Plays but Video is Black / Decoder Error
* The file is encoded in H.265/HEVC, AV1, or 10-bit color depth (`yuv420p10le`).
* Re-encode the file using the **Universal FFmpeg Conversion Command** above.

### Friends Cannot Connect
1. Verify Tailscale Funnels are active in the background:
   ```bash
   tailscale funnel status
   ```
2. If firewall blocks ports locally on Fedora:
   ```bash
   sudo firewall-cmd --add-port={8080,8081}/tcp --permanent
   sudo firewall-cmd --reload
   ```

---

## Acknowledgments & Credits

This cannot even be considered a project, it is a configuration set of open-source software and networking tools:

* **[OpenTogetherTube](https://github.com/dyc3/opentogethertube)** — Created and maintained by [dyc3](https://github.com/dyc3). OpenTogetherTube provides synchronized video playback, user room management, and real-time chat capabilities.
* **[Tailscale](https://tailscale.com/)** — Developed by Tailscale Inc. Tailscale simplifies secure networking using WireGuard®, enabling peer-to-peer mesh connections and public ingress via Tailscale Funnel without manual port forwarding.
* **[Nginx](https://nginx.org/)** — High-performance HTTP server developed by Igor Sysoev and maintained by F5 Networks.
* **[FFmpeg](https://ffmpeg.org/)** — Leading multimedia framework for video transcoding and decoding.
