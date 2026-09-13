FROM python:3.12-slim

WORKDIR /app
COPY server.py http_server.py ./

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN pip install --no-cache-dir "python-socketio[client]>=5.11,<6" \
    && python -m py_compile server.py http_server.py

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).read()" || exit 1

CMD ["python", "http_server.py"]
