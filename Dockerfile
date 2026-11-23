# Testumgebung: Ubuntu mit allen Werkzeugen, die das Toolkit braucht.
#   docker build -t bash-toolkit .
#   docker run --rm bash-toolkit                  # Tests ausführen
#   docker run --rm -it bash-toolkit bash         # Shell zum Ausprobieren
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends shellcheck openssl procps passwd tar gzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/bash-sysadmin-toolkit
COPY . .
RUN chmod +x scripts/*.sh tests/*.sh

CMD ["bash", "tests/run-tests.sh"]
