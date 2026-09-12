"""demo-service — намеренно «проблемное» Python-приложение для демонстрации
профилирования и трейсинга в Coroot.

Проблема: CPU-bound обработчик — наивная рекурсия + busy-loop.
Трейсинг: OpenTelemetry. SDK и экспорт конфигурирует `opentelemetry-instrument`
(см. Dockerfile) из переменных окружения OTEL_* — endpoint OTLP
(OTEL_EXPORTER_OTLP_TRACES_ENDPOINT) и имя сервиса (OTEL_SERVICE_NAME) задаются
в Helm-чарте. Здесь только создаём вложенные spans поверх server-span'ов.
"""
import math
from http.server import BaseHTTPRequestHandler, HTTPServer

from opentelemetry import trace

tracer = trace.get_tracer("demo-python")


def naive_fib(n: int) -> int:
    """Наивный рекурсивный Фибоначчи: экспоненциальная сложность — видно в CPU-профиле."""
    if n < 2:
        return n
    return naive_fib(n - 1) + naive_fib(n - 2)


def cpu_burn() -> int:
    """Намеренно бесполезная CPU-работа: рекурсия + цикл с плавающей точкой."""
    total = 0
    total += naive_fib(30)  # ~1.6 млн рекурсивных вызовов
    for i in range(2_000_000):
        total += int(math.sqrt(i))
    return total


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with tracer.start_as_current_span(self.path):
            if self.path == "/cpu":
                n = cpu_burn()
                body = f"burned cpu: {n}\n".encode()
            elif self.path == "/healthz":
                body = b"ok\n"
            else:
                self.send_response(404)
                self.end_headers()
                return

            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    print("demo-service listening on :8080")
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
