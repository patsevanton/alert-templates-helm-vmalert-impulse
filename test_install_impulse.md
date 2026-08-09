Для установки Impulse через Helm используйте следующие команды:

```bash
helm repo add impulse https://eslupmi-community.github.io/helm-charts
helm repo update
helm install my-impulse impulse/impulse \
  --version 1.0.14 \
  --namespace impulse \
  --create-namespace \
  -f values/values-impulse.yaml
```
