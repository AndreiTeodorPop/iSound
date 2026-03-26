from flask import Flask, request, jsonify, send_file
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

    # Use a temp directory so concurrent downloads don't collide
    tmp_dir = tempfile.mkdtemp()
    output_template = os.path.join(tmp_dir, "%(title)s.%(ext)s")

    opts = {
        "quiet": True,
        # Download best audio and convert to m4a so iOS can play it natively
        "format": "bestaudio[ext=m4a]/bestaudio/best",
        "outtmpl": output_template,
        "postprocessors": [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "m4a",
            "preferredquality": "192",
        }],
        # Keep the file after post-processing
        "keepvideo": False,
    }

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(
                f"https://www.youtube.com/watch?v={video_id}",
                download=True
            )
            title = info.get("title", video_id)

        # Find the downloaded file (yt_dlp may adjust the extension)
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
        # Clean up temp files after response is sent
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
    app.run(host="0.0.0.0", port=8080)
