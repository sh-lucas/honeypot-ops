# Plano de implementação: observabilidade integrada

## Objetivo

Adicionar observabilidade profissional e de baixa manutenção ao `rust-tmpl` e ao k3s do `oracle-cloud`, cobrindo:

- logs estruturados e pesquisáveis;
- métricas da aplicação e do cluster;
- traces de requests, handlers, workers e operações SQLite;
- detecção confiável de queries lentas;
- profiling manual de CPU e memória quando uma métrica indicar um problema.

A stack permanente terá somente dois componentes novos:

1. OpenTelemetry Collector para receber, enriquecer e encaminhar telemetria.
2. OpenObserve single-node para armazenar, consultar e visualizar os dados.

Não serão adicionados Prometheus, Grafana, Loki, Tempo, sidecars por aplicação ou uma plataforma separada de profiling.

## 1. Módulo de observabilidade do `rust-tmpl`

Criar `src/observability/` como um módulo de infraestrutura plano, sem traits ou abstrações desnecessárias.

### Inicialização

- Uma função `observability::init(&ObservabilityConfig) -> ObservabilityGuard` configura logs, traces e métricas.
- `ObservabilityGuard` executa o flush da telemetria no graceful shutdown com timeout curto.
- Se o Collector estiver indisponível, a aplicação continua atendendo normalmente e mantém os logs em `stdout`.
- Exportação OTLP usa batches assíncronos, fila limitada e timeout para nunca introduzir espera remota no hot path.

### Logs estruturados

- Substituir `println!` e o middleware `BasicLog` por `tracing`.
- Escrever JSON em `stdout` como única fonte dos logs da aplicação.
- Cada evento terá, quando aplicável:
  - timestamp, nível, target e mensagem;
  - serviço, versão e ambiente;
  - request ID, trace ID e span ID;
  - campos tipados próprios do evento.
- Não registrar authorization, cookies, senhas, JWTs, conteúdo completo de requests, parâmetros SQL ou a URL do banco.
- Controlar verbosidade por `RUST_LOG`, sem implementar reload dinâmico inicialmente.

O Collector lerá o `stdout` do pod uma única vez. A aplicação não exportará logs por OTLP, evitando duplicação.

### Requests, handlers e workers

- Substituir `BasicLog` por um middleware HTTP que crie um span para cada request.
- Registrar método, rota normalizada, status, duração e request ID.
- Produzir métricas RED por rota:
  - quantidade de requests;
  - erros;
  - histograma de duração;
  - requests em andamento.
- Usar o template da rota, nunca a URI completa, como atributo de métrica para limitar cardinalidade.
- Instrumentar handlers e workers importantes com `#[tracing::instrument]`, usando `skip(...)` para pools, configurações, payloads e secrets.
- Não instrumentar automaticamente toda função. Novos spans serão adicionados apenas em fronteiras relevantes ou em trechos comprovadamente caros.

### SQLite e SQLx

- Ativar a integração nativa do SQLx com `tracing`.
- Configurar `log_slow_statements` com limiar vindo de ambiente e padrão inicial de 250 ms.
- Toda query acima do limiar emitirá um evento `WARN` correlacionado ao request ou worker que a executou, incluindo duração e resumo sanitizado da operação, nunca os parâmetros.
- Manter logs normais de query desabilitados em produção; eles poderão ser habilitados temporariamente por `RUST_LOG` durante uma investigação.
- Expor métricas simples do pool: conexões ativas, ociosas e tamanho total.
- Não criar repository genérico, macro obrigatória ou wrapper ao redor de cada query. O SQLx continua sendo usado diretamente nos handlers.

Isso garante que uma query SQLite de dois segundos seja detectada sem exigir disciplina manual em cada novo call site.

### Configuração

Adicionar à configuração da aplicação:

- `OTEL_SERVICE_NAME`, com padrão baseado no nome do crate;
- `OTEL_SERVICE_VERSION`, com padrão baseado na versão do crate;
- `DEPLOYMENT_ENVIRONMENT`, com padrão `development`;
- `OTEL_EXPORTER_OTLP_ENDPOINT`, opcional fora do cluster;
- `OTEL_TRACES_SAMPLER_ARG`, com padrão conservador em produção;
- `SLOW_QUERY_THRESHOLD_MS`, com padrão `250`;
- `RUST_LOG`, com filtro padrão seguro.

Não colocar credenciais do OpenObserve na aplicação. Apenas o Collector conhecerá essas credenciais.

## 2. Coleta no k3s

Implantar OpenTelemetry Collector Contrib como `DaemonSet`. No cluster atual haverá um único pod, mas o formato continuará correto caso novos nós sejam adicionados.

O Collector terá três pipelines:

### Logs

- Ler logs CRI de `stdout/stderr` dos containers com `filelog`.
- Interpretar o JSON emitido pela aplicação Rust.
- Anexar namespace, pod, deployment, container e node.
- Manter logs não estruturados de componentes do k3s como texto pesquisável.
- Excluir apenas ruído comprovado, sem filtros amplos que possam ocultar falhas.

### Métricas

- Receber métricas OTLP das aplicações.
- Coletar CPU, memória, filesystem, rede e reinícios de node, pod e container por `kubeletstats` e `hostmetrics`.
- Coletar métricas internas do próprio Collector para identificar fila cheia ou exportações descartadas.
- Não instalar Prometheus nem kube-state-metrics na primeira versão.

### Traces

- Receber OTLP das aplicações.
- Aplicar atributos Kubernetes.
- Processar em batch e encaminhar ao OpenObserve.

Todos os pipelines terão `memory_limiter`, `batch`, retry com backoff e filas limitadas. Se o OpenObserve estiver temporariamente indisponível, o Collector absorverá uma interrupção curta sem crescer memória indefinidamente.

## 3. OpenObserve

Implantar OpenObserve como `StatefulSet` single-node ARM64 em namespace próprio.

- Usar imagem fixada por versão, nunca `latest`.
- Persistir dados em PVC local.
- Configurar readiness/liveness probes e requests/limits compatíveis com o VPS de 12 GB.
- Ler usuário e senha de um `Secret` criado fora do Git, seguindo o processo atual do repositório.
- Receber logs, métricas e traces somente do Collector pela rede interna do cluster.
- Expor a interface exclusivamente pela Tailscale usando o entrypoint Traefik `websecure` existente.
- Não criar rota pelo túnel Cloudflare nem alterar firewall, Podman ou TLS existentes.
- Começar com retenção de 14 dias para logs/traces e 30 dias para métricas, ajustável depois de medir o consumo real.

Criar uma configuração inicial pequena:

- dashboard de requests, erros e latência por serviço/rota;
- dashboard de CPU, memória, restarts e uso de disco do cluster;
- visão de slow queries baseada nos eventos do SQLx;
- alertas para taxa elevada de erro, p95 alto, query lenta, OOM/restarts, disco alto e falhas do Collector.

## 4. Profiling sob demanda

Tracing mede tempo de parede e mostra em qual handler ou operação o request ficou lento. Métricas mostram quando CPU ou memória ficaram anormais. Nenhum dos dois identifica sozinho a função exata responsável pelo consumo de CPU.

Para essa investigação:

- manter símbolos de debug separados para a imagem release ou produzir uma variante de profiling do mesmo commit;
- habilitar frame pointers nessa variante para stacks confiáveis;
- fornecer comandos documentados para capturar um perfil curto com `perf` ou `pprof` dentro de uma janela controlada;
- gerar flamegraph localmente e associá-lo à versão/commit investigado;
- usar profiling de alocações somente na variante de profiling ou em teste de carga, sem trocar o allocator da aplicação normal.

Não haverá daemon de profiling contínuo. Se no futuro os incidentes de CPU forem frequentes e não reproduzíveis, continuous profiling poderá ser avaliado como uma etapa separada, sem complicar a primeira versão.

## 5. Testes e critérios de aceite

### Aplicação Rust

- Testar configuração e fallback sem Collector.
- Confirmar que cada request gera exatamente um log de conclusão.
- Confirmar propagação de request ID e correlação entre log, trace, handler e query.
- Confirmar métricas HTTP com rotas normalizadas e cardinalidade limitada.
- Executar uma query artificialmente lenta e verificar o `WARN` após o limiar configurado.
- Verificar que tokens, senhas, payloads e parâmetros SQL não aparecem nos logs.
- Simular Collector indisponível e confirmar que requests não bloqueiam e memória não cresce sem limite.
- Validar graceful shutdown, `cargo fmt --check`, Clippy, testes e build release.

### Infraestrutura

- Validar manifests com Kustomize e conferir RBAC e NetworkPolicies.
- Validar a configuração NixOS sem executar `make deploy` ou comandos com `sudo`.
- Após o Flux reconciliar, confirmar no OpenObserve:
  - logs da aplicação sem duplicatas;
  - logs do k3s pesquisáveis;
  - métricas de aplicação, pod e node;
  - trace completo de um request;
  - slow query correlacionada ao trace;
  - UI acessível pela Tailscale e inacessível pela Cloudflare.
- Fazer teste de carga comparativo e usar como meta inicial overhead inferior a 3% de CPU, sem crescimento não limitado de memória.

## Ordem de implementação

1. Criar o módulo Rust, substituir `BasicLog` e instrumentar HTTP, SQLx e workers.
2. Adicionar e validar testes locais de logs, métricas, traces e slow queries.
3. Implantar OpenObserve e Collector no `oracle-cloud`.
4. Conectar uma aplicação do template ao endpoint interno do Collector.
5. Validar os três sinais de ponta a ponta e eliminar qualquer duplicação.
6. Adicionar dashboards, alertas e o procedimento manual de profiling.

## Decisões e limites

- OpenObserve será a única interface e armazenamento de observabilidade.
- O Collector será o único caminho autenticado de ingestão no OpenObserve.
- `stdout` será a única fonte de logs da aplicação.
- SQLx continuará direto e data-driven, sem repository ou wrapper obrigatório.
- Profiling será manual e sob demanda.
- Alta disponibilidade, armazenamento externo e SOPS ficam fora desta implementação inicial.
