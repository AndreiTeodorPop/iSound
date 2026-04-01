from flask import Flask, request, jsonify, send_file, Response
import yt_dlp
import os
import re
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


# Profile 1: web with cookies + persistent JS player cache for signature solving.
# Profile 2: ios without cookies — uses Apple's API (HLS streams, no signature needed).
#            Only attempted if web fails; ios hits bot detection on rate-limited IPs.
_CLIENT_PROFILES = [
    (["web"], True),
    (["ios"], False),
]

# HLS (m3u8) formats are pre-signed and need no JS decryption — ideal for ios client.
_FORMAT_FALLBACKS = [
    "bestaudio[protocol=m3u8_native]/bestaudio[protocol=m3u8]/bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio/best",
    "bestaudio[protocol=m3u8_native]/bestaudio[protocol=m3u8]/bestaudio/best",
    "best[protocol=m3u8_native]/best[protocol=m3u8]/best",
]


class _QuietLogger:
    """Fully silent yt-dlp logger — yt-dlp failures are expected and handled
    by the Invidious fallback, so we don't need noise in the console."""
    def debug(self, msg): pass
    def info(self, msg): pass
    def warning(self, msg): pass
    def error(self, msg): pass


def _fetch_info_with_retry(video_id, max_retries=3):
    url = f"https://www.youtube.com/watch?v={video_id}"
    last_err = None

    for clients, use_cookies in _CLIENT_PROFILES:
        base_opts = {
            "quiet": True,
            "logger": _QuietLogger(),
            "cachedir": YTDLP_CACHE_DIR,
            "nocheckcertificate": True,
            "extractor_args": {
                "youtube": {"player_client": clients}
            },
        }
        if use_cookies and os.path.exists(COOKIES_FILE):
            base_opts["cookiefile"] = COOKIES_FILE

        for fmt in _FORMAT_FALLBACKS:
            opts = {**base_opts, "format": fmt}
            try:
                with yt_dlp.YoutubeDL(opts) as ydl:
                    return ydl.extract_info(url, download=False)
            except Exception as e:
                last_err = e
                err_str = str(e)
                if "Requested format is not available" in err_str or \
                   "Only images are available" in err_str or \
                   "Sign in to confirm" in err_str:
                    break  # this profile won't work, try next profile
                # 429: brief wait then try next format
                if "429" in err_str:
                    time.sleep(3)
                # any other error: move on immediately

    raise last_err


# Invidious public instances — tried in order when yt-dlp fails.
# These run their own extraction and return pre-solved YouTube stream URLs.
_INVIDIOUS_INSTANCES = [
    "https://inv.nadeko.net",
    "https://invidious.fdn.fr",
    "https://yt.drgnz.club",
    "https://invidious.privacyredirect.com",
]


def _fetch_info_invidious(video_id):
    """Fetch stream URL from Invidious API (no signature solving required)."""
    for base in _INVIDIOUS_INSTANCES:
        try:
            r = http_requests.get(
                f"{base}/api/v1/videos/{video_id}",
                headers={"User-Agent": "iMusic/1.0"},
                timeout=8,
            )
            print(f"[Invidious] {base} → HTTP {r.status_code}", flush=True)
            if r.status_code != 200:
                continue
            data = r.json()
            if "error" in data:
                print(f"[Invidious] {base} → API error: {data['error']}", flush=True)
                continue

            # Prefer adaptive audio-only formats; fall back to muxed streams
            formats = data.get("adaptiveFormats", []) + data.get("formatStreams", [])
            audio = [f for f in formats if "audio" in f.get("type", "") and "video" not in f.get("type", "")]
            if not audio:
                audio = formats
            if not audio:
                print(f"[Invidious] {base} → no formats found", flush=True)
                continue

            best = max(audio, key=lambda f: int(f.get("bitrate", 0)))
            url = best.get("url")
            if not url:
                print(f"[Invidious] {base} → best format has no url", flush=True)
                continue

            print(f"[Invidious] {base} → OK", flush=True)
            return {
                "url":      url,
                "title":    data.get("title", ""),
                "artist":   data.get("author", ""),
                "duration": int(data.get("lengthSeconds", 0)),
                "expires":  time.time() + CACHE_TTL,
            }
        except Exception as e:
            print(f"[Invidious] {base} → exception: {e}", flush=True)
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

    # Fall back to Invidious (pre-solved URLs, works around rate-limited IPs)
    if not entry:
        entry = _fetch_info_invidious(video_id)

    if not entry:
        print(f"[iMusic] All sources failed for video {video_id}", flush=True)
        raise Exception("Could not fetch stream from YouTube or Invidious")

    with _cache_lock:
        _cache[video_id] = entry
    return entry


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

        headers = {"User-Agent": "Mozilla/5.0"}
        range_header = request.headers.get("Range")
        if range_header:
            headers["Range"] = range_header

        r = http_requests.get(yt_url, headers=headers, stream=True, timeout=30)

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

    tmp_dir = tempfile.mkdtemp()
    output_template = os.path.join(tmp_dir, "%(title)s.%(ext)s")

    url = f"https://www.youtube.com/watch?v={video_id}"
    last_err = None
    info = None

    for clients, use_cookies in _CLIENT_PROFILES:
        dl_base = {
            "quiet": True,
            "logger": _QuietLogger(),
            "cachedir": YTDLP_CACHE_DIR,
            "outtmpl": output_template,
            "postprocessors": [{
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "192",
            }],
            "keepvideo": False,
            "nocheckcertificate": True,
            "extractor_args": {
                "youtube": {"player_client": clients}
            },
            **({"ffmpeg_location": FFMPEG_DIR} if FFMPEG_DIR else {}),
        }
        if use_cookies and os.path.exists(COOKIES_FILE):
            dl_base["cookiefile"] = COOKIES_FILE

        for fmt in _FORMAT_FALLBACKS:
            opts = {**dl_base, "format": fmt}
            try:
                with yt_dlp.YoutubeDL(opts) as ydl:
                    info = ydl.extract_info(url, download=True)
                break  # success
            except Exception as e:
                last_err = e
                err_str = str(e)
                if "Requested format is not available" in err_str or \
                   "Only images are available" in err_str:
                    continue  # try next format
                raise  # unexpected error — surface immediately

        if info is not None:
            break  # got a result, skip remaining client profiles

    if info is None:
        raise last_err

    try:
        title = info.get("title", video_id)

        files = os.listdir(tmp_dir)
        if not files:
            return jsonify({"error": "download produced no file"}), 500

        file_path = os.path.join(tmp_dir, files[0])

        return send_file(
            file_path,
            mimetype="audio/mpeg",
            as_attachment=True,
            download_name=f"{title}.mp3"
        )

    except Exception as e:
        return jsonify({"error": str(e)}), 500

    finally:
        for f in os.listdir(tmp_dir):
            try:
                os.remove(os.path.join(tmp_dir, f))
            except Exception:
                pass
        try:
            os.rmdir(tmp_dir)
        except Exception:
            pass


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
    try:
        from deep_translator import GoogleTranslator
        if len(text) <= 4500:
            result = GoogleTranslator(source=src_lang, target='en').translate(text)
            return result
        # Split into chunks preserving line boundaries
        lines = text.split('\n')
        chunks, current, current_len = [], [], 0
        for line in lines:
            if current_len + len(line) + 1 > 4500:
                chunks.append('\n'.join(current))
                current, current_len = [line], len(line)
            else:
                current.append(line)
                current_len += len(line) + 1
        if current:
            chunks.append('\n'.join(current))
        translated_parts = []
        for chunk in chunks:
            t = GoogleTranslator(source=src_lang, target='en').translate(chunk)
            translated_parts.append(t or chunk)
        return '\n'.join(translated_parts)
    except Exception as e:
        print(f"Translation error (Google): {e}")
        # Fallback: MyMemory (handles up to ~500 chars per request)
        try:
            r = http_requests.get(
                "https://api.mymemory.translated.net/get",
                params={"q": text[:490], "langpair": f"{src_lang}|en"},
                timeout=10,
            )
            if r.status_code == 200:
                return r.json().get("responseData", {}).get("translatedText")
        except Exception:
            pass
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

    # 1. Try lrclib.net (free, no key, best coverage)
    lyrics_text = None
    try:
        r = http_requests.get(
            "https://lrclib.net/api/search",
            params={"track_name": title, "artist_name": artist_clean or title},
            headers={"Lrclib-Client": "iMusic/1.0"},
            timeout=10,
        )
        if r.status_code == 200:
            items = r.json()
            for item in items:
                text = item.get("plainLyrics", "").strip()
                if text:
                    lyrics_text = text
                    break
    except Exception as e:
        print(f"lrclib error: {e}")

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
                        break
            except Exception as e:
                print(f"lyrics.ovh error: {e}")

    if not lyrics_text:
        return jsonify({"error": "Lyrics not found"}), 404

    lang = _detect_language(lyrics_text)
    translated = None
    if lang != "en":
        translated = _translate_to_english(lyrics_text, lang)

    result = {
        "lyrics": lyrics_text,
        "translated": translated,
        "language": lang,
    }

    with _lyrics_cache_lock:
        _lyrics_cache[cache_key] = {"data": result, "expires": now + LYRICS_CACHE_TTL}

    return jsonify(result)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
