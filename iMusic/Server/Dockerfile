# Use slim Python 3.11
FROM python:3.11-slim

# Install ffmpeg and Node.js (required by yt-dlp for YouTube signature/n-challenge solving).
# Debian installs the binary as "nodejs"; yt-dlp looks for "node" — symlink bridges the gap.
RUN apt-get update && apt-get install -y ffmpeg nodejs npm && \
    ln -sf /usr/bin/nodejs /usr/local/bin/node && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Install Node dependencies before copying the rest (layer cache).
COPY generate_pot.js package.json* ./
RUN npm install --omit=dev 2>/dev/null || npm install

# Copy project files
COPY . .

# Install Python dependencies.
# yt-dlp is upgraded to the absolute latest AFTER requirements.txt so Docker layer
# caching never leaves an outdated yt-dlp (YouTube breaks old versions quickly).
RUN pip install --no-cache-dir --quiet --root-user-action=ignore --upgrade pip && \
    pip install --no-cache-dir --quiet --root-user-action=ignore -r requirements.txt && \
    pip install --no-cache-dir --quiet --root-user-action=ignore --upgrade yt-dlp

# Persistent yt-dlp cache (stores the YouTube JS player so signature solving
# works without re-downloading on every container restart).
# Mount this as a volume: -v yt-dlp-cache:/app/yt-dlp-cache
RUN mkdir -p /app/yt-dlp-cache

ENV PORT=8080
ENV WORKERS=1

RUN chmod +x /app/start.sh

CMD ["/app/start.sh"]
