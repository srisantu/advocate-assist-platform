FROM python:3.11-slim
WORKDIR /workspace
COPY apps/requirements.txt ./apps/requirements.txt
RUN pip install --no-cache-dir -r apps/requirements.txt
COPY . .
CMD ["python3", "scripts/run_local_demo.py"]
