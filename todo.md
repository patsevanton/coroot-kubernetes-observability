# TODO

- [ ] Исследовать «Нюанс Prometheus retention» из README: блоки по 2 часа, поэтому при `prometheus.retention: "1h"` реальные метрики живут до ~3–4 часов. Проверить фактическое поведение retention встроенного Prometheus Coroot (когда именно удаляются блоки при `--storage.tsdb.retention.time=1h`) и при необходимости уточнить формулировку в README.
- [x] Добавить трейсы (OpenTelemetry) во все 4 демо-приложения (Nuxt, Python, Go, Java) и описать раздел по трейсам в README.md.
- [ ] Разобраться, почему у Java в Profiling флеймграф показывает `[unknown]` (30 min, 99%): async-profiler подгружается динамически (JVM Attach API), поэтому без debug-информации большинство сэмплов не символизируется. Проверить, реально ли применяются флаги `-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints` из `apps/java/Dockerfile`, и при необходимости найти способ символизации (например, `-XX:+PreserveFramePointer`, либо проверка версии JVM/async-profiler).
- [ ] Поднять OpenTelemetry Collector, отправлять трейсы в него, а оттуда — в Coroot. Пример конфига от разработчиков Coroot:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:

exporters:
  otlphttp/coroot:
    endpoint: "http://coroot.158.160.201.15.sslip.io"
    encoding: proto
    headers:
      "x-api-key": ""

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp/coroot]
    logs:
       receivers: [otlp]
       processors: [batch]
       exporters: [otlphttp/coroot]
```
