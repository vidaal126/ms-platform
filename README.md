# ms-platform

Ambiente local compartilhado dos microserviços extraídos do monolito:

- [`ms-catalog`](../ms-catalog/README.md): cadastro de itens; producer de
  `catalog.ItemCreated` via Transactional Outbox.
- [`ms-transport`](../ms-transport/README.md): consumer que mantém o read
  model `catalog_items` com o que transporte precisa (peso e dimensões).

Os três repositórios ficam lado a lado em `Documents/projects`. Nenhum código é
compartilhado entre os serviços: o contrato entre eles é o formato do evento.

## Arquitetura

```
             POST /items
                 |
                 v
 +---------------------------------+          +---------------------------------+
 | ms-catalog                      |          | ms-transport                    |
 |                                 |          |                                 |
 |  ItemEntity.create()            |          |  consumer group                 |
 |   registra ItemCreated          |          |  ms-transport.catalog-item-sync |
 |          |                      |          |          |                      |
 |  1 transacao: items + outbox    |          |  decoder Zod (v1 legado e v2)   |
 |          |                      |          |          |                      |
 |  OutboxPublisher (polling)  ----+--> Kafka +-> 1 transacao:                  |
 |                                 |  catalog.|    processed_events (PK)        |
 |  database: catalog              |  Item    |    + upsert catalog_items       |
 +---------------------------------+  Created |    (so se occurredAt mais novo) |
                                              |          |                      |
                                              |  commit offset+1 depois disso   |
                                              |                                 |
                                              |  nao recuperavel -> DLT         |
                                              |  catalog.ItemCreated.DLT        |
                                              |  recuperavel -> retry, pausa    |
                                              |                                 |
                                              |  database: transport            |
                                              |  GET /catalog-items/:itemId     |
                                              +---------------------------------+
```

## Fluxo do evento de ponta a ponta

1. `POST /items` no ms-catalog. Opcionais: `Idempotency-Key` e
   `x-correlation-id`; sem este último, um correlationId é gerado.
2. A entidade valida as invariantes e registra `ItemCreated`. O repositório
   grava o item e a linha do outbox na mesma transação.
3. O publisher lê o outbox e publica em `catalog.ItemCreated`:
   - envelope `{eventId, eventType, schemaVersion: 2, occurredAt, aggregateId,
     correlationId, payload}`;
   - key = `aggregateId`, o que garante ordem por item;
   - headers `eventType`, `schemaVersion` e `correlationId`.
4. O ms-transport valida a mensagem com Zod. Aceita o envelope v2 e o formato
   v1 legado, que tem `schemaVersion` dentro do payload.
5. O insert em `processed_events` e o upsert em `catalog_items` acontecem na
   mesma transação. O offset + 1 só é commitado depois dessa transação, do ack
   da DLT ou da detecção de duplicata.
6. Erros não recuperáveis (JSON inválido, schema, versão não suportada,
   invariante) vão para `catalog.ItemCreated.DLT` com os bytes originais.
   Erros recuperáveis (banco ou timeout) passam por retry com backoff e jitter;
   esgotado o limite, a partição é pausada e retomada depois.

## Como subir

```bash
cp .env.example .env              # opcional: os padroes ja funcionam
docker compose up -d --build
```

| Serviço | Endereço no host |
|---|---|
| ms-catalog | http://localhost:3000 |
| ms-transport | http://localhost:3001 |
| Kafka (listener externo) | localhost:9092 |
| Kafka UI | http://localhost:8090 |
| Postgres (databases `catalog` e `transport`) | localhost:5433 |

Para rodar os apps no host, suba só a infraestrutura e siga o README de cada
serviço:

```bash
docker compose up -d postgres kafka kafka-init kafka-ui
```

### Postgres

O ambiente usa um container com dois databases, cada um com usuário próprio:

- `catalog`, do usuário `catalog`;
- `transport`, do usuário `transport`.

Os databases são criados por `initdb/01-create-databases.sh` na primeira subida
do volume. O script só roda com o volume vazio, então mudar usuários ou nomes
depois exige um volume novo.

### Kafka

O broker é KRaft, com um nó, e expõe dois listeners:

| Listener | Endereço | Quem usa |
|---|---|---|
| INTERNAL | `kafka:29092` | containers do compose |
| EXTERNAL | `localhost:9092` | apps rodando no host |

Com isso, `KAFKA_BROKER` vale `kafka:29092` dentro do compose e
`localhost:9092` no `.env` de cada serviço.

O auto-create de tópicos fica desligado. O `kafka-init` cria os tópicos
explicitamente, com 1 partição e retenção infinita:

- `catalog.ItemCreated`
- `catalog.ItemCreated.DLT`

### Volumes e migração do compose antigo

O compose antes ficava em `ms-catalog/docker-compose.yml`, com um Postgres por
serviço (`catalog_db` e `transport_db`).

- **Kafka**: o volume antigo, `ms-catalog_kafka_data`, é reaproveitado por
  padrão (`KAFKA_VOLUME`, com o mesmo `CLUSTER_ID`). A massa do tópico e os
  offsets dos groups são preservados.
- **Postgres**: `ms-platform_postgres_data` é um volume novo. Os volumes
  antigos (`ms-catalog_catalog_db_data` e `ms-catalog_transport_db_data`) não
  são tocados.

Para levar os dados do catálogo, faça uma vez, com os dois ambientes parados:

```bash
docker run -d --name old-catalog-db -e POSTGRES_PASSWORD=x \
  -v ms-catalog_catalog_db_data:/var/lib/postgresql/data postgres:16-alpine
docker exec old-catalog-db pg_dump -U catalog -d catalog_db --data-only \
  --exclude-table=_prisma_migrations > catalog.sql
docker stop old-catalog-db && docker rm old-catalog-db

docker compose up -d postgres catalog-migrate
docker compose exec -T postgres psql -U catalog -d catalog < catalog.sql
```

O read model do transport não precisa de migração: ele é reconstruído pelo
replay do tópico (veja o README do ms-transport).

### Ambiente isolado (validação)

Para testar sem tocar nos volumes do dia a dia, use outro nome de projeto e
volumes próprios:

```bash
POSTGRES_VOLUME=ms-validation_postgres_data KAFKA_VOLUME=ms-validation_kafka_data \
  docker compose -p ms-validation up -d --build
# ...
docker compose -p ms-validation down -v    # remove so os volumes ms-validation_*
```

Com um volume Kafka vazio, a massa de teste do tópico é publicada pelo
`yarn seed:topic` do ms-catalog.

## Testes

Cada serviço tem as próprias suítes; todas usam testcontainers e só precisam
de Docker, sem depender deste compose.

```bash
cd ../ms-catalog && yarn lint && yarn typecheck && yarn test && yarn test:integration && yarn test:e2e
cd ../ms-transport && yarn lint && yarn typecheck && yarn test && yarn test:integration
```

| Suíte | Onde | O que cobre |
|---|---|---|
| unitários | cada serviço | domínio, use cases, filtro de erros, idempotência, decoder, commit, retry e pausa do consumer |
| integração | ms-catalog | POST, outbox, Kafka (envelope, key, headers), 409, 400, Idempotency-Key (replay e 422) |
| integração | ms-transport | replay da massa (1 item e 3 na DLT), duplicidade v1 e v2, reordenação, poison message na DLT |
| e2e | ms-catalog | POST no catálogo, depois outbox, Kafka e GET no read model do transporte (imagem do ms-transport buildada de `../ms-transport`) |

## Limitações conhecidas

- **Eventos legados na DLT.** Os 2 eventos legados do tópico não têm peso e
  dimensões, e a mensagem `t` não é JSON; os três vão para a DLT. Cada replay
  do tópico republica esses três na DLT.
- **eventId de v1 derivado da posição.** Eventos v1 não têm eventId, então ele
  é um UUID v5 de tópico+partição+offset. O mesmo evento v1 republicado ganha
  outro id; o guard de `sourceOccurredAt` impede que altere o item.
- **Uma réplica por serviço.** O outbox não usa `SKIP LOCKED`, e o rate limit
  e o throttler vivem em memória.
- **Erro não classificado é tratado como recuperável.** Nunca perde evento,
  mas um erro permanente mantém a partição em ciclos de pausa e retomada.
