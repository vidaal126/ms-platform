# ms-platform

Ambiente compartilhado dos microserviços extraídos do monolito
`sales-order-api`: compose, jobs de inicialização, observabilidade e o smoke
test ponta a ponta.

Todos os repositórios ficam lado a lado em `Documents/projects`. Nenhum
código é compartilhado entre serviços: o contrato entre eles é o formato dos
eventos e das rotas HTTP.

| Serviço | Papel | Database | Publica | Consome |
|---|---|---|---|---|
| [ms-gateway](../ms-gateway/README.md) | entrada única `/api/v1`, valida JWT (JWKS) e autoriza por rota | - | - | - |
| [ms-auth](../ms-auth/README.md) | usuários, roles, login, refresh rotativo, JWKS | `auth` | - | - |
| [ms-catalog](../ms-catalog/README.md) | itens (preço, peso, dimensões) | `catalog` | `catalog.ItemCreated` | - |
| [ms-transport](../ms-transport/README.md) | tipos de transporte e read model físico dos itens | `transport` | `transport.TransportType{Created,Updated}` | `catalog.ItemCreated` |
| [ms-customer](../ms-customer/README.md) | clientes (CPF) e transportes autorizados | `customer` | `customer.Customer{Created,Updated}` | `transport.*` |
| [ms-sales-order](../ms-sales-order/README.md) | pedidos, máquina de estados, agendamento | `sales_order` | `sales-order.*` | `catalog.ItemCreated`, `customer.*`, `transport.*` |

## Arquitetura

```
 cliente
    |  HTTPS /api/v1/*  (Bearer JWT)
    v
 +------------+   JWKS (cache)   +---------+
 | ms-gateway | ---------------> | ms-auth | --- db auth
 +------------+                  +---------+
    |  roteia por prefixo, injeta x-user-id / x-user-roles / x-correlation-id
    |
    +--> ms-catalog ----- db catalog     --outbox--> catalog.ItemCreated ----------+
    +--> ms-transport --- db transport   --outbox--> transport.TransportType* ---+ |
    +--> ms-customer ---- db customer    --outbox--> customer.Customer* -------+ | |
    +--> ms-sales-order - db sales_order --outbox--> sales-order.* (5 topicos) | | |
                                                                            | | |
        ms-transport   <-- catalog.ItemCreated ---------------------------------+ |
        ms-customer    <-- transport.* ----------------------------------------+ |
        ms-sales-order <-- catalog.ItemCreated, customer.*, transport.* (réplicas)
```

Padrões aplicados em todos os serviços:

- **Transactional Outbox**: o agregado e o evento são gravados na mesma
  transação, e um publisher publica o evento no Kafka.
- **Envelope v2**: `{eventId, eventType, schemaVersion, occurredAt,
  aggregateId, correlationId, payload}`. Os headers `eventType`,
  `schemaVersion` e `correlationId` acompanham a mensagem, e a key é o
  `aggregateId`.
- **Consumo idempotente**:
  - `autoCommit: false`, com commit de `offset + 1` só depois da persistência,
    do ack da DLT ou da detecção de duplicata;
  - `processed_events` com upsert condicional por `sourceOccurredAt`;
  - retry com backoff e jitter; esgotado o limite, a partição é pausada e
    depois retomada.
- **DLT por consumidor**: `<topico>.<servico>.DLT`, com o header
  `dlt-consumer-group`. A exceção histórica é `catalog.ItemCreated.DLT`, que é
  do ms-transport.
- **Réplicas locais**: o cliente e o pedido validam contra réplicas
  alimentadas por eventos, sem chamada síncrona entre serviços. A
  consistência é eventual.
- **Segurança**:
  - JWT RS256 emitido pelo ms-auth e validado no gateway;
  - o gateway remove os `x-user-*` que vierem do cliente;
  - o `Authorization` só é repassado ao ms-auth.

### Fluxo de um pedido de ponta a ponta

1. `POST /api/v1/auth/login` retorna o access token (15 min) e o refresh token.
2. Três cadastros, cada um publicando seu evento pelo outbox:
   - `POST /api/v1/transport-types` no ms-transport publica
     `transport.TransportTypeCreated`;
   - `POST /api/v1/items` no ms-catalog publica `catalog.ItemCreated`;
   - `POST /api/v1/customers` no ms-customer valida os transportes na réplica
     local e publica `customer.CustomerCreated`.
3. O ms-sales-order atualiza as réplicas de item, cliente e transporte.
4. `POST /api/v1/sales-orders` valida o pedido contra as réplicas, congela o
   preço, calcula o total e publica `sales-order.OrderCreated`.
5. O pedido percorre os status:
   - `PUT .../status PLANEJADA`;
   - `POST .../schedule`, que leva a AGENDADA;
   - `PUT .../schedule` (reagendamento);
   - `PUT .../status EM_TRANSPORTE`;
   - `PUT .../status ENTREGUE`.
6. Um único `x-correlation-id` acompanha o request HTTP, o envelope, os logs
   de cada serviço e o Loki.

## Como subir

```bash
cp .env.example .env              # opcional: os padrões funcionam localmente
docker compose up -d --build
./scripts/smoke.sh                # fluxo completo pelo gateway
```

| Endereço | O que é |
|---|---|
| http://localhost:8088/api/v1 | **ms-gateway**, a entrada pública (a 8000 costuma estar ocupada pelo Portainer) |
| http://localhost:3300 | Grafana (admin/admin), com o dashboard "ms-platform - visão geral" |
| http://localhost:9090 | Prometheus |
| http://localhost:3100 | Loki (API) |
| http://localhost:8090 | Kafka UI |
| localhost:9092 | Kafka, listener externo para apps no host |
| localhost:5433 | Postgres com os 5 databases |
| 3000 a 3004 | serviços, expostos só para desenvolvimento |

Admin inicial: `admin@ms-platform.local` / `admin-dev-password`
(`AUTH_BOOTSTRAP_ADMIN_*`). **Troque fora do ambiente local.**

Para rodar os apps no host, suba só a infraestrutura e siga o README de cada
serviço:

```bash
docker compose up -d postgres postgres-init kafka kafka-init kafka-ui
```

### Jobs de inicialização

Todos são idempotentes e rodam a cada `up`:

| Job | Faz |
|---|---|
| `postgres-init` | cria o usuário e o database de cada serviço que ainda não existir (`scripts/create-databases.sh`); funciona também num volume já inicializado |
| `kafka-init` | cria todos os tópicos e DLTs com retenção infinita (`scripts/create-topics.sh`); o auto-create fica desligado no broker |
| `auth-keygen` | gera uma vez a chave RSA 3072 do ms-auth no volume `auth_keys` (`scripts/generate-auth-key.mjs`) |
| `*-migrate` | `prisma migrate deploy` de cada serviço, antes do app subir |

### Kafka

| Listener | Endereço | Quem usa |
|---|---|---|
| INTERNAL | `kafka:29092` | containers |
| EXTERNAL | `localhost:9092` | apps no host |

O broker é KRaft com um nó. O `CLUSTER_ID` é fixo para reabrir o volume
existente.

## Observabilidade

- **Métricas**: cada serviço expõe `GET /metrics` (prom-client) na rede
  interna; o gateway não roteia essa rota. Métricas comuns:
  - `http_request_duration_seconds{service, method, route, status_code}`, com
    a rota em forma de template, para manter a cardinalidade baixa;
  - `kafka_messages_consumed_total{topic, outcome}`, com `outcome` entre
    applied, duplicate, stale, dead_letter e retry_exhausted;
  - `outbox_events_published_total` e `outbox_pending_events`.

  Métricas específicas:
  - `auth_session_events_total`, no ms-auth;
  - `gateway_proxy_errors_total`, no ms-gateway;
  - `kafka_consumergroup_lag`, via kafka-exporter.
- **Logs**: o Alloy lê o stdout JSON (pino) dos containers `ms-*` pelo socket
  do Docker e envia ao Loki.
  - Labels: `service`, `project` e `level`.
  - O `correlationId` vai como structured metadata. Consulta no Grafana ou no
    Loki: `{service=~"ms-.*"} | correlationId="<id>"`.
- **Grafana**: datasources e dashboard provisionados, sem edição pela UI. O
  dashboard mostra:
  - requisições por segundo, latência p95 e respostas 5xx;
  - erros de proxy do gateway;
  - consumo por resultado e mensagens enviadas para a DLT;
  - lag por consumer group e outbox pendente;
  - sessões do ms-auth e memória;
  - painel de logs com filtro por correlationId.

## Volumes e migração do compose antigo

O compose antes ficava em `ms-catalog/docker-compose.yml`, com um Postgres por
serviço. Ele foi removido.

- **Kafka**: o volume antigo, `ms-catalog_kafka_data`, é reaproveitado por
  padrão (`KAFKA_VOLUME`, com o mesmo `CLUSTER_ID`), então a massa do tópico é
  preservada.
- **Postgres**: `ms-platform_postgres_data` é novo. Os volumes antigos
  (`ms-catalog_catalog_db_data` e `ms-catalog_transport_db_data`) não são
  tocados. Para levar os dados do catálogo, uma vez só:

```bash
docker run -d --name old-catalog-db -e POSTGRES_PASSWORD=x \
  -v ms-catalog_catalog_db_data:/var/lib/postgresql/data postgres:16-alpine
docker exec old-catalog-db pg_dump -U catalog -d catalog_db --data-only \
  --exclude-table=_prisma_migrations > catalog.sql
docker stop old-catalog-db && docker rm old-catalog-db
docker compose up -d postgres postgres-init catalog-migrate
docker compose exec -T postgres psql -U catalog -d catalog < catalog.sql
```

Os read models e as réplicas não precisam de migração: são reconstruídos pelo
replay dos tópicos (os consumer groups novos leem desde o início).

### Ambiente isolado (validação)

Para testar sem tocar nos volumes do dia a dia, use outro nome de projeto e
volumes próprios:

```bash
cat > /tmp/iso.env <<'EOF'
POSTGRES_VOLUME=ms-iso_postgres_data
KAFKA_VOLUME=ms-iso_kafka_data
AUTH_KEYS_VOLUME=ms-iso_auth_keys
PROMETHEUS_VOLUME=ms-iso_prometheus_data
LOKI_VOLUME=ms-iso_loki_data
GRAFANA_VOLUME=ms-iso_grafana_data
EOF
docker compose -p ms-iso --env-file /tmp/iso.env up -d --build
./scripts/smoke.sh
docker compose -p ms-iso --env-file /tmp/iso.env down -v   # remove só os volumes ms-iso_*
```

Com um volume Kafka vazio, a massa de teste do tópico do catálogo é
publicada pelo `yarn seed:topic` do ms-catalog.

## Testes

Cada serviço tem as próprias suítes. Integração e e2e usam testcontainers,
precisam só de Docker e sempre partem de um ambiente zerado.

```bash
for s in ms-gateway ms-auth ms-catalog ms-transport ms-customer ms-sales-order; do
  (cd ../$s && yarn lint && yarn typecheck && yarn test && yarn test:integration)
done
(cd ../ms-catalog && yarn test:e2e)   # catálogo -> Kafka -> read model do transporte
./scripts/smoke.sh                     # plataforma inteira no ar, só pelo gateway
```

O smoke cobre:

- **Autenticação e autorização:**
  - 401 sem token;
  - admin cria operador;
  - 403 para o operador criando usuário;
  - rotação do refresh e 401 no reuso.
- **Cadastros e réplicas:**
  - cadastros esperando as réplicas;
  - read model do ms-transport.
- **Pedido:**
  - preço congelado e total;
  - máquina de estados completa, com AGENDADA recusada no `PUT /status`;
  - troca de transporte bloqueada durante o transporte.
- **Observabilidade:**
  - os 6 alvos no ar no Prometheus;
  - o consumo registrado;
  - os logs do pedido correlacionados no Loki.

## Limitações conhecidas

- **Serviços internos confiam no gateway.** Eles não revalidam o JWT. Em
  produção, só o gateway deve ser publicado, e as portas 3000 a 3004 existem
  apenas para desenvolvimento. A exceção é o ms-auth, que revalida o token em
  `/users`.
- **Consistência eventual das réplicas.** Um cadastro recém-feito em outro
  serviço pode dar 422 por alguns instantes. O smoke espera por isso.
- **Preço e nome não se atualizam nas réplicas.** O catálogo não publica
  `ItemUpdated`.
- **Eventos legados na DLT.** Os 2 eventos antigos sem peso nem dimensões e a
  mensagem inválida da massa vão para a DLT. Cada replay os republica.
- **eventId de eventos v1.** É derivado de tópico, partição e offset. O mesmo
  evento republicado ganha outro id, e o guard de `sourceOccurredAt` impede
  que ele altere o dado.
- **Uma réplica por serviço.** O outbox não usa `SKIP LOCKED`, e o rate limit
  fica em memória.
- **Erro não classificado no consumo é tratado como recuperável.** Não perde
  evento, mas um erro permanente mantém a partição em ciclos de pausa e
  retomada. O readiness e o dashboard mostram isso.
- **Access token não é revogável.** Vale até expirar (15 min). A chave de
  assinatura é única, sem rotação com duas chaves no JWKS.
- **Observabilidade de desenvolvimento.** Loki e Prometheus usam disco local;
  não há alertas nem traces distribuídos.
- **O Alloy precisa do socket do Docker.** Ele é montado só para leitura, mas
  continua sendo acesso privilegiado ao host.
