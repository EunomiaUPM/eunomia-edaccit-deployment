# Stage 1 — build the React frontend
FROM node:22-alpine AS frontend-builder
WORKDIR /app/frontend

COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

COPY frontend/ ./

# VITE_* vars are baked in at build time by Vite.
# Override via docker-compose build.args if needed.
ARG VITE_AUTH_MODE=eunomia-consumer
ARG VITE_ARCGIS_BASE_URL=https://edaccit.esrilab.es/server
ENV VITE_AUTH_MODE=$VITE_AUTH_MODE
ENV VITE_ARCGIS_BASE_URL=$VITE_ARCGIS_BASE_URL

RUN npm run build

# Stage 2 — runtime (FastAPI + pre-built SPA)
FROM python:3.12-slim
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY --from=frontend-builder /app/frontend/dist ./frontend/dist

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
