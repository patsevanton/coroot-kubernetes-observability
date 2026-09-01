// CPU-bound обработчик: наивный Фибоначчи (экспоненциальная сложность).
// Виден в eBPF CPU-профиле Coroot при включённой символизации Node.js
// (флаги --perf-basic-prof-only-functions --interpreted-frames-native-stack).

function fib(n: number): number {
  if (n < 2) return n
  return fib(n - 1) + fib(n - 2)
}

export default defineEventHandler(() => {
  const n = fib(35) // ~18 млн вызовов — заметная CPU-нагрузка
  return { fibonacci: n }
})
