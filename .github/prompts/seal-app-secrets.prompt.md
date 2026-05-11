---
name: seal-app-secrets
description: >
  Use when you need to add a new application to the bb-cluster with secrets sealed via
  Sealed Secrets (kubeseal). Generates: namespace YAML, sealing script, sealed secret manifest,
  ArgoCD Application YAML, and registers everything in base/kustomization.yaml.
  Trigger phrases: "dodaj aplikację z secretami", "seal secrets", "sealed secret dla", 
  "nowa aplikacja z secretami", "kubeseal", "SealedSecret".
agent: agent
---

# Zadanie: Skonfiguruj Sealed Secrets dla nowej aplikacji

Jesteś agentem zarządzającym klastrem Kubernetes opisanym w tym repozytorium.
Twoim zadaniem jest wygenerowanie wszystkich plików potrzebnych do dodania nowej aplikacji
z sekretami zaszyfrowanymi przez Sealed Secrets, zgodnie ze wzorcem użytym dla `passbolt`.

## Wzorzec repozytorium

Przeanalizuj następujące pliki referencyjne przed generowaniem kodu:

- `base/passbolt-namespace.yaml` — wzorzec namespace
- `base/passbolt-sealed-secret.yaml` — wzorzec SealedSecret
- `base/passbolt-application.yaml` — wzorzec ArgoCD Application z referencją do secretu
- `scripts/seal-passbolt-secrets.sh` — wzorzec skryptu do uszczelniania
- `scripts/generate-password.sh` — helper do generowania haseł
- `base/kustomization.yaml` — lista zasobów do aktualizacji

## Krok 1: Zbierz wymagania i odczytaj istniejącą konfigurację

Zapytaj użytkownika tylko o:

1. **Nazwa aplikacji** (`APP_NAME`) — np. `myapp` (lowercase, bez spacji); jeśli plik `base/<APP_NAME>-application.yaml` już istnieje, odczytaj go automatycznie.

Następnie **samodzielnie odczytaj** plik `base/<APP_NAME>-application.yaml` i wyodrębnij z niego:

- **Namespace** (`NAMESPACE`) — z `spec.destination.namespace`
- **Nazwa secretu** (`SECRET_NAME`) — z wartości `secretName`, `existingSecret`, lub podobnych pól w `valuesObject`
- **Wszystkie wartości sekretów** — przeszukaj cały `valuesObject` w poszukiwaniu pól, które:
  - zawierają hasła, tokeny, klucze API (pola o nazwach zawierających: `password`, `secret`, `token`, `key`, `credentials`, `auth`)
  - są referencjami do secretu (`existingSecret`, `existingSecretPasswordKey`)
  - są wartościami środowiskowymi przekazywanymi przez `passboltEnv.plain` lub odpowiedniki

**Reguły ekstrakcji wartości:**

- Jeśli wartość jest już ustawiona w `valuesObject` jako plaintext → przenieś ją 1:1 do `.env.<APP_NAME>`
- Jeśli pole wskazuje na `existingSecret` (czyli wartość jest już zewnętrzna) → zidentyfikuj oczekiwany klucz i zapytaj użytkownika o wartość
- Jeśli wartość jest powtórzeniem innego sekretu (np. kilka kluczy ma tę samą wartość jak `redis-password`) → użyj jednej zmiennej env dla wszystkich

Po ekstrakcji **pokaż użytkownikowi listę** znalezionych kluczy i ich wartości (zamaskuj hasła jako `***`) i poproś o potwierdzenie lub korektę przed wygenerowaniem plików.

## Krok 2: Wygeneruj pliki

### 2a. Namespace — `base/<APP_NAME>-namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <NAMESPACE>
```

### 2b. Skrypt uszczelniający — `scripts/seal-<APP_NAME>-secrets.sh`

Wzoruj się na `scripts/seal-passbolt-secrets.sh`. Skrypt musi:

- Wczytywać wartości z `.env.<APP_NAME>` (jeden klucz=wartość per linia)
- Walidować że wszystkie wymagane zmienne są ustawione
- Budować `kubectl create secret` z dokładnie tymi kluczami, których chart oczekuje (nazwy kluczy wyodrębnione w Kroku 1)

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="<NAMESPACE>"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR/../base"
ENV_FILE="$SCRIPT_DIR/../.env.<APP_NAME>"
CERT_FILE="$(mktemp)"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env.<APP_NAME> not found."
  echo "Wymagane zmienne (uzupełnij i zapisz jako .env.<APP_NAME>):"
  # Wypisz wszystkie wymagane zmienne wyodrębnione z pliku aplikacji
  echo "  ZMIENNA1=wartość"
  echo "  ZMIENNA2=wartość"
  exit 1
fi

source "$ENV_FILE"

# Walidacja — sprawdź każdą wymaganą zmienną (po jednej na każdy klucz secretu)
: "${ZMIENNA1:?ZMIENNA1 not set in .env.<APP_NAME>}"
: "${ZMIENNA2:?ZMIENNA2 not set in .env.<APP_NAME>}"

echo "==> Fetching sealed-secrets public cert from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  > "$CERT_FILE"

echo "==> Sealing <SECRET_NAME>..."
kubectl create secret generic <SECRET_NAME> \
  --namespace="$NAMESPACE" \
  --from-literal=klucz1="$ZMIENNA1" \
  --from-literal=klucz2="$ZMIENNA2" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/<APP_NAME>-sealed-secret.yaml"

rm -f "$CERT_FILE"
echo "==> Gotowe: base/<APP_NAME>-sealed-secret.yaml"
```

Ustaw skrypt jako wykonywalny (wspomnij użytkownikowi o `chmod +x`).

### 2c. Placeholder sealed secret — `base/<APP_NAME>-sealed-secret.yaml`

Utwórz plik z komentarzem (zostanie nadpisany po uruchomieniu skryptu):

```yaml
# Ten plik jest generowany automatycznie przez scripts/seal-<APP_NAME>-secrets.sh
# NIE edytuj ręcznie. Uruchom skrypt, żeby wygenerować zaszyfrowane dane.
#
# Wymagania: kubectl, kubeseal, dostęp do klastra
# Użycie:
#   1. Utwórz .env.<APP_NAME> z wymaganymi zmiennymi (patrz skrypt)
#   2. bash scripts/seal-<APP_NAME>-secrets.sh
```

### 2d. ArgoCD Application — `base/<APP_NAME>-application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <APP_NAME>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: <HELM_REPO_URL>
    chart: <CHART_NAME>
    targetRevision: "<CHART_VERSION>"
    helm:
      releaseName: <APP_NAME>
      valuesObject:
        # ... helm values ...
        # Referencja do secretu — użyj odpowiedniego dla danego charta:
        # existingSecret: <SECRET_NAME>
        # secretName: <SECRET_NAME>
  destination:
    server: https://kubernetes.default.svc
    namespace: <NAMESPACE>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

### 2e. Aktualizacja `base/kustomization.yaml`

Dodaj do listy `resources` (zachowaj istniejącą kolejność, dodaj na końcu):

```yaml
- <APP_NAME>-namespace.yaml
- <APP_NAME>-application.yaml
- <APP_NAME>-sealed-secret.yaml
```

## Krok 3: Instrukcja dla użytkownika

Po wygenerowaniu plików poinformuj użytkownika o kolejnych krokach:

```
Pliki zostały wygenerowane. Kolejne kroki:

1. Zweryfikuj plik .env.<APP_NAME> — wartości zostały przeniesione z pliku aplikacji.
   Sprawdź czy są kompletne, szczególnie pola które wymagały ręcznego uzupełnienia:
   cat .env.<APP_NAME>

2. Uruchom skrypt uszczelniający (wymaga dostępu do klastra):
   chmod +x scripts/seal-<APP_NAME>-secrets.sh
   bash scripts/seal-<APP_NAME>-secrets.sh

3. Sprawdź wygenerowany plik:
   cat base/<APP_NAME>-sealed-secret.yaml

4. Commituj TYLKO pliki yaml (nie .env!):
   git add base/<APP_NAME>-*.yaml base/kustomization.yaml scripts/seal-<APP_NAME>-secrets.sh
   git commit -m "feat: add <APP_NAME> with sealed secrets"
```

## Ważne zasady

- Plik `.env.<APP_NAME>` NIGDY nie trafia do gita. Sprawdź czy `.gitignore` zawiera `.env.*`.
- `SealedSecret` jest zaszyfrowany kluczem klastra — po rotacji klucza trzeba ponownie uszczelniać.
- Namespace musi istnieć przed aplikowaniem `SealedSecret` — dlatego namespace jest osobnym zasobem z niższym sync-wave.
- Jeśli chart używa `existingSecret`, upewnij się że nazwy kluczy w secret dokładnie odpowiadają temu czego chart oczekuje (sprawdź dokumentację charta).
