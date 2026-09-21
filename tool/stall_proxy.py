#!/usr/bin/env python3
"""Local HTTP relay that can freeze or throttle a stream on demand.

The whole point of the stream watchdog is to recover from a stream that stops
delivering data while the socket stays open - the case that used to hang
forever with no error. Waiting for a real IPTV provider to misbehave is not a
test; this reproduces that failure deterministically.

Sits between the player and a real origin stream and applies a timeline:

    relay:20,stall:45,relay:60

  relay:<s>  forward bytes normally for <s> seconds
  stall:<s>  stop forwarding for <s> seconds, keeping the socket OPEN
             (this is the freeze - no data, no error, no disconnect)
  drop:<s>   close the connection abruptly, refuse new ones for <s> seconds
             (tests whether FFmpeg's own reconnect absorbs it without the
             watchdog ever needing to fire)
  throttle:<s>@<kbps>
             forward bytes for <s> seconds, but paced at <kbps> kilobits per
             second instead of realtime - a pipe too narrow for the stream's
             bitrate. This is the case the quality ladder exists for, and it is
             distinct from every phase above: data keeps arriving, nothing
             errors, and the stream is never frozen for long enough to look
             like a freeze - it just rebuffers over and over. Nothing in this
             file could produce that before, which meant the congestion
             detector had no end-to-end test.

Two modes:

  --mode hls  rewrite playlists so segment fetches come back through the proxy
  --mode ts   (default) concatenate an HLS source's segments into ONE endless
              MPEG-TS response, paced at realtime - which is the shape of an
              Xtream live stream, and the shape this app actually has to
              survive. Pacing matters: delivered unpaced, mpv would buffer
              minutes of video and a stall would never surface as a freeze.

Usage:
    python tool/stall_proxy.py --upstream <URL> --script relay:25,stall:60
    python tool/stall_proxy.py --upstream <URL> \
        --script relay:20,throttle:120@400,relay:120
    # then point the player at http://127.0.0.1:8899/
"""

import argparse
import base64
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = time.monotonic()
# The timeline is measured from the moment the player actually starts pulling
# media, not from proxy launch - otherwise a slow build eats the relay phase and
# the stream is already stalled before playback ever begins.
STREAM_START = None
TIMELINE = []
UPSTREAM = ""
MODE = "ts"
CHUNK = 64 * 1024


def log(message):
    print(f"[proxy {time.monotonic() - START:7.1f}s] {message}", flush=True)


DEFAULT_THROTTLE_KBPS = 400.0


def parse_script(script):
    """'relay:20,throttle:45@400' -> [('relay', 20.0, None), ('throttle', 45.0, 400.0)]

    The third element is the target rate in kilobits per second, and is only
    meaningful for a throttle phase.
    """
    phases = []
    for part in script.split(","):
        part = part.strip()
        if not part:
            continue
        kind, _, argument = part.partition(":")
        if kind not in ("relay", "stall", "drop", "throttle"):
            raise ValueError(f"unknown phase {kind!r}")

        seconds, _, rate = argument.partition("@")
        kbps = None
        if kind == "throttle":
            kbps = float(rate) if rate else DEFAULT_THROTTLE_KBPS
            if kbps <= 0:
                raise ValueError("throttle rate must be positive")
        elif rate:
            raise ValueError(f"{kind!r} does not take a rate")

        phases.append((kind, float(seconds), kbps))
    return phases


def stream_elapsed():
    global STREAM_START
    if STREAM_START is None:
        STREAM_START = time.monotonic()
        log("client connected - timeline starts now")
    return time.monotonic() - STREAM_START


def phase_at(elapsed):
    """(kind, kbps) the timeline is in at `elapsed` seconds. Past the end of the
    timeline the stream relays normally, so recovery has something to recover
    to."""
    cursor = 0.0
    for kind, duration, kbps in TIMELINE:
        if elapsed < cursor + duration:
            return kind, kbps
        cursor += duration
    return "relay", None


def encode(url):
    return base64.urlsafe_b64encode(url.encode()).decode()


def decode(token):
    return base64.urlsafe_b64decode(token.encode()).decode()


def rewrite_playlist(body, base_url, proxy_root):
    """Point every URI in an HLS playlist back at this proxy, so segment
    fetches are subject to the timeline too."""
    out = []
    for line in body.decode("utf-8", "replace").splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            absolute = urllib.parse.urljoin(base_url, stripped)
            out.append(f"{proxy_root}/p?u={encode(absolute)}")
        elif 'URI="' in stripped:
            prefix, _, rest = stripped.partition('URI="')
            uri, _, suffix = rest.partition('"')
            absolute = urllib.parse.urljoin(base_url, uri)
            out.append(f'{prefix}URI="{proxy_root}/p?u={encode(absolute)}"{suffix}')
        else:
            out.append(line)
    return "\n".join(out).encode()


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "IPTV Player/1.0"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.read(), response.geturl()


def resolve_media_playlist(url):
    """Follow a master playlist down to a media playlist of actual segments."""
    body, final_url = fetch(url)
    text = body.decode("utf-8", "replace")

    if "#EXT-X-STREAM-INF" in text:
        for line in text.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                return resolve_media_playlist(urllib.parse.urljoin(final_url, line))
        raise RuntimeError("master playlist had no variants")

    segments = []
    duration = 6.0
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXTINF:"):
            try:
                duration = float(line[8:].split(",")[0])
            except ValueError:
                duration = 6.0
        elif line and not line.startswith("#"):
            segments.append((urllib.parse.urljoin(final_url, line), duration))
    if not segments:
        raise RuntimeError("no segments found")
    return segments


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # too noisy; we do our own logging

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        if MODE == "ts" and parsed.path != "/p":
            self._serve_endless_ts()
            return

        if parsed.path == "/p":
            params = urllib.parse.parse_qs(parsed.query)
            target = decode(params["u"][0])
        else:
            target = UPSTREAM

        proxy_root = f"http://{self.headers.get('Host', '127.0.0.1:8899')}"

        try:
            request = urllib.request.Request(
                target, headers={"User-Agent": "IPTV Player/1.0"}
            )
            upstream = urllib.request.urlopen(request, timeout=15)
        except Exception as exc:
            log(f"upstream failed: {type(exc).__name__}")
            self.send_error(502)
            return

        content_type = upstream.headers.get("Content-Type", "")
        is_playlist = "mpegurl" in content_type.lower() or target.endswith(".m3u8")

        if is_playlist:
            body = rewrite_playlist(upstream.read(), target, proxy_root)
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(200)
        self.send_header("Content-Type", content_type or "video/mp2t")
        self.send_header("Connection", "close")
        self.end_headers()
        self._relay(upstream)

    def _serve_endless_ts(self):
        """One never-ending MPEG-TS response, looping the source segments and
        pacing each one over its EXTINF duration. This is what an Xtream live
        stream looks like to the player."""
        try:
            segments = resolve_media_playlist(UPSTREAM)
        except Exception as exc:
            log(f"could not resolve source: {exc}")
            self.send_error(502)
            return

        log(f"serving endless TS from {len(segments)} segments, paced at realtime")
        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Connection", "close")
        self.end_headers()

        announced = None
        served = 0
        index = 0

        while True:
            url, duration = segments[index % len(segments)]
            index += 1

            try:
                data, _ = fetch(url)
            except Exception as exc:
                log(f"segment fetch failed: {type(exc).__name__}")
                return

            # Spread this segment's bytes across its playback duration.
            slices = max(1, int(duration * 4))
            size = max(1, len(data) // slices)
            deadline = time.monotonic()

            for offset in range(0, len(data), size):
                phase, kbps = phase_at(stream_elapsed())
                if phase != announced:
                    rate = f" @ {kbps:.0f}kbps" if kbps else ""
                    log(f"--> {phase.upper()}{rate} "
                        f"(served {served // 1024} KiB)")
                    announced = phase

                if phase == "drop":
                    log("dropping connection")
                    try:
                        self.wfile.close()
                    except OSError:
                        pass
                    return

                if phase == "stall":
                    # Socket open, no bytes. The freeze.
                    time.sleep(0.25)
                    continue

                try:
                    self.wfile.write(data[offset:offset + size])
                    served += size
                except (BrokenPipeError, ConnectionResetError, OSError):
                    log("client went away")
                    return

                if phase == "throttle":
                    # Pace to the target rate rather than to playback. The
                    # deadline is re-anchored to now so that leaving the phase
                    # resumes realtime pacing instead of dumping the whole
                    # backlog in one burst - the stream simply runs late, which
                    # is what a narrow pipe actually does.
                    time.sleep((size * 8) / (kbps * 1000.0))
                    deadline = time.monotonic()
                    continue

                deadline += duration / slices
                sleep_for = deadline - time.monotonic()
                if sleep_for > 0:
                    time.sleep(sleep_for)

    def _relay(self, upstream):
        """Forward the body, obeying the timeline. A stall deliberately stops
        writing without closing - that is the freeze being reproduced."""
        announced = None
        served = 0

        while True:
            phase, kbps = phase_at(stream_elapsed())

            if phase != announced:
                rate = f" @ {kbps:.0f}kbps" if kbps else ""
                log(f"--> {phase.upper()}{rate} "
                    f"(served {served // 1024} KiB so far)")
                announced = phase

            if phase == "drop":
                log("dropping connection")
                try:
                    self.wfile.close()
                except OSError:
                    pass
                return

            if phase == "stall":
                # Socket stays open, no bytes move. This is the freeze.
                time.sleep(0.25)
                continue

            try:
                chunk = upstream.read(CHUNK)
            except Exception as exc:
                log(f"upstream read failed: {type(exc).__name__}")
                return

            if not chunk:
                log("upstream ended")
                return

            try:
                self.wfile.write(chunk)
                served += len(chunk)
            except (BrokenPipeError, ConnectionResetError, OSError):
                log("client went away")
                return

            if phase == "throttle":
                # Hold the write rate below the stream's bitrate. Unlike the
                # endless-TS path this relay is not realtime-paced to begin
                # with, so throttling is the only pacing here.
                time.sleep((len(chunk) * 8) / (kbps * 1000.0))


def main():
    global TIMELINE, UPSTREAM, MODE

    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--script", default="relay:20,stall:45")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--mode", choices=("ts", "hls"), default="ts")
    args = parser.parse_args()

    TIMELINE = parse_script(args.script)
    UPSTREAM = args.upstream
    MODE = args.mode

    total = sum(d for _, d in TIMELINE)
    log(f"mode: {args.mode}")
    log(f"timeline: {args.script}  (relays normally after {total:.0f}s)")
    log(f"listening on http://127.0.0.1:{args.port}/")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
