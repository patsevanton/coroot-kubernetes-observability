# Coroot: как eBPF-профилирование, инспекции, логи, трейсы находят проблемы app в k8s

## Введение

Классический мониторинг отвечает на вопрос «*что* сломалось»: метрики показывают рост CPU, логи — стек ошибок, трейсы — медленный сервис. Но когда нужно ответить «*почему* именно этот сервис стал медленным», почти все инструменты пасуют. Вы видите, что контейнер потребляет 2 ядра CPU, но не видите, какая строка кода их загружает.

[Coroot](https://github.com/coroot/coroot) — open-source observability-платформа, которая превращает метрики, логи и трейсы в конкретные, готовые к действию выводы о том, что чинить. Её ключевая особенность — **непрерывное профилирование из коробки**: eBPF-профилировщик снимает CPU-профили всех процессов на ноде без единой строки кода в приложении, а языковые профилировщики (Go, Java) добавляют память и блокировки. Результат — флеймграф до точной строки кода в один клик, плюс предустановленные инспекции, которые автоматически находят типовые проблемы (утечки памяти, лишние аллокации, блокировки).

Coroot ставится в любой Kubernetes-кластер. В этой статье мы развернём Coroot через официальный coroot-operator (Community Edition), а затем задеплоим четыре намеренно «сломанных» приложения — на Nuxt (Node.js), Python, Go и Java — и посмотрим, как их проблемы всплывают в профилировании.

## Coroot vs Pyroscope vs Parca vs Pixie vs Perforator

| Метрика | Coroot (Community Edition) | Grafana Pyroscope | Parca | Pixie | Perforator (Yandex) |
|---------|--------|-------------------|-------|---------------------|---------------------|
| Профилирование | eBPF CPU + Go (heap/pprof) + Java (async-profiler) | языковые SDK, Grafana Alloy, OTLP; eBPF через Alloy/OTel | eBPF + pprof | eBPF-автоинструментация k8s, CPU-профили | eBPF kernel + userspace, CPU, sPGO/AutoFDO |
| Нужны ли изменения кода | Нет (eBPF + Go heap), для CPU/blocking/mutex — опционально pprof | Да — SDK/агент (eBPF только через Alloy/OTel) | Нет (eBPF) | Нет (eBPF) | Нет (eBPF) |
| Метрики + логи + трейсы | ✅ в одном UI | ❌ (только профили) | ❌ (только профили) | ⚠️ (eBPF-метрики, запросы и трейсы) | ❌ (только профили) |
| Автодиагностика (инспекции) | ✅ 80%+ типовых проблем | ❌ | ❌ | ⚠️ (готовые PxL-скрипты) | ❌ |
| SLO-алертинг | ✅ | ❌ | ❌ | ❌ | ❌ |
| Service Map | ✅ | ❌ | ❌ | ⚠️ (по eBPF-трафику) | ❌ |
| Хранилище профилей | ClickHouse | S3-совместимое | object storage | локально в кластере (краткосрочное) | ClickHouse (метаданные профилей) + PostgreSQL (метаданные бинарей) + S3-совместимое (сырые профили) |
| Self-hosted | ✅ | ✅ | ✅ | ✅ | ✅ |

В таблице — только свободные решения: Coroot Community Edition, Grafana Pyroscope, Parca, Pixie и Perforator. Дополнительно к уже рассмотренным выделяются два профилировщика с eBPF-сбором: [Pixie](https://github.com/pixie-io/pixie) — open-source eBPF-автоинструментация для Kubernetes, которая снимает метрики, запросы и CPU-профили без изменений в подах; [Perforator](https://github.com/yandex/perforator) от Yandex — production-ready continuous profiling для больших датацентров (десятки тысяч нод), вдохновлённый Google-Wide Profiling, с размоткой стека без frame pointers/дебаг-символов и генерацией sPGO-профилей для PGO-сборки.

Coroot не пытается быть «ещё одним pprof-интерфейсом» — профили здесь один из сигналов наравне с метриками, логами и трейсами, и все они связаны между собой: от аномалии на графике CPU — в флеймграф, от фрейма — в связанные логи и трейсы.

Отличительные особенности Coroot:

- **Zero-instrumentation** — eBPF снимает CPU-профили всех процессов на ноде без изменений в коде
- **Языковые профилировщики** — Go (heap + pprof: CPU/blocking/mutex), Java (async-profiler: CPU/alloc/lock)
- **Инспекции** — предустановленные проверки аудитируют каждое приложение и находят ~80% типовых проблем без настройки
- **Просмотр в один клик** — флеймграф, сравнение с базовой линией, drill в логи и трейсы

### Два способа профилирования: eBPF и user-space

Coroot собирает профили двумя способами, которые дополняют друг друга: eBPF покрывает CPU для всех процессов на ноде, а языковые профилировщики добирают память и блокировки для конкретных рантаймов.

- **eBPF-профилировщик** — `coroot-node-agent` (DaemonSet на каждой ноде) загружает eBPF-программы в ядро и цепляет их к CPU perf-событиям, снимая CPU-стектрейсы всех процессов без изменений в коде. Затем агент символизирует адреса, ассоциирует стек с контейнером/подом, обрезает незначимые фреймы (всё меньше 0.25% профиля, флаг `--profiles-prune-fraction`) и отправляет профиль в Coroot. Но это всегда только CPU.

- **Языковые профилировщики** — это не плагин и не библиотека в коде приложения, а механизмы внутри агентов Coroot, которые обращаются к чужому процессу снаружи:

  - **Go heap** — `coroot-node-agent` читает структуру `runtime.MemProfile` прямо из памяти процесса (`/proc/<pid>/mem`). В приложение ничего не подключается.
  - **Go pprof** — `coroot-cluster-agent` скрейпит стандартный `/debug/pprof` (CPU/blocking/mutex), который Go-рантайм отдаёт из коробки; его лишь нужно экспортировать в приложении и пометить аннотациями.
  - **Java** — `coroot-node-agent` находит HotSpot JVM и динамически подгружает нативную `libasync-profiler.so` через JVM Attach API (CPU/alloc/lock). Библиотека приходит с агентом, а не с приложением.
  - **Python** — eBPF-инструментирование резолвит Python-фреймы через Pyroscope eBPF-профайлер (`github.com/grafana/pyroscope/ebpf`), который `coroot-node-agent` запускает с включённой Python-инструментацией (`PythonEnabled`).

## Предварительные требования

Для развёртывания демо-окружения понадобятся:

- установленный и настроенный Kubernetes-кластер.
- [kubectl](https://kubernetes.io/docs/tasks/tools/) и [Helm](https://helm.sh/) >= 3;

## Часть 1. Разворачиваем Coroot в Kubernetes

### Архитектура

Coroot в кластере состоит из нескольких компонентов, которые разворачивает **coroot-operator**:

- **coroot** — сам сервер (StatefulSet, 1 реплика): UI, API, инспекции
- **coroot-node-agent** — DaemonSet на каждой ноде: eBPF CPU-профилировщик (плюс Go heap-профайлер, Python-инструментирование и Java через async-profiler), метрики, логи, трейсы
- **coroot-cluster-agent** — Deployment: кластерная телеметрия + pprof-скрейп Go-приложений
- **Prometheus** — хранилище метрик (remote-write receiver включён)
- **ClickHouse** — хранилище логов, трейсов и профилей (+ clickhouse-keeper для координации)

```mermaid
flowchart TB
    Coroot["Coroot<br/>(UI, API, инспекции)"]

    Coroot --> PG[(Prometheus<br/>метрики)]
    Coroot --> CH[(ClickHouse<br/>логи/трейсы/профили)]

    NodeAgent["coroot-node-agent<br/>DaemonSet, eBPF"] -->|"профили: CPU (eBPF)<br/>Go heap, Java async-profiler"| Coroot
    NodeAgent -->|метрики, логи| Coroot
    ClusterAgent["coroot-cluster-agent<br/>pprof-скрейп"] -->|Go-профили| Coroot

    ClusterAgent -->|"скрейп /debug/pprof"| App["demo-приложения"]
    App -->|"OTLP (трейсы)"| OTel["OpenTelemetry Collector"]
    OTel -->|OTLP| Coroot
```

### Шаг 1. Установка Coroot в кластер

Coroot ставится вручную через Helm. Сначала создаём namespace и Secret с паролем администратора:

```bash
kubectl create namespace coroot

kubectl -n coroot create secret generic coroot-admin-secret \
  --from-literal=admin-password=<пароль-админа>
```

Затем создаём `coroot-values.yaml`:

```yaml
metricsRefreshInterval: "30s"

# Retention: все данные Coroot хранятся не дольше 1 часа
cacheTTL: "1h"      # TTL метрического кэша Coroot
tracesTTL: "1h"     # TTL таблиц трейсов в ClickHouse
logsTTL: "1h"       # TTL таблиц логов в ClickHouse
profilesTTL: "1h"   # TTL таблиц профилей в ClickHouse

authBootstrapAdminPasswordSecret:
  name: coroot-admin-secret
  key: admin-password

ingress:
  className: traefik
  host: coroot_url
  path: /

clickhouse:
  shards: 1
  replicas: 1
  keeper:
    replicas: 1
  storage:
    size: "20Gi"

prometheus:
  retention: "1h"
  storage:
    size: "10Gi"

storage:
  size: "10Gi"

# Java-профилирование: node-agent динамически подгружает async-profiler в HotSpot JVM
nodeAgent:
  env:
    - name: ENABLE_JAVA_ASYNC_PROFILER
      value: "true"
```

Устанавливаем оператор и сам Coroot:

```bash
# Оператор Coroot (управляет Coroot CR, node-agent, cluster-agent, Prometheus, ClickHouse)
helm install coroot-operator oci://ghcr.io/coroot/charts/coroot-operator \
  --version 0.9.10 -n coroot

# Coroot CE: чарт рендерит Coroot CR (spec — из coroot-values.yaml)
helm install coroot oci://ghcr.io/coroot/charts/coroot-ce \
  --version 0.3.3 -n coroot -f coroot-values.yaml
```

### Шаг 2. Coroot CR и retention 1 час

Helm-чарт `coroot-ce` рендерит Custom Resource `Coroot`, которым управляет оператор. Что здесь важно:

- **Retention ограничен 1 часом** в трёх местах: TTL таблиц ClickHouse (`logsTTL`/`tracesTTL`/`profilesTTL`), метрический кэш (`cacheTTL`) и retention встроенного Prometheus (`prometheus.retention: "1h"`). TTL применяются при создании таблиц; для уже существующих таблиц их нужно поправить через `ALTER TABLE ... MODIFY TTL`.
- **Java-профилирование** включается флагом `ENABLE_JAVA_ASYNC_PROFILER=true` на node-agent. Java-агент для профилирования не нужен: node-agent сам находит HotSpot JVM и подгружает async-profiler через JVM Attach API. (Java-агент в [apps/java/Dockerfile](apps/java/Dockerfile) — это OpenTelemetry-инструментация для трейсов, к профилированию отношения не имеет.)
- **Нюанс по Prometheus**: данные хранятся двухчасовыми блоками, а retention отсчитывается не от текущего момента, а от `maxTime` самого свежего закрытого блока (`--storage.tsdb.retention.time` сравнивается как `blocks[0].MaxTime - block.MaxTime >= retention`). Поэтому блок удаляется не «через 1 час после записи», а только когда поверх него закрывается следующий блок: итого блок живёт ~2 часа в head до отсечения на 2-часовой границе плюс ещё ~2 часа на диске. При `prometheus.retention: "1h"` фактический горизонт метрик лежит в диапазоне от ~2 до ~4 часов (ближе к 2 — сразу после отсечения блока, ближе к 4 — перед следующим), плюс Coroot держит рядом собственный метрический кэш (`cacheTTL: "1h"`).
- **Пароль администратора** живёт только в Kubernetes Secret `coroot-admin-secret`, а в CR передаётся ссылка на него (`authBootstrapAdminPasswordSecret`) — в git и в Helm-release пароля нет.
- **Keeper — 1 реплика** вместо 3 по умолчанию: для демо-кластера из 3 нод это разумный компромисс (3 реплики keeper'а съели бы всю ноду).

### Шаг 3. Проверяем

```bash
# Переключаем kubectl на контекст вашего кластера
kubectl config use-context <ваш-кластер>

# Ждём готовности подов
kubectl get pods -n coroot -w
```

Должно получиться примерно так:

```
NAME                                 READY   STATUS    RESTARTS   AGE
coroot-coroot-0                      1/1     Running   0          5m
coroot-clickhouse-shard-0-0          1/1     Running   0          5m
coroot-clickhouse-keeper-0           1/1     Running   0          5m
coroot-prometheus-xxx-yyy            1/1     Running   0          5m
coroot-node-agent-abc12              1/1     Running   0          5m
coroot-node-agent-def34              1/1     Running   0          5m
coroot-node-agent-ghi56              1/1     Running   0          5m
coroot-cluster-agent-xxx-yyy         1/1     Running   0          5m
coroot-operator-xxx-yyy              1/1     Running   0          5m
```

Открываем UI:

Входим с логином `admin` и паролем администратора (`coroot_admin_password`). Оператор уже сконфигурировал Prometheus и ClickHouse и создал проект `default`, поэтому ничего настраивать не нужно — сразу переходим к приложениям.

## Часть 2. Четыре «сломанных» приложения

Чтобы продемонстрировать профилирование, задеплоим четыре приложения с намеренно внесёнными проблемами. Исходники — в каталоге [apps](apps), деплой — Helm-чартом [chart](chart).

### Шаг 1. OpenTelemetry Collector

Скорее всего, у вас уже установлен **OpenTelemetry Collector**, поэтому конфигурируем отправку трейсов через него — он принимает трейсы от всех четырёх приложений по OTLP/HTTP (порт `4318`), батчит их и пересылает в Coroot. Конфигурация — в [otel-collector-values.yaml](otel-collector-values.yaml) в корне репозитория (используется `alternateConfig` чарта `open-telemetry/opentelemetry-collector`, чтобы оставить только HTTP-ресивер трейсов без jaeger/zipkin/prometheus-ресиверов):

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm install otel-collector open-telemetry/opentelemetry-collector \
  --version 0.173.1 -n otel --create-namespace -f otel-collector-values.yaml
```

Коллектор слушает OTLP/HTTP на `4318` в namespace `otel`. Приложения обращаются к нему по адресу `http://otel-collector.otel:4318/v1/traces`, а сам коллектор пересылает батчи в Coroot на внутренний сервис `coroot-coroot.coroot:8080`.

### Шаг 2. Четыре приложения

Образы собираются в CI ([.github/workflows/docker.yml](.github/workflows/docker.yml)) из исходников в [apps](apps) и публикуются в GitHub Container Registry с тегом версии (`ghcr.io/patsevanton/coroot-kubernetes-observability/<app>:<version>`), чарт ссылается на конкретную версию через `imageRegistry` и `image.tag` в [chart/values.yaml](chart/values.yaml). Исходники Helm-чарта — в каталоге [chart](chart). Все четыре приложения поднимаются одной установкой чарта:

```bash
helm install demo ./chart --namespace demo --create-namespace
```

При необходимости приложения включаются по отдельности флагами `--set golang.enabled=false`, `--set java.enabled=false` и т.д. — по умолчанию включены все четыре.

Вместе с приложениями чарт поднимает **генераторы нагрузки** — по одному Kubernetes Job на каждое включённое приложение (`load-nuxt`, `load-python`, `load-golang`, `load-java`). Job'ы в бесконечном цикле дёргают проблемные эндпоинты приложения (`curl ... > /dev/null`), поэтому под Job'а всё время `Running`, а нагрузка идёт непрерывно. Пути запросов задаются в `load.paths` блока каждого приложения в [chart/values.yaml](chart/values.yaml), а сам генератор отключается флагом `--set load.enabled=false`:

```bash
kubectl get jobs -n demo
```

### Демо 1: Nuxt (Node.js) — CPU-bound

Приложение на Nuxt 3 с единственным API-эндпоинтом `/api/cpu`, который считает наивный Фибоначчи (`fib(35)` — ~30 млн рекурсивных вызовов). Экспоненциальная сложность мгновенно видна в CPU-профиле.

Ключевой момент — **символизация JS-фреймов**. eBPF-профилировщик снимает нативные стектрейсы, но без perf-map названия JS-функций не резолвятся. Node.js умеет генерировать perf-map сам, если запустить его с флагами:

```yaml
env:
  - name: NODE_OPTIONS
    value: "--perf-basic-prof-only-functions --interpreted-frames-native-stack"
```

С этими флагами во флеймграфе будут реальные имена функций `fib`/`fib`, а не анонимные адреса.

Минимальная рабочая версия — **18.19+ / 20.10+ / 21.1+**.

**Трейсы** подключаются через OpenTelemetry: Nitro-плагин [server/plugins/otel.ts](apps/nuxt/server/plugins/otel.ts) запускает `NodeSDK` с `HttpInstrumentation`, который на каждый запрос создаёт server-span, а в обработчике добавляется вложенный span `fib`. Экспорт — в OpenTelemetry Collector через OTLP (`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` в [chart/values.yaml](chart/values.yaml)).

Нагрузку создаёт Job `load-nuxt`, который непрерывно вызывает `/api/cpu` (см. раздел выше).

### Демо 2: Python

Python-приложение на стандартном `http.server` с эндпоинтом `/cpu`: наивный `fib(30)` плюс busy-loop с `math.sqrt`. eBPF-профилировщик Coroot снимает CPU-профиль Python-процесса без каких-либо агентов и изменений кода, а пи-профайлер резолвит Python-фреймы, так что во флеймграфе виден именно `naive_fib`.

**Трейсы** — автоинструментация OpenTelemetry: приложение запускается через `opentelemetry-instrument` (см. [apps/python/Dockerfile](apps/python/Dockerfile)), который сам инструментирует `http.server` и экспортирует server-span'ы в OpenTelemetry Collector через OTLP. В [apps/python/app.py](apps/python/app.py) обработчик дополнительно оборачивается во вложенный span через `trace.get_tracer(...)`.

Нагрузку создаёт Job `load-python`, который непрерывно вызывает `/cpu`.

**Флеймграф CPU** — открываем приложение `demo-python` → вкладка **Profiling**. Агрегированный флеймграф за выбранный интервал покажет, что почти всё CPU уходит в `naive_fib` — рекурсию с экспоненциальной сложностью. То же для `demo-nuxt`, где благодаря perf-map виден именно `fib` в JS.

Режим **Comparison** подсветит красным функции, которые стали есть больше CPU относительно прошлого интервала — удобно ловить регрессии после релиза.

### Демо 3: Golang

Go-приложение с тремя проблемами сразу:

- **утечка памяти** — фоновый цикл каждую секунду добавляет 1 MiB в слайс, который никогда не освобождается (при лимите 2 GiB под доходит до OOM примерно за 30 минут)
- **утечка горутин** — эндпоинт `/leak` запускает горутину, которая блокируется навсегда
- **CPU-нагрузка** — эндпоинт `/cpu` с бесполезным циклом на 5 млн итераций

Для Go Coroot использует **два комплементарных механизма**: автоматический heap-профилинг через `coroot-node-agent` (читает `runtime.MemProfile` из `/proc/<pid>/mem`, без изменений в коде; управляется флагом `--go-heap-profiler` = `disabled`/`enabled`/`force`) и pprof-скрейп через `coroot-cluster-agent`. Чтобы включить pprof-скрейп (CPU/blocking/mutex), нужно экспортировать `/debug/pprof` и аннотировать под — в чарте это уже сделано через `golang.podAnnotations` в [chart/values.yaml](chart/values.yaml):

```yaml
golang:
  podAnnotations:
    coroot.com/profile-scrape: "true"
    coroot.com/profile-port: "8080"
```

Сам код подключает `net/http/pprof` одной строкой:

```go
import _ "net/http/pprof"
```

**Трейсы** — ручное инструментирование OpenTelemetry (автоинструментации для Go в Coroot нет): маршрутизатор оборачивается в `otelhttp.NewHandler`, а OTLP-экспортер настраивается в [apps/golang/main.go](apps/golang/main.go) из переменных окружения и шлёт спаны в OpenTelemetry Collector. Каждый входящий запрос на `/cpu` и `/leak` становится трейсом в Coroot. Обратите внимание: зависимости OpenTelemetry требуют Go **1.25+**, поэтому образ собирается на `golang:1.25-alpine` (см. [apps/golang/Dockerfile](apps/golang/Dockerfile) и [apps/golang/go.mod](apps/golang/go.mod)).

Нагрузку создаёт Job `load-golang`, который по кругу вызывает `/leak` и `/cpu`.

Memory-профиль показывает устойчивый рост `alloc_space`: куча растёт на ~1 MiB/сек за счёт фонового `growLeak`. Флеймграф memory-профиля указывает точное место — `main.growLeak`, где происходит `append` в `leakBuf`.

Горутины-утечки видны косвенно: число горутин растёт (`/healthz` отдаёт `runtime.NumGoroutine()`), а Coroot связывает это с ростом потребления и деградацией SLO.

### Демо 4: Java

Java-приложение на встроенном `com.sun.net.httpserver` с тремя эндпоинтами:

- **`/cpu`** — наивный `fib(35)` плюс цикл на 5 млн итераций
- **`/alloc`** — фоновая аллокация массивов (видна в Memory-профиле как `alloc_space`/`alloc_objects`)
- **`/lock`** — два потока намеренно конкурируют за один монитор (`synchronized` + `sleep`), создавая Lock-профиль

Для Java-профилирования Coroot не требуется ни Java-агент, ни изменения в коде: `coroot-node-agent` находит HotSpot JVM по `libjvm.so` в `/proc/<pid>/maps` и динамически подгружает `libasync-profiler.so` через JVM Attach API. Единственное, что нужно, — включить флаг на node-agent (это уже сделано в [coroot.tf](coroot.tf)):

```yaml
nodeAgent:
  env:
    - name: ENABLE_JAVA_ASYNC_PROFILER
      value: "true"
```

JVM-флаги для профилирования **не обязательны**, но желательны: async-profiler подгружается в JVM **динамически** (через JVM Attach API), а не через `-agentpath` на старте, поэтому часть JIT-скомпилированного до attach кода не имеет debug-информации в точках сэмплирования, из-за чего часть сэмплов во флеймграфе попадает в `[unknown]`. Чтобы минимизировать потери, приложение запускается с флагами (см. [apps/java/Dockerfile](apps/java/Dockerfile)):

```
-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints -XX:+PreserveFramePointer
```

`-XX:+DebugNonSafepoints` заставляет JIT сохранять debug-информацию и в несейфпоинтах — без него инлайнируемые методы могут вообще не попадать в профиль. `-XX:+PreserveFramePointer` сохраняет регистр frame pointer, что дополнительно улучшает резолв нативных/вызывающих фреймов (полезно и для eBPF-профилировщика). Полностью убрать `[unknown]` всё равно нельзя: на горячих методах (в демо — `naiveFib`), скомпилированных до подключения агента, дебаг-инфо появляется лишь после перекомпиляции.

**Трейсы** — автоматическая инструментация через OpenTelemetry Java-агент: в [apps/java/Dockerfile](apps/java/Dockerfile) jar скачивается и подключается флагом `-javaagent`, так что менять код не нужно — спаны HTTP-запросов генерируются автоматически и уходят в OpenTelemetry Collector через OTLP.

Нагрузку создаёт Job `load-java`, который по кругу вызывает `/cpu`, `/alloc` и `/lock`.

Для `demo-java` Coroot показывает сразу несколько типов профилей из async-profiler:

- **CPU** — почти всё время в `naiveFib` (рекурсия с экспоненциальной сложностью), как и у Python/Node.js, но с нативными Java-фреймами
- **Memory** — рост `alloc_space`/`alloc_objects` по стеку аллокаций в `DemoJava.allocate`
- **Lock** — время ожидания монитора (`delay`) и число контеншенов (`contentions`) на `synchronized`-блоке

Рядом с профилями async-profiler экспортирует одноимённые метрики (`container_jvm_alloc_bytes_total`, `container_jvm_lock_contentions_total`, `container_jvm_profiling_status` и др.) — по ним удобно ловить аномалии на графике и проваливаться в флеймграф.

## Часть 3. Что видно в Coroot

### Инспекции

Помимо профилей, предустановленные инспекции Coroot автоматически подсветят проблемы: постоянный рост потребления памяти, высокую утилизацию CPU одним подом, отсутствие лимитов и т.д. Инспекции — это и есть «встроенная экспертиза», которая находит типовые проблемы без ручной настройки дашбордов.

#### Что означает CPU shortage

В колонке **CPU** на странице приложения Coroot показывает **shortage** — недостаток процессорного времени: сколько времени процессы ждали CPU, но не получали его. Метрика — `container_resources_cpu_delay_seconds_total` (Linux delay accounting). Например, delay 500ms/сек означает, что к каждой секунде обработки запросов добавляется 500ms задержки.

### Трейсы

Все четыре демо-приложения инструментированы OpenTelemetry и отправляют трейсы по OTLP over HTTP в **OpenTelemetry Collector**, который батчит их и пересылает в Coroot. Коллектор принимает OTLP на сервисе `otel-collector.otel` по порту `4318`, а в Coroot трейсы уходят на внутренний сервис `coroot-coroot.coroot:8080` по пути `/v1/traces`.

| Приложение | Способ инструментирования | Что в трейсе |
|---|---|---|
| Go | ручной SDK: `otelhttp.NewHandler` поверх маршрутизатора | server-span на каждый запрос `/cpu`/`/leak` |
| Python | автоинструментация `opentelemetry-instrument` (`http.server`) + вложенный span в обработчике | server-span + span `/cpu` |
| Java | автоинструментация через `-javaagent:opentelemetry-javaagent.jar` | server-span на каждый запрос без изменений кода |
| Nuxt (Node.js) | `NodeSDK` + `HttpInstrumentation` в Nitro-плагине + вложенный span `fib` | server-span + span `fib` |

Общая схема для всех четырёх языков одинакова: приложение экспортирует OTLP-спаны в коллектор, тот пересылает их в Coroot, а Coroot пишет их в ClickHouse (таблица трейсов живёт `tracesTTL: "1h"`) и строит из них Service Map, латентность и drill-down от спана — в логи и профили.

Как это выглядит в UI: выберите приложение → вкладка **Tracing**. Coroot показывает HeatMap распределения запросов по времени, статусам и длительности:

Свободной фильтрации трасс по атрибутам в Coroot нет — фильтрация выполняется выделением области на HeatMap:

- **Ось X (время)** задаёт `tsRange`, **ось Y (длительность)** — `durRange`, а **статус** — метка `err` внутри `durRange`.
- **«Show error traces»** фильтрует по `StatusCode='STATUS_CODE_ERROR'`.
- **«Show latency SLO violations»** фильтрует по `Duration >= SLO objective`.
- **Источник** трасс (OpenTelemetry vs eBPF) переключается селектором `sources`.

- **Ошибки** — выделите область на графике, и Coroot проанализирует *все* попавшие туда трассы, найдя конкретные спаны, где ошибка возникла.
- **Медленные запросы** — в режиме сравнения Coroot подсветит красным операции, которые стали занимать больше времени, чем раньше; это удобно для ловли регрессий после релиза.
- **Сравнение атрибутов** — Coroot автоматически найдёт, чем запросы из аномалии отличаются от остальных (по любым кастомным атрибутам спанов, без настройки).

Связь с профилированием двусторонняя: от аномалии на графике CPU (например, `naive_fib` у `demo-python`) можно провалиться во флеймграф, а из медленного span'а — в связанные логи и профили.

### Отправка алертов

Помимо отображения алертов в UI, Coroot умеет отправлять их наружу. Настройка — в **Project Settings → Integrations**: Slack, Microsoft Teams, PagerDuty, Opsgenie, а также произвольный webhook. Маршрутизация — по [категориям приложений](https://docs.coroot.com/configuration/application-categories#notification-routing): для каждой категории независимо включаются интеграции под три типа событий — **Incidents** (нарушения SLO), **Deployments** и **Alerts** (check-, log-, Kubernetes events- и PromQL-алерты). Например, алерты для категории `production` можно слать в Slack и PagerDuty, а `staging` — только в Slack-канал.

Сами алерты Coroot строит из четырёх источников: встроенные инспекции (check-based), новые паттерны ошибок в логах, предупреждающие Kubernetes-события и кастомные PromQL-правила — так что для наших «сломанных» приложений уведомления появятся без единого правила вручную (утечка памяти, высокая утилизация CPU и т.д.).

## Масштабирование и обновление

### Компоненты

Оператор автоматически обновляет компоненты Coroot, пока версии образов не зафиксированы в Coroot CR. Сам оператор обновляется отдельно:

```bash
helm upgrade -n coroot coroot-operator oci://ghcr.io/coroot/charts/coroot-operator
```

### Реплики и ClickHouse

Для продакшена имеет смысл `clickhouse.shards/replicas: 2` и `keeper.replicas: 3` (по умолчанию), а также несколько реплик Coroot (`replicas: 2`), для чего потребуется вынести конфигурацию из SQLite в PostgreSQL (`postgres.*` в CR). В демо-конфигурации всё однократно ради экономии ресурсов.

## Заключение

Coroot закрывает главный пробел классического мониторинга — вопрос «*почему* медленно». Непрерывное eBPF-профилирование снимает CPU-профили без единой строки кода, языковые профилировщики добавляют память и блокировки, а предустановленные инспекции автоматически находят типовые проблемы. Всё это — с метриками, логами и трейсами в одном UI.

Ключевые преимущества:

- **Zero-instrumentation** — eBPF снимает CPU-профили всех процессов без изменений в коде
- **Флеймграф до строки кода** — CPU и память в один клик, сравнение с базовой линией
- **Встроенная экспертиза** — инспекции находят ~80% типовых проблем автоматически
- **Все сигналы в одном месте** — метрики, логи, трейсы и профили связаны между собой
- **Простота развёртывания** — один Helm-чарт coroot-operator управляет всем стеком

Полезные ссылки:

- GitHub: [github.com/coroot/coroot](https://github.com/coroot/coroot)
- Документация: [docs.coroot.com](https://docs.coroot.com/)
- Helm-чарты (OCI): [ghcr.io/coroot/charts](https://github.com/coroot/coroot-operator/pkgs/container/charts%2Fcoroot-operator)
- Operator: [github.com/coroot/coroot-operator](https://github.com/coroot/coroot-operator)
- Live demo: [demo.coroot.com](https://demo.coroot.com/)
