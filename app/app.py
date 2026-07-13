"""
Minimal Flask to-do app used as the demo workload for the AKS + TrueWatch
interview demo. Intentionally simple (in-memory storage, no DB) so the
project's complexity lives in the infra/observability layers, not the app.
"""
import logging
import os
import uuid

from flask import Flask, jsonify, render_template, request

# --- OpenTelemetry setup -----------------------------------------------
# We configure the SDK by hand (instead of `opentelemetry-instrument`) so the
# exporter target is explicit and easy to point at whatever OTLP endpoint the
# DataKit DaemonSet exposes on each node.
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
    OTLPSpanExporter,
)
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# DataKit's OTLP HTTP receiver defaults to port 9529 on the DaemonSet pod.
# HOST_IP is injected via the Kubernetes downward API (see k8s/deployment.yaml)
# so each app pod talks to the DataKit instance running on its own node,
# avoiding an extra network hop across nodes.
HOST_IP = os.environ.get("HOST_IP", "localhost")
OTLP_ENDPOINT = os.environ.get(
    "OTEL_EXPORTER_OTLP_ENDPOINT", f"http://{HOST_IP}:9529"
)
SERVICE_NAME = os.environ.get("OTEL_SERVICE_NAME", "todo-app")

resource = Resource.create({"service.name": SERVICE_NAME})
provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(endpoint=f"{OTLP_ENDPOINT}/v1/traces")
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

# --- In-memory data store ------------------------------------------------
# No database on purpose: this demo's point is the surrounding infra
# (AKS, Terraform, CI/CD, observability), not data durability. Restarting
# the pod clears the list, which is fine for a demo.
todos: dict[str, dict] = {}


@app.get("/healthz")
def healthz():
    """Liveness/readiness probe target."""
    return jsonify(status="ok"), 200


@app.get("/api/todos")
def list_todos():
    return jsonify(list(todos.values())), 200


@app.post("/api/todos")
def create_todo():
    body = request.get_json(silent=True) or {}
    title = body.get("title", "").strip()
    if not title:
        return jsonify(error="title is required"), 400

    todo_id = str(uuid.uuid4())
    todo = {"id": todo_id, "title": title, "done": False}
    todos[todo_id] = todo
    log.info("created todo %s", todo_id)
    return jsonify(todo), 201


@app.put("/api/todos/<todo_id>")
def update_todo(todo_id):
    todo = todos.get(todo_id)
    if not todo:
        return jsonify(error="not found"), 404

    body = request.get_json(silent=True) or {}
    if "title" in body:
        todo["title"] = body["title"]
    if "done" in body:
        todo["done"] = bool(body["done"])
    return jsonify(todo), 200


@app.delete("/api/todos/<todo_id>")
def delete_todo(todo_id):
    if todos.pop(todo_id, None) is None:
        return jsonify(error="not found"), 404
    return "", 204


@app.get("/")
def index():
    return render_template("index.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
