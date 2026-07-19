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
