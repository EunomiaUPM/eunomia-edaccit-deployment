FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY populate_catalog.py entrypoint.sh ./
RUN chmod +x entrypoint.sh
# catalog-payloads/ and connector-payloads/ are bind-mounted at runtime
ENTRYPOINT ["./entrypoint.sh"]
