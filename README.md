# Self-Hosted WatchParty with OpenTogetherTube & Tailscale

A complete, self-hosted watch party solution that streams local video files synchronously to remote friends over HTTPS without requiring port forwarding or router access.

---

## Stack Architecture

* **OpenTogetherTube**: Node.js web application for synchronized video playback and chat.
* **PostgreSQL & Redis**: Storage backends for rooms, users, and state management.
* **Nginx Video Server**: High-performance static web server configured with CORS headers for streaming video from `~/Videos`.
* **Tailscale Funnel**: Secure, persistent peer-to-peer mesh & public HTTPS ingress tunnel bypassing home firewalls/CGNAT.

---

## Prerequisites

* A Linux host operating system (**Fedora** or **Debian/Ubuntu** derivative).
* A free [Tailscale Account](https://tailscale.com/).
* A regular user account with `sudo` privileges.

---

## Quick Start (Automated Setup)

1. Save `setup_watchparty.sh` in your project directory (e.g., `~/dev/watchparty/setup_watchparty.sh`).
2. Make the setup script executable:
   ```bash
   chmod +x setup_watchparty.sh
   ```
3. Run the setup script:
   ```bash
   ./setup_watchparty.sh
   ```
   *The script prompts for your OS profile (Debian/Ubuntu vs. Fedora), installs dependencies, enables systemd services on boot, clones the repository, generates secrets, configures `production.toml` and `nginx.conf`, sets up background Tailscale Funnels, launches the containers, and runs database migrations automatically.*

---

## Daily Operation & Stack Management

Containers are configured with `restart: "no"` so they only run when explicitly started.

### Daily Management Commands

| Action | Command |
| :--- | :--- |
| **Start WatchParty Stack** | `docker compose start` |
| **Stop WatchParty Stack** | `docker compose stop` |
| **Check Container Status** | `docker compose ps` |
| **Check Active Funnels** | `tailscale funnel status` |
| **View Service Logs** | `docker compose logs -f opentogethertube`, `docker compose logs -f videoserver` |

---

## Universal Video Encoding Rules

Web browsers require specific video codecs for cross-platform playback (Windows, macOS, iOS, Android, Linux). Non-standard profiles (such as 10-bit color, H.265/HEVC, or 5.1 surround sound) cause playback errors like `NS_ERROR_DOM_MEDIA_DECODE_ERR` or black screens.

### Mandatory Encoding Profile

* **Container:** MP4 (`.mp4`)
* **Video Codec:** H.264 / AVC (`libx264`)
* **Color Space / Pixel Format:** 8-bit `yuv420p`
* **Audio Codec:** 2-Channel Stereo AAC (`-c:a aac -ac 2`)
* **HTTP Fast-Start:** `-movflags +faststart`

### Universal FFmpeg Conversion Command

Run this command on any video file before streaming:

```bash
ffmpeg -i ~/Videos/input.mkv \
  -c:v libx264 -pix_fmt yuv420p -preset fast -crf 22 \
  -c:a aac -ac 2 -b:a 192k \
  -movflags +faststart \
  ~/Videos/output.mp4
```

### Verifying File Compatibility

Check that an encoded file matches web standards:

```bash
ffprobe -v error -show_entries stream=codec_name,pix_fmt,channels -of default=noprintwrappers=1 ~/Videos/movie_web.mp4
```
*Expected output: `h264`, `yuv420p`, `aac`, `2`.*

### Hardcoding subtitles to you videos

```bash
ffmpeg -i ~/Videos/input.mp4 \
  -vf "subtitles=/path/to/subtitles.srt" \
  -c:a copy ~/Videos/output.mp4
```

---

## Adding Videos to Your Room

1. Place your converted MP4 files in `~/Videos/`.
2. Open your OpenTogetherTube interface at `https://<your-magicdns>.ts.net/`.
3. Create or join a room.
4. Add the video stream URL to the queue using your video server's HTTPS endpoint:
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
* Re-encode the file using the Universal FFmpeg Conversion Command above.

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
