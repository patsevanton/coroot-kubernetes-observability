# Стадия сборки
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY DemoJava.java ./
RUN javac -g -d /app DemoJava.java

# Скачиваем OpenTelemetry Java-агент для автоинструментации (трейсы)
FROM alpine:3.20 AS otel
RUN wget -q -O /opentelemetry-javaagent.jar \
      https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar

# Финальный образ (HotSpot JVM — требование async-profiler)
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app ./
COPY --from=otel /opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar
EXPOSE 8080
# async-profiler: флаги DebugNonSafepoints; трейсы: OTel javaagent (конфигурация из env OTEL_*)
ENTRYPOINT ["java", \
  "-javaagent:/app/opentelemetry-javaagent.jar", \
  "-XX:+UnlockDiagnosticVMOptions", "-XX:+DebugNonSafepoints", \
  "-cp", "/app", "DemoJava"]