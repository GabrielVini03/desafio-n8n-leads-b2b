#!/usr/bin/env bash
# Sobe o ambiente completo (n8n + Postgres), cria a credencial do banco a partir
# do .env, importa e ativa os workflows. Pode ser executado mais de uma vez:
# a importação sobrescreve os workflows pelo mesmo ID.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  cp .env.example .env
  echo "» .env criado a partir do .env.example"
fi
set -a; source .env; set +a

N8N_URL="http://localhost:${HOST_PORT:-5678}"
MAIN_ID="hIhRkh6i2GPFRGRg"
ERROR_ID="pB37UWtTRAfDsjp1"

echo "» Subindo containers..."
docker compose up -d

wait_for() { # url, código HTTP diferente de 404/000 indica que está no ar
  for _ in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X "$1" "$2" || true)
    [ "$code" != "000" ] && [ "$code" != "404" ] && [ "$code" != "503" ] && return 0
    sleep 2
  done
  echo "Tempo esgotado aguardando $2" >&2; exit 1
}
wait_for GET "$N8N_URL/healthz"

echo "» Criando credencial do Postgres (valores vindos do .env)..."
# Enviada por stdin: a senha não é gravada em disco no host.
printf '[{"id":"PgLeadsLocal0001","name":"Postgres Leads","type":"postgres","data":{"host":"postgres","port":5432,"database":"%s","user":"%s","password":"%s","ssl":"disable"}}]' \
  "$POSTGRES_DB" "$POSTGRES_USER" "$POSTGRES_PASSWORD" \
  | docker compose exec -T n8n sh -c 'cat > /tmp/cred.json && n8n import:credentials --input=/tmp/cred.json; rm -f /tmp/cred.json'

echo "» Importando workflows..."
docker compose cp workflows/Lead_B2B_Error_Workflow.json n8n:/tmp/error.json
docker compose cp workflows/Lead_B2B_Processamento_e_Roteamento.json n8n:/tmp/main.json
docker compose exec -T n8n n8n import:workflow --input=/tmp/error.json
docker compose exec -T n8n n8n import:workflow --input=/tmp/main.json

echo "» Ativando workflows..."
docker compose exec -T n8n n8n publish:workflow --id="$ERROR_ID"
docker compose exec -T n8n n8n publish:workflow --id="$MAIN_ID"
docker compose restart n8n >/dev/null
wait_for POST "$N8N_URL/webhook/lead-b2b"

echo
echo "✔ Pronto."
echo "  UI:      $N8N_URL  (no primeiro acesso, crie a conta de owner)"
echo "  Webhook: POST $N8N_URL/webhook/lead-b2b"
echo
echo "Próximo passo: bash scripts/testar.sh"
