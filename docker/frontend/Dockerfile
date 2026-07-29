# syntax=docker/dockerfile:1

ARG NODE_VERSION=22

FROM node:${NODE_VERSION}-alpine AS dependencies
WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED=1

COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

FROM node:${NODE_VERSION}-alpine AS builder
WORKDIR /app

ARG NEXT_PUBLIC_INTERNAL_SYSTEM_URL

ENV NEXT_PUBLIC_INTERNAL_SYSTEM_URL=${NEXT_PUBLIC_INTERNAL_SYSTEM_URL}
ENV NEXT_TELEMETRY_DISABLED=1

COPY --from=dependencies /app/node_modules ./node_modules
COPY frontend ./

RUN npm run build

FROM node:${NODE_VERSION}-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
ENV PORT=3000
ENV NEXT_TELEMETRY_DISABLED=1

RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 nextjs

COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000

CMD ["node", "server.js"]
