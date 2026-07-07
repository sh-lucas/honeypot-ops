#!/usr/bin/env bash
set -eo pipefail

export KUBECONFIG="$(pwd)/kubernetes/kubeconfig.yaml"

echo "=== 1. Removendo finalizers dos recursos do Flux para destravar o namespace ==="
# Tenta remover os finalizers das kustomizations e gitrepos para que o k8s consiga deletá-los
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system -o jsonpath='{.items[*].metadata.name}' | xargs -r -I {} sh -c '
  echo "Removendo finalizer da Kustomization {}..."
  kubectl patch kustomization/{} -n flux-system --type=merge -p "{\"metadata\":{\"finalizers\":null}}" || true
'

kubectl get gitrepositories.source.toolkit.fluxcd.io -n flux-system -o jsonpath='{.items[*].metadata.name}' | xargs -r -I {} sh -c '
  echo "Removendo finalizer do GitRepository {}..."
  kubectl patch gitrepository/{} -n flux-system --type=merge -p "{\"metadata\":{\"finalizers\":null}}" || true
'

echo "=== 2. Removendo finalizers do namespace flux-system ==="
# Remove o finalizer do próprio namespace caso ele continue preso em Terminating
kubectl get namespace flux-system -o json | jq '.spec.finalizers = []' > /tmp/ns-flux-system.json || true
if [ -s /tmp/ns-flux-system.json ]; then
  kubectl replace --raw "/api/v1/namespaces/flux-system/finalize" -f /tmp/ns-flux-system.json || true
  rm -f /tmp/ns-flux-system.json
fi

echo "=== 3. Aguardando a deleção completa do namespace ==="
kubectl wait --for=delete namespace/flux-system --timeout=60s || true

# Verifica se o namespace sumiu
if kubectl get ns flux-system >/dev/null 2>&1; then
  echo "⚠️ Namespace flux-system ainda existe. Forçando deleção..."
  kubectl delete ns flux-system --grace-period=0 --force || true
else
  echo "✅ Namespace flux-system deletado com sucesso!"
fi

echo ""
echo "=== PRÓXIMOS PASSOS ==="
echo "Como você comentou que vai recriar o repositório do zero sem histórico (o que é excelente para limpar os secrets antigos expostos),"
echo "a maneira mais limpa e recomendada de restaurar o Flux agora é rodar o comando de bootstrap novamente:"
echo ""
echo "  export GITHUB_TOKEN=seu_token_aqui"
echo "  flux bootstrap github \\"
echo "    --owner=sh-lucas \\"
echo "    --repository=catnip-infra \\"
echo "    --branch=master \\"
echo "    --path=./kubernetes \\"
echo "    --personal"
echo ""
echo "Isso vai recriar o namespace 'flux-system', configurar a chave de deploy SSH correta no GitHub, e aplicar os recursos."
echo "Depois disso, o Flux lerá seu kubernetes/sync.yaml e aplicará a infra (cert-manager) e as apps (zot, cloudflared, hello-world) automaticamente!"
