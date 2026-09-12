# Стадия сборки
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY DemoJava.java ./
RUN javac -g -d /app DemoJava.java

# Финальный образ (HotSpot JVM — требование async-profiler)
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app ./
EXPOSE 8080
ENTRYPOINT ["java", "-cp", "/app", "DemoJava"]