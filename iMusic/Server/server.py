from flask import Flask, request, jsonify, Response, stream_with_context
import os
import re
import subprocess
import shutil
import time
import threading
import urllib.parse
import requests as http_requests

FFMPEG_LOCATION = shutil.which("ffmpeg") or "/usr/bin/ffmpeg"

app = Flask(__name__)

_cache = {}
_cache_lock = threading.Lock()


def _fetch_info_cobalt(video_id):
    """cobalt.tools public API — runs on independent infrastructure not flagged by YouTube."""
    try:
        r = http_requests.post(
            "https://api.cobalt.tools/",
            json={
                "url": f"https://www.youtube.com/watch?v={video_id}",
                "downloadMode": "audio",
            },
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "iMusic/1.0",
            },
            timeout=15,
        )
        if r.status_code != 200:
            print(f"[cobalt] HTTP {r.status_code}", flush=True)
            return None
        data = r.json()
        status = data.get("status")
        if status in ("error", "rate-limit"):
            print(f"[cobalt] {status}: {data.get('error', {}).get('code', '')}", flush=True)
            return None
        url = data.get("url")
        if not url:
            print(f"[cobalt] no url (status={status})", flush=True)
            return None
        print(f"[cobalt] OK → {status}", flush=True)
        filename = data.get("filename", "")
        title = re.sub(r'\.(opus|mp3|m4a|webm)$', '', filename)
        return {
            "url":      url,
            "title":    title,
            "artist":   "",
            "duration": 0,
            "expires":  time.time() + 1800,
        }
    except Exception as e:
        print(f"[cobalt] {e}", flush=True)
    return None


def _get_info(video_id):
    now = time.time()
    with _cache_lock:
        entry = _cache.get(video_id)
        if entry and entry["expires"] > now:
            return entry

    entry = _fetch_info_cobalt(video_id)

    if not entry:
        print(f"[iMusic] cobalt failed for {video_id}", flush=True)
        raise Exception("Could not fetch stream from YouTube")

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
        return jsonify({"error": str(e)}), 500


@app.route("/proxy")
def proxy():
    video_id = request.args.get("id", "")
    if not video_id:
        return jsonify({"error": "missing id"}), 400
    try:
        entry = _get_info(video_id)
        url = entry["url"]
        print(f"[proxy] {video_id} → {url[:80]}...", flush=True)

        headers = {"Accept": "*/*", "Accept-Encoding": "identity"}
        range_header = request.headers.get("Range")
        if range_header:
            headers["Range"] = range_header

        r = http_requests.get(url, headers=headers, stream=True, timeout=30)
        print(f"[proxy] {video_id} → HTTP {r.status_code} {r.headers.get('Content-Type', '?')}", flush=True)

        if r.status_code not in (200, 206):
            with _cache_lock:
                _cache.pop(video_id, None)
            return jsonify({"error": f"upstream returned {r.status_code}"}), 502

        response_headers = {
            "Content-Type":  r.headers.get("Content-Type", "audio/mp4"),
            "Accept-Ranges": "bytes",
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

    info = _fetch_info_cobalt(video_id)
    if not info:
        return jsonify({"error": "Could not fetch audio URL"}), 500

    source_url = info["url"]
    title = info.get("title") or video_id
    safe_title = re.sub(r'[/\\:*?"<>|]', '_', title)

    ffmpeg_cmd = [
        FFMPEG_LOCATION or "ffmpeg",
        "-i", source_url,
        "-vn",
        "-f", "mp3",
        "-q:a", "2",
        "pipe:1",
    ]

    try:
        proc = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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
    encoded_name = urllib.parse.quote(f"{safe_title}.mp3", safe='')
    return Response(
        stream_with_context(generate()),
        mimetype="audio/mpeg",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{encoded_name}"},
    )


@app.route("/related")
def related():
    return jsonify({"items": []}), 200


_lyrics_cache = {}
_lyrics_cache_lock = threading.Lock()
LYRICS_CACHE_TTL = 86400


def _clean_artist(artist):
    cleaned = re.sub(
        r'(?i)\s*[-–]\s*(vevo|official|music|topic|channel|tv|records?|entertainment).*$',
        '', artist
    )
    cleaned = re.sub(r'(?i)\s*(vevo|official\s*channel|official\s*music)$', '', cleaned)
    return cleaned.strip()


def _detect_language(text):
    try:
        from langdetect import detect
        return detect(text[:500])
    except Exception:
        return "en"


def _translate_to_english(text, src_lang):
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
        return None

    if len(text) <= 4500:
        return _translate_chunk(text)

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
    from html.parser import HTMLParser

    class _GeniusParser(HTMLParser):
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
                elif tag == 'br':
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
        r = http_requests.get("https://genius.com/api/search", params={"q": q}, headers=headers, timeout=10)
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
            if not path or not path.endswith("-lyrics"):
                continue
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
            clean_lines = []
            for line in raw.split('\n'):
                t = line.strip()
                if not t or (t.startswith('[') and t.endswith(']')):
                    continue
                if len(t) > 200 or 'contributors' in t.lower():
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

    if not lyrics_text and not artist_clean and ' ' in title:
        last_space = title.rfind(' ')
        retry_artist = title[:last_space].strip()
        retry_title = title[last_space + 1:].strip()
        if retry_artist and retry_title:
            items2 = _lrclib_search(retry_title, retry_artist)
            lyrics_text = _lrclib_extract(items2)

    if lyrics_text:
        source = "LrcLib"

    if not lyrics_text:
        for a in ([artist_clean, ""] if artist_clean else [""]):
            try:
                a_enc = urllib.parse.quote(a) if a else urllib.parse.quote(title)
                t_enc = urllib.parse.quote(title)
                r = http_requests.get(f"https://api.lyrics.ovh/v1/{a_enc}/{t_enc}", timeout=10)
                if r.status_code == 200:
                    lyrics_text = r.json().get("lyrics", "").strip()
                    if lyrics_text:
                        source = "lyrics.ovh"
                        break
            except Exception as e:
                print(f"lyrics.ovh error: {e}")

    if not lyrics_text:
        lyrics_text = _fetch_from_genius(title, artist_clean or artist)
        if lyrics_text:
            source = "Genius"

    if not lyrics_text:
        return jsonify({"error": "Lyrics not found"}), 404

    lang = _detect_language(lyrics_text)
    translated = _translate_to_english(lyrics_text, lang)

    result = {"lyrics": lyrics_text, "translated": translated, "language": lang, "source": source}
    with _lyrics_cache_lock:
        _lyrics_cache[cache_key] = {"data": result, "expires": now + LYRICS_CACHE_TTL}

    return jsonify(result)


@app.route("/translate", methods=["POST"])
def translate_route():
    body = request.get_json(silent=True) or {}
    text = body.get("text", "").strip()
    if not text:
        return jsonify({"error": "missing text"}), 400

    lang = _detect_language(text)
    translated = _translate_to_english(text, lang)
    if not translated:
        return jsonify({"translated": None, "language": lang})

    return jsonify({"translated": translated, "language": lang})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
