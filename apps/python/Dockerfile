FROM python:3.12-slim
WORKDIR /app
COPY --from=ghcr.io/astral-sh/uv:0.12.13 /uv /uvx /bin/
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-install-project
COPY app.py ./
# opentelemetry-instrument кладётся в .venv при uv sync
ENV PATH="/app/.venv/bin:$PATH"
EXPOSE 8080
CMD ["opentelemetry-instrument", "--traces_exporter", "otlp_proto_http", "--metrics_exporter", "none", "--logs_exporter", "none", "python", "app.py"]