# Стадия сборки
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /demo-service .

# Финальный образ
FROM alpine:3.20
RUN adduser -D -u 10001 app
USER app
COPY --from=build /demo-service /demo-service
EXPOSE 8080
ENTRYPOINT ["/demo-service"]
