FROM python:3.12-slim

WORKDIR /app
COPY server.py http_server.py ./
RUN python -m py_compile server.py http_server.py

ENV PYTHONUNBUFFERED=1
EXPOSE 8000
CMD ["python", "http_server.py"]
