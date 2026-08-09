{ config, pkgs, ... }:

{
  # State version
  system.stateVersion = "24.11";

  # LTS em vez de `linuxPackages_latest`. O `_latest` trazia 7.1.3; nao havia
  # motivo de hardware para estar na ponta -- a NIC e virtio_net e a CPU e uma
  # Neoverse N1 (ARMv8.2), ambas suportadas ha muitas versoes. LTS troca reboot
  # frequente e risco de regressao por previsibilidade.
  boot.kernelPackages = pkgs.linuxPackages;

  # Desliga a zeragem de heap em toda alocacao.
  #
  # O kernel do NixOS sobe com `mem auto-init: stack:all(zero), heap alloc:on`,
  # que e o mesmo default do Ubuntu 22.04/24.04 -- ou seja, nas opcoes caras a
  # config ja era equivalente. Isto aqui vai ALEM do Ubuntu: `init_on_alloc=0`
  # remove o memset de toda alocacao de slab/pagina, que num proxy e pago uma
  # vez por skb. `page_poison=0` desliga o CONFIG_PAGE_POISONING, que o Ubuntu
  # nem compila.
  #
  # O que NAO da para mexer por boot param, e por isso ficou de fora:
  #   - INIT_STACK_ALL_ZERO   -> so em tempo de compilacao
  #   - PREEMPT full          -> CONFIG_PREEMPT_DYNAMIC nao esta setado, entao
  #                              nao existe `preempt=voluntary` aqui
  #   - LIST_HARDENED, HARDENED_USERCOPY, RANDOM_KMALLOC_CACHES -> idem
  # Tirar esses exigiria `structuredExtraConfig`, o que significa compilar
  # kernel em 2 cores N1 e sair do cache binario para sempre. Nao compensa.
  #
  # Custo de seguranca assumido: heap nao inicializada volta a poder vazar
  # conteudo de alocacao anterior por bug de use-of-uninitialized. Aceitavel
  # aqui porque a superficie exposta e so o tunel Cloudflare.
  #
  # Medido nesta VPS, mediana de 3 repeticoes, antes (7.1.3) -> depois (6.18.38
  # + params). Arquivos em ~/bench-antes.txt e ~/bench-depois2.txt no no:
  #
  #   MICRO   mmap+touch          3407 -> 3854 MB/s   +13,1%  <- sonda do init_on_alloc
  #           syscall getpid      9,58 -> 10,47 M/s    +9,3%  <- ganho do kernel, nao do param
  #           tcp loopback RT    41283 -> 43133/s      +4,5%
  #   MACRO   plinth direto      34020 -> 40476 rps   +19,0%
  #           router -> plinth   16301 -> 17111 rps    +5,0%
  #           router /healthz    72980 -> 76393 rps    +4,7%
  #           router TLS         13111 -> 13734 rps    +4,8%
  #   CONTROLE AES-128-GCM        2,78 -> 2,77 GB/s    -0,4%  (inalterado, offload intacto)
  #
  # Atencao ao medir de novo: a primeira rodada pos-reboot deu -35% em
  # /healthz com variancia de 20%. Era ruido -- flux e openobserve ainda
  # digerindo o boot. Espera load1 < 0,10 antes de confiar no numero, e ignora
  # load5/load15, que ficam inflados pelo proprio wrk da rodada anterior.
  boot.kernelParams = [ "init_on_alloc=0" "init_on_free=0" "page_poison=0" ];

  # Networking
  networking.hostName = "oracle";
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network.networks."10-enp0s6" = {
    matchConfig.Name = "enp0s6";
    networkConfig.DHCP = "yes";
  };

  # Set time zone and locales
  time.timeZone = "America/Sao_Paulo";
  i18n.defaultLocale = "pt_BR.UTF-8";

  # User accounts

  users.users.lucas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "k3sconfig" ]; # Enable ‘sudo’ for the user.
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDKoegVux238kUTvIqRW/tYUQWzGBNspA2t8lnlP19xvPlVvn1TvXLeZBAek3bifDD1LXv8YBkMrjKAITcYnaibVA7pxbs01fmwP1SmwWVfF0B2fq5e3nWlSaAmMxT2JBvNV0iSEn9Xh/l6tWtWW3gBp8J3vwI93q7wXvLD4P6aYrDulyoa5q0EXReLoSpVGwl+udwKTDM1XyVIyCAEdm2satmWZUvGdPDuBINV3KwoGfgaDHDpBDw2EyUM6kFbWFFUOuySfWzGeWHwctlf4fvFYrbRyWOQ4HmgS/TSO+R2UkBJsevLiXw6/Y+uNKG//7QMI3/VLbmL8oqgRZNZ3dzB ssh-key-2026-07-01"
    ];
  };

  # Enable passwordless sudo for 'wheel' group
  security.sudo.wheelNeedsPassword = true;

  # Enable the OpenSSH daemon
  services.openssh = {
    enable = true;
    openFirewall = false; # Do not open port 22 publicly
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Firewall
  networking.firewall = {
    enable = true;
    # 443 exposta na internet publica para o router nginx (kubernetes/apps/router),
    # servindo *.sh-lucas.dev direto, sem passar pelo tunel da Cloudflare.
    # Abrir aqui nao basta: a cadeia public-block abaixo dropa tudo que entra por
    # enp0s6 antes desta regra valer, entao ha um ACCEPT correspondente la.
    allowedTCPPorts = [ 443 ];
    allowedUDPPorts = [ 41641 ]; # Tailscale direct connections
    trustedInterfaces = [ "tailscale0" "cni0" "flannel.1" ]; # Trust Tailscale and K3s interfaces

    # Bloqueia absolutamente tudo vindo da internet pública (enp0s6) no mangle PREROUTING,
    # antes do K3s interceptar tráfego via NAT, permitindo apenas conexões de saída (respostas),
    # tráfego direto do Tailscale (UDP 41641) e DHCP (UDP 68).
    #
    # Também filtra o tráfego da Tailscale no mangle PREROUTING para permitir apenas SSH, DNS,
    # HTTPS e a API do Kubernetes, dropando o resto antes que o K3s faça DNAT.
    extraCommands = ''
      # --- Bloco da Internet Pública (enp0s6) ---
      iptables -t mangle -N public-block 2>/dev/null || true
      iptables -t mangle -F public-block
      
      iptables -t mangle -A public-block -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      iptables -t mangle -A public-block -p udp --dport 41641 -j ACCEPT
      iptables -t mangle -A public-block -p udp --dport 68 -j ACCEPT
      # HTTPS publico para o router nginx. Precisa estar aqui alem do
      # allowedTCPPorts: esta cadeia roda antes, no mangle PREROUTING, e o DROP
      # final descartaria o pacote antes de o K3s fazer o DNAT.
      iptables -t mangle -A public-block -p tcp --dport 443 -j ACCEPT
      iptables -t mangle -A public-block -j DROP
      
      iptables -t mangle -D PREROUTING -i enp0s6 -j public-block 2>/dev/null || true
      iptables -t mangle -A PREROUTING -i enp0s6 -j public-block

      # --- Bloco do Tailscale (tailscale0) ---
      iptables -t mangle -N tailscale-block 2>/dev/null || true
      iptables -t mangle -F tailscale-block
      
      iptables -t mangle -A tailscale-block -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      iptables -t mangle -A tailscale-block -p tcp --dport 22 -j ACCEPT
      iptables -t mangle -A tailscale-block -p tcp --dport 53 -j ACCEPT
      iptables -t mangle -A tailscale-block -p udp --dport 53 -j ACCEPT
      iptables -t mangle -A tailscale-block -p tcp --dport 443 -j ACCEPT
      iptables -t mangle -A tailscale-block -p tcp --dport 6443 -j ACCEPT
      iptables -t mangle -A tailscale-block -j DROP
      
      iptables -t mangle -D PREROUTING -i tailscale0 -j tailscale-block 2>/dev/null || true
      iptables -t mangle -A PREROUTING -i tailscale0 -j tailscale-block
    '';
  };

  # Services
  services.tailscale.enable = true;
  systemd.services.tailscaled.serviceConfig = {
    OOMScoreAdjust = -1000;
    Nice = -10;
  };

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--write-kubeconfig-mode 640"
      "--write-kubeconfig-group k3sconfig"
      "--tls-san ${config.networking.hostName}"
      "--disable metrics-server"
      "--secrets-encryption"
      "--secrets-encryption-provider=secretbox"
    ];
  };
  # Grupo de acesso ao kubeconfig
  users.groups.k3sconfig = {};

  # Proxies para expor o CoreDNS na interface do Tailscale
  systemd.services.coredns-tailscale-proxy-udp = {
    description = "CoreDNS Tailscale UDP Proxy";
    after = [ "network.target" "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat UDP-LISTEN:53,bind=100.72.43.20,fork UDP:10.43.0.10:53";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  systemd.services.coredns-tailscale-proxy-tcp = {
    description = "CoreDNS Tailscale TCP Proxy";
    after = [ "network.target" "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:53,bind=100.72.43.20,fork TCP:10.43.0.10:53";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # Garante de forma declarativa que o certificado do K3s seja regenerado
  # caso o hostname mude.
  systemd.services.k3s = {
    preStart = ''
      CERT_FILE="/var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt"
      if [ -f "$CERT_FILE" ]; then
        # Se o hostname nao estiver no certificado, removemos para recriar
        if ! ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -text -noout | grep -q "${config.networking.hostName}"; then
          echo "Hostname nao encontrado no certificado do K3s. Removendo para forcar regeneracao..."
          rm -f "$CERT_FILE"
        fi
      fi
    '';
  };


  # Virtualisation
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true; # Emula o socket do Docker em /run/docker.sock
  };
  # K3s registry auth: managed manually on the server at /etc/rancher/k3s/registries.yaml
  # Local backup copy: ./registries.yaml (gitignored)

  # Programs / Shell integrations
  programs.bash.interactiveShellInit = ''
    eval "$(zoxide init bash --cmd cd)"
    if [ "$UID" -ne 0 ]; then
      alias lazydocker="DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock lazydocker"
    fi
  '';

  # Memory & Performance (zram Swap)
  zramSwap = {
    enable = true;
    memoryPercent = 50; # 6GB of swap for a 12GB instance
  };

  # Network Performance Optimizations (TCP BBR + Fair Queueing + Fast Socket Reuse)
  boot.kernel.sysctl = {
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.ipv4.tcp_tw_reuse" = 1;
  };

  # Nix settings (Flakes, garbage collection)
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "root" "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  # Environment variables
  environment.variables = {
    KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  };


  # Essential packages
  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    curl
    htop
    tmux
    btop
    lazydocker
    zoxide
    micro
    docker-compose
    podman-compose
    kubectl
  ];
}
