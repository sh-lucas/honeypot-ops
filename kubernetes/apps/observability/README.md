# Observabilidade

O OpenObserve e o OpenTelemetry Collector são gerenciados pelo Flux neste diretório.

Antes da primeira reconciliação, crie manualmente o secret no cluster:

```bash
kubectl -n observability create secret generic openobserve-credentials \
  --from-literal=username='seu-email' \
  --from-literal=password='uma-senha-longa-e-unica'
```

O Collector recebe OTLP/HTTP em `http://otel-collector.observability.svc.cluster.local:4318`.
As aplicações devem definir `OTEL_EXPORTER_OTLP_ENDPOINT` para esse endereço. Logs não usam OTLP: a aplicação escreve JSON em `stdout` e o Collector os acompanha continuamente em `/var/log/pods`.

O Collector exclui os próprios pods do namespace `observability`; isso evita um ciclo entre os access logs do OpenObserve e o coletor. Logs de aplicações e dos demais namespaces continuam sendo coletados.

A UI fica em `https://observe.sh-lucas.dev`, no entrypoint `websecure`. O CoreDNS resolve esse hostname apenas para o IP da Tailscale do servidor; não existe registro público A/AAAA nem rota pelo tunnel Cloudflare. O certificado usa o `ClusterIssuer` DNS-01 já existente, sem expor a UI.

As imagens são deliberadamente fixadas. Atualize ambas em um commit separado depois de conferir as notas de versão.

## TODO

### Qualidade dos logs

- [ ] **Separar streams por tipo** — atualmente tudo cai em `k8s_logs`. Melhor separar em pelo menos duas:
  - `app_logs` — namespaces de aplicação (checkup, etc.)
  - `infra_logs` — traefik, cert-manager, kube-system
  - Usar o `routing` connector ou múltiplos pipelines com filtro por `k8s.namespace.name`
- [ ] **Parsear JSON nos logs de app** — adicionar `json_parser` operator no `filelog` receiver para que campos como `level`, `traceId` e `message` sejam indexados como atributos no OpenObserve, não só como string crua no `body`

### Alertas

- [ ] **Configurar alertas no OpenObserve** para os casos que realmente importam:
  - `CrashLoopBackOff` — pod reiniciando repetidamente (detectável via logs do kubelet ou métrica `kube_pod_container_status_waiting_reason`)
  - **Downtime** — pod não-ready por mais de N minutos (métrica `kubelet_running_pods` ou ausência de heartbeat)
  - **Acúmulo de erros** — taxa de logs com `level=error` acima de threshold por janela de tempo
  - **Disco cheio** — métrica `filesystem_usage` do hostmetrics acima de 80%
  - Canal de destino a definir (e-mail, webhook, Telegram, etc.)
