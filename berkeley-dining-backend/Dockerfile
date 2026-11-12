# CalSwipes API image for Google Cloud Run (also runs locally with docker compose).
# Cloud Run tells the container which port to listen on through $PORT (default 8080).
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /service
COPY requirements.lock .
RUN pip install --no-cache-dir -r requirements.lock

COPY app ./app
COPY migrations ./migrations
COPY alembic.ini .

RUN useradd --create-home service
USER service
EXPOSE 8080

# Shell form so ${PORT} is expanded; exec so uvicorn gets SIGTERM directly from Cloud Run.
CMD exec uvicorn app.main:create_app --factory --host 0.0.0.0 --port ${PORT} --proxy-headers --forwarded-allow-ips='*'
