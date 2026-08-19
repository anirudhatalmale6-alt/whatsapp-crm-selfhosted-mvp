#!/usr/bin/env bash
# =============================================================================
#  Escalar: anadir el numero 3, 4, 5...  Genera el bloque de compose y las
#  variables que hay que pegar. Es la prueba de que escalar cuesta minutos,
#  no un rediseno.
#
#  Uso:  ./scripts/add-number.sh 3 wa3.tudominio.com ventas3
# =============================================================================
set -euo pipefail
N="${1:?numero (3,4,5...)}"; HOST="${2:?subdominio}"; INSTANCE="${3:?nombre instancia}"
KEY=$(openssl rand -hex 16 | tr '[:lower:]' '[:upper:]')

cat <<EOF

### 1) anadir a .env ###########################################################
N${N}_HOST=${HOST}
N${N}_INSTANCE=${INSTANCE}
N${N}_API_KEY=${KEY}
N${N}_PROXY_HOST=
N${N}_PROXY_PORT=
N${N}_PROXY_PROTOCOL=http
N${N}_PROXY_USERNAME=
N${N}_PROXY_PASSWORD=

### 2) anadir a docker-compose.yml (servicios) #################################
  evolution-n${N}:
    <<: *evolution-common
    container_name: wacrm-evolution-n${N}
    environment:
      <<: *evolution-env
      SERVER_URL: https://\${N${N}_HOST}
      AUTHENTICATION_API_KEY: \${N${N}_API_KEY}
      DATABASE_CONNECTION_URI: postgresql://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@postgres:5432/evolution_n${N}?schema=public
      CHATWOOT_IMPORT_DATABASE_CONNECTION_URI: postgresql://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@postgres:5432/chatwoot?sslmode=disable
      CACHE_REDIS_URI: redis://redis:6379/${N}
      CACHE_REDIS_PREFIX_KEY: evo_n${N}
      PROXY_HOST: \${N${N}_PROXY_HOST}
      PROXY_PORT: \${N${N}_PROXY_PORT}
      PROXY_PROTOCOL: \${N${N}_PROXY_PROTOCOL}
      PROXY_USERNAME: \${N${N}_PROXY_USERNAME}
      PROXY_PASSWORD: \${N${N}_PROXY_PASSWORD}
    volumes:
      - evo_n${N}_instances:/evolution/instances
    depends_on:
      postgres: { condition: service_healthy }
      redis:    { condition: service_healthy }
    labels:
      - traefik.enable=true
      - traefik.docker.network=wacrm_edge
      - traefik.http.routers.evo-n${N}.rule=Host(\`\${N${N}_HOST}\`)
      - traefik.http.routers.evo-n${N}.entrypoints=websecure
      - traefik.http.routers.evo-n${N}.tls.certresolver=le
      - traefik.http.services.evo-n${N}.loadbalancer.server.port=8080

### 3) anadir a docker-compose.yml (volumes) ###################################
  evo_n${N}_instances:

### 4) anadir a postgres-init/01-databases.sh la base evolution_n${N}
###    (si Postgres ya esta arrancado, crearla a mano:)
docker compose exec postgres psql -U \$POSTGRES_USER -c "CREATE DATABASE evolution_n${N};"

### 5) levantar y vincular #####################################################
docker compose up -d evolution-n${N}
./scripts/provision.sh n${N}

EOF
