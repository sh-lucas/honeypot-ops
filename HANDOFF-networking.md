# Handoff — custo de CPU do caminho de rede (sessão 08–09/08/2026)

Arquivo **não commitado** e não versionado. Serve de estado para retomar depois.

**Conclusão em uma linha:** a networking do cluster está mais cara do que deveria,
e o custo extra está **inteiramente no caminho de ingresso do pacote vindo da NIC
real** — não no k3s de forma difusa, não no app, não no firewall.

---

## 1. Método (para os números serem comparáveis)

Tudo que vale nesta página foi medido assim:

- CPU = `user + nice + system + irq + softirq + steal` do `/proc/stat`, ou seja
  **máquina inteira, kernel incluído**;
- **janela ociosa de controle** medida logo antes e subtraída;
- CPU do gerador de carga descontada, ou o gerador rodando **na outra máquina**;
- normalizado como **% de 1 core por 1000 rps** = `(µs/req) ÷ 10`;
- app idêntico nas duas máquinas (mesma imagem `plinth`, mesmo endpoint `/`,
  27 bytes de JSON, health que não toca SQLite).

Máquinas: ambas Ampere A1 (Neoverse-N1), 2 OCPU, `sa-saopaulo-1`, mesmo subnet
`10.0.0.0/24`, steal desprezível (0,16% e 0,25%).

- `catnip-cloud` / `oracle` — 10.0.0.91, NixOS, k3s, kernel 6.18.38
- `network-degradation` — 10.0.0.134 / 147.15.91.95, Ubuntu, sem k3s, kernel 6.17

---

## 2. O resultado principal

| | carga local (loopback) | carga externa (NIC real) | **delta da NIC** |
|---|---:|---:|---:|
| VM nova (sem k3s) | 6,1% | 11,9% | **+5,8 pontos** |
| Cluster k3s | 6,3% | 19,0% | **+12,7 pontos** |

**No loopback as duas máquinas empatam (6,1% vs 6,3%).** O k3s não custa nada ali.
Todo o buraco aparece quando o pacote entra pela `enp0s6`: a NIC custa **57,3 µs/req**
na VM nova e **126,1 µs/req** no cluster — **2,2×**.

Caminho medido nos dois casos: nginx termina TLS → proxy → plinth.

Como é custo **por pacote**, qualquer coisa que aumente a contagem de pacotes
(resposta maior, handshake TLS novo, keepalive expirando) multiplica 126 µs no
cluster contra 57 µs na VM. É a explicação da degradação em rotas mais lentas.

### Decomposição do caminho externo do cluster (189,6 µs/req)

```
nginx router          43,1 µs   (4,3%)
plinth                15,9 µs   (1,6%)
sem dono em cgroup   130,6 µs  (13,1%)   <- 69% do total
                     --------
                     189,6 µs  (19,0% por 1000 rps)
```

Na VM nova, `nginx 77,4 + plinth 41,6 = 119,0` contra 118,7 medidos — **sobra ~zero**.
O nginx lá parece "caro" só porque roda com `--network host` e absorve o softirq
dentro do próprio cgroup. **Não compare a coluna "nginx" de uma máquina com a da
outra**; só o total é comparável.

### O que já foi isolado dentro dos 130,6 µs

Medido de dentro do oracle, mesmo TLS, mesmo backend:

| caminho | rps | µs/req | % / 1000 rps |
|---|---:|---:|---:|
| via svclb (443 do host → pod svclb → router) | 22.474 | 63,5 | 6,3% |
| direto no pod do router (`10.42.0.x:8443`) | 29.027 | 44,1 | 4,4% |

**O hop do klipper-lb custa 19,4 µs/req e 29% de vazão.** Real, mas não explica os
130,6 µs sozinho — e foi medido em loopback, onde cada travessia é mais barata que
com pacote de NIC real.

Contraprova de que o caminho de pod em si é barato: nginx dentro de pod, resposta
trivial, carga local → **78.363 rps a 6,9 µs/req**. Atravessa flannel, cni0, veth,
NetworkPolicy e kube-proxy. Portanto **130 µs não é "custo normal de CNI"**.

---

## 3. O cloudflared

| caminho | % de 1 core / 1000 rps |
|---|---:|
| via túnel Cloudflare | **~63%** |
| direto na 443, sem túnel | **19,0%** |

**O túnel respondia por ~70% do custo do caminho de entrada** (~44 dos 63 pontos).
Boa parte disso é softirq de UDP/QUIC contra o edge, que não aparece em cgroup.

Na VM de teste isolada o cloudflared saiu ainda pior: **580–598 µs/req** contra
~220 µs/req do cluster — mas medido a ~1.000 rps contra 2.308 rps, então parte da
diferença é falta de amortização, não ambiente.

Teto do túnel na VM nova: **~1.050 rps**, independente de concorrência.
`keepAliveConnections` 100 → 1000 tirou o colapso em alta concorrência
(354 → 1.073 rps, 148 erros → 0) mas **não moveu o teto**. Com 400 conexões voltou
a degradar (702 rps, 282 timeouts) com a CPU caindo para 26% — fila, não CPU.
Suspeito: as 4 conexões QUIC com o edge (`connIndex=0..3`, padrão).

---

## 4. Descobertas laterais que continuam valendo

- **`limits.cpu: 50m`** em `hello-world` e `checkup` = teto rígido de **452 rps**.
  Medido: `nr_throttled=738`, `throttled_usec=89.686.977` (89,7 s parado). Bater
  direto no IP do pod, sem Traefik nem Service, dá os mesmos 452 rps. É a causa das
  "rotas lentas de 1-3k", e não tem nada a ver com o caminho de entrada.
- **Soma dos `requests` = 1.575m num nó de 2 cores** (79% comprometido). Pods com
  10m de request ficam com peso residual sob disputa.
- **NetworkPolicy / firewall interno: inocentes.** nginx dentro de pod (atravessando
  netpol, CNI, kube-proxy) foi **mais rápido** que o mesmo nginx no loopback do host
  (78.363 vs 61.688 rps). Controlei `reuseport`, que era o confundidor óbvio.
- **Traefik vs nginx:** 32,0 vs 6,9 µs/req de CPU de processo em resposta trivial, no
  mesmo nó e mesmo netns — **4,6×**. Confirma a medição que já estava no repo
  (254 vs 79 µs/req).
- **Traefik `/ping` (2 bytes) = 31.406 rps**, mais lento que o plinth servindo JSON
  real (40.390 rps).
- **Diferença entre as VMs:** ~10% por requisição (nginx idêntico do nixpkgs:
  24,3 vs 27,9 µs/req). Não é hardware — mesmo Neoverse-N1, mesmo BogoMIPS, mesmas
  mitigações. **Não consegui separar** quanto é kernel 6.17 vs 6.18, quanto é a carga
  de fundo do k3s (4,7%) e quanto são hooks de netfilter.

---

## 5. Estado atual da infra

### Cluster — mudanças commitadas e no ar

| commit | o que fez |
|---|---|
| `991121d` | reverteu `d81cec1`: 443 direto, Traefik solta `websecure`, NixOS abre 443 |
| `818f119` | router serve registry e observe no listener 8443 |
| `674834a` | corrigiu o filtro de IP (faixa privada, não CGNAT) |
| `41ae6af` | liberou o router nas NetworkPolicies de registry e observe |

Verificado funcionando:

| | Tailscale | internet pública |
|---|---|---|
| `registry.sh-lucas.dev` | 401 (pede credencial) | **403** |
| `observe.sh-lucas.dev` | 308 | **403** |
| `plinth` / `hello-world` | 200 | 200 |

`podman pull` pela Tailscale funciona; `image-reflector` do Flux voltou a escanear.

**O cloudflared continua de pé e continua servindo todo o tráfego público real**,
porque o DNS não mudou — `plinth/bench/registry.sh-lucas.dev` resolvem para
`104.21.14.129` e `172.67.159.41` (proxy da Cloudflare). O caminho direto na 443
existe e funciona, mas nada real usa. Os testes "pela internet" desta sessão usaram
`curl --resolve` forçando `147.15.105.66`.

Nada foi alterado em `hello-world` (o `patch` do limite foi bloqueado; segue 50m).

### VM de teste — sujeira deixada

| item | como reverter |
|---|---|
| nix (single-user), podman | `sudo rm -rf /nix`, `apt remove podman` |
| container `plinth` na 9090 | `podman rm -f plinth` |
| nginx: 443 TLS→plinth, 8444, stub otel na 4318 | remover sites de `/etc/nginx/sites-enabled` |
| cloudflared como serviço systemd, **com o token no unit** | `sudo cloudflared service uninstall` |
| CA local `bench-local-ca` no trust store | `sudo rm /usr/local/share/ca-certificates/bench-local-ca.crt && sudo update-ca-certificates --fresh` |
| `iptables` 443 e 9443 | só em memória, reboot desfaz |
| `sysctl net.ipv4.ip_unprivileged_port_start=443` | não persistido |
| `loginctl enable-linger ubuntu` | `sudo loginctl disable-linger ubuntu` |
| `/etc/hosts`: `10.0.0.91 plinth.sh-lucas.dev` | remover a linha |

**Rotacionar o token do túnel Cloudflare** — foi colado no chat e gravado no unit
do systemd da VM.

---

## 6. Fios soltos

1. **`hostPort: 443` no pod do router**, eliminando o `svclb`. Ganho já medido em
   loopback: 19,4 µs/req. Falta medir no caminho de NIC real, onde deve ser maior.
   **É o próximo passo mais barato e com maior retorno esperado.**
2. **Os 126,1 µs de NIC no cluster** continuam sem decomposição fina. Faltou `perf`
   / `/proc/softirqs` sob carga (precisa de sudo, que pede senha no oracle).
3. **A/B do kernel.** A geração `system-38` (kernel 7.1.3, `init_on_alloc=1`) ainda
   está no store. Um `nixos-rebuild switch` para ela + reboot permitiria repetir o
   teste idêntico e separar kernel de método. Custa um reboot do cluster.
   Isso responderia "o que mudou desde anteontem", junto com: os "6-7k rps" antigos
   eram do **Traefik**, não do nginx, e o gerador era o link de casa (variação de 3×
   documentada no `d81cec1`).
4. **Arrancar o cloudflared** (decidido, adiado): apontar A → `147.15.105.66` com
   proxy desligado para plinth/checkup/hello-world, **não** para registry/observe,
   e depois `kubectl -n cloudflare scale deploy/cloudflared --replicas=0`.
5. **Nunca medido:** o cluster com nginx sozinho recebendo por NIC real **sem TLS**,
   para separar o custo de TLS do custo de rede.

---

## 7. Mecanismo dos 2,2× — medido, não teorizado

Contagem de pacotes por interface durante carga externa, normalizada pelo `enp0s6`
(2 pacotes por requisição: um de ida, um de volta), o que dá o numero de requests
sem depender do output do gerador.

### Travessias de pilha de rede por requisição

| interface | cluster k3s | VM nova |
|---|---:|---:|
| `enp0s6` | 2,00 | 2,00 |
| `cni0` | 2,00 | — |
| veth do plinth | 2,01 | — |
| veth do router | **4,01** | — |
| `lo` (nginx↔plinth) | — | 4,01 |
| **total** | **10,0** | **6,0** |

- Cluster: **10 travessias por requisição**. VM: **6**. Razao 1,67×.
- As 4 travessias extras do cluster nao equivalem as da VM. As da VM sao no `lo`,
  MTU 65536, checksum dispensado. As do cluster sao em `veth`/`cni0`, MTU 1450.
- Cada travessia de netns via veth **reexecuta o caminho de recepcao inteiro** no
  namespace de destino: `netif_rx` → softirq NET_RX → camada IP → conntrack →
  netfilter → avaliacao de NetworkPolicy.
- 1,67× de travessias, cada uma mais cara que a da VM → os **2,2× de CPU** medidos
  no caminho de NIC real (126,1 vs 57,3 µs/req). Mecanismo fecha.
- O `veth594ef9ab` com 4,01 e o do router: recebe do cliente, manda pro plinth,
  recebe a resposta, devolve. Quatro passagens no mesmo par de veth.

### MTU — achado novo, não contaminou as medições desta sessão

```
oracle   enp0s6 = 1500     lo = 65536   flannel.1 = 1450   cni0 = 1450   veth* = 1450
VM nova  enp0s6 = 9000     lo = 65536
tailscale0 = 1280
```

- **A VM esta com jumbo frames (9000) e o host do k3s nao (1500).** A OCI entrega
  9000 via DHCP; o cloud-image do Ubuntu aplica, a config do NixOS aparentemente
  ignora.
- Na resposta de 27 bytes usada nos testes isso **nao muda a contagem de pacotes**,
  entao nenhuma medicao desta sessao foi afetada. Em trafego real com payload
  grande, o oracle fragmenta em ~6× mais pacotes que a VM pelo mesmo byte.
- Ajuste de uma linha no `configuration.nix`. Candidato forte a ganho real, ainda
  **nao medido**.
- `cni0`/`flannel.1` em 1450 e default do flannel, que reserva 50 bytes para
  encapsulamento VXLAN. **O cluster tem um no so — nunca sai VXLAN.** Esses 50
  bytes estao sendo pagos a toa e dao para ser recuperados.

Note: não é a causa principal, mas essa fragmentação eu já tinha sentido antes.
Ping/"GET /" sempre foi estável, mas qualquer payload maiorzinho costuma gerar degradação muito mais rápido nos benchmarks.

### Por que o nginx gasta mais CPU que a aplicação

Observado nas medicoes antigas e reproduzido aqui (nginx 43,1 µs vs plinth 15,9 µs
no cluster). Não é anomalia:

- o proxy mantem **duas** conexoes TCP por requisicao (cliente e upstream) e paga a
  pilha de rede duas vezes; a aplicacao paga uma;
- faz cripto de registro TLS e copia bytes entre dois sockets;
- "bater no SQLite" custa menos CPU do que a intuição sugere: leitura vinda do page
  cache e da ordem de microssegundos, escrita e batched pelo WAL, e parsear body
  grande roda na velocidade de `memcpy`.

No cluster isso piora porque **cada uma das duas pontas do proxy carrega as
travessias extras** acima. Parte dos 43,1 µs e encanamento, nao nginx.

### Por que NIC real custa mais que loopback (isso e normal, nao defeito)

- `lo` tem MTU 65536: requisicao e resposta cabem em um skb; sem driver, sem DMA,
  sem interrupcao, sem checksum (`CHECKSUM_UNNECESSARY`); vai da fila do socket
  emissor direto para a do receptor, com cache quente.
- `enp0s6` tem IRQ → NAPI → softirq, ring buffer do virtio e, por ser VM,
  notificacao do virtio que pode custar vmexit.
- ~2× aqui e esperado. O que **nao** e esperado sao os 2,2× adicionais do cluster
  sobre a VM no mesmo caminho de NIC real.
