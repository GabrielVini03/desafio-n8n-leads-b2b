#!/usr/bin/env bash
# Bateria de testes do webhook. Cada caso compara o HTTP status com o esperado.
# Limpa a tabela de idempotência antes, para que os casos de sucesso não sejam
# barrados como duplicados de uma execução anterior.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

URL="http://localhost:${HOST_PORT:-5678}/webhook/lead-b2b"
passou=0; falhou=0

docker compose exec -T postgres psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "TRUNCATE lead_idempotencia;" >/dev/null

caso() { # descrição, status esperado, corpo (opcional)
  local resposta status corpo
  if [ $# -ge 3 ]; then
    resposta=$(curl -s -m 60 -w '\n%{http_code}' -X POST "$URL" -H 'Content-Type: application/json' -d "$3")
  else
    resposta=$(curl -s -m 60 -w '\n%{http_code}' -X POST "$URL" -H 'Content-Type: application/json')
  fi
  status=$(tail -n1 <<<"$resposta"); corpo=$(sed '$d' <<<"$resposta")
  if [ "$status" = "$2" ]; then marca="✅"; passou=$((passou+1)); else marca="❌"; falhou=$((falhou+1)); fi
  printf '\n%s %s — esperado %s, recebido %s\n   %s\n' "$marca" "$1" "$2" "$status" "$corpo"
}

caso "Sucesso SP → Sul/Sudeste (com espaços extras)" 200 \
  '{"empresa":"  Exemplo Comércio LTDA  ","cnpj":"43.261.753/0001-63","email":"  contato@exemplo.com.br ","cep":"01310-100","valor_estimado":5000}'
caso "Mesmo CNPJ logo em seguida → idempotência" 409 \
  '{"empresa":"Exemplo Comércio LTDA","cnpj":"43261753000163","email":"contato@exemplo.com.br","cep":"01310100","valor_estimado":5000}'
caso "Sucesso SC → Geral" 200 \
  '{"empresa":"Petrobras","cnpj":"33.000.167/0001-01","email":"compras@petrobras.com.br","cep":"88010-400","valor_estimado":120000}'
caso "CEP inexistente → exceção operacional" 202 \
  '{"empresa":"Banco do Brasil","cnpj":"00.000.000/0001-91","email":"contato@bb.com.br","cep":"99999-999","valor_estimado":800}'
caso "Campo obrigatório ausente (email)" 400 \
  '{"empresa":"X","cnpj":"43.261.753/0001-63","cep":"01310-100","valor_estimado":100}'
caso "CNPJ com dígitos repetidos" 400 \
  '{"empresa":"X","cnpj":"11.111.111/1111-11","email":"a@b.com","cep":"01310-100","valor_estimado":100}'
caso "CNPJ com dígito verificador errado" 400 \
  '{"empresa":"X","cnpj":"43.261.753/0001-64","email":"a@b.com","cep":"01310-100","valor_estimado":100}'
caso "E-mail malformado" 400 \
  '{"empresa":"X","cnpj":"43.261.753/0001-63","email":"nao-eh-email","cep":"01310-100","valor_estimado":100}'
caso "CEP com 7 dígitos" 400 \
  '{"empresa":"X","cnpj":"43.261.753/0001-63","email":"a@b.com","cep":"0131010","valor_estimado":100}'
caso "valor_estimado negativo" 400 \
  '{"empresa":"X","cnpj":"43.261.753/0001-63","email":"a@b.com","cep":"01310-100","valor_estimado":-50}'
caso "Corpo vazio" 400
caso "JSON malformado" 400 '{"empresa": "X",'
caso "Corpo que não é objeto (array)" 400 '[1, 2, 3]'

printf '\nResultado: %d passaram, %d falharam\n' "$passou" "$falhou"
[ "$falhou" -eq 0 ]
