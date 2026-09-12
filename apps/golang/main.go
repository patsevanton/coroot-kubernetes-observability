// demo-service — намеренно «проблемное» Go-приложение для демонстрации
// профилирования и трейсинга в Coroot. Содержит:
//   - утечку памяти: слайс байтов, который растёт без ограничения
//   - утечку горутин: каждый запрос порождает горутину, которая не завершается
//   - CPU-нагрузку в обработчике (наивные вычисления)
//   - экспорт трейсов в Coroot через OpenTelemetry (OTLP)
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

var (
	// leakBuf — буфер, который только растёт: классическая утечка памяти
	leakBuf  []byte
	leakLock sync.Mutex

	// bgJobs — «забытые» горутины: каждая создаёт тикер и никогда не останавливается
	bgJobs sync.WaitGroup
)

// initTracer настраивает OTLP-экспортер трейсов в Coroot.
// Endpoint и service.name берутся из переменных окружения
// (OTEL_EXPORTER_OTLP_TRACES_ENDPOINT, OTEL_SERVICE_NAME и т.д.).
func initTracer() *sdktrace.TracerProvider {
	ctx := context.Background()

	// otlptracehttp.NewClient() читает конфигурацию из env
	// (OTEL_EXPORTER_OTLP_TRACES_ENDPOINT, OTEL_EXPORTER_OTLP_TRACES_PROTOCOL и др.)
	exporter, err := otlptrace.New(ctx, otlptracehttp.NewClient())
	if err != nil {
		log.Printf("warning: failed to initialize OTLP trace exporter: %v", err)
		return sdktrace.NewTracerProvider()
	}

	// service.name резолвится из OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES
	res, err := resource.New(ctx,
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
	)
	if err != nil {
		log.Printf("warning: failed to build OTel resource: %v", err)
		res = resource.Default()
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))
	return tp
}

// spawnLeakyGoroutine запускает горутину, которая никогда не завершится.
func spawnLeakyGoroutine() {
	go func() {
		for {
			// Гортим работаем вечно: утекающая горутина с тикером
			t := time.NewTicker(1 * time.Second)
			defer t.Stop()
			select {} // блокируемся навсегда
		}
	}()
}

// growLeak добавляет блок памяти, который никогда не освобождается.
func growLeak() {
	leakLock.Lock()
	defer leakLock.Unlock()
	// 1 MiB за вызов, без освобождения — куча растёт линейно
	leakBuf = append(leakBuf, make([]byte, 1024*1024)...)
}

// cpuBurn тратит CPU на бесполезные вычисления (видно в CPU-профиле).
func cpuBurn() {
	_ = 0
	for i := 0; i < 5_000_000; i++ {
		_ = i * i
	}
}

func leakHandler(w http.ResponseWriter, r *http.Request) {
	spawnLeakyGoroutine()
	fmt.Fprintf(w, "leaked: buffer=%d bytes, goroutines=%d\n", len(leakBuf), runtime.NumGoroutine())
}

func cpuHandler(w http.ResponseWriter, r *http.Request) {
	cpuBurn()
	fmt.Fprintf(w, "burned cpu, goroutines=%d\n", runtime.NumGoroutine())
}

func main() {
	tp := initTracer()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tp.Shutdown(ctx)
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/leak", leakHandler)
	mux.HandleFunc("/cpu", cpuHandler)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "ok, goroutines=%d\n", runtime.NumGoroutine())
	})

	// Оборачиваем маршрутизатор в otelhttp — каждый входящий запрос получает server-span
	// и экспортируется в Coroot как трейс.
	var handler http.Handler = mux
	handler = otelhttp.NewHandler(handler, "http-server")

	fmt.Println("demo-service listening on :8080")
	// background "фоновая" нагрузка, чтобы проблема была видна и без внешних запросов
	go func() {
		for {
			growLeak()
			time.Sleep(1 * time.Second)
		}
	}()

	// Плавное завершение: flush трейсов при SIGTERM/SIGINT
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		<-sig
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tp.Shutdown(ctx)
		os.Exit(0)
	}()

	if err := http.ListenAndServe(":8080", handler); err != nil {
		panic(err)
	}
}
