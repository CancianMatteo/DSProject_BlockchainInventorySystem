# --- Stage 1: Build ---
FROM python:3.12-slim AS builder

# Impedisce a Python di generare file .pyc e abilita il buffering dei log
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /build

# Installazione delle dipendenze di sistema necessarie per compilare alcuni pacchetti (es. cryptography/argon2)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Installazione delle dipendenze Python
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --prefix=/install -r requirements.txt

# --- Stage 2: Final ---
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app

WORKDIR /app

# Copia delle dipendenze installate dallo stage builder
COPY --from=builder /install /usr/local

# Creazione della directory per il database SQLite e dell'utente non-root
RUN mkdir /data && \
    groupadd -r bisuser && useradd -r -g bisuser bisuser && \
    chown bisuser:bisuser /data

# Copia del codice sorgente (il file .dockerignore escluderà i file non necessari)
COPY . .

# Garantisce permessi di lettura/esecuzione per l'utente runtime non-root
RUN chown -R bisuser:bisuser /app && chmod -R u+rwX,go+rX /app

# Passaggio all'utente non-root per sicurezza 
USER bisuser

# Esposizione della porta definita nel blueprint 
EXPOSE 8000

# Volume per la persistenza del database SQLite 
VOLUME ["/data"]

# Avvio del server HTTP
CMD ["python", "-m", "app.run_server"]