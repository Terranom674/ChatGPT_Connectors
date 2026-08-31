FROM python:3.12-slim

WORKDIR /app
COPY operations.py management_surface.py server.py http_server.py ./

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN python -m py_compile operations.py management_surface.py server.py http_server.py \
 && python -c "import management_surface as m, server; assert not (m.REQUIRED_MANAGEMENT_TOOLS - set(m.OPERATION_BY_NAME)); assert len(server.TOOLS) >= len(m.REQUIRED_MANAGEMENT_TOOLS); print('Manifold management tools:', len(server.TOOLS))"

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).read()" || exit 1

CMD ["python", "http_server.py"]
