Для установки Impulse через Helm используйте следующие команды:

```bash
helm repo add impulse https://eslupmi.github.io/helm-charts/packages
helm repo update
helm upgrade --install impulse impulse/impulse \
  --version 1.0.6 \
  --namespace impulse \
  --create-namespace \
  -f values-impulse.yaml
```
