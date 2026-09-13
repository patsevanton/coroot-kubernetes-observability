# TODO

- Посмотреть ещё профилировщики (дополнительно к Coroot, Pyroscope, Parca, Datadog Continuous Profiler).

- [x] Разобраться с Java `[unknown]`: флаги `-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints` реально применяются, async-profiler подгружается (`/tmp/coroot/libasyncProfiler.so`, JFR пишется), JVM Temurin 21 HotSpot. Остаточный `[unknown]` — следствие runtime-attach (горячий `naiveFib` скомпилирован до attach). Добавлен `-XX:+PreserveFramePointer` в `apps/java/Dockerfile`, README уточнён.
- [x] Разобраться с фильтрацией трейсов в Coroot: свободной фильтрации по аттрибутам нет; фильтрация — выделением области на HeatMap (время по X → `tsRange`, длительность по Y → `durRange`, статус — метка `err` в `durRange`). Кнопки «Show error traces» (`StatusCode='STATUS_CODE_ERROR'`) и «Show latency SLO violations» (`Duration >= SLO objective`). Источник (OpenTelemetry vs eBPF) — переключатель `sources`.
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
