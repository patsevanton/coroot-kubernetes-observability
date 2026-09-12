# Стадия сборки
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY nuxt.config.ts ./
COPY server ./server
RUN npm run build

# Финальный образ
FROM node:20-alpine
WORKDIR /app
COPY --from=build /app/.output ./.output
# NODE_OPTIONS: perf-map для символизации JS-фреймов в eBPF CPU-профиле Coroot.
# OTEL_EXPORTER_OTLP_TRACES_ENDPOINT и OTEL_SERVICE_NAME задаются в Helm-чарте (chart/values.yaml).
ENV NODE_OPTIONS="--perf-basic-prof-only-functions --interpreted-frames-native-stack"
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]