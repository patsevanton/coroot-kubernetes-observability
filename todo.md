# TODO

- [ ] Исследовать «Нюанс Prometheus retention» из README: блоки по 2 часа, поэтому при `prometheus.retention: "1h"` реальные метрики живут до ~3–4 часов. Проверить фактическое поведение retention встроенного Prometheus Coroot (когда именно удаляются блоки при `--storage.tsdb.retention.time=1h`) и при необходимости уточнить формулировку в README.
- [ ] Добавить трейсы (OpenTelemetry) во все 4 демо-приложения (Nuxt, Python, Go, Java) и описать раздел по трейсам в README.md.
