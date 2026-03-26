from flask import Flask, request, jsonify, send_file, Response
import yt_dlp
import os
import tempfile
import shutil
import time
import threading
import requests as http_requests

FFMPEG_LOCATION = shutil.which("ffmpeg") or "/usr/bin/ffmpeg"
FFMPEG_DIR = os.path.dirname(FFMPEG_LOCATION) if FFMPEG_LOCATION else None

app = Flask(__name__)

# Cache: video_id -> {url, title, artist, duration, expires}
_cache = {}
_cache_lock = threading.Lock()
CACHE_TTL = 3600  # YouTube URLs expire in ~6h; refresh after 1h to be safe


def _get_info(video_id):
    now = time.time()
    with _cache_lock:
        entry = _cache.get(video_id)
        if entry and entry["expires"] > now:
            return entry

    opts = {
        "quiet": True,
        "format": "bestaudio[ext=m4a]/bestaudio",
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(
            f"https://www.youtube.com/watch?v={video_id}",
            download=False
        )

    entry = {
        "url":      info["url"],
        "title":    info.get("title", ""),
        "artist":   info.get("uploader", ""),
        "duration": info.get("duration", 0),
        "expires":  now + CACHE_TTL,
    }
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
        # Return a proxy URL so the iPhone doesn't hit the IP-locked CDN directly
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

    opts = {
        "quiet": True,
        "format": "bestaudio[ext=m4a]/bestaudio/best",
        "outtmpl": output_template,
        "postprocessors": [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "m4a",
            "preferredquality": "192",
        }],
        "keepvideo": False,
        **({"ffmpeg_location": FFMPEG_DIR} if FFMPEG_DIR else {}),
    }

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(
                f"https://www.youtube.com/watch?v={video_id}",
                download=True
            )
            title = info.get("title", video_id)

        files = os.listdir(tmp_dir)
        if not files:
            return jsonify({"error": "download produced no file"}), 500

        file_path = os.path.join(tmp_dir, files[0])

        return send_file(
            file_path,
            mimetype="audio/mp4",
            as_attachment=True,
            download_name=f"{title}.m4a"
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


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
