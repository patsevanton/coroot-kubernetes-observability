// Стадия сборки
FROM node:20-slim AS build
WORKDIR /app
COPY package.json ./
RUN npm install
COPY nuxt.config.ts ./
COPY server ./server
RUN npm run build

# Финальный образ
FROM node:20-slim
WORKDIR /app
COPY --from=build /app/.output ./.output
ENV NODE_OPTIONS="--perf-basic-prof-only-functions --interpreted-frames-native-stack"
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]
