
Alertas (https://observe.sh-lucas.dev → Alerts):
1. Crie um destino webhook primeiro (Alert Destinations → New → tipo Webhook, aponte pra onde você quiser receber — ntfy/Discord/n8n/etc).
2. Para cada alerta, é: stream + condição SQL/threshold + janela + destino. Sugestões concretas:
  - Erro fatal/error: stream app_logs, condição level in ('error','fatal'), contagem > X em janela de 5min.
  - 4xx/5xx: se seus apps logam status HTTP como atributo (verifique se checkup/plinth expõem isso no JSON — senão precisa adicionar ao log), condição sobre proporção de status >= 400 na janela. Se não houver esse campo ainda, é mais fácil extrair via regex do body num alerta SQL, ou adicionar o campo estruturado no app.
  - CrashLoopBackOff/OOM: stream infrastructure_metrics, watchar k8s.container.restarts (do kubeletstats) subindo, ou logar diretamente por padrão de mensagem do kubelet em infra_logs.
  - Disco cheio: stream infrastructure_metrics, métrica de filesystem (hostmetrics) > 80%.

Dashboard de timings: como checkup/plinth já mandam OTLP pra application_traces, no OpenObserve vá em Traces → você já tem span duration nativamente pesquisável/plotável. Pra um dashboard dedicado: Dashboards → New → adicione painéis com queries SQL sobre a stream application_traces agregando duration por service.name/operation (p50/p95/p99 via approx_percentile_cont).
