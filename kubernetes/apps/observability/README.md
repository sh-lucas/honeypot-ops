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

A UI fica em `https://observe.sh-lucas.dev`, no entrypoint `websecure`; portanto só deve ser acessível pela Tailscale. O certificado DNS-01 usa o `ClusterIssuer` Cloudflare já existente.

As imagens são deliberadamente fixadas. Atualize ambas em um commit separado depois de conferir as notas de versão.
