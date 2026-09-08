set positional-arguments := true
set shell := ["bash", "-euo", "pipefail", "-c"]

remote := "lucas@oracle"
stage := "/tmp/nixos-config"
export SOPS_EDITOR := env_var_or_default("SOPS_EDITOR", "micro")

# List the available project commands.
[private]
default:
    @just --list

# Deploy the NixOS configuration after copying it to the host.
[group('host')]
deploy: copy switch

# Copy the NixOS configuration and encrypted host secret to the VPS.
[group('host')]
copy:
    ssh {{ remote }} "mkdir -p {{ stage }}/secrets"
    scp nixos/flake.nix nixos/configuration.nix nixos/hardware-configuration.nix nixos/disko.nix nixos/flake.lock {{ remote }}:{{ stage }}/
    scp nixos/secrets/registries.sops.yaml {{ remote }}:{{ stage }}/secrets/

# Apply the staged NixOS configuration on the VPS.
[group('host')]
switch:
    ssh -t {{ remote }} "sudo cp -r {{ stage }}/* /etc/nixos/ && sudo nixos-rebuild switch --flake /etc/nixos#oracle && rm -rf {{ stage }}"

# Download the K3s kubeconfig without replacing a working copy on failure.
[group('cluster')]
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    destination="kubernetes/kubeconfig.yaml"
    temporary="$(mktemp "kubernetes/.kubeconfig.yaml.XXXXXX")"
    trap 'rm -f "$temporary"' EXIT
    ssh {{ remote }} "cat /etc/rancher/k3s/k3s.yaml" > "$temporary"
    sed -i 's/127.0.0.1/oracle/g' "$temporary"
    chmod 0600 "$temporary"
    mv "$temporary" "$destination"
    trap - EXIT
    echo "Kubeconfig salvo em $destination. Use: export KUBECONFIG=$PWD/$destination"

alias gkcfg := kubeconfig

# Validate that a secret path is local and covered by SOPS conventions.
[private]
_check-secret-path path:
    #!/usr/bin/env bash
    set -euo pipefail
    repository="$(pwd -P)"
    resolved="$(realpath -m -- "$1")"
    case "$resolved" in
      "$repository"/*) ;;
      *) echo "erro: o secret precisa ficar dentro do repositório" >&2; exit 2 ;;
    esac
    case "$1" in
      *.sops.yaml) ;;
      *) echo "erro: use um caminho terminado em .sops.yaml" >&2; exit 2 ;;
    esac
    relative="${resolved#"$repository"/}"
    case "$relative" in
      kubernetes/*.sops.yaml|nixos/secrets/*.sops.yaml|secrets/kubeconfig.sops.yaml) ;;
      *) echo "erro: nenhuma regra SOPS aprovada cobre este caminho: $1" >&2; exit 2 ;;
    esac

# Edit an existing encrypted secret with micro.
[group('secrets')]
secret-edit path: (_check-secret-path path)
    #!/usr/bin/env bash
    set -euo pipefail
    repository="$(pwd -P)"
    target="$(realpath -m -- "$1")"
    target="${target#"$repository"/}"
    test -f "$target" || { echo "erro: secret não encontrado: $target" >&2; exit 2; }
    nix develop ./nixos --command bash -c '
      set -euo pipefail
      set +e
      sops edit "$1"
      status=$?
      set -e
      if test "$status" -eq 200; then
        echo "Nenhuma alteração em $1."
        exit 0
      fi
      test "$status" -eq 0 || exit "$status"
      sops decrypt "$1" >/dev/null
      echo "Secret recriptografado e validado: $1"
    ' just-secret-edit "$target"

alias se := secret-edit

# Create a new encrypted secret with micro; Kubernetes name/namespace are optional.
[group('secrets')]
secret-create path name="" namespace="": (_check-secret-path path)
    #!/usr/bin/env bash
    set -euo pipefail
    repository="$(pwd -P)"
    target="$(realpath -m -- "$1")"
    target="${target#"$repository"/}"
    name="$2"
    namespace="$3"
    test ! -e "$target" || { echo "erro: o arquivo já existe: $target" >&2; exit 2; }
    directory="$(dirname -- "$target")"
    test -d "$directory" || { echo "erro: diretório não encontrado: $directory" >&2; exit 2; }
    nix develop ./nixos --command bash -c '
      set -euo pipefail
      target="$1"
      name="$2"
      namespace="$3"
      directory="$(dirname -- "$target")"
      temporary="$(mktemp --tmpdir="$directory" ".$(basename -- "$target").XXXXXX.sops.yaml")"
      trap '\''rm -f -- "$temporary"'\'' EXIT
      case "$target" in
        kubernetes/*)
          test -n "$name" || name="$(basename -- "$target" .sops.yaml)"
          test -n "$namespace" || namespace="$(basename -- "$directory")"
          [[ "$name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || { echo "erro: nome Kubernetes inválido: $name" >&2; exit 2; }
          [[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "erro: namespace Kubernetes inválido: $namespace" >&2; exit 2; }
          printf "apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\nstringData:\n  replace-me: replace-me\n" "$name" "$namespace" |
            sops encrypt --filename-override "$target" --input-type yaml --output-type yaml /dev/stdin > "$temporary"
          ;;
        nixos/secrets/*)
          test -z "$name$namespace" || { echo "erro: nome e namespace só se aplicam a Secrets Kubernetes" >&2; exit 2; }
          printf "value: replace-me\n" |
            sops encrypt --filename-override "$target" --input-type yaml --output-type yaml /dev/stdin > "$temporary"
          ;;
        *)
          echo "erro: este caminho só aceita edição, não criação genérica: $target" >&2
          exit 2
          ;;
      esac
      set +e
      sops edit "$temporary"
      status=$?
      set -e
      if test "$status" -eq 200; then
        echo "Criação cancelada; nenhum arquivo foi gravado."
        exit 0
      fi
      test "$status" -eq 0 || exit "$status"
      sops decrypt "$temporary" >/dev/null
      if sops decrypt "$temporary" | grep -F -- "replace-me" >/dev/null; then
        echo "erro: substitua todos os placeholders replace-me antes de salvar" >&2
        exit 2
      fi
      test ! -e "$target" || { echo "erro: o destino apareceu durante a edição: $target" >&2; exit 2; }
      mv -- "$temporary" "$target"
      trap - EXIT
      echo "Secret criado e validado: $target"
    ' just-secret-create "$target" "$name" "$namespace"

alias sc := secret-create

# Check every tracked or untracked SOPS file without printing plaintext.
[group('secrets')]
secret-check:
    #!/usr/bin/env bash
    nix develop ./nixos --command bash -c '
      set -euo pipefail
      count=0
      while IFS= read -r -d "" file; do
        sops decrypt "$file" >/dev/null
        count=$((count + 1))
      done < <(git ls-files -z --cached --others --exclude-standard -- "*.sops.yaml" ":(exclude).sops.yaml")
      test "$count" -gt 0 || { echo "erro: nenhum arquivo SOPS encontrado" >&2; exit 2; }
      echo "$count arquivo(s) SOPS validado(s)."
    '

alias secrets-check := secret-check

# Run all local checks without deploying anything.
[group('validation')]
check: _justfile-check secret-check _manifests-check _nix-check

[private]
_justfile-check:
    just --unstable --fmt --check

[private]
_manifests-check:
    nix develop ./nixos --command bash -c 'kubectl kustomize kubernetes >/dev/null && kubectl kustomize kubernetes/apps >/dev/null && kubectl kustomize kubernetes/infra >/dev/null'

[private]
_nix-check:
    nix flake check ./nixos --no-build --all-systems
