// OpenTelemetry tracing для Nitro-сервера Nuxt.
// SDK стартует на этапе инициализации Nitro-плагина (до обработки запросов):
//   - HttpInstrumentation автоматически создаёт server-span на каждый HTTP-запрос;
//   - endpoint и service.name читаются из переменных окружения
//     OTEL_EXPORTER_OTLP_TRACES_ENDPOINT / OTEL_SERVICE_NAME.
import { NodeSDK } from '@opentelemetry/sdk-node'
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http'

export default defineNitroPlugin(() => {
  const sdk = new NodeSDK({
    instrumentations: [new HttpInstrumentation()],
  })
  sdk.start()
})