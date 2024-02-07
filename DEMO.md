# Demo
# After provisioning, run this command to create a policy for ldap-handler:
```bash
kubectl cp ./policy/ldap-handler.hcl north/vault-primary-0:/tmp/ldap-handler.hcl
kubectl -n north exec vault-primary-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault policy write ldap-handler /tmp/ldap-handler.hcl"
```
# After provisioning, run this command to create a role for ldap-handler:
```bash
kubectl -n north exec vault-primary-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault write auth/token/roles/ldap-handler \
    allowed_policies=ldap-handler \
    orphan=true \
    renewable=false \
    token_type=batch"
```

# Enable Audit Logs to stdout on the leader
```bash
for cluster_type in "dr" "kms" "primary"; do
    ROOT_TOKEN=$(cat externals/vault_operator_init_${cluster_type}.json | jq -r .root_token)
    UNSEAL_KEY_0=$(cat externals/vault_operator_init_${cluster_type}.json | jq -r '.unseal_keys_b64.[0]')
    if [[ "$cluster_type" == "dr" ]]; then
        ns=south
    fi
    if [[ "$cluster_type" == "kms" ]]; then
        ns=north
    fi
    if [[ "$cluster_type" == "primary" ]]; then
        ns=north
    fi
    if [[ "$cluster_type" == "pr-east" ]]; then
        ns=east
    fi
    if [[ "$cluster_type" == "pr-west" ]]; then
        ns=west
    fi
    kubectl -n $ns exec vault-${cluster_type}-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault login ${ROOT_TOKEN}"
    kubectl -n $ns exec vault-${cluster_type}-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault operator raft list-peers"
    kubectl -n $ns exec vault-${cluster_type}-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault audit enable file file_path=stdout"
    kubectl -n $ns exec vault-${cluster_type}-1 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault audit enable file file_path=stdout"
    kubectl -n $ns exec vault-${cluster_type}-2 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault audit enable file file_path=stdout"
done
```
# Generate a batch token using the ldap-handler role:
```bash
kubectl -n north exec vault-primary-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault token create \
    -role=ldap-handler \
    -ttl=8h \
    -format=json" > externals/auth-token-ldap-handler.json
```
# Login to the Secondary using the batch token
```bash
TOKEN_LOGIN=$(cat externals/auth-token-ldap-handler.json | jq -r .auth.client_token)
kubectl -n east exec vault-pr-east-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault login ${TOKEN_LOGIN}"
kubectl -n west exec vault-pr-west-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault login ${TOKEN_LOGIN}"
```
# Copy the Prometheus Metrics policy & create
```bash
kubectl cp ./policy/prometheus-metrics.hcl north/vault-primary-0:/tmp/prometheus-metrics.hcl
kubectl -n north exec vault-primary-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault policy write prometheus-metrics /tmp/prometheus-metrics.hcl"
```
# Generate Prometheus Metrics Token
```bash
kubectl -n north exec vault-primary-0 -- /bin/sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault token create \
  -field=token \
  -policy prometheus-metrics" \
  > externals/vault_prometheus_token_primary.json
```

