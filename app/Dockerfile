# --- build stage -----------------------------------------------------------
# Separate build stage keeps the final image free of pip's build cache/wheels.
FROM python:3.12-slim AS build

WORKDIR /app
COPY requirements.txt .
# --user installs into /root/.local so we can copy just that layer forward.
RUN pip install --no-cache-dir --user -r requirements.txt

# --- runtime stage -----------------------------------------------------------
FROM python:3.12-slim

# Run as a non-root user inside the container (defense in depth — the app
# doesn't need root, and AKS/most clusters flag root containers in policy).
RUN useradd --create-home --uid 1000 appuser
WORKDIR /app

COPY --from=build /root/.local /home/appuser/.local
COPY app.py .

ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONUNBUFFERED=1

USER appuser
EXPOSE 8080

# Gunicorn would be more production-grade, but Flask's built-in server keeps
# the demo's moving parts minimal; swap for gunicorn if load-testing matters.
CMD ["python", "app.py"]
