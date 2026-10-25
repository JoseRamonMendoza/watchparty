# Self-Hosted WatchParty with OpenTogetherTube & Tailscale

A complete, self-hosted watch party solution that streams local video files synchronously to remote friends over HTTPS without requiring port forwarding, static public IPs, or router access.

---

## Stack Architecture

* **[OpenTogetherTube](https://github.com/dyc3/opentogethertube)**: Open-source Node.js web application for synchronized video playback and real-time room chat.
* **[Nginx Video Server](https://nginx.org/)**: Light, event-driven web server configured with CORS headers to stream video files directly from `~/Videos`.
* **[Tailscale Funnel](https://tailscale.com/kb/1223/funnel)**: Zero-config mesh network powered by [WireGuard®](https://www.wireguard.com/) providing secure, persistent public HTTPS ingress tunnels that bypass CGNAT and home firewalls.

---

## Prerequisites

Before running the setup, ensure your host environment meets the following requirements:

1. **Operating System:**
   - A Linux host operating system ([Fedora](https://fedoraproject.org/) or [Debian](https://www.debian.org/)/[Ubuntu](https://ubuntu.com/)).

2. **User Privileges:**
   - A standard Linux user account with `sudo` administrative privileges.

3. **Tailscale Account & Funnel Access:**
   - A free [Tailscale Account](https://tailscale.com/).
   - Tailscale installed and logged in on the host machine.
   - Tailscale Funnel enabled in your Tailnet access control policy (ACL):
     Ensure your `tailnet` policy grants `"funnel"` rights to your node's tag or user.

4. **Docker & Docker Compose:**
   - Docker Engine and the Docker Compose plugin (`docker compose`) installed and running.
   - Your user added to the `docker` group (`sudo usermod -aG docker $USER`).

5. **Full FFmpeg Installation (with `libx264` and `ffprobe`):**
   Web streaming requires the patent-supported `libx264` encoder.

   - **Debian / Ubuntu:**
     ```bash
     sudo apt update && sudo apt install -y ffmpeg
     ```

   - **Fedora:**
     *(Fedora's default `ffmpeg-free` package lacks `libx264`. You must enable RPM Fusion to install the full multimedia build)*:
     ```bash
     # 1. Enable RPM Fusion repositories
     sudo dnf install -y \
       [https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm](https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm) -E %fedora).noarch.rpm \
       [https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm](https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm) -E %fedora).noarch.rpm

     # 2. Swap ffmpeg-free with full ffmpeg
     sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
     ```

---

## Quick Start (Automated Setup)

1. Make the setup script executable:
   ```bash
   chmod +x setup_watchparty.sh
   ```
2. Run the setup script:
   ```bash
   ./setup_watchparty.sh
   ```

---

## Daily Operation & Stack Management

Containers are configured with `restart: "no"` so they only run when you explicitly turn them on.

### Daily Management Commands

| Action | Command |
| :--- | :--- |
| **Start WatchParty Stack** | `docker compose start` |
| **Stop WatchParty Stack** | `docker compose stop` |
| **Check Container Status** | `docker compose ps` |
| **Check Active Funnels** | `tailscale serve status` |
| **View App Logs** | `docker compose logs -f opentogethertube` |
| **View Video Server Logs** | `docker compose logs -f videoserver` |

---

### Universal Video Encoding Rules
Web browsers require specific video codecs for cross-platform playback across Windows, macOS, iOS, Android, and Linux. Non-standard profiles (such as 10-bit color, H.265/HEVC, AV1, or 5.1/7.1 surround sound) cause browser decode errors (such as NS_ERROR_DOM_MEDIA_DECODE_ERR) or black screens.

Mandatory Encoding Profile
Container: MP4 (.mp4)

Video Codec: H.264 / AVC 8-bit (libx264, yuv420p)

Audio Codec: 2-Channel Stereo AAC (-c:a aac -ac 2 -b:a 192k)

HTTP Fast-Start: -movflags +faststart (places stream index headers at the start of the file for instant buffering)

### Video Transcoding & Verification (`transcode.sh`)

Use the bundled `transcode.sh` utility to convert any video format (`.mkv`, `.avi`, `.mov`, `.webm`, `.mp4`) into an 8-bit H.264/AAC stereo MP4 optimized for browser streaming. The script automatically validates output compatibility after conversion, and can also be used standalone to inspect existing video files.

#### CLI Options

| Flag | Argument | Description |
| :--- | :--- | :--- |
| `-i` | `<file>` | Path to the input video file (required for transcoding). |
| `-o` | `<file>` | Custom destination path (default: `<input_name>_web.mp4`). |
| `-s` | `<file>` | Burn an external subtitle file (`.srt`, `.ass`, `.vtt`) into the video. |
| `-e` | `[index]` | Burn an internal/embedded subtitle stream (default: `0` for first track). |
| `-c` | `<file>` | Inspect an existing video file for web compatibility without encoding. |
| `-h` | None | Display usage instructions and examples. |

---

#### Usage Examples

**1. Standard Conversion (Auto-Verified)**
Converts the input file and outputs `<input_name>_web.mp4`, running compatibility verification upon completion:
```bash
./transcode.sh -i ~/Videos/input.mkv
```

**2. Custom Output Destination**
```bash
./transcode.sh -i ~/Videos/input.mkv -o ~/Videos/party_stream.mp4
```

**3. Burn External Subtitles**
Hardcodes `.srt` or `.ass` subtitle tracks directly into the video stream:
```bash
./transcode.sh -i ~/Videos/input.mkv -s ~/Videos/subtitles.srt
```

**4. Burn Embedded Subtitles**
Hardcodes subtitles already contained inside the container:
```bash
# Burn first embedded subtitle stream (index 0)
./transcode.sh -i ~/Videos/input.mkv -e

# Burn specific embedded subtitle stream (e.g., track 1)
./transcode.sh -i ~/Videos/input.mkv -e 1
```

**5. Standalone Compatibility Check**
Verify whether any existing video file on your system meets browser streaming requirements without modifying it:
```bash
./transcode.sh -c ~/Videos/output_web.mp4
```

*Expected output on success:*
```text
==================================================
 Verifying Web Compatibility: output_web.mp4
==================================================
  • Video Codec:  h264       (Required: h264)
  • Pixel Format: yuv420p    (Required: yuv420p)
  • Audio Codec:  aac        (Required: aac)
  • Channels:     2          (Required: 2)
--------------------------------------------------
 Status: READY (Matches universal web streaming standard)
==================================================
```

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
   tailscale serve status
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
