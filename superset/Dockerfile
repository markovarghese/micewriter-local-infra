FROM apache/superset:latest
USER root
RUN /app/docker/pip-install.sh --no-cache "trino[sqlalchemy]" psycopg2-binary
USER superset
