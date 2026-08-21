FROM python:3.12-slim

WORKDIR /app

# httpx is the only dependency; pinned so a rebuild months from now on the
# production Windows box resolves the same wheel it was tested against.
RUN pip install --no-cache-dir "httpx==0.28.1"

COPY end-to-end-test.py ./

# No shell involved: the entrypoint is the interpreter, so the image runs
# identically from PowerShell, cmd or a POSIX shell. Extra `docker compose run`
# arguments land as script flags.
ENTRYPOINT ["python", "-u", "end-to-end-test.py"]
