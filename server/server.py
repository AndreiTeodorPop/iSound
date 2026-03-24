from flask import Flask, request, jsonify, send_file, after_this_request
import yt_dlp
import os
import tempfile

app = Flask(__name__)


@app.route("/stream")
def stream():
    video_id = request.args.get("id", "")
    if not video_id:
        return jsonify({"error": "missing id"}), 400

    opts = {
        "quiet": True,
        "format": "bestaudio[ext=m4a]/bestaudio",
    }
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(
                f"https://www.youtube.com/watch?v={video_id}",
                download=False
            )
        return jsonify({
            "url": info["url"],
            "title": info.get("title", ""),
            "artist": info.get("uploader", ""),
            "duration": info.get("duration", 0)
        })
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
        # No FFmpeg postprocessors — download the native format directly
        "format": "bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio",
        "outtmpl": output_template,
    }

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(
                f"https://www.youtube.com/watch?v={video_id}",
                download=True
            )
            title = info.get("title", video_id)
            ext = info.get("ext", "m4a")

        files = os.listdir(tmp_dir)
        if not files:
            return jsonify({"error": "download produced no file"}), 500

        file_path = os.path.join(tmp_dir, files[0])
        mimetype = "audio/mp4" if ext == "m4a" else "audio/webm"

        # Defer cleanup until AFTER the response has been fully sent
        @after_this_request
        def cleanup(response):
            try:
                os.remove(file_path)
                os.rmdir(tmp_dir)
            except Exception:
                pass
            return response

        return send_file(
            file_path,
            mimetype=mimetype,
            as_attachment=True,
            download_name=f"{title}.{ext}"
        )

    except Exception as e:
        # Clean up immediately on error — no response file to send
        for f in os.listdir(tmp_dir):
            try:
                os.remove(os.path.join(tmp_dir, f))
            except Exception:
                pass
        try:
            os.rmdir(tmp_dir)
        except Exception:
            pass
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
