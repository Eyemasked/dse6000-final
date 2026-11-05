FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY data/ ./data/

EXPOSE 8080

CMD ["sh", "-c", "gunicorn --bind :${PORT:-8080} --workers 1 --threads 8 --timeout 0 main:server"]
