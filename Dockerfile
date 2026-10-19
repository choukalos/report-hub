FROM python:3.14-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server/ ./server/
COPY migrations/ ./migrations/
COPY templates/ ./templates/
COPY static/ ./static/
COPY tests/ ./tests/

EXPOSE 8101
CMD ["python", "-m", "uvicorn", "server.main:app", "--host", "0.0.0.0", "--port", "8101"]