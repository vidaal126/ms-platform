#!/bin/sh
# Job kafka-init: unica origem dos topicos (auto-create desligado no broker).
# Retencao infinita: a padrao (7 dias) apagaria historico usado em replay e as
# mensagens da DLT. Idempotente.
set -eu
BOOTSTRAP=kafka:29092

# Eventos publicados (outbox de cada servico dono).
EVENT_TOPICS="
catalog.ItemCreated
transport.TransportTypeCreated
transport.TransportTypeUpdated
customer.CustomerCreated
customer.CustomerUpdated
sales-order.OrderCreated
sales-order.OrderStatusChanged
sales-order.DeliveryScheduled
sales-order.DeliveryRescheduled
sales-order.TransportChanged
"

# DLTs, uma por consumidor: catalog.ItemCreated.DLT e a do ms-transport
# (nome fixado antes da regra por servico); as demais levam o servico no nome.
DLT_TOPICS="
catalog.ItemCreated.DLT
catalog.ItemCreated.ms-sales-order.DLT
transport.TransportTypeCreated.ms-customer.DLT
transport.TransportTypeUpdated.ms-customer.DLT
transport.TransportTypeCreated.ms-sales-order.DLT
transport.TransportTypeUpdated.ms-sales-order.DLT
customer.CustomerCreated.ms-sales-order.DLT
customer.CustomerUpdated.ms-sales-order.DLT
"

for topic in $EVENT_TOPICS $DLT_TOPICS; do
  kafka-topics --bootstrap-server "$BOOTSTRAP" --create --if-not-exists \
    --topic "$topic" --partitions 1 --replication-factor 1 \
    --config retention.ms=-1
done
kafka-topics --bootstrap-server "$BOOTSTRAP" --list
