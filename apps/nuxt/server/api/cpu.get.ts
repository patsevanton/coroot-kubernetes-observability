// CPU-bound обработчик: наивный Фибоначчи (экспоненциальная сложность).
// Виден в eBPF CPU-профиле Coroot при включённой символизации Node.js
// (флаги --perf-basic-prof-only-functions --interpreted-frames-native-stack).
// Трейсы: server-span создаёт HttpInstrumentation (server/plugins/otel.ts),
// а здесь добавляем вложенный span на само вычисление.
import { trace } from '@opentelemetry/api'

function fib(n: number): number {
  if (n < 2) return n
  return fib(n - 1) + fib(n - 2)
}

export default defineEventHandler(() => {
  const span = trace.getTracer('demo-nuxt').startSpan('fib')
  const result = fib(35) // ~18 млн вызовов — заметная CPU-нагрузка
  span.end()
  return { fibonacci: result }
})
