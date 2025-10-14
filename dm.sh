#!/bin/bash

# Script de instalación automática para Dailymotion M3U8 Server
# Uso: bash install.sh

set -e

echo "=================================================="
echo "  Dailymotion M3U8 Server - Instalación Automática"
echo "=================================================="
echo ""

# Verificar si es root
if [ "$EUID" -ne 0 ]; then 
    echo "⚠️  Este script debe ejecutarse como root"
    echo "   Usa: sudo bash install.sh"
    exit 1
fi

# Variables
INSTALL_DIR="/opt/dailymotion-server"

echo "📦 Actualizando sistema..."
apt update && apt upgrade -y

echo ""
echo "📦 Instalando dependencias..."
apt install -y python3 python3-pip python3-venv nginx certbot python3-certbot-nginx

echo ""
echo "📦 Instalando yt-dlp..."
pip3 install --upgrade yt-dlp

echo ""
echo "📁 Creando directorio de instalación..."
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

echo ""
echo "🐍 Creando entorno virtual de Python..."
python3 -m venv venv
source venv/bin/activate

echo ""
echo "📦 Instalando dependencias de Python..."
pip install flask gunicorn yt-dlp

echo ""
echo "📝 Creando archivo del servidor..."
cat > $INSTALL_DIR/server.py << 'EOFPYTHON'
from flask import Flask, Response, redirect, render_template_string, jsonify
import subprocess
from datetime import datetime, timedelta

app = Flask(__name__)

cache = {}

def get_m3u8_with_ytdlp(video_url):
    try:
        print(f"🔍 Extrayendo M3U8 de: {video_url}")
        result = subprocess.check_output(
            ["yt-dlp", "-g", video_url],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=30
        ).strip()
        lines = result.split('\n')
        stream_url = lines[0] if lines else None
        if stream_url:
            print(f"✅ M3U8 obtenido: {stream_url[:80]}...")
            return stream_url
        print("❌ No se obtuvo URL")
        return None
    except Exception as e:
        print(f"❌ Error: {e}")
        return None

def get_cached_url(video_id):
    video_url = f"https://www.dailymotion.com/video/{video_id}"
    now = datetime.now()
    if video_id in cache:
        cached_data = cache[video_id]
        if (now - cached_data['timestamp']) < timedelta(minutes=30):
            print("✅ Usando URL del cache")
            return cached_data['url']
    print("🔄 Obteniendo nueva URL con yt-dlp...")
    url = get_m3u8_with_ytdlp(video_url)
    if url:
        cache[video_id] = {'url': url, 'timestamp': now}
        print("✅ URL guardada en cache")
    return url

@app.route('/')
def index():
    html = """<!DOCTYPE html><html><head><title>Dailymotion M3U8 Server</title>
<style>body{font-family:Arial,sans-serif;max-width:800px;margin:50px auto;padding:20px;background:#f5f5f5}
.container{background:white;padding:30px;border-radius:10px;box-shadow:0 2px 10px rgba(0,0,0,0.1)}
h1{color:#333}.channel{background:#f0f0f0;padding:15px;margin:10px 0;border-radius:5px}
code{background:#e8e8e8;padding:2px 6px;border-radius:3px}</style></head>
<body><div class="container"><h1>🎥 Dailymotion M3U8 Server</h1>
<h2>📺 Canales Disponibles:</h2>
<div class="channel"><h3>CDN en Vivo (x9lincs)</h3>
<p>Stream: <code>/stream/x9lincs</code></p>
<p>Playlist: <code>/playlist/x9lincs.m3u8</code></p></div>
<div class="channel"><h3>CDN Deportes (x9lntl6)</h3>
<p>Stream: <code>/stream/x9lntl6</code></p>
<p>Playlist: <code>/playlist/x9lntl6.m3u8</code></p></div>
<p><strong>Cache:</strong> 30 minutos | <strong>Auto-renovación:</strong> ✅</p>
</div></body></html>"""
    return render_template_string(html)

@app.route('/stream/<video_id>')
def stream(video_id):
    url = get_cached_url(video_id)
    if url:
        return redirect(url)
    return Response("No se pudo obtener el stream", status=404)

@app.route('/get/<video_id>')
def get_url(video_id):
    url = get_cached_url(video_id)
    if url:
        return Response(url, mimetype='text/plain')
    return Response("No se pudo obtener el stream", status=404)

@app.route('/playlist/<video_id>.m3u8')
def playlist(video_id):
    video_id = video_id.replace('.m3u8', '')
    url = get_cached_url(video_id)
    if not url:
        return Response("No se pudo obtener el stream", status=404)
    m3u8_content = f"""#EXTM3U
#EXT-X-VERSION:3
#EXTINF:-1 tvg-id="" tvg-name="Dailymotion {video_id}" tvg-logo="" group-title="Live",Stream
{url}
"""
    return Response(m3u8_content, mimetype='application/vnd.apple.mpegurl')

@app.route('/api/url/<video_id>')
def api_url(video_id):
    url = get_cached_url(video_id)
    if url:
        cached_data = cache.get(video_id, {})
        return jsonify({
            'success': True,
            'video_id': video_id,
            'url': url,
            'cached_at': cached_data.get('timestamp').isoformat() if cached_data.get('timestamp') else None
        })
    return jsonify({'success': False, 'error': 'No se pudo obtener el stream'}), 404

@app.route('/clear-cache')
def clear_cache_route():
    cache.clear()
    return jsonify({'success': True, 'message': 'Cache limpiado'})

if __name__ == '__main__':
    app.run(debug=False, host='0.0.0.0', port=5000)
EOFPYTHON

echo ""
echo "🔧 Creando servicio systemd..."
cat > /etc/systemd/system/dailymotion-stream.service << 'EOFSERVICE'
[Unit]
Description=Dailymotion M3U8 Stream Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/dailymotion-server
Environment="PATH=/opt/dailymotion-server/venv/bin"
ExecStart=/opt/dailymotion-server/venv/bin/gunicorn --bind 0.0.0.0:5000 --workers 2 --timeout 120 server:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSERVICE

echo ""
echo "🔧 Configurando Nginx..."
cat > /etc/nginx/sites-available/dailymotion-stream << 'EOFNGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 300s;
    }
}
EOFNGINX

ln -sf /etc/nginx/sites-available/dailymotion-stream /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t

echo ""
echo "🚀 Iniciando servicios..."
systemctl daemon-reload
systemctl enable dailymotion-stream
systemctl start dailymotion-stream
systemctl restart nginx

echo ""
echo "=================================================="
echo "  ✅ ¡Instalación Completada!"
echo "=================================================="
echo ""
echo "📺 Tus canales están disponibles en:"
echo ""
echo "   CDN en Vivo:"
echo "   http://$(curl -s ifconfig.me)/stream/x9lincs"
echo "   http://$(curl -s ifconfig.me)/playlist/x9lincs.m3u8"
echo ""
echo "   CDN Deportes:"
echo "   http://$(curl -s ifconfig.me)/stream/x9lntl6"
echo "   http://$(curl -s ifconfig.me)/playlist/x9lntl6.m3u8"
echo ""
echo "🔧 Comandos útiles:"
echo "   Ver estado:    systemctl status dailymotion-stream"
echo "   Ver logs:      journalctl -u dailymotion-stream -f"
echo "   Reiniciar:     systemctl restart dailymotion-stream"
echo "   Limpiar cache: curl http://localhost/clear-cache"
echo ""
echo "📝 Para configurar SSL:"
echo "   certbot --nginx -d tu-dominio.com"
echo ""
echo "=================================================="
