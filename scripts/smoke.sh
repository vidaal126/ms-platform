#!/usr/bin/env bash
# Smoke test ponta a ponta, so pelo gateway, contra a plataforma no ar:
#   login -> transporte -> item -> cliente -> pedido -> planejado -> agendado
#   -> reagendado -> em transporte -> entregue, com as replicas via Kafka,
#   autorizacao (401/403) e observabilidade (Prometheus e Loki).
#
# Uso: scripts/smoke.sh   (variaveis opcionais abaixo; requer curl e jq)
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8088}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@ms-platform.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin-dev-password}"
REPLICA_TIMEOUT_S="${REPLICA_TIMEOUT_S:-60}"

API="$GATEWAY_URL/api/v1"
RUN_ID="$(date +%s)-$$"
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

step() { printf '\n== %s\n' "$*"; }
ok() { printf '   ok: %s\n' "$*"; }
fail() { printf '   FALHOU: %s\n' "$*" >&2; printf '   corpo: %s\n' "$(cat "$BODY_FILE")" >&2; exit 1; }

# call METHOD PATH [BODY] [TOKEN] [CORRELATION_ID] -> imprime o status; corpo em $BODY_FILE
call() {
  local method="$1" path="$2" body="${3:-}" token="${4:-}" correlation="${5:-smoke-$RUN_ID}"
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$method" -H "x-correlation-id: $correlation")
  [[ -n "$token" ]] && args+=(-H "authorization: Bearer $token")
  [[ -n "$body" ]] && args+=(-H 'content-type: application/json' --data "$body")
  curl "${args[@]}" "$API$path"
}

expect() {
  local expected="$1" actual="$2" what="$3"
  [[ "$actual" == "$expected" ]] || fail "$what: esperado $expected, veio $actual"
  ok "$what ($actual)"
}

# Repete a chamada enquanto a resposta for 422 (replica ainda nao recebeu o
# evento): consistencia eventual entre servicos.
call_until_replicated() {
  local deadline=$((SECONDS + REPLICA_TIMEOUT_S)) status
  while :; do
    status="$(call "$@")"
    [[ "$status" != "422" ]] && { echo "$status"; return; }
    (( SECONDS >= deadline )) && { echo "$status"; return; }
    sleep 1
  done
}

json() { jq -r "$1" "$BODY_FILE"; }

# CPF valido e aleatorio (digitos verificadores mod 11): o smoke pode rodar
# varias vezes sem colidir no unique do documento.
random_cpf() {
  local d=() i sum r
  for i in {0..8}; do d[i]=$((RANDOM % 10)); done
  for pass in 9 10; do
    sum=0
    for ((i = 0; i < pass; i++)); do sum=$((sum + d[i] * (pass + 1 - i))); done
    r=$(((sum * 10) % 11)); ((r == 10)) && r=0
    d[pass]=$r
  done
  printf '%d%d%d.%d%d%d.%d%d%d-%d%d' "${d[@]}"
}

step "health do gateway"
curl -sf "$GATEWAY_URL/health/ready" >/dev/null || fail "gateway nao esta pronto em $GATEWAY_URL"
ok "gateway pronto"

step "autenticacao e autorizacao"
expect 401 "$(call GET /items)" "rota protegida sem token"
expect 200 "$(call POST /auth/login "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")" "login do admin"
ADMIN="$(json .accessToken)"
OPERATOR_EMAIL="operador-$RUN_ID@ms-platform.local"
expect 201 "$(call POST /users "{\"email\":\"$OPERATOR_EMAIL\",\"password\":\"operador-senha-segura\",\"roles\":[\"operator\"]}" "$ADMIN")" "admin cria operador"
expect 200 "$(call POST /auth/login "{\"email\":\"$OPERATOR_EMAIL\",\"password\":\"operador-senha-segura\"}")" "login do operador"
OPERATOR="$(json .accessToken)"
REFRESH="$(json .refreshToken)"
expect 403 "$(call POST /users '{"email":"x@y.co","password":"outra-senha-segura","roles":["admin"]}' "$OPERATOR")" "operador nao cria usuario"
expect 200 "$(call POST /auth/refresh "{\"refreshToken\":\"$REFRESH\"}")" "refresh rotaciona"
expect 401 "$(call POST /auth/refresh "{\"refreshToken\":\"$REFRESH\"}")" "reuso do refresh antigo"

step "cadastros (o operador escreve)"
expect 201 "$(call POST /transport-types "{\"name\":\"Caminhao $RUN_ID\"}" "$OPERATOR")" "tipo de transporte"
TRANSPORT_ID="$(json .id)"
expect 201 "$(call POST /items "{\"sku\":\"SMOKE-$RUN_ID\",\"name\":\"Caixa smoke\",\"unitPrice\":12.34,\"weightKg\":1.5,\"dimensions\":{\"lengthCm\":30,\"widthCm\":20,\"heightCm\":10}}" "$OPERATOR")" "item no catalogo"
ITEM_ID="$(json .id)"
CUSTOMER_BODY="{\"name\":\"Cliente $RUN_ID\",\"document\":\"$(random_cpf)\",\"authorizedTransportTypeIds\":[\"$TRANSPORT_ID\"]}"
expect 201 "$(call_until_replicated POST /customers "$CUSTOMER_BODY" "$OPERATOR")" "cliente (espera a replica de transporte no ms-customer)"
CUSTOMER_ID="$(json .id)"

step "read model do transporte (catalog.ItemCreated)"
deadline=$((SECONDS + REPLICA_TIMEOUT_S))
until [[ "$(call GET "/catalog-items/$ITEM_ID" "" "$OPERATOR")" == "200" ]]; do
  (( SECONDS >= deadline )) && fail "item $ITEM_ID nao chegou ao read model do ms-transport"
  sleep 1
done
ok "item no read model do ms-transport"

step "pedido de venda"
ORDER_CORRELATION="smoke-order-$RUN_ID"
ORDER_BODY="{\"customerId\":\"$CUSTOMER_ID\",\"transportTypeId\":\"$TRANSPORT_ID\",\"items\":[{\"itemId\":\"$ITEM_ID\",\"quantity\":3}]}"
expect 201 "$(call_until_replicated POST /sales-orders "$ORDER_BODY" "$OPERATOR" "$ORDER_CORRELATION")" "pedido (espera replicas de item, cliente e transporte)"
ORDER_ID="$(json .id)"
[[ "$(json .status)" == "CRIADA" ]] || fail "status inicial"
[[ "$(json '.items[0].unitPrice')" == "12.34" ]] || fail "preco congelado"
[[ "$(json .total)" == "37.02" ]] || fail "total 3 x 12.34"
ok "status CRIADA, preco congelado 12.34, total 37.02"

TOMORROW="$(date -u -d '+1 day' +%F)"
LATER="$(date -u -d '+2 day' +%F)"
expect 422 "$(call PUT "/sales-orders/$ORDER_ID/status" '{"status":"AGENDADA"}' "$OPERATOR")" "AGENDADA so via agendamento"
expect 200 "$(call PUT "/sales-orders/$ORDER_ID/status" '{"status":"PLANEJADA"}' "$OPERATOR")" "CRIADA -> PLANEJADA"
expect 201 "$(call POST "/sales-orders/$ORDER_ID/schedule" "{\"deliveryDate\":\"$TOMORROW\",\"windowStart\":\"${TOMORROW}T09:00:00Z\",\"windowEnd\":\"${TOMORROW}T12:00:00Z\"}" "$OPERATOR")" "agendamento (PLANEJADA -> AGENDADA)"
expect 200 "$(call PUT "/sales-orders/$ORDER_ID/schedule" "{\"deliveryDate\":\"$LATER\",\"windowStart\":\"${LATER}T13:00:00Z\",\"windowEnd\":\"${LATER}T17:00:00Z\"}" "$OPERATOR")" "reagendamento"
expect 200 "$(call PUT "/sales-orders/$ORDER_ID/status" '{"status":"EM_TRANSPORTE"}' "$OPERATOR")" "AGENDADA -> EM_TRANSPORTE"
expect 422 "$(call PUT "/sales-orders/$ORDER_ID/transport" "{\"transportTypeId\":\"$TRANSPORT_ID\"}" "$OPERATOR")" "troca de transporte bloqueada em EM_TRANSPORTE"
expect 200 "$(call PUT "/sales-orders/$ORDER_ID/status" '{"status":"ENTREGUE"}' "$OPERATOR")" "EM_TRANSPORTE -> ENTREGUE"
expect 200 "$(call GET "/sales-orders/$ORDER_ID" "" "$OPERATOR")" "consulta final"
[[ "$(json .status)" == "ENTREGUE" && "$(json .scheduling.deliveryDate)" == "$LATER" ]] || fail "estado final"
ok "ENTREGUE com a entrega reagendada para $LATER"

step "observabilidade"
sleep 20 # um ciclo de scrape do Prometheus (15s) e o envio do Alloy
query_prom() { curl -sG "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result | length'; }
[[ "$(query_prom 'up{job="services"} == 1')" == "6" ]] || fail "Prometheus nao ve os 6 servicos no ar"
ok "Prometheus: 6 servicos up"
[[ "$(query_prom 'kafka_messages_consumed_total{service="ms-sales-order",outcome="applied"}')" -gt 0 ]] || fail "sem consumo no ms-sales-order"
ok "Prometheus: consumo aplicado no ms-sales-order"
LOKI_SERVICES="$(curl -sG "$LOKI_URL/loki/api/v1/query_range" \
  --data-urlencode "query={service=~\"ms-.*\"} | correlationId=\"$ORDER_CORRELATION\"" \
  --data-urlencode "start=$(( $(date +%s) - 900 ))000000000" | jq -r '[.data.result[].stream.service] | unique | join(",")')"
[[ "$LOKI_SERVICES" == *ms-gateway* && "$LOKI_SERVICES" == *ms-sales-order* ]] || fail "Loki sem os logs do pedido (veio: $LOKI_SERVICES)"
ok "Loki: correlationId $ORDER_CORRELATION em $LOKI_SERVICES"

printf '\nSMOKE OK (run %s, pedido %s)\n' "$RUN_ID" "$ORDER_ID"
