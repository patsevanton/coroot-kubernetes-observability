// demo-service — намеренно «проблемное» Go-приложение для демонстрации
// профилирования в Coroot. Содержит:
//   - утечку памяти: слайс байтов, который растёт без ограничения
//   - утечку горутин: каждый запрос порождает горутину, которая не завершается
//   - CPU-нагрузку в обработчике (наивные вычисления)
package main

import (
	"fmt"
	"net/http"
	_ "net/http/pprof"
	"runtime"
	"sync"
	"time"
)

var (
	// leakBuf — буфер, который только растёт: классическая утечка памяти
	leakBuf  []byte
	leakLock sync.Mutex

	// bgJobs — «забытые» горутины: каждая создаёт тикер и никогда не останавливается
	bgJobs sync.WaitGroup
)

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
	growLeak()
	spawnLeakyGoroutine()
	fmt.Fprintf(w, "leaked: buffer=%d bytes, goroutines=%d\n", len(leakBuf), runtime.NumGoroutine())
}

func cpuHandler(w http.ResponseWriter, r *http.Request) {
	cpuBurn()
	fmt.Fprintf(w, "burned cpu, goroutines=%d\n", runtime.NumGoroutine())
}

func main() {
	http.HandleFunc("/leak", leakHandler)
	http.HandleFunc("/cpu", cpuHandler)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "ok, goroutines=%d\n", runtime.NumGoroutine())
	})

	fmt.Println("demo-service listening on :8080")
	// background "фоновая" нагрузка, чтобы проблема была видна и без внешних запросов
	go func() {
		for {
			growLeak()
			time.Sleep(500 * time.Millisecond)
		}
	}()

	if err := http.ListenAndServe(":8080", nil); err != nil {
		panic(err)
	}
}
