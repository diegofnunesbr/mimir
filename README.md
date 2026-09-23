# mimir

Instalação do **Grafana Mimir** em modo single-binary (`target: all`), pra
receber métricas via `remote_write` das VMs do homelab. Sem MinIO/S3: usa
`filesystem` como backend de storage, direto na PVC do pod - suficiente
pra escala de homelab, não recomendado em produção multi-tenant.

Mesmo padrão da empresa no caminho de envio: o Alloy das VMs manda pro
Mimir com **mTLS** (certificado de cliente), e o Ingress expõe **só** o
envio. Lá é um gateway dedicado (`telemetry-agents`) na frente de um Mimir
multi-tenant; aqui é o próprio Ingress do ingress-nginx fazendo a
verificação, na frente de um Mimir sem multi-tenant. O Mimir não tem
autenticação própria, então sem isso qualquer um na rede conseguia ler a
config, consultar e gravar métricas.

## Pré-requisitos

- `Kubernetes` instalado
- `kubectl` instalado
- ArgoCD instalado (ver repositório `argocd`)
- `cert-manager` instalado (repositório `cert-manager`)
- `ingress-nginx` instalado (repositório `ingress-nginx`)
- DNS `mimir.diegofnunesbr.com` apontando pro node (ver repositório `dns`)

## Estrutura do repositório

```text
mimir/
├── applications/
│   └── argocd.mimir.yaml     # Application do Argo CD
├── mimir.yaml                # Namespace, ConfigMap, PVC, Deployment, Service
└── README.md
```

## Instalar o Mimir

```bash
git clone https://github.com/diegofnunesbr/mimir.git
cd mimir
kubectl apply -f applications/argocd.mimir.yaml
```

**Lembrete:** a Application aponta pro GitHub (`repoURL`), não pro seu
clone local - qualquer mudança em `mimir.yaml` só tem efeito depois de
`git push` (e um sync, automático ou forçado via
`kubectl -n argocd patch application mimir --type merge -p '{"operation":{"sync":{}}}'`).

## Acesso

| Quem | Por onde | Autenticação |
|---|---|---|
| Alloy nas VMs (envio) | `https://mimir.diegofnunesbr.com/api/v1/push` | certificado de cliente emitido pela CA `mimir-agents-ca` |
| Grafana (consultas) | `http://mimir.mimir.svc:8080/prometheus`, direto pelo Service | nenhuma, só dentro do cluster |
| Você (debug, páginas de admin) | `kubectl --context=k0s -n mimir port-forward svc/mimir 8080:8080` e `http://localhost:8080` | acesso ao cluster |

O Ingress só roteia `/api/v1/push` (`pathType: Exact`) e exige o
certificado no host inteiro (`auth-tls-verify-client: "on"`, confiando na
CA do Secret `cert-manager/mimir-agents-ca`). Sem certificado, qualquer
requisição volta `400 No required SSL certificate was sent`; com
certificado, qualquer caminho fora do envio volta 404. Abrir o endereço no
navegador não funciona de propósito: quem usa ele é o Alloy.

A CA fica no repositório `cert-manager`; o certificado de cliente e a
entrega pras VMs (e a renovação anual) no repositório `rundeck`, seção
"Certificado mTLS do Alloy".

## Verificar

```bash
kubectl --context=k0s -n mimir port-forward svc/mimir 8080:8080 &
curl -s -G 'http://localhost:8080/prometheus/api/v1/query' \
  --data-urlencode 'query=up{host="<ip-da-vm-onboardada>"}'
```

Resultado esperado: `"status":"success"` com um vetor não vazio. Se vier
`"error":"too many unhealthy instances in the ring"`, é porque
`replication_factor` do `ingester`/`store_gateway` está diferente de `1` -
esse manifesto já sobe com `replication_factor: 1` porque só existe uma
réplica; se algum dia aumentar `spec.replicas` no Deployment, ajuste esse
valor junto.

## Remover o Mimir

```bash
cd mimir
kubectl delete -f applications/argocd.mimir.yaml
kubectl delete namespace mimir --ignore-not-found
```

Isso também apaga as métricas armazenadas (a PVC fica presa ao namespace).
