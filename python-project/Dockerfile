FROM python:3.12-slim-bookworm

RUN pip install --no-cache-dir requests==2.32.3

COPY ETL.py /app/ETL.py

WORKDIR /app

CMD ["python3", "ETL.py"]