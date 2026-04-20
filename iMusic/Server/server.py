from flask import Flask, request, jsonify, send_file, Response, stream_with_context
import yt_dlp
import os
import re
import subprocess
import tempfile
import shutil
import time
import threading
import urllib.parse
import requests as http_requests

FFMPEG_LOCATION = shutil.which("ffmpeg") or "/usr/bin/ffmpeg"
FFMPEG_DIR = os.path.dirname(FFMPEG_LOCATION) if FFMPEG_LOCATION else None

# Path to the Netscape-format cookies file used to bypass YouTube bot detection.
# Inside Docker the working directory is /app, so cookies.txt lives at /app/cookies.txt.
# When running locally the file is expected next to server.py.
_SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
COOKIES_FILE = os.path.join(_SERVER_DIR, "cookies.txt") if os.path.exists(
    os.path.join(_SERVER_DIR, "cookies.txt")
) else "/app/cookies.txt"

# Persistent cache for yt-dlp (stores the YouTube JS player after first download so
# signature/n-challenge solving works without re-downloading on every request).
# Mount /app/yt-dlp-cache as a Docker volume to survive container restarts.
YTDLP_CACHE_DIR = os.environ.get("YTDLP_CACHE_DIR", "/app/yt-dlp-cache")
os.makedirs(YTDLP_CACHE_DIR, exist_ok=True)

app = Flask(__name__)

# Cache: video_id -> {url, title, artist, duration, expires}
_cache = {}
_cache_lock = threading.Lock()
CACHE_TTL = 3600  # YouTube URLs expire in ~6h; refresh after 1h to be safe


# (client_list, use_cookies)
# Browser cookies work with web-based clients only; ios/android API endpoints
# reject browser cookies and fail with "no player response".
_CLIENT_PROFILES = [
    (["android"], True),   # pre-signed URLs + cookies to satisfy bot check
    (["android"], False),  # fallback without cookies
]

# Prefer direct HTTPS m4a streams (non-fragmented, non-DASH, non-HLS).
# Fragmented MP4 / DASH streams cause AVFoundation to report double duration on iOS,
# resulting in silence in the second half of playback.
# protocol=https selects progressive-download streams that proxy cleanly.
_FORMAT_FALLBACKS = [
    "bestaudio[ext=m4a]/bestaudio/best",
    "bestaudio",
    "best",
    "worst",  # last resort — any stream at all
]


class _QuietLogger:
    """Logs only errors from yt-dlp so we can see which clients/formats fail."""
    def debug(self, msg): pass
    def info(self, msg): pass
    def warning(self, msg): pass
    def error(self, msg): print(f"[yt-dlp] {msg}", flush=True)


def _fetch_info_with_retry(video_id, max_retries=3):
    url = f"https://www.youtube.com/watch?v={video_id}"
    last_err = None

    for clients, use_cookies in _CLIENT_PROFILES:
        # ios/android return pre-signed URLs — no JS needed.
        # All other clients need JS to decrypt the n-challenge / signature.
        no_js_clients = {"ios", "android"}
        if any(c in no_js_clients for c in clients):
            player_skip = ["webpage", "configs", "js"]
        else:
            player_skip = ["webpage"]

        base_opts = {
            "quiet": True,
            "logger": _QuietLogger(),
            "cachedir": YTDLP_CACHE_DIR,
            "nocheckcertificate": True,
            "extractor_args": {
                "youtube": {
                    "player_client": clients,
                    "player_skip": player_skip,
                }
            },
        }
        if use_cookies and os.path.exists(COOKIES_FILE):
            base_opts["cookiefile"] = COOKIES_FILE

        # First try without any format spec — get all formats yt-dlp can see,
        # then manually pick the best audio. Avoids "Requested format is not available"
        # when GetPOT unlocks metadata but the format list is unexpectedly shaped.
        try:
            with yt_dlp.YoutubeDL(base_opts) as ydl:
                info = ydl.extract_info(url, download=False)
                formats = info.get("formats") or []
                # Pick best audio-only m4a (avoids iOS double-duration bug with DASH),
                # then any audio-only, then combined as last resort (never video-only).
                audio = (
                    next((f for f in reversed(formats) if f.get("ext") == "m4a" and f.get("acodec") != "none" and f.get("vcodec") == "none"), None) or
                    next((f for f in reversed(formats) if f.get("acodec") != "none" and f.get("vcodec") == "none"), None) or
                    next((f for f in reversed(formats) if f.get("acodec") != "none" and f.get("url")), None)
                )
                if audio:
                    info["url"] = audio["url"]
                    print(f"[yt-dlp/{clients[0]}] OK (no-fmt pick: {audio.get('ext','?')} {audio.get('abr','?')}kbps)", flush=True)
                    return info
                # formats list empty — fall through to format-spec attempts
        except Exception as e:
            last_err = e
            err_str = str(e)
            print(f"[yt-dlp/{clients[0]}] no-fmt: {err_str[:120]}", flush=True)
            if "Sign in to confirm" in err_str or "Only images are available" in err_str:
                continue  # skip remaining formats for this profile

        for fmt in _FORMAT_FALLBACKS:
            opts = {**base_opts, "format": fmt}
            try:
                with yt_dlp.YoutubeDL(opts) as ydl:
                    info = ydl.extract_info(url, download=False)
                    print(f"[yt-dlp/{clients[0]}] OK", flush=True)
                    return info
            except Exception as e:
                last_err = e
                err_str = str(e)
                print(f"[yt-dlp/{clients[0]}] {err_str[:120]}", flush=True)
                if "Sign in to confirm" in err_str:
                    break  # IP/auth blocked — no point trying other formats
                if "Only images are available" in err_str:
                    break  # not a video — skip profile
                if "429" in err_str:
                    time.sleep(3)

    raise last_err


def _fetch_info_pytubefix(video_id):
    """Fallback extractor using pytubefix with multiple clients.
    Different clients use different API endpoints with different bot-detection
    thresholds — we try them in order until one works."""
    from pytubefix import YouTube

    url = f"https://www.youtube.com/watch?v={video_id}"

    # Client order tuned for cloud IPs (Railway / Render / Fly):
    # MWEB        — mobile web, lowest bot-detection threshold on datacenter IPs.
    # ANDROID     — base Android client, different UA + API path from ANDROID_VR.
    # WEB_CREATOR — YouTube Studio client, rarely rate-limited.
    # ANDROID_VR / ANDROID_MUSIC / WEB_EMBED / WEB — last resorts.
    # Removed: TV_EMBED (blocked: "no longer supported"), IOS (HTTP 400),
    #          ANDROID_EMBED (not a valid pytubefix client name → KeyError).
    _PYTUBEFIX_CLIENTS = [
        "MWEB",
        "ANDROID",
        "WEB_CREATOR",
        "ANDROID_VR",
        "ANDROID_MUSIC",
        "WEB_EMBED",
        "WEB",
    ]

    for client in _PYTUBEFIX_CLIENTS:
        try:
            yt = YouTube(url, client=client)
            # Prefer AAC/m4a — natively supported by iOS AVPlayer.
            stream = yt.streams.filter(only_audio=True, mime_type="audio/mp4").order_by("abr").last()
            if not stream:
                stream = yt.streams.filter(only_audio=True).order_by("abr").last()
            if not stream:
                stream = yt.streams.first()
            if not stream:
                continue
            print(f"[pytubefix/{client}] OK", flush=True)
            return {
                "url":      stream.url,
                "title":    yt.title or "",
                "artist":   yt.author or "",
                "duration": yt.length or 0,
                "expires":  time.time() + CACHE_TTL,
            }
        except Exception as e:
            print(f"[pytubefix/{client}] {e}", flush=True)
            continue

    return None


def _get_info(video_id):
    now = time.time()
    with _cache_lock:
        entry = _cache.get(video_id)
        if entry and entry["expires"] > now:
            return entry

    entry = None

    # Try yt-dlp first (best quality when the server IP is not rate-limited)
    try:
        info = _fetch_info_with_retry(video_id)
        entry = {
            "url":      info["url"],
            "title":    info.get("title", ""),
            "artist":   info.get("uploader", ""),
            "duration": info.get("duration", 0),
            "expires":  now + CACHE_TTL,
        }
    except Exception:
        pass

    # Fall back to pytubefix — independent Python extractor, different HTTP
    # patterns than yt-dlp, often succeeds when yt-dlp is rate-limited.
    if not entry:
        entry = _fetch_info_pytubefix(video_id)

    if not entry:
        print(f"[iMusic] All sources failed for video {video_id}", flush=True)
        raise Exception("Could not fetch stream from YouTube or Invidious")

    with _cache_lock:
        _cache[video_id] = entry
    return entry


@app.route("/")
def health():
    return jsonify({"status": "ok"}), 200


@app.route("/stream")
def stream():
    video_id = request.args.get("id", "")
    if not video_id:
        return jsonify({"error": "missing id"}), 400

    try:
        entry = _get_info(video_id)
        proxy_url = request.host_url.rstrip("/") + f"/proxy?id={video_id}"
        return jsonify({
            "url":      proxy_url,
            "title":    entry["title"],
            "artist":   entry["artist"],
            "duration": entry["duration"],
        })
    except Exception as e:
        status = 429 if "429" in str(e) else 500
        msg = "YouTube is rate-limiting the server. Please wait a moment and try again." if status == 429 else str(e)
        return jsonify({"error": msg}), status


@app.route("/proxy")
def proxy():
    video_id = request.args.get("id", "")
    if not video_id:
        return jsonify({"error": "missing id"}), 400

    try:
        entry = _get_info(video_id)
        yt_url = entry["url"]

        print(f"[proxy] {video_id} → {yt_url[:80]}...", flush=True)

        headers = {
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            "Accept": "*/*",
            "Accept-Encoding": "identity",  # avoid compressed responses
        }
        range_header = request.headers.get("Range")
        if range_header:
            headers["Range"] = range_header

        r = http_requests.get(yt_url, headers=headers, stream=True, timeout=30)
        print(f"[proxy] {video_id} → HTTP {r.status_code} {r.headers.get('Content-Type', '?')}", flush=True)

        if r.status_code not in (200, 206):
            # Invalidate cache so the next request fetches a fresh URL
            with _cache_lock:
                _cache.pop(video_id, None)
            return jsonify({"error": f"upstream returned {r.status_code}"}), 502

        response_headers = {
            "Content-Type":   r.headers.get("Content-Type", "audio/mp4"),
            "Accept-Ranges":  "bytes",
        }
        if "Content-Length" in r.headers:
            response_headers["Content-Length"] = r.headers["Content-Length"]
        if "Content-Range" in r.headers:
            response_headers["Content-Range"] = r.headers["Content-Range"]

        def generate():
            for chunk in r.iter_content(chunk_size=65536):
                if chunk:
                    yield chunk

        return Response(generate(), status=r.status_code, headers=response_headers)

    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/download")
def download():
    video_id = request.args.get("id", "")
    if not video_id:
        return jsonify({"error": "missing id"}), 400

    # yt-dlp always fails with bot detection on this server IP.
    # Go straight to pytubefix to get the direct CDN audio URL.
    info = _fetch_info_pytubefix(video_id)
    if not info:
        return jsonify({"error": "Could not fetch audio URL"}), 500

    yt_url = info["url"]
    title = info.get("title") or video_id
    safe_title = re.sub(r'[/\\:*?"<>|]', '_', title)

    # Stream ffmpeg output directly to the client — no temp file needed.
    # ffmpeg fetches the CDN URL and converts to mp3 on-the-fly.
    # Data starts flowing to the client within seconds, avoiding iOS URLSession timeouts.
    ffmpeg_cmd = [
        FFMPEG_LOCATION or "ffmpeg",
        "-headers", "User-Agent: Mozilla/5.0 (compatible)\r\nAccept: */*\r\n",
        "-i", yt_url,
        "-vn",          # audio only
        "-f", "mp3",
        "-q:a", "2",
        "pipe:1",
    ]

    try:
        proc = subprocess.Popen(
            ffmpeg_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    def generate():
        try:
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                yield chunk
        finally:
            proc.stdout.close()
            proc.wait()

    print(f"[download] {video_id} → streaming ffmpeg mp3", flush=True)
    return Response(
        stream_with_context(generate()),
        mimetype="audio/mpeg",
        headers={"Content-Disposition": f'attachment; filename="{safe_title}.mp3"'},
    )


@app.route("/related")
def related():
    video_id = request.args.get("id", "")
    if not video_id:
        return jsonify({"error": "missing id"}), 400

    try:
        # Use cached title/artist from the stream call — avoids a second YouTube fetch
        # which triggers bot-detection. The video must have been streamed first.
        with _cache_lock:
            entry = _cache.get(video_id)

        if not entry:
            return jsonify({"items": []}), 200

        title = entry.get("title", "")
        artist = entry.get("artist", "")

        # Clean noisy suffixes from the uploader name (e.g. "EdSheeranVEVO" → "EdSheeran")
        artist_clean = re.sub(
            r'(?i)\b(vevo|official|music|records?|tv|channel|entertainment)\b', '', artist
        ).strip(" -")

        # Search by artist only so we get their other songs, not the same song again.
        # Fall back to a cleaned-up title if the artist name is too short/empty.
        if len(artist_clean) > 2:
            query = artist_clean
        else:
            # Strip "Official Video / Lyrics / ft. ..." noise from the title
            query = re.sub(r'(?i)\s*[\(\[].*?[\)\]]', '', title).strip()

        search_opts = {
            "quiet": True,
            "extract_flat": True,
            "skip_download": True,
            "playlistend": 11,
            "quiet": True,
            "logger": _QuietLogger(),
            "nocheckcertificate": True,
            "extractor_args": {
                "youtube": {
                    "player_client": ["web", "android"]
                }
            },
            **( {"cookiefile": COOKIES_FILE} if os.path.exists(COOKIES_FILE) else {} ),
        }
        with yt_dlp.YoutubeDL(search_opts) as ydl:
            search_info = ydl.extract_info(f"ytsearch11:{query}", download=False)

        results = []
        for v in (search_info.get("entries") or []):
            vid_id = v.get("id")
            # Skip missing IDs, the current video, channels (UC…), and playlists
            if not vid_id or vid_id == video_id:
                continue
            if len(vid_id) != 11 or v.get("_type") in ("channel", "playlist"):
                continue
            results.append({
                "id": vid_id,
                "title": v.get("title", ""),
                "channelTitle": v.get("uploader", "") or v.get("channel", ""),
            })
            if len(results) >= 10:
                break

        return jsonify({"items": results})

    except Exception as e:
        status = 429 if "429" in str(e) else 500
        msg = "YouTube is rate-limiting the server. Please wait a moment and try again." if status == 429 else str(e)
        return jsonify({"error": msg}), status


_lyrics_cache = {}
_lyrics_cache_lock = threading.Lock()
LYRICS_CACHE_TTL = 86400  # 24 hours


def _clean_artist(artist):
    """Strip YouTube-style suffixes like '- Topic', 'VEVO', 'Official', etc."""
    cleaned = re.sub(
        r'(?i)\s*[-–]\s*(vevo|official|music|topic|channel|tv|records?|entertainment).*$',
        '', artist
    )
    cleaned = re.sub(
        r'(?i)\s*(vevo|official\s*channel|official\s*music)$',
        '', cleaned
    )
    return cleaned.strip()


def _detect_language(text):
    try:
        from langdetect import detect
        return detect(text[:500])
    except Exception:
        return "en"


def _translate_to_english(text, src_lang):
    """Translate lyrics to English using the unofficial Google Translate API.
    Returns None if translation fails or is identical to the source."""
    if not text:
        return None

    def _translate_chunk(chunk):
        try:
            r = http_requests.get(
                "https://translate.googleapis.com/translate_a/single",
                params={"client": "gtx", "sl": "auto", "tl": "en", "dt": "t", "q": chunk},
                timeout=15,
            )
            if r.status_code == 200:
                data = r.json()
                result = ''.join(item[0] for item in data[0] if item and item[0])
                if result and result.strip() != chunk.strip():
                    return result
        except Exception as e:
            print(f"Translation chunk error: {e}")
        return None  # None = failed, caller should keep original or skip

    if len(text) <= 4500:
        return _translate_chunk(text)

    # Split into ≤4500-char chunks on line boundaries
    lines = text.split('\n')
    chunks, current, current_len = [], [], 0
    for line in lines:
        if current_len + len(line) + 1 > 4500:
            if current:
                chunks.append('\n'.join(current))
            current, current_len = [line], len(line)
        else:
            current.append(line)
            current_len += len(line) + 1
    if current:
        chunks.append('\n'.join(current))

    parts = [_translate_chunk(c) or c for c in chunks]
    result = '\n'.join(parts)
    return result if result.strip() != text.strip() else None


def _fetch_from_genius(title, artist):
    """Fetch plain lyrics from Genius — best coverage for non-English content
    (Russian, Japanese, French, Italian, Hungarian, Mongolian, etc.)."""
    from html.parser import HTMLParser

    class _GeniusParser(HTMLParser):
        """Collects text from <div data-lyrics-container="true"> blocks."""
        def __init__(self):
            super().__init__()
            self._active = False
            self._depth = 0
            self._parts = []
            self._buf = []

        def handle_starttag(self, tag, attrs):
            d = dict(attrs)
            if tag == 'div' and d.get('data-lyrics-container') == 'true':
                self._active = True
                self._depth = 1
            elif self._active:
                if tag == 'div':
                    self._depth += 1
                elif tag in ('br',):
                    self._buf.append('\n')

        def handle_endtag(self, tag):
            if self._active and tag == 'div':
                self._depth -= 1
                if self._depth == 0:
                    self._parts.append(''.join(self._buf))
                    self._buf = []
                    self._active = False

        def handle_data(self, data):
            if self._active:
                self._buf.append(data)

        def lyrics(self):
            combined = '\n'.join(self._parts)
            return re.sub(r'\n{3,}', '\n\n', combined).strip()

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        "Accept-Language": "en-US,en;q=0.9",
    }
    try:
        q = f"{artist} {title}" if artist else title
        r = http_requests.get(
            "https://genius.com/api/search",
            params={"q": q},
            headers=headers,
            timeout=10,
        )
        if r.status_code != 200:
            return None
        hits = r.json().get("response", {}).get("hits", [])

        import unicodedata
        def _norm(s):
            return unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode().lower()

        title_words = [w for w in re.split(r'\W+', _norm(title)) if len(w) >= 3]

        for hit in hits[:5]:
            if hit.get("type") != "song":
                continue
            result = hit.get("result", {})
            path = result.get("path", "")
            # Only fetch actual song lyrics pages (paths end with "-lyrics")
            if not path or not path.endswith("-lyrics"):
                continue
            # Verify hit title matches our song — prevents scraping wrong pages (release lists, etc.)
            hit_title = _norm(result.get("title", ""))
            if title_words and not any(w in hit_title for w in title_words):
                continue
            page = http_requests.get(f"https://genius.com{path}", headers=headers, timeout=15)
            if page.status_code != 200:
                continue
            parser = _GeniusParser()
            parser.feed(page.text)
            raw = parser.lyrics()
            if not raw:
                continue
            # Strip section markers and validate — reject metadata/descriptions
            clean_lines = []
            for line in raw.split('\n'):
                t = line.strip()
                if not t:
                    continue
                if t.startswith('[') and t.endswith(']'):
                    continue  # [Verse 1], [Chorus], etc.
                if len(t) > 200:
                    continue  # metadata paragraphs, not lyrics
                if 'contributors' in t.lower():
                    continue
                clean_lines.append(t)
            if len(clean_lines) >= 3:
                return '\n'.join(clean_lines)
    except Exception as e:
        print(f"Genius error: {e}")
    return None


@app.route("/lyrics")
def lyrics_route():
    title = request.args.get("title", "").strip()
    artist = request.args.get("artist", "").strip()
    if not title:
        return jsonify({"error": "missing title"}), 400

    artist_clean = _clean_artist(artist)

    cache_key = f"{artist_clean}|{title}".lower()
    now = time.time()
    with _lyrics_cache_lock:
        entry = _lyrics_cache.get(cache_key)
        if entry and entry["expires"] > now:
            return jsonify(entry["data"])

    lyrics_text = None
    source = None

    # 1. lrclib.net (great for synced content)
    if not lyrics_text:
        def _lrclib_search(track_name, artist_name):
            try:
                params = {"track_name": track_name}
                if artist_name:
                    params["artist_name"] = artist_name
                r = http_requests.get(
                    "https://lrclib.net/api/search",
                    params=params,
                    headers={"Lrclib-Client": "iMusic/1.0"},
                    timeout=10,
                )
                if r.status_code == 200:
                    return r.json()
            except Exception as e:
                print(f"lrclib error: {e}")
            return []

        def _lrclib_extract(items):
            for item in items:
                text = item.get("plainLyrics", "").strip()
                if not text:
                    synced = item.get("syncedLyrics", "").strip()
                    if synced:
                        text = re.sub(r'\[\d+:\d+\.\d+\]\s*', '', synced).strip()
                if text:
                    return text
            return None

        items = _lrclib_search(title, artist_clean)
        lyrics_text = _lrclib_extract(items)

        # Retry: if no artist and title looks like "Artist SongTitle" (no dash separator),
        # split on the last space and use left part as artist, right as track.
        # Example: "いきものがかり ブルーバード" → artist="いきものがかり", track="ブルーバード"
        if not lyrics_text and not artist_clean and ' ' in title:
            last_space = title.rfind(' ')
            retry_artist = title[:last_space].strip()
            retry_title  = title[last_space+1:].strip()
            if retry_artist and retry_title:
                items2 = _lrclib_search(retry_title, retry_artist)
                lyrics_text = _lrclib_extract(items2)

        if lyrics_text:
            source = "LrcLib"

    # 2. Fallback: lyrics.ovh
    if not lyrics_text:
        for a in ([artist_clean, ""] if artist_clean else [""]):
            try:
                a_enc = urllib.parse.quote(a) if a else urllib.parse.quote(title)
                t_enc = urllib.parse.quote(title)
                url = f"https://api.lyrics.ovh/v1/{a_enc}/{t_enc}"
                r = http_requests.get(url, timeout=10)
                if r.status_code == 200:
                    lyrics_text = r.json().get("lyrics", "").strip()
                    if lyrics_text:
                        source = "lyrics.ovh"
                        break
            except Exception as e:
                print(f"lyrics.ovh error: {e}")

    # 3. Fallback: Genius — best non-English coverage (Russian, Japanese, etc.)
    if not lyrics_text:
        lyrics_text = _fetch_from_genius(title, artist_clean or artist)
        if lyrics_text:
            source = "Genius"

    if not lyrics_text:
        return jsonify({"error": "Lyrics not found"}), 404

    lang = _detect_language(lyrics_text)
    # Always attempt translation with sl=auto — Google correctly handles romanized
    # non-English text (e.g. transliterated Mongolian) that langdetect mis-labels as "en".
    # The function returns None when the translation is identical to the source (actual English).
    translated = _translate_to_english(lyrics_text, lang)

    result = {
        "lyrics": lyrics_text,
        "translated": translated,
        "language": lang,
        "source": source,
    }

    with _lyrics_cache_lock:
        _lyrics_cache[cache_key] = {"data": result, "expires": now + LYRICS_CACHE_TTL}

    return jsonify(result)


@app.route("/translate", methods=["POST"])
def translate_route():
    """Translate arbitrary text to English. Auto-detects the source language
    (more accurate than client-side detection for mixed-language lyrics)."""
    body = request.get_json(silent=True) or {}
    text = body.get("text", "").strip()
    if not text:
        return jsonify({"error": "missing text"}), 400

    # Always auto-detect on the server — langdetect is more accurate for lyrics
    # than NLLanguageRecognizer on iOS, especially for mixed-language content.
    lang = _detect_language(text)
    # Always attempt translation — sl=auto lets Google handle romanized non-English
    # text that langdetect mis-labels as "en" (e.g. transliterated Mongolian).
    translated = _translate_to_english(text, lang)
    if not translated:
        return jsonify({"translated": None, "language": lang})

    return jsonify({"translated": translated, "language": lang})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
